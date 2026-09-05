import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_sms/weft_sms.dart';

/// Whether SMS can be one of the networks in this device's inbox.
///
/// Three states, not a boolean, because the two "no" answers lead to different
/// screens: a device with no radio can never carry SMS and must not be offered
/// it, while a phone where Braid simply is not the default app is one tap away
/// from carrying it. Conflating them produces either a button that cannot work
/// or a missing feature with no explanation.
enum SmsAvailability {
  /// No SMS at all: a desktop, a tablet with no modem, or an Android build
  /// where the channel has no handler. Nothing to offer and nothing to ask.
  unsupported,

  /// The device can do SMS and Braid is not the app doing it.
  ///
  /// **This is a normal, fully supported state, not a degraded one.** Braid is a
  /// Matrix client that can also carry SMS; every other network works exactly
  /// as before and the SMS network is simply absent from the inbox.
  notDefault,

  /// Braid holds `ROLE_SMS`: threads are readable, messages sendable, and
  /// received messages arrive on [SmsPlatform.incoming].
  ready,
}

/// How a request for the default-SMS-app role ended.
///
/// Not a boolean, and the reason is the bug this replaced. Four different things
/// can happen after the button is tapped and only one of them is a decline, but
/// the old signature had one word for all four — so a role the system granted
/// while the activity was being recreated came back as `false` and the screen
/// said *"Nothing changed. Braid is not your SMS app"* to somebody who had just
/// made Braid their SMS app. See the phase-05 diagnosis note.
///
/// The wire strings are [SmsRole.Outcome] on the Kotlin side; the two lists are
/// the same list and neither may be extended alone.
enum SmsRoleOutcome {
  /// Braid holds the role, confirmed by asking the system after the dialog
  /// closed rather than by trusting its result code.
  granted,

  /// The dialog was shown and the answer was no. **The only outcome the
  /// "nothing changed" copy belongs on.**
  denied,

  /// No dialog could be shown: no telephony, no `ROLE_SMS` on this ROM, a build
  /// missing a component the role requires, or no activity to raise it from.
  /// The user was never asked, so they did not refuse.
  unavailable,

  /// A second request replaced this one. Silent by design — the request that
  /// superseded it is the one still on screen and it will report for both.
  superseded,

  /// The activity went away while the dialog was up. The system knows the
  /// answer; this call simply did not carry it back. Re-read the status.
  interrupted;

  /// The platform's string, defaulting to [interrupted].
  ///
  /// An unrecognised value is a Kotlin side newer than this Dart, which is a
  /// hot-restart reality in development. [interrupted] is the safe default
  /// because it means "go and ask the system", which is right for any answer
  /// this enum cannot name.
  static SmsRoleOutcome fromWire(Object? value) => switch (value) {
    'granted' => SmsRoleOutcome.granted,
    'denied' => SmsRoleOutcome.denied,
    'unavailable' => SmsRoleOutcome.unavailable,
    'superseded' => SmsRoleOutcome.superseded,
    _ => SmsRoleOutcome.interrupted,
  };
}

/// What the platform says about SMS on this device.
@immutable
class SmsPlatformStatus {
  const SmsPlatformStatus({
    required this.availability,
    this.canRequestRole = false,
    this.roleAvailable = false,
    this.hasPermissions = false,
    this.defaultPackage,
  });

  /// The answer for a platform with no SMS channel at all.
  static const SmsPlatformStatus unsupported = SmsPlatformStatus(
    availability: SmsAvailability.unsupported,
  );

  final SmsAvailability availability;

  /// Whether the system's default-app dialog can be shown.
  ///
  /// False once Weft already holds the role, and on a device where the role
  /// does not exist — a button wired to this cannot be tapped into a dialog
  /// that will not appear.
  final bool canRequestRole;

  /// Whether this device has a default-SMS-app role to give at all.
  ///
  /// Stays true once Braid holds it, which is what separates it from
  /// [canRequestRole]: "there is nothing left to ask for" and "this ROM has no
  /// such role" are both `canRequestRole: false` and are opposite sentences.
  final bool roleAvailable;

  /// Whether the SMS permission group is actually granted.
  ///
  /// Distinct from [availability] on purpose. Holding the role normally grants
  /// the group, but the two are not one instant: a role handed to another app
  /// while Weft is in the background revokes the permissions under a read that
  /// is already running. A `ready` status with this false is the state where
  /// every read comes back empty, and it is worth being able to say so rather
  /// than showing an inbox that has mysteriously lost its SMS.
  final bool hasPermissions;

