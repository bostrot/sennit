import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../services/ai/quick_messages.dart';

/// Asks which quick message to write.
///
/// The list the user keeps on the quick messages settings screen, and a last
/// row that goes there. Returns the one picked, or null — including when the
/// user chose to edit the list, in which case [onEdit] runs once the sheet is
/// gone, so the settings screen is pushed onto the chat rather than onto a
/// sheet that is closing.
Future<QuickMessage?> showQuickMessageSheet(
  BuildContext context,
  List<QuickMessage> messages, {
  required VoidCallback onEdit,
  BuildContext? anchorContext,
}) async {
  var editing = false;
  final picked = await showWeftPanel<QuickMessage>(
    context: context,
    anchorContext: anchorContext,
    showDragHandle: true,
    builder: (context) {
      final l10n = context.l10n;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: WeftSpace.xl,
                  vertical: WeftSpace.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        l10n.quickMessageSheetTitle,
                        style: context.text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: WeftSpace.xxs),
                    Text(
                      l10n.quickMessageSheetSubtitle,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (messages.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WeftSpace.xl,
                    vertical: WeftSpace.md,
                  ),
                  child: Text(l10n.quickMessagesEmpty),
                ),
              for (final message in messages)
                ListTile(
                  leading: QuickMessageEmoji(message: message),
                  title: Text(l10n.quickMessageTitle(message)),
                  onTap: () => Navigator.of(context).pop(message),
                ),
              const Divider(height: WeftSpace.lg),
              ListTile(
                leading: const Icon(Icons.edit_note_rounded),
                title: Text(l10n.quickMessageEditList),
                onTap: () {
                  editing = true;
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: WeftSpace.sm),
            ],
          ),
        ),
      );
    },
  );
  if (editing) onEdit();
  return picked;
}

/// A quick message's emoji in the leading slot, or a neutral sparkle for one
/// without, so the titles stay aligned.
///
/// Excluded from semantics: the title says what the row is, and a screen
/// reader announcing "birthday cake, Happy Birthday" reads it twice.
class QuickMessageEmoji extends StatelessWidget {
  const QuickMessageEmoji({super.key, required this.message});

  final QuickMessage message;

  @override
  Widget build(BuildContext context) {
    final emoji = message.emoji?.trim() ?? '';
    return ExcludeSemantics(
      child: SizedBox(
        width: 28,
        child: Center(
          child: emoji.isEmpty
              ? Icon(
                  Icons.auto_awesome_outlined,
                  color: context.colors.onSurfaceVariant,
                )
              : Text(emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }
}
