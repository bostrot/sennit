import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/providers.dart';
import '../../app/stores.dart';
import '../../services/links/link_preview_service.dart';
import 'settings_section.dart';

/// The opt-in for link previews, and the per-network escape hatch under it.
///
/// Its own screen rather than a row on the endpoints screen: that one is about
/// software the user runs, and this is about what their *homeserver* is asked
/// to do on their behalf. The copy follows the same rule either way — the
/// sentence next to the switch says what turning it on discloses, in the words
/// the user would use, before they can turn it on.
class LinkPreviewsScreen extends ConsumerWidget {
  const LinkPreviewsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(linkPreviewSettingsProvider);
    final networks = ref.watch(chatRepositoryProvider).availableNetworks;

    return Scaffold(
      appBar: AppBar(title: const Text('Link previews')),
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: [
          const PrivacyNotice(
            message:
                'A preview is fetched by your homeserver, not by this device, '
                'so the site is never told your IP address or when you read '
                'the message. The cost is on the other side: your homeserver '
                'learns every link you are sent and when, including links '
                'inside end-to-end encrypted chats it can otherwise never '
                'read. Leave this off unless you run the homeserver yourself '
                'or trust whoever does.',
          ),
          const SizedBox(height: WeftSpace.lg),

          SwitchListTile(
            title: const PrivacyGatedTitle(
              title: 'Show link previews',
              warning:
                  'Turning this on tells your homeserver every link you are '
                  'sent, including links inside encrypted chats.',
            ),
            subtitle: const Text(
              'Off means no link in any message is ever looked up. Nothing is '
              'requested until you switch this on.',
            ),
            value: settings.enabled,
            onChanged: (v) =>
                _write(ref, settings.copyWith(enabled: v), clearCache: !v),
            contentPadding: EdgeInsets.zero,
          ),

          if (settings.enabled) ...[
            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'Networks',
              subtitle:
                  'Excluded networks are never previewed, whatever the switch '
                  'above says. Use this for the conversations that must leave '
                  'nothing on the homeserver beyond their ciphertext.',
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
                'No bridges are configured yet, so there is nothing to '
                'exclude. Networks appear here as they connect.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),

            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'Cached previews',
              subtitle:
                  'Answers already given are kept so the same link is not '
                  'asked about twice. Clearing them costs a fresh request the '
                  'next time one of those links is on screen.',
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Clear cached previews'),
                onPressed: () => _clearCache(context, ref),
              ),
            ),
          ],
        ],
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
    if (clearCache) stores.linkPreviews.clear();
    ref.read(settingsRevisionProvider.notifier).bump();
  }

  void _clearCache(BuildContext context, WidgetRef ref) {
    final removed = ref.read(storesProvider).linkPreviews.count;
    ref.read(storesProvider).linkPreviews.clear();
    ref.read(settingsRevisionProvider.notifier).bump();
    // The count is the entire confirmation that anything happened — the button
    // looks identical before and after — and a bare snackbar said it to nobody
    // who was not watching.
    showWeftMessage(
      context,
      removed == 1 ? 'Forgot 1 preview.' : 'Forgot $removed previews.',
    );
  }
}
