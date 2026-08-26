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
import 'package:weft_domain/weft_domain.dart';

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
    return Semantics(
      container: true,
      // Named as a warning rather than left as a paragraph. The red box and the
      // shield glyph are the entire signal that this is not more explanatory
      // copy, and both are invisible to a reader — who otherwise hears four
      // sentences of prose indistinguishable from the section blurbs below it.
      label: 'Privacy warning. $message',
      excludeSemantics: true,
      child: Container(
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
      ),
    );
  }
}

/// A switch's title, with the cost of turning it on attached to it.
///
/// A [PrivacyNotice] and the control it gates are unrelated siblings in a
/// `ListView`: the warning is read first only by someone who arrives at the top
/// and walks down. A reader who lands on the switch directly — by a heading
/// jump, by touch exploration, by returning to a screen they have used before —
/// is offered a toggle that undoes end-to-end encryption and told nothing at
/// all.
///
/// Given as the tile's `title` rather than wrapped *around* the tile, and that
/// is the whole reason this is a widget rather than a line at each call site: a
/// `SwitchListTile` forms its own semantics node, so an annotation above it
/// becomes a second node a reader meets separately from the switch it
/// qualifies. Inside the tile it merges, and the warning arrives with the
/// control it is about.
///
/// A hint rather than a longer label because that is what a hint is for: a
/// screen reader says the name and the state first, then what acting on it
/// means. Keep [warning] to the one sentence that would stop someone — the
/// full text is still above, and a hint read on every focus change has to be
/// short enough that it is not skipped by the third visit.
class PrivacyGatedTitle extends StatelessWidget {
  const PrivacyGatedTitle({
    super.key,
    required this.title,
    required this.warning,
  });

  final String title;
  final String warning;

  @override
  Widget build(BuildContext context) =>
      Semantics(hint: warning, child: Text(title));
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
    // One header node carrying both lines. A settings screen is a list of
    // sections, and heading navigation is how a reader skips the six they did
    // not come for — which needs the title to *be* a heading, not a bold run.
    return Semantics(
      header: true,
      container: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: Padding(
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
      ),
    );
  }
}

/// One network, and whether a privacy gate lets it through.
///
/// Every gate of this shape has the same escape hatch under it — previews for
/// the group chat, nothing for the one conversation that must leave no trace —
/// and the row was written twice before it was written here. The switch reads
/// *allowed*, not *excluded*, because a list of switches where on means "no"
/// is a list nobody parses correctly at a glance.
class NetworkToggleRow extends StatelessWidget {
  const NetworkToggleRow({
    super.key,
    required this.network,
    required this.allowed,
    required this.onChanged,
  });

  final ChatNetwork network;
  final bool allowed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      // The tile is one merged node, and the title beside the glyph is already
      // the network's name — a labelled glyph here reads "WhatsApp, WhatsApp".
      secondary: NetworkGlyph(network: network, size: 28, semanticsLabel: ''),
      title: Text(network.label),
      value: allowed,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
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
