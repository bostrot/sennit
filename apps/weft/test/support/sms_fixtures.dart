import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/sms/sms_platform.dart';
import 'package:weft_sms/weft_sms.dart';

/// Android's telephony stack, as a map.
///
/// There is no version of `flutter test` with a SIM in it, and none of what is
/// worth testing above this line needs one. What the platform side does is read
/// cursors; what the Dart side does is decide what a row means — which rows are
/// messages at all, which are unplaceable, what a type and a status say about
/// delivery, and what happens when the role is handed to another app underneath
/// a call. Every one of those is a decision, and each is wrong in a way that
/// reaches the user as a missing or mislabelled message.
///
/// Shared by `sms_platform_test.dart` and `sms_repository_test.dart` so both
/// halves are exercised against one fake: a repository test that invented its
/// own gateway would be testing the repository against a channel shape nobody
/// has checked against the real one.
class FakeSmsChannel {
  FakeSmsChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  static const Map<String, Object?> _defaultStatus = {
    'supported': true,
    'isDefault': true,
    'canRequestRole': false,
    'hasPermissions': true,
    'defaultPackage': 'com.bostrot.weft',
  };

  final MethodChannel channel = const MethodChannel('weft-test/sms');

  /// What `getStatus` answers — the role held, by default.
  Map<String, Object?>? status = _defaultStatus;

  /// Rows `getThreads` answers with.
  List<Map<String, Object?>> threads = const [];

  /// Rows `getMessages` answers with, for every thread.
  List<Map<String, Object?>> messages = const [];

  /// Rows `getMessages` answers with per thread id, when the flat [messages]
  /// list is not enough — a test that opens two threads, or one that checks
  /// pagination, needs the provider to answer differently per query.
  Map<String, List<Map<String, Object?>>>? messagesByThread;

  /// Events queued before Dart attached, as `SmsBridge` tags them.
  List<Map<String, Object?>> pending = const [];

  /// What `sendMessage` writes back, or null for a platform that refused.
  Map<String, Object?>? sentRow;

  /// The user's answer to the role dialog.
  bool roleGranted = false;

  /// Methods that fail, and the code they fail with — a role handed away
  /// mid-call, a permission revoked in Settings.
  Map<String, String> failures = const {};

  /// Every method invoked, in order.
  final List<String> calls = [];

  /// Arguments of the last call to each method.
  final Map<String, Object?> arguments = {};

  /// The `limit` each `getMessages` was asked for, in order. Pagination is the
  /// one thing here that is a sequence rather than a state.
  final List<int> messageLimits = [];

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    arguments[call.method] = call.arguments;

    final failure = failures[call.method];
    if (failure != null) {
      throw PlatformException(code: failure, message: 'test failure');
    }

    switch (call.method) {
      case 'getStatus':
        return status;
      case 'requestRole':
        return roleGranted;
      case 'getThreads':
        return threads;
      case 'getMessages':
        return _messagesFor(call.arguments);
      case 'getPending':
        return pending;
      case 'sendMessage':
        return sentRow;
      case 'markThreadRead':
        return 3;
      default:
        throw MissingPluginException(call.method);
    }
  }

  List<Map<String, Object?>> _messagesFor(Object? arguments) {
    final args = arguments as Map<Object?, Object?>?;
    final limit = args?['limit'] as int? ?? kSmsReadLimit;
    messageLimits.add(limit);

    final byThread = messagesByThread;
    final rows = byThread == null
        ? messages
        : byThread[args?['threadId'] as String?] ?? const [];
    return rows.length <= limit ? rows : rows.sublist(0, limit);
  }

  /// Pushes an event the way the platform does when Dart *is* listening.
  Future<void> emit(String event, Map<String, Object?> payload) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(event, payload),
          ),
          (_) {},
        );
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

/// A provider message row, with the fields a test cares about overridden.
Map<String, Object?> smsRow({
  String id = '11',
  String threadId = '7',
  String address = '+441234567890',
  String body = 'hello',
  int timestamp = 1700000000000,
  int type = SmsProviderType.inbox,
  int status = SmsProviderStatus.none,
  Object? subject,
  Object? attachmentUri,
  Object? attachmentMimeType,
  Object? attachmentSizeBytes,
}) => {
  'id': id,
  'threadId': threadId,
  'address': address,
  'body': body,
  'timestamp': timestamp,
  'type': type,
  'status': status,
  'subject': subject,
  'attachmentUri': attachmentUri,
  'attachmentMimeType': attachmentMimeType,
  'attachmentSizeBytes': attachmentSizeBytes,
};

/// A provider conversation row.
Map<String, Object?> smsThreadRow({
  String id = '7',
  List<String> addresses = const ['+441234567890'],
  Object? title,
  String snippet = 'see you at six',
  int unreadCount = 0,
  int lastMessageAt = 1700000000000,
  bool archived = false,
}) => {
  'id': id,
  'addresses': addresses,
  'title': title,
  'snippet': snippet,
  'unreadCount': unreadCount,
  'lastMessageAt': lastMessageAt,
  'archived': archived,
};
