import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide Sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/services/web/web_bundle_store.dart';

void main() {
  late Directory root;
  late SimpleKeyPair keys;
  late String publicKey;

  setUpAll(() async {
    keys = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 3));
    publicKey = base64.encode((await keys.extractPublicKey()).bytes);
  });

  setUp(() => root = Directory.systemTemp.createTempSync('sennit-web-test'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Uint8List zip(Map<String, String> files) {
    final archive = Archive();
    for (final MapEntry(:key, :value) in files.entries) {
      archive.addFile(ArchiveFile.bytes(key, utf8.encode(value)));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  /// A release page serving [archive] under a manifest signed by [signer],
  /// claiming [claimedArchive]'s hash.
  Future<http.Client> release(
    Uint8List archive, {
    Uint8List? claimedArchive,
    SimpleKeyPair? signer,
  }) async {
    final claimed = claimedArchive ?? archive;
    final manifest = utf8.encode(
      jsonEncode({
        'format': 1,
        'version': '9.9.9',
        'file': 'sennit-web-9.9.9.zip',
        'sha256': (await Sha256().hash(
          claimed,
        )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'size': claimed.length,
      }),
    );
    final sig = await Ed25519().sign(manifest, keyPair: signer ?? keys);
    return MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('.json')) return http.Response.bytes(manifest, 200);
      if (path.endsWith('.json.sig')) {
        return http.Response(base64.encode(sig.bytes), 200);
      }
      if (path.endsWith('.zip')) return http.Response.bytes(archive, 200);
      return http.Response('', 404);
    });
  }

  WebBundleStore store(http.Client client) => WebBundleStore(
    version: '9.9.9',
    client: client,
    root: () async => root,
    publicKey: publicKey,
  );

  test('a verified bundle is installed, found again, and removed', () async {
    final archive = zip({'index.html': '<html>', 'assets/a.txt': 'a'});
    final s = store(await release(archive));
    expect(await s.current(), isA<WebBundleAbsent>());

    final last = await s.download().last;
    expect(last, isA<WebBundleReady>());
    final dir = (last as WebBundleReady).directory;
    expect(File('${dir.path}/assets/a.txt').readAsStringSync(), 'a');
    expect(await s.current(), isA<WebBundleReady>());

    await s.remove();
    expect(await s.current(), isA<WebBundleAbsent>());
  });

  test('a swapped archive is rejected and nothing is kept', () async {
    final good = zip({'index.html': '<html>'});
    final evil = zip({'index.html': '<script>evil</script>'});
    final s = store(await release(evil, claimedArchive: good));
    final last = await s.download().last;
    expect(last, isA<WebBundleFailed>());
    expect((last as WebBundleFailed).error, WebBundleError.rejected);
    expect(await s.current(), isA<WebBundleAbsent>());
  });

  test('a manifest signed by another key is rejected', () async {
    final stranger = await Ed25519().newKeyPairFromSeed(
      List<int>.filled(32, 9),
    );
    final s = store(await release(zip({'index.html': ''}), signer: stranger));
    final last = await s.download().last as WebBundleFailed;
    expect(last.error, WebBundleError.rejected);
  });

  test('a release without a bundle says so', () async {
    final s = store(MockClient((_) async => http.Response('', 404)));
    final last = await s.download().last as WebBundleFailed;
    expect(last.error, WebBundleError.unavailable);
  });

  test('a newer version replaces the old one on disk', () async {
    Directory('${root.path}/1.0.0').createSync(recursive: true);
    final s = store(await release(zip({'index.html': ''})));
    await s.download().last;
    expect(root.listSync().map((e) => e.path.split('/').last).toList(), [
      '9.9.9',
    ]);
  });
}
