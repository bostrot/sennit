import 'dart:typed_data';

import 'package:weft/data/chat_repository.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

/// One relation action, as the UI asked for it.
///
/// What is worth recording is the *arguments*, not that a call happened: the
/// whole point of the reaction and reply routing is which event id the UI hands
/// down, and a spy that only counted calls could not tell a reaction sent to
/// the right message from one sent to whatever was last on screen.
class RecordedCall {
  const RecordedCall(this.method, {this.eventId, this.body, this.key});

  final String method;
  final String? eventId;
  final String? body;
  final String? key;

  @override
  String toString() =>
      'RecordedCall($method, eventId: $eventId, body: $body, key: $key)';
}

/// A [ChatRepository] that forwards everything and remembers the relations.
///
/// Wraps rather than replaces, so the timeline the widget under test renders is
/// still the real demo one — including the aggregation that turns a recorded
/// `react` into a chip. A stub would have to reimplement that to be useful, and
/// would then be asserting its own arithmetic.
class RecordingChatRepository implements ChatRepository {
  RecordingChatRepository(this.inner);

  final ChatRepository inner;

  final List<RecordedCall> calls = [];

  /// The arguments of the last call to [method], or null if it was never made.
  RecordedCall? lastCallTo(String method) =>
      calls.where((c) => c.method == method).lastOrNull;

  @override
  Future<void> send(String chatId, String body, {ChatNetwork? via}) {
    calls.add(RecordedCall('send', body: body));
    return inner.send(chatId, body, via: via);
  }

  @override
  Future<void> sendReply(
    String chatId,
    String body, {
    required String replyToEventId,
    ChatNetwork? via,
  }) {
    calls.add(RecordedCall('sendReply', eventId: replyToEventId, body: body));
    return inner.sendReply(
      chatId,
      body,
      replyToEventId: replyToEventId,
      via: via,
    );
  }

  @override
  Future<void> react(String chatId, String eventId, String key) {
    calls.add(RecordedCall('react', eventId: eventId, key: key));
    return inner.react(chatId, eventId, key);
  }

  @override
  Future<void> unreact(String chatId, String reactionEventId) {
    calls.add(RecordedCall('unreact', eventId: reactionEventId));
    return inner.unreact(chatId, reactionEventId);
  }

  @override
  Future<void> editMessage(String chatId, String eventId, String newBody) {
    calls.add(RecordedCall('editMessage', eventId: eventId, body: newBody));
    return inner.editMessage(chatId, eventId, newBody);
  }

  @override
  Future<void> redact(String chatId, String eventId) {
    calls.add(RecordedCall('redact', eventId: eventId));
    return inner.redact(chatId, eventId);
  }

  @override
  List<ChatNetwork> get availableNetworks => inner.availableNetworks;
  @override
  IdentityGraph get identityGraph => inner.identityGraph;
  @override
  Stream<List<Chat>> watchChats() => inner.watchChats();
  @override
  Chat? chatForRoom(String roomId) => inner.chatForRoom(roomId);
  @override
  Future<MergedTimeline> timelineFor(String chatId) =>
      inner.timelineFor(chatId);
  @override
  Future<void> mergeHandles(String a, String b) => inner.mergeHandles(a, b);
  @override
  Future<void> unmergeHandle(String handleId) => inner.unmergeHandle(handleId);
  @override
  Future<void> rejectSuggestion(String a, String b) =>
      inner.rejectSuggestion(a, b);
  @override
  void indexMessages(
    String chatId,
    List<WeftMessage> messages, {
    String chatTitle = '',
  }) => inner.indexMessages(chatId, messages, chatTitle: chatTitle);
  @override
  Future<void> setSendNetwork(String chatId, ChatNetwork network) =>
      inner.setSendNetwork(chatId, network);
  @override
  Future<void> markRead(String chatId) => inner.markRead(chatId);
  @override
  Future<void> setArchived(String chatId, {required bool archived}) =>
      inner.setArchived(chatId, archived: archived);
  @override
  Future<void> setMuted(String chatId, {required bool muted}) =>
      inner.setMuted(chatId, muted: muted);
  @override
  Future<void> deleteChat(String chatId) => inner.deleteChat(chatId);
  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) => inner.attachmentBytes(roomId, eventId, thumbnail: thumbnail);
  @override
  Future<AttachmentLocation?> attachmentLocation(
    String roomId,
    String eventId,
  ) => inner.attachmentLocation(roomId, eventId);
  @override
  Future<void> sendAttachment(
    String chatId,
    AttachmentSource source, {
    ChatNetwork? via,
    bool isVoiceNote = false,
    int? durationMs,
  }) =>
      inner.sendAttachment(chatId, source, via: via, isVoiceNote: isVoiceNote);
  @override
  Stream<List<UploadTask>> watchUploads(String chatId) =>
      inner.watchUploads(chatId);
  @override
  Future<void> retryUpload(String taskId) => inner.retryUpload(taskId);
  @override
  Future<void> cancelUpload(String taskId) => inner.cancelUpload(taskId);
}
