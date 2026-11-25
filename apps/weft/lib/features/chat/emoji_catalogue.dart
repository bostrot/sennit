import 'dart:io' show Platform;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart'
    show Category, CategoryEmoji, Emoji, EmojiPickerUtils, SkinTone;
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The groups the picker shows, in the order it shows them.
///
/// The package's own `Category`, minus its `RECENT` — recents are ours, kept
/// beside the rest of the reaction state rather than in the package's private
/// shared preferences.
const List<Category> kEmojiGroups = [
  Category.SMILEYS,
  Category.ANIMALS,
  Category.FOODS,
  Category.ACTIVITIES,
  Category.TRAVEL,
  Category.OBJECTS,
  Category.SYMBOLS,
  Category.FLAGS,
];

/// The six skin tones a picker offers, the first being none at all.
const List<String?> kSkinTones = [
  null,
  SkinTone.light,
  SkinTone.mediumLight,
  SkinTone.medium,
  SkinTone.mediumDark,
  SkinTone.dark,
];

/// One emoji the picker can offer.
@immutable
class CatalogueEmoji {
  const CatalogueEmoji(this.emoji, this.keywords, {this.hasSkinTone = false});

  final String emoji;

  /// Lower-cased: the reader's language first, then English. A German reader
  /// typing "thumbs" still finds the thumbs-up, and so does one typing
  /// "daumen".
  final List<String> keywords;

  final bool hasSkinTone;

  /// [emoji] in [tone], or unchanged when it takes none.
  String toned(String? tone) {
    if (tone == null || !hasSkinTone) return emoji;
    return EmojiPickerUtils().applySkinTone(Emoji(emoji, ''), tone).emoji;
  }

  /// Whether every word of [query] is in one of the names. The tables keep
  /// single words ("thumb", "up"), so "thumbs up" is matched a word at a time,
  /// and a plural is matched by its singular.
  bool matches(String query) {
    for (var word in query.split(' ')) {
      if (word.isEmpty) continue;
      if (word.length > 3 && word.endsWith('s')) {
        word = word.substring(0, word.length - 1);
      }
      if (!keywords.any((k) => k.contains(word))) return false;
    }
    return true;
  }
}

/// Every emoji this device can draw, grouped, with names to search by.
@immutable
class EmojiCatalogue {
  const EmojiCatalogue(this.groups);

  final Map<Category, List<CatalogueEmoji>> groups;

  Iterable<CatalogueEmoji> get all => groups.values.expand((g) => g);

  /// Emoji whose names contain [query].
  ///
  /// Shortcodes are names wearing punctuation: `:thumbs_up:` is searched as
  /// "thumbs up", which is how the tables spell it.
  List<CatalogueEmoji> search(String query) {
    final needle = query
        .toLowerCase()
        .replaceAll(':', '')
        .replaceAll(RegExp(r'[_\-\s]+'), ' ')
        .trim();
    if (needle.isEmpty) return const [];
    return [
      for (final emoji in all)
        if (emoji.emoji == query.trim() || emoji.matches(needle)) emoji,
    ];
  }
}

/// Which emoji in a list the platform can draw, one answer per entry.
typedef EmojiSupportCheck = Future<List<bool>> Function(List<String> emoji);

/// The platform's answer. Overridden in tests, where there is no glyph to ask
/// about.
final emojiSupportCheckProvider = Provider<EmojiSupportCheck>(
  (ref) => platformEmojiSupport,
);

/// The newest emoji release the OS ships a font for, or null when it cannot be
/// told and every entry has to be asked about one by one.
///
/// Apple's emoji font ships with the OS, so the version *is* the answer, and
/// the version is the only thing the tables below need. Android's emoji font
/// is updatable and varies by maker, so Android always asks the font instead.
final emojiVersionProvider = Provider<double?>((ref) => platformEmojiVersion());

