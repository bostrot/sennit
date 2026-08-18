import 'package:flutter_test/flutter_test.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// The device layer's decisions, without a homeserver.
///
/// Everything here is deliberately reachable without an SDK client: the order
/// of a device list, what "trusted" means, and what an encrypted room's device
/// list adds up to are all judgements a user acts on, and none of them should
/// need a live Synapse to check.
void main() {
  WeftDevice device(
    String id, {
    String? name,
    DateTime? seen,
    bool current = false,
    DeviceTrust trust = DeviceTrust.verified,
  }) => WeftDevice(
    deviceId: id,
    displayName: name,
    lastSeenAt: seen,
    isCurrent: current,
    trust: trust,
  );

  group('deviceTrustFrom', () {
    test('no keys is its own state, not an unverified device', () {
      // The difference matters in the UI: one gets a Verify button, the other
      // cannot be verified at all, and offering the button on the second sends
      // the user into a flow that can only fail.
      expect(
        deviceTrustFrom(hasKeys: false, blocked: false, verified: false),
        DeviceTrust.noKeys,
      );
      expect(
        deviceTrustFrom(hasKeys: true, blocked: false, verified: false),
        DeviceTrust.unverified,
      );
    });

    test('blocked outranks verified', () {
      // A device whose self-signature stops checking out is reported blocked
      // while an old verification is still on record. Showing it as verified
      // would be the one wrong answer.
      expect(
        deviceTrustFrom(hasKeys: true, blocked: true, verified: true),
        DeviceTrust.blocked,
      );
    });

    test('a device with no keys is never "needs attention"', () {
      expect(DeviceTrust.noKeys.needsAttention, isFalse);
      expect(DeviceTrust.unverified.needsAttention, isTrue);
      expect(DeviceTrust.blocked.needsAttention, isTrue);
      expect(DeviceTrust.verified.needsAttention, isFalse);
    });
  });

  group('WeftDevice', () {
    test('falls back to the device id when there is no usable name', () {
      expect(device('ABCDEF').label, 'ABCDEF');
      expect(device('ABCDEF', name: '   ').label, 'ABCDEF');
      expect(device('ABCDEF', name: ' Pixel ').label, 'Pixel');
    });

    test('is a value type', () {
      expect(device('A', name: 'x'), device('A', name: 'x'));
      expect(device('A', name: 'x').hashCode, device('A', name: 'x').hashCode);
      expect(device('A', name: 'x'), isNot(device('A', name: 'y')));
    });
  });

  group('sortDevices', () {
    final old = DateTime.utc(2026, 1, 1);
    final recent = DateTime.utc(2026, 8, 18);

    test('this device leads, even when it is stale and verified', () {
      final sorted = sortDevices([
        device('B', seen: recent, trust: DeviceTrust.unverified),
        device('A', seen: old, current: true),
      ]);

      expect(sorted.map((d) => d.deviceId), ['A', 'B']);
    });

    test('unverified beats recent, because that is what is looked for', () {
      // The session someone needs to find is the one that appeared last
      // Tuesday and has not been verified — by definition not the top of a
      // recency list.
      final sorted = sortDevices([
        device('fresh', seen: recent),
        device('suspicious', seen: old, trust: DeviceTrust.unverified),
      ]);

      expect(sorted.map((d) => d.deviceId), ['suspicious', 'fresh']);
    });

    test('within a tier, most recently seen first and unknown times last', () {
      final sorted = sortDevices([
        device('never'),
        device('older', seen: old),
        device('newer', seen: recent),
      ]);

      expect(sorted.map((d) => d.deviceId), ['newer', 'older', 'never']);
    });

    test('the order is total, so two loads cannot reshuffle the list', () {
      final one = sortDevices([
        device('B', seen: recent),
        device('A', seen: recent),
      ]);
      final two = sortDevices([
        device('A', seen: recent),
        device('B', seen: recent),
      ]);

      expect(one.map((d) => d.deviceId), ['A', 'B']);
      expect(two.map((d) => d.deviceId), one.map((d) => d.deviceId));
    });
  });

  group('roomTrustFrom', () {
    RoomDeviceTrust participant(
      String user,
      String device, {
      bool verified = true,
      bool blocked = false,
    }) =>
        (userId: user, deviceId: device, verified: verified, blocked: blocked);

    test('an unencrypted room never warns, whatever its devices look like', () {
      final trust = roomTrustFrom(
        encrypted: false,
        ownUserId: '@me:example.org',
        devices: [participant('@them:example.org', 'X', verified: false)],
      );

      expect(trust, RoomTrust.none);
      expect(trust.hasWarning, isFalse);
    });

    test('counts unverified devices and the people behind them', () {
      final trust = roomTrustFrom(
        encrypted: true,
        ownUserId: '@me:example.org',
        devices: [
          participant('@them:example.org', 'A', verified: false),
          participant('@them:example.org', 'B', verified: false),
          participant('@other:example.org', 'C', verified: false),
          participant('@me:example.org', 'MINE'),
        ],
      );

      expect(trust.hasWarning, isTrue);
      expect(trust.unverifiedDevices, 3);
      expect(trust.unverifiedUsers, 2);
      expect(trust.includesOwnDevice, isFalse);
    });

    test('a blocked device is not warned about', () {
      // It receives no keys, so it cannot read what is sent next. Warning
      // about it would point at the one case the user has already handled.
      final trust = roomTrustFrom(
        encrypted: true,
        ownUserId: '@me:example.org',
        devices: [
          participant('@them:example.org', 'A', verified: false, blocked: true),
        ],
      );

      expect(trust.hasWarning, isFalse);
      expect(trust.unverifiedDevices, 0);
    });

    test('an unverified device of our own is flagged as ours', () {
      final trust = roomTrustFrom(
        encrypted: true,
        ownUserId: '@me:example.org',
        devices: [participant('@me:example.org', 'LAPTOP', verified: false)],
      );

      expect(trust.includesOwnDevice, isTrue);
      expect(trust.unverifiedUsers, 1);
    });
  });
}
