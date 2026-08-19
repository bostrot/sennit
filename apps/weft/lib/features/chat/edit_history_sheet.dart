import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'rich_text_view.dart';

/// Every version a message has had, oldest first.
///
/// The list comes from `applyEdits`, which is the only thing that has it: a
/// homeserver hands over the original event and its replacements separately,
/// and the SDK's display event resolves them into the *current* text — the
/// words that were replaced survive nowhere else. That is also why this sheet
/// exists at all. An "edited" marker with nothing behind it asks the reader to
/// take the sender's word for what they used to say.
///
/// Each version is rendered through [RichTextView], so an edit that changed the
/// formatting shows as the formatting it had, and a version whose HTML was
/// hostile is refused by the same allowlist the bubble uses.
Future<void> showEditHistorySheet(
  BuildContext context, {
  required WeftMessage message,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _EditHistorySheet(message: message),
  );
}

class _EditHistorySheet extends StatelessWidget {
  const _EditHistorySheet({required this.message});

  final WeftMessage message;

  @override
  Widget build(BuildContext context) {
    final history = message.editHistory;
    final ink = context.colors.onSurface;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.xl,
            0,
            WeftSpace.xl,
            WeftSpace.xl,
          ),
          children: [
            Semantics(
              header: true,
              child: Text('Edit history', style: context.text.titleMedium),
            ),
            const SizedBox(height: WeftSpace.xs),
            Text(
              history.isEmpty
                  ? 'No earlier versions were kept for this message.'
                  : '${history.length} versions, oldest first.',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: WeftSpace.lg),
            for (var i = 0; i < history.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: WeftSpace.md),
                child: _Version(
                  record: history[i],
                  // The last entry is what the bubble is showing now; the first
                  // is what was originally sent. Both are worth labelling, or
                  // the reader has to count rows to work out which is which.
                  label: switch (i) {
                    0 => 'Original',
                    _ when i == history.length - 1 => 'Current',
                    _ => 'Edit $i',
                  },
                  ink: ink,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Version extends StatelessWidget {
  const _Version({
    required this.record,
    required this.label,
    required this.ink,
  });

  final EditRecord record;
  final String label;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // "Original, 3 Jun 2026 14:32" as one heading over the version it
        // labels. Two nodes with nothing tying them to the body underneath
        // leaves a reader stepping through a sheet of undated paragraphs.
        Semantics(
          header: true,
          container: true,
          excludeSemantics: true,
          label:
              '$label, '
              '${DateFormat.yMMMd().add_Hm().format(record.timestamp)}',
          child: Row(
            children: [
              Text(
                label,
                style: context.text.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: WeftSpace.sm),
              Text(
                DateFormat.yMMMd().add_Hm().format(record.timestamp),
                style: context.text.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: WeftSpace.xs),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(WeftSpace.md),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHigh,
            borderRadius: WeftRadius.allMd,
          ),
          child: RichTextView(
            document: parseMessageBody(
              body: record.body,
              formattedBody: record.formattedBody,
            ),
            baseStyle:
                context.text.bodyMedium?.copyWith(color: ink) ??
                TextStyle(color: ink),
            accent: context.colors.primary,
          ),
        ),
      ],
    );
  }
}
