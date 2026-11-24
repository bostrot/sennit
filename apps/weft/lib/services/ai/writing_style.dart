import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:weft_domain/weft_domain.dart';

import 'event_title.dart' show messageWords;

/// How the user writes, so the AI features write like them.
///
/// Three things go into a reply prompt (see [stylePromptBlock]): the style
/// profile learned for this chat — or, for a chat with too little history,
/// the user's usual one — the habits measured from their own messages here
/// ([measureWritingHabits]), and a handful of those messages as they were
/// sent ([ownStyleExamples]). The contact's style goes along too, as context
/// only: someone who writes formally is usually answered a certain way, and
/// the model is told never to copy them.
///
/// The profiles themselves are learned facts in `MemoryBook`, marked
/// [LearnedFact.style]: the user's style in a chat under the chat's keys, the
/// contact's under theirs, the usual one under [kOwnStyleKey]. Learned,
/// edited, pinned and undone like every other fact.

/// The fewest messages from one person that say anything about how they
/// write. Fewer, and no habits are measured and no profile is learned.
const int kStyleMinMessages = 3;

/// The most of the user's own messages a reply prompt carries as examples.
const int kStyleExamples = 10;

/// The longest one example is sent; a long message is cut at a word.
const int kStyleExampleChars = 160;

/// The longest style profile kept: two short sentences.
const int kStyleMaxChars = 280;

/// The key the user's usual style is filed under in `MemoryBook`: not a chat
/// and not a person, but the user, in every chat.
const String kOwnStyleKey = 'self';

/// What the reply prompts are told about how the user writes, and how the
/// people they write to do.
@immutable
class AiStyle {
  const AiStyle({
    this.mine = '',
    this.usual = '',
    this.habits = '',
    this.examples = const [],
    this.theirs = const [],
  });

  static const AiStyle none = AiStyle();

  /// The user's style in this chat, as learned or edited.
  final String mine;

  /// The user's style across chats, for a chat with no [mine] yet.
  final String usual;

  /// [WritingHabits.describe] of the user's own messages here, or empty.
  final String habits;

  /// The user's own recent messages here, oldest first.
  final List<String> examples;

  /// How each contact writes, for understanding them only.
  final List<({String name, String style})> theirs;

  bool get isEmpty =>
      mine.trim().isEmpty &&
      usual.trim().isEmpty &&
      habits.trim().isEmpty &&
      examples.isEmpty &&
      theirs.every((t) => t.style.trim().isEmpty);

  @override
  String toString() =>
      'AiStyle(${mine.isEmpty ? 'no' : 'a'} profile, '
      '${usual.isEmpty ? 'no' : 'a'} usual one, ${examples.length} examples, '
      '${theirs.length} of theirs)';
}

/// Counted habits of one person's messages: length, capitals, full stops,
/// exclamation marks and emojis. What a model is bad at estimating from a
/// transcript and a few lines of code are good at.
@immutable
class WritingHabits {
  const WritingHabits({
    required this.messages,
    required this.medianWords,
    required this.lowercaseShare,
    required this.periodShare,
    required this.exclamationShare,
    required this.emojiShare,
    this.emojis = const [],
  });

  /// How many messages were measured.
  final int messages;

  /// The middle message's length, in words.
  final int medianWords;

  /// The share of messages that start with a small letter, of those that
  /// start with a letter that has a case.
  final double lowercaseShare;

  /// The share ending in a full stop.
  final double periodShare;

  /// The share with an exclamation mark.
  final double exclamationShare;

  /// The share with at least one emoji.
  final double emojiShare;

  /// The emojis used most, most used first, at most three.
  final List<String> emojis;

  /// The habits in a few English words, for a prompt: "very short (about 3
  /// words); starts lowercase; no full stop at the end; emojis in most
  /// messages (😂 🙈)". Only what stands out is said.
  String describe() {
    final length = switch (medianWords) {
      <= 4 => 'very short',
      <= 10 => 'short',
      <= 25 => 'medium length',
      _ => 'long',
    };
    final emojiList = emojis.isEmpty ? '' : ' (${emojis.join(' ')})';
    return [
      '$length (about $medianWords ${medianWords == 1 ? 'word' : 'words'})',
      if (lowercaseShare >= 0.7)
        'starts lowercase'
      else if (lowercaseShare <= 0.2)
        'starts with a capital',
      if (periodShare >= 0.6)
        'ends with a full stop'
      else if (periodShare <= 0.15)
        'no full stop at the end',
      if (exclamationShare >= 0.3) 'often uses "!"',
      if (emojiShare >= 0.5)
        'emojis in most messages$emojiList'
      else if (emojiShare >= 0.15)
        'emojis sometimes$emojiList'
      else if (emojiShare == 0)
        'no emojis'
      else
        'emojis rarely$emojiList',
    ].join('; ');
  }

