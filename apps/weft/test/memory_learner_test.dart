/// The background learner: when a chat is read again on its own, and when it
/// is not.
///
/// The claims: a burst of conversation or a day of it makes a chat due, a
/// chat that was just read or just failed waits, nothing runs while the app is
/// in the background or the switches are off, and passes never pile up.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/ai/memory_learner.dart';
import 'package:weft_domain/weft_domain.dart';

const _room = '!anna:example.org';
const _chat = Chat(
  id: _room,
  title: 'Anna',
  sources: [ChatSource(roomId: _room, network: ChatNetwork.whatsapp)],
);
const _otherRoom = '!ben:example.org';
const _other = Chat(
  id: _otherRoom,
  title: 'Ben',
  sources: [ChatSource(roomId: _otherRoom, network: ChatNetwork.signal)],
);

WeftMessage _msg(int i, {String room = _room, bool autoReply = false}) =>
    WeftMessage(
      eventId: '\$$room-$i',
      roomId: room,
      network: ChatNetwork.whatsapp,
      senderId: '@anna:example.org',
      senderName: 'Anna',
      timestamp: DateTime.utc(2026, 11, 24, 12, 0, i),
      kind: MessageKind.text,
      body: 'message $i',
      isOwn: false,
      isAutoReply: autoReply,
    );

