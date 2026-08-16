import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Thrown when transcription fails in a way worth showing the user.
class TranscriptionException implements Exception {
  const TranscriptionException(
    this.message, {
    this.statusCode,
    this.retryable = false,
  });

  final String message;
  final int? statusCode;

  /// Whether retrying later could plausibly succeed. Rate limits and 5xx are
  /// retryable; a rejected API key is not, and retrying it just burns quota.
  final bool retryable;

  @override
  String toString() => 'TranscriptionException: $message';
}

/// A voice message ready to transcribe.
@immutable
class TranscriptionRequest {
  const TranscriptionRequest({
    required this.audio,
    required this.filename,
    this.mimeType = 'audio/ogg',
    this.languageHint,
    this.prompt,
  });

  final Uint8List audio;

  /// Sent as the multipart filename. Whisper-style backends use the extension
  /// to pick a decoder, so it must reflect the real container.
  final String filename;

  final String mimeType;

  /// BCP-47 or ISO-639-1 hint. Null asks the backend to auto-detect, which is
  /// the default because most people's voice notes are in one language and
  /// detection handles the rest.
  final String? languageHint;

  /// Optional context to bias decoding — names and jargon the model would
  /// otherwise mangle.
  final String? prompt;
}

/// The result of a transcription.
@immutable
class Transcript {
  const Transcript({
    required this.text,
    required this.provider,
    this.language,
    this.durationMs,
    this.confidence,
  });

  final String text;

  /// Which provider produced this, so a re-transcription can be attributed.
  final String provider;

  /// Language the backend detected or was told to use.
  final String? language;

  final int? durationMs;
  final double? confidence;

  bool get isEmpty => text.trim().isEmpty;

  @override
  String toString() => 'Transcript(${language ?? "?"}, ${text.length} chars)';
}

/// Turns speech into text.
///
/// Weft hosts no transcription service. The user points this at whatever they
/// run or pay for, which is the whole reason it is an interface — and why the
/// adapters below cover the two request shapes that between them serve almost
/// every backend in use.
abstract class TranscriptionProvider {
  /// Stable identifier, recorded with each transcript.
  String get id;

  /// Human-facing name for settings.
  String get displayName;

  Future<Transcript> transcribe(TranscriptionRequest request);

  void dispose() {}
}

/// Talks to any endpoint implementing OpenAI's `/v1/audio/transcriptions`.
///
/// That covers OpenAI Whisper, faster-whisper's server, whisper.cpp's server,
/// Groq, LocalAI and vLLM — so one adapter serves both the fully local and the
/// hosted case without the user having to care which shape they picked.
class OpenAiCompatibleTranscriptionProvider implements TranscriptionProvider {
  OpenAiCompatibleTranscriptionProvider({
    required this.baseUrl,
    this.model = 'whisper-1',
    this.apiKey,
    this.timeout = const Duration(minutes: 3),
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Endpoint root, e.g. `https://api.openai.com/v1` or `http://localhost:9000/v1`.
  final Uri baseUrl;
  final String model;
  final String? apiKey;
  final Duration timeout;

  final http.Client _http;
  final bool _ownsClient;

  @override
  String get id => 'openai-compatible';

  @override
  String get displayName => 'OpenAI-compatible (Whisper)';

  @override
  Future<Transcript> transcribe(TranscriptionRequest request) async {
    final uri = baseUrl.replace(
      path:
          '${baseUrl.path.replaceAll(RegExp(r'/$'), '')}/audio/transcriptions',
    );

    final multipart = http.MultipartRequest('POST', uri)
      ..fields['model'] = model
      // verbose_json carries the detected language, which the UI needs in
      // order to offer "re-transcribe in the right language".
      ..fields['response_format'] = 'verbose_json'
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          request.audio,
          filename: request.filename,
        ),
      );

    if (request.languageHint != null) {
      multipart.fields['language'] = request.languageHint!;
    }
    if (request.prompt != null) multipart.fields['prompt'] = request.prompt!;
    if (apiKey != null && apiKey!.isNotEmpty) {
      multipart.headers['authorization'] = 'Bearer $apiKey';
    }

    final http.Response response;
    try {
      final streamed = await _http.send(multipart).timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } on Exception catch (e) {
      throw TranscriptionException(
        'Could not reach the transcription endpoint: $e',
        retryable: true,
      );
    }

    if (response.statusCode != 200) {
      throw _describeFailure(response);
    }

    final body = utf8.decode(response.bodyBytes);
    final decoded = jsonDecode(body);

    // verbose_json gives an object; some servers only honour the plain `json`
    // or `text` formats, so all three are accepted.
    if (decoded is String) {
      return Transcript(text: decoded.trim(), provider: id);
    }
    if (decoded is! Map || decoded['text'] is! String) {
      throw const TranscriptionException(
        'The transcription endpoint returned an unexpected shape',
      );
    }

    return Transcript(
      text: (decoded['text'] as String).trim(),
      provider: id,
      language: decoded['language'] as String?,
      durationMs: decoded['duration'] is num
          ? ((decoded['duration'] as num) * 1000).round()
          : null,
    );
  }

