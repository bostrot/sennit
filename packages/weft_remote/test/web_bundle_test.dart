import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide Sha256;
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:weft_remote/weft_remote.dart';

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    archive.addFile(ArchiveFile.bytes(key, utf8.encode(value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// [_zip] with an entry named [raw], which the encoder would not write as it
/// is: it turns backslashes into slashes since archive 4.4. A placeholder of
/// the same length is encoded and swapped for [raw] in the bytes — names are
/// outside the CRC, so the archive stays valid.
Uint8List _zipNamed(String raw) {
  final placeholder = raw.replaceAll(r'\', '|');
  final bytes = _zip({'index.html': '', placeholder: 'x'});
  final from = utf8.encode(placeholder);
  final to = utf8.encode(raw);
  for (var i = 0; i + from.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < from.length && match; j++) {
      match = bytes[i + j] == from[j];
    }
    if (match) bytes.setRange(i, i + to.length, to);
  }
  return bytes;
}

void main() {
  late SimpleKeyPair keys;
  late String publicKey;

  setUpAll(() async {
    keys = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 7));
    publicKey = base64.encode((await keys.extractPublicKey()).bytes);
  });

  Future<(Uint8List, String)> signed(Map<String, Object?> manifest) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
    final sig = await Ed25519().sign(bytes, keyPair: keys);
    return (bytes, base64.encode(sig.bytes));
  }

  Future<Map<String, Object?>> manifestFor(Uint8List zip) async => {
    'format': 1,
    'version': '1.0.25',
    'file': 'sennit-web-1.0.25.zip',
    'sha256': (await Sha256().hash(
      zip,
    )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    'size': zip.length,
  };

  test('a signed bundle for this version verifies and unpacks', () async {
    final zip = _zip({'index.html': '<html>', 'main.dart.js': 'x'});
    final (bytes, sig) = await signed(await manifestFor(zip));
    final manifest = await WebBundleManifest.verify(
      bytes,
      sig,
      expectedVersion: '1.0.25',
      publicKey: publicKey,
    );
    await manifest.checkArchive(zip);
    expect(
      unpackWebBundle(zip).keys,
      containsAll(['index.html', 'main.dart.js']),
    );
  });

  Matcher fails(WebBundleFailure f) =>
      throwsA(isA<WebBundleException>().having((e) => e.failure, 'failure', f));

  test('a manifest edited after signing is refused', () async {
    final zip = _zip({'index.html': '<html>'});
    final (bytes, sig) = await signed(await manifestFor(zip));
    final edited = Uint8List.fromList(bytes)..[bytes.length - 3] ^= 1;
    expect(
      WebBundleManifest.verify(
        edited,
        sig,
        expectedVersion: '1.0.25',
        publicKey: publicKey,
      ),
      fails(WebBundleFailure.signature),
    );
  });

  test('the release key refuses a bundle signed by anyone else', () async {
    final zip = _zip({'index.html': '<html>'});
    final (bytes, sig) = await signed(await manifestFor(zip));
    expect(
      WebBundleManifest.verify(bytes, sig, expectedVersion: '1.0.25'),
      fails(WebBundleFailure.signature),
    );
  });

  test('a bundle for another version is refused', () async {
    final zip = _zip({'index.html': '<html>'});
    final (bytes, sig) = await signed(await manifestFor(zip));
    expect(
      WebBundleManifest.verify(
        bytes,
        sig,
        expectedVersion: '1.0.26',
        publicKey: publicKey,
      ),
      fails(WebBundleFailure.version),
    );
  });

  test('a swapped archive fails the hash', () async {
    final zip = _zip({'index.html': '<html>'});
    final (bytes, sig) = await signed(await manifestFor(zip));
    final manifest = await WebBundleManifest.verify(
      bytes,
      sig,
      expectedVersion: '1.0.25',
      publicKey: publicKey,
    );
    final other = _zip({'index.html': '<evil>'});
    expect(manifest.checkArchive(other), fails(WebBundleFailure.digest));
  });

  test('paths that leave the bundle directory are refused', () {
    for (final name in ['../x', '/etc/x', r'a\b', 'a/../../b', 'c:/x']) {
      expect(
        () => unpackWebBundle(_zipNamed(name)),
        fails(WebBundleFailure.archive),
        reason: name,
      );
    }
  });

  test('the shipped public key is a valid Ed25519 key', () {
    expect(base64.decode(kWebBundlePublicKey), hasLength(32));
  });
}
