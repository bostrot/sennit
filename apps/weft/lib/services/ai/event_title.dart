import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:weft_domain/weft_domain.dart';

import 'conversation_context.dart' show kAiContextMessages;
import 'llm_budget.dart';
import 'llm_request.dart';

/// How many messages of the conversation the title model is shown, the one
/// with the date included.
///
/// Under [kAiContextMessages], which is the most any AI feature may send: a
/// title needs the plan, not the afternoon. Sixteen lines is the exchange a
/// date is usually settled in — "we should try Luigi's" six messages before
/// "friday at 7?" — which is the whole reason to send more than one message.
const int kEventTitleContextMessages = 16;

/// How many of those may come *after* the message with the date. "Perfect,
/// I'll book a table at Luigi's" is often where the place is named.
const int kEventTitleFollowingMessages = 4;

/// The character budget for the transcript, a few hundred tokens: small
/// enough for a phone-sized local model to read inside the timeout.
const int kEventTitleContextChars = 2400;

/// The longest a single line may be before it is cut, so one pasted article
/// cannot spend the whole budget.
const int _lineChars = 300;

/// What marks the message the chip is under in the transcript.
const String kEventTitleMarker = '>>';

/// The conversation around [trigger] as the title prompt reads it: one
/// `Name: text` line per message, oldest first, with [trigger]'s line marked
/// [kEventTitleMarker].
///
/// Both sides, because a plan is made by both: "Luigi's?" from the user and
/// "yes! friday at 7?" from Sam is one appointment, and the half with the date
/// rarely has the rest. `You` for the user, as in `transcriptLinesFor`, so the
/// endpoint reads the same speaker the other prompts use.
///
/// Centred on [trigger] rather than on the newest message: a chip on last
/// week's message is about last week's conversation. A thread reply is read
/// with its own thread, and a room message with the room — thread replies
/// there are other conversations. The message [trigger] replies to is kept
/// even when it is older than the window, since it is what "yes, let's do
/// that" means.
///
/// Only what a person said: no redacted messages, bridge notices, auto-replies
/// or attachments without words. Edits are already applied to the body, so
/// their old versions never appear; the quoted reply fallback some clients
/// prepend is dropped, since the target is its own line.
List<String> eventTitleTranscript(
  WeftMessage trigger,
  Iterable<WeftMessage> conversation, {
  int maxMessages = kEventTitleContextMessages,
  int maxFollowing = kEventTitleFollowingMessages,
  int maxChars = kEventTitleContextChars,
}) {
  assert(maxMessages > 0 && maxMessages <= kAiContextMessages);
  final root = trigger.threadRootId;
  bool sameConversation(WeftMessage m) => root != null
      ? m.threadRootId == root || m.eventId == root
      : m.threadRootId == null;

  final byId = <String, WeftMessage>{};
  for (final m in conversation) {
    if (m.eventId == trigger.eventId) continue;
    if (sameConversation(m) && _wordsOf(m) != null) {
      byId.putIfAbsent(m.eventId, () => m);
    }
  }
  final ordered = [...byId.values, trigger]..sort(_chronological);
  final at = ordered.indexOf(trigger);
  final following = ordered
      .skip(at + 1)
      .take(maxFollowing.clamp(0, maxMessages - 1))
      .toList();
  final preceding = ordered
      .sublist(0, at)
      .reversed
      .take(maxMessages - 1 - following.length)
      .toList()
      .reversed
      .toList();

  // The message being answered, when it fell outside the window.
  String? replied;
  final targetId = trigger.replyToEventId?.trim();
  if (targetId != null && !preceding.any((m) => m.eventId == targetId)) {
    final target = conversation
        .where((m) => m.eventId == targetId && _wordsOf(m) != null)
        .firstOrNull;
    final preview = trigger.replyPreview;
    if (target != null) {
      replied = _line(target, _lineChars);
    } else if (preview != null &&
        !preview.isStub &&
        !preview.redacted &&
        preview.body.trim().isNotEmpty) {
      replied = _format(
        preview.senderName ?? '',
        preview.body,
        _lineChars,
        own: false,
      );
    }
    if (replied != null) {
      replied = '(replied to) $replied';
      if (preceding.length + following.length + 1 >= maxMessages &&
          preceding.isNotEmpty) {
        preceding.removeAt(0);
      }
    }
  }

  final before = [for (final m in preceding) _line(m, _lineChars)];
  final marked = '$kEventTitleMarker ${_line(trigger, _lineChars * 2)}';
  final after = [for (final m in following) _line(m, _lineChars)];

  // Over budget: the lines farthest back go first, then the last ones after.
  int length() => [
    ...before,
    marked,
    ...after,
    ?replied,
  ].fold(0, (n, l) => n + l.length + 1);
  while (length() > maxChars && (before.isNotEmpty || after.isNotEmpty)) {
    if (before.isNotEmpty) {
      before.removeAt(0);
    } else {
      after.removeLast();
    }
  }
  return [?replied, ...before, marked, ...after];
}

