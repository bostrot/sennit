import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The user cancelled; not an error.
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class DownloadFailure implements Exception {
  const DownloadFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Moves one file from a URL to disk. Two implementations: plain HTTP for
/// desktop, and the OS download service for mobile (see
/// `background_transport.dart` for why mobile cannot just use HTTP).
abstract class ModelDownloadTransport {
  /// [headers] are sent with the request.
  ///
  /// Empty for a model file, which is a public URL on a CDN. Not empty for
  /// Matrix media since spec v1.11, which moved every download behind
  /// `Authorization: Bearer` — the media viewer's Save action reuses this
  /// transport, and without the header a saved photo would be a 401 page
  /// written to the user's Downloads folder.
  ///
  /// [requiresWiFi] holds the download until the device is on Wi-Fi, where
  /// the operating system can tell; the plain HTTP transport cannot, and
  /// runs on whatever network there is.
  Future<void> download({
    required Uri url,
    required File target,
    required int expectedBytes,
    required String displayName,
    Map<String, String> headers = const {},
    void Function(int totalOnDisk)? onBytes,
    Future<bool> Function()? shouldContinue,
    bool requiresWiFi = false,
  });

  void dispose() {}
}

/// Streaming HTTP with range-resume.
///
/// Desktop needs no OS service — the process simply keeps running — and this
/// path also serves as the fallback anywhere the plugin cannot. Resume works
/// by asking the server for bytes from wherever the partial file ends, so a
/// killed download continues instead of starting over.
class HttpModelDownloadTransport implements ModelDownloadTransport {
  HttpModelDownloadTransport({http.Client? httpClient})
    : _http = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;

  @override
  Future<void> download({
    required Uri url,
    required File target,
    required int expectedBytes,
    required String displayName,
    Map<String, String> headers = const {},
    void Function(int totalOnDisk)? onBytes,
    Future<bool> Function()? shouldContinue,
    bool requiresWiFi = false,
  }) async {
    await target.parent.create(recursive: true);

    // The catalog size is a hint for progress, not a contract: published
    // sizes drift, and treating a mismatch as corruption would make a good
    // download restart forever.
    var have = target.existsSync() ? target.lengthSync() : 0;
    if (have >= expectedBytes && expectedBytes > 0) return;

    final request = http.Request('GET', url);
    request.headers.addAll(headers);
    if (have > 0) request.headers['range'] = 'bytes=$have-';

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } on Exception catch (e) {
      throw DownloadFailure('Could not reach the download server: $e');
    }

    if (response.statusCode == 200 && have > 0) {
      // Server ignored the range; it is sending the whole file again.
      await target.delete();
      have = 0;
    } else if (response.statusCode != 200 && response.statusCode != 206) {
      throw DownloadFailure('$displayName failed (${response.statusCode})');
    }

    final sink = target.openWrite(mode: FileMode.append);
    try {
      await for (final chunk in response.stream) {
        if (shouldContinue != null && !await shouldContinue()) {
          throw const DownloadCancelled();
        }
        sink.add(chunk);
        have += chunk.length;
        onBytes?.call(have);
      }
    } finally {
      await sink.close();
    }

    // A stream that ended without error is complete; only an empty file is
    // unambiguously wrong. Comparing against the catalog size would fail a
    // perfectly good download whenever that published number has drifted.
    if (!target.existsSync() || target.lengthSync() == 0) {
      throw DownloadFailure('$displayName produced no data. Retry to resume.');
    }
  }

  @override
  void dispose() {
    if (_ownsClient) _http.close();
  }
}