/// The emoji this device can draw, named in [languageCode].
final emojiCatalogueProvider = FutureProvider.family<EmojiCatalogue, String>((
  ref,
  languageCode,
) async {
  final version = ref.watch(emojiVersionProvider);
  final check = ref.watch(emojiSupportCheckProvider);
  return buildEmojiCatalogue(
    languageCode: languageCode,
    version: version,
    check: check,
  );
});

/// Assembles the catalogue: the package's tables in the reader's language,
/// English names merged in for search, the releases the package does not
/// carry yet, and then anything the device would draw as a box taken out.
@visibleForTesting
Future<EmojiCatalogue> buildEmojiCatalogue({
  required String languageCode,
  required double? version,
  required EmojiSupportCheck check,
}) async {
  final local = getDefaultEmojiLocale(Locale(languageCode));
  final english = languageCode == 'en'
      ? const <String, List<String>>{}
      : _keywordsByEmoji(getDefaultEmojiLocale(const Locale('en')));

  final groups = <Category, List<CatalogueEmoji>>{
    for (final group in kEmojiGroups) group: [],
  };
  for (final category in local) {
    final into = groups[category.category];
    if (into == null) continue;
    for (final emoji in category.emoji) {
      into.add(
        CatalogueEmoji(emoji.emoji, [
          ..._keywordsOf(emoji),
          ...?english[emoji.emoji],
        ], hasSkinTone: emoji.hasSkinTone),
      );
    }
  }
  for (final extra in _newerEmoji) {
    // Without a version — Android, the web — the entry is offered and the
    // glyph check below decides.
    if (version != null && extra.version > version) continue;
    groups[extra.group]!.add(
      CatalogueEmoji(
        extra.emoji,
        extra.keywords.split(' | '),
        hasSkinTone: extra.hasSkinTone,
      ),
    );
  }

  final flat = [for (final g in kEmojiGroups) ...groups[g]!];
  final supported = await check([for (final e in flat) e.emoji]);
  if (supported.length != flat.length) return EmojiCatalogue(groups);
  final drawable = {
    for (var i = 0; i < flat.length; i++)
      if (supported[i]) flat[i].emoji,
  };
  return EmojiCatalogue({
    for (final g in kEmojiGroups)
      g: [
        for (final e in groups[g]!)
          if (drawable.contains(e.emoji)) e,
      ],
  });
}

Map<String, List<String>> _keywordsByEmoji(List<CategoryEmoji> set) => {
  for (final category in set)
    for (final emoji in category.emoji) emoji.emoji: _keywordsOf(emoji),
};

List<String> _keywordsOf(Emoji emoji) => [
  for (final k in emoji.keywords)
    if (k.trim().isNotEmpty) k.trim().toLowerCase(),
];

/// Asks Android's font, through the channel `emoji_picker_flutter` registers,
/// which entries it has a glyph for. Everywhere else the answer is yes: Apple
/// is filtered by [emojiVersionProvider] before this is reached, and the web
/// draws from a Noto Color Emoji that is always current.
Future<List<bool>> platformEmojiSupport(List<String> emoji) async {
  if (kIsWeb || !Platform.isAndroid) return [for (final _ in emoji) true];
  try {
    final answer = await const MethodChannel(
      'emoji_picker_flutter',
    ).invokeListMethod<bool>('getSupportedEmojis', {'source': emoji});
    return answer ?? [for (final _ in emoji) true];
  } on Object catch (error) {
    debugPrint('weft: emoji support check failed: $error');
    return [for (final _ in emoji) true];
  }
}

