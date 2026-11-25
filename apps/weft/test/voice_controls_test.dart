import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/chat/voice_recording_bar.dart';
import 'package:weft/services/audio/voice_player.dart';
import 'package:weft/services/audio/voice_recorder.dart';
import 'package:weft_design/weft_design.dart';

/// Pausing a voice note mid-recording, and playing voice notes faster.
void main() {
  group('recording bar', () {
    late _FakeRecorder recorder;

    setUp(() => recorder = _FakeRecorder());
    tearDown(() => recorder.close());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(brightness: Brightness.light),
          home: Scaffold(
            body: VoiceRecordingBar(
              recorder: recorder,
              onCancel: () {},
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('pause holds the take and resume carries on', (tester) async {
      await pump(tester);
      expect(find.byTooltip('Pause recording'), findsOneWidget);

      await tester.tap(find.byTooltip('Pause recording'));
      await tester.pump();
      expect(recorder.paused, isTrue);
      expect(find.byTooltip('Resume recording'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('^Recording paused, ')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Resume recording'));
      await tester.pump();
      expect(recorder.paused, isFalse);
      expect(
        find.bySemanticsLabel(RegExp('^Recording voice message, ')),
        findsOneWidget,
      );

      // The bar is torn down mid-take; nothing is kept.
      await tester.pumpWidget(const SizedBox());
      expect(recorder.cancelled, isTrue);
    });

    testWidgets('a paused take still sends', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Pause recording'));
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(recorder.stopped, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('playback speed', () {
    test('steps 1× → 1.5× → 2× → 1×', () {
      expect(VoicePlayback.nextSpeed(1), 1.5);
      expect(VoicePlayback.nextSpeed(1.5), 2);
      expect(VoicePlayback.nextSpeed(2), 1);
    });

    test('belongs to the listener, not to one note', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final player = container.read(voicePlayerProvider.notifier);

      expect(container.read(voicePlayerProvider).speed, 1);
      await player.cycleSpeed();
      expect(container.read(voicePlayerProvider).speed, 1.5);
      // Every state change keeps it unless it is the speed being changed.
      expect(
        container.read(voicePlayerProvider).copyWith(playing: true).speed,
        1.5,
      );
      expect(VoicePlayback.idle(speed: 2).speed, 2);
    });

    testWidgets('reads as a number in the reader\'s language', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(captured.l10n.chatVoiceSpeedValue(1.5), '1,5×');
      expect(captured.l10n.chatVoiceSpeedValue(2), '2×');
    });
  });
}

class _FakeRecorder implements VoiceRecorder {
  final _levels = StreamController<Amplitude>.broadcast();
  final _clock = Stopwatch();
  bool _paused = false;
  bool cancelled = false;
  bool stopped = false;

  void close() => _levels.close();

  @override
  Stream<Amplitude> get amplitude => _levels.stream;

  @override
  Duration get elapsed => _clock.elapsed;

  @override
  bool get paused => _paused;

  @override
  Future<bool> start() async {
    _clock.start();
    return true;
  }

  @override
  Future<void> pause() async => _paused = true;

  @override
  Future<void> resume() async => _paused = false;

  @override
  Future<VoiceRecording?> stop() async {
    stopped = true;
    return null;
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async {}
}
