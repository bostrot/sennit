import 'dart:async';
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
import 'package:weft/app/localisation.dart';

import 'support/recording_repository.dart';

/// Wraps the demo repository but reports every chat as having no reachable
/// rooms, standing in for a room the account has since left.
class _NoRoomsRepository implements ChatRepository {
  @override
  Future<void> retryFailedSend(String roomId, String eventId) async {}

  @override
  Future<void> discardFailedSend(String roomId, String eventId) async {}

  @override
  Future<void> forgetLocally(String roomId, String eventId) async {}

  @override
  Future<void> markUnread(String chatId) async {}

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
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) => const [];

  @override
  List<({String roomId, String eventId, DateTime at})> ownReadUpTo(
    String chatId,
  ) => const [];

  @override
  Future<ChatRequestState?> answerChatRequest(
    String chatId,
    ChatRequestAction action,
  ) => _inner.answerChatRequest(chatId, action);

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
    String? caption,
  }) => _inner.sendAttachment(
    chatId,
    source,
    via: via,
    isVoiceNote: isVoiceNote,
    caption: caption,
  );
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
  Future<void> sendThreadReply(
    String chatId,
    String body, {
    required String threadRootId,
    String? replyToEventId,
    String? threadLatestEventId,
  }) => _inner.sendThreadReply(
    chatId,
    body,
    threadRootId: threadRootId,
    replyToEventId: replyToEventId,
    threadLatestEventId: threadLatestEventId,
  );
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

/// The cold-start shape: an inbox that has not been folded together yet, and
/// then is.
///
/// This is what a notification tap lands in. The deep link routes to the chat
/// screen the moment the app is up, which is before the chat list exists — so
/// the conversation the link names is briefly absent, and [timelineFor]
/// answers exactly as the real repositories do for an id it has never heard
/// of.
class _SyncingRepository extends RecordingChatRepository {
  _SyncingRepository(DemoChatRepository super.inner);

  final _chats = StreamController<List<Chat>>.broadcast();
  var _synced = false;

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _synced ? await inner.watchChats().first : const [];
    yield* _chats.stream;
  }

  @override
  Chat? chatForRoom(String roomId) =>
      _synced ? inner.chatForRoom(roomId) : null;

  @override
  Future<MergedTimeline> timelineFor(String chatId) async {
    if (!_synced) throw ArgumentError.value(chatId, 'chatId', 'Unknown chat');
    return inner.timelineFor(chatId);
  }

  /// The first sync landing.
  Future<void> sync() async {
    _synced = true;
    _chats.add(await inner.watchChats().first);
  }

  Future<void> dispose() => _chats.close();
}

void main() {
  Future<void> pump(WidgetTester tester, ChatRepository repository, String id) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
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

  // Regression: tapping a notification that cold-started Sennit landed on
  // "not in your inbox" for a conversation that was perfectly present — the
  // deep link routes here before the chat list has been folded together, and
  // the screen took the first look as the verdict.
  testWidgets('a chat the inbox has not folded together yet is waited for', (
    tester,
  ) async {
    final repository = _SyncingRepository(DemoChatRepository());
    addTearDown(repository.dispose);

    await pump(tester, repository, 'merged:anna');
    // Not `pumpAndSettle`: the waiting screen is a spinner, which never
    // settles — which is the point of it.
    await tester.pump();
    await tester.pump();

    expect(
      find.text('That conversation is not in your inbox.'),
      findsNothing,
      reason: 'a chat still syncing is not a chat that is gone',
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Under a bar, which is what carries the way back once this screen is a
    // pushed route: the wait can last seconds, and a bare spinner is a dead
    // end for anyone who tapped the wrong notification.
    expect(find.byType(AppBar), findsOneWidget);

    await repository.sync();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Anna Maven'), findsWidgets);
  });

  // The link a notification actually carries is the chat's id *at the time it
  // was posted* — which for a chat merged since then names a room rather than
  // the conversation the inbox now holds.
  testWidgets('a room id that arrives inside a merged chat opens it', (
    tester,
  ) async {
    final repository = _SyncingRepository(DemoChatRepository());
    addTearDown(repository.dispose);

    await pump(tester, repository, '!anna_wa_room:example.org');
    await tester.pump();
    await tester.pump();

    expect(find.text('That conversation is not in your inbox.'), findsNothing);

    await repository.sync();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Anna Maven'), findsWidgets);
  });

  testWidgets('a chat that never arrives is called missing in the end', (
    tester,
  ) async {
    final repository = _SyncingRepository(DemoChatRepository());
    addTearDown(repository.dispose);

    await pump(tester, repository, 'merged:anna');
    await tester.pump();
    expect(find.text('That conversation is not in your inbox.'), findsNothing);

    // Past the grace period with nothing having turned up: the wait is
    // bounded, so a genuinely stale link still gets an answer.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('That conversation is not in your inbox.'),
      findsOneWidget,
    );
  });
}