/// The Emoji release this OS draws in full, from its version.
///
/// Only the releases after the package's own tables (Emoji 14) matter, and
/// every supported iOS and macOS already draws 14.
double? platformEmojiVersion() {
  if (kIsWeb) return null;
  if (Platform.isAndroid) return null;
  final match = RegExp(
    r'(\d+)\.(\d+)',
  ).firstMatch(Platform.operatingSystemVersion);
  final major = int.tryParse(match?.group(1) ?? '') ?? 0;
  final minor = int.tryParse(match?.group(2) ?? '') ?? 0;
  bool atLeast(int a, int b) => major > a || (major == a && minor >= b);
  if (Platform.isIOS) {
    if (atLeast(18, 4)) return 16.0;
    if (atLeast(17, 4)) return 15.1;
    if (atLeast(16, 4)) return 15.0;
    return 14.0;
  }
  if (Platform.isMacOS) {
    if (atLeast(15, 4)) return 16.0;
    if (atLeast(14, 4)) return 15.1;
    return 15.0;
  }
  // Windows and Linux draw from whatever emoji font is installed, which is
  // anyone's guess; the package's tables are the safe floor.
  return 14.0;
}

/// Emoji newer than the package's tables, with the release that added them.
///
/// English names only: search still finds them in every language through the
/// English keywords, which is where every entry's names end up anyway.
const List<
  ({
    String emoji,
    Category group,
    double version,
    String keywords,
    bool hasSkinTone,
  })