  @override
  String toString() => 'WritingHabits($messages messages)';
}

// The analyzer does not know the binary property; the VM and dart2js do.
// ignore: valid_regexps
final RegExp _emoji = RegExp(r'\p{Extended_Pictographic}', unicode: true);

/// The habits of [texts], one person's messages, or null for fewer than
/// [kStyleMinMessages] — three lines say nothing about anyone.
WritingHabits? measureWritingHabits(Iterable<String> texts) {
  final list = [
    for (final t in texts)
      if (t.trim().isNotEmpty) t.trim(),
  ];
  if (list.length < kStyleMinMessages) return null;
  final words = [
    for (final t in list)
      t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length,
  ]..sort();
  var cased = 0;
  var lower = 0;
  var periods = 0;
  var exclamations = 0;
  var withEmoji = 0;
  final emojiCounts = <String, int>{};
  for (final text in list) {
    final first = RegExp(r'\p{L}', unicode: true).firstMatch(text)?[0];
    if (first != null && first.toUpperCase() != first.toLowerCase()) {
      cased++;
      if (first == first.toLowerCase()) lower++;
    }
    // A full stop, not an ellipsis.
    if (text.endsWith('.') && !text.endsWith('..')) periods++;
    if (text.contains('!')) exclamations++;
    final found = _emoji.allMatches(text).map((m) => m[0]!).toList();
    if (found.isNotEmpty) withEmoji++;
    for (final e in found) {
      emojiCounts[e] = (emojiCounts[e] ?? 0) + 1;
    }
  }
  final top = emojiCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return WritingHabits(
    messages: list.length,
    medianWords: words[words.length ~/ 2],
    lowercaseShare: cased == 0 ? 0.5 : lower / cased,
    periodShare: periods / list.length,
    exclamationShare: exclamations / list.length,
    emojiShare: withEmoji / list.length,
    emojis: [for (final e in top.take(3)) e.key],
  );
}

/// The user's own messages of [messages] worth showing a model as examples of
/// how they write: the newest [max] in words, each once, oldest first, each
/// cut to [kStyleExampleChars] and all together to [maxChars] — the oldest go
/// first. [allowed] leaves out what may not be sent, such as an encrypted
/// chat's messages while learning from those is off.
List<String> ownStyleExamples(
  Iterable<WeftMessage> messages, {
  int max = kStyleExamples,
  int maxChars = 1200,
  bool Function(WeftMessage message)? allowed,
}) {
  final own = [
    for (final m in messages)
      if (m.isOwn && (allowed?.call(m) ?? true)) m,
  ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  final seen = <String>{};
  final picked = <String>[];
  var used = 0;
  for (final m in own) {
    if (picked.length >= max) break;
    final words = messageWords(m);
    if (words == null || !seen.add(words)) continue;
    final text = _cut(words, kStyleExampleChars);
    if (used + text.length + 3 > maxChars) break;
    used += text.length + 3;
    picked.add(text);
  }
  return picked.reversed.toList(growable: false);
}

String _cut(String text, int max) {
  if (text.length <= max) return text;
  final cut = text.substring(0, max - 1).lastIndexOf(' ');
  return '${text.substring(0, cut > 0 ? cut : max - 1)}…';
}

/// What [messages] say in words, those that say anything, for
/// [measureWritingHabits].
List<String> wordsOf(Iterable<WeftMessage> messages) => [
  for (final m in messages) ?messageWords(m),
];

/// The user's recent messages per chat, as seen while Sennit runs: what a
/// reply chip on a notification has to go on when the conversation buffer
/// holds only the message being answered.
///
/// In memory only, never written anywhere, the newest [kStyleExamples] of
/// each of the [kOwnMessageCacheChats] chats spoken in most recently.
class OwnMessageCache {
  final LinkedHashMap<String, List<WeftMessage>> _byChat = LinkedHashMap();

  /// The [chatId]'s own messages among [messages] remembered, and what is
  /// remembered for it with them: the newest of both, by event id once.
  List<WeftMessage> remember(String chatId, Iterable<WeftMessage> messages) {
    final known = _byChat.remove(chatId) ?? const [];
    final byId = <String, WeftMessage>{
      for (final m in known) m.eventId: m,
      for (final m in messages)
        if (m.isOwn && messageWords(m) != null) m.eventId: m,
    };
    final newest = byId.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final kept = newest.take(kStyleExamples).toList(growable: false);
    if (kept.isNotEmpty) _byChat[chatId] = kept;
    while (_byChat.length > kOwnMessageCacheChats) {
      _byChat.remove(_byChat.keys.first);
    }
    return kept;
  }

  void clear() => _byChat.clear();
}

/// How many chats [OwnMessageCache] remembers messages for.
const int kOwnMessageCacheChats = 64;

/// The paragraph a reply prompt's system message gets about how the user
/// writes, cut to [maxChars], or nothing when nothing is known.
///
/// The instruction comes first and the profile right after, because a model
/// that sees only the contact's messages in the transcript writes like the
/// contact — or like an assistant, polished and complete, which a terse
/// lowercase texter never sends. The examples go last and are what is cut
/// first: a profile says more per character than one more example.
String stylePromptBlock(AiStyle? style, {required int maxChars}) {
  if (style == null || style.isEmpty || maxChars <= 0) return '';
  final mine = style.mine.trim();
  final usual = style.usual.trim();
  final lines = <String>[
    'Write as the user: whatever you write is sent from their phone, in '
        'their name. Match how the user writes in this chat — their '
        'language or mix of languages, du or Sie, length, capitalisation, '
        'punctuation, emojis, typical words and tone. Not how the other '
        'person writes, and not like an assistant: nothing more polished '
        'than the user would type.',
    if (mine.isNotEmpty)
      "The user's style in this chat: ${_cut(mine, kStyleMaxChars)}"
    else if (usual.isNotEmpty)
      "The user's usual style: ${_cut(usual, kStyleMaxChars)}",
    if (style.habits.trim().isNotEmpty)
      "Measured from the user's messages here: ${style.habits.trim()}",
  ];
  for (final t in style.theirs) {
    if (t.style.trim().isEmpty) continue;
    lines.add(
      'How ${t.name} writes (only to understand them — never copy it): '
      '${_cut(t.style.trim(), kStyleMaxChars)}',
    );
  }
  var used = lines.fold(0, (n, l) => n + l.length + 1);
  // Whatever does not fit goes, from the end — but never the instruction.
  while (used > maxChars && lines.length > 1) {
    used -= lines.removeLast().length + 1;
  }
  const heading =
      "Messages the user sent in this chat (their voice — don't repeat "
      'them):';
  final examples = <String>[];
  var room = maxChars - used - heading.length - 1;
  for (final e in style.examples.reversed) {
    final line = '- $e';
    if (line.length + 1 > room) break;
    room -= line.length + 1;
    examples.insert(0, line);
  }
  // The instruction alone, with nothing about the user to go by, is noise.
  if (lines.length == 1 && examples.isEmpty) return '';
  return '\n\n${[
    ...lines,
    if (examples.isNotEmpty) ...[heading, ...examples],
  ].join('\n')}';
}

