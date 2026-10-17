import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../data/auto_reply_transport.dart';
import 'auto_reply_writer.dart';
import 'conversation_context.dart';

/// One attempt, kept so the user can see what happened.
///
/// The alternative was a `debugPrint`, and a feature that sends messages on
/// someone's behalf must not fail where only a developer can see it. A user who
/// switched on a holiday responder and got silence needs to be able to find out
/// whether the model was unreachable, whether the conversation hit its cap, or
/// whether nothing matched at all — and each of those is a different thing to
/// go and fix.
@immutable
class AutoReplyAttempt {
  const AutoReplyAttempt({
    required this.chatId,
    required this.chatTitle,
    required this.at,
    this.outcome,
    this.refusal,
    this.ruleName,
    this.text,
  });

  final String chatId;
  final String chatTitle;
  final DateTime at;

  /// How the model and the transport did, or null when the engine refused
  /// before either was reached.
  final AutoReplyOutcome? outcome;

  /// Why the engine refused, or null when it did not.
  final AutoReplyRefusal? refusal;

  /// The rule that would have answered, when one was chosen.
  final String? ruleName;

  /// What was sent. Held only for a success, and only so the screen can show
  /// the last thing said on the user's behalf — which is the single most
  /// reassuring thing this screen can display.
  final String? text;

  bool get succeeded => outcome == AutoReplyOutcome.sent;

  /// Whether the screen offers to try this one again.
  ///
  /// Only the failures another go can fix: the model, the network or the
  /// transport let the user down. A decline was the model doing what it was
  /// told, a missing endpoint needs the endpoints screen, and the engine's
  /// refusals — the cap, the cooldown, the schedule — would refuse again.
  bool get canRetry => switch (outcome) {
    AutoReplyOutcome.refused ||
    AutoReplyOutcome.unreachable ||
    AutoReplyOutcome.timedOut ||
    AutoReplyOutcome.sendFailed => true,
    _ => false,
  };
}

/// How many more times a reply the model wrote outside the format is asked
/// for, before it is reported as [AutoReplyOutcome.refused].
///
/// One. A model at a non-zero temperature that missed the tags once mostly
/// finds them the second time; one that misses twice is misconfigured, and a
/// third request would only make the user wait longer to find out.
const int kAutoReplyFormatRetries = 1;

/// How many attempts are remembered.
///
/// In memory and bounded: this is a diagnostic, not a log. Persisting it would
/// mean writing every message the model wrote into the settings table, next to
/// the conversation it came from, which is a copy of the conversation nobody
/// asked for.
const int kAutoReplyAttemptHistory = 20;

/// Watches incoming messages, decides, writes, and sends without reading.
///
/// The orchestration only. Every decision is `shouldReply` in `weft_autoreply`,
/// every word is the user's own model through [composeAutoReply], and the send
/// is [AutoReplyTransport] — which is the one that carries the unread
/// guarantee. What is left here is sequencing and the things that need a
/// running app: the settings lookups, the rolling conversation context, and the
/// ledger.
///
/// Everything it depends on is injected as a function, the way
/// `MatrixNotificationPipeline` takes its policy: the rules, the labels and the
/// endpoint are all read *per message* rather than captured, so a rule switched
/// on affects the next message rather than the next launch.
class AutoReplyService {
  AutoReplyService({
    required Stream<WeftMessage> incoming,
    required AutoReplyTransport transport,
    required Chat? Function(String roomId) chatForRoom,
    required List<AutoReplyRule> Function() rules,
    required Set<String> Function(String chatId) labelsOf,
    required bool Function(String chatId) isServiceChat,
    required bool Function(Chat chat) isBroadcast,
    required Set<String> Function() ownUserIds,
    required AutoReplyEndpoint? Function() endpoint,
    required void Function(AutoReplyAttempt attempt) onAttempt,
    AutoReplyComposer? composer,
    AutoReplyLedger? ledger,
    DateTime Function()? now,
    Future<String?> Function(List<String> transcript)? calendar,
  }) : _incoming = incoming,
       _transport = transport,
       _chatForRoom = chatForRoom,
       _rules = rules,
       _labelsOf = labelsOf,
       _isServiceChat = isServiceChat,
       _isBroadcast = isBroadcast,
       _ownUserIds = ownUserIds,
       _endpoint = endpoint,
       _onAttempt = onAttempt,
       _composer = composer ?? composeAutoReply,
       _ledger = ledger ?? AutoReplyLedger(),
       _now = now ?? DateTime.now,
       _calendar = calendar;

