import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:meta/meta.dart';

/// How much this account trusts one of its own devices.
///
/// Deliberately four states rather than a boolean. "Not verified" and "has no
/// encryption keys at all" look identical in a list and mean opposite things:
/// the first is a device the user can and should verify, the second is one that
/// *cannot* be verified and cannot read encrypted messages either. Offering a
/// Verify button on the second is an invitation to a flow that can only fail.
enum DeviceTrust {
  /// Cross-signed by this account, or verified face to face against a device
  /// that is.
  verified,

  /// Has uploaded keys and has not been verified. Nothing is wrong yet; this
  /// is simply the state every device starts in.
  unverified,

  /// Blocked by the user, or its own self-signature does not check out — which
  /// the SDK reports the same way, because both mean "do not send keys here".
  blocked,

  /// Never uploaded encryption keys. An old or non-E2EE client; it can neither
  /// be verified nor read anything encrypted.
  noKeys;

  /// Whether this state is one the user is expected to do something about.
  ///
  /// [noKeys] is excluded on purpose: there is no action behind the warning, so
  /// a badge that demanded attention would be a demand with nowhere to go.
  bool get needsAttention =>
      this == DeviceTrust.unverified || this == DeviceTrust.blocked;
}

/// Classifies a device from the three facts the SDK exposes about its keys.
///
/// Takes booleans rather than a `DeviceKeys` so the rule — and the order the
/// three are tested in, which is the whole content of it — is testable without
/// a client, a homeserver or a key store.
DeviceTrust deviceTrustFrom({
  required bool hasKeys,
  required bool blocked,
  required bool verified,
}) {
  if (!hasKeys) return DeviceTrust.noKeys;
  // Blocked wins over verified: the SDK reports a device with a broken
  // self-signature as blocked, and such a device must never be presented as
  // trustworthy even if an older verification is still on record.
  if (blocked) return DeviceTrust.blocked;
  return verified ? DeviceTrust.verified : DeviceTrust.unverified;
}

/// One login session on this account, as the devices screen needs it.
@immutable
class WeftDevice {
  const WeftDevice({
    required this.deviceId,
    this.displayName,
    this.lastSeenIp,
    this.lastSeenAt,
    this.isCurrent = false,
    this.trust = DeviceTrust.noKeys,
  });

  final String deviceId;

  /// What the user (or the client that created it) called this device. Absent
  /// when nobody ever named it.
  final String? displayName;

  /// Where the homeserver last saw it. May be minutes out of date, and is
  /// absent on servers that do not record it.
  final String? lastSeenIp;

  final DateTime? lastSeenAt;

  /// Whether this is the device the app is running on.
  final bool isCurrent;

  final DeviceTrust trust;

  /// What to put on the row: the name if there is one, the device id otherwise.
  ///
  /// Never an empty string — a whitespace-only display name is treated as no
  /// name at all, because a row with a blank title is indistinguishable from a
  /// rendering bug.
  String get label {
    final name = displayName?.trim();
    return name == null || name.isEmpty ? deviceId : name;
  }

