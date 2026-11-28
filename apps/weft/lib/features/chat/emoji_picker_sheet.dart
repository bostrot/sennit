import 'dart:math' as math;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' show Category;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import '../../app/localisation.dart';
import '../../app/stores.dart';
import 'emoji_catalogue.dart';

/// The reactions offered without opening anything.
///
/// The first four are fixed, because this row is the one that appears on a
/// long-press and muscle memory is the whole point of it: a row that reorders
/// itself as the user reacts means the thumbs-up is in a different place every
/// week. The last two are where these two sit until the reader picks something
/// else — see [quickReactionsWith].
const List<String> kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// How many of [kQuickReactions] never move.
const int kQuickReactionsFixed = 4;

/// The quick row for a reader whose recent reactions are [recents].
///
/// Same length as [kQuickReactions], so the row still fits a phone on one
/// line: the fixed four, then the reader's two latest picks from outside them,
/// topped up with the defaults when there are fewer than two. A custom emoji
/// is never one of them — this row draws keys as text, and its URI would wrap
/// the row round itself; see `isImageReactionKey`.
List<String> quickReactionsWith(List<String> recents) {
  final fixed = kQuickReactions.take(kQuickReactionsFixed).toList();
  final taken = {for (final k in fixed) normaliseReactionKey(k)};
  final tail = <String>[];
  for (final key in [
    ...recents,
    ...kQuickReactions.skip(kQuickReactionsFixed),
  ]) {
    if (tail.length == kQuickReactions.length - kQuickReactionsFixed) break;
    if (isImageReactionKey(key)) continue;
    if (taken.add(normaliseReactionKey(key))) tail.add(key);
  }
  return [...fixed, ...tail];
}

/// How many recent reactions the picker remembers.
const int kReactionRecentsLimit = 32;

/// Where [ReactionRecents] and [ReactionSkinTone] keep their answers.
const kReactionRecentsSetting = 'reactions.recent';
const kReactionSkinToneSetting = 'reactions.skin_tone';

/// Reactions the user has sent, most recent first.
///
/// Kept as sent, so a recent ❤️ is drawn as the emoji and not as the bare ❤
/// text glyph it normalises to, but compared normalised, so `👍` sent from one
/// client and `👍️` from another do not fill the row with the same emoji twice.
class ReactionRecents extends Notifier<List<String>> {
  @override
  List<String> build() {
    final saved = storesOrNull(
      ref,
    )?.settings.getJson(kReactionRecentsSetting)?['keys'];
    return saved is List
        ? [
            // Older builds noted custom emoji too; the picker and the quick
            // row draw these as text, so they are dropped on the way in.
            for (final key in saved)
              if (key is String && !isImageReactionKey(key)) key,
          ]
        : const [];
  }

  void note(String key) {
    final normalised = normaliseReactionKey(key);
    if (normalised.isEmpty || isImageReactionKey(normalised)) return;
    state = [
      key.trim(),
      ...state.where((k) => normaliseReactionKey(k) != normalised),
    ].take(kReactionRecentsLimit).toList(growable: false);
    storesOrNull(
      ref,
    )?.settings.setJson(kReactionRecentsSetting, {'keys': state});
  }
}

final reactionRecentsProvider = NotifierProvider<ReactionRecents, List<String>>(
  ReactionRecents.new,
);

/// The skin tone the picker puts on people and hands, or null for none.
class ReactionSkinTone extends Notifier<String?> {
  @override
  String? build() {
    final saved = storesOrNull(
      ref,
    )?.settings.getString(kReactionSkinToneSetting);
    return kSkinTones.contains(saved) ? saved : null;
  }

  void choose(String? tone) {
    state = tone;
    final settings = storesOrNull(ref)?.settings;
    if (tone == null) {
      settings?.remove(kReactionSkinToneSetting);
    } else {
      settings?.setString(kReactionSkinToneSetting, tone);
    }
  }
}

final reactionSkinToneProvider = NotifierProvider<ReactionSkinTone, String?>(
  ReactionSkinTone.new,
);

/// Picks a reaction. Returns null when the panel is dismissed.
///
/// [anchorContext] is the control it was opened from — the "+" on a message's
/// reaction bar, or the row in its action menu. On a desktop that turns the
/// panel into a popover beside *that message*, which is the whole of what a
/// reaction picker is for; without it the picker drops from the top of the
/// window and gives no clue which message it is about.
Future<String?> showEmojiPickerSheet(
  BuildContext context, {
  BuildContext? anchorContext,
}) {
  return showWeftPanel<String>(
    context: context,
    anchorContext: anchorContext,
    showDragHandle: true,
    isScrollControlled: true,
    width: 360,
    builder: (_) => const EmojiPicker(),
  );
}

