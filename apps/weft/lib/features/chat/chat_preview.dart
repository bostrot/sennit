import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:weft_design/weft_design.dart';

import 'chat_view.dart';

/// A look at a conversation that does not count as having read it.
///
/// Opening a chat marks it read and takes its notification down, which is the
/// right thing for opening a chat and the wrong thing for finding out who it
/// was from. The unread marker is the only record of what is still owed an
/// answer, and spending it to answer "is this urgent?" is a bad trade — so the
/// same question gets an answer that costs nothing.
///
/// Held open rather than held down. Telegram X previews for as long as the
/// finger stays on the row, which suits a thumb and does not suit a pointer:
/// on a desktop the natural thing is to read for a moment, which a gesture
/// that ends on release makes impossible. Escape, a click outside, or the
/// same row again closes it.
///
/// Resolves to true when the user asked to open the conversation properly —
/// Enter, or the button in the footer — and null when they simply closed it.
Future<bool?> showChatPreview(BuildContext context, String chatId) {
  return Navigator.of(context, rootNavigator: true).push<bool>(
    _ChatPreviewRoute(
      chatId: chatId,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _ChatPreviewRoute extends PopupRoute<bool> {
  _ChatPreviewRoute({required this.chatId, required this.barrierLabel});

  final String chatId;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.45);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final size = MediaQuery.sizeOf(context);
    // Big enough to answer the question — a screenful of the conversation —
    // and small enough that the inbox is still visible around it, so it reads
    // as a look *into* the list rather than as having navigated away from it.
    final width = (size.width * 0.62).clamp(360.0, 760.0);
    final height = (size.height * 0.68).clamp(320.0, 720.0);

    return Shortcuts(
      shortcuts: chatPreviewShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          OpenPreviewedChatIntent: CallbackAction<OpenPreviewedChatIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop(true);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: _PreviewCard(chatId: chatId),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      // From slightly small, the way a peek behaves everywhere it exists: the
      // card grows out of the row rather than arriving on top of it.
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(context.isDesktop ? 12 : 20);

    return Padding(
      padding: const EdgeInsets.all(WeftSpace.lg),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 40,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            children: [
              Expanded(
                child: ChatView(
                  key: ValueKey('preview:$chatId'),
                  chatId: chatId,
                  preview: true,
                ),
              ),
              const _PreviewFooter(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says what this is, and that nothing has been spent by looking.
///
/// Without it a preview is indistinguishable from the conversation itself, and
/// the whole reason to use one is a promise about what it did *not* do — a
/// promise the user cannot verify by looking at the messages.
class _PreviewFooter extends StatelessWidget {
  const _PreviewFooter();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.md,
        vertical: WeftSpace.sm,
      ),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: context.palette.border, width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.visibility_outlined,
            size: 14,
            color: context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: WeftSpace.sm),
          Flexible(
            child: Text(
              'Preview — still unread',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: WeftSpace.md),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

/// Opens the conversation a preview is showing, and closes the preview.
///
/// Enter, because that is what a selected thing does everywhere else, and
/// because a preview that cannot become the real thing is a dead end.
class OpenPreviewedChatIntent extends Intent {
  const OpenPreviewedChatIntent();
}

/// Shortcuts a preview installs while it is open.
const Map<ShortcutActivator, Intent> chatPreviewShortcuts = {
  SingleActivator(LogicalKeyboardKey.enter): OpenPreviewedChatIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): OpenPreviewedChatIntent(),
};