>
_newerEmoji = [
  // Emoji 15.0
  (
    emoji: '🫨',
    group: Category.SMILEYS,
    version: 15.0,
    keywords: 'shaking face | earthquake | shock | vibrate',
    hasSkinTone: false,
  ),
  (
    emoji: '🩷',
    group: Category.SYMBOLS,
    version: 15.0,
    keywords: 'pink heart | heart | love | cute',
    hasSkinTone: false,
  ),
  (
    emoji: '🩵',
    group: Category.SYMBOLS,
    version: 15.0,
    keywords: 'light blue heart | heart | cyan | teal',
    hasSkinTone: false,
  ),
  (
    emoji: '🩶',
    group: Category.SYMBOLS,
    version: 15.0,
    keywords: 'grey heart | gray heart | heart | silver',
    hasSkinTone: false,
  ),
  (
    emoji: '🫷',
    group: Category.SMILEYS,
    version: 15.0,
    keywords: 'leftwards pushing hand | push | stop | wait | high five',
    hasSkinTone: true,
  ),
  (
    emoji: '🫸',
    group: Category.SMILEYS,
    version: 15.0,
    keywords: 'rightwards pushing hand | push | stop | wait | high five',
    hasSkinTone: true,
  ),
  (
    emoji: '🫎',
    group: Category.ANIMALS,
    version: 15.0,
    keywords: 'moose | elk | antlers',
    hasSkinTone: false,
  ),
  (
    emoji: '🫏',
    group: Category.ANIMALS,
    version: 15.0,
    keywords: 'donkey | mule | stubborn',
    hasSkinTone: false,
  ),
  (
    emoji: '🪽',
    group: Category.ANIMALS,
    version: 15.0,
    keywords: 'wing | angel | fly | bird',
    hasSkinTone: false,
  ),
  (
    emoji: '🐦‍⬛',
    group: Category.ANIMALS,
    version: 15.0,
    keywords: 'black bird | crow | raven | bird',
    hasSkinTone: false,
  ),
  (
    emoji: '🪿',
    group: Category.ANIMALS,
    version: 15.0,
    keywords: 'goose | honk | bird',
    hasSkinTone: false,
  ),
  (
    emoji: '🪼',
    group: Category.ANIMALS,
    version: 15.0,
    keywords: 'jellyfish | sting | sea',
    hasSkinTone: false,
  ),
  (
    emoji: '🪻',
    group: Category.ANIMALS,
    version: 15.0,
    keywords: 'hyacinth | lavender | flower',
    hasSkinTone: false,
  ),
  (
    emoji: '🫚',
    group: Category.FOODS,
    version: 15.0,
    keywords: 'ginger root | ginger | spice',
    hasSkinTone: false,
  ),
  (
    emoji: '🫛',
    group: Category.FOODS,
    version: 15.0,
    keywords: 'pea pod | peas | edamame | vegetable',
    hasSkinTone: false,
  ),
  (
    emoji: '🪭',
    group: Category.OBJECTS,
    version: 15.0,
    keywords: 'folding hand fan | fan | hot',
    hasSkinTone: false,
  ),
  (
    emoji: '🪮',
    group: Category.OBJECTS,
    version: 15.0,
    keywords: 'hair pick | comb | afro',
    hasSkinTone: false,
  ),
  (
    emoji: '🪇',
    group: Category.OBJECTS,
    version: 15.0,
    keywords: 'maracas | music | shake',
    hasSkinTone: false,
  ),
  (
    emoji: '🪈',
    group: Category.OBJECTS,
    version: 15.0,
    keywords: 'flute | music | recorder',
    hasSkinTone: false,
  ),
  (
    emoji: '🪯',
    group: Category.SYMBOLS,
    version: 15.0,
    keywords: 'khanda | sikh | religion',
    hasSkinTone: false,
  ),
  (
    emoji: '🛜',
    group: Category.SYMBOLS,
    version: 15.0,
    keywords: 'wireless | wifi | internet | network',
    hasSkinTone: false,
  ),
  // Emoji 15.1
  (
    emoji: '🙂‍↔️',
    group: Category.SMILEYS,
    version: 15.1,
    keywords: 'head shaking horizontally | no | shake',
    hasSkinTone: false,
  ),
  (
    emoji: '🙂‍↕️',
    group: Category.SMILEYS,
    version: 15.1,
    keywords: 'head shaking vertically | yes | nod',
    hasSkinTone: false,
  ),
  (
    emoji: '🐦‍🔥',
    group: Category.ANIMALS,
    version: 15.1,
    keywords: 'phoenix | fire | rebirth | bird',
    hasSkinTone: false,
  ),
  (
    emoji: '🍋‍🟩',
    group: Category.FOODS,
    version: 15.1,
    keywords: 'lime | citrus | fruit',
    hasSkinTone: false,
  ),
  (
    emoji: '🍄‍🟫',
    group: Category.FOODS,
    version: 15.1,
    keywords: 'brown mushroom | mushroom | fungus',
    hasSkinTone: false,
  ),
  (
    emoji: '⛓️‍💥',
    group: Category.OBJECTS,
    version: 15.1,
    keywords: 'broken chain | break | free',
    hasSkinTone: false,
  ),
  // Emoji 16.0
  (
    emoji: '🫩',
    group: Category.SMILEYS,
    version: 16.0,
    keywords: 'face with bags under eyes | tired | exhausted | sleepy',
    hasSkinTone: false,
  ),
  (
    emoji: '🫆',
    group: Category.SMILEYS,
    version: 16.0,
    keywords: 'fingerprint | identity | forensics',
    hasSkinTone: false,
  ),
  (
    emoji: '🪾',
    group: Category.ANIMALS,
    version: 16.0,
    keywords: 'leafless tree | tree | winter | bare',
    hasSkinTone: false,
  ),
  (
    emoji: '🫜',
    group: Category.FOODS,
    version: 16.0,
    keywords: 'root vegetable | beet | turnip | radish',
    hasSkinTone: false,
  ),
  (
    emoji: '🪉',
    group: Category.OBJECTS,
    version: 16.0,
    keywords: 'harp | music | instrument',
    hasSkinTone: false,
  ),
  (
    emoji: '🪏',
    group: Category.OBJECTS,
    version: 16.0,
    keywords: 'shovel | dig | spade',
    hasSkinTone: false,
  ),
  (
    emoji: '🫟',
    group: Category.ACTIVITIES,
    version: 16.0,
    keywords: 'splatter | paint | splash | stain',
    hasSkinTone: false,
  ),
  (
    emoji: '🇨🇶',
    group: Category.FLAGS,
    version: 16.0,
    keywords: 'flag sark | sark',
    hasSkinTone: false,
  ),
];