  /// The package that currently holds the role, for an explanatory sentence.
  final String? defaultPackage;

  bool get isReady => availability == SmsAvailability.ready;

  /// Decodes the platform's map, defaulting to [unsupported].
  ///
  /// Every unknown or missing field reads as "no SMS here". The failure mode of
  /// the opposite default is an inbox that promises a network the device cannot
  /// carry.
  factory SmsPlatformStatus.fromMap(Map<Object?, Object?>? map) {
    if (map == null) return unsupported;
    final supported = map['supported'] == true;
    if (!supported) return unsupported;
    return SmsPlatformStatus(
      availability: map['isDefault'] == true
          ? SmsAvailability.ready
          : SmsAvailability.notDefault,
      canRequestRole: map['canRequestRole'] == true,
      // Absent on a platform side older than this Dart, where "can request it"
      // was the only answer there was. Reading `canRequestRole` as the fallback
      // keeps that build's screen exactly as it was rather than telling it the
      // role does not exist.
      roleAvailable:
          map['roleAvailable'] == true ||
          (map['roleAvailable'] == null &&
              (map['canRequestRole'] == true || map['isDefault'] == true)),
      hasPermissions: map['hasPermissions'] == true,
      defaultPackage: map['defaultPackage'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SmsPlatformStatus &&
      other.availability == availability &&
      other.canRequestRole == canRequestRole &&
      other.roleAvailable == roleAvailable &&
      other.hasPermissions == hasPermissions &&
      other.defaultPackage == defaultPackage;

  @override
  int get hashCode => Object.hash(
    availability,
    canRequestRole,
    roleAvailable,
    hasPermissions,
    defaultPackage,
  );

  @override
  String toString() =>
      'SmsPlatformStatus(${availability.name}, permissions: $hasPermissions)';
}

/// An MMS that reached the device and cannot be fetched.
///
/// Braid does not download MMS yet — Android exposes the transport but not the
/// PDU parser, so retrieval means vendoring AOSP's — and this is what says so.
/// It exists rather than being dropped because the alternative is a message the
/// sender watched leave their phone and the recipient never hears about.
@immutable
class SmsMmsPush {
  const SmsMmsPush({required this.receivedAt, this.sizeBytes = 0});

  final DateTime receivedAt;

  /// Bytes of the notification PDU — the pointer to the message, not the
  /// message. Never the size of the photo somebody sent.
  final int sizeBytes;

  static SmsMmsPush? fromMap(Map<Object?, Object?> map) {
    final at = map['receivedAt'];
    if (at is! int) return null;
    return SmsMmsPush(
      receivedAt: DateTime.fromMillisecondsSinceEpoch(at),
      sizeBytes: switch (map['sizeBytes']) {
        final int size when size >= 0 => size,
        _ => 0,
      },
    );
  }
}

/// Where SMS threads and messages come from.
///
/// A seam for the same reason [SharedFileResolver] is one in `intents.dart`:
/// behind it is a method channel into Android's telephony stack, and there is
/// no version of `flutter test` that has a SIM in it. `SmsChatRepository` and
/// everything above it take this interface, so the repository's decisions —
/// what becomes a `Chat`, which thread a message joins, when a merge signal is
/// contributed — are testable against a list.
abstract interface class SmsGateway {
  Future<SmsPlatformStatus> status();

  /// Shows the system's default-SMS-app dialog and resolves to how it ended.
  ///
  /// [SmsRoleOutcome.denied] is an answer, not an error. So is
  /// [SmsRoleOutcome.unavailable] — it is a fact about the device — and neither
  /// throws. Callers must not treat "not granted" as one case; see the enum.
  Future<SmsRoleOutcome> requestRole();

  /// Opens Android's default-apps settings, resolving to whether it opened.
  ///
  /// The way *out* of the role, which no API provides: `RoleManager` can be
  /// asked for a role and cannot be told to give one up. Without this the role
  /// is a one-way door, and it is a door with a cost — the phone's RCS — so
  /// the way back belongs in the same screen as the way in.
  Future<bool> openDefaultAppSettings();

  Future<List<SmsThread>> threads({int limit});

  Future<List<SmsMessage>> messages(String threadId, {int limit});

  /// Sends [body] to [address], resolving to the stored message.
  ///
  /// Null when the platform would not take it at all. A message that *was*
  /// handed to the radio comes back with [DeliveryState.sending]; whether it
  /// arrived is later news, on [statusUpdates].
  Future<SmsMessage?> send({required String address, required String body});

  Future<int> markThreadRead(String threadId);

  /// Messages received while Braid is running.
  Stream<SmsMessage> get incoming;

  /// Send outcomes and delivery reports for messages already shown.
  Stream<SmsMessage> get statusUpdates;

  /// MMS notifications Braid cannot retrieve.
  Stream<SmsMmsPush> get mmsPushes;

  /// Replays anything that arrived before Dart was listening.
  Future<void> drainPending();
}

/// `com.bostrot.weft/sms` — Android's telephony stack, as Dart types.
///
/// Nothing here decides anything. Normalising a number, counting segments,
/// mapping a provider row's type and status onto a [DeliveryState] and judging
/// whether an SMS address is the same person as a WhatsApp handle all live in
/// `packages/weft_sms`, in pure Dart, tested without a device. This class moves
/// maps across a channel and turns them into that package's value types.
///
/// Every call answers rather than throws. `MissingPluginException` is the
/// ordinary state of four of Weft's five platforms and reads as "no SMS here";
/// a `PlatformException` is a role or a permission that changed underneath a
/// call, which is a thing users do in Settings while an app is open. Neither is
/// allowed to take down an inbox whose other networks are working perfectly.
class SmsPlatform implements SmsGateway {
  SmsPlatform({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.bostrot.weft/sms') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;

  final StreamController<SmsMessage> _incoming =
      StreamController<SmsMessage>.broadcast();
  final StreamController<SmsMessage> _statuses =
      StreamController<SmsMessage>.broadcast();
  final StreamController<SmsMmsPush> _pushes =
      StreamController<SmsMmsPush>.broadcast();

  @override
  Stream<SmsMessage> get incoming => _incoming.stream;

  @override
  Stream<SmsMessage> get statusUpdates => _statuses.stream;

  @override
  Stream<SmsMmsPush> get mmsPushes => _pushes.stream;

  @override
  Future<SmsPlatformStatus> status() async {
    final map = await _invoke<Map<Object?, Object?>>('getStatus');
    return SmsPlatformStatus.fromMap(map);
  }

  @override
  Future<SmsRoleOutcome> requestRole() async {
    final answer = await _invoke<Object>('requestRole');
    // Null is the `_invoke` swallow: a missing plugin, or the role changing
    // under the call. Neither is a decline — there is no dialog on a platform
    // with no channel — so it reads as unavailable.
    if (answer == null) return SmsRoleOutcome.unavailable;
    return SmsRoleOutcome.fromWire(answer);
  }

  @override
  Future<bool> openDefaultAppSettings() async =>
      await _invoke<bool>('openDefaultAppSettings') ?? false;

  @override
  Future<List<SmsThread>> threads({int limit = kSmsReadLimit}) async {
    final rows = await _invoke<List<Object?>>('getThreads', {'limit': limit});
    return [
      for (final row in rows ?? const [])
        if (row is Map<Object?, Object?>) ?smsThreadFromPlatform(row),
    ];
  }

  @override
  Future<List<SmsMessage>> messages(
    String threadId, {
    int limit = kSmsReadLimit,
  }) async {
    final rows = await _invoke<List<Object?>>('getMessages', {
      'threadId': threadId,
      'limit': limit,
    });
    return [
      for (final row in rows ?? const [])
        if (row is Map<Object?, Object?>) ?smsMessageFromPlatform(row),
    ];
  }

  @override
  Future<SmsMessage?> send({
    required String address,
    required String body,
  }) async {
    final row = await _invoke<Map<Object?, Object?>>('sendMessage', {
      'address': address,
      'body': body,
    });
    return row == null ? null : smsMessageFromPlatform(row);
  }

  @override
  Future<int> markThreadRead(String threadId) async =>
      await _invoke<int>('markThreadRead', {'threadId': threadId}) ?? 0;

  @override
  Future<void> drainPending() async {
    final events = await _invoke<List<Object?>>('getPending');
    for (final event in events ?? const []) {
      if (event is! Map<Object?, Object?>) continue;
      final payload = event['payload'];
      if (payload is! Map<Object?, Object?>) continue;
      _dispatch(event['event'] as String?, payload);
    }
  }

  /// Releases the streams. The channel handler is dropped with them so a
  /// message arriving after teardown is not delivered into a closed sink.
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await Future.wait([_incoming.close(), _statuses.close(), _pushes.close()]);
  }

  Future<void> _onCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is Map<Object?, Object?>) _dispatch(call.method, arguments);
  }

  /// One place both a live call and a replayed one land, so a message received
  /// during a cold start is handled by exactly the same code as one that
  /// arrived a second later.
  void _dispatch(String? event, Map<Object?, Object?> payload) {
    switch (event) {
      case 'onSmsReceived':
        final message = smsMessageFromPlatform(payload);
        if (message != null && !_incoming.isClosed) _incoming.add(message);
      case 'onSmsStatus':
        final message = smsMessageFromPlatform(payload);
        if (message != null && !_statuses.isClosed) _statuses.add(message);
      case 'onMmsPush':
        final push = SmsMmsPush.fromMap(payload);
        if (push != null && !_pushes.isClosed) _pushes.add(push);
      default:
        // An event from a newer platform side than this Dart. Ignored rather
        // than thrown on: the two halves ship together, but a stale engine
        // surviving a hot restart is a development reality.
        break;
    }
  }

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // No SMS channel: every platform but Android, and the normal case.
      return null;
    } on PlatformException catch (error) {
      // The role or its permissions changed under the call. Logged rather than
      // rethrown — the caller's answer is "no SMS right now", which is a state
      // it already has to render.
      debugPrint('weft: sms $method failed: ${error.code}');
      return null;
    }
  }
}

