import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';

/// Explains Sennit's push gateway before a store build first uses it.
///
/// Shown once, after the notification permission has been settled: a store
/// build registers nothing with the gateway until this has been answered.
/// What it says is what PRIVACY.md says — what is sent, who gets it, how to
/// choose otherwise — so the user agrees to the same thing the policy
/// describes. Also reachable from the Push section's "What is sent?".
///
/// Returns true for Sennit's gateway, false for "choose another way", and
/// null when dismissed without an answer (asked again next launch).
Future<bool?> showPushExplanation(BuildContext context, {bool ask = true}) =>
    Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PushExplanationScreen(ask: ask),
      ),
    );

class PushExplanationScreen extends StatelessWidget {
  const PushExplanationScreen({super.key, this.ask = true});

  /// Whether to offer the two answers; false when opened from settings, where
  /// the choice is the radio group behind it.
  final bool ask;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(top: WeftSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: WeftSpace.xs),
          Text(body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );

    return Scaffold(
      appBar: const WeftAppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.xl,
            0,
            WeftSpace.xl,
            WeftSpace.xl,
          ),
          children: [
            Icon(
              Icons.notifications_paused_outlined,
              size: 40,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: WeftSpace.lg),
            Text(
              l10n.pushIntroTitle,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WeftSpace.md),
            Text(l10n.pushIntroBody, style: theme.textTheme.bodyMedium),
            section(l10n.pushIntroSentTitle, l10n.pushIntroSent),
            section(l10n.pushIntroWhoTitle, l10n.pushIntroWho),
            section(l10n.pushIntroOptOutTitle, l10n.pushIntroOptOut),
            if (ask) ...[
              const SizedBox(height: WeftSpace.xl),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.pushIntroAccept),
              ),
              const SizedBox(height: WeftSpace.sm),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.pushIntroOther),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
