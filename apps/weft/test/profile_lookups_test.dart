import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/profile_lookups.dart';
import 'package:weft_domain/weft_domain.dart';

NetworkHandle _handle({String? displayName, String? avatarUrl}) =>
    NetworkHandle(
      id: '@whatsapp_4915100000001:example.org',
      network: ChatNetwork.whatsapp,
      remoteId: '4915100000001',
      matrixUserId: '@whatsapp_4915100000001:example.org',
      displayName: displayName,
      avatarUrl: avatarUrl,
    );

void main() {
  group('LookupLane', () {
    test('never runs more lookups at once than it is wide', () async {
      final lane = LookupLane(width: 3);
      final gates = <Completer<void>>[];
      var peak = 0;
      var finished = 0;

      for (var i = 0; i < 50; i++) {
        final gate = Completer<void>();
        gates.add(gate);
        lane.add(() async {
          if (lane.running > peak) peak = lane.running;
          await gate.future;
          finished++;
        });
      }

      // An account's worth of lookups asked for in one go: three start, the
      // rest wait.
      expect(lane.running, 3);
      expect(lane.waiting, 47);

      for (final gate in gates) {
        gate.complete();
        await pumpEventQueue();
      }

      expect(finished, 50);
      expect(peak, 3);
      expect(lane.running, 0);
      expect(lane.waiting, 0);
    });

    test('a lookup that throws gives its place to the next one', () async {
      final lane = LookupLane(width: 1);
      var second = false;

      lane.add(() async => throw StateError('no route to host'));
      lane.add(() async => second = true);
      await pumpEventQueue();

      expect(second, isTrue);
      expect(lane.running, 0);
    });

    test('closing drops what is waiting and accepts nothing more', () async {
      final lane = LookupLane(width: 1);
      final gate = Completer<void>();
      final ran = <int>[];

      lane.add(() async {
        await gate.future;
        ran.add(0);
      });
      lane.add(() async => ran.add(1));
      lane.close();
      lane.add(() async => ran.add(2));

      gate.complete();
      await pumpEventQueue();

      // The one already in flight finishes; nothing behind it starts.
      expect(ran, [0]);
      expect(lane.waiting, 0);
    });
  });

  group('rememberedProfile', () {
    test('a stored name and picture are what the last run learned', () {
      final remembered = rememberedProfile(
        _handle(displayName: 'Anna Maven', avatarUrl: 'https://hs/thumb/a'),
        fallbackName: 'Whatsapp 4915100000001',
      );

      expect(remembered.displayName, 'Anna Maven');
      expect(remembered.avatarUrl, 'https://hs/thumb/a');
    });

    test('a stored name that is only the made-up one is no name', () {
      // The first run wrote the guess down before the profile arrived, and
      // then never got an answer. Handing it back as knowledge would stop the
      // repository asking again.
      final remembered = rememberedProfile(
        _handle(displayName: 'Whatsapp 4915100000001'),
        fallbackName: 'Whatsapp 4915100000001',
      );

      expect(remembered.displayName, isNull);
      expect(remembered.avatarUrl, isNull);
    });

    test('a blank stored name is no name', () {
      expect(
        rememberedProfile(
          _handle(displayName: '  '),
          fallbackName: 'x',
        ).displayName,
        isNull,
      );
    });

    test('a peer nobody has stored remembers nothing', () {
      final remembered = rememberedProfile(null, fallbackName: 'x');

      expect(remembered.displayName, isNull);
      expect(remembered.avatarUrl, isNull);
    });
  });
}
