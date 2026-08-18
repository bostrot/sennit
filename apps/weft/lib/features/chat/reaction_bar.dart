import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// The tally chips under a bubble.
///
/// One chip per key, counting *people* — the tallies arrive from
/// `aggregateReactions`, which has already collapsed the same person reacting
/// on two legs of a merged chat into one. Nothing here counts anything; a bar
/// that did its own arithmetic would be a second answer to a question the
/// aggregation has already settled.
///
/// Order is the aggregation's — first reaction first, never by count. A bar
/// sorted by count reshuffles while the reader is looking at it and moves the
/// chip out from under a thumb already travelling towards it.
class ReactionBar extends StatelessWidget {
  const ReactionBar({
    super.key,
    required this.tallies,
    required this.own,
    required this.onToggle,
    this.onShowSenders,
    this.onAdd,
  });

  final List<ReactionTally> tallies;

  /// Which side of the thread the bar belongs to, so it lines up with the
  /// bubble above it rather than floating in the middle.
  final bool own;

  final ValueChanged<ReactionTally> onToggle;

  /// Long-press: who reacted. Null leaves the chip tap-only.
  final ValueChanged<ReactionTally>? onShowSenders;

  /// The trailing "+" that opens the picker. Null hides it — a bubble whose
  /// message cannot be reacted to at all.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    if (tallies.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.xs),
      child: Wrap(
        spacing: WeftSpace.xs,
        runSpacing: WeftSpace.xs,
        alignment: own ? WrapAlignment.end : WrapAlignment.start,
        children: [
          for (final tally in tallies)
            ReactionChip(
              tally: tally,
              onTap: () => onToggle(tally),
              onLongPress: onShowSenders == null
                  ? null
                  : () => onShowSenders!(tally),
            ),
          if (onAdd != null) _AddReactionChip(onTap: onAdd!),
        ],
      ),
    );
  }
}

/// One key's chip: the emoji, the count, and whether it is the reader's.
class ReactionChip extends StatelessWidget {
  const ReactionChip({
    super.key,
    required this.tally,
    this.onTap,
    this.onLongPress,
  });

  final ReactionTally tally;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final mine = tally.byLocalUser;
    final accent = context.colors.primary;

    return Semantics(
      button: true,
      selected: mine,
      label: '${tally.key} ${tally.count}',
      child: Material(
        color: mine
            ? accent.withValues(alpha: 0.22)
            : context.colors.surfaceContainerHighest,
        borderRadius: WeftRadius.pill,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: WeftMotion.fast,
            curve: WeftMotion.standard,
            padding: const EdgeInsets.symmetric(
              horizontal: WeftSpace.sm,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              borderRadius: WeftRadius.pill,
              // The reader's own reaction is outlined as well as tinted:
              // colour alone is the one difference a colour-blind reader
              // cannot use to tell "I reacted" from "someone did".
              border: Border.all(
                color: mine ? accent : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tally.key, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: WeftSpace.xs),
                Text(
                  '${tally.count}',
                  style: context.text.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: mine ? accent : context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddReactionChip extends StatelessWidget {
  const _AddReactionChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.surfaceContainerHighest,
      borderRadius: WeftRadius.pill,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: WeftSpace.sm,
            vertical: 4,
          ),
          child: Icon(
            Icons.add_reaction_outlined,
            size: 14,
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Who reacted with one key.
///
/// [nameFor] resolves a sender id to something a human recognises. The tally
/// carries *handles*, not unified contact ids, precisely so this sheet can name
/// the person who actually pressed the emoji rather than the contact they were
/// merged into — in a merged chat those are different answers, and "Anna
/// (WhatsApp)" is the useful one.
Future<void> showReactionSendersSheet(
  BuildContext context, {
  required ReactionTally tally,
  required String Function(String senderId) nameFor,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WeftSpace.xl,
              0,
              WeftSpace.xl,
              WeftSpace.sm,
            ),
            child: Row(
              children: [
                Text(tally.key, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: WeftSpace.sm),
                Text(
                  tally.count == 1 ? '1 person' : '${tally.count} people',
                  style: context.text.titleSmall,
                ),
              ],
            ),
          ),
          for (final senderId in tally.senderIds)
            ListTile(
              dense: true,
              leading: WeftAvatar(label: nameFor(senderId), size: 32),
              title: Text(nameFor(senderId)),
              subtitle: Text(
                senderId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
