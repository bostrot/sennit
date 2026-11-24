import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/services/ai/conversation_context.dart';
import 'package:weft/services/ai/llm_budget.dart';
import 'package:weft/services/ai/llm_limits.dart';
import 'package:weft/services/ai/llm_request.dart';
import 'package:weft/services/ai/person_memory.dart' show kAiMemoryLocalChars;
import 'package:weft/services/ai/quick_messages.dart'
    show kQuickMessageContextMessages;

const _litellm = 'https://litellm.example.org/v1';
const _ollama = 'http://localhost:11434/v1';
const _openai = 'https://api.openai.com/v1';

/// What the owner's litellm answers on `/v1/model/info`, trimmed to the fields
/// that matter and one neighbour that must not be picked instead.
const _litellmInfo = {
  'data': [
    {
      'model_name': 'qwen3.8-flash-next-q2_0-nothink',
      'model_info': {'max_input_tokens': 1000, 'max_output_tokens': 10},
    },
    {
      'model_name': 'qwen3.8-flash-next-q2_0',
      'litellm_params': {'model': 'openai/qwen3.8-flash-next-q2_0'},
      'model_info': {
        'max_input_tokens': 172032,
        'max_output_tokens': 32768,
        'max_tokens': 16384,
        'input_cost_per_token': 0,
      },
    },
  ],
};

