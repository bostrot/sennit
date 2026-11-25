import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft_attachments/weft_attachments.dart' show MediaQuality;
import 'package:weft_store/weft_store.dart';

import 'package:weft_domain/weft_domain.dart' show ChatNetwork;

import 'contacts_access.dart' show showContactsAccessResult;
import '../../app/billing_providers.dart';
import '../../app/build_info.dart';
import '../../app/localisation.dart';
import '../auth/walkthrough_screen.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../services/web/phone_connection.dart';
import '../../app/stores.dart';
import '../bridges/bridges_screen.dart';
import '../../services/backup/backup_service.dart' show kSennitVersion;
import '../../services/account/account_deletion.dart';
import '../../services/billing/entitlements.dart';
import '../../services/contacts/device_contacts.dart';
import '../../services/status/status_feed.dart';
import '../merge/merge_screen.dart';
import '../schedule/scheduled_screen.dart';
import 'appearance_sheet.dart';
import 'ai_screen.dart';
import 'backup_screen.dart';
import 'delete_account_screen.dart';
import 'device_sync_screen.dart';
import 'integrations_screen.dart';
import 'devices_screen.dart';
import 'link_previews_screen.dart';
import 'mcp_screen.dart';
import 'notifications_screen.dart';
import 'pro_screen.dart';
import 'security_screen.dart';
import 'sennit_web_screen.dart';
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
    final l10n = context.l10n;
    final pro = ref.watch(proControllerProvider);
    final userId = ref.watch(ownUserIdProvider);

    void push(Widget screen) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => screen));
    }

    // A row for a paid feature leads to the Pro screen until it is unlocked,
    // rather than into a screen whose settings would do nothing.
    Widget tile({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
      ProFeature? feature,
    }) {
      final locked = feature != null && !pro.unlocks(feature);
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: locked
            ? const ProBadge()
            : const Icon(Icons.chevron_right_rounded),
        onTap: locked ? () => pushProScreen(context) : onTap,
      );
    }

    // Sennit Web only: forget the phone and start over at the connect screen.
    void unpairBrowser() => forgetPhone();

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
      appBar: WeftAppBar(title: Text(l10n.settingsTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.only(bottom: WeftSpace.xxl),
          children: [
            header(l10n.settingsSectionChats),
            tile(
              icon: Icons.call_merge_rounded,
              title: l10n.settingsMergedChatsTitle,
              subtitle: l10n.settingsMergedChatsSubtitle,
              onTap: () => push(const MergeScreen()),
            ),
            if (!kRemoteClient)
              tile(
                icon: Icons.schedule_send_outlined,
                title: l10n.settingsScheduledTitle,
                subtitle: l10n.settingsScheduledSubtitle,
                onTap: () => push(const ScheduledScreen()),
              ),
            if (!kRemoteClient)
              tile(
                icon: Icons.hub_outlined,
                title: l10n.settingsBridgesTitle,
                subtitle: l10n.settingsBridgesSubtitle,
                onTap: () => push(const BridgesScreen()),
              ),
            if (!kDemoMode && defaultTargetPlatform == TargetPlatform.android)
              tile(
                icon: Icons.sms_outlined,
                title: l10n.settingsSmsTitle,
                subtitle: l10n.settingsSmsSubtitle,
                onTap: () => push(const SmsScreen()),
              ),

            if (!kRemoteClient) const _StatusRingsToggle(),

            header(l10n.settingsSectionLookAndFeel),
            tile(
              icon: Icons.palette_outlined,
              title: l10n.settingsAppearanceTitle,
              subtitle: l10n.settingsAppearanceSubtitle,
              onTap: () => showAppearanceSheet(context),
            ),
            if (!kRemoteClient)
              tile(
                icon: Icons.notifications_outlined,
                title: l10n.settingsNotificationsTitle,
                subtitle: l10n.settingsNotificationsSubtitle,
                onTap: () => push(const NotificationsScreen()),
              ),
            if (_hasKeyboard)
              tile(
                icon: Icons.keyboard_outlined,
                title: l10n.settingsShortcutsTitle,
                subtitle: l10n.settingsShortcutsSubtitle,
                onTap: () => showShortcutsSheet(context),
              ),

            // Sennit Web shows what belongs to the browser; everything else is
            // the phone's, and set there.
            if (kRemoteClient) ...[
              header(l10n.settingsSectionThisBrowser),
              const _SendOnEnterToggle(),
              tile(
                icon: Icons.link_off_rounded,
                title: l10n.sennitWebUnpairTitle,
                subtitle: l10n.sennitWebUnpairSubtitle,
                onTap: unpairBrowser,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: WeftSpace.lg,
                  vertical: WeftSpace.sm,
                ),
                child: Text(
                  l10n.sennitWebSettingsOnPhone,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
            ] else ...[
              header(l10n.settingsSectionSearchAndIntelligence),
              tile(
                icon: Icons.auto_awesome_outlined,
                title: l10n.settingsAiTitle,
                subtitle: l10n.settingsAiSubtitle,
                feature: ProFeature.aiReplies,
                onTap: () => push(const AiSettingsScreen()),
              ),
              const _AgendaToggle(),
              const _SendOnEnterToggle(),
              const _MediaQualityTile(),
              const _HiddenNetworksSection(),

              header(l10n.settingsSectionPrivacyAndSecurity),
              const _ReadReceiptsToggle(),
              const _ContactNamesToggle(),
              tile(
                icon: Icons.link_rounded,
                title: l10n.settingsLinkPreviewsTitle,
                subtitle: l10n.settingsLinkPreviewsSubtitle,
                onTap: () => push(const LinkPreviewsScreen()),
              ),
              if (!kDemoMode)
                tile(
                  icon: Icons.sync_rounded,
                  title: l10n.settingsDeviceSyncTitle,
                  subtitle: l10n.settingsDeviceSyncSubtitle,
                  onTap: () => push(const DeviceSyncScreen()),
                ),
              tile(
                icon: Icons.devices_rounded,
                title: l10n.settingsDevicesTitle,
                subtitle: l10n.settingsDevicesSubtitle,
                onTap: () => push(const DevicesScreen()),
              ),
              tile(
                icon: Icons.lock_outline_rounded,
                title: l10n.settingsEncryptionTitle,
                subtitle: l10n.settingsEncryptionSubtitle,
                onTap: () => push(const SecurityScreen()),
              ),
              tile(
                icon: Icons.archive_outlined,
                title: l10n.settingsBackupTitle,
                subtitle: l10n.settingsBackupSubtitle,
                onTap: () => push(const BackupScreen()),
              ),

              header(l10n.settingsSectionConnections),
              tile(
                icon: Icons.widgets_outlined,
                title: l10n.settingsSurfacesTitle,
                subtitle: l10n.settingsSurfacesSubtitle,
                onTap: () => push(const SurfacesScreen()),
              ),
              tile(
                icon: Icons.home_outlined,
                title: l10n.settingsIntegrationsTitle,
                subtitle: l10n.settingsIntegrationsSubtitle,
                feature: ProFeature.integrations,
                onTap: () => push(const IntegrationsScreen()),
              ),
              // The browser build is the client; it does not serve itself.
              if (!kDemoMode && !kIsWeb)
                tile(
                  icon: Icons.language_rounded,
                  title: l10n.settingsSennitWebTitle,
                  subtitle: l10n.settingsSennitWebSubtitle,
                  onTap: () => push(const SennitWebScreen()),
                ),
              tile(
                icon: Icons.terminal_rounded,
                title: l10n.settingsMcpTitle,
                subtitle: l10n.settingsMcpSubtitle,
                feature: ProFeature.mcpServer,
                onTap: () => push(const McpScreen()),
              ),

              if (userId != null) ...[
                header(l10n.settingsSectionAccount),
                ListTile(
                  leading: Icon(
                    Icons.person_remove_outlined,
                    color: context.colors.error,
                  ),
                  title: Text(
                    l10n.settingsDeleteAccountTitle,
                    style: TextStyle(color: context.colors.error),
                  ),
                  subtitle: Text(
                    l10n.settingsDeleteAccountSubtitle(serverOfUserId(userId)),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => push(const DeleteAccountScreen()),
                ),
              ],
            ],

            header(l10n.settingsSectionAbout),
            if (pro.charges && !kRemoteClient)
              tile(
                icon: Icons.workspace_premium_outlined,
                title: l10n.proTitle,
                subtitle: pro.owned()
                    ? l10n.proSettingsSubtitleOwned
                    : l10n.proSettingsSubtitle,
                onTap: () => pushProScreen(context),
              ),
            tile(
              icon: Icons.info_outline_rounded,
              title: l10n.settingsAboutTitle,
              subtitle: l10n.settingsAboutSubtitle,
              onTap: () => _showAbout(context),
            ),
            if (!kRemoteClient)
              tile(
                icon: Icons.explore_outlined,
                title: l10n.settingsTourTitle,
                subtitle: l10n.settingsTourSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (route) => WalkthroughScreen(
                      onDone: () => Navigator.of(route).pop(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Flutter's About dialog, which carries the licence page with it.
  ///
  /// A test build adds its commit and build date under the version, so a bug
  /// report can name the exact build; see [BuildInfo.summary].
  static void _showAbout(BuildContext context) {
    final build = BuildInfo.current.summary;
    showAboutDialog(
      context: context,
      applicationName: 'Sennit',
      applicationVersion: kSennitVersion,
      children: [if (build != null) SelectableText(build)],
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
      title: Text(context.l10n.settingsReadReceiptsTitle),
      subtitle: Text(context.l10n.settingsReadReceiptsSubtitle),
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
    final l10n = context.l10n;

    return ExpansionTile(
      leading: const Icon(Icons.visibility_off_outlined),
      title: Text(l10n.settingsHiddenNetworksTitle),
      subtitle: Text(
        hidden.isEmpty
            ? l10n.settingsHiddenNetworksNone
            : l10n.settingsHiddenNetworksSome(
                hidden.map((n) => n.label).join(', '),
              ),
      ),
      children: [
        for (final network in networks)
          SwitchListTile(
            dense: true,
            title: Text(l10n.settingsShowNetworkInAll(network.label)),
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
      title: Text(context.l10n.settingsContactNamesTitle),
      subtitle: Text(context.l10n.settingsContactNamesSubtitle),
      value: stores.settings.getBool(WeftSettings.useDeviceContactNames),
      onChanged: (value) async {
        if (value) {
          // The permission prompt belongs to the tap, not to a later sync.
          final access = await enableDeviceContacts(
            stores.settings,
            onChanged: ref.read(settingsRevisionProvider.notifier).bump,
          );
          if (context.mounted) showContactsAccessResult(context, access);
          return;
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
/// What the Return key does in the composer.
///
/// Off by default, which is the opposite of most messengers and deliberate:
/// this composer grows to five lines and people write paragraphs in it, so a
/// Return that sends turns every attempt at a second line into a message
/// nobody meant to send — and there is no unsending one that has already left
/// for another network.
class _SendOnEnterToggle extends ConsumerWidget {
  const _SendOnEnterToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    final WeftStores stores;
    try {
      stores = ref.watch(storesProvider);
    } on StateError {
      return const SizedBox.shrink();
    }

    final on = stores.settings.getBool(WeftSettings.sendOnEnter);
    return SwitchListTile(
      secondary: const Icon(Icons.keyboard_return_rounded),
      title: Text(context.l10n.settingsSendOnEnterTitle),
      subtitle: Text(
        on
            ? context.l10n.settingsSendOnEnterSubtitleOn
            : context.l10n.settingsSendOnEnterSubtitleOff,
      ),
      value: on,
      onChanged: (value) {
        stores.settings.setBool(WeftSettings.sendOnEnter, value: value);
        ref.read(settingsRevisionProvider.notifier).bump();
      },
    );
  }
}

/// How large the photos the user sends go out.
///
/// A sheet of three rather than a switch: the middle choice is the one most
/// people want, and a switch has no middle.
class _MediaQualityTile extends ConsumerWidget {
  const _MediaQualityTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    final WeftStores stores;
    try {
      stores = ref.watch(storesProvider);
    } on Object {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final current = MediaQuality.fromId(
      stores.settings.getString(WeftSettings.mediaQuality),
    );

    Future<void> choose() async {
      final picked = await showModalBottomSheet<MediaQuality>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final quality in MediaQuality.values)
                ListTile(
                  title: Text(mediaQualityLabel(l10n, quality)),
                  subtitle: Text(mediaQualityHint(l10n, quality)),
                  trailing: quality == current
                      ? const Icon(Icons.check_rounded)
                      : null,
                  selected: quality == current,
                  onTap: () => Navigator.of(context).pop(quality),
                ),
            ],
          ),
        ),
      );
      if (picked == null || picked == current) return;
      stores.settings.setString(WeftSettings.mediaQuality, picked.id);
      ref.read(settingsRevisionProvider.notifier).bump();
    }

    return ListTile(
      leading: const Icon(Icons.photo_size_select_large_rounded),
      title: Text(l10n.settingsMediaQualityTitle),
      subtitle: Text(mediaQualityLabel(l10n, current)),
      onTap: choose,
    );
  }
}

/// The name of [quality], as the settings row and its sheet show it.
String mediaQualityLabel(AppL10n l10n, MediaQuality quality) =>
    switch (quality) {
      MediaQuality.original => l10n.mediaQualityOriginal,
      MediaQuality.high => l10n.mediaQualityHigh,
      MediaQuality.dataSaver => l10n.mediaQualityDataSaver,
    };

/// What [quality] does, in a line.
String mediaQualityHint(AppL10n l10n, MediaQuality quality) =>
    switch (quality) {
      MediaQuality.original => l10n.mediaQualityOriginalHint,
      MediaQuality.high => l10n.mediaQualityHighHint,
      MediaQuality.dataSaver => l10n.mediaQualityDataSaverHint,
    };

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
      title: Text(context.l10n.settingsAgendaTitle),
      subtitle: Text(context.l10n.settingsAgendaSubtitle),
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
    final l10n = context.l10n;

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
          title: Text(l10n.settingsStatusesTitle),
          subtitle: Text(switch (mode) {
            StatusMode.rings => l10n.settingsStatusesSubtitleRings,
            StatusMode.group => l10n.settingsStatusesSubtitleGroup,
            StatusMode.off => l10n.settingsStatusesSubtitleOff,
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
                (StatusMode.rings, l10n.settingsStatusModeRings),
                (StatusMode.group, l10n.settingsStatusModeGroup),
                (StatusMode.off, l10n.settingsStatusModeOff),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: mode == value,
                  onSelected: (_) => setMode(value),
                ),
              if (hidden.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.visibility_rounded, size: 16),
                  label: Text(l10n.settingsUnhideStatusSenders(hidden.length)),
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
