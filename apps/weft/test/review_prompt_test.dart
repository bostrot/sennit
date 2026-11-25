import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/services/review/review_prompt.dart';

void main() {
  final now = DateTime(2026, 11, 25, 12);

  ReviewCounters happy({
    Duration installed = const Duration(days: 10),
    int activeDays = 5,
    int messagesSent = 40,
    DateTime? lastPrompt,
    String? lastPromptVersion,
  }) => ReviewCounters(
    firstSeen: now.subtract(installed),
    activeDays: activeDays,
    messagesSent: messagesSent,
    lastPrompt: lastPrompt,
    lastPromptVersion: lastPromptVersion,
  );

  bool ask({
    ReviewStore store = ReviewStore.play,
    ReviewCounters? counters,
    ReviewMoment moment = const ReviewMoment(),
    String version = '1.0.27',
  }) => shouldRequestReview(
    store: store,
    counters: counters ?? happy(),
    moment: moment,
    now: now,
    version: version,
  );

  group('shouldRequestReview', () {
    test('asks a settled, active user at a quiet moment', () {
      expect(ask(), isTrue);
      expect(ask(store: ReviewStore.appStore), isTrue);
    });

    test('never asks from a build no store distributed', () {
      expect(ask(store: ReviewStore.none), isFalse);
    });

    test('waits until the install is old enough', () {
      expect(ask(counters: happy(installed: const Duration(days: 4))), isFalse);
      expect(ask(counters: happy(installed: const Duration(days: 5))), isTrue);
    });

    test('waits for enough active days', () {
      expect(ask(counters: happy(activeDays: 2)), isFalse);
      expect(ask(counters: happy(activeDays: 3)), isTrue);
    });

    test('waits for enough sent messages', () {
      expect(ask(counters: happy(messagesSent: 19)), isFalse);
      expect(ask(counters: happy(messagesSent: 20)), isTrue);
    });

    test('never in a session that hit an error, a call, onboarding or a '
        'half-typed message', () {
      for (final moment in const [
        ReviewMoment(crashedThisSession: true),
        ReviewMoment(onboarding: true),
        ReviewMoment(inCall: true),
        ReviewMoment(composing: true),
      ]) {
        expect(ask(moment: moment), isFalse);
      }
    });

    test('at most once per version', () {
      final counters = happy(
        lastPrompt: now.subtract(const Duration(days: 200)),
        lastPromptVersion: '1.0.27',
      );
      expect(ask(counters: counters), isFalse);
      expect(ask(counters: counters, version: '1.0.28'), isTrue);
    });

    test('no more often than every 90 days, even across versions', () {
      expect(
        ask(
          counters: happy(
            lastPrompt: now.subtract(const Duration(days: 89)),
            lastPromptVersion: '1.0.20',
          ),
        ),
        isFalse,
      );
      expect(
        ask(
          counters: happy(
            lastPrompt: now.subtract(const Duration(days: 90)),
            lastPromptVersion: '1.0.20',
          ),
        ),
        isTrue,
      );
    });
  });

  group('ReviewStore.resolve', () {
    ReviewStore resolve(String define, TargetPlatform platform) =>
        ReviewStore.resolve(define, platform: platform, isWeb: false);

    test('Play builds ask only on Android', () {
      expect(resolve('play', TargetPlatform.android), ReviewStore.play);
      expect(resolve('play', TargetPlatform.iOS), ReviewStore.none);
    });

    test('App Store builds ask on iOS and macOS', () {
      expect(resolve('appstore', TargetPlatform.iOS), ReviewStore.appStore);
      expect(resolve('appstore', TargetPlatform.macOS), ReviewStore.appStore);
      expect(resolve('appstore', TargetPlatform.android), ReviewStore.none);
    });

    test('release-page, desktop, F-Droid and web builds never ask', () {
      expect(resolve('', TargetPlatform.android), ReviewStore.none);
      expect(resolve('', TargetPlatform.macOS), ReviewStore.none);
      expect(resolve('play', TargetPlatform.windows), ReviewStore.none);
      expect(resolve('appstore', TargetPlatform.linux), ReviewStore.none);
      expect(
        ReviewStore.resolve(
          'play',
          platform: TargetPlatform.android,
          isWeb: true,
        ),
        ReviewStore.none,
      );
    });
  });

  group('ReviewPrompter', () {
    late WeftStores stores;
    late DateTime clock;
    late int requests;

    ReviewPrompter prompter({String version = '1.0.27'}) => ReviewPrompter(
      stores.settings,
      store: ReviewStore.play,
      version: version,
      clock: () => clock,
      request: () async => requests++,
    );

    setUp(() {
      stores = WeftStores.inMemory();
      clock = DateTime(2026, 11, 1, 9);
      requests = 0;
    });
    tearDown(() => stores.dispose());

    test('counts each day once and every send', () async {
      final p = prompter()..recordActive();
      p.recordActive();
      clock = clock.add(const Duration(hours: 3));
      await p.noteMessageSent(const ReviewMoment());
      await p.noteMessageSent(const ReviewMoment());
      clock = clock.add(const Duration(days: 1));
      p.recordActive();

      final counters = p.counters();
      expect(counters.activeDays, 2);
      expect(counters.messagesSent, 2);
      expect(counters.firstSeen, DateTime(2026, 11, 1, 9));
    });

    test('asks once after a send that meets every condition, then not '
        'again this version', () async {
      final p = prompter();
      for (var day = 0; day < 5; day++) {
        p.recordActive();
        for (var i = 0; i < 4; i++) {
          await p.noteMessageSent(const ReviewMoment());
        }
        clock = clock.add(const Duration(days: 1));
      }
      expect(requests, 0, reason: 'not before day five');

      expect(await p.noteMessageSent(const ReviewMoment()), isTrue);
      expect(requests, 1);
      expect(await p.noteMessageSent(const ReviewMoment()), isFalse);

      clock = clock.add(const Duration(days: 30));
      expect(
        await prompter(version: '1.0.28').maybeAsk(const ReviewMoment()),
        isFalse,
        reason: 'a new version still waits out the 90 days',
      );
      clock = clock.add(const Duration(days: 60));
      expect(
        await prompter(version: '1.0.28').maybeAsk(const ReviewMoment()),
        isTrue,
      );
      expect(requests, 2);
    });

    test('a store that throws still counts as asked', () async {
      final p = ReviewPrompter(
        stores.settings,
        store: ReviewStore.play,
        version: '1.0.27',
        clock: () => clock,
        request: () async => throw StateError('no Play services'),
      )..recordActive();
      for (var day = 0; day < 5; day++) {
        clock = clock.add(const Duration(days: 1));
        p.recordActive();
      }
      for (var i = 0; i < 19; i++) {
        await p.noteMessageSent(const ReviewMoment());
      }
      expect(await p.noteMessageSent(const ReviewMoment()), isTrue);
      expect(await p.maybeAsk(const ReviewMoment()), isFalse);
    });
  });
}
