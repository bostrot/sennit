import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../app/reply_reminder_providers.dart';
import 'settings_section.dart';

/// "Every 30 minutes", "Every 3 hours" — an interval as the settings say it.
String replyReminderIntervalLabel(BuildContext context, Duration interval) {
  final l10n = context.l10n;
  return interval.inMinutes % 60 == 0
      ? l10n.replyRemindersEveryHours(interval.inHours)
      : l10n.replyRemindersEveryMinutes(interval.inMinutes);
}

/// Reply reminders: a nudge about a message read and not answered.
///
/// Off unless switched on, and everything below the switch is hidden while it
/// is off, the way the notification master switch hides what it disables.
class ReplyRemindersScreen extends ConsumerWidget {
  const ReplyRemindersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(replyReminderSettingsProvider);
    final notifier = ref.read(replyReminderSettingsProvider.notifier);
    void update(ReplyReminderSettings Function(ReplyReminderSettings) change) =>
        notifier.edit(change);

    // The interval on file, even if it is not one of the presets, so a value
    // from an older build is shown as selected rather than as nothing.
    final intervals = {...kReplyReminderIntervals, settings.interval}.toList()
      ..sort();

    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.replyRemindersTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            SwitchListTile(
              title: Text(context.l10n.replyRemindersEnableTitle),
              subtitle: Text(context.l10n.replyRemindersEnableSubtitle),
              value: settings.enabled,
              onChanged: (v) => update((s) => s.copyWith(enabled: v)),
              contentPadding: EdgeInsets.zero,
            ),
            if (settings.enabled) ...[
              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.replyRemindersIntervalTitle,
                subtitle: context.l10n.replyRemindersIntervalSubtitle,
              ),
              Wrap(
                spacing: WeftSpace.sm,
                runSpacing: WeftSpace.sm,
                children: [
                  for (final interval in intervals)
                    ChoiceChip(
                      label: Text(
                        replyReminderIntervalLabel(context, interval),
                      ),
                      selected: interval == settings.interval,
                      onSelected: (_) =>
                          update((s) => s.copyWith(interval: interval)),
                    ),
                ],
              ),

              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.replyRemindersWhichChatsTitle,
                subtitle: context.l10n.replyRemindersWhichChatsSubtitle,
              ),
              SwitchListTile(
                title: Text(context.l10n.replyRemindersIncludeGroupsTitle),
                subtitle: Text(
                  context.l10n.replyRemindersIncludeGroupsSubtitle(
                    kReplyReminderMaxGroupPeers,
                  ),
                ),
                value: settings.includeGroups,
                onChanged: (v) => update((s) => s.copyWith(includeGroups: v)),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: Text(context.l10n.replyRemindersIncludeMutedTitle),
                subtitle: Text(context.l10n.replyRemindersIncludeMutedSubtitle),
                value: settings.includeMuted,
                onChanged: (v) => update((s) => s.copyWith(includeMuted: v)),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: Text(context.l10n.replyRemindersQuietHoursTitle),
                subtitle: Text(context.l10n.replyRemindersQuietHoursSubtitle),
                value: settings.respectQuietHours,
                onChanged: (v) =>
                    update((s) => s.copyWith(respectQuietHours: v)),
                contentPadding: EdgeInsets.zero,
              ),

              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.replyRemindersExcludedTitle,
                subtitle: context.l10n.replyRemindersExcludedSubtitle,
              ),
              _ExcludedChats(settings: settings),
            ],
          ],
        ),
      ),
    );
  }
}

/// The chats switched off, and the way to switch one more off.
class _ExcludedChats extends ConsumerWidget {
  const _ExcludedChats({required this.settings});

  final ReplyReminderSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final titles = {for (final chat in chats) chat.id: chat.title};
    final ids = settings.excludedChats.toList()
      ..sort((a, b) => (titles[a] ?? a).compareTo(titles[b] ?? b));
    final notifier = ref.read(replyReminderSettingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (ids.isEmpty)
          Text(
            context.l10n.replyRemindersNoneExcluded,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        for (final id in ids)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_paused_outlined),
            // A chat the inbox has not resolved shows its id rather than
            // vanishing from the list of things switched off.
            title: Text(titles[id] ?? id),
            trailing: IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: context.l10n.replyRemindersIncludeAgain,
              onPressed: () => notifier.setChatExcluded(id, excluded: false),
            ),
          ),
        const SizedBox(height: WeftSpace.sm),
        OutlinedButton.icon(
          onPressed: () async {
            final chatId = await _pickChat(context, chats);
            if (chatId == null) return;
            notifier.setChatExcluded(chatId, excluded: true);
          },
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(context.l10n.replyRemindersExcludeChat),
        ),
      ],
    );
  }

  Future<String?> _pickChat(BuildContext context, List<Chat> chats) {
    final candidates =
        chats.where((c) => !c.archived && !settings.isExcluded(c.id)).toList()
          ..sort((a, b) => a.title.compareTo(b.title));
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.l10n.replyRemindersExcludeChat),
        children: [
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: WeftSpace.lg,
                vertical: WeftSpace.sm,
              ),
              child: Text(context.l10n.replyRemindersNoChatsToExclude),
            ),
          for (final chat in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(chat.id),
              child: Text(chat.title),
            ),
        ],
      ),
    );
  }
}
