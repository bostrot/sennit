import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_remote/weft_remote.dart';

/// Method and event names of the phone ↔ browser protocol, shared by
/// [RemoteChatHost] and `RemoteChatRepository` so neither can drift.
abstract final class RemoteMethods {
  /// The host's pushed snapshot of everything the browser reads
  /// synchronously: chats, identity graph, ephemeral state, open timelines.
  static const String stateEvent = 'state';

  static const String hello = 'hello';
  static const String timelineOpen = 'timeline.open';
  static const String timelineMore = 'timeline.more';
  static const String timelineClose = 'timeline.close';
  static const String attachmentBytes = 'attachment.bytes';

  /// A picture the phone fetches with its own homeserver credentials — an
  /// avatar, a link preview. Only homeserver media; see `SennitWebServer`.
  static const String mediaFetch = 'media.fetch';

  /// Every [ChatRepository] call that takes plain values and returns nothing,
  /// forwarded by name.
  static const String send = 'send';
  static const String sendReply = 'sendReply';
  static const String sendThreadReply = 'sendThreadReply';
  static const String sendLocation = 'sendLocation';
  static const String sendCalendarInvite = 'sendCalendarInvite';
  static const String editCalendarInvite = 'editCalendarInvite';
  static const String respondCalendarInvite = 'respondCalendarInvite';
  static const String createPoll = 'createPoll';
  static const String votePoll = 'votePoll';
  static const String react = 'react';
  static const String unreact = 'unreact';
  static const String editMessage = 'editMessage';
  static const String redact = 'redact';
  static const String setSendNetwork = 'setSendNetwork';
  static const String markRead = 'markRead';
  static const String markUnread = 'markUnread';
  static const String markUnreadFrom = 'markUnreadFrom';
  static const String retryFailedSend = 'retryFailedSend';
  static const String discardFailedSend = 'discardFailedSend';
  static const String forgetLocally = 'forgetLocally';
  static const String setArchived = 'setArchived';
  static const String setMuted = 'setMuted';
  static const String deleteChat = 'deleteChat';
  static const String setTyping = 'setTyping';
  static const String mergeHandles = 'mergeHandles';
  static const String unmergeHandle = 'unmergeHandle';
  static const String rejectSuggestion = 'rejectSuggestion';
  static const String createDirectChat = 'createDirectChat';
  static const String createGroupChat = 'createGroupChat';
  static const String startBridgeChat = 'startBridgeChat';
  static const String answerChatRequest = 'answerChatRequest';
}

/// Error codes beyond [RemoteException]'s own, mapped back to the exception
/// types the screens already catch.
abstract final class RemoteErrors {
  /// An `ArgumentError` on the phone: the chat or event is not there (yet).
  static const String notFound = 'not_found';

  /// A `StateError` on the phone; its message is shown as is.
  static const String state = 'state';
}

/// Protocol version. The browser bundle is downloaded to match the app
/// version, so a mismatch means a stale cache — the hello says which.
const int kRemoteProtocolVersion = 1;

Map<String, Object?> decisionToJson(MergeDecision d) => {
  'pair': d.pair,
  'verdict': d.verdict.name,
  'source': d.source.name,
  'at': d.decidedAt.millisecondsSinceEpoch,
};

MergeDecision decisionFromJson(Map<String, Object?> j) => MergeDecision(
  pair: j['pair']! as String,
  verdict: j['verdict'] == MergeVerdict.merged.name
      ? MergeVerdict.merged
      : MergeVerdict.rejected,
  source: j['source'] == MergeDecisionSource.auto.name
      ? MergeDecisionSource.auto
      : MergeDecisionSource.user,
  decidedAt: DateTime.fromMillisecondsSinceEpoch(j['at']! as int, isUtc: true),
);

/// Shorthand used on both ends.
Map<String, Object?> messageJson(WeftMessage m) => DomainCodec.message(m);
