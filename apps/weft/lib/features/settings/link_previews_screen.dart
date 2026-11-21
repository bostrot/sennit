import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../app/stores.dart';
import '../../services/links/link_preview_service.dart';
import 'settings_section.dart';

/// The switch for link previews, the separate opt-in for encrypted chats, and
/// the per-network escape hatch under them.
///
/// Its own screen rather than a row on the endpoints screen: that one is about
/// software the user runs, and this is about what their *homeserver* is asked
/// to do on their behalf. The copy follows the same rule either way — the
/// sentence next to a switch that discloses something says what, in the words
/// the user would use, before they can turn it on. The master switch is on by
/// default and carries no such warning because, outside encrypted chats, the
/// homeserver already holds every link it would be asked about.
class LinkPreviewsScreen extends ConsumerWidget {
  const LinkPreviewsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(linkPreviewSettingsProvider);
    final networks = ref.watch(chatRepositoryProvider).availableNetworks;

    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.linkPreviewsTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            PrivacyNotice(message: context.l10n.linkPreviewsNotice),
            const SizedBox(height: WeftSpace.lg),

            SwitchListTile(
              title: Text(context.l10n.linkPreviewsShowTitle),
              subtitle: Text(context.l10n.linkPreviewsShowSubtitle),
              value: settings.enabled,
              onChanged: (v) =>
                  _write(ref, settings.copyWith(enabled: v), clearCache: !v),
              contentPadding: EdgeInsets.zero,
            ),

            if (settings.enabled) ...[
              SwitchListTile(
                title: PrivacyGatedTitle(
                  title: context.l10n.linkPreviewsEncryptedTitle,
                  warning: context.l10n.linkPreviewsEncryptedWarning,
                ),
                subtitle: Text(context.l10n.linkPreviewsEncryptedSubtitle),
                value: settings.encryptedRooms,
                // Switching it off empties the cache for the same reason the
                // master switch does: rows left behind would keep drawing
                // cards for encrypted chats from consent just withdrawn. The
                // cache is keyed by url alone, so it cannot forget only those.
                onChanged: (v) => _write(
                  ref,
                  settings.copyWith(encryptedRooms: v),
                  clearCache: !v,
                ),
                contentPadding: EdgeInsets.zero,
              ),

              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.settingsNetworksSectionTitle,
                subtitle: context.l10n.linkPreviewsNetworksSubtitle,
              ),
              for (final network in networks)
                NetworkToggleRow(
                  network: network,
                  allowed: !settings.excludedNetworks.contains(network.id),
                  onChanged: (allowed) => _write(
                    ref,
                    settings.copyWith(
                      excludedNetworks: {
                        ...settings.excludedNetworks.where(
                          (id) => id != network.id,
                        ),
                        if (!allowed) network.id,
                      },
                    ),
                  ),
                ),
              if (networks.isEmpty)
                Text(
                  context.l10n.settingsNoBridgesToExclude,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),

              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.linkPreviewsCacheTitle,
                subtitle: context.l10n.linkPreviewsCacheSubtitle,
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(context.l10n.linkPreviewsClearCache),
                  onPressed: () => _clearCache(context, ref),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Saves the gate, and empties the cache when it has just been closed.
  ///
  /// Switching previews off has to forget the answers as well as stop asking
  /// new questions: rows left behind would keep drawing cards from lookups the
  /// user has this moment withdrawn their consent for.
  void _write(
    WidgetRef ref,
    LinkPreviewSettings next, {
    bool clearCache = false,
  }) {
    final stores = ref.read(storesProvider);
    next.writeTo(stores.settings);
    if (clearCache) {
      stores.linkPreviews.clear();
      ref.read(linkPreviewMemoryProvider).clear();
    }
    ref.read(settingsRevisionProvider.notifier).bump();
  }

  void _clearCache(BuildContext context, WidgetRef ref) {
    final removed = ref.read(storesProvider).linkPreviews.count;
    ref.read(storesProvider).linkPreviews.clear();
    ref.read(linkPreviewMemoryProvider).clear();
    ref.read(settingsRevisionProvider.notifier).bump();
    // The count is the entire confirmation that anything happened — the button
    // looks identical before and after — and a bare snackbar said it to nobody
    // who was not watching.
    showWeftMessage(context, context.l10n.linkPreviewsForgot(removed));
  }
}
