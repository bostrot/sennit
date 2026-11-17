import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/design_strings.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/app/settings.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import '../../test/support/load_repository.dart';

/// Frame timings for the two screens people live in, at a heavy account's size.
///
///   cd apps/weft
///   flutter drive --profile -d macos \
///     --driver test_driver/perf_driver.dart \
///     --target integration_test/perf/perf_test.dart \
///     --dart-define=WEFT_DEMO=true --dart-define=PERF_SURFACE=touch \
///     --dart-define=PERF_ONLY=chat
///
/// `PERF_SURFACE` is `touch` (the phone shell, in a 412×915 window) or `mac`
/// (the three-pane window). Profile mode, because a debug build's frame times
/// say more about the JIT than about the app.
///
/// Each scenario prints one `PERF {…}` line of JSON: the frame count, build
/// and raster percentiles in milliseconds, and how many frames missed a 60Hz
/// budget. The inbox is re-emitted every 300ms throughout, which is what a
/// syncing account does to this tree — a scroll measured on a silent
/// repository is a scroll nobody has.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  const surfaceName = String.fromEnvironment(
    'PERF_SURFACE',
    defaultValue: 'touch',
  );
  final mac = surfaceName == 'mac';

  // Which act to run: `inbox`, `chat` (a freshly opened conversation),
  // `deep` (the same conversation with a long way of history already loaded)
  // or `switch` (moving between conversations quickly, on timelines that are
  // kept between visits as the Matrix repository keeps them).
  //
  // One per launch, and each kept under twenty seconds, for a reason that has
  // nothing to do with Braid: a Mac whose display is asleep or locked puts a
  // window nobody can see into App Nap about half a minute after launch, and
  // from then on the frame rate and every build time are the throttle's
  // numbers, not the app's. `fps` on an idle scenario is the tell — it should
  // be the display's refresh rate.
  // Whether each sync changes a conversation (a message arrived somewhere) or
  // none (a receipt, a typing notice): `PERF_QUIET_SYNC=true` for the second,
  // which is most syncs and should cost a frame nothing at all.
  const tickChanges = !bool.fromEnvironment('PERF_QUIET_SYNC');

  const only = String.fromEnvironment('PERF_ONLY', defaultValue: 'inbox');
  final runInbox = only == 'inbox';
  final runChat = only == 'chat';
  final runDeep = only == 'deep';
  final runSwitch = only == 'switch';

  testWidgets('perf — $surfaceName/$only', (tester) async {
    expect(kDemoMode, isTrue, reason: 'Run with --dart-define=WEFT_DEMO=true');
    await initializeDateFormatting();

    await binding.setSurfaceSize(
      mac ? const Size(1400, 900) : const Size(412, 915),
    );
    addTearDown(() => binding.setSurfaceSize(null));

    final repository = LoadChatRepository(
      preloaded: runDeep ? 1500 : 0,
      cachesTimelines: runSwitch,
    );
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(repository),
        catchingUpProvider.overrideWith((ref) => Stream.value(false)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(storesBootstrapProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: const WeftAppearance().themeFor(
            Brightness.light,
            surface: mac ? WeftSurface.mac : WeftSurface.touch,
            pointer: mac,
          ),
          builder: (context, child) => WeftDesignStringsScope(
            strings: weftDesignStringsFrom(context.l10n),
            child: child ?? const SizedBox.shrink(),
          ),
          home: const InboxShell(),
        ),
      ),
    );
    await _run(tester, const Duration(seconds: 1));
    expect(find.byType(ChatTile), findsWidgets);

    final results = <String, Map<String, Object>>{};
    Future<void> measure(String name, Future<void> Function() body) async {
      results[name] = await _measure(body);
      // ignore: avoid_print
      print(
        'PERF ${jsonEncode({'scenario': '$surfaceName/$name', ...results[name]!})}',
      );
    }

    // The sync heartbeat, for the whole run.
    final heartbeat = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => repository.tick(changeOne: tickChanges),
    );
    addTearDown(heartbeat.cancel);

    final inboxList = find.byType(Scrollable).first;

    if (runInbox) {
      // The inbox doing nothing but receiving syncs.
      await measure(
        'inbox_idle_sync',
        () => _run(tester, const Duration(seconds: 4)),
      );

      // Scrolling the inbox while it syncs.
      await measure('inbox_scroll', () async {
        for (var i = 0; i < 5; i++) {
          await tester.fling(inboxList, const Offset(0, -500), 4000);
          await _run(tester, const Duration(milliseconds: 1000));
        }
        for (var i = 0; i < 3; i++) {
          await tester.fling(inboxList, const Offset(0, 500), 4000);
          await _run(tester, const Duration(milliseconds: 1000));
        }
      });
    }

    if (runChat || runDeep) {
      final prefix = runDeep ? 'deep' : 'chat';

      // Opening the busy group.
      await measure('${prefix}_open', () async {
        await tester.tap(find.text('Load test group').first);
        await _run(tester, const Duration(milliseconds: 1500));
      });
      expect(find.byType(ChatView), findsOneWidget);

      final thread = find
          .descendant(
            of: find.byType(ChatView),
            matching: find.byType(Scrollable),
          )
          .first;

      // The open conversation doing nothing but receiving syncs.
      await measure(
        '${prefix}_idle_sync',
        () => _run(tester, const Duration(seconds: 4)),
      );

      // Scrolling back through history while it syncs — and, in a freshly
      // opened conversation, backfills.
      await measure('${prefix}_scroll_back', () async {
        for (var i = 0; i < 8; i++) {
          await tester.fling(thread, const Offset(0, 500), 5000);
          await _run(tester, const Duration(milliseconds: 900));
        }
      });

      // Typing into the composer.
      final composer = find.descendant(
        of: find.byType(ChatView),
        matching: find.byType(EditableText),
      );
      if (composer.evaluate().isNotEmpty) {
        await tester.tap(composer.first);
        await _run(tester, const Duration(milliseconds: 300));
        await measure('${prefix}_typing', () async {
          const text = 'The quick brown fox jumps over the lazy dog';
          for (var i = 1; i <= text.length; i++) {
            tester.testTextInput.updateEditingValue(
              TextEditingValue(
                text: text.substring(0, i),
                selection: TextSelection.collapsed(offset: i),
              ),
            );
            await _run(tester, const Duration(milliseconds: 50));
          }
        });
      }
    }

    if (runSwitch) {
      // Driven through the app's own doors rather than by tapping rows: which
      // rows are on screen depends on the window, and the cost being measured
      // is the conversation's, not the tap's. Two panes select; one pane
      // pushes a screen and goes back from it.
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      const group = LoadChatRepository.groupChatId;
      final rows = [for (var i = 1; i <= 6; i++) '!load_$i:example.org'];
      Future<void> open(String chatId) async {
        if (mac) {
          container.read(selectedChatProvider.notifier).select(chatId);
          await _run(tester, const Duration(milliseconds: 150));
        } else {
          unawaited(pushChat(navigator, chatId));
          await _run(tester, const Duration(milliseconds: 350));
          navigator.pop();
          await _run(tester, const Duration(milliseconds: 250));
        }
      }

      // Back and forth between the busy group and one other conversation.
      await measure('switch_back_and_forth', () async {
        for (var i = 0; i < (mac ? 6 : 4); i++) {
          await open(group);
          await open(rows.first);
        }
      });

      // Down the inbox one conversation after another.
      await measure('switch_click_through', () async {
        // One round on a phone, where each visit is a push and a pop: two
        // would run the act past the point a hidden window is napped.
        for (var round = 0; round < (mac ? 2 : 1); round++) {
          for (final row in [group, ...rows]) {
            await open(row);
          }
        }
        await _run(tester, const Duration(milliseconds: 500));
      });
      // ignore: avoid_print
      print(
        'PERF ${jsonEncode({'scenario': '$surfaceName/switch_counts', 'pages': repository.pages, 'indexed': repository.indexed, 'indexed_wrong_chat': repository.indexedUnderWrongChat, 'group_loaded': repository.loadedIn(LoadChatRepository.groupChatId)})}',
      );
    }

    heartbeat.cancel();
    binding.reportData = results;
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Lets real frames run for [duration].
Future<void> _run(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Runs [body] and summarises the frames the engine reported for it.
///
/// Two clocks, because a frame timing only covers a frame. `build_*` and
/// `raster_*` are the engine's own; `lag_*` is how late a 4ms timer on the UI
/// isolate fired, which is what catches work done *between* frames — a
/// listener, a timer, a completed future — that holds the thread just as
/// surely and appears in no build time at all.
Future<Map<String, Object>> _measure(Future<void> Function() body) async {
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);

  const period = Duration(milliseconds: 4);
  final lags = <double>[];
  final beat = Stopwatch()..start();
  var last = beat.elapsedMicroseconds;
  final lagTimer = Timer.periodic(period, (_) {
    final now = beat.elapsedMicroseconds;
    lags.add((now - last - period.inMicroseconds) / 1000);
    last = now;
  });

  final clock = Stopwatch()..start();
  await body();
  clock.stop();
  lagTimer.cancel();
  // Timings are delivered in batches, up to a second late in profile mode.
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  SchedulerBinding.instance.removeTimingsCallback(collect);

  double ms(Duration d) => d.inMicroseconds / 1000;
  final build = [for (final t in timings) ms(t.buildDuration)]..sort();
  final raster = [for (final t in timings) ms(t.rasterDuration)]..sort();
  lags.sort();
  double pct(List<double> sorted, double p) =>
      sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];
  double round(double v) => (v * 100).round() / 100;
  double mean(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  return {
    'frames': timings.length,
    'wall_ms': clock.elapsedMilliseconds,
    'fps': round(timings.length * 1000 / clock.elapsedMilliseconds),
    'build_avg': round(mean(build)),
    'build_p50': round(pct(build, 0.5)),
    'build_p90': round(pct(build, 0.9)),
    'build_p99': round(pct(build, 0.99)),
    'build_max': round(build.isEmpty ? 0 : build.last),
    'build_total': round(build.fold(0, (a, b) => a + b)),
    'build_over_8ms': build.where((v) => v > 8.33).length,
    'build_over_16ms': build.where((v) => v > 16.67).length,
    'raster_avg': round(mean(raster)),
    'raster_p90': round(pct(raster, 0.9)),
    'raster_p99': round(pct(raster, 0.99)),
    'raster_max': round(raster.isEmpty ? 0 : raster.last),
    'raster_over_16ms': raster.where((v) => v > 16.67).length,
    'lag_p90': round(pct(lags, 0.9)),
    'lag_p99': round(pct(lags, 0.99)),
    'lag_max': round(lags.isEmpty ? 0 : lags.last),
    'lag_over_16ms': lags.where((v) => v > 16.67).length,
    // Everything the UI isolate was late by, summed: the thread's busy time.
    'busy_ms': round(lags.where((v) => v > 1).fold(0, (a, b) => a + b)),
  };
}
