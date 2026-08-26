import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_richtext/weft_richtext.dart';

/// The six reactions offered without opening anything.
///
/// A fixed set rather than the user's most-used, because this row is the one
/// that appears on a long-press and muscle memory is the whole point of it: a
/// row that reorders itself as the user reacts means the thumbs-up is in a
/// different place every week.
const List<String> kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// How many recent reactions the picker remembers.
const int kReactionRecentsLimit = 16;

/// Reactions the user has sent, most recent first.
///
/// In memory for this session only, in the same shape and for the same reason
/// as `WeftAppearance`: `weft_store` grows a settings row for it alongside the
/// rest of the preferences surface, and inventing a migration for a list of
/// emoji ahead of that would be a schema change nothing else is ready for.
///
/// Keys are normalised on the way in, so `👍` sent from one client and `👍️`
/// from another do not fill the row with the same emoji twice.
class ReactionRecents extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void note(String key) {
    final normalised = normaliseReactionKey(key);
    if (normalised.isEmpty) return;
    state = [
      normalised,
      ...state.where((k) => k != normalised),
    ].take(kReactionRecentsLimit).toList(growable: false);
  }
}

final reactionRecentsProvider = NotifierProvider<ReactionRecents, List<String>>(
  ReactionRecents.new,
);

/// Picks a reaction. Returns null when the sheet is dismissed.
Future<String?> showEmojiPickerSheet(BuildContext context) {
  return showWeftPanel<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _EmojiPickerSheet(),
  );
}

class _EmojiPickerSheet extends ConsumerWidget {
  const _EmojiPickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(reactionRecentsProvider);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.lg,
            0,
            WeftSpace.lg,
            WeftSpace.lg,
          ),
          children: [
            if (recents.isNotEmpty) ...[
              _Heading('Recent'),
              _EmojiWrap(
                emoji: recents,
                onPick: (key) => Navigator.of(context).pop(key),
              ),
              const SizedBox(height: WeftSpace.md),
            ],
            for (final group in _emojiGroups) ...[
              _Heading(group.name),
              _EmojiWrap(
                emoji: group.emoji,
                onPick: (key) => Navigator.of(context).pop(key),
              ),
              const SizedBox(height: WeftSpace.md),
            ],
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    // A header, so the groups are navigable rather than being one long run of
    // several hundred emoji the reader has to step through in order.
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.sm),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: context.text.labelMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _EmojiWrap extends StatelessWidget {
  const _EmojiWrap({required this.emoji, required this.onPick});

  final List<String> emoji;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      children: [
        for (final key in emoji)
          // `button: true` is the whole of it: the cell was an `InkWell` over a
          // glyph, which a reader meets as a character rather than as something
          // it can press.
          Semantics(
            button: true,
            label: key,
            excludeSemantics: true,
            onTap: () => onPick(key),
            // 20dp wide before this, in a grid of hundreds where every
            // neighbour is a different reaction. The glyph still paints at 26;
            // what grows is the box around it, and the `Wrap`'s own spacing is
            // dropped below because the padding now provides it.
            child: WeftTapTarget(
              child: InkWell(
                onTap: () => onPick(key),
                borderRadius: WeftRadius.allSm,
                child: Padding(
                  padding: const EdgeInsets.all(WeftSpace.xs),
                  child: Text(key, style: const TextStyle(fontSize: 26)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The offered set.
///
/// Hand-picked rather than the full Unicode tables: a complete picker is a
/// package and a font of its own, and what a reaction picker is actually used
/// for is a short list of reactions. Grouped so the row a reader is reaching
/// for stays in the same place between releases.
const List<({String name, List<String> emoji})> _emojiGroups = [
  (
    name: 'Reactions',
    emoji: [
      '👍',
      '👎',
      '❤️',
      '🔥',
      '🎉',
      '👏',
      '🙏',
      '💯',
      '✅',
      '❌',
      '👀',
      '🤝',
    ],
  ),
  (
    name: 'Faces',
    emoji: [
      '😀',
      '😂',
      '🥲',
      '😊',
      '😍',
      '😘',
      '🤔',
      '😐',
      '🙄',
      '😴',
      '😭',
      '😡',
      '😱',
      '🤯',
      '🥳',
      '😎',
      '🤒',
      '🤮',
    ],
  ),
  (name: 'Hands', emoji: ['👋', '🤙', '✌️', '🤞', '👌', '🫶', '💪', '🖐️']),
  (
    name: 'Things',
    emoji: [
      '☕',
      '🍕',
      '🍺',
      '🎂',
      '🎁',
      '⚽',
      '🚗',
      '✈️',
      '🏠',
      '💡',
      '📎',
      '⏰',
      '📌',
      '💰',
      '🎵',
      '📷',
    ],
  ),
  (name: 'Nature', emoji: ['🌞', '🌧️', '❄️', '🌈', '🌱', '🌸', '🐶', '🐱']),
];
