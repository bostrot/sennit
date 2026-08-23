import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft_store/weft_store.dart';

import 'package:weft_domain/weft_domain.dart' show ChatNetwork;

import '../../app/a11y.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../bridges/bridges_screen.dart';
import '../../services/contacts/device_contacts.dart';
import '../../services/status/status_feed.dart';
import '../merge/merge_screen.dart';
import 'appearance_sheet.dart';
import 'integrations_screen.dart';
import 'devices_screen.dart';
import 'endpoints_screen.dart';
import 'link_previews_screen.dart';
import 'mcp_screen.dart';
import 'models_screen.dart';
import 'notifications_screen.dart';
import 'security_screen.dart';
import 'shortcuts_sheet.dart';
import 'sms_screen.dart';
import 'surfaces_screen.dart';

/// The one place every setting lives.
///
/// The inbox's overflow menu used to be this screen: eleven destinations in a
/// popup, where "Devices" sat between "Show archived" and "Keyboard
/// shortcuts". A menu is for things you do *to the inbox*; configuration
/// belongs on a screen with room for grouping and a sentence per entry.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static bool get _hasKeyboard => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void push(Widget screen) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => screen));
    }

    Widget tile({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
    }) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      );
    }

    Widget header(String text) => Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.lg,
        WeftSpace.lg,
        WeftSpace.lg,
        WeftSpace.xs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: context.text.labelLarge?.copyWith(
            color: context.colors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: WeftSpace.xxl),
        children: [
          header('Chats'),
          tile(
            icon: Icons.call_merge_rounded,
            title: 'Merged chats',
            subtitle: 'One person across several messengers, as one thread',
            onTap: () => push(const MergeScreen()),
          ),
          tile(
            icon: Icons.hub_outlined,
            title: 'Bridges',
            subtitle: 'The messenger bridges on your Matrix server',
            onTap: () => push(const BridgesScreen()),
          ),
          if (!kDemoMode && defaultTargetPlatform == TargetPlatform.android)
            tile(
              icon: Icons.sms_outlined,
              title: 'SMS',
              subtitle: 'Text messages on this phone, in the inbox',
              onTap: () => push(const SmsScreen()),
            ),

          const _StatusRingsToggle(),

          header('Look & feel'),
          tile(
            icon: Icons.palette_outlined,
            title: 'Appearance',
            subtitle: 'Theme, colour and density',
            onTap: () => showAppearanceSheet(context),
          ),
          tile(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            subtitle: 'What may interrupt you, and how',
            onTap: () => push(const NotificationsScreen()),
          ),
          if (_hasKeyboard)
            tile(
              icon: Icons.keyboard_outlined,
              title: 'Keyboard shortcuts',
              subtitle: 'Everything the keyboard can do here',
              onTap: () => showShortcutsSheet(context),
            ),

          header('Search & intelligence'),
          tile(
            icon: Icons.manage_search_rounded,
            title: 'Search & transcription',
            subtitle: 'Semantic search and voice transcription endpoints',
            onTap: () => push(const EndpointsScreen()),
          ),
          tile(
            icon: Icons.download_for_offline_outlined,
            title: 'Local models',
            subtitle: 'Run search and transcription on this device',
            onTap: () => push(const ModelsScreen()),
          ),
          const _AgendaToggle(),
          const _HiddenNetworksSection(),

          header('Privacy & security'),
          const _ReadReceiptsToggle(),
          const _ContactNamesToggle(),
          tile(
            icon: Icons.link_rounded,
            title: 'Link previews',
            subtitle: 'Whether links in messages may be previewed',
            onTap: () => push(const LinkPreviewsScreen()),
          ),
          tile(
            icon: Icons.devices_rounded,
            title: 'Devices',
            subtitle: 'Your other logins, and signing them out',
            onTap: () => push(const DevicesScreen()),
          ),
          tile(
            icon: Icons.lock_outline_rounded,
            title: 'Encryption',
            subtitle: 'Cross-signing, key backup and recovery',
            onTap: () => push(const SecurityScreen()),
          ),

          header('Connections'),
          tile(
            icon: Icons.widgets_outlined,
            title: 'Widgets & watch',
            subtitle: 'Home screen widgets and the watch companion',
            onTap: () => push(const SurfacesScreen()),
          ),
          tile(
            icon: Icons.home_outlined,
            title: 'Integrations',
            subtitle: 'Home Assistant and paperless-ngx, your own instances',
            onTap: () => push(const IntegrationsScreen()),
          ),
          tile(
            icon: Icons.terminal_rounded,
            title: 'MCP server',
            subtitle: 'Let your own agents read and send through Braid',
            onTap: () => push(const McpScreen()),
          ),
        ],
      ),
    );
  }
}

/// The read-receipts switch.
///
/// Off keeps the *private* receipt — this account's own devices still clear
/// their badges — and withholds the public one, which is what bridges relay
/// to the remote network as its native read marker.
class _ReadReceiptsToggle extends ConsumerWidget {
  const _ReadReceiptsToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    final WeftStores stores;
    try {
      stores = ref.watch(storesProvider);
    } on Object {
      return const SizedBox.shrink();
    }

    return SwitchListTile(
      secondary: const Icon(Icons.done_all_rounded),
      title: const Text('Send read receipts'),
      subtitle: const Text(
        'Off, senders are not told you read their messages — on WhatsApp and '
        'friends too, via the bridge. Your own devices still sync.',
      ),
      value: stores.settings.getBool(
        WeftSettings.sendReadReceipts,
        fallback: true,
      ),
      onChanged: (value) {
        stores.settings.setBool(WeftSettings.sendReadReceipts, value: value);
        ref.read(settingsRevisionProvider.notifier).bump();
      },
    );
  }
}

