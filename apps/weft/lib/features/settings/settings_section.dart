/// The two pieces every privacy-gated settings screen is built from.
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
