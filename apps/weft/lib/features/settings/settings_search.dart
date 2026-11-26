/// Finding a setting by what it is called or what it does.
///
/// The settings tree is deep — notifications, AI, endpoints, integrations,
/// SMS — and the switch someone wants is often two screens down under a name
/// they would not have guessed. The search field on the settings screen
/// matches every word typed against a row's title, its description and the
/// screens it sits under, so "quiet" finds quiet hours whether they live under
/// Notifications or Reply reminders.
library;

import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import '../../services/billing/entitlements.dart';
import 'ai_screen.dart';
import 'appearance_sheet.dart';
import 'auto_reply_screen.dart';
import 'backup_screen.dart';
import 'device_sync_screen.dart';
import 'endpoints_screen.dart';
import 'integrations_screen.dart';
import 'link_previews_screen.dart';
import 'mcp_screen.dart';
import 'models_screen.dart';
import 'notifications_screen.dart';
import 'person_memory_settings_screen.dart';
import 'quick_messages_screen.dart';
import 'reply_reminders_screen.dart';
import 'security_screen.dart';
import 'sennit_web_screen.dart';
import 'sms_screen.dart';
import 'surfaces_screen.dart';

/// One row search can find.
///
/// [trail] names the screens it sits under, outermost first, and is what a
/// result shows above its title — "Notifications › Quiet hours" says where
/// the row will be when the screen opens.
@immutable
class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.title,
    this.subtitle,
    this.trail = const [],
    this.icon,
    this.open,
    this.child,
  });

  final String title;
  final String? subtitle;
  final List<String> trail;
  final IconData? icon;

  /// Opens the screen the row lives on.
  final void Function(BuildContext context)? open;

  /// The row itself, drawn as the result when it is a switch that lives on
  /// the settings screen: flipping it from the result is the shortest way.
  final Widget? child;

  /// Whether every word of [query] is somewhere in this entry.
  ///
  /// Words rather than the whole string, so "previews link" finds "Link
  /// previews"; case-folded, so a phone keyboard's capital letter does not
  /// hide everything.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'));
    final haystack = [title, subtitle ?? '', ...trail].join('\n').toLowerCase();
    return words.where((w) => w.isNotEmpty).every(haystack.contains);
  }

  /// Whether the title alone carries every word, which sorts a result first.
  bool _titleMatches(String query) =>
      SettingsSearchEntry(title: title).matches(query);
}

/// The entries of [all] that match [query], title hits first.
///
/// Stable inside each group, so results keep the order of the settings
/// screen itself rather than jumping around as letters are typed.
List<SettingsSearchEntry> searchSettings(
  List<SettingsSearchEntry> all,
  String query,
) {
  if (query.trim().isEmpty) return const [];
  final hits = all.where((e) => e.matches(query)).toList();
  return [
    ...hits.where((e) => e._titleMatches(query)),
    ...hits.where((e) => !e._titleMatches(query)),
  ];
}

