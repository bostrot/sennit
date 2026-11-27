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
/// away from it, with a count of what [arrived] since they did.
///
/// Absent rather than transparent when hidden: a control nobody can see must
/// not be something a screen reader lands on or Tab stops at.
class JumpToLatestButton extends StatelessWidget {
  const JumpToLatestButton({
    super.key,
    required this.visible,
    required this.arrived,
    required this.onPressed,
  });

  final ValueListenable<bool> visible;

  /// Messages that arrived at the bottom while the reader was away; a badge
  /// on the button while it is above zero.
  final ValueListenable<int> arrived;

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
            ? ValueListenableBuilder<int>(
                valueListenable: arrived,
                builder: (context, count, _) => _button(context, count),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _button(BuildContext context, int count) {
    final l10n = context.l10n;
    final button = Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: context.colors.surfaceContainerHigh,
      child: IconButton(
        // The count is part of the name, so a screen reader hears why the
        // button is worth pressing; the badge itself is not read again.
        tooltip: count > 0
            ? semanticsSentence([
                l10n.chatJumpToLatest,
                l10n.chatNewMessagesBelow(count),
              ])
            : l10n.chatJumpToLatest,
        icon: const Icon(Icons.keyboard_arrow_down),
        onPressed: onPressed,
      ),
    );
    // A stack even without a count, so the first arrival adds the badge
    // beside the button instead of rebuilding it — which would take keyboard
    // focus off it the moment a message lands.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        if (count > 0)
          // Over the button's top corner, the way a count sits on an app icon,
          // so it reads as belonging to the button without covering the arrow.
          // Lifted by a share of its own height, which grows with the text, but
          // held to the button's edge sideways: a wide "12" pushed out past it
          // would leave the screen on a phone. Its growth with the text is
          // capped too — at 2.0× an uncapped badge is as wide as the button and
          // hides the arrow it labels — and the number is in the button's name
          // for anyone who needs it larger still.
          PositionedDirectional(
            top: 0,
            end: -WeftSpace.xs,
            child: FractionalTranslation(
              translation: const Offset(0, -0.4),
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.4,
                    child: WeftUnreadBadge(
                      count: count,
                      color: context.palette.unreadDot,
                      ink: context.colors.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
