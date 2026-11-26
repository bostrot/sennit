import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';

/// A poll: the question, one tappable row per option, and the running tally.
///
/// Votes are MSC3381's: each voter's latest response counts, so tapping again
/// changes the vote rather than adding one. A single-choice poll moves the
/// vote; a multiple-choice one toggles the row. An undisclosed poll shows
/// only the reader's own pick until it ends, and a closed poll ignores taps
/// and marks the winning answer.
class PollCard extends StatelessWidget {
  const PollCard({
    super.key,
    required this.poll,
    required this.own,
    this.onVote,
    this.onEnd,
  });

  final PollData poll;

  /// Whether the bubble is the reader's own, which only decides the colours.
  final bool own;

  /// Sends the selection a tap leads to. Null where nothing on a message
  /// acts, such as a preview.
  final ValueChanged<Set<String>>? onVote;

  /// Closes the poll. Null unless the reader started it, it is still open,
  /// and the network carries the end.
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = context.l10n;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final muted = palette.mutedOnBubble(own);
    // People, not selections: in a multiple-choice poll three voters can cast
    // seven votes, and the bar should say what share of *people* chose a row.
    final people = poll.voterCount > 0 ? poll.voterCount : poll.totalVotes;
    final shown = poll.resultsVisible;
    final top = poll.votes.values.fold(0, (a, b) => a > b ? a : b);
    final canVote = !poll.ended && onVote != null;

    final notes = [
      if (poll.multipleChoice) l10n.chatPollChooseUpTo(poll.maxSelections),
      if (!shown) l10n.chatPollResultsHidden,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 2),
              child: Icon(Icons.poll_rounded, size: 18, color: onBubble),
            ),
            const SizedBox(width: WeftSpace.sm),
            Flexible(
              child: Text(
                poll.question,
                style: context.text.bodyMedium?.copyWith(
                  color: onBubble,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: WeftSpace.xs),
          Text(
            notes.join(' · '),
            style: context.text.labelSmall?.copyWith(color: muted),
          ),
        ],
        const SizedBox(height: WeftSpace.sm),
        for (final option in poll.options) ...[
          PollOptionRow(
            option: option,
            votes: poll.votes[option.id] ?? 0,
            people: people,
            showCount: shown,
            chosen: poll.ownVotes.contains(option.id),
            multipleChoice: poll.multipleChoice,
            winner: poll.ended && top > 0 && poll.votes[option.id] == top,
            ended: poll.ended,
            own: own,
            onTap: canVote
                ? () {
                    final next = poll.selectionAfterTap(option.id);
                    if (next != null) onVote!(next);
                  }
                : null,
          ),
          const SizedBox(height: WeftSpace.xs),
        ],
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: WeftSpace.sm,
          children: [
            Text(
              poll.ended
                  ? l10n.chatPollFinalResult(people)
                  : l10n.chatPollVotes(people),
              style: context.text.labelSmall?.copyWith(color: muted),
            ),
            if (shown && poll.voters.isNotEmpty)
              _FooterButton(
                label: l10n.chatPollViewVotes,
                color: onBubble,
                onTap: () => showPollVotesSheet(context, poll),
              ),
            if (onEnd != null && !poll.ended)
              _FooterButton(
                label: l10n.chatPollEnd,
                color: onBubble,
                onTap: onEnd!,
              ),
          ],
        ),
      ],
    );
  }
}

class _FooterButton extends StatelessWidget {
  const _FooterButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: color,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: WeftSpace.sm),
        textStyle: context.text.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      child: Text(label),
    );
  }
}

/// One answer of a poll: a check, the text, and — where results show — the
/// count with a bar behind the row for its share.
class PollOptionRow extends StatelessWidget {
  const PollOptionRow({
    super.key,
    required this.option,
    required this.votes,
    required this.people,
    required this.showCount,
    required this.chosen,
    required this.multipleChoice,
    required this.winner,
    required this.ended,
    required this.own,
    this.onTap,
  });

  final PollOption option;
  final int votes;
  final int people;
  final bool showCount;
  final bool chosen;
  final bool multipleChoice;
  final bool winner;
  final bool ended;
  final bool own;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = context.l10n;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final share = !showCount || people == 0 ? 0.0 : votes / people;
    final icon = switch ((chosen, multipleChoice)) {
      (true, true) => Icons.check_box_rounded,
      (false, true) => Icons.check_box_outline_blank_rounded,
      (true, false) => Icons.check_circle_rounded,
      (false, false) => Icons.circle_outlined,
    };