  WeftDevice copyWith({
    String? displayName,
    String? lastSeenIp,
    DateTime? lastSeenAt,
    bool? isCurrent,
    DeviceTrust? trust,
  }) {
    return WeftDevice(
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      lastSeenIp: lastSeenIp ?? this.lastSeenIp,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      isCurrent: isCurrent ?? this.isCurrent,
      trust: trust ?? this.trust,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WeftDevice &&
          other.deviceId == deviceId &&
          other.displayName == displayName &&
          other.lastSeenIp == lastSeenIp &&
          other.lastSeenAt == lastSeenAt &&
          other.isCurrent == isCurrent &&
          other.trust == trust;

  @override
  int get hashCode => Object.hash(
    deviceId,
    displayName,
    lastSeenIp,
    lastSeenAt,
    isCurrent,
    trust,
  );

  @override
  String toString() => 'WeftDevice($deviceId, ${trust.name})';
}

/// Orders the device list: this device, then the ones that need attention, then
/// the rest by how recently the server saw them.
///
/// Recency alone would be wrong. The device a user most needs to find is either
/// the one they are holding — to check they are on the right account — or the
/// unverified one that appeared last Tuesday, and that one is by definition not
/// at the top of a recency list. Sorting by risk above recency puts both where
/// they are looked for.
///
/// The device id is the final tiebreak so the order is total: a list that
/// reshuffles between two loads because two devices share a timestamp reads as
/// something having changed when nothing has.
List<WeftDevice> sortDevices(Iterable<WeftDevice> devices) {
  return devices.sorted((a, b) {
    if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;

    final attention = a.trust.needsAttention;
    if (attention != b.trust.needsAttention) return attention ? -1 : 1;

    final at = a.lastSeenAt;
    final bt = b.lastSeenAt;
    if (at != null && bt != null && at != bt) return bt.compareTo(at);
    // A device the server has no timestamp for sinks below ones it has.
    if ((at == null) != (bt == null)) return at == null ? 1 : -1;

    return a.deviceId.compareTo(b.deviceId);
  });
}

/// One participant device in a room, reduced to what trust depends on.
typedef RoomDeviceTrust = ({
  String userId,
  String deviceId,
  bool verified,
  bool blocked,
});

/// What an encrypted room's device list means for the person about to type in
/// it.
@immutable
class RoomTrust {
  const RoomTrust({
    required this.encrypted,
    required this.unverifiedDevices,
    required this.unverifiedUsers,
    required this.includesOwnDevice,
  });

  /// A room with nothing to warn about — the state every non-encrypted chat and
  /// every fully verified one is in.
  static const RoomTrust none = RoomTrust(
    encrypted: false,
    unverifiedDevices: 0,
    unverifiedUsers: 0,
    includesOwnDevice: false,
  );

  final bool encrypted;

  /// How many devices in the room have keys but no verification.
  final int unverifiedDevices;

  /// How many distinct people those devices belong to.
  final int unverifiedUsers;

  /// Whether one of them is this account's own — which changes the advice from
  /// "check with them" to "verify your other device", and is the only case with
  /// a one-tap fix.
  final bool includesOwnDevice;

  bool get hasWarning => encrypted && unverifiedDevices > 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoomTrust &&
          other.encrypted == encrypted &&
          other.unverifiedDevices == unverifiedDevices &&
          other.unverifiedUsers == unverifiedUsers &&
          other.includesOwnDevice == includesOwnDevice;

  @override
  int get hashCode => Object.hash(
    encrypted,
    unverifiedDevices,
    unverifiedUsers,
    includesOwnDevice,
  );
}

/// Summarises a room's participant devices.
///
/// Blocked devices are *not* counted. They receive no keys, so they cannot read
/// what is sent next — warning about them would point at the one case the user
/// has already dealt with.
RoomTrust roomTrustFrom({
  required bool encrypted,
  required String ownUserId,
  required Iterable<RoomDeviceTrust> devices,
}) {
  if (!encrypted) return RoomTrust.none;

  final unverified = devices
      .where((d) => !d.verified && !d.blocked)
      .toList(growable: false);

  return RoomTrust(
    encrypted: true,
    unverifiedDevices: unverified.length,
    unverifiedUsers: unverified.map((d) => d.userId).toSet().length,
    includesOwnDevice: unverified.any((d) => d.userId == ownUserId),
  );
}

/// Asked for the account password when the homeserver demands re-authentication.
///
/// Returns null when the user backs out, which is a cancellation and not a
/// failure — nothing has been signed out at that point.
typedef ReauthPrompt = Future<String?> Function();

/// The user abandoned the re-authentication prompt. Nothing was changed.
class ReauthCancelled implements Exception {
  const ReauthCancelled();

  @override
  String toString() => 'ReauthCancelled';
}

/// A device action could not be carried out, with a sentence fit to show.
class DeviceActionException implements Exception {
  const DeviceActionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reading and changing this account's other logins.
///
/// An interface rather than one class so the devices screen can be built and
/// tested against a fake: every method here is a homeserver round trip, and a
/// screen that can only be exercised against a live Synapse is a screen that
/// stops being exercised.
abstract class DeviceManager {
  /// Every device on this account, ordered by [sortDevices].
  Future<List<WeftDevice>> devices();

  /// Renames a device. An empty [displayName] clears the name.
  Future<void> rename(String deviceId, String displayName);

  /// Signs devices out, re-authenticating through [reauth] if the homeserver
  /// asks — which it does for anything that invalidates a token.
  ///
  /// Throws [ReauthCancelled] if the user backs out and
  /// [DeviceActionException] if the server wants a login type Weft cannot
  /// present here.
  Future<void> signOut(List<String> deviceIds, {required ReauthPrompt reauth});
}

/// [DeviceManager] over the Famedly SDK.
class MatrixDeviceManager implements DeviceManager {
  MatrixDeviceManager(this._client);

  final sdk.Client _client;

  @override
  Future<List<WeftDevice>> devices() async {
    final raw = await _client.getDevices() ?? const <sdk.Device>[];
    final userId = _client.userID;
    final keys = userId == null
        ? null
        : _client.userDeviceKeys[userId]?.deviceKeys;

    return sortDevices([
      for (final device in raw)
        WeftDevice(
          deviceId: device.deviceId,
          displayName: device.displayName,
          lastSeenIp: device.lastSeenIp,
          lastSeenAt: device.lastSeenTs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(device.lastSeenTs!),
          isCurrent: device.deviceId == _client.deviceID,
          trust: _trustOf(keys?[device.deviceId]),
        ),
    ]);
  }

  DeviceTrust _trustOf(sdk.DeviceKeys? keys) => deviceTrustFrom(
    hasKeys: keys != null,
    blocked: keys?.blocked ?? false,
    verified: keys?.verified ?? false,
  );

  @override
  Future<void> rename(String deviceId, String displayName) =>
      _client.updateDevice(deviceId, displayName: displayName);

  @override
  Future<void> signOut(
    List<String> deviceIds, {
    required ReauthPrompt reauth,
  }) async {
    if (deviceIds.isEmpty) return;

    try {
      await _client.deleteDevices(deviceIds);
      return;
    } on sdk.MatrixException catch (error) {
      final session = error.session;
      if (session == null) rethrow;

      // No auth was sent, so no stage is completed and the stages the server
      // will accept are exactly the first of each advertised flow.
      final stages = {
        for (final flow in error.authenticationFlows ?? const [])
          if (flow.stages.isNotEmpty) flow.stages.first,
      };
      if (!stages.contains(sdk.AuthenticationTypes.password)) {
        throw const DeviceActionException(
          'Your homeserver wants a kind of confirmation Weft cannot show here '
          'yet. Sign these devices out from your account settings on the '
          'server instead.',
        );
      }

      final userId = _client.userID;
      if (userId == null) rethrow;

      final password = await reauth();
      if (password == null) throw const ReauthCancelled();

      await _client.deleteDevices(
        deviceIds,
        auth: sdk.AuthenticationPassword(
          session: session,
          password: password,
          identifier: sdk.AuthenticationUserIdentifier(user: userId),
        ),
      );
    }
  }
}

/// What the devices in [rooms] mean for the next message sent into them.
///
/// Takes a list rather than one room because a Weft conversation is a merge of
/// one or more, and the warning belongs to the conversation. Devices are
/// deduplicated across the rooms: this account's own device is a member of
/// every encrypted room in the merge, and counting it once per room would
/// report three unverified devices where there is one.
///
/// Cheap on a synced client — the device keys are already in the store — but
/// asynchronous because a room whose membership arrived in a gappy sync has to
/// fetch the missing users' keys before it can honestly say nothing is
/// unverified.
Future<RoomTrust> trustOfRooms(Iterable<sdk.Room> rooms) async {
  final encrypted = rooms.where((room) => room.encrypted).toList();
  if (encrypted.isEmpty) return RoomTrust.none;

  final seen = <String>{};
  final devices = <RoomDeviceTrust>[];
  for (final room in encrypted) {
    for (final key in await room.getUserDeviceKeys()) {
      final deviceId = key.deviceId ?? '';
      if (!seen.add('${key.userId}|$deviceId')) continue;
      devices.add((
        userId: key.userId,
        deviceId: deviceId,
        verified: key.verified,
        blocked: key.blocked,
      ));
    }
  }

  return roomTrustFrom(
    encrypted: true,
    ownUserId: encrypted.first.client.userID ?? '',
    devices: devices,
  );
}
