import 'dart:math';

import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'support/fixtures.dart';

/// Independent oracle for the expected merge order.
///
/// Deliberately a different algorithm from the one under test: a single global
/// sort keyed on (timestamp desc, roomId asc, position-within-source asc)
/// rather than a k-way cursor walk. Agreeing answers from two different methods
/// is worth far more than a copy of the implementation.
List<WeftMessage> _referenceMerge(List<List<WeftMessage>> lists) {
  final keyed = <({WeftMessage m, String room, int index})>[];
  for (final list in lists) {
    for (var i = 0; i < list.length; i++) {
      keyed.add((m: list[i], room: list[i].roomId, index: i));
    }
  }
  keyed.sort((x, y) {
    final byTs = y.m.timestamp.compareTo(x.m.timestamp);
    if (byTs != 0) return byTs;
    final byRoom = x.room.compareTo(y.room);
    if (byRoom != 0) return byRoom;
    return x.index.compareTo(y.index);
  });
  return keyed.map((e) => e.m).toList();
}

void main() {
  group('MergedTimeline watermark', () {
    test('hides messages that a slower source could still outrank', () async {
      // WhatsApp reaches further back than Signal. Signal's unloaded history
      // could contain anything older than t=160, so nothing below 160 is safe.
      final whatsapp = InMemoryTimelineSource(
        roomId: '!wa',
        network: ChatNetwork.whatsapp,
        pageSize: 4,
        history: [
          for (var t = 100; t <= 190; t += 10)
            msg('!wa', ChatNetwork.whatsapp, t),
        ],
      );
      final signal = InMemoryTimelineSource(
        roomId: '!sg',
        network: ChatNetwork.signal,
        pageSize: 2,
        history: [
          for (var t = 105; t <= 195; t += 10)
            msg('!sg', ChatNetwork.signal, t),
        ],
      );

      final timeline = MergedTimeline(sources: [whatsapp, signal]);
      await timeline.loadMore();

      final view = timeline.view();
      expect(view.watermark, isNotNull);

      // Signal loaded 195 and 185; WhatsApp loaded 190..160.
      // Watermark is max(oldest) = max(160, 185) = 185, and it is exclusive,
      // so 185 itself is withheld for one more round.
      expect(
        view.watermark,
        DateTime.fromMillisecondsSinceEpoch(185 * 1000, isUtc: true),
      );
      expect(
        view.messages.map((m) => m.timestamp.millisecondsSinceEpoch ~/ 1000),
        [195, 190],
      );
    });

    test('exposes nothing while a source has history but no loaded page', () {
      final loaded = InMemoryTimelineSource(
        roomId: '!wa',
        network: ChatNetwork.whatsapp,
        history: [msg('!wa', ChatNetwork.whatsapp, 100)],
      );
      final untouched = InMemoryTimelineSource(
        roomId: '!sg',
        network: ChatNetwork.signal,
        history: [msg('!sg', ChatNetwork.signal, 999)],
      );

      final timeline = MergedTimeline(sources: [loaded, untouched]);
      // Nothing is primed, so no ordering claim can be made at all.
      expect(timeline.view().messages, isEmpty);
    });

    test('drops the watermark once every source is exhausted', () async {
      final a = InMemoryTimelineSource(
        roomId: '!a',
        network: ChatNetwork.whatsapp,
        pageSize: 50,
        history: [
          msg('!a', ChatNetwork.whatsapp, 10),
          msg('!a', ChatNetwork.whatsapp, 30),
        ],
      );
      final b = InMemoryTimelineSource(
        roomId: '!b',
        network: ChatNetwork.signal,
        pageSize: 50,
        history: [msg('!b', ChatNetwork.signal, 20)],
      );

      final timeline = MergedTimeline(sources: [a, b]);
      while (timeline.hasMoreHistory) {
        await timeline.loadMore();
      }

      final view = timeline.view();
      expect(view.watermark, isNull);
      expect(view.hasMoreHistory, isFalse);
      expect(
        view.messages.map((m) => m.timestamp.millisecondsSinceEpoch ~/ 1000),
        [30, 20, 10],
      );
    });
  });

  group('MergedTimeline pagination', () {
    test('pulls only from the source holding the watermark up', () async {
      // Signal is the laggard; paginating WhatsApp could not lower the
      // watermark, so it must be left alone.
      final whatsapp = InMemoryTimelineSource(
        roomId: '!wa',
        network: ChatNetwork.whatsapp,
        pageSize: 5,
        history: [
          for (var t = 100; t <= 200; t += 10)
            msg('!wa', ChatNetwork.whatsapp, t),
        ],
      );
      final signal = InMemoryTimelineSource(
        roomId: '!sg',
        network: ChatNetwork.signal,
        pageSize: 1,
        history: [
          for (var t = 100; t <= 200; t += 10)
            msg('!sg', ChatNetwork.signal, t),
        ],
      );

      final timeline = MergedTimeline(sources: [whatsapp, signal]);
      await timeline.loadMore(); // primes both
      final waCallsAfterPriming = whatsapp.loadCallCount;

      await timeline.loadMore();
      await timeline.loadMore();

      expect(signal.loadCallCount, greaterThan(1));
      expect(
        whatsapp.loadCallCount,
        waCallsAfterPriming,
        reason: 'WhatsApp is already older than the watermark',
      );
    });

    test(
      'loadMoreUntilVisibleGrowth keeps going until the view grows',
      () async {
        // Signal pages one at a time from far in the future, so several rounds
        // are needed before any new message becomes visible.
        final whatsapp = InMemoryTimelineSource(
          roomId: '!wa',
          network: ChatNetwork.whatsapp,
          pageSize: 20,
          history: [
            for (var t = 100; t <= 120; t += 10)
              msg('!wa', ChatNetwork.whatsapp, t),
          ],
        );
        final signal = InMemoryTimelineSource(
          roomId: '!sg',
          network: ChatNetwork.signal,
          pageSize: 1,
          history: [
            for (var t = 300; t <= 400; t += 10)
              msg('!sg', ChatNetwork.signal, t),
          ],
        );

        final timeline = MergedTimeline(sources: [whatsapp, signal]);
        await timeline.loadMore();
        final before = timeline.view().messages.length;

        final after = await timeline.loadMoreUntilVisibleGrowth();
        expect(after.messages.length, greaterThan(before));
      },
    );
  });

  group('MergedTimeline ordering', () {
    test('breaks timestamp ties deterministically', () async {
      final a = InMemoryTimelineSource(
        roomId: '!aaa',
        network: ChatNetwork.whatsapp,
        pageSize: 10,
        history: [msg('!aaa', ChatNetwork.whatsapp, 500, eventId: r'$z')],
      );
      final b = InMemoryTimelineSource(
        roomId: '!bbb',
        network: ChatNetwork.signal,
        pageSize: 10,
        history: [msg('!bbb', ChatNetwork.signal, 500, eventId: r'$a')],
      );

      final first = MergedTimeline(sources: [a, b]);
      await first.loadMore();
      final orderOne = first.view().messages.map((m) => m.roomId).toList();

      final a2 = InMemoryTimelineSource(
        roomId: '!aaa',
        network: ChatNetwork.whatsapp,
        pageSize: 10,
        history: [msg('!aaa', ChatNetwork.whatsapp, 500, eventId: r'$z')],
      );
      final b2 = InMemoryTimelineSource(
        roomId: '!bbb',
        network: ChatNetwork.signal,
        pageSize: 10,
        history: [msg('!bbb', ChatNetwork.signal, 500, eventId: r'$a')],
      );
      // Same messages, sources supplied in the opposite order.
      final second = MergedTimeline(sources: [b2, a2]);
      await second.loadMore();

      expect(second.view().messages.map((m) => m.roomId).toList(), orderOne);
    });

    test('applies per-source clock-skew correction', () async {
      // Raw timestamps say WhatsApp is newer; a +60s correction on Signal
      // flips the true order.
      final whatsapp = InMemoryTimelineSource(
        roomId: '!wa',
        network: ChatNetwork.whatsapp,
        pageSize: 10,
        history: [msg('!wa', ChatNetwork.whatsapp, 1000)],
      );
      final signal = InMemoryTimelineSource(
        roomId: '!sg',
        network: ChatNetwork.signal,
        pageSize: 10,
        history: [msg('!sg', ChatNetwork.signal, 970)],
        clockOffset: const Duration(seconds: 60),
      );

      final timeline = MergedTimeline(sources: [whatsapp, signal]);
      await timeline.loadMore();

      expect(timeline.view().messages.first.roomId, '!sg');
    });
  });

  group('MergedTimeline invariants (randomised)', () {
    // The property that actually matters: as backfill proceeds, the visible
    // timeline may only *grow downwards*. A message must never be inserted
    // above one the user has already read.
    test('the visible list only ever extends, never reorders', () async {
      final rng = Random(20260815);

      for (var trial = 0; trial < 200; trial++) {
        final sourceCount = 2 + rng.nextInt(4);
        final sources = <InMemoryTimelineSource>[];

        for (var s = 0; s < sourceCount; s++) {
          final roomId = '!room$s';
          final network = ChatNetwork.values[s % ChatNetwork.values.length];
          final count = rng.nextInt(25);
          final history = <WeftMessage>[];
          for (var i = 0; i < count; i++) {
            // Deliberately overlapping ranges and duplicate timestamps.
            final t = 1000 + rng.nextInt(60);
            history.add(msg(roomId, network, t, eventId: '\$${s}_$i'));
          }
          sources.add(
            InMemoryTimelineSource(
              roomId: roomId,
              network: network,
              history: history,
              pageSize: 1 + rng.nextInt(5),
            ),
          );
        }

        final timeline = MergedTimeline(sources: sources);
        var previous = timeline.view().messages;

        var guard = 0;
        while (timeline.hasMoreHistory && guard++ < 500) {
          await timeline.loadMore();
          final current = timeline.view().messages;

          expect(
            current.length,
            greaterThanOrEqualTo(previous.length),
            reason: 'trial $trial: the visible list shrank',
          );
          for (var i = 0; i < previous.length; i++) {
            expect(
              current[i].eventId,
              previous[i].eventId,
              reason:
                  'trial $trial: message at index $i was displaced — a '
                  'later backfill reordered already-visible history',
            );
          }
          previous = current;
        }

        // Once exhausted, the merged view must equal what an independent
        // reference merge produces from the complete, unpaginated histories.
        final expected = _referenceMerge([for (final s in sources) s.loaded]);
        expect(
          previous.map((m) => m.eventId).toList(),
          expected.map((m) => m.eventId).toList(),
          reason: 'trial $trial: final order diverged from the reference merge',
        );
      }
    });
  });
}