/// The newest of [conversation] as a prompt reads it: one `Name: text` line
/// per message, oldest first, with no message marked.
///
/// [eventTitleTranscript] without a trigger, for a feature that writes the
/// *next* message rather than naming an earlier one — the room's latest
/// exchange, thread replies left out as they are there. The same filter and
/// the same line shape, so every prompt reads one kind of transcript, and the
/// same budget rule: lines farthest back go first.
List<String> recentConversationTranscript(
  Iterable<WeftMessage> conversation, {
  int maxMessages = kEventTitleContextMessages,
  int maxChars = kEventTitleContextChars,
}) {
  // Not bound by `kAiContextMessages`: learning from a chat reads hundreds
  // of messages when the model's window has room for them.
  assert(maxMessages > 0);
  final byId = <String, WeftMessage>{};
  for (final m in conversation) {
    if (m.threadRootId == null && _wordsOf(m) != null) {
      byId.putIfAbsent(m.eventId, () => m);
    }
  }
  final ordered = byId.values.toList()..sort(_chronological);
  final lines = [
    for (final m in ordered.skip(
      ordered.length > maxMessages ? ordered.length - maxMessages : 0,
    ))
      _line(m, _lineChars),
  ];
  var length = lines.fold(0, (n, l) => n + l.length + 1);
  while (length > maxChars && lines.length > 1) {
    length -= lines.removeAt(0).length + 1;
  }
  return lines;
}

int _chronological(WeftMessage a, WeftMessage b) {
  final byTime = a.timestamp.compareTo(b.timestamp);
  return byTime != 0 ? byTime : a.eventId.compareTo(b.eventId);
}

/// What [m] says in words, or null when it is nothing a person said.
String? _wordsOf(WeftMessage m) {
  if (m.redacted || m.isBridgeNotice || m.isAutoReply) return null;
  final String raw;
  switch (m.kind) {
    case MessageKind.text:
      raw = m.body;
    case MessageKind.voice || MessageKind.audio:
      raw = m.transcript ?? '';
    default:
      return null;
  }
  var text = raw;
  // The spec's reply fallback: "> <@sam:x> quoted" lines, then a blank one.
  if (m.replyToEventId != null) {
    text = text.replaceFirst(RegExp(r'^(?:>[^\n]*\n)+\n?'), '');
  }
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? null : text;
}

String _line(WeftMessage m, int limit) =>
    _format(m.senderName, _wordsOf(m) ?? m.body, limit, own: m.isOwn);

String _format(String sender, String text, int limit, {required bool own}) {
  final name = own
      ? 'You'
      : (sender.trim().isEmpty ? 'Someone' : sender.trim());
  var words = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (words.length > limit) words = '${words.substring(0, limit - 1)}…';
  return '$name: $words';
}