  static TranscriptionException _describeFailure(http.Response response) {
    return switch (response.statusCode) {
      401 || 403 => const TranscriptionException(
        'The transcription endpoint rejected the API key.',
      ),
      404 => const TranscriptionException(
        'No transcription endpoint at that URL. The base URL usually ends in /v1.',
      ),
      413 => const TranscriptionException(
        'That voice message is too large for the endpoint.',
      ),
      429 => const TranscriptionException(
        'The transcription endpoint is rate limiting.',
        statusCode: 429,
        retryable: true,
      ),
      >= 500 => TranscriptionException(
        'The transcription endpoint failed (${response.statusCode}).',
        statusCode: response.statusCode,
        retryable: true,
      ),
      _ => TranscriptionException(
        'Transcription failed (${response.statusCode}).',
        statusCode: response.statusCode,
      ),
    };
  }

  @override
  void dispose() {
    if (_ownsClient) _http.close();
  }
}

/// Deepgram's `/v1/listen`, which takes a raw body rather than multipart.
class DeepgramTranscriptionProvider implements TranscriptionProvider {
  DeepgramTranscriptionProvider({
    required this.apiKey,
    Uri? baseUrl,
    this.model = 'nova-2',
    this.timeout = const Duration(minutes: 3),
    http.Client? httpClient,
  }) : baseUrl = baseUrl ?? Uri.parse('https://api.deepgram.com/v1/listen'),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final Uri baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;

  final http.Client _http;
  final bool _ownsClient;

  @override
  String get id => 'deepgram';

  @override
  String get displayName => 'Deepgram';

  @override
  Future<Transcript> transcribe(TranscriptionRequest request) async {
    final uri = baseUrl.replace(
      queryParameters: {
        'model': model,
        'smart_format': 'true',
        if (request.languageHint != null) 'language': request.languageHint!,
        if (request.languageHint == null) 'detect_language': 'true',
      },
    );

    final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {
              'authorization': 'Token $apiKey',
              'content-type': request.mimeType,
            },
            body: request.audio,
          )
          .timeout(timeout);
    } on Exception catch (e) {
      throw TranscriptionException(
        'Could not reach Deepgram: $e',
        retryable: true,
      );
    }

    if (response.statusCode != 200) {
      throw TranscriptionException(
        'Deepgram returned ${response.statusCode}.',
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500 || response.statusCode == 429,
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final alternative = _firstAlternative(decoded);
    if (alternative == null) {
      throw const TranscriptionException(
        'Deepgram returned no transcription for that audio',
      );
    }

    return Transcript(
      text: (alternative['transcript'] as String? ?? '').trim(),
      provider: id,
      language: _detectedLanguage(decoded),
      confidence: (alternative['confidence'] as num?)?.toDouble(),
    );
  }

  /// Digs `results.channels[0].alternatives[0]` out defensively — the response
  /// is deeply nested and a shape change should be an error message, not a
  /// cast exception.
  static Map<String, Object?>? _firstAlternative(Object? decoded) {
    if (decoded is! Map) return null;
    final results = decoded['results'];
    if (results is! Map) return null;
    final channels = results['channels'];
    if (channels is! List || channels.isEmpty) return null;
    final first = channels.first;
    if (first is! Map) return null;
    final alternatives = first['alternatives'];
    if (alternatives is! List || alternatives.isEmpty) return null;
    final alternative = alternatives.first;
    return alternative is Map ? alternative.cast<String, Object?>() : null;
  }

  static String? _detectedLanguage(Object? decoded) {
    if (decoded is! Map) return null;
    final results = decoded['results'];
    if (results is! Map) return null;
    final channels = results['channels'];
    if (channels is! List || channels.isEmpty) return null;
    final first = channels.first;
    return first is Map ? first['detected_language'] as String? : null;
  }

  @override
  void dispose() {
    if (_ownsClient) _http.close();
  }
}