/// Every emoji the device can draw: a search field, the skin tone, a tab per
/// group, and the reader's recents first.
class EmojiPicker extends ConsumerStatefulWidget {
  const EmojiPicker({super.key});

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

/// `null` is the recents tab.
typedef _Tab = Category?;

class _EmojiPickerState extends ConsumerState<EmojiPicker> {
  final _search = TextEditingController();
  _Tab? _tab;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(String key) => Navigator.of(context).pop(key);

  @override
  Widget build(BuildContext context) {
    final recents = ref.watch(reactionRecentsProvider);
    final tone = ref.watch(reactionSkinToneProvider);
    final language = Localizations.localeOf(context).languageCode;
    final catalogue = ref.watch(emojiCatalogueProvider(language));
    final query = _search.text.trim();

    // Recents first when there are any: they are what a picker is opened for
    // more often than not.
    final tabs = <_Tab>[if (recents.isNotEmpty) null, ...kEmojiGroups];
    final tab = tabs.contains(_tab) ? _tab : tabs.first;

    final height = context.isDesktop
        ? 420.0
        : MediaQuery.sizeOf(context).height * 0.6;

    return SafeArea(
      top: false,
      child: Padding(
        // The search field brings the keyboard up; the grid stays above it.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  WeftSpace.lg,
                  0,
                  WeftSpace.sm,
                  WeftSpace.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        // A keyboard that rises over the grid the moment the
                        // picker opens hides what most readers came for; a
                        // desktop has nowhere for it to rise.
                        autofocus: context.isDesktop,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search_rounded),
                          hintText: context.l10n.emojiPickerSearchHint,
                          border: OutlineInputBorder(
                            borderRadius: WeftRadius.pill,
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                        ),
                      ),
                    ),
                    _SkinTonePicker(
                      tone: tone,
                      onChanged: (t) =>
                          ref.read(reactionSkinToneProvider.notifier).choose(t),
                    ),
                  ],
                ),
              ),
              if (query.isEmpty)
                _GroupTabs(
                  tabs: tabs,
                  selected: tab,
                  onSelected: (t) => setState(() => _tab = t),
                ),
              Expanded(
                child: catalogue.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => const SizedBox.shrink(),
                  data: (catalogue) {
                    final List<String> emoji;
                    final String? heading;
                    if (query.isNotEmpty) {
                      emoji = [
                        for (final e in catalogue.search(query)) e.toned(tone),
                      ];
                      heading = null;
                    } else if (tab == null) {
                      emoji = recents;
                      heading = context.l10n.emojiGroupRecent;
                    } else {
                      emoji = [
                        for (final e in catalogue.groups[tab]!) e.toned(tone),
                      ];
                      heading = _groupName(context, tab);
                    }
                    if (emoji.isEmpty && query.isNotEmpty) {
                      return Center(
                        child: Text(
                          context.l10n.emojiPickerNoResults,
                          style: context.text.bodyMedium?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    return _EmojiGrid(
                      key: ValueKey(query.isEmpty ? tab : query),
                      heading: heading,
                      emoji: emoji,
                      onPick: _pick,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _groupName(BuildContext context, _Tab tab) {
  final l10n = context.l10n;
  return switch (tab) {
    null || Category.RECENT => l10n.emojiGroupRecent,
    Category.SMILEYS => l10n.emojiGroupSmileys,
    Category.ANIMALS => l10n.emojiGroupAnimals,
    Category.FOODS => l10n.emojiGroupFood,
    Category.ACTIVITIES => l10n.emojiGroupActivities,
    Category.TRAVEL => l10n.emojiGroupTravel,
    Category.OBJECTS => l10n.emojiGroupObjects,
    Category.SYMBOLS => l10n.emojiGroupSymbols,
    Category.FLAGS => l10n.emojiGroupFlags,
  };
}

IconData _groupIcon(_Tab tab) => switch (tab) {
  null || Category.RECENT => Icons.history_rounded,
  Category.SMILEYS => Icons.emoji_emotions_outlined,
  Category.ANIMALS => Icons.pets_outlined,
  Category.FOODS => Icons.fastfood_outlined,
  Category.ACTIVITIES => Icons.sports_soccer_outlined,
  Category.TRAVEL => Icons.directions_car_outlined,
  Category.OBJECTS => Icons.lightbulb_outline_rounded,
  Category.SYMBOLS => Icons.emoji_symbols_outlined,
  Category.FLAGS => Icons.flag_outlined,
};

class _GroupTabs extends StatelessWidget {
  const _GroupTabs({
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<_Tab> tabs;
  final _Tab selected;
  final ValueChanged<_Tab> onSelected;

  @override
  Widget build(BuildContext context) {
    // Scrolls rather than squeezes: nine 48dp targets are wider than the
    // narrowest phone, and a tab shrunk below a thumb is worse than one
    // reached by a flick.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: WeftSpace.sm),
      child: Row(
        children: [
          for (final tab in tabs)
            IconButton(
              tooltip: _groupName(context, tab),
              isSelected: tab == selected,
              color: context.colors.onSurfaceVariant,
              selectedIcon: Icon(
                _groupIcon(tab),
                color: context.colors.primary,
              ),
              icon: Icon(_groupIcon(tab)),
              onPressed: () => onSelected(tab),
            ),
        ],
      ),
    );
  }
}

class _SkinTonePicker extends StatelessWidget {
  const _SkinTonePicker({required this.tone, required this.onChanged});

  final String? tone;
  final ValueChanged<String?> onChanged;

  static String _hand(String? tone) => tone == null ? '✋' : '✋$tone';

  static String _name(BuildContext context, String? tone) {
    final index = kSkinTones.indexOf(tone);
    return context.l10n.emojiSkinToneName(
      const [
        'none',
        'light',
        'mediumLight',
        'medium',
        'mediumDark',
        'dark',
      ][index < 0 ? 0 : index],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: context.l10n.emojiSkinTone,
      initialValue: kSkinTones.indexOf(tone),
      onSelected: (i) => onChanged(kSkinTones[i]),
      itemBuilder: (context) => [
        for (var i = 0; i < kSkinTones.length; i++)
          PopupMenuItem(
            value: i,
            child: Semantics(
              label: _name(context, kSkinTones[i]),
              excludeSemantics: true,
              child: Row(
                children: [
                  Text(
                    _hand(kSkinTones[i]),
                    style: const TextStyle(fontSize: 22),
                  ),
                  const SizedBox(width: WeftSpace.sm),
                  Text(_name(context, kSkinTones[i])),
                ],
              ),
            ),
          ),
      ],
      child: Semantics(
        label: context.l10n.emojiSkinTone,
        value: _name(context, tone),
        excludeSemantics: true,
        child: WeftTapTarget(
          child: Padding(
            padding: const EdgeInsets.all(WeftSpace.sm),
            child: Text(_hand(tone), style: const TextStyle(fontSize: 22)),
          ),
        ),
      ),
    );
  }
}

/// The narrowest an emoji cell is allowed to be: a thumb.
const double _cell = 48;

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid({
    super.key,
    required this.heading,
    required this.emoji,
    required this.onPick,
  });

  final String? heading;
  final List<String> emoji;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => CustomScrollView(
        slivers: [
          if (heading != null)
            SliverPadding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                WeftSpace.lg,
                WeftSpace.xs,
                WeftSpace.lg,
                WeftSpace.xs,
              ),
              // A header, so a reader stepping through the grid knows which of
              // the groups the several hundred emoji after it belong to.
              sliver: SliverToBoxAdapter(
                child: Semantics(
                  header: true,
                  child: Text(
                    heading!,
                    style: context.text.labelMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              WeftSpace.md,
              0,
              WeftSpace.md,
              WeftSpace.lg,
            ),
            // Built lazily: the full set is close to two thousand cells, and a
            // `Wrap` lays out every one of them before the first frame.
            sliver: SliverGrid.builder(
              // As many whole 48dp cells as fit, each then a little wider: a
              // maximum extent would round the other way, and every cell would
              // fall a fraction short of a thumb.
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: math.max(
                  1,
                  (constraints.maxWidth - 2 * WeftSpace.md) ~/ _cell,
                ),
              ),
              itemCount: emoji.length,
              itemBuilder: (context, i) => _EmojiCell(emoji[i], onPick: onPick),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmojiCell extends StatelessWidget {
  const _EmojiCell(this.emoji, {required this.onPick});

  final String emoji;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    // `button: true` is the whole of it: a glyph in an `InkWell` is met by a
    // reader as a character rather than as something it can press.
    return Semantics(
      button: true,
      label: emoji,
      excludeSemantics: true,
      onTap: () => onPick(emoji),
      child: InkWell(
        onTap: () => onPick(emoji),
        borderRadius: WeftRadius.allSm,
        child: Center(
          // Scaled down rather than clipped when the reader's text is large:
          // the cell is already the full width of a thumb.
          child: FittedBox(
            child: Text(emoji, style: const TextStyle(fontSize: 28)),
          ),
        ),
      ),
    );
  }
}
