import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// "Which app does this actually go out on?", as a chip.
///
/// Lives in its own file because the answer has to be given in two places now:
/// the composer, where it has always been, and the attachment preview sheet,
/// where a share of six photos is about to leave on whichever network is
/// selected. Two chips that could disagree would be worse than none.
class SendNetworkChip extends StatelessWidget {
  const SendNetworkChip({
    super.key,
    required this.chat,
    required this.current,
    required this.onPick,
    this.networks,
  });

  final Chat chat;
  final ChatNetwork current;
  final ValueChanged<ChatNetwork> onPick;

  /// The legs actually offered, or null for all of [Chat.networks].
  ///
  /// Narrowed by the share sheet to the networks that can carry the file being
  /// shared. A menu that lists Signal for a 200 MB video is a menu whose entries
  /// are not all choices — picking that one is picking a send that fails — and
  /// the WhatsApp leg beside it reaches the same person.
  final List<ChatNetwork>? networks;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.networkColor(current);

    return PopupMenuButton<ChatNetwork>(
      // The current leg, not just the verb. "Send via…" never said *what is
      // selected right now*, and the only other indication is an 18dp logo —
      // so the one fact this chip exists to state was the one it withheld.
      tooltip: 'Send via ${current.label}',
      onSelected: onPick,
      itemBuilder: (context) => [
        for (final n in networks ?? chat.networks)
          PopupMenuItem(
            value: n,
            // The tick beside the current entry is purely visual; `selected`
            // is how a reader is told which of the legs it is already on.
            child: Semantics(
              selected: n == current,
              container: true,
              excludeSemantics: true,
              label: n.label,
              child: Row(
                children: [
                  NetworkGlyph(network: n, size: 20),
                  const SizedBox(width: WeftSpace.md),
                  Text(n.label),
                  if (n == current) ...[
                    const Spacer(),
                    Icon(Icons.check_rounded, size: 16, color: accent),
                  ],
                ],
              ),
            ),
          ),
      ],
      child: AnimatedContainer(
        duration: WeftMotion.fast,
        curve: WeftMotion.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.sm,
          vertical: WeftSpace.sm,
        ),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.15),
          borderRadius: WeftRadius.pill,
          border: Border.all(color: accent.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The button's own label says the network; the glyph repeating it
            // would announce "WhatsApp" twice in a row.
            NetworkGlyph(network: current, size: 18, semanticsLabel: ''),
            const SizedBox(width: WeftSpace.xs),
            Icon(Icons.expand_more_rounded, size: 16, color: accent),
          ],
        ),
      ),
    );
  }
}