/// Per-network "keep out of All" switches.
///
/// A work bridge that should not mingle with private conversations: its
/// chats leave the combined view and the network's spot in the rail becomes
/// the one door to them. Unread badges on the rail still count them — hidden
/// is not muted.
class _HiddenNetworksSection extends ConsumerWidget {
  const _HiddenNetworksSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ChatNetwork> networks;
    try {
      networks = ref.watch(chatRepositoryProvider).availableNetworks;
    } on Object {
      return const SizedBox.shrink();
    }
    if (networks.isEmpty) return const SizedBox.shrink();
    final hidden = ref.watch(hiddenFromAllProvider);

    return ExpansionTile(
      leading: const Icon(Icons.visibility_off_outlined),
      title: const Text('Hide networks from All'),
      subtitle: Text(
        hidden.isEmpty
            ? 'Every network shows in the combined inbox'
            : 'Hidden: ${hidden.map((n) => n.label).join(', ')} — tap the '
                  'network in the rail to see its chats',
      ),
      children: [
        for (final network in networks)
          SwitchListTile(
            dense: true,
            title: Text('Show ${network.label} in All'),
            value: !hidden.contains(network),
            onChanged: (_) =>
                ref.read(hiddenFromAllProvider.notifier).toggle(network),
          ),
      ],
    );
  }
}

/// The address-book-names switch.
///
/// Turning it on asks for the contacts permission there and then; a refusal
/// flips the switch straight back rather than leaving it on and doing
/// nothing. Matching runs entirely on the device.
class _ContactNamesToggle extends ConsumerWidget {
  const _ContactNamesToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    final WeftStores stores;
    try {
      stores = ref.watch(storesProvider);
    } on Object {
      return const SizedBox.shrink();
    }

    return SwitchListTile(
      secondary: const Icon(Icons.person_pin_rounded),
      title: const Text('Use address book names'),
      subtitle: const Text(
        'Name people the way your contacts app does when a phone number '
        'matches, instead of the name WhatsApp or Signal reports. Matched on '
        'this device only.',
      ),
      value: stores.settings.getBool(WeftSettings.useDeviceContactNames),
      onChanged: (value) async {
        if (value) {
          // The permission prompt belongs to the tap, not to a later sync.
          final names = await loadDeviceContactNames();
          if (names == null) {
            if (context.mounted) {
              showWeftMessage(
                context,
                'Braid was not allowed to read your contacts.',
              );
            }
            return;
          }
          stores.settings.setJson(kContactNamesCacheKey, names);
        }
        stores.settings.setBool(
          WeftSettings.useDeviceContactNames,
          value: value,
        );
        ref.read(settingsRevisionProvider.notifier).bump();
      },
    );
  }
}

/// The appointment-detection switch.
///
/// Its own widget because it is the one row on this screen with state. Fully
/// on-device — rules plus, when installed, the local embedding model — which
/// is why it defaults on where the remote-endpoint gates default off.
class _AgendaToggle extends ConsumerWidget {
  const _AgendaToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    final WeftStores stores;
    try {
      stores = ref.watch(storesProvider);
    } on Object {
      // Settings opened before bootstrap finished; the row simply waits.
      return const SizedBox.shrink();
    }

    return SwitchListTile(
      secondary: const Icon(Icons.event_available_rounded),
      title: const Text('Detect appointments'),
      subtitle: const Text(
        'Offer "add to calendar" under messages that name a date. '
        'Runs entirely on this device.',
      ),
      value: stores.settings.getBool(WeftSettings.agendaDetect, fallback: true),
      onChanged: (value) {
        stores.settings.setBool(WeftSettings.agendaDetect, value: value);
        ref.read(settingsRevisionProvider.notifier).bump();
      },
    );
  }
}

/// How statuses appear: rings, the plain group, or nowhere at all — plus
/// the way back for people hidden with a long-press on their ring.
class _StatusRingsToggle extends ConsumerWidget {
  const _StatusRingsToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    final WeftStores stores;
    try {
      stores = ref.watch(storesProvider);
    } on Object {
      return const SizedBox.shrink();
    }
    final mode = ref.watch(statusModeProvider);
    final hidden = ref.watch(hiddenStatusSendersProvider);

    void setMode(StatusMode next) {
      stores.settings.setString(WeftSettings.statusMode, switch (next) {
        StatusMode.rings => 'rings',
        StatusMode.group => 'group',
        StatusMode.off => 'off',
      });
      ref.read(settingsRevisionProvider.notifier).bump();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.donut_large_rounded),
          title: const Text('Statuses'),
          subtitle: Text(switch (mode) {
            StatusMode.rings =>
              'Shown as story rings above the inbox. The broadcast group '
                  'stays hidden.',
            StatusMode.group =>
              'Shown as the "Status Broadcast" group chat, like any other.',
            StatusMode.off => 'Not shown anywhere.',
          }),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: WeftSpace.xl + WeftSpace.xl,
            end: WeftSpace.lg,
            bottom: WeftSpace.sm,
          ),
          child: Wrap(
            spacing: WeftSpace.sm,
            children: [
              for (final (value, label) in [
                (StatusMode.rings, 'Rings'),
                (StatusMode.group, 'Group chat'),
                (StatusMode.off, 'Off'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: mode == value,
                  onSelected: (_) => setMode(value),
                ),
              if (hidden.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.visibility_rounded, size: 16),
                  label: Text('Unhide ${hidden.length}'),
                  onPressed: () =>
                      ref.read(hiddenStatusSendersProvider.notifier).reset(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
