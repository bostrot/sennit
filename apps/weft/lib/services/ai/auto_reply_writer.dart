import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'llm_budget.dart';
import 'llm_request.dart';
import 'person_memory.dart' show AiMemory, memoryPromptBlock;
import 'smart_replies.dart' show calendarPromptBlock;

/// How an attempt to write an auto-reply ended.
///
/// A code rather than a sentence, for the reason every other package in this
/// workspace answers in codes: the words belong to the ARB and the switch that
/// turns one into the other lives in `app/l10n_labels.dart`. The English on
/// each case here is what a `debugPrint` shows, not what a user reads.
///
/// Every value except [AutoReplyOutcome.sent] means **nothing was sent**. Only
/// [AutoReplyOutcome.refused] is retried on its own, once, by the service: a
/// model sampled at a non-zero temperature that missed the format once mostly
/// hits it the second time. The rest are not — a model that timed out once
/// will time out again while the same message is the newest one, and a retry
/// loop against someone else's Ollama is a way to make a phone hot. Those wait
/// for the user's Retry on the settings screen.
enum AutoReplyOutcome {
  /// A reply was written and handed to the transport.
  sent,

  /// No endpoint or no model name. The feature is dormant, not broken.
  notConfigured,

  /// The endpoint could not be reached, or answered something other than 200.
  unreachable,

  /// The endpoint took longer than the deadline.
  timedOut,

  /// The model answered, but with nothing usable — reasoning it never came out
  /// of, an empty string, or anything outside the answer format.
  refused,

  /// The model stopped at the answer length before it wrote an answer, even
  /// after being asked again with more room — a thinking model still
  /// thinking.
  cutOff,

  /// The model answered in the format and chose not to reply, because the
  /// user's instruction or the conversation said no message should go out.
  declined,

  /// A reply was written and the transport would not send it.
  sendFailed,
}

/// A written reply, or the reason there is not one.
@immutable
class AutoReplyDraft {
  const AutoReplyDraft.written(String this.text)
    : outcome = AutoReplyOutcome.sent;

  const AutoReplyDraft.failed(this.outcome) : text = null;

  final AutoReplyOutcome outcome;

  /// The words to send, or null. Non-null exactly when [outcome] is
  /// [AutoReplyOutcome.sent].
  final String? text;

  @override
  String toString() => text == null
      ? 'AutoReplyDraft.failed(${outcome.name})'
      : 'AutoReplyDraft.written(${text!.length} chars)';
}

/// The longest auto-reply that will be sent.
///
/// A ceiling on someone else's model, which is the only place it can be
/// imposed: `max_tokens` is a request, not a promise, and a local model that
/// ignores it writes an essay. Six hundred characters is a long chat message
/// and a short paragraph — past that the words are not a reply any more.
const int kAutoReplyMaxChars = 600;