    return WeftFocusable(
      button: onTap != null,
      selected: chosen,
      onTap: onTap,
      label: semanticsSentence([
        option.text,
        if (showCount) l10n.chatPollVotes(votes),
        if (chosen) l10n.chatPollYourVote,
        if (ended)
          l10n.chatPollClosed
        else if (onTap != null)
          l10n.chatPollTapToVote,
      ]),
      borderRadius: WeftRadius.allSm,
      child: Stack(
        children: [
          // The share bar, behind the words. Directional, so it grows from
          // the right in Arabic.
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: share.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: onBubble.withValues(alpha: winner ? 0.28 : 0.15),
                  borderRadius: WeftRadius.allSm,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WeftSpace.sm,
              vertical: WeftSpace.sm,
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: onBubble),
                const SizedBox(width: WeftSpace.sm),
                Expanded(
                  child: Text(
                    option.text,
                    style: context.text.bodySmall?.copyWith(
                      color: onBubble,
                      fontWeight: winner ? FontWeight.w700 : null,
                    ),
                  ),
                ),
                if (showCount) ...[
                  const SizedBox(width: WeftSpace.sm),
                  Text(
                    l10n.chatPollOptionVotes(votes),
                    style: context.text.labelSmall?.copyWith(
                      color: palette.mutedOnBubble(own),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Who chose what, one section per answer.
Future<void> showPollVotesSheet(BuildContext context, PollData poll) {
  return showWeftPanel<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final l10n = context.l10n;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.xl,
            0,
            WeftSpace.xl,
            WeftSpace.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  poll.question,
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final option in poll.options) ...[
                const SizedBox(height: WeftSpace.md),
                Row(
                  children: [
                    Expanded(
                      child: Text(option.text, style: context.text.titleSmall),
                    ),
                    Text(
                      l10n.chatPollVotes(poll.votes[option.id] ?? 0),
                      style: context.text.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: WeftSpace.xs),
                Text(
                  (poll.voters[option.id] ?? const []).isEmpty
                      ? l10n.chatPollNoVotes
                      : poll.voters[option.id]!.join(', '),
                  style: context.text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// What the poll composer hands back.
@immutable
class PollDraft {
  const PollDraft({
    required this.question,
    required this.options,
    this.multipleChoice = false,
    this.undisclosed = false,
  });

  final String question;
  final List<String> options;
  final bool multipleChoice;
  final bool undisclosed;
}

/// The question, two to [PollSupport.maxOptions] answers, and the kinds of
/// poll the chat's network carries; pops a [PollDraft] or null.
class PollComposerDialog extends StatefulWidget {
  const PollComposerDialog({super.key, this.support = const PollSupport()});

  final PollSupport support;

  @override
  State<PollComposerDialog> createState() => _PollComposerDialogState();
}

class _PollComposerDialogState extends State<PollComposerDialog> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  late bool _multipleChoice = widget.support.multipleChoiceOnly;
  bool _undisclosed = false;
  bool _duplicates = false;

  int get _maxOptions => widget.support.maxOptions.clamp(
    PollSupport.minAnswers,
    PollSupport.maxAnswers,
  );

  @override
  void dispose() {
    _question.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final question = _question.text.trim();
    final options = [
      for (final option in _options)
        if (option.text.trim().isNotEmpty) option.text.trim(),
    ];
    if (question.isEmpty || options.length < PollSupport.minAnswers) return;
    // Two identical answers are two rows nobody can tell apart, and the
    // networks that index answers by their text refuse them outright.
    final distinct = options.map((o) => o.toLowerCase()).toSet();
    if (distinct.length != options.length) {
      setState(() => _duplicates = true);
      return;
    }
    Navigator.of(context).pop(
      PollDraft(
        question: question,
        options: options,
        multipleChoice: _multipleChoice,
        undisclosed: _undisclosed,
      ),
    );
  }

  void _remove(int index) {
    setState(() {
      _options.removeAt(index).dispose();
      _duplicates = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final support = widget.support;
    final maxLength = support.optionMaxLength > 0
        ? support.optionMaxLength
        : null;

    return AlertDialog(
      title: Text(l10n.chatNewPollTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _question,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: l10n.chatPollQuestion),
              ),
              const SizedBox(height: WeftSpace.sm),
              for (var i = 0; i < _options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: WeftSpace.sm),
                  child: TextField(
                    key: ValueKey(_options[i]),
                    controller: _options[i],
                    maxLength: maxLength,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) {
                      if (_duplicates) setState(() => _duplicates = false);
                    },
                    decoration: InputDecoration(
                      labelText: l10n.chatPollOptionN(i + 1),
                      counterText: '',
                      suffixIcon: _options.length > PollSupport.minAnswers
                          ? IconButton(
                              tooltip: l10n.chatPollRemoveOption,
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => _remove(i),
                            )
                          : null,
                    ),
                  ),
                ),
              if (_duplicates)
                Padding(
                  padding: const EdgeInsets.only(bottom: WeftSpace.sm),
                  child: Text(
                    l10n.chatPollOptionsDistinct,
                    style: context.text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_options.length < _maxOptions)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _options.add(TextEditingController())),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(l10n.chatPollAddOption),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.chatPollMultipleChoice),
                subtitle: support.multipleChoiceOnly
                    ? Text(l10n.chatPollMultipleChoiceOnly)
                    : null,
                value: _multipleChoice,
                onChanged: support.multipleChoiceOnly
                    ? null
                    : (on) => setState(() => _multipleChoice = on),
              ),
              if (support.undisclosed)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.chatPollHideResults),
                  value: _undisclosed,
                  onChanged: (on) => setState(() => _undisclosed = on),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.chatPollCreate)),
      ],
    );
  }
}