void main() {
  group('detection parsing', () {
    test('litellm /model/info: the window and the answer limit', () {
      expect(
        parseLitellmModelInfo(_litellmInfo, 'qwen3.8-flash-next-q2_0'),
        const LlmLimits(
          contextTokens: 172032,
          outputTokens: 32768,
          from: 'litellm',
        ),
      );
    });

    test('litellm without max_output_tokens falls back to max_tokens', () {
      final limits = parseLitellmModelInfo({
        'data': [
          {
            'model_name': 'llama',
            'model_info': {'max_input_tokens': 8192, 'max_tokens': 2048},
          },
        ],
      }, 'llama');
      expect(limits?.outputTokens, 2048);
    });

    test('litellm naming another model, or nothing, is null', () {
      expect(parseLitellmModelInfo(_litellmInfo, 'gpt-4o'), isNull);
      expect(parseLitellmModelInfo({'detail': 'Not Found'}, 'x'), isNull);
      expect(parseLitellmModelInfo('<html>', 'x'), isNull);
    });

    test('an OpenAI-style /models list with litellm\'s limits', () {
      expect(
        parseOpenAiModels({
          'data': [
            {
              'id': 'qwen3.8-flash-next-q2_0',
              'object': 'model',
              'max_input_tokens': 172032,
              'max_output_tokens': 32768,
            },
          ],
        }, 'qwen3.8-flash-next-q2_0'),
        const LlmLimits(
          contextTokens: 172032,
          outputTokens: 32768,
          from: 'openai',
        ),
      );
    });

    test('vLLM\'s max_model_len and OpenRouter\'s context_length', () {
      expect(
        parseOpenAiModels({
          'data': [
            {'id': 'Qwen/Qwen3-8B', 'max_model_len': 32768},
          ],
        }, 'qwen/qwen3-8b')?.contextTokens,
        32768,
      );
      final router = parseOpenAiModels({
        'data': [
          {
            'id': 'deepseek/deepseek-r1',
            'context_length': 163840,
            'top_provider': {'max_completion_tokens': 65536},
          },
        ],
      }, 'deepseek/deepseek-r1');
      expect(router?.contextTokens, 163840);
      expect(router?.outputTokens, 65536);
    });

    test('OpenAI\'s own list says nothing about limits', () {
      expect(
        parseOpenAiModels({
          'data': [
            {'id': 'gpt-4o', 'object': 'model', 'owned_by': 'openai'},
          ],
        }, 'gpt-4o'),
        isNull,
      );
    });

    test('Ollama: num_ctx when set, the trained length otherwise', () {
      const trained = {
        'model_info': {
          'general.architecture': 'qwen3',
          'qwen3.context_length': 40960,
        },
      };
      expect(parseOllamaShow(trained)?.contextTokens, 40960);
      expect(parseOllamaShow(trained)?.from, 'ollama');
      expect(
        parseOllamaShow({
          ...trained,
          'parameters': 'temperature 0.6\nnum_ctx 16384\ntop_p 0.95',
        })?.contextTokens,
        16384,
      );
      expect(parseOllamaShow({'error': 'model not found'}), isNull);
    });

    test('LM Studio: the loaded window before the most it could load', () {
      final limits = parseLmStudioModel({
        'id': 'qwen3-8b',
        'max_context_length': 131072,
        'loaded_context_length': 32768,
      });
      expect(limits?.contextTokens, 32768);
      expect(limits?.from, 'lmstudio');
    });
  });

  group('detectLlmLimits', () {
    test('asks litellm first, with the key, and reads it', () async {
      final asked = <String>[];
      final limits = await detectLlmLimits(
        baseUrl: _litellm,
        model: 'qwen3.8-flash-next-q2_0',
        apiKey: 'sk-test',
        client: MockClient((request) async {
          asked.add('${request.method} ${request.url.path}');
          expect(request.headers['Authorization'], 'Bearer sk-test');
          if (request.url.path == '/v1/model/info') {
            return http.Response(jsonEncode(_litellmInfo), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      expect(limits?.contextTokens, 172032);
      expect(limits?.outputTokens, 32768);
      expect(asked, ['GET /v1/model/info']);
    });

    test(
      'falls through to Ollama, read-only, and never sends a chat',
      () async {
        final asked = <String>[];
        final limits = await detectLlmLimits(
          baseUrl: _ollama,
          model: 'qwen3:8b',
          client: MockClient((request) async {
            asked.add('${request.method} ${request.url.path}');
            if (request.url.path == '/api/show') {
              expect(jsonDecode(request.body), {'model': 'qwen3:8b'});
              return http.Response(
                jsonEncode({
                  'model_info': {'qwen3.context_length': 40960},
                }),
                200,
              );
            }
            return http.Response('404 page not found', 404);
          }),
        );
        expect(limits, const LlmLimits(contextTokens: 40960, from: 'ollama'));
        expect(asked.where((a) => a.contains('chat/completions')), isEmpty);
        expect(asked.last, 'POST /api/show');
      },
    );

    test('a server that says nothing, or is down, is null', () async {
      expect(
        await detectLlmLimits(
          baseUrl: _openai,
          model: 'gpt-4o',
          client: MockClient((_) async => http.Response('{"data": []}', 200)),
        ),
        isNull,
      );
      expect(
        await detectLlmLimits(
          baseUrl: _ollama,
          model: 'x',
          client: MockClient((_) async => throw http.ClientException('down')),
        ),
        isNull,
      );
    });
  });

  group('LlmBudget', () {
    test('the owner\'s litellm: hundreds of messages to learn from', () {
      final budget = LlmBudget.resolve(
        _litellm,
        const LlmModelSettings(
          detectedContextTokens: 172032,
          detectedOutputTokens: 32768,
          detectedFrom: 'litellm',
        ),
      );
      expect(budget.contextTokens, 172032);
      expect(budget.contextDetected, isTrue);
      expect(budget.thinking, isTrue);
      expect(budget.answerTokens, kLlmLocalAnswerTokens);

      final learn = budget.forFeature(AiFeature.learnFacts);
      expect(learn.maxTokens, kLlmLocalAnswerTokens);
      expect(learn.maxMessages, greaterThanOrEqualTo(300));
      // Capped for time, not filled to the window.
      expect(learn.transcriptChars, 32000 * kLlmCharsPerToken);

      // The chips stay short and fast even here.
      final chips = budget.forFeature(AiFeature.smartReplies);
      expect(chips.maxTokens, lessThanOrEqualTo(1024));
      expect(chips.retryMaxTokens, chips.maxTokens);
      expect(chips.transcriptChars, lessThanOrEqualTo(1000 * 3));

      expect(budget.memoryChars, greaterThan(kAiMemoryLocalChars));
    });

    test('nothing detected: an 8k guess, with half of it for the answer', () {
      final budget = LlmBudget.resolve(_ollama);
      expect(budget.contextTokens, kLlmFallbackContextTokens);
      expect(budget.contextDetected, isFalse);
      for (final feature in AiFeature.values) {
        final room = budget.forFeature(feature);
        // Prompt and answer fit in the window together.
        expect(
          room.retryMaxTokens +
              room.transcriptChars ~/ kLlmCharsPerToken +
              kLlmPromptOverheadTokens,
          lessThanOrEqualTo(kLlmFallbackContextTokens + 400),
          reason: '$feature',
        );
      }
      expect(
        budget.forFeature(AiFeature.learnFacts).maxTokens,
        kLlmFallbackContextTokens ~/ 2,
      );
    });

    test('a hosted API asks for short answers and retries with room', () {
      final budget = LlmBudget.resolve(_openai);
      expect(budget.thinking, isFalse);
      final quick = budget.forFeature(AiFeature.quickMessage);
      expect(
        quick.maxTokens,
        LlmBudget.naturalAnswerTokens(AiFeature.quickMessage),
      );
      expect(quick.retryMaxTokens, greaterThan(quick.maxTokens));
      expect(budget.forFeature(AiFeature.eventTitle).maxTokens, 60);
      expect(budget.memoryChars, greaterThanOrEqualTo(1200));
    });

    test('the user\'s numbers win, and a detected limit caps the default', () {
      final typed = LlmBudget.resolve(
        _ollama,
        const LlmModelSettings(
          contextTokens: 32768,
          answerTokens: 2000,
          thinking: false,
          detectedContextTokens: 4096,
          detectedOutputTokens: 1000,
        ),
      );
      expect(typed.contextTokens, 32768);
      expect(typed.answerTokens, 2000);
      expect(typed.thinking, isFalse);
      expect(typed.contextDetected, isFalse);

      final capped = LlmBudget.resolve(
        _ollama,
        const LlmModelSettings(detectedOutputTokens: 1000),
      );
      expect(capped.answerTokens, 1000);
    });

    test('the quick message window matches what its settings screen says', () {
      expect(
        LlmBudget.resolve(
          _ollama,
          const LlmModelSettings(contextTokens: 200000),
        ).forFeature(AiFeature.quickMessage).maxMessages,
        kQuickMessageContextMessages,
      );
    });

    test('settings survive a round trip, and junk reads as nothing', () {
      const settings = LlmModelSettings(
        contextTokens: 200000,
        thinking: true,
        detectedOutputTokens: 32768,
        detectedFrom: 'litellm',
      );
      expect(LlmModelSettings.fromJson(settings.toJson()), settings);
      expect(
        LlmModelSettings.fromJson({'context': -1, 'thinking': 'yes'}),
        LlmModelSettings.none,
      );
      expect(
        LlmModelSettings.keyFor('http://x/v1/', ' m '),
        LlmModelSettings.keyFor('http://x/v1', 'm'),
      );
    });
  });

  group('requestCompletion', () {
    http.Client answering(
      List<({String? content, String finish})> answers,
      List<int> asked,
    ) {
      var i = 0;
      return MockClient((request) async {
        asked.add((jsonDecode(request.body) as Map)['max_tokens'] as int);
        final a = answers[i++ % answers.length];
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': a.content},
                'finish_reason': a.finish,
              },
            ],
          }),
          200,
        );
      });
    }

    Future<LlmAnswer> ask(http.Client client, {int retry = 4096}) =>
        requestCompletion(
          client,
          Uri.parse('$_ollama/chat/completions'),
          headers: const {},
          body: const {'model': 'm', 'messages': []},
          maxTokens: 512,
          retryMaxTokens: retry,
          answered: (content) => content.contains('DONE'),
          timeout: const Duration(seconds: 1),
        );

    test('cut off before an answer: asked once more, with more room', () async {
      final asked = <int>[];
      final answer = await ask(
        answering([
          (content: '<think>hmm', finish: 'length'),
          (content: 'DONE', finish: 'stop'),
        ], asked),
      );
      expect(asked, [512, 4096]);
      expect(answer.content, 'DONE');
      expect(answer.cutOff, isFalse);
    });

    test('cut off twice: the second answer, marked cut off', () async {
      final asked = <int>[];
      final answer = await ask(
        answering([(content: null, finish: 'length')], asked),
      );
      expect(asked, [512, 4096]);
      expect(answer.cutOff, isTrue);
    });

    test('an answer that is there is not asked for again', () async {
      final asked = <int>[];
      await ask(answering([(content: 'DONE, and', finish: 'length')], asked));
      expect(asked, [512]);
    });

    test('no more room to give: no second request', () async {
      final asked = <int>[];
      final answer = await ask(
        answering([(content: null, finish: 'length')], asked),
        retry: 512,
      );
      expect(asked, [512]);
      expect(answer.cutOff, isTrue);
    });
  });

  test('fitTranscript drops the oldest lines and keeps the newest', () {
    final lines = ['Anna: ${'a' * 50}', 'You: ${'b' * 50}', 'Anna: ok?'];
    expect(fitTranscript(lines, 1000), lines);
    expect(fitTranscript(lines, 70), ['You: ${'b' * 50}', 'Anna: ok?']);
    expect(fitTranscript(lines, 1), ['Anna: ok?']);
  });
}