/// The rows on screens below the settings screen.
///
/// Only rows whose words are fixed: a description that changes with the
/// setting's value would match one state and not the other. The gates mirror
/// the settings screen's own, so a result never opens a screen this build
/// does not show. A row added to one of these screens belongs here too.
List<SettingsSearchEntry> nestedSettingsEntries(
  AppL10n l10n, {
  required bool android,
  required bool showSms,
  required bool showSennitWeb,
  required void Function(BuildContext context, Widget screen) push,
  required bool Function(ProFeature feature) locked,
  required void Function(BuildContext context) openPro,
}) {
  void Function(BuildContext) to(Widget screen, {ProFeature? gate}) =>
      (context) => gate != null && locked(gate)
      ? openPro(context)
      : push(context, screen);

  List<SettingsSearchEntry> under(
    List<String> trail,
    IconData icon,
    void Function(BuildContext) open,
    List<(String, String?)> rows,
  ) => [
    for (final (title, subtitle) in rows)
      SettingsSearchEntry(
        title: title,
        subtitle: subtitle,
        trail: trail,
        icon: icon,
        open: open,
      ),
  ];

  final notifications = [l10n.settingsNotificationsTitle];
  final reminders = [...notifications, l10n.replyRemindersTitle];
  final ai = [l10n.settingsAiTitle];

  return [
    ...under(
      notifications,
      Icons.notifications_outlined,
      to(const NotificationsScreen()),
      [
        (
          l10n.notificationsMentionsOnlyTitle,
          l10n.notificationsMentionsOnlySubtitle,
        ),
        (
          l10n.notificationsMentionsBypassTitle,
          l10n.notificationsMentionsBypassSubtitle,
        ),
        (
          l10n.notificationsShowPreviewsTitle,
          l10n.notificationsShowPreviewsSubtitle,
        ),
        (
          l10n.notificationsQuietHoursTitle,
          l10n.notificationsQuietHoursSubtitle,
        ),
        (
          l10n.notificationsDeliverSilentlyTitle,
          l10n.notificationsDeliverSilentlySubtitle,
        ),
        (
          l10n.notificationsMutedChatsTitle,
          l10n.notificationsMutedChatsSubtitle,
        ),
        (
          l10n.notificationsSmartRepliesTitle,
          l10n.notificationsSmartRepliesSubtitle,
        ),
        (l10n.notificationsPushTitle, l10n.notificationsPushSubtitle),
        (l10n.notificationsTestTitle, l10n.notificationsTestSubtitle),
        (l10n.replyRemindersTitle, null),
        if (android) ...[
          (
            l10n.notificationsStayConnectedTitle,
            l10n.notificationsStayConnectedSubtitle,
          ),
          (
            l10n.notificationsBatteryToggleTitle,
            l10n.notificationsBatteryToggleSubtitle,
          ),
        ],
      ],
    ),
    ...under(
      reminders,
      Icons.notifications_active_outlined,
      to(const ReplyRemindersScreen()),
      [
        (l10n.replyRemindersEnableTitle, l10n.replyRemindersEnableSubtitle),
        (l10n.replyRemindersIntervalTitle, l10n.replyRemindersIntervalSubtitle),
        (
          l10n.replyRemindersIncludeMutedTitle,
          l10n.replyRemindersIncludeMutedSubtitle,
        ),
        (
          l10n.replyRemindersQuietHoursTitle,
          l10n.replyRemindersQuietHoursSubtitle,
        ),
        (
          l10n.replyRemindersReactionsTitle,
          l10n.replyRemindersReactionsSubtitle,
        ),
      ],
    ),
    ...under(
      [l10n.settingsAppearanceTitle],
      Icons.palette_outlined,
      (context) => showAppearanceSheet(context),
      [
        (
          l10n.appearanceRailMultiSelectTitle,
          l10n.appearanceRailMultiSelectSubtitle,
        ),
      ],
    ),
    if (showSms)
      ...under(
        [l10n.settingsSmsTitle],
        Icons.sms_outlined,
        to(const SmsScreen()),
        [(l10n.smsRoleTitle, l10n.smsRoleSubtitle), (l10n.smsRcsTitle, null)],
      ),
    ...under(
      ai,
      Icons.auto_awesome_outlined,
      to(const AiSettingsScreen(), gate: ProFeature.aiReplies),
      [
        (l10n.settingsEndpointsTitle, l10n.settingsEndpointsSubtitle),
        (l10n.settingsModelsTitle, l10n.settingsModelsSubtitle),
        (l10n.settingsAutoReplyTitle, l10n.settingsAutoReplySubtitle),
        (l10n.quickMessageSheetTitle, l10n.quickMessagesSettingsSubtitle),
        (l10n.personMemorySettingsTitle, l10n.personMemorySettingsSubtitle),
      ],
    ),
    ...under(
      [...ai, l10n.settingsEndpointsTitle],
      Icons.dns_outlined,
      to(const EndpointsScreen(), gate: ProFeature.aiReplies),
      [
        (l10n.endpointsTranscriptionTitle, l10n.endpointsTranscriptionSubtitle),
        (
          l10n.endpointsAutoTranscribeTitle,
          l10n.endpointsAutoTranscribeSubtitle,
        ),
        (l10n.endpointsEmbeddingsTitle, l10n.endpointsEmbeddingsSubtitle),
        (l10n.endpointsLlmTitle, l10n.endpointsLlmSubtitle),
        (l10n.endpointsThinkingTitle, l10n.endpointsThinkingSubtitle),
        (l10n.endpointsLimitsTitle, l10n.endpointsLimitsSubtitle),
      ],
    ),
    ...under(
      [...ai, l10n.settingsModelsTitle],
      Icons.memory_rounded,
      to(const ModelsScreen(), gate: ProFeature.aiReplies),
      [
        (l10n.modelsUseForSearchTitle, l10n.modelsUseForSearchSubtitle),
        (l10n.modelsUseForVoiceTitle, l10n.modelsUseForVoiceSubtitle),
      ],
    ),
    ...under(
      [...ai, l10n.settingsAutoReplyTitle],
      Icons.reply_all_rounded,
      to(const AutoReplyScreen(), gate: ProFeature.aiReplies),
      [(l10n.autoReplyRulesTitle, l10n.autoReplyRulesSubtitle)],
    ),
    ...under(
      [...ai, l10n.quickMessageSheetTitle],
      Icons.bolt_rounded,
      to(const QuickMessagesScreen(), gate: ProFeature.aiReplies),
      const [],
    ),
    ...under(
      [...ai, l10n.personMemorySettingsTitle],
      Icons.person_search_outlined,
      to(const PersonMemorySettingsScreen(), gate: ProFeature.aiReplies),
      [
        (l10n.personMemoryAutoTitle, l10n.personMemoryAutoSubtitle),
        (l10n.personMemoryEncryptedTitle, l10n.personMemoryEncryptedSubtitle),
      ],
    ),
    ...under(
      [l10n.settingsLinkPreviewsTitle],
      Icons.link_rounded,
      to(const LinkPreviewsScreen()),
      [
        (l10n.linkPreviewsShowTitle, l10n.linkPreviewsShowSubtitle),
        (l10n.linkPreviewsEncryptedTitle, l10n.linkPreviewsEncryptedSubtitle),
        (l10n.linkPreviewsCacheTitle, l10n.linkPreviewsCacheSubtitle),
      ],
    ),
    ...under(
      [l10n.settingsDeviceSyncTitle],
      Icons.sync_rounded,
      to(const DeviceSyncScreen()),
      [
        (l10n.deviceSyncEnableTitle, l10n.deviceSyncEnableSubtitle),
        (l10n.deviceSyncSecretsTitle, l10n.deviceSyncSecretsSubtitle),
      ],
    ),
    ...under(
      [l10n.settingsEncryptionTitle],
      Icons.lock_outline_rounded,
      to(const SecurityScreen()),
      [
        (l10n.securityRecoveryTitle, l10n.securityRecoverySubtitle),
        (l10n.securityRestoreTitle, l10n.securityRestoreSubtitle),
      ],
    ),
    ...under(
      [l10n.settingsBackupTitle],
      Icons.archive_outlined,
      to(const BackupScreen()),
      [
        (l10n.backupExportSectionTitle, l10n.backupExportSectionSubtitle),
        (l10n.backupIncludeMediaTitle, l10n.backupIncludeMediaSubtitle),
        (l10n.backupRestoreSectionTitle, l10n.backupRestoreSectionSubtitle),
      ],
    ),
    ...under(
      [l10n.settingsSurfacesTitle],
      Icons.widgets_outlined,
      to(const SurfacesScreen()),
      [
        (l10n.surfacesWidgetsTitle, l10n.surfacesWidgetsSubtitle),
        (l10n.surfacesWatchTitle, l10n.surfacesWatchSubtitle),
        (l10n.surfacesPreviewsTitle, l10n.surfacesPreviewsSubtitle),
      ],
    ),
    ...under(
      [l10n.settingsIntegrationsTitle],
      Icons.home_outlined,
      to(const IntegrationsScreen(), gate: ProFeature.integrations),
      [
        (l10n.integrationsCalendarTitle, l10n.integrationsCalendarSubtitle),
        (
          l10n.integrationsCalendarForAiTitle,
          l10n.integrationsCalendarForAiSubtitle,
        ),
        (
          l10n.integrationsHomeAssistantTitle,
          l10n.integrationsHomeAssistantSubtitle,
        ),
        (l10n.integrationsPaperlessTitle, l10n.integrationsPaperlessSubtitle),
      ],
    ),
    if (showSennitWeb)
      ...under(
        [l10n.settingsSennitWebTitle],
        Icons.language_rounded,
        to(const SennitWebScreen()),
        [
          (l10n.sennitWebServeTitle, l10n.sennitWebServeSubtitle),
          (l10n.sennitWebRelayTitle, null),
        ],
      ),
    ...under(
      [l10n.settingsMcpTitle],
      Icons.terminal_rounded,
      to(const McpScreen(), gate: ProFeature.mcpServer),
      [
        (l10n.mcpRunServerTitle, null),
        (l10n.mcpTunnelTitle, null),
        (l10n.mcpApiKeysTitle, null),
      ],
    ),
  ];
}

/// One result: the trail it sits under, then the row as it reads there.
class SettingsSearchResult extends StatelessWidget {
  const SettingsSearchResult({super.key, required this.entry});

  final SettingsSearchEntry entry;

  @override
  Widget build(BuildContext context) {
    final child = entry.child;
    if (child != null) return child;
    final open = entry.open;
    final subtitle = entry.subtitle;
    return ListTile(
      leading: entry.icon == null ? null : Icon(entry.icon),
      title: Text(entry.title),
      subtitle: Text(
        [
          if (entry.trail.isNotEmpty) entry.trail.join(' › '),
          ?subtitle,
        ].join('\n'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: entry.trail.isNotEmpty && subtitle != null,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: open == null ? null : () => open(context),
    );
  }
}

/// The field at the top of the settings screen.
class SettingsSearchField extends StatelessWidget {
  const SettingsSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: context.l10n.settingsSearchHint,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.settingsSearchClear,
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        border: const OutlineInputBorder(borderRadius: WeftRadius.pill),
      ),
    );
  }
}