  final Stream<WeftMessage> _incoming;
  final AutoReplyTransport _transport;
  final Chat? Function(String roomId) _chatForRoom;
  final List<AutoReplyRule> Function() _rules;
  final Set<String> Function(String chatId) _labelsOf;
  final bool Function(String chatId) _isServiceChat;
  final bool Function(Chat chat) _isBroadcast;
  final Set<String> Function() _ownUserIds;
  final AutoReplyEndpoint? Function() _endpoint;
  final void Function(AutoReplyAttempt attempt) _onAttempt;
  final AutoReplyComposer _composer;
  final AutoReplyLedger _ledger;
  final DateTime Function() _now;

  /// The calendar section for a transcript, or null — see
  /// `aiCalendarContext`. Asked once per attempt, before the first request, so
  /// a format retry is the same question asked again.
  final Future<String?> Function(List<String> transcript)? _calendar;

  StreamSubscription<WeftMessage>? _sub;

  /// Conversations with a reply in flight.
  ///
  /// A model takes seconds and a burst of three messages arrives in one. Without
  /// this each of them would start its own completion, and the cap would then be
  /// spent by a single paragraph split across three bubbles — every one of them
  /// past the ledger, because none of the replies had landed yet.
  final Set<String> _inFlight = <String>{};

  /// The last few messages per conversation, oldest first.
  ///
  /// Built from the stream rather than fetched from a timeline, and that is a
  /// privacy decision as much as a cost one: what is sent to the model is what
  /// the app has *seen arrive* this session, never history paginated out of the
  /// homeserver for the purpose. The same buffer the reply chips are given, so
  /// the two features disclose the same quantity of the same thing.
  final ConversationContext<WeftMessage> _context =
      ConversationContext<WeftMessage>();

