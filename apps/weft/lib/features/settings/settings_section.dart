/// The pieces every privacy-gated settings screen is built from.
///
/// Both started life private inside `endpoints_screen.dart`, which is where the
/// house style for this kind of copy was set: state the cost of switching the
/// thing on, in the sentence next to the switch, in the words the user would
/// use. Weft now has more than one gate of this shape — remote endpoints, and
/// link previews — and a second screen that reinvented the warning box would
/// have drifted from the first within a release.
library;

import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

/// The red box at the top of a screen that can send something off the device.
///
/// Deliberately not a tooltip, an info icon or an expandable: the whole point
/// is that the reader cannot switch the feature on without having been shown
/// what it costs.
class PrivacyNotice extends StatelessWidget {
  const PrivacyNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.errorContainer.withValues(alpha: 0.5),
        borderRadius: WeftRadius.allMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.privacy_tip_outlined,
            size: 20,
            color: context.colors.onErrorContainer,
          ),
          const SizedBox(width: WeftSpace.md),
          Expanded(
            child: Text(
              message,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A settings section's title and the sentence explaining when to use it.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: context.text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// What a settings screen shows instead of a list it could not load.
///
/// An empty list and a failed load look identical, and only one of them means
/// "there is nothing here" — so every screen that fetches from the homeserver
/// renders this instead, with the failure's own sentence and a way to retry.
class SettingsMessage extends StatelessWidget {
  const SettingsMessage({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: WeftSpace.lg),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// A dialog that asks for one line of text and pops it, or pops null.
///
/// Stateful, and owning its controller, because the alternative — building the
/// controller at the call site and disposing it when `showDialog` returns —
/// disposes it while the dialog's exit animation is still rebuilding the field
/// it belongs to. That is a "used after being disposed" assertion in the frame
/// after every dialog, which is exactly what this replaced.
///
/// Shared rather than private to the devices screen, which is where the bug was
/// found and fixed: a second copy would be a second chance to reintroduce it.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.message,
    required this.fieldLabel,
    required this.confirmLabel,
    this.initialValue = '',
    this.obscure = false,
    this.helperText,
  });

  final String title;
  final String message;
  final String fieldLabel;
  final String confirmLabel;
  final String initialValue;
  final bool obscure;

  /// The line under the field, for the case where what to type is not obvious
  /// from its label — an optional passphrase, say.
  final String? helperText;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: WeftSpace.md),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: widget.obscure,
            decoration: InputDecoration(
              labelText: widget.fieldLabel,
              helperText: widget.helperText,
              helperMaxLines: 3,
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
