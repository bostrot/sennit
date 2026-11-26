import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart' show SettingsStore, WeftSettings;

import '../../app/localisation.dart';

/// Where the privacy policy says what usage statistics contain.
final Uri kUsageStatsPolicy = Uri.parse(
  'https://erictrenkel.com/apps/sennit/privacy.html#analytics',
);

/// Asks once whether Sennit may send anonymous usage statistics.
///
/// Once per account: the answer, and that it was asked, both sync. Dismissing
/// the dialog is a "no" — the switch stays off and the question is not put
/// again; Settings → Privacy is where to change it.
///
/// Returns whether the dialog was shown.
Future<bool> askUsageStatsOnce(
  BuildContext context,
  SettingsStore settings, {
  required VoidCallback onChanged,
}) async {
  if (settings.getBool(WeftSettings.usageStatsAsked)) return false;
  settings.setBool(WeftSettings.usageStatsAsked, value: true);
  final allowed = await showDialog<bool>(
    context: context,
    builder: (_) => const UsageStatsConsentDialog(),
  );
  settings.setBool(WeftSettings.usageStats, value: allowed ?? false);
  onChanged();
  return true;
}

/// The question itself: what is sent, what never is, and two answers of
/// equal weight, so neither looks like the one expected.
class UsageStatsConsentDialog extends StatelessWidget {
  const UsageStatsConsentDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final muted = context.text.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return AlertDialog(
      icon: const Icon(Icons.insights_outlined),
      title: Text(l10n.usageStatsConsentTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.usageStatsConsentBody),
            const SizedBox(height: WeftSpace.md),
            Text(l10n.usageStatsConsentNever, style: muted),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => launchUrl(
                  kUsageStatsPolicy,
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(l10n.usageStatsConsentPolicy),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Same width and, when one label wraps, the same height.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.usageStatsConsentDecline),
                ),
              ),
              const SizedBox(width: WeftSpace.sm),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(l10n.usageStatsConsentAllow),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
