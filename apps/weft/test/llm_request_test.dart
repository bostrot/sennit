import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:weft/services/ai/auto_reply_writer.dart';
import 'package:weft/services/ai/event_title.dart';
import 'package:weft/services/ai/llm_request.dart';
import 'package:weft/services/ai/quick_messages.dart';

/// How long an AI request may take, and that it really stops when it is
/// given up on.
///
/// The slow-server tests run against a real socket on loopback, not a
/// `MockClient`: what is under test is that the connection is closed, which a
/// mock has no connection to show.
void main() {
  group('isHostedLlm', () {
    final cases = {
      'https://api.openai.com/v1': true,
      'https://API.OpenAI.com/v1/': true,
      'https://my-team.openai.azure.com/openai/v1': true,
      'https://openrouter.ai/api/v1': true,
      'https://api.groq.com/openai/v1': true,
      'https://generativelanguage.googleapis.com/v1beta/openai': true,
      'http://localhost:11434/v1': false,
      'http://127.0.0.1:1234/v1': false,
      'http://192.168.1.20:8080/v1': false,
      'http://ollama.local:11434/v1': false,
      'https://llm.example.org/v1': false,
      // A lookalike is somebody's own server, not OpenAI's.
      'https://api.openai.com.example.org/v1': false,
      'https://notapi.openai.com.evil/v1': false,
      '': false,
      'not a url': false,
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      test('"$key" → $value', () => expect(isHostedLlm(key), value));
    }
  });

  group('llmResponseTimeout', () {
    const hosted = 'https://api.openai.com/v1';
    const local = 'http://localhost:11434/v1';

    test('a hosted API keeps the limits each feature always had', () {
      expect(
        llmResponseTimeout(hosted, LlmTask.quickMessage),
        const Duration(seconds: 60),
      );
      expect(
        llmResponseTimeout(hosted, LlmTask.autoReply),
        const Duration(seconds: 60),
      );
      expect(
        llmResponseTimeout(hosted, LlmTask.todo),
        const Duration(seconds: 20),
      );
      expect(
        llmResponseTimeout(hosted, LlmTask.eventTitle),
        const Duration(seconds: 8),
      );
      expect(
        llmResponseTimeout(hosted, LlmTask.probe),
        const Duration(seconds: 12),
      );
    });

    test('a self-hosted model is given minutes', () {
      expect(
        llmResponseTimeout(local, LlmTask.quickMessage),
        const Duration(minutes: 10),
      );
      expect(
        llmResponseTimeout(local, LlmTask.autoReply),
        const Duration(minutes: 10),
      );
      expect(
        llmResponseTimeout(local, LlmTask.todo),
        const Duration(minutes: 10),
      );
      expect(
        llmResponseTimeout(local, LlmTask.eventTitle),
        const Duration(minutes: 2),
      );
      expect(
        llmResponseTimeout(local, LlmTask.probe),
        const Duration(minutes: 3),
      );
    });

    test(
      'every task waits longer on a self-hosted model than a hosted one',
      () {
        for (final task in LlmTask.values) {
          expect(
            llmResponseTimeout(local, task),
            greaterThan(llmResponseTimeout(hosted, task)),
            reason: '$task',
          );
        }
      },
    );
  });

  group('against a slow server', () {
    late ServerSocket server;
    late Duration delay;

    /// Completes when the client hangs up before the server answered.
    late Completer<void> hungUp;

    // A raw socket rather than an `HttpServer`, because the client closing
    // the connection is what is being looked for, and a socket says so
    // plainly.
    setUp(() async {
      hungUp = Completer<void>();
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        var answered = false;
        socket.listen(
          (_) {},
          onDone: () {
            if (!answered && !hungUp.isCompleted) hungUp.complete();
          },
          onError: (Object _) {
            if (!answered && !hungUp.isCompleted) hungUp.complete();
          },
        );
        Future<void>.delayed(delay, () {
          if (hungUp.isCompleted) return;
          answered = true;
          final body = utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"title": "Dinner with Sam"}'},
                  'finish_reason': 'stop',
                },
              ],
            }),
          );
          socket
            ..write(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/json; charset=utf-8\r\n'
              'Content-Length: ${body.length}\r\n'
              'Connection: close\r\n\r\n',
            )
            ..add(body);
          unawaited(socket.close());
        });
      });
    });

    tearDown(() => server.close());

    String baseUrl() => 'http://127.0.0.1:${server.port}/v1';

    test(
      'a self-hosted model answering after the old eight seconds is waited for',
      () async {
        // The event title gave up after eight seconds for every endpoint.
        delay = const Duration(seconds: 9);
        final title = await suggestEventTitle(
          baseUrl: baseUrl(),
          model: 'slow',
          transcript: const ['Sam: friday at 7?'],
        );
        expect(title, 'Dinner with Sam');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('cancelling aborts the request, not only the wait', () async {
      delay = const Duration(minutes: 5);
      final cancel = Completer<void>();
      final started = Stopwatch()..start();
      final draft = composeQuickMessage(
        baseUrl: baseUrl(),
        model: 'slow',
        instruction: 'Write a birthday wish.',
        transcript: const ['Anna: Bis Samstag!'],
        language: 'de',
        cancel: cancel.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancel.complete();
      expect((await draft).text, isNull);
      expect(started.elapsed, lessThan(const Duration(seconds: 5)));
      await hungUp.future.timeout(const Duration(seconds: 5));
    });

    test('a timeout aborts the request too', () async {
      delay = const Duration(minutes: 5);
      final draft = await composeQuickMessage(
        baseUrl: baseUrl(),
        model: 'slow',
        instruction: 'Write a birthday wish.',
        transcript: const ['Anna: Bis Samstag!'],
        language: 'de',
        timeout: const Duration(milliseconds: 300),
      );
      expect(draft.outcome, AutoReplyOutcome.timedOut);
      await hungUp.future.timeout(const Duration(seconds: 5));
    });
  });
}