/// Asks the configured LLM to write one reply, following the user's prompt.
///
/// A sibling of `suggestSmartReplies` rather than a parameter on it, because
/// the two want different answers from the same endpoint: chips want a JSON
/// array of eight-word fragments, and this wants one message in prose. Sharing
/// a function would mean a format contract that fits neither.
///
/// [instruction] is the user's own rule prompt, put in the system message
/// verbatim. Not templated, not sanitised, not wrapped in advice — it is the
/// whole feature, and a client that quietly edited it would be answering for
/// something the user did not write.
///
/// [transcript] is a bounded slice of recent conversation, oldest first, each
/// line already `Name: what they said`. Bounded by the caller, at
/// `kAiContextMessages` — it is the quantity of conversation that leaves the
/// device on every reply, so it is decided in one place for every AI feature
/// and not here.
///
/// [calendar] is the user's busy times as `calendarPromptSection` writes them,
/// or null. Given only when the conversation is about when someone is free, so
/// "are you around on Friday?" is answered from the calendar instead of
/// guessed, and a busy slot is met with a free one.
///
/// [memory] is what the user noted about this chat and the people in it, or
/// null — null whenever the "use personal memory" switch is off. Trimmed to
/// the endpoint's budget by `memoryPromptBlock`.
Future<AutoReplyDraft> composeAutoReply({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String instruction,
  required String chatTitle,
  required List<String> transcript,
  String? calendar,
  AiMemory? memory,
  LlmBudget? budget,
  http.Client? client,
  Duration? timeout,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || instruction.trim().isEmpty) {
    return const AutoReplyDraft.failed(AutoReplyOutcome.notConfigured);
  }
  if (transcript.isEmpty) {
    return const AutoReplyDraft.failed(AutoReplyOutcome.refused);
  }

  final limits = budget ?? LlmBudget.resolve(base);
  // The budget is spent on reasoning too: a thinking model handed 220 tokens
  // spent all of them inside `<think>` and never reached the tags. The cap on
  // what is *sent* is [kAutoReplyMaxChars], not this.
  final room = limits.forFeature(AiFeature.autoReply);
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
        'temperature': 0.6,
        'messages': [
          {
            'role': 'system',
            'content':
                'You are writing one chat message on behalf of the user, '
                'who is not at their phone. Follow their instruction '
                'exactly.\n\n'
                'Answer in exactly this format and nothing else:\n'
                '$kAutoReplyOpen'
                'the message to send'
                '$kAutoReplyClose\n\n'
                'Inside the tags put ONLY the message — no greeting '
                'unless the instruction asks for one, no explanation, no '
                'quotation marks, no markdown, no signature. Write in the '
                "same language as the conversation. Keep it under four "
                'sentences.\n\n'
                'If no message should be sent — the instruction says not '
                'to answer in a situation like this one, or the newest '
                'message needs no answer — output exactly '
                '$kAutoReplyDecline instead.\n\n'
                'Anything outside the tags is thrown away, and an answer '
                'without them is never sent.\n\n'
                "The user's instruction:\n$instruction"
                '${calendarPromptBlock(calendar)}'
                '${memoryPromptBlock(memory, baseUrl: base, budget: limits, feature: AiFeature.autoReply)}',
          },
          {
            'role': 'user',
            'content':
                'Conversation "$chatTitle" (newest message last):\n'
                '${transcript.join('\n')}\n\n'
                'Your answer, in the format above:',
          },
        ],
      },
      maxTokens: room.maxTokens,
      retryMaxTokens: room.retryMaxTokens,
      // Only a closed reply or a decline counts: a message cut off mid-way is
      // never sent, so it is worth the second try.
      answered: (content) =>
          parseAutoReply(content, finished: false).outcome !=
          AutoReplyOutcome.refused,
      timeout: timeout ?? llmResponseTimeout(base, LlmTask.autoReply),
      what: 'auto-reply',
    );

    if (!answer.ok) {
      debugPrint('weft: auto-reply: $url answered ${answer.status}');
      return const AutoReplyDraft.failed(AutoReplyOutcome.unreachable);
    }

    final content = answer.content;
    if (content == null) {
      debugPrint('weft: auto-reply: no content in the completion');
      return AutoReplyDraft.failed(
        answer.cutOff ? AutoReplyOutcome.cutOff : AutoReplyOutcome.refused,
      );
    }

    // "stop" is the model ending its answer itself, which is what tells an
    // answer that forgot its closing tag apart from one cut off by the budget.
    // Anything else — "length", or a server that does not say — is read as
    // cut off.
    final draft = parseAutoReply(
      content,
      finished: answer.finishReason == 'stop',
    );
    if (draft.outcome == AutoReplyOutcome.refused) {
      debugPrint('weft: auto-reply: nothing usable in ${jsonEncode(content)}');
      if (answer.cutOff) {
        return const AutoReplyDraft.failed(AutoReplyOutcome.cutOff);
      }
    }
    return draft;
  } on TimeoutException {
    debugPrint('weft: auto-reply against $url timed out');
    return const AutoReplyDraft.failed(AutoReplyOutcome.timedOut);
  } on Object catch (error) {
    debugPrint('weft: auto-reply against $url failed: $error');
    return const AutoReplyDraft.failed(AutoReplyOutcome.unreachable);
  } finally {
    if (owned) httpClient.close();
  }
}

/// The tags the model must wrap its message in.
///
/// A format rather than free prose, because free prose is where a thinking
/// model's narration ends up: "Okay, they asked about Friday, so I should…"
/// reads as a sentence to every heuristic, and it was being sent. With the
/// message fenced in tags, everything outside them is thrown away unread, and
/// an answer that never opens or never closes them is not sent at all.
const String kAutoReplyOpen = '<reply>';
const String kAutoReplyClose = '</reply>';

/// What the model writes instead of [kAutoReplyOpen] when the user's
/// instruction or the conversation says no message should go out.
const String kAutoReplyDecline = '<no-reply/>';

