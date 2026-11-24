import 'dart:collection';

import 'package:weft_domain/weft_domain.dart';

/// How much of a conversation any AI feature may send to the model.
///
/// One number for every feature rather than one per feature, because it is a
/// privacy quantity and not a tuning one: it is how many messages leave the
/// device when the model is asked anything, and a user who has read what the
/// auto-reply screen discloses should not find the reply chips disclosing
/// something else. Both features bound their buffer by this, and both tests
/// assert the bound.
///
/// Twenty-four short lines is a few minutes of chat and a prompt of a few
/// hundred tokens — enough that "see you there" and "which one?" are answered
/// in the light of what they refer to, which is the whole reason to send more
/// than the newest message. Past that the extra lines are older than the thing
/// being replied to and buy nothing but latency on someone's local model.
const int kAiContextMessages = 24;

/// How many conversations keep a context buffer at once.
///
/// An LRU rather than unbounded: a busy account would otherwise accumulate one
/// buffer per room for the life of the process, and the conversations that
/// matter to an answer are the ones recently spoken in.
const int kAiContextConversations = 64;

/// The recent messages of several conversations, oldest first, bounded twice.
///
/// Extracted from `AutoReplyService`, which had it first, so the reply chips
/// can be given the same thing. The two AI features used to disagree about what
/// "the conversation" meant — the auto-reply engine remembered what it had seen
/// arrive this session, while the chips were handed whatever was still posted
/// in the notification shade, which is one line for every chat the user has
/// just read. One buffer makes the question have one answer.
///
/// Generic over the entry, and deliberately knows nothing about messages: the
/// auto-reply path holds `WeftMessage`s and the notification path holds
/// `NotificationContent`, and each formats its own transcript lines. What is
/// shared is the bookkeeping — the per-conversation cap, the LRU over
/// conversations, and the oldest-first order the prompts are written against.
///
/// In memory only. Nothing here is persisted: a buffer written to disk would be
/// a copy of the conversation kept beside it for no one's benefit.
class ConversationContext<T> {
  ConversationContext({
    this.maxMessages = kAiContextMessages,
    this.maxConversations = kAiContextConversations,
  }) : assert(maxMessages > 0),
       assert(maxConversations > 0);

  /// How many entries one conversation keeps.
  final int maxMessages;

  /// How many conversations are tracked before the least recently touched one
  /// is dropped.
  final int maxConversations;

  final LinkedHashMap<String, List<T>> _entries = LinkedHashMap();

  /// Appends [entry] to [key]'s buffer and returns the bounded result.
  ///
  /// The return value is the transcript the caller wants in the same step,
  /// which is what keeps "remember this" and "what should the model see" from
  /// drifting apart.
  List<T> remember(String key, T entry) {
    // Re-inserted rather than updated in place, which is what makes the
    // LinkedHashMap an LRU: the least recently touched conversation is first.
    final existing = _entries.remove(key) ?? <T>[];
    existing.add(entry);
    if (existing.length > maxMessages) {
      existing.removeRange(0, existing.length - maxMessages);
    }
    _entries[key] = existing;
    while (_entries.length > maxConversations) {
      _entries.remove(_entries.keys.first);
    }
    return List.unmodifiable(existing);
  }

  /// What the model would be sent for [key], oldest first. Empty for a
  /// conversation nothing has been remembered for.
  ///
  /// A snapshot, not the buffer: a caller holding the live list would see it
  /// change under them on the next message, and could trim it.
  List<T> of(String key) => List.unmodifiable(_entries[key] ?? const []);

  /// Drops one conversation's buffer.
  void forget(String key) => _entries.remove(key);

  /// Drops everything. Called on dispose, so a signed-out session leaves no
  /// conversation behind in memory.
  void clear() => _entries.clear();

  /// How many conversations are currently tracked.
  int get length => _entries.length;
}

/// [lines] without the oldest ones, until what is left fits in [maxChars] —
/// the newest line always stays, since it is what is being answered.
List<String> fitTranscript(List<String> lines, int maxChars) {
  var length = lines.fold(0, (n, l) => n + l.length + 1);
  var start = 0;
  while (length > maxChars && start < lines.length - 1) {
    length -= lines[start++].length + 1;
  }
  return start == 0 ? lines : lines.sublist(start);
}

/// One `Name: what they said` line per message, oldest first — the shape every
/// prompt in `services/ai` is written against.
///
/// Shared rather than written out at each call site, because the two AI
/// features send the *same* transcript to the *same* endpoint and a model that
/// saw "You:" from one feature and the user's display name from the other
/// would be answering two different conversations. `You` rather than the
/// user's own name for the same reason the prompts say "on behalf of the
/// user": it is the word a model needs to tell the sides apart.
///
/// [WeftMessage.searchableText] rather than the raw body: it is the visible
/// text of a formatted message, so `<b>fire</b>` reaches the model as `fire`
/// rather than as markup, and whatever a `<script>` held never reaches it at
/// all. Newlines are collapsed because the prompt is one message per line and
/// a body with a line break in it would read as a second speaker.
List<String> transcriptLinesFor(Iterable<WeftMessage> messages) => [
  for (final message in messages)
    '${message.isOwn ? 'You' : message.senderName}: '
        '${message.searchableText.replaceAll(RegExp(r'\s+'), ' ').trim()}',
];
