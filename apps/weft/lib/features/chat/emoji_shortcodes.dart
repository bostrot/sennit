import 'package:flutter/services.dart';
import 'package:weft_richtext/weft_richtext.dart';

import 'emoji_shortcode_data.dart';

export 'emoji_shortcode_data.dart' show EmojiShortcode, kEmojiShortcodes;

/// The `:query` being typed at the caret: where its colon is, and what follows.
class ShortcodeQuery {
  const ShortcodeQuery({
    required this.start,
    required this.end,
    required this.text,
  });

  /// Index of the opening colon.
  final int start;

  /// The caret, one past the last character of [text].
  final int end;

  /// What follows the colon, as typed.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is ShortcodeQuery &&
      other.start == start &&
      other.end == end &&
      other.text == text;

  @override
  int get hashCode => Object.hash(start, end, text);
}

/// One row of the popup.
class EmojiSuggestion {
  const EmojiSuggestion({required this.emoji, required this.name});

  /// The emoji to insert, already in the user's skin tone where it takes one.
  final String emoji;

  /// The name that matched, without colons.
  final String name;
}

/// How many characters after the colon before anything is suggested. One is
/// every `:D` and `:P` anyone types, and a popup for each of them.
const int kShortcodeMinQuery = 2;

final RegExp _queryChar = RegExp(r'[A-Za-z0-9_+\-]');
final RegExp _space = RegExp(r'\s');

/// The `:query` ending at the caret in [value], or null when there is none.
///
/// The colon has to start the text or follow whitespace. That one rule is what
/// keeps `10:30`, `https://` and `Note:` from opening anything: in all of
/// them the colon is glued to the word before it. Text inside a code span is
/// left alone too — someone pasting `a:bc` between backticks means it
/// literally.
ShortcodeQuery? shortcodeQueryAt(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  // Mid-composition in an input method: the text is not the user's yet.
  if (value.composing.isValid && !value.composing.isCollapsed) return null;
  final text = value.text;
  final caret = selection.baseOffset;
  if (caret > text.length) return null;
  // Only at the end of a token: a caret moved back into `:thumbsup` is the
  // user editing, not asking.
  if (caret < text.length && _queryChar.hasMatch(text[caret])) return null;

  var i = caret;
  while (i > 0 && _queryChar.hasMatch(text[i - 1])) {
    i--;
  }
  final colon = i - 1;
  if (colon < 0 || text[colon] != ':') return null;
  if (colon > 0 && !_space.hasMatch(text[colon - 1])) return null;
  final query = text.substring(i, caret);
  if (query.length < kShortcodeMinQuery) return null;
  if (_insideCode(text, colon)) return null;
  return ShortcodeQuery(start: colon, end: caret, text: query);
}

/// Whether [index] sits inside a code span or block: an odd number of
/// backticks before it. A fence is three, so it flips the count the same way.
bool _insideCode(String text, int index) {
  var ticks = 0;
  for (var i = 0; i < index; i++) {
    if (text.codeUnitAt(i) == 0x60) ticks++;
  }
  return ticks.isOdd;
}

/// The Fitzpatrick modifiers, lightest first — Slack's `skin-tone-2` to `-6`.
const List<String> kSkinToneModifiers = [
  '\u{1F3FB}',
  '\u{1F3FC}',
  '\u{1F3FD}',
  '\u{1F3FE}',
  '\u{1F3FF}',
];

/// [emoji] in [modifier]'s skin tone: the modifier goes straight after the
/// first code point, replacing the variation selector if one was there.
String applySkinTone(String emoji, String modifier) {
  final runes = emoji.runes.toList();
  if (runes.isEmpty) return emoji;
  final rest = runes.skip(1).toList();
  if (rest.isNotEmpty && rest.first == 0xFE0F) rest.removeAt(0);
  return String.fromCharCodes([runes.first, ...modifier.runes, ...rest]);
}

final RegExp _toneOrSelector = RegExp('[\u{1F3FB}-\u{1F3FF}️]', unicode: true);

String _base(String emoji) =>
    normaliseReactionKey(emoji).replaceAll(_toneOrSelector, '');

Map<String, EmojiShortcode>? _byName;

/// The emoji called exactly [name], or null.
EmojiShortcode? emojiForShortcode(String name) {
  final table = _byName ??= {
    for (final entry in kEmojiShortcodes)
      for (final n in entry.names) n: entry,
  };
  return table[name.toLowerCase()];
}

