import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import '../../app/sennit_web_providers.dart';
import '../../app/stores.dart';
import '../../services/web/pairing_registry.dart';
import '../../services/web/web_bundle_store.dart';
import '../components/qr_card.dart';
import 'settings_section.dart';

/// Sennit Web: the app in a browser, served by this device.
///
/// This screen owns the browser files — downloaded on demand, never part of
/// the app — and the switch that serves them.
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
            if (bundle is WebBundleReady) ...[
              const Divider(height: WeftSpace.xl),
              const _Serving(),
            ],
          ],
        ),
      ),
    );
  }
}

/// The switch, where to open it, the pairing code and the paired browsers.
class _Serving extends ConsumerWidget {
  const _Serving();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final serving = ref.watch(sennitWebServerProvider);
    final controller = ref.read(sennitWebServerProvider.notifier);
    ref.watch(settingsRevisionProvider);
    final paired = controller.registry.browsers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          title: Text(l10n.sennitWebServeTitle),
          subtitle: Text(
            serving.failed
                ? l10n.sennitWebServeFailed(kSennitWebPort)
                : l10n.sennitWebServeSubtitle,
          ),
          value: serving.running,
          onChanged: (on) =>
              unawaited(on ? controller.start() : controller.stop()),
          contentPadding: EdgeInsets.zero,
        ),
        if (serving.running) ...[
          const SizedBox(height: WeftSpace.sm),
          SettingsSectionHeader(
            title: l10n.sennitWebAddressTitle,
            subtitle: l10n.sennitWebConnected(serving.connected),
          ),
          for (final url in serving.urls)
            SelectableText(url.toString(), style: context.text.bodyLarge),
          const SizedBox(height: WeftSpace.md),
          FilledButton.icon(
            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
            label: Text(l10n.sennitWebPair),
            onPressed: () {
              final url = controller.pairingUrl();
              if (url != null) unawaited(_showPairing(context, url));
            },
          ),
        ],
        const SizedBox(height: WeftSpace.lg),
        SettingsSectionHeader(
          title: l10n.sennitWebPairedTitle,
          subtitle: paired.isEmpty ? l10n.sennitWebPairedNone : '',
        ),
        for (final browser in paired)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.web_rounded),
            title: Text(browser.name),
            subtitle: Text(
              l10n.sennitWebPairedSeen(
                MaterialLocalizations.of(
                  context,
                ).formatMediumDate(browser.lastSeen ?? browser.pairedAt),
              ),
            ),
            trailing: IconButton(
              tooltip: l10n.sennitWebRevoke,
              icon: const Icon(Icons.link_off_rounded),
              onPressed: () => _revoke(ref, browser),
            ),
          ),
      ],
    );
  }

  void _revoke(WidgetRef ref, PairedBrowser browser) {
    ref.read(sennitWebServerProvider.notifier).revoke(browser.key);
    ref.read(settingsRevisionProvider.notifier).bump();
  }

  static Future<void> _showPairing(BuildContext context, Uri url) {
    final l10n = context.l10n;
    final link = url.toString();
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.sennitWebPairTitle),
        // A fixed width: the dialog sizes itself by asking its content, and
        // the QR card's layout builder cannot answer that.
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                QrCard.data(link, semanticsLabel: l10n.sennitWebPairTitle),
                const SizedBox(height: WeftSpace.md),
                Text(
                  l10n.sennitWebPairBody,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                unawaited(Clipboard.setData(ClipboardData(text: link))),
            child: Text(l10n.sennitWebCopyLink),
          ),
          TextButton(
            onPressed: () =>
                unawaited(SharePlus.instance.share(ShareParams(uri: url))),
            child: Text(l10n.sennitWebShareLink),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }
}

/// Shown in the inbox header while Sennit Web is served — a server listening
/// on the network should never be something the user forgot about. Nothing
/// at all otherwise.
class SennitWebIndicator extends ConsumerWidget {
  const SennitWebIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sennitWebServerProvider.select((s) => s.running))) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: context.l10n.sennitWebServingBanner,
      icon: Icon(Icons.language_rounded, color: context.colors.primary),
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SennitWebScreen())),
    );
  }
}
