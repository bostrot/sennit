/// Packs the browser build into the signed archive the app downloads.
///
/// ```
/// SENNIT_WEB_SIGNING_KEY=<base64 seed> \
///   dart run tooling/scripts/package_web_bundle.dart apps/weft/build/web 1.0.25 dist
/// ```
///
/// Writes `sennit-web-<version>.zip`, `sennit-web-<version>.json` (version,
/// archive name, SHA-256, size) and `sennit-web-<version>.json.sig` (Ed25519
/// over the JSON's exact bytes). The app verifies the signature against the
/// public key in `packages/weft_remote/lib/src/web_bundle.dart`, so this
/// refuses to sign with a key whose public half is not that one — a rotated
/// secret without the matching code change would otherwise publish bundles
/// every install rejects.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' hide Sha256;
import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: package_web_bundle.dart <build dir> <version> <out>',
    );
    exit(64);
  }
  final [buildDir, version, outDir] = args;
  final seed = Platform.environment['SENNIT_WEB_SIGNING_KEY'];
  if (seed == null || seed.trim().isEmpty) {
    stderr.writeln('SENNIT_WEB_SIGNING_KEY is not set');
    exit(1);
  }

  final keys = await Ed25519().newKeyPairFromSeed(base64.decode(seed.trim()));
  final public = base64.encode((await keys.extractPublicKey()).bytes);
  final shipped = RegExp(r"kWebBundlePublicKey =\s*'([^']+)'")
      .firstMatch(
        File('packages/weft_remote/lib/src/web_bundle.dart').readAsStringSync(),
      )
      ?.group(1);
  if (public != shipped) {
    stderr.writeln('The signing key does not match kWebBundlePublicKey.');
    exit(1);
  }

  // Sorted, with a fixed timestamp, so the same build packs to the same bytes.
  final root = Directory(buildDir);
  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.substring(root.path.length + 1))
          .where((p) => !p.endsWith('.DS_Store'))
          .toList()
        ..sort();
  if (!files.contains('index.html') || !files.contains('sqlite3.wasm')) {
    stderr.writeln('$buildDir is missing index.html or sqlite3.wasm');
    exit(1);
  }
  final archive = Archive();
  for (final path in files) {
    final file = ArchiveFile.bytes(
      path,
      File('${root.path}/$path').readAsBytesSync(),
    )..lastModTime = 0;
    archive.addFile(file);
  }
  final zip = ZipEncoder().encodeBytes(archive);
  final hash = await Sha256().hash(zip);
  final digest = [
    for (final b in hash.bytes) b.toRadixString(16).padLeft(2, '0'),
  ].join();

  final name = 'sennit-web-$version';
  final manifest = utf8.encode(
    jsonEncode({
      'format': 1,
      'version': version,
      'file': '$name.zip',
      'sha256': digest,
      'size': zip.length,
    }),
  );
  final signature = await Ed25519().sign(manifest, keyPair: keys);

  Directory(outDir).createSync(recursive: true);
  File('$outDir/$name.zip').writeAsBytesSync(zip);
  File('$outDir/$name.json').writeAsBytesSync(manifest);
  final sig = '${base64.encode(signature.bytes)}\n';
  File('$outDir/$name.json.sig').writeAsStringSync(sig);
  stdout.writeln('$name.zip  ${zip.length} bytes  sha256 $digest');
}
