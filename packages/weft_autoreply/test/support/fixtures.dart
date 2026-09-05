import 'package:clock/clock.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';

/// The fixed clock every test in this package reasons against.
///
/// Thursday 15 January 2026, 10:00 UTC. A weekday and a working hour, chosen so
/// the "inside an office-hours window" case is the default and the interesting
/// cases are the ones that step outside it. `package:clock` rather than a bare
/// `DateTime` because the engine's whole contract is that it decides from the
/// `now` it is handed — [decide] proves that by installing a clock set to a
/// *different* instant and checking nothing moves.
final Clock fixedClock = Clock.fixed(DateTime.utc(2026, 1, 15, 10));

/// 10:00 UTC on Thursday 15 January 2026.
final DateTime now = fixedClock.now();

/// The same wall-clock day at an arbitrary other minute, for tests that need a
/// second instant without re-deriving one.
DateTime at({int hour = 10, int minute = 0, int day = 15}) =>
    DateTime.utc(2026, 1, day, hour, minute);

/// A message with only what the engine cares about; everything else defaulted.
WeftMessage msg({
  String eventId = r'$event_1',
  String roomId = '!room:example.org',
  ChatNetwork network = ChatNetwork.whatsapp,
  String senderId = '@whatsapp_grace:example.org',
  String senderName = 'Grace',
  DateTime? timestamp,
  MessageKind kind = MessageKind.text,
  bool isOwn = false,
  bool isAutoReply = false,
  String body = 'are you around this afternoon?',
  String? transcript,
  bool redacted = false,
}) {
  return WeftMessage(
    eventId: eventId,
    roomId: roomId,
    network: network,
    senderId: senderId,
    senderName: senderName,
    timestamp: timestamp ?? now,
    kind: kind,
    isOwn: isOwn,
    isAutoReply: isAutoReply,
    body: body,
    transcript: transcript,
    redacted: redacted,
  );
}

/// A single-source chat.
Chat chat({
  String id = '!room:example.org',
  String title = 'Grace',
  ChatNetwork network = ChatNetwork.whatsapp,
  String? contactId,
  ChatRequestState? request,
}) {
  return Chat(
    id: id,
    title: title,
    contactId: contactId,
    request: request,
    sources: [ChatSource(roomId: id, network: network)],
  );
}

/// A merged chat: one contact, a WhatsApp leg and a Signal leg.
Chat mergedChat({String contactId = 'contact_1'}) => Chat(
  id: 'merged:$contactId',
  title: 'Grace',
  contactId: contactId,
  sources: const [
    ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
    ChatSource(roomId: '!sg:example.org', network: ChatNetwork.signal),
  ],
);

/// The conversation as the engine sees it, with the app-supplied facts
/// defaulted to the uninteresting answer.
AutoReplyChatState state({
  Chat? forChat,
  Set<String> labels = const {},
  bool isServiceChat = false,
  bool isBroadcast = false,
  List<AutoReplySent> recentReplies = const [],
}) {
  return AutoReplyChatState(
    chat: forChat ?? chat(),
    labels: labels,
    isServiceChat: isServiceChat,
    isBroadcast: isBroadcast,
    recentReplies: recentReplies,
  );
}

/// An enabled rule with a prompt, so a test states only the field it is about.
///
/// Enabled here and **disabled** in [AutoReplyRule]'s own default, deliberately:
/// production must never start replying from a half-filled form, and a test
/// that had to remember `enabled: true` on every rule would be a test file
/// where forgetting it looks like a passing guard.
AutoReplyRule rule({
  String id = 'rule_1',
  String name = 'Out of office',
  String prompt = 'Say I am away until Monday and will read this then.',
  AutoReplyAudience audience = const EveryoneAudience(),
  bool enabled = true,
  ReplyWindow? window,
  Duration cooldown = Duration.zero,
}) {
  return AutoReplyRule(
    id: id,
    name: name,
    prompt: prompt,
    audience: audience,
    enabled: enabled,
    window: window,
    cooldown: cooldown,
  );
}

/// The user, as the engine sees them.
const Set<String> ownUserIds = {'@ada:example.org', '@whatsapp_me:example.org'};

/// Calls [shouldReply] with the fixture user, under a clock deliberately set to
/// a *different* instant than [now].
///
/// The mismatch is the point. Every schedule and cooldown boundary in this
/// package has to be decided from the `now` that is passed in, because the
/// background push isolate has no reason to share the UI isolate's idea of the
/// time. Running the whole suite under a clock an hour off proves that nothing
/// inside quietly reaches for the ambient one.
AutoReplyDecision decide({
  WeftMessage? message,
  AutoReplyChatState? forChat,
  List<AutoReplyRule>? rules,
  DateTime? when,
}) {
  return withClock(
    Clock.fixed(DateTime.utc(2026, 6, 30, 3)),
    () => shouldReply(
      message: message ?? msg(),
      chat: forChat ?? state(),
      rules: rules ?? [rule()],
      now: when ?? now,
      ownUserIds: ownUserIds,
    ),
  );
}

/// Why [decision] sent nothing, or null when it plans a reply. Named so an
/// expectation reads as the rule it is about.
AutoReplyRefusal? reasonFor(AutoReplyDecision decision) => decision.refusal;

/// Office hours: 09:00 → 17:00 UTC, every day.
ReplyWindow officeHours({
  int offsetMinutes = 0,
  Set<int> weekdays = const {},
}) => ReplyWindow(
  startMinute: 9 * 60,
  endMinute: 17 * 60,
  offsetMinutes: offsetMinutes,
  weekdays: weekdays,
);

/// A window that wraps past midnight: 22:00 → 07:00.
ReplyWindow overnight({int offsetMinutes = 0, Set<int> weekdays = const {}}) =>
    ReplyWindow(
      startMinute: 22 * 60,
      endMinute: 7 * 60,
      offsetMinutes: offsetMinutes,
      weekdays: weekdays,
    );

/// An auto-reply the ledger already holds, [ago] before [now].
AutoReplySent sent({
  String ruleId = 'rule_1',
  Duration ago = Duration.zero,
  DateTime? from,
}) => AutoReplySent(ruleId: ruleId, at: (from ?? now).subtract(ago));
