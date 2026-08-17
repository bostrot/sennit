import 'dart:async';

import 'package:weft/services/notifications/notification_presentation.dart';
import 'package:weft/services/notifications/notification_service.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// The two fakes the notification path needs to run with no device and no
/// homeserver.
///
/// Shared rather than private to one suite because `notification_service_test`
/// and `notifications_screen_test` both drive the *same* chain — the screen's
/// "Send test notification" button posts through the very service the other
/// file exercises — and two copies of a recording sink would be two things to
/// keep in step. A rule that fired under one file's fake and not the other's
/// would read as a real difference between the suites.

/// A [NotificationSink] that records instead of posting.
class RecordingNotificationSink implements NotificationSink {
  final List<NotificationPresentation> shown = [];
  final List<({int id, String? tag})> cancelled = [];
  final List<({String id, String label, String link})> shortcuts = [];

  NotificationActivation? launch;
  void Function(NotificationActivation)? _onActivation;

  /// Fires the callback the platform would fire when a notification is tapped.
  void activate(
    NotificationPresentation presentation, {
    String? actionId,
    String? input,
  }) {
    _onActivation?.call(
      NotificationActivation(
        payload: NotificationPayload.decode(presentation.payload.encode())!,
        actionId: actionId,
        input: input,
      ),
    );
  }

  @override
  Future<void> initialize(
    void Function(NotificationActivation) onActivation,
  ) async {
    _onActivation = onActivation;
  }

  @override
  Future<NotificationActivation?> launchActivation() async => launch;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(NotificationPresentation presentation) async =>
      shown.add(presentation);

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelled.add((id: id, tag: tag));

  @override
  Future<void> publishConversationShortcut({
    required String id,
    required String label,
    required String link,
    String? iconPath,
  }) async => shortcuts.add((id: id, label: label, link: link));
}

/// A [MatrixNotificationSession] with no homeserver behind it.
class FakeNotificationSession implements MatrixNotificationSession {
  /// Event id → the message `messageFor` answers with. What a push path finds
  /// when it goes looking for the event it was poked about.
  final Map<String, WeftMessage> messages = {};

  final _incoming = StreamController<WeftMessage>.broadcast();

  /// Publishes a message on the sync path.
  void deliver(WeftMessage message) => _incoming.add(message);

  Future<void> close() => _incoming.close();

  @override
  Set<String> get ownUserIds => {'@me:example.org'};

  @override
  Set<String> get ownDisplayNames => {'Me'};

  @override
  Stream<WeftMessage> get incomingMessages => _incoming.stream;

  @override
  Future<WeftMessage?> messageFor({
    required String roomId,
    required String eventId,
  }) async => messages[eventId];

  @override
  DateTime? lastReadAt(String roomId) => null;
}