/// What [query] matches, best first.
///
/// Ranked in tiers — the exact name, then names that start with the query,
/// then names with a word that does (`:face` finds `upside_down_face` after
/// `face_with_…`), then anywhere inside, then the letters in order (`:thmbs`).
/// What the user reached for recently ([recents], most recent first) goes
/// ahead of the other names that start the same way, then the shorter name,
/// then Unicode's order.
///
/// [skinTone] is one of [kSkinToneModifiers], applied to the emoji that take
/// one.
List<EmojiSuggestion> searchEmojiShortcodes(
  String query, {
  List<String> recents = const [],
  String? skinTone,
  int limit = 30,
}) {
  final q = query.toLowerCase();
  if (q.isEmpty) return const [];
  final recentRank = <String, int>{};
  for (var i = 0; i < recents.length; i++) {
    recentRank.putIfAbsent(_base(recents[i]), () => i);
  }

  final scored = <_Scored>[];
  for (var index = 0; index < kEmojiShortcodes.length; index++) {
    final entry = kEmojiShortcodes[index];
    int? bestTier;
    String? bestName;
    for (final name in entry.names) {
      final tier = _tier(name, q);
      if (tier == null) continue;
      if (bestTier == null ||
          tier < bestTier ||
          (tier == bestTier && name.length < bestName!.length)) {
        bestTier = tier;
        bestName = name;
      }
    }
    if (bestTier == null) continue;
    scored.add(
      _Scored(
        entry: entry,
        name: bestName!,
        tier: bestTier,
        recent: recentRank[_base(entry.emoji)] ?? recents.length,
        index: index,
      ),
    );
  }
  // Recents lead within a band rather than within a tier: `:sm` should put
  // the 😏 used yesterday ahead of `:smile:`, but not a `guardsman` that only
  // has the letters somewhere inside.
  int band(int tier) => tier == 0 ? 0 : (tier <= 2 ? 1 : 2);
  scored.sort((a, b) {
    var c = band(a.tier).compareTo(band(b.tier));
    if (c != 0) return c;
    c = a.recent.compareTo(b.recent);
    if (c != 0) return c;
    c = a.tier.compareTo(b.tier);
    if (c != 0) return c;
    c = a.name.length.compareTo(b.name.length);
    if (c != 0) return c;
    return a.index.compareTo(b.index);
  });
  return [
    for (final s in scored.take(limit))
      EmojiSuggestion(
        emoji: skinTone != null && s.entry.tones
            ? applySkinTone(s.entry.emoji, skinTone)
            : s.entry.emoji,
        name: s.name,
      ),
  ];
}

int? _tier(String name, String q) {
  if (name == q) return 0;
  if (name.startsWith(q)) return 1;
  if (name.contains('_$q')) return 2;
  if (name.contains(q)) return 3;
  // Letters in order, for a typo'd or abbreviated name. Not for two letters:
  // nearly every name has some `a…e` in it.
  if (q.length < 3) return null;
  var at = 0;
  for (final unit in name.codeUnits) {
    if (unit == q.codeUnitAt(at) && ++at == q.length) return 4;
  }
  return null;
}

class _Scored {
  _Scored({
    required this.entry,
    required this.name,
    required this.tier,
    required this.recent,
    required this.index,
  });

  final EmojiShortcode entry;
  final String name;
  final int tier;
  final int recent;
  final int index;
}

/// [value] with a just-closed `:name:` before the caret turned into its emoji,
/// or null when there is nothing to convert.
///
/// Only an exact name converts, and only when the opening colon follows
/// whitespace or starts the text — the same rule as [shortcodeQueryAt], so
/// `12:30:45` stays a time.
TextEditingValue? convertClosedShortcode(
  TextEditingValue value, {
  String? skinTone,
}) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.baseOffset;
  final text = value.text;
  if (caret < 2 || caret > text.length || text[caret - 1] != ':') return null;
  final query = shortcodeQueryAt(
    value.copyWith(
      selection: TextSelection.collapsed(offset: caret - 1),
      composing: TextRange.empty,
    ),
  );
  // One character is enough here, unlike for the popup: an exact name is a
  // deliberate act, and `:x:` is a name.
  final ShortcodeQuery? closed = query ?? _shortQueryBefore(text, caret - 1);
  if (closed == null) return null;
  final entry = emojiForShortcode(closed.text);
  if (entry == null) return null;
  final emoji = skinTone != null && entry.tones
      ? applySkinTone(entry.emoji, skinTone)
      : entry.emoji;
  final replaced = text.replaceRange(closed.start, caret, emoji);
  return TextEditingValue(
    text: replaced,
    selection: TextSelection.collapsed(offset: closed.start + emoji.length),
  );
}

/// A one-character `:x` ending at [end], which [shortcodeQueryAt] declines.
ShortcodeQuery? _shortQueryBefore(String text, int end) {
  if (end < 2 || !_queryChar.hasMatch(text[end - 1])) return null;
  final colon = end - 2;
  if (text[colon] != ':') return null;
  if (colon > 0 && !_space.hasMatch(text[colon - 1])) return null;
  if (_insideCode(text, colon)) return null;
  return ShortcodeQuery(start: colon, end: end, text: text[end - 1]);
}

/// [value] with [query] replaced by [emoji] and a space after it, unless a
/// space is already there.
TextEditingValue insertEmojiForQuery(
  TextEditingValue value,
  ShortcodeQuery query,
  String emoji,
) {
  final text = value.text;
  final spaced = query.end < text.length && _space.hasMatch(text[query.end]);
  final insert = spaced ? emoji : '$emoji ';
  final replaced = text.replaceRange(query.start, query.end, insert);
  return TextEditingValue(
    text: replaced,
    selection: TextSelection.collapsed(
      offset: query.start + insert.length + (spaced ? 1 : 0),
    ),
  );
}
