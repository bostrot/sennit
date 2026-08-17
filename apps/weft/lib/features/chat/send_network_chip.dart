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
  });

  final Chat chat;
  final ChatNetwork current;
  final ValueChanged<ChatNetwork> onPick;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.networkColor(current);

    return PopupMenuButton<ChatNetwork>(
      tooltip: 'Send via…',
      onSelected: onPick,
      itemBuilder: (context) => [
        for (final n in chat.networks)
          PopupMenuItem(
            value: n,
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
            NetworkGlyph(network: current, size: 18),
            const SizedBox(width: WeftSpace.xs),
            Icon(Icons.expand_more_rounded, size: 16, color: accent),
          ],
        ),
      ),
    );
  }
}
