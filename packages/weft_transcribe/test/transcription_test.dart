import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weft_transcribe/weft_transcribe.dart';

void main() {
  final request = TranscriptionRequest(
    audio: Uint8List.fromList(List.filled(64, 7)),
    filename: 'voice.ogg',
  );

  group('OpenAI-compatible provider', () {
    test('posts multipart audio and parses verbose_json', () async {
      late http.BaseRequest captured;
      final client = MockClient((r) async {
        captured = r;
        return http.Response(
          jsonEncode({
            'text': ' are we still on for Thursday ',
            'language': 'english',
            'duration': 8.4,
          }),
          200,
        );
      });

      final provider = OpenAiCompatibleTranscriptionProvider(
        baseUrl: Uri.parse('http://localhost:9000/v1'),
        apiKey: 'secret',
        httpClient: client,
      );

      final transcript = await provider.transcribe(request);

      expect(captured.url.path, '/v1/audio/transcriptions');
      expect(captured.headers['authorization'], 'Bearer secret');
      expect(transcript.text, 'are we still on for Thursday');
      expect(transcript.language, 'english');
      expect(transcript.durationMs, 8400);
      expect(transcript.provider, 'openai-compatible');
    });

    test('tolerates a base URL with a trailing slash', () async {
      late Uri url;
      final client = MockClient((r) async {
        url = r.url;
        return http.Response(jsonEncode({'text': 'ok'}), 200);
      });

      await OpenAiCompatibleTranscriptionProvider(
        baseUrl: Uri.parse('http://localhost:9000/v1/'),
        httpClient: client,
      ).transcribe(request);

      expect(url.path, '/v1/audio/transcriptions');
    });

    test('passes a language hint when given, and omits it otherwise', () async {
      var body = '';
      final client = MockClient((r) async {
        body = await _bodyOf(r);
        return http.Response(jsonEncode({'text': 'ok'}), 200);
      });

      final provider = OpenAiCompatibleTranscriptionProvider(
        baseUrl: Uri.parse('http://localhost:9000/v1'),
        httpClient: client,
      );

      await provider.transcribe(request);
      expect(
        body,
        isNot(contains('name="language"')),
        reason: 'no hint should mean auto-detect',
      );

      await provider.transcribe(
        TranscriptionRequest(
          audio: request.audio,
          filename: request.filename,
          languageHint: 'de',
        ),
      );
      expect(body, contains('name="language"'));
    });

    test('accepts a plain-text response from a simpler server', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode('just the words'), 200),
      );

      final transcript = await OpenAiCompatibleTranscriptionProvider(
        baseUrl: Uri.parse('http://localhost:9000/v1'),
        httpClient: client,
      ).transcribe(request);

      expect(transcript.text, 'just the words');
    });

    group('failures', () {
      Future<TranscriptionException> failWith(int status) async {
        final client = MockClient((_) async => http.Response('nope', status));
        try {
          await OpenAiCompatibleTranscriptionProvider(
            baseUrl: Uri.parse('http://localhost:9000/v1'),
            httpClient: client,
          ).transcribe(request);
          fail('expected a TranscriptionException for $status');
        } on TranscriptionException catch (e) {
          return e;
        }
      }

      test('a rejected key is not retryable', () async {
        final error = await failWith(401);
        expect(
          error.retryable,
          isFalse,
          reason: 'retrying a bad key just burns quota',
        );
        expect(error.message, contains('API key'));
      });

      test('a wrong URL says so plainly', () async {
        expect((await failWith(404)).message, contains('base URL'));
      });

      test('rate limits and server errors are retryable', () async {
        expect((await failWith(429)).retryable, isTrue);
        expect((await failWith(503)).retryable, isTrue);
      });

      test('an unreachable endpoint is retryable', () async {
        final client = MockClient((_) async => throw const _NetworkDown());
        try {
          await OpenAiCompatibleTranscriptionProvider(
            baseUrl: Uri.parse('http://localhost:9000/v1'),
            httpClient: client,
          ).transcribe(request);
          fail('expected a TranscriptionException');
        } on TranscriptionException catch (e) {
          expect(e.retryable, isTrue);
        }
      });

      test('a malformed body is reported, not cast-crashed', () async {
        final client = MockClient(
          (_) async => http.Response(jsonEncode({'nope': 1}), 200),
        );
        expect(
          () => OpenAiCompatibleTranscriptionProvider(
            baseUrl: Uri.parse('http://localhost:9000/v1'),
            httpClient: client,
          ).transcribe(request),
          throwsA(isA<TranscriptionException>()),
        );
      });
    });
  });

  group('Deepgram provider', () {
    test('posts a raw body and reads the nested transcript', () async {
      late http.BaseRequest captured;
      final client = MockClient((r) async {
        captured = r;
        return http.Response(
          jsonEncode({
            'results': {
              'channels': [
                {
                  'detected_language': 'de',
                  'alternatives': [
                    {'transcript': 'bis Donnerstag', 'confidence': 0.97},
                  ],
                },
              ],
            },
          }),
          200,
        );
      });

      final transcript = await DeepgramTranscriptionProvider(
        apiKey: 'dg-key',
        httpClient: client,
      ).transcribe(request);

      expect(captured.headers['authorization'], 'Token dg-key');
      expect(captured.url.queryParameters['detect_language'], 'true');
      expect(transcript.text, 'bis Donnerstag');
      expect(transcript.language, 'de');
      expect(transcript.confidence, closeTo(0.97, 1e-9));
    });

    test('reports a shape change instead of crashing', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'results': {}}), 200),
      );

      expect(
        () => DeepgramTranscriptionProvider(
          apiKey: 'k',
          httpClient: client,
        ).transcribe(request),
        throwsA(isA<TranscriptionException>()),
      );
    });
  });

  group('TranscriptionSettings', () {
    test('is unusable until enabled and configured', () {
      const off = TranscriptionSettings();
      expect(off.isUsable, isFalse, reason: 'must be off by default');

      const enabledWithoutUrl = TranscriptionSettings(enabled: true);
      expect(enabledWithoutUrl.isUsable, isFalse);

      const configured = TranscriptionSettings(
        enabled: true,
        baseUrl: 'http://localhost:9000/v1',
      );
      expect(configured.isUsable, isTrue);
    });

    test('excluded networks are never sent, even when enabled', () {
      const settings = TranscriptionSettings(
        enabled: true,
        baseUrl: 'http://localhost:9000/v1',
        excludedNetworks: {'signal'},
      );

      expect(settings.allows('whatsapp'), isTrue);
      expect(settings.allows('signal'), isFalse);
    });

    test('builds the right provider, or none', () {
      expect(buildTranscriptionProvider(const TranscriptionSettings()), isNull);

      final openAi = buildTranscriptionProvider(
        const TranscriptionSettings(
          enabled: true,
          baseUrl: 'http://localhost:9000/v1',
        ),
      );
      expect(openAi, isA<OpenAiCompatibleTranscriptionProvider>());

      final deepgram = buildTranscriptionProvider(
        const TranscriptionSettings(
          enabled: true,
          backend: TranscriptionBackend.deepgram,
        ),
        apiKey: 'dg',
      );
      expect(deepgram, isA<DeepgramTranscriptionProvider>());

      // Deepgram without a key cannot work, so it must not be built.
      expect(
        buildTranscriptionProvider(
          const TranscriptionSettings(
            enabled: true,
            backend: TranscriptionBackend.deepgram,
          ),
        ),
        isNull,
      );
    });

    test('rejects a base URL that is not a URL', () {
      const settings = TranscriptionSettings(
        enabled: true,
        baseUrl: 'not a url',
      );
      expect(settings.isUsable, isFalse);
    });
  });
}

/// Reads a multipart body back out for assertions.
///
/// MockClient finalises the request before handing it to the handler, so what
/// arrives is a plain [http.Request] carrying the encoded multipart bytes —
/// not the [http.MultipartRequest] that was sent.
Future<String> _bodyOf(http.BaseRequest request) async {
  if (request is http.Request) {
    return utf8.decode(request.bodyBytes, allowMalformed: true);
  }
  return '';
}

class _NetworkDown implements Exception {
  const _NetworkDown();
}