/// What the learning prompt is told about style: the profiles so far and the
/// habits measured in the conversation it reads.
@immutable
class StyleLearning {
  const StyleLearning({
    this.mine = '',
    this.usual = '',
    this.theirs = const {},
    this.myHabits = '',
    this.theirHabits = const {},
  });

  static const StyleLearning none = StyleLearning();

  /// The user's style in this chat so far.
  final String mine;

  /// The user's usual style so far.
  final String usual;

  /// Each person's style so far, by the name the prompt uses.
  final Map<String, String> theirs;

  /// The user's habits in this conversation, or empty for too few messages —
  /// in which case no style of theirs is learned from it.
  final String myHabits;

  /// The same for each person, by name; a name missing has too few.
  final Map<String, String> theirHabits;

  /// Whether a style may be learned for [who] — "me", "default" or a name —
  /// from this conversation: whether they wrote enough of it.
  bool mayLearn(String who) => switch (who.trim().toLowerCase()) {
    'me' || 'default' => myHabits.isNotEmpty,
    _ => theirHabits.keys.any(
      (name) => name.trim().toLowerCase() == who.trim().toLowerCase(),
    ),
  };

  /// The lines the learning prompt's user turn gets, or none.
  List<String> promptLines() {
    String so(String s) => s.trim().isEmpty ? '(nothing yet)' : s.trim();
    return [
      'Writing style so far:',
      '- me (the user, in this chat): ${so(mine)}',
      '- default (the user, in all chats): ${so(usual)}',
      for (final MapEntry(:key, :value) in theirs.entries)
        if (value.trim().isNotEmpty) '- $key: ${value.trim()}',
      '',
      'Measured in this conversation:',
      '- me: ${myHabits.isEmpty ? 'too few messages' : myHabits}',
      for (final MapEntry(:key, :value) in theirHabits.entries)
        '- $key: $value',
    ];
  }

  @override
  String toString() =>
      'StyleLearning(${myHabits.isEmpty ? 'too little' : 'enough'} of mine, '
      '${theirHabits.length} measured)';
}

/// [text] as a style profile is kept: one line, at most [kStyleMaxChars].
/// Null for nothing.
String? cleanStyle(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(text)) return null;
  return _cut(text, kStyleMaxChars);
}
