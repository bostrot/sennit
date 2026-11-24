import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import '../../app/sennit_web_providers.dart';
import '../../services/web/web_bundle_store.dart';
import 'settings_section.dart';

/// Sennit Web: the app in a browser, served by this device.
///
/// This screen owns the browser files — downloaded on demand, never part of
/// the app — and, once the server lands, the switch that serves them.
class SennitWebScreen extends ConsumerWidget {
  const SennitWebScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final bundle = ref.watch(webBundleProvider);
    final controller = ref.read(webBundleProvider.notifier);

    final status = switch (bundle) {
      WebBundleAbsent() => l10n.sennitWebBundleAbsent,
      WebBundleDownloading(:final fraction) => l10n.sennitWebBundleDownloading(
        ((fraction ?? 0) * 100).round(),
      ),
      WebBundleReady(:final sizeBytes) => l10n.sennitWebBundleReady(
        (sizeBytes / (1024 * 1024)).round(),
      ),
      WebBundleFailed(error: WebBundleError.unavailable) =>
        l10n.sennitWebBundleUnavailable,
      WebBundleFailed(error: WebBundleError.network) =>
        l10n.sennitWebBundleNetwork,
      WebBundleFailed(error: WebBundleError.rejected) =>
        l10n.sennitWebBundleRejected,
    };

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.settingsSennitWebTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            PrivacyNotice(message: l10n.sennitWebNotice),
            const SizedBox(height: WeftSpace.lg),
            SettingsSectionHeader(
              title: l10n.sennitWebBundleTitle,
              subtitle: status,
            ),
            if (bundle case WebBundleDownloading(:final fraction))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: WeftSpace.sm),
                child: LinearProgressIndicator(value: fraction),
              ),
            const SizedBox(height: WeftSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: switch (bundle) {
                WebBundleReady() => OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(l10n.sennitWebRemove),
                  onPressed: controller.remove,
                ),
                WebBundleDownloading() => const SizedBox.shrink(),
                _ => FilledButton.icon(
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(l10n.sennitWebDownload),
                  onPressed: controller.download,
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}