/// Asks the configured LLM what to call the appointment a conversation is
/// about.
///
/// [transcript] is [eventTitleTranscript]'s output. The same
/// OpenAI-compatible chat completions call as [suggestSmartReplies], for the
/// same reason. Returns null on any failure: the caller already has a
/// rule-made title, and a calendar entry is not the place for an error.
Future<String?> suggestEventTitle({
  required String baseUrl,
  required String model,
  String? apiKey,
  required List<String> transcript,
  LlmBudget? budget,
  http.Client? client,
  Duration? timeout,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || transcript.isEmpty) {
    return null;
  }
  final room = (budget ?? LlmBudget.resolve(base)).forFeature(
    AiFeature.eventTitle,
  );
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? llmHttpClient();
  try {
    final answer = await requestCompletion(
      httpClient,
      url,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: {
        'model': model,
        'temperature': 0.2,
        'messages': [
          {
            'role': 'system',
            'content':
                'You name calendar events. You are given a chat, oldest '
                'message first. "You" is the user; every other name is '
                'someone they are talking to. The line marked '
                '"$kEventTitleMarker" is the message that set the date; '
                'the lines around it say what the plan is. Output ONLY a '
                'JSON object with a "title" string — no analysis, no '
                'commentary, no markdown. The title says what the event '
                'is, and with whom and where when the chat says so: '
                '"Dinner with Sam at Luigi\'s", not "Meeting". At most '
                'eight words, in the same language as the chat, without '
                'the date or time, never "You" and never a copied '
                'message.',
          },
          // Worked examples, as in the reply prompt: they pin the format
          // and leave no placeholder to parrot back. The second has
          // nothing in the marked line but the time — the title is in
          // the lines around it, which is what the examples must teach.
          {
            'role': 'user',
            'content':
                'Chat:\nLea: Hast du nächste Woche Zeit?\n'
                'You: Dienstag geht, warum?\n'
                '$kEventTitleMarker Lea: Dann lass uns um 14:30 zusammen '
                'zum Zahnarzt gehen, ich hab Angst 😅\n'
                'You: Klar, ich komm mit\n\nJSON:',
          },
          {'role': 'assistant', 'content': '{"title": "Zahnarzt mit Lea"}'},
          {
            'role': 'user',
            'content':
                'Chat:\nSam: we should finally try that new italian '
                'place\n'
                'You: Luigi\'s? heard it\'s great\n'
                '$kEventTitleMarker Sam: yes! friday at 7?\n'
                'You: perfect, I\'ll book a table\n\nJSON:',
          },
          {
            'role': 'assistant',
            'content': '{"title": "Dinner with Sam at Luigi\'s"}',
          },
          {
            'role': 'user',
            'content': 'Chat:\n${transcript.join('\n')}\n\nJSON:',
          },
        ],
      },
      maxTokens: room.maxTokens,
      retryMaxTokens: room.retryMaxTokens,
      answered: (content) => parseEventTitle(content) != null,
      timeout: timeout ?? llmResponseTimeout(base, LlmTask.eventTitle),
      what: 'event title',
    );
    if (!answer.ok) {
      debugPrint('weft: event title: $url answered ${answer.status}');
      return null;
    }
    final content = answer.content;
    if (content == null) {
      debugPrint('weft: event title: no content in the completion');
      return null;
    }
    final title = parseEventTitle(content);
    if (title == null) {
      debugPrint('weft: event title: nothing usable in ${jsonEncode(content)}');
    }
    return title;
  } on Object catch (error) {
    debugPrint('weft: event title against $url failed: $error');
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// Pulls the title out of whatever the model said, or null.
///
/// JSON or nothing, as with reply chips: a model's untagged reasoning must
/// not become the name of somebody's dentist appointment.
String? parseEventTitle(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return null;
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final Object? parsed;
  try {
    parsed = jsonDecode(text.substring(start, end + 1));
  } on FormatException {
    return null;
  }
  if (parsed is! Map || parsed['title'] is! String) return null;

  final title = (parsed['title'] as String).trim().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );
  if (title.isEmpty || title.length > 60) return null;
  if (title.contains('<') || title.contains('>') || title.contains('**')) {
    return null;
  }
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(title)) return null;
  return title;
}

/// Words that name no event in particular: a title that is only one of these
/// tells the calendar nothing its own "new event" placeholder would not.
const _genericTitles = {
  'appointment',
  'call',
  'calendar event',
  'date',
  'event',
  'meeting',
  'meetup',
  'new event',
  'plan',
  'plans',
  'reminder',
  'untitled',
  'besprechung',
  'ereignis',
  'erinnerung',
  'termin',
  'treffen',
  'veranstaltung',
  'verabredung',
  'événement',
  'evenement',
  'rappel',
  'rendez-vous',
  'rendez vous',
  'réunion',
  'reunion',
  'cita',
  'evento',
  'recordatorio',
  'reunión',
  'compromisso',
  'encontro',
  'lembrete',
  'reunião',
  '会议',
  '活动',
  '提醒',
  '约会',
  '见面',
};

/// Whether [title] says nothing about the event: a bare "Meeting", or
/// [message] copied out rather than named.
bool isGenericEventTitle(String title, {String? message}) {
  String plain(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s-]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final t = plain(title);
  if (t.isEmpty || _genericTitles.contains(t)) return true;
  if (message == null) return false;
  final m = plain(message);
  if (m.isEmpty) return false;
  // A short message may well *be* its title — "Zahnarzt" is both. A long one
  // repeated back is a model that did not name anything.
  return t.split(' ').length > 5 && m.startsWith(t);
}

/// The title to use: [model]'s when it names something, else [fallback], the
/// rule-made one.
String chooseEventTitle({
  required String? model,
  required String fallback,
  String? message,
}) {
  if (model == null || isGenericEventTitle(model, message: message)) {
    return fallback;
  }
  return model;
}