void main() {
  final noon = DateTime(2026, 11, 24, 12);

  group('memoryLearnDue', () {
    test('a burst makes a chat due, whenever it was last read', () {
      final state = MemoryLearnState(
        newMessages: kMemoryLearnAfterMessages,
        lastLearned: noon.subtract(const Duration(hours: 1)),
        lastTried: noon.subtract(const Duration(hours: 1)),
      );
      expect(memoryLearnDue(state, noon), isTrue);
      expect(
        memoryLearnDue(
          state.copyWith(newMessages: kMemoryLearnAfterMessages - 1),
          noon,
        ),
        isFalse,
      );
    });

    test('a little conversation waits for its daily pass', () {
      final yesterday = noon.subtract(kMemoryLearnDaily);
      final state = MemoryLearnState(
        newMessages: kMemoryLearnDailyMessages,
        lastLearned: yesterday,
        lastTried: yesterday,
      );
      expect(memoryLearnDue(state, noon), isTrue);
      expect(
        memoryLearnDue(state, noon.subtract(const Duration(minutes: 1))),
        isFalse,
      );
      expect(
        memoryLearnDue(
          state.copyWith(newMessages: kMemoryLearnDailyMessages - 1),
          noon,
        ),
        isFalse,
      );
    });

    test('a chat never read is due after a few messages', () {
      expect(
        memoryLearnDue(
          const MemoryLearnState(newMessages: kMemoryLearnDailyMessages),
          noon,
        ),
        isTrue,
      );
      expect(memoryLearnDue(const MemoryLearnState(), noon), isFalse);
    });

    test('just tried waits the gap; just failed waits the retry', () {
      final tried = noon.subtract(kMemoryLearnMinGap ~/ 2);
      final busy = MemoryLearnState(
        newMessages: 100,
        lastLearned: tried,
        lastTried: tried,
      );
      expect(memoryLearnDue(busy, noon), isFalse);

      final failedAt = noon.subtract(kMemoryLearnMinGap);
      final failed = MemoryLearnState(
        newMessages: 100,
        lastLearned: failedAt.subtract(const Duration(days: 1)),
        lastTried: failedAt,
      );
      expect(memoryLearnDue(failed, noon), isFalse);
      expect(memoryLearnDue(failed, failedAt.add(kMemoryLearnRetry)), isTrue);
    });

    test('state survives the settings table', () {
      final state = MemoryLearnState(
        newMessages: 7,
        lastLearned: noon,
        lastTried: noon,
      );
      expect(MemoryLearnState.fromJson(state.toJson()), state);
      expect(MemoryLearnState.fromJson('nonsense'), const MemoryLearnState());
    });
  });

  group('MemoryLearner', () {
    late DateTime now;
    late bool enabled;
    late List<(String, MemoryLearnState)> passes;
    late bool answer;
    late ValueNotifier<bool> foreground;
    Map<String, MemoryLearnState>? saved;

    MemoryLearner learner({
      Map<String, MemoryLearnState> loaded = const {},
      Completer<bool>? hold,
    }) => MemoryLearner(
      incoming: const Stream.empty(),
      chatForRoom: (room) => switch (room) {
        _room => _chat,
        _otherRoom => _other,
        _ => null,
      },
      chatById: (id) => switch (id) {
        _room => _chat,
        _otherRoom => _other,
        _ => null,
      },
      isServiceChat: (_) => false,
      isBroadcast: (_) => false,
      enabled: () => enabled,
      learn: (chat, state) async {
        passes.add((chat.id, state));
        return hold == null ? answer : hold.future;
      },
      load: () => loaded,
      save: (states) => saved = states,
      foreground: foreground,
      now: () => now,
      spacing: Duration.zero,
    );

    setUp(() {
      now = noon;
      enabled = true;
      passes = [];
      answer = true;
      foreground = ValueNotifier(true);
      saved = null;
    });

    test('a burst of messages starts a pass by itself', () async {
      final l = learner();
      for (var i = 0; i < kMemoryLearnDailyMessages - 1; i++) {
        l.handleMessage(_msg(i));
      }
      await pumpEventQueue();
      expect(passes, isEmpty);

      l.handleMessage(_msg(99));
      await pumpEventQueue();
      expect(passes.single.$1, _room);
      expect(passes.single.$2.newMessages, kMemoryLearnDailyMessages);
      final after = l.states[_room]!;
      expect(after.newMessages, 0);
      expect(after.lastLearned, noon);
      await l.dispose();
      expect(saved![_room], after);
    });

    test('auto-replies and unknown rooms are not counted', () {
      final l = learner()
        ..handleMessage(_msg(1, autoReply: true))
        ..handleMessage(_msg(2, room: '!nowhere:example.org'));
      expect(l.states, isEmpty);
    });

    test('the daily pass comes with the tick, not before', () async {
      final l = learner(
        loaded: {
          _room: MemoryLearnState(
            newMessages: kMemoryLearnDailyMessages,
            lastLearned: noon.subtract(const Duration(hours: 23)),
            lastTried: noon.subtract(const Duration(hours: 23)),
          ),
        },
      );
      expect(await l.check(), isNull);
      now = noon.add(const Duration(hours: 1));
      expect(await l.check(), _room);
      expect(passes, hasLength(1));
    });

    test('off, or in the background, nothing runs; counting goes on', () async {
      enabled = false;
      final l = learner();
      for (var i = 0; i < kMemoryLearnAfterMessages; i++) {
        l.handleMessage(_msg(i));
      }
      await pumpEventQueue();
      expect(passes, isEmpty);
      expect(l.states[_room]!.newMessages, kMemoryLearnAfterMessages);

      enabled = true;
      foreground.value = false;
      expect(await l.check(), isNull);

      l.start();
      // Coming back to the front checks at once.
      foreground.value = true;
      await pumpEventQueue();
      expect(passes.single.$1, _room);
      await l.dispose();
    });

    test('a failed pass keeps the count and waits to retry', () async {
      answer = false;
      final l = learner(
        loaded: {_room: const MemoryLearnState(newMessages: 40)},
      );
      expect(await l.check(), _room);
      expect(l.states[_room]!.newMessages, 40);
      expect(l.states[_room]!.lastTried, noon);
      expect(await l.check(), isNull);

      answer = true;
      now = noon.add(kMemoryLearnRetry);
      expect(await l.check(), _room);
      expect(l.states[_room]!.newMessages, 0);
    });

    test('one pass at a time, the busiest chat first', () async {
      final hold = Completer<bool>();
      final l = learner(
        loaded: {
          _room: const MemoryLearnState(newMessages: 5),
          _otherRoom: const MemoryLearnState(newMessages: 50),
        },
        hold: hold,
      );
      final first = l.check();
      expect(await l.check(), isNull);
      expect(l.running, isTrue);
      // What arrives during the pass is left for the next one.
      l.handleMessage(_msg(1, room: _otherRoom));
      hold.complete(true);
      expect(await first, _otherRoom);
      expect(l.states[_otherRoom]!.newMessages, 1);
      expect(passes.map((p) => p.$1), [_otherRoom]);
    });

    test('a chat that is gone is forgotten', () async {
      final l = learner(
        loaded: {'!gone:example.org': const MemoryLearnState(newMessages: 50)},
      );
      expect(await l.check(), isNull);
      expect(l.states, isEmpty);
    });

    test('no more than the daily ceiling of passes', () async {
      final l = learner();
      var ran = 0;
      // Two chats in turn, so each waits out its own gap and the whole run
      // stays within one day.
      for (var i = 0; i < kMemoryLearnMaxPerDay + 5; i++) {
        final room = i.isEven ? _room : _otherRoom;
        for (var j = 0; j < kMemoryLearnAfterMessages; j++) {
          l.handleMessage(_msg(j, room: room));
        }
        now = now.add(kMemoryLearnMinGap ~/ 2);
        if (await l.check() != null) ran++;
      }
      await pumpEventQueue();
      expect(passes.length, kMemoryLearnMaxPerDay);
      expect(ran, lessThanOrEqualTo(kMemoryLearnMaxPerDay));
    });
  });
}
