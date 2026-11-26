import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:weft/services/ai/on_device/on_device_llm.dart';
import 'package:weft/services/ai/on_device/on_device_models.dart';
import 'package:weft/services/ai/on_device/qwen_chat_template.dart';

/// The real on-device model in the real app: llama.cpp loads a GGUF from
/// [_model], writes three short replies, and the speeds are printed.
///
///   cd apps/weft
///   flutter test integration_test/perf/on_device_llm_test.dart -d DEVICE \
///     --dart-define=ON_DEVICE_MODEL=/path/to/Bonsai-8B-Q1_0.gguf \
///     --dart-define=ON_DEVICE_ID=bonsai-8b-q1
///
/// On a simulator the path can be one on the Mac; on an Android device, put
/// the file under `/sdcard/Android/data/com.bostrot.weft/files/`. Skipped
/// without a model, so it costs nothing where there is none.
const String _model = String.fromEnvironment('ON_DEVICE_MODEL');
const String _id = String.fromEnvironment(
  'ON_DEVICE_ID',
  defaultValue: 'bonsai-8b-q1',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('writes replies on this device', (tester) async {
    final llm = OnDeviceLlm(modelPath: (_) async => _model);
    final spec = OnDeviceLlmSpec.byId(_id)!;
    final convo = List.generate(
      12,
      (i) => i.isEven
          ? 'Anna: Hast du gehört, dass das Konzert am Samstag verschoben '
                'wurde? Ich weiß nicht, ob ich dann noch kann.'
          : 'Me: Oh nein, echt? Auf wann denn? Ich hätte nur am Samstag Zeit '
                'gehabt.',
    ).join('\n');
    final messages = [
      const ChatTurn(
        'system',
        'You write short chat replies the user could send. Output ONLY a '
            'JSON object with a "replies" list of one or two strings.',
      ),
      ChatTurn(
        'user',
        'Conversation (newest message last):\n$convo\n'
            'Anna: Kommst du morgen mit ins Kino?\n\nJSON:',
      ),
    ];
    for (var run = 0; run < 3; run++) {
      final pieces = <String>[];
      final answer = await llm.complete(
        modelId: spec.id,
        messages: messages,
        maxTokens: 96,
        onText: pieces.add,
      );
      // ignore: avoid_print
      print(
        'ON_DEVICE ${spec.id} run=$run context=${llm.contextTokensFor(spec)} '
        'load=${answer.loadTime.inMilliseconds}ms '
        'prompt=${answer.promptTokens} '
        'first=${answer.firstTokenTime.inMilliseconds}ms '
        '(${answer.promptTokensPerSecond.toStringAsFixed(1)} tok/s) '
        'tokens=${answer.completionTokens} '
        'decode=${answer.tokensPerSecond.toStringAsFixed(1)} tok/s '
        'pieces=${pieces.length} text=${answer.text.replaceAll('\n', ' ')}',
      );
      expect(answer.text, isNotEmpty);
      expect(pieces.join().trim(), answer.text);
    }
    await llm.unload();
  }, skip: _model.isEmpty);
}
