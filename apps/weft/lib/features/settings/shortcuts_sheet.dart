import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import '../../app/localisation.dart';

import '../../app/shortcuts.dart';

/// Every keyboard binding Weft has, in one place.
///
/// A shortcut nobody can find is a shortcut nobody uses, and the two ways in
/// are deliberately different in kind: Ctrl/Cmd + / for whoever already reaches
/// for the keyboard, and an entry in the inbox's overflow menu for whoever does
/// not know there is a keyboard model to look for.
///
/// Built from [weftKeyBindings] rather than from a list written out here, so a
/// binding cannot be added without appearing in this sheet — including the
/// three the composer owns rather than the app, which are exactly the ones
/// people go looking for ("how do I type a second line?").
Future<void> showShortcutsSheet(BuildContext context) {
  return showWeftPanel<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _ShortcutsSheet(),
  );
}

class _ShortcutsSheet extends StatelessWidget {
  const _ShortcutsSheet();

  @override
  Widget build(BuildContext context) {
    final bindings = weftKeyBindings(context.l10n);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.xl,
          0,
          WeftSpace.xl,
          WeftSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.shortcutsTitle,
              style: context.text.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: WeftSpace.lg),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: bindings.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: WeftSpace.sm),
                itemBuilder: (_, i) => _BindingRow(binding: bindings[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BindingRow extends StatelessWidget {
  const _BindingRow({required this.binding});

  final WeftKeyBinding binding;

  @override
  Widget build(BuildContext context) {
    final keys = binding.activators.map(describeShortcut).toList();
    final or = context.l10n.shortcutsOr;

    // One node, not one per key cap. "Next conversation, Alt + Arrow Down or
    // ⌘ + Page Down" is the sentence; the caps are a picture of it, and read
    // separately they are a run of single letters with no verb.
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: context.l10n.shortcutsBindingSemantics(
        binding.description,
        keys.join(' $or '),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(binding.description, style: context.text.bodyMedium),
          ),
          const SizedBox(width: WeftSpace.md),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: WeftSpace.xs,
            runSpacing: WeftSpace.xs,
            children: [
              for (var i = 0; i < keys.length; i++) ...[
                if (i > 0)
                  Text(
                    or,
                    style: context.text.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                _KeyCap(keys[i]),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A key combination, drawn as the thing it is.
class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.sm,
        vertical: WeftSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: WeftRadius.allSm,
        border: Border.all(color: context.palette.border),
      ),
      child: Text(
        label,
        style: context.text.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          // The caps are a picture of the keys, and a picture that grows with
          // the text scaler is what keeps them legible at 2.0× — no fixed
          // height here for the same reason SCALE-4 was a finding.
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
