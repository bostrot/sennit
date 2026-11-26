import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide Sha256;
import 'package:cryptography/cryptography.dart';

/// The Ed25519 key release builds sign Sennit Web bundles with. Its private
/// half is the `SENNIT_WEB_SIGNING_KEY` repository secret.
const String kWebBundlePublicKey =
    'x4e9cLCfYe9X1gTWEWwGV8W/wdtwa47uA0sMIgEvoUo=';

/// Why a downloaded bundle was refused. Nothing refused is ever kept.
enum WebBundleFailure {
  /// The manifest's signature does not verify against [kWebBundlePublicKey].
  signature,

  /// The manifest is for another app version.
  version,

  /// The archive's hash or size is not the one the manifest signs.
  digest,

  /// The archive is malformed, or names a path outside its own directory.
  archive,
}

class WebBundleException implements Exception {
  const WebBundleException(this.failure, [this.detail = '']);
  final WebBundleFailure failure;
  final String detail;

  @override
  String toString() => 'WebBundleException(${failure.name}) $detail';
}

/// What a release says about its browser bundle: which version, which
/// archive, and that archive's SHA-256 and size. Signed as the exact bytes
/// published, so verification never depends on re-serialising JSON.
class WebBundleManifest {
  const WebBundleManifest({
    required this.version,
    required this.file,
    required this.sha256,
    required this.size,
  });

  /// Parses and checks [bytes] against [signature] (base64 Ed25519).
  static Future<WebBundleManifest> verify(
    Uint8List bytes,
    String signature, {
    required String expectedVersion,
    String publicKey = kWebBundlePublicKey,
  }) async {
    final ok = await Ed25519().verify(
      bytes,
      signature: Signature(
        base64.decode(signature.trim()),
        publicKey: SimplePublicKey(
          base64.decode(publicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!ok) throw const WebBundleException(WebBundleFailure.signature);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const WebBundleException(WebBundleFailure.archive, 'manifest');
    }
    if (json is! Map<String, Object?> || json['format'] != 1) {
      throw const WebBundleException(WebBundleFailure.archive, 'manifest');
    }
    final manifest = WebBundleManifest(
      version: json['version']! as String,
      file: json['file']! as String,
      sha256: json['sha256']! as String,
      size: json['size']! as int,
    );
    if (manifest.version != expectedVersion) {
      throw WebBundleException(
        WebBundleFailure.version,
        '${manifest.version} != $expectedVersion',
      );
    }
    return manifest;
  }

  final String version;

  /// The archive's file name on the release page.
  final String file;

  /// Lowercase hex.
  final String sha256;
  final int size;

  Map<String, Object?> toJson() => {
    'format': 1,
    'version': version,
    'file': file,
    'sha256': sha256,
    'size': size,
  };

  /// Checks [archive] against what this manifest signs.
  Future<void> checkArchive(Uint8List archive) async {
    if (archive.length != size) {
      throw WebBundleException(
        WebBundleFailure.digest,
        'size ${archive.length} != $size',
      );
    }
    final digest = await Sha256().hash(archive);
    final hex = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (hex != sha256) {
      throw const WebBundleException(WebBundleFailure.digest, 'sha256');
    }
  }
}

/// The files of a verified archive, by relative path.
///
/// Refuses absolute paths, `..` segments and backslashes rather than
/// normalising them: an archive that needs normalising was not built by the
/// release workflow.
Map<String, Uint8List> unpackWebBundle(Uint8List zip) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zip);
  } on Object {
    throw const WebBundleException(WebBundleFailure.archive, 'zip');
  }
  final files = <String, Uint8List>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = entry.name;
    final segments = name.split('/');
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.contains(r'\') ||
        name.contains(':') ||
        segments.any((s) => s == '..' || s == '.' || s.isEmpty)) {
      throw WebBundleException(WebBundleFailure.archive, name);
    }
    files[name] = entry.readBytes() ?? Uint8List(0);
  }
  if (!files.containsKey('index.html')) {
    throw const WebBundleException(WebBundleFailure.archive, 'no index.html');
  }
  return files;
}