  /// Starts watching. Idempotent.
  void start() {
    _sub ??= _incoming.listen(
      (message) => unawaited(handleMessage(message)),
      onError: (Object error) =>
          debugPrint('weft: auto-reply stream failed: $error'),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    // The buffer goes with the service: a disposed service is a signed-out or
    // reconfigured session, and nothing it had seen should outlive it.
    _context.clear();
  }

  /// Decides and, when a rule wins, writes and sends.
  ///
  /// Public because the dry-run preview goes through [preview] and the tests go
  /// through here: a path of its own would prove only that the path of its own
  /// works.
  Future<void> handleMessage(WeftMessage message) async {
    final chat = _chatForRoom(message.roomId);
    // No chat means the inbox has not folded this room yet — first sync, or a
    // room just joined. Nothing to reply *into*, and inventing a target is the
    // failure the whole `chatForRoom` seam exists to avoid.
    if (chat == null) return;

    _remember(chat.id, message);
    await _answer(chat, message);
  }

  /// Tries [chatId] again after a failed attempt.
  ///
  /// The settings screen's Retry. It answers the newest message the other
  /// side sent, through [shouldReply] like any other — a rule switched off
  /// since, a schedule that has closed or a cap that has filled refuses the
  /// retry the same way it would refuse a new message, so a tap cannot send
  /// what the rules would not.
  ///
  /// False, and nothing attempted, when there is nothing left to answer: the
  /// conversation is gone from this session's context, or the newest thing in
  /// it is already from the user's side — they answered themselves, or a
  /// reply went out after all.
  Future<bool> retry(String chatId) async {
    final recent = _context.of(chatId);
    if (recent.isEmpty) return false;
    final newest = recent.last;
    if (newest.isOwn || newest.isAutoReply) return false;
    final chat = _chatForRoom(newest.roomId);
    if (chat == null) return false;
    await _answer(chat, newest, reportEveryRefusal: true);
    return true;
  }

  /// [reportEveryRefusal] is for a retry the user asked for, where silence
  /// would read as the button doing nothing: "no rule covers this chat any
  /// more" is worth a log line when someone just tapped Retry on it.
  Future<void> _answer(
    Chat chat,
    WeftMessage message, {
    bool reportEveryRefusal = false,
  }) async {
    final decision = shouldReply(
      message: message,
      chat: _stateFor(chat),
      rules: _rules(),
      now: _now(),
      ownUserIds: _ownUserIds(),
    );

    final rule = decision.rule;
    if (rule == null) {
      // Only the refusals a user could act on are surfaced. "You sent that
      // yourself" and "no rule covers this chat" are true of almost every
      // message that arrives, and a log full of them would bury the one entry
      // that matters.
      if (reportEveryRefusal || _isWorthReporting(decision.refusal)) {
        _report(chat: chat, refusal: decision.refusal);
      }
      return;
    }

    // One completion per conversation at a time.
    if (!_inFlight.add(chat.id)) return;
    try {
      final draft = await _write(rule, chat);
      if (draft.text == null) {
        _report(chat: chat, outcome: draft.outcome, ruleName: rule.name);
        return;
      }

      final String? eventId;
      try {
        eventId = await _transport.sendAutoReply(chat.id, draft.text!);
      } on Object catch (error) {
        debugPrint('weft: auto-reply to ${chat.id} would not send: $error');
        _report(
          chat: chat,
          outcome: AutoReplyOutcome.sendFailed,
          ruleName: rule.name,
        );
        return;
      }

      final at = _now();
      _ledger.record(
        chat.id,
        AutoReplySent(ruleId: rule.id, at: at, eventId: eventId),
      );
      // Into the context too, so the next message in the conversation is
      // answered in the light of what was already said on the user's behalf.
      _remember(
        chat.id,
        WeftMessage(
          eventId: eventId ?? 'local:auto-reply',
          roomId: chat.sources.first.roomId,
          network: chat.sendNetwork ?? chat.sources.first.network,
          senderId: '',
          senderName: '',
          timestamp: at,
          kind: MessageKind.text,
          isOwn: true,
          isAutoReply: true,
          body: draft.text!,
        ),
      );
      _report(
        chat: chat,
        outcome: AutoReplyOutcome.sent,
        ruleName: rule.name,
        text: draft.text,
      );
    } finally {
      _inFlight.remove(chat.id);
    }
  }

  /// Writes a reply for [chat] under [rule] without sending it.
  ///
  /// The settings screen's dry run. It goes through the same [composeAutoReply]
  /// with the same context slice as the real path, so what it shows is what
  /// would have been sent — and it deliberately skips [shouldReply], because
  /// the point of a preview is to tune a prompt at three in the afternoon for a
  /// rule that only fires at night.
  Future<AutoReplyDraft> preview(AutoReplyRule rule, Chat chat) =>
      _write(rule, chat);

  Future<AutoReplyDraft> _write(AutoReplyRule rule, Chat chat) async {
    final endpoint = _endpoint();
    if (endpoint == null) {
      return const AutoReplyDraft.failed(AutoReplyOutcome.notConfigured);
    }
    final transcript = transcriptFor(chat.id);
    final calendar = await _calendarFor(transcript);
    Future<AutoReplyDraft> ask() => _composer(
      baseUrl: endpoint.baseUrl,
      model: endpoint.model,
      apiKey: endpoint.apiKey,
      instruction: rule.prompt,
      chatTitle: chat.title,
      transcript: transcript,
      calendar: calendar,
    );

    var draft = await ask();
    // Only a format miss is asked for again — see [kAutoReplyFormatRetries].
    // An empty transcript is refused before any request and would be again.
    for (
      var retry = 0;
      retry < kAutoReplyFormatRetries &&
          draft.outcome == AutoReplyOutcome.refused &&
          transcript.isNotEmpty;
      retry++
    ) {
      debugPrint('weft: auto-reply: asking ${chat.id} again after a refusal');
      draft = await ask();
    }
    return draft;
  }

  /// A calendar that cannot be read is no calendar: the reply still goes out,
  /// it just cannot say whether Friday works.
  Future<String?> _calendarFor(List<String> transcript) async {
    final calendar = _calendar;
    if (calendar == null || transcript.isEmpty) return null;
    try {
      return await calendar(transcript);
    } on Object catch (error) {
      debugPrint('weft: auto-reply: calendar unavailable: $error');
      return null;
    }
  }

  /// The conversation slice that would be sent to the model, oldest first.
  ///
  /// Exposed so the settings screen can say how much is disclosed and a test
  /// can assert the bound without reaching into the buffer.
  List<String> transcriptFor(String chatId) =>
      transcriptLinesFor(_context.of(chatId));

  AutoReplyChatState _stateFor(Chat chat) => AutoReplyChatState(
    chat: chat,
    labels: _labelsOf(chat.id),
    isServiceChat: _isServiceChat(chat.id),
    isBroadcast: _isBroadcast(chat),
    recentReplies: _ledger.repliesIn(chat.id, now: _now()),
  );

  void _remember(String chatId, WeftMessage message) =>
      _context.remember(chatId, message);

  /// Whether a refusal is one the user would want to see.
  ///
  /// The five that are: the model is off, the conversation is capped, it is
  /// cooling, the schedule is closed, or a rule matched and something else
  /// stopped it. Everything before those is true of ordinary traffic — the
  /// user's own messages, every chat with no rule — and reporting them would
  /// leave a screen where the interesting line is never on it.
  static bool _isWorthReporting(AutoReplyRefusal? refusal) => switch (refusal) {
    AutoReplyRefusal.conversationCap ||
    AutoReplyRefusal.cooling ||
    AutoReplyRefusal.outsideSchedule => true,
    _ => false,
  };

  void _report({
    required Chat chat,
    AutoReplyOutcome? outcome,
    AutoReplyRefusal? refusal,
    String? ruleName,
    String? text,
  }) {
    _onAttempt(
      AutoReplyAttempt(
        chatId: chat.id,
        chatTitle: chat.title,
        at: _now(),
        outcome: outcome,
        refusal: refusal,
        ruleName: ruleName,
        text: text,
      ),
    );
  }
}

/// The user's endpoint, resolved once per attempt.
@immutable
class AutoReplyEndpoint {
  const AutoReplyEndpoint({
    required this.baseUrl,
    required this.model,
    this.apiKey,
  });

  final String baseUrl;
  final String model;
  final String? apiKey;

  /// The endpoint, or null when nothing is configured — the same test
  /// `notifications_screen.dart` applies before offering reply chips, so the
  /// two features agree about what "an LLM is set up" means.
  static AutoReplyEndpoint? resolve({
    required String? baseUrl,
    required String? model,
    String? apiKey,
  }) {
    final url = (baseUrl ?? '').trim();
    final name = (model ?? '').trim();
    if (url.isEmpty || name.isEmpty) return null;
    return AutoReplyEndpoint(baseUrl: url, model: name, apiKey: apiKey);
  }
}

/// [composeAutoReply]'s shape, so a test can supply a model that answers
/// instantly and a screen can supply one that never fails.
typedef AutoReplyComposer =
    Future<AutoReplyDraft> Function({
      required String baseUrl,
      required String model,
      String? apiKey,
      required String instruction,
      required String chatTitle,
      required List<String> transcript,
      String? calendar,
    });