/// Pulls a sendable message out of whatever the model said.
///
/// [finished] is whether the model ended the answer itself (`finish_reason`
/// "stop") rather than running out of budget. It decides one case only: a
/// reply that was opened and never closed is the whole message when the model
/// stopped on its own — small models drop the closing tag — and the first
/// half of one when the budget cut it off.
///
/// A [AutoReplyDraft.written] only for an answer in the format the prompt
/// asks for; [AutoReplyOutcome.declined] when the model chose not to reply;
/// [AutoReplyOutcome.refused] for everything else. No best effort, and that is
/// the difference between this and `parseSmartReplies`. A chip nobody taps
/// costs nothing; this text is *sent*, to a person, on WhatsApp, and cannot be
/// unsent.
AutoReplyDraft parseAutoReply(String content, {bool finished = false}) {
  const refused = AutoReplyDraft.failed(AutoReplyOutcome.refused);

  // Thinking models narrate before they answer, and the narration may well
  // quote the format it is about to use. The tagged form goes first; an
  // unclosed <think> means the reasoning ran to the end of the budget and there
  // is no answer in there at all.
  final text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return refused;

  // The last marker is the answer. Untagged reasoning can mention either one
  // before the model settles on what it means. Matched by pattern rather than
  // on a lower-cased copy, whose offsets need not line up with the original's.
  final open = RegExp(
    r'<\s*reply\s*>',
    caseSensitive: false,
  ).allMatches(text).lastOrNull;
  final decline = RegExp(
    r'<\s*no[-_ ]?reply\s*/?\s*>',
    caseSensitive: false,
  ).allMatches(text).lastOrNull;
  if (decline != null && decline.start > (open?.start ?? -1)) {
    return const AutoReplyDraft.failed(AutoReplyOutcome.declined);
  }
  if (open == null) return refused;

  final close = RegExp(
    r'<\s*/\s*reply\s*>',
    caseSensitive: false,
  ).firstMatch(text.substring(open.end));
  // Opened and never closed. When the budget ran out that is the first half of
  // a message, which is worse than none of it; when the model stopped by itself
  // it only forgot the tag, and what follows the opening one is the message.
  final String inside;
  if (close != null) {
    inside = text.substring(open.end, open.end + close.start);
  } else if (finished) {
    final unclosed = _unclosedMessage(text.substring(open.end));
    if (unclosed == null) return refused;
    inside = unclosed;
  } else {
    return refused;
  }

  final message = _clean(inside);
  return message == null ? refused : AutoReplyDraft.written(message);
}

/// The message after a `<reply>` the model never closed, or null.
///
/// Up to the first blank line only: a model that forgot the tag may well go on
/// to explain its answer, and the explanation must not be sent with it. Any
/// `<` left in what remains is a mangled tag — `</repl`, a second `<reply>` —
/// and a message with markup in it is not one to send.
String? _unclosedMessage(String rest) {
  final message = rest.trimLeft().split(RegExp(r'\n\s*\n')).first;
  if (message.contains('<')) return null;
  return message;
}

/// The message inside the tags tidied into something sendable, or null.
///
/// The model was told to put only the message there, and mostly does; this is
/// for the times it does not.
String? _clean(String message) {
  var text = message.trim();

  // A fenced block is the model formatting an answer it was told not to
  // format. The contents are the answer.
  final fence = RegExp(r'```(?:\w+)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();

  // A label the prompt invited — "The message to send:" echoed back.
  text = text
      .replaceFirst(
        RegExp(
          r'^(?:reply|response|message|answer)\s*:\s*',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  // Quotation marks around the whole thing, which most models add at least
  // sometimes. Stripped only when they wrap the entire text, so a reply that
  // quotes something in the middle keeps its punctuation.
  text = _unwrapQuotes(text);

  if (text.isEmpty) return null;
  // Letters, not just punctuation or an emoji the model chose instead of
  // answering.
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(text)) return null;
  // A heading or a bulleted analysis is the model describing the conversation.
  if (text.startsWith('#') || text.startsWith('- ') || text.startsWith('* ')) {
    return null;
  }
  if (text.endsWith(':')) return null;

  return _capLength(text);
}

/// [text] cut to [kAutoReplyMaxChars] at a sentence boundary, or null when
/// there is no boundary to cut at.
///
/// Refusing rather than hard-truncating: six hundred characters with no
/// sentence end in them is not a long message, it is a model that has stopped
/// writing one, and sending the first two thirds of it would be worse than
/// sending nothing.
String? _capLength(String text) {
  if (text.length <= kAutoReplyMaxChars) return text;

  final head = text.substring(0, kAutoReplyMaxChars);
  final cut = [
    head.lastIndexOf('. '),
    head.lastIndexOf('! '),
    head.lastIndexOf('? '),
    head.lastIndexOf('\n'),
  ].reduce((a, b) => a > b ? a : b);
  if (cut < 40) return null;
  return head.substring(0, cut + 1).trim();
}

/// [text] with one matching pair of wrapping quotes removed.
String _unwrapQuotes(String text) {
  const pairs = {'"': '"', '“': '”', '«': '»', '„': '“', "'": "'"};
  if (text.length < 2) return text;
  final closing = pairs[text[0]];
  if (closing == null || !text.endsWith(closing)) return text;
  // Only when the pair wraps the whole thing: a reply that opens with a quoted
  // phrase and ends with another is two quotations, not one.
  final inner = text.substring(1, text.length - 1);
  if (inner.contains(closing)) return text;
  return inner.trim();
}