/// Rows a single read pulls across the channel.
///
/// A thread with a decade of messages exists and does not need to cross a
/// method channel to draw a screenful. The platform applies the same default.
const int kSmsReadLimit = 200;

/// One provider row as [SmsMessage], or null when it cannot be placed.
///
/// Null is returned for a row with no id or no thread — both are the provider's
/// own keys and a row missing either cannot be addressed, updated or merged. It
/// is a corrupt row, not a message, and inventing an id for it would produce a
/// bubble that reappears on every read.
SmsMessage? smsMessageFromPlatform(Map<Object?, Object?> map) {
  final id = (map['id'] as String?)?.trim();
  final threadId = (map['threadId'] as String?)?.trim();
  if (id == null || id.isEmpty || threadId == null || threadId.isEmpty) {
    return null;
  }

  final type = switch (map['type']) {
    final int value => value,
    _ => SmsProviderType.inbox,
  };
  final status = switch (map['status']) {
    final int value => value,
    _ => SmsProviderStatus.none,
  };

  return SmsMessage(
    id: id,
    threadId: threadId,
    address: (map['address'] as String?) ?? '',
    timestamp: DateTime.fromMillisecondsSinceEpoch(switch (map['timestamp']) {
      final int at when at > 0 => at,
      _ => 0,
    }),
    // Everything that is not an inbox row was written by this device. Drafts
    // included: a draft is the user's own text, and the day one is rendered it
    // belongs on their side of the thread.
    isOutgoing: type != SmsProviderType.inbox,
    body: (map['body'] as String?) ?? '',
    subject: (map['subject'] as String?)?.trim().isEmpty ?? true
        ? null
        : map['subject'] as String?,
    // The mapping itself is `weft_sms`'s, not this file's — a second switch on
    // provider integers here is exactly the duplicate that would drift.
    deliveryState: smsDeliveryState(type: type, status: status),
    attachmentUri: map['attachmentUri'] as String?,
    attachmentMimeType: map['attachmentMimeType'] as String?,
    attachmentSizeBytes: switch (map['attachmentSizeBytes']) {
      final int size when size >= 0 => size,
      _ => null,
    },
  );
}

/// One conversation row as [SmsThread], or null when it has no id.
SmsThread? smsThreadFromPlatform(Map<Object?, Object?> map) {
  final id = (map['id'] as String?)?.trim();
  if (id == null || id.isEmpty) return null;

  return SmsThread(
    id: id,
    addresses: [
      for (final address in (map['addresses'] as List?) ?? const [])
        if (address is String && address.trim().isNotEmpty) address.trim(),
    ],
    // The provider has no title column: a thread is named by its participants
    // until contacts say otherwise, which is a lookup the repository owns.
    title: (map['title'] as String?)?.trim().isEmpty ?? true
        ? null
        : (map['title'] as String?)?.trim(),
    snippet: map['snippet'] as String?,
    unreadCount: switch (map['unreadCount']) {
      final int count when count >= 0 => count,
      _ => 0,
    },
    lastMessageAt: switch (map['lastMessageAt']) {
      final int at when at > 0 => DateTime.fromMillisecondsSinceEpoch(at),
      _ => null,
    },
    archived: map['archived'] == true,
  );
}
