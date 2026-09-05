import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';

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
  /// Opens the picker, given the chip's own context to hang a popover on.
  final ValueChanged<BuildContext>? onAdd;

  @override
  Widget build(BuildContext context) {
    if (tallies.isEmpty) return const SizedBox.shrink();

    final people = tallies.fold(0, (sum, t) => sum + t.count);

    // A summary node over the chips, not instead of them: the chips are
    // controls and have to stay individually reachable, but a reader arriving
    // at a bubble should learn "3 reactions" in one breath rather than by
    // stepping through them to count.
    return Semantics(
      container: true,
      label: context.l10n.reactionsSummary(people),
      // No padding of its own any more. Every chip below carries a 48dp tap
      // target around a pill that still paints at its old size, so the gap this
      // used to add is now inside the chips — spare height that is live rather
      // than dead, since a tap anywhere in it reaches the chip.
      //
      // That spare height is aligned to the *top* of each chip
      // (`WeftTapTarget.alignment`), which is what makes the pills sit against
      // the bubble instead of floating half a thumb below it. [runSpacing] is
      // the gap between rows of a bar that wrapped, and was missing entirely —
      // a second row of reactions was flush against the first.
      child: Wrap(
        spacing: WeftSpace.xs,
        runSpacing: WeftSpace.xxs,
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
      // The `InkWell` builds a node of its own from the emoji and the count —
      // "👍\n2", the pill's size, with the tap on it — so without this the
      // chip is two nodes, and the inner one is the 28dp target the outer one
      // exists to replace. Excluding it takes the tap with it, hence the
      // restatement below.
      excludeSemantics: true,
      onTap: onTap,
      // The long-press — who reacted — was an action a screen reader had no way
      // to discover. Naming it puts it in the actions rotor beside the tap.
      onLongPress: onLongPress,
      onLongPressHint: onLongPress == null
          ? null
          : context.l10n.reactionSeeWhoHint,
      label: context.l10n.reactionChipSemantics(tally.key, tally.count),
      // Inside the annotation, so the node the reader touches and the box the
      // guideline measures are both the grown one. A 28dp pill is comfortable
      // to read and roughly half of what a thumb can be asked to find.
      //
      // Grown *downwards*: the extra height a thumb needs is spent in the
      // margin before the next message rather than half above the pill, which
      // is what used to hold the bar a finger's width off the bubble it
      // belongs to. The target is the same size; only the ink moved.
      child: WeftTapTarget(
        alignment: Alignment.topCenter,
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
                vertical: WeftSpace.xxs,
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
                    context.l10n.reactionCount(tally.count),
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
      ),
    );
  }
}

class _AddReactionChip extends StatelessWidget {
  const _AddReactionChip({required this.onTap});

  /// Given this chip's own context, so a popover opens *at the chip* rather
  /// than at whatever ancestor happened to hold the callback.
  final ValueChanged<BuildContext> onTap;

  @override
  Widget build(BuildContext context) {
    // The one chip in the bar with no text in it, and so the one that announced
    // nothing: an unlabelled button sitting after a row of labelled ones.
    return Semantics(
      button: true,
      label: context.l10n.reactionAdd,
      excludeSemantics: true,
      onTap: () => onTap(context),
      // Top-aligned like its neighbours, or the "+" would sit half a chip lower
      // than the tallies it follows.
      child: WeftTapTarget(
        alignment: Alignment.topCenter,
        child: Tooltip(
          message: context.l10n.reactionAdd,
          excludeFromSemantics: true,
          child: Material(
            color: context.colors.surfaceContainerHighest,
            borderRadius: WeftRadius.pill,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onTap(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: WeftSpace.sm,
                  vertical: WeftSpace.xs,
                ),
                child: Icon(
                  Icons.add_reaction_outlined,
                  size: 14,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
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
  return showWeftPanel<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
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
                  context.l10n.reactionPeopleCount(tally.count),
                  style: context.text.titleSmall,
                ),
              ],
            ),
          ),
          for (final senderId in tally.senderIds)
            // The handle stays on screen — in a merged chat it is what tells
            // "Anna on WhatsApp" from "Anna on Signal" — but it is not read
            // aloud. `@anna:matrix.example.org` announced character by
            // character is thirty syllables of noise per row, and the name
            // above it is the answer to the question the sheet asks.
            Semantics(
              label: nameFor(senderId),
              excludeSemantics: true,
              child: ListTile(
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
            ),
        ],
      ),
    ),
  );
}
