import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';

/// Whether a reversed timeline at [position] is far enough from its newest
/// message for a way back to be worth offering.
///
/// Half a screen, measured rather than fixed: a constant that is right on a
/// phone is a third of a line on a tall window. Below it the newest message is
/// still in view or one flick away, and a button there is a thing in front of
/// the words for no gain — never showing at the bottom is the half of this
/// control other clients have had to fix after shipping it.
bool isAwayFromLatest(ScrollPosition position) =>
    position.hasViewportDimension &&
    position.pixels > position.viewportDimension / 2;

/// Brings a reversed timeline back to its newest message.
///
/// A long way up is not animated in full: the list would build every bubble
/// between here and the bottom to scroll past them in a quarter of a second.
/// It jumps to within two screens and glides the rest, which looks the same
/// and costs two screens.
Future<void> scrollToLatest(
  ScrollController controller, {
  required Duration duration,
  Curve curve = WeftMotion.standard,
}) async {
  if (!controller.hasClients) return;
  final position = controller.position;
  // `animateTo` asserts on a zero duration, and zero is what reduced motion
  // asks for.
  if (duration == Duration.zero) {
    position.jumpTo(0);
    return;
  }
  final runUp = position.viewportDimension * 2;
  if (position.pixels > runUp) position.jumpTo(runUp);
  await position.animateTo(0, duration: duration, curve: curve);
}

/// The round button over the bottom corner of a conversation that returns to
/// the newest message, shown only while [visible] says the reader has scrolled
/// away from it.
///
/// Absent rather than transparent when hidden: a control nobody can see must
/// not be something a screen reader lands on or Tab stops at.
class JumpToLatestButton extends StatelessWidget {
  const JumpToLatestButton({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  final ValueListenable<bool> visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (context, visible, _) => AnimatedSwitcher(
        duration: context.motion.fast,
        switchInCurve: context.motion.standard,
        switchOutCurve: context.motion.standard,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        ),
        child: visible
            ? Material(
                elevation: 3,
                shape: const CircleBorder(),
                color: context.colors.surfaceContainerHigh,
                child: IconButton(
                  tooltip: context.l10n.chatJumpToLatest,
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: onPressed,
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
