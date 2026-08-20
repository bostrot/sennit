import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/labels.dart';

/// Picks (or creates) a label for the selected chats. Pops the label, or null.
Future<String?> showLabelSheet(
  BuildContext context,
  WidgetRef ref,
  Set<String> chatIds,
) {
  final labels = ref.read(chatLabelsProvider.notifier).all;
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _LabelSheet(existing: labels, chatIds: chatIds),
  );
}

class _LabelSheet extends ConsumerStatefulWidget {
  const _LabelSheet({required this.existing, required this.chatIds});

  final List<String> existing;
  final Set<String> chatIds;

  @override
  ConsumerState<_LabelSheet> createState() => _LabelSheetState();
}

class _LabelSheetState extends ConsumerState<_LabelSheet> {
  final _newLabel = TextEditingController();

  @override
  void dispose() {
    _newLabel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labelsByChat = ref.watch(chatLabelsProvider);
    // Checked when every selected chat already carries the label, so the
    // sheet reads as state, not just as a list of names.
    bool allHave(String label) => widget.chatIds.every(
      (id) => labelsByChat[id]?.contains(label) ?? false,
    );

    return Padding(
      padding: EdgeInsets.only(
        left: WeftSpace.lg,
        right: WeftSpace.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + WeftSpace.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Label ${widget.chatIds.length} '
            'conversation${widget.chatIds.length == 1 ? '' : 's'}',
            style: context.text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          Text(
            'A label already on every selected chat is removed instead.',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: WeftSpace.md),
          if (widget.existing.isNotEmpty) ...[
            Wrap(
              spacing: WeftSpace.sm,
              runSpacing: WeftSpace.sm,
              children: [
                for (final label in widget.existing)
                  FilterChip(
                    label: Text(label),
                    selected: allHave(label),
                    onSelected: (_) => Navigator.of(context).pop(label),
                  ),
              ],
            ),
            const SizedBox(height: WeftSpace.md),
          ],
          Row(
            children: [
              Expanded(
                child: WeftLabelledField(
                  label: 'New label',
                  child: TextField(
                    controller: _newLabel,
                    autofocus: widget.existing.isEmpty,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (value) => Navigator.of(context).pop(value),
                    decoration: const InputDecoration(
                      hintText: 'New label — e.g. Work',
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: WeftSpace.sm),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_newLabel.text),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
