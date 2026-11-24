import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_remote/weft_remote.dart';

/// Where the installed bundle stands.
sealed class WebBundleState {
  const WebBundleState();
}

class WebBundleAbsent extends WebBundleState {
  const WebBundleAbsent();
}

class WebBundleDownloading extends WebBundleState {
  const WebBundleDownloading(this.received, this.total);
  final int received;

  /// Zero until the manifest says how big the archive is.
  final int total;

  double? get fraction => total > 0 ? received / total : null;
}

class WebBundleReady extends WebBundleState {
  const WebBundleReady({required this.directory, required this.sizeBytes});

  /// The unpacked files, ready to serve.
  final Directory directory;
  final int sizeBytes;
}

/// Why the last download stopped.
enum WebBundleError {
  /// The release has no bundle for this version — published without the
  /// signing key, or not published yet.
  unavailable,

  /// No connection, or the server failed.
  network,

  /// The download did not verify. Never kept.
  rejected,
}

class WebBundleFailed extends WebBundleState {
  const WebBundleFailed(this.error);
  final WebBundleError error;
}

/// Sennit Web's files: downloaded on demand from this version's GitHub
/// release, verified, unpacked into the app's support directory, removable.
///
/// Nothing here ships inside the app. The release's manifest is signed with
/// the key in `weft_remote`, the manifest pins the archive's SHA-256 and size,
/// and the archive is unpacked only after both check out — into a staging
/// directory that becomes the bundle with one rename, so a crash mid-unpack
/// never leaves half a bundle that looks installed.
class WebBundleStore {
  WebBundleStore({
    required this.version,
    http.Client? client,
    Future<Directory> Function()? root,
    this.releaseBase = 'https://github.com/bostrot/sennit/releases/download',
    this.publicKey = kWebBundlePublicKey,
  }) : _client = client ?? http.Client(),
       _root = root ?? _defaultRoot;

  final String version;
  final String releaseBase;
  final String publicKey;
  final http.Client _client;
  final Future<Directory> Function() _root;

  static const String _marker = '.sennit-web.json';

  static Future<Directory> _defaultRoot() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'sennit-web'),
  );

  Future<Directory> _versionDir() async =>
      Directory(p.join((await _root()).path, version));

  /// What is installed for this version, read from disk.
  Future<WebBundleState> current() async {
    final dir = await _versionDir();
    final marker = File(p.join(dir.path, _marker));
    if (!marker.existsSync()) return const WebBundleAbsent();
    try {
      final json = jsonDecode(marker.readAsStringSync()) as Map;
      return WebBundleReady(directory: dir, sizeBytes: json['size']! as int);
    } on Object {
      return const WebBundleAbsent();
    }
  }

  /// Downloads, verifies and installs, reporting progress as it goes.
  Stream<WebBundleState> download() async* {
    yield const WebBundleDownloading(0, 0);
    final name = 'sennit-web-$version';
    final base = '$releaseBase/v$version';
    final WebBundleManifest manifest;
    try {
      final manifestBytes = await _get('$base/$name.json');
      final signature = utf8.decode(await _get('$base/$name.json.sig'));
      manifest = await WebBundleManifest.verify(
        manifestBytes,
        signature,
        expectedVersion: version,
        publicKey: publicKey,
      );
    } on _NotFound {
      yield const WebBundleFailed(WebBundleError.unavailable);
      return;
    } on WebBundleException {
      yield const WebBundleFailed(WebBundleError.rejected);
      return;
    } on Object {
      yield const WebBundleFailed(WebBundleError.network);
      return;
    }

    final archive = BytesBuilder(copy: false);
    try {
      final response = await _client.send(
        http.Request('GET', Uri.parse('$base/${manifest.file}')),
      );
      if (response.statusCode == 404) throw _NotFound();
      if (response.statusCode != 200) {
        throw HttpException('${response.statusCode}');
      }
      var last = 0;
      await for (final chunk in response.stream) {
        archive.add(chunk);
        // Refuse to buffer past what the signed manifest promised.
        if (archive.length > manifest.size) {
          throw const WebBundleException(WebBundleFailure.digest);
        }
        if (archive.length - last > 256 * 1024) {
          last = archive.length;
          yield WebBundleDownloading(archive.length, manifest.size);
        }
      }
    } on _NotFound {
      yield const WebBundleFailed(WebBundleError.unavailable);
      return;
    } on WebBundleException {
      yield const WebBundleFailed(WebBundleError.rejected);
      return;
    } on Object {
      yield const WebBundleFailed(WebBundleError.network);
      return;
    }

    try {
      final bytes = archive.takeBytes();
      await manifest.checkArchive(bytes);
      final files = unpackWebBundle(bytes);
      final ready = await _install(manifest, files);
      yield ready;
    } on WebBundleException {
      yield const WebBundleFailed(WebBundleError.rejected);
    }
  }

  Future<WebBundleReady> _install(
    WebBundleManifest manifest,
    Map<String, Uint8List> files,
  ) async {
    final root = await _root();
    final target = await _versionDir();
    final staging = Directory(p.join(root.path, '$version.partial'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    for (final MapEntry(:key, :value) in files.entries) {
      final file = File(p.join(staging.path, key));
      // unpackWebBundle refused anything that could leave the directory; this
      // checks the joined path anyway, since it is what actually gets written.
      if (!p.isWithin(staging.path, file.path)) {
        throw WebBundleException(WebBundleFailure.archive, key);
      }
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(value);
    }
    File(
      p.join(staging.path, _marker),
    ).writeAsStringSync(jsonEncode(manifest.toJson()));
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(target.path);
    // Bundles for other versions are dead weight: each one only matches the
    // app build it was made for.
    for (final other in root.listSync().whereType<Directory>()) {
      if (other.path != target.path) other.deleteSync(recursive: true);
    }
    return WebBundleReady(directory: target, sizeBytes: manifest.size);
  }

  /// Deletes every downloaded bundle.
  Future<void> remove() async {
    final root = await _root();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  Future<Uint8List> _get(String url) async {
    final response = await _client.get(Uri.parse(url));
    if (response.statusCode == 404) throw _NotFound();
    if (response.statusCode != 200) {
      throw HttpException('${response.statusCode}');
    }
    return response.bodyBytes;
  }
}

class _NotFound implements Exception {}
