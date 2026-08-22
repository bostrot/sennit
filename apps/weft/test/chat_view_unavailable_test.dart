import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

/// Wraps the demo repository but reports every chat as having no reachable
/// rooms, standing in for a room the account has since left.
class _NoRoomsRepository implements ChatRepository {
  @override
  Future<String?> createDirectChat(String matrixUserId) async => null;

  @override
  Future<String?> createGroupChat(
    String name,
    List<String> inviteMatrixIds,
  ) async => null;

  @override
  Future<bool> startBridgeChat(ChatNetwork network, String identifier) async =>
      false;

  @override
  List<String> typingIn(String chatId) => const [];

  @override
  Future<void> setTyping(String chatId, {required bool typing}) async {}

  @override
  ({bool online, DateTime? lastActiveAt})? presenceFor(String chatId) => null;

  @override
  Future<void> editCalendarInvite(
    String roomId,
    String inviteEventId, {
    required String title,
    required DateTime start,
    DateTime? end,
  }) async {}

  @override
  List<({String roomId, String eventId, DateTime at})> peerReadUpTo(
    String chatId,
  ) => const [];

  @override
  void setContactNameOverrides(Map<String, String> namesByPhoneDigits) {}

  @override
  String? avatarUrlFor(String userId, {String? roomId}) => null;

  @override
  int get timelineEpoch => 0;

  @override
  Future<void> sendCalendarInvite(
    String chatId, {
    required String title,
    required DateTime start,
    DateTime? end,
    ChatNetwork? via,
  }) async {}

  @override
  Future<void> respondCalendarInvite(
    String roomId,
    String inviteEventId, {
    required CalendarReply reply,
    DateTime? proposedStart,
  }) async {}

  @override
  Future<void> createPoll(
    String chatId, {
    required String question,
    required List<String> options,
    ChatNetwork? via,
  }) async {}

  @override
  Future<void> votePoll(
    String roomId,
    String startEventId,
    Set<String> answerIds,
  ) async {}

  @override
  Set<String> get serviceChatIds => const {};

  @override
  Future<void> sendLocation(
    String chatId, {
    required double latitude,
    required double longitude,
    ChatNetwork? via,
  }) async {}

  _NoRoomsRepository(this._inner);

  final DemoChatRepository _inner;

  @override
  Future<MergedTimeline> timelineFor(String chatId) async =>
      throw StateError('Chat $chatId has no reachable rooms');

  @override
  List<ChatNetwork> get availableNetworks => _inner.availableNetworks;
  @override
  IdentityGraph get identityGraph => _inner.identityGraph;
  @override
  Stream<List<Chat>> watchChats() => _inner.watchChats();
  @override
  Chat? chatForRoom(String roomId) => _inner.chatForRoom(roomId);
  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) =>
      _inner.send(chatId, body, via: via);
  @override
  Future<void> setSendNetwork(String chatId, ChatNetwork network) =>
      _inner.setSendNetwork(chatId, network);
  @override
  Future<void> markRead(String chatId) => _inner.markRead(chatId);
  @override
  Future<void> mergeHandles(String a, String b) => _inner.mergeHandles(a, b);
  @override
  Future<void> unmergeHandle(String h) => _inner.unmergeHandle(h);
  @override
  Future<void> rejectSuggestion(String a, String b) =>
      _inner.rejectSuggestion(a, b);
  @override
  void indexMessages(
    String chatId,
    List<WeftMessage> messages, {
    String chatTitle = '',
  }) {}
  @override
  Future<void> setArchived(String chatId, {required bool archived}) =>
      _inner.setArchived(chatId, archived: archived);
  @override
  Future<void> setMuted(String chatId, {required bool muted}) =>
      _inner.setMuted(chatId, muted: muted);
  @override
  Future<void> deleteChat(String chatId) => _inner.deleteChat(chatId);
  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) => _inner.attachmentBytes(roomId, eventId, thumbnail: thumbnail);
  @override
  Future<AttachmentLocation?> attachmentLocation(
    String roomId,
    String eventId,
  ) => _inner.attachmentLocation(roomId, eventId);
  @override
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
    int? durationMs,
  }) =>
      _inner.sendAttachment(chatId, source, via: via, isVoiceNote: isVoiceNote);
  @override
  Stream<List<UploadTask>> watchUploads(String chatId) =>
      _inner.watchUploads(chatId);
  @override
  Future<void> retryUpload(String taskId) => _inner.retryUpload(taskId);
  @override
  Future<void> cancelUpload(String taskId) => _inner.cancelUpload(taskId);
  @override
  Future<void> sendReply(
    String chatId,
    String body, {
    required String replyToEventId,
    ChatNetwork? via,
  }) =>
      _inner.sendReply(chatId, body, replyToEventId: replyToEventId, via: via);
  @override
  Future<void> react(String chatId, String eventId, String key) =>
      _inner.react(chatId, eventId, key);
  @override
  Future<void> unreact(String chatId, String reactionEventId) =>
      _inner.unreact(chatId, reactionEventId);
  @override
  Future<void> editMessage(String chatId, String eventId, String newBody) =>
      _inner.editMessage(chatId, eventId, newBody);
  @override
  Future<void> redact(String chatId, String eventId) =>
      _inner.redact(chatId, eventId);
}

void main() {
  Future<void> pump(WidgetTester tester, ChatRepository repository, String id) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: ChatView(chatId: id),
        ),
      ),
    );
  }

  // Regression: a deep link to an unknown chat used to throw
  // `Invalid argument (chatId): Unknown chat` as an unhandled async exception.
  // Found by firing `weft://chat/!abc:example.org` at a real device.
  testWidgets('an unknown chat id renders a message, not an exception', (
    tester,
  ) async {
    await pump(tester, DemoChatRepository(), '!does-not-exist:example.org');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('That conversation is not in your inbox.'),
      findsOneWidget,
    );
  });

  testWidgets('a chat whose rooms are gone explains itself', (tester) async {
    await pump(tester, _NoRoomsRepository(DemoChatRepository()), 'merged:anna');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('no reachable rooms'), findsOneWidget);
  });

  testWidgets('a known chat still opens normally', (tester) async {
    await pump(tester, DemoChatRepository(), 'merged:anna');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Anna Maven'), findsWidgets);
  });
}
