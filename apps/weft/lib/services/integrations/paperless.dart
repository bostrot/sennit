import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_attachments/weft_attachments.dart';

/// One document, as the paperless-ngx API lists it.
class PaperlessDocument {
  const PaperlessDocument({
    required this.id,
    required this.title,
    this.correspondent,
    this.created,
  });

  final int id;
  final String title;
  final String? correspondent;
  final DateTime? created;
}

/// Talks to the user's own paperless-ngx instance.
///
/// Read-only on purpose: Braid searches, lists and downloads so a document can
/// be shared into a conversation. Filing things *into* the archive is
/// paperless's own job (and its own apps do it better).
class PaperlessClient {
  PaperlessClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final String token;
  final http.Client _http;

  Map<String, String> get _headers => {'authorization': 'Token $token'};

  Uri _api(String path, [Map<String, String>? query]) => baseUrl.replace(
    path: '${baseUrl.path.replaceFirst(RegExp(r'/$'), '')}$path',
    queryParameters: query,
  );

  Future<bool> probe() async {
    try {
      final response = await _http
          .get(_api('/api/documents/', {'page_size': '1'}), headers: _headers)
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// Newest first; [query] narrows by paperless's own full-text search.
  Future<List<PaperlessDocument>> search(String query, {int limit = 25}) async {
    final response = await _http
        .get(
          _api('/api/documents/', {
            'page_size': '$limit',
            'ordering': '-created',
            if (query.trim().isNotEmpty) 'query': query.trim(),
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw PaperlessException('paperless answered ${response.statusCode}.');
    }

    final decoded = jsonDecode(response.body);
    final results = decoded is Map ? decoded['results'] : null;
    if (results is! List) return const [];
    return [
      for (final row in results)
        if (row is Map && row['id'] is int)
          PaperlessDocument(
            id: row['id'] as int,
            title: (row['title'] as String?) ?? 'Untitled',
            correspondent: row['correspondent_name'] as String?,
            created: DateTime.tryParse(row['created'] as String? ?? ''),
          ),
    ];
  }

  /// Downloads the document to a temp file and describes it for the send
  /// pipeline. The archived PDF is what paperless serves by default, which is
  /// exactly the thing worth sharing.
  Future<AttachmentSource> stage(PaperlessDocument document) async {
    final response = await _http
        .get(_api('/api/documents/${document.id}/download/'), headers: _headers)
        .timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) {
      throw PaperlessException('The download answered ${response.statusCode}.');
    }

    final safe = document.title
        .replaceAll(RegExp(r'[^\w\s.-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, '${safe.isEmpty ? 'document' : safe}.pdf'),
    );
    await file.writeAsBytes(response.bodyBytes, flush: true);

    final bytes = response.bodyBytes;
    return AttachmentSource(
      filename: file.path,
      sizeBytes: bytes.length,
      header: Uint8List.sublistView(
        bytes,
        0,
        bytes.length < 64 ? bytes.length : 64,
      ),
      declaredMimeType: 'application/pdf',
    );
  }

  void dispose() => _http.close();
}

class PaperlessException implements Exception {
  const PaperlessException(this.message);

  final String message;

  @override
  String toString() => message;
}
