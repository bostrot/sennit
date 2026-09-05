import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';

import '../../app/providers.dart';
import '../../app/snapshot_providers.dart';
import '../../app/stores.dart';
import '../../services/snapshot/snapshot_writer.dart';
import 'settings_section.dart';

/// The opt-in for home screen widgets and the watch companions.
///
/// The third screen of this shape, after the endpoints screen and link
/// previews, and written to be recognisably the same one: a red box saying what
/// switching this on costs, in the words the user would use, before they can
/// switch it on; a per-network escape hatch under it; and no copy invented
/// where the existing copy already says the thing.
///
/// What is new here is the last section. Every other gate in Weft sends
/// something to a *service* — a homeserver, an endpoint the user configured —
/// and the user can reason about what that means. This one writes conversation
/// content to a file on their own phone, which sounds harmless and is the
/// larger disclosure of the two: it is outside the encrypted store, the OS
/// reads it on its own schedule, and any device-level backup copies it. So the
/// screen shows the actual row, built by the actual `buildSnapshotRow` against
/// the user's actual top conversation. A hand-drawn mock-up would be a second
/// answer to what the policy discloses, and it is the answer nobody re-checks
/// after the policy changes.
class SurfacesScreen extends ConsumerWidget {
  const SurfacesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(snapshotSettingsProvider);
    final networks = ref.watch(chatRepositoryProvider).availableNetworks;

    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.surfacesTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            PrivacyNotice(message: context.l10n.surfacesNotice),
            const SizedBox(height: WeftSpace.lg),

            SwitchListTile(
              title: PrivacyGatedTitle(
                title: context.l10n.surfacesWidgetsTitle,
                warning: context.l10n.surfacesWriteWarning,
              ),
              subtitle: Text(context.l10n.surfacesWidgetsSubtitle),
              value: settings.widgets,
              onChanged: (v) => _write(ref, settings.copyWith(widgets: v)),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              title: PrivacyGatedTitle(
                title: context.l10n.surfacesWatchTitle,
                warning: context.l10n.surfacesWriteWarning,
              ),
              subtitle: Text(context.l10n.surfacesWatchSubtitle),
              value: settings.watch,
              onChanged: (v) => _write(ref, settings.copyWith(watch: v)),
              contentPadding: EdgeInsets.zero,
            ),

            if (settings.anySurface) ...[
              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.surfacesRowShowsTitle,
                subtitle: context.l10n.surfacesRowShowsSubtitle,
              ),
              SwitchListTile(
                title: PrivacyGatedTitle(
                  title: context.l10n.surfacesPreviewsTitle,
                  warning: context.l10n.surfacesPreviewsWarning,
                ),
                subtitle: Text(context.l10n.surfacesPreviewsSubtitle),
                value: settings.includePreviews,
                onChanged: (v) =>
                    _write(ref, settings.copyWith(includePreviews: v)),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: PrivacyGatedTitle(
                  title: context.l10n.surfacesNamesTitle,
                  warning: context.l10n.surfacesNamesWarning,
                ),
                subtitle: Text(
                  context.l10n.surfacesNamesSubtitle(
                    context.l10n.snapshotRedactedRowTitle,
                  ),
                ),
                value: settings.includeSenderNames,
                onChanged: (v) =>
                    _write(ref, settings.copyWith(includeSenderNames: v)),
                contentPadding: EdgeInsets.zero,
              ),

              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.settingsNetworksSectionTitle,
                subtitle: context.l10n.surfacesNetworksSubtitle,
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
                title: context.l10n.surfacesLeavesStoreTitle,
                subtitle: context.l10n.surfacesLeavesStoreSubtitle,
              ),
              _SnapshotRowPreview(settings: settings),
            ],
          ],
        ),
      ),
    );
  }

  /// Saves the gate and pushes it straight at the container.
  ///
  /// Both halves matter, and the second is the one that is easy to leave out.
  /// Bumping the revision rebuilds this screen; it does not touch the file the
  /// widget is reading. Someone who has just switched previews off has to see
  /// the home screen stop showing them before they put the phone down, and the
  /// next inbox tick may be minutes away — so the writer is told now.
  void _write(WidgetRef ref, SnapshotSettings next) {
    next.writeTo(ref.read(storesProvider).settings);
    ref.read(settingsRevisionProvider.notifier).bump();
    ref.read(snapshotWriterProvider).applySettings(next);
  }
}

/// One row, exactly as a companion surface would receive it.
///
/// Built through [buildSnapshotRow] — the same function the writer calls — from
/// the first conversation the current policy actually allows. Not the first
/// conversation full stop: a preview that showed an excluded chat would be
/// showing something that is never written, which is the opposite of what this
/// section is for.
///
/// Falls back to a stand-in only when there is nothing to show yet. That case
/// says so, rather than quietly presenting a fiction as the user's own data.
class _SnapshotRowPreview extends ConsumerWidget {
  const _SnapshotRowPreview({required this.settings});

  final SnapshotSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final policy = settings.policy;
    final placeholder = _placeholderChat(context.l10n);
    final subject = chats.firstWhere(
      (chat) => chat.networks.every(policy.allows),
      orElse: () => placeholder,
    );
    final isPlaceholder = identical(subject, placeholder);
    final row = buildSnapshotRow(
      subject,
      policy,
      words: weftNotifyStringsFrom(context.l10n),
      redactedTitle: context.l10n.snapshotRedactedRowTitle,
      deletedPreview: context.l10n.chatMessageDeleted,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WidgetRowCard(row: row),
        const SizedBox(height: WeftSpace.sm),
        Text(
          isPlaceholder
              ? context.l10n.surfacesPreviewPlaceholder
              : context.l10n.surfacesPreviewReal,
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The mock-up itself.
///
/// Drawn as a card that does not look like the rest of the settings screen,
/// because a row rendered in app chrome reads as part of the app rather than as
/// a thing sitting on a home screen. Every string in it comes off the
/// [SnapshotRow]; nothing is re-derived, including the `99+` cap, which is
/// formatted in Dart precisely so that a Glance composable and a SwiftUI view
/// cannot disagree about it.
class _WidgetRowCard extends StatelessWidget {
  const _WidgetRowCard({required this.row});

  final SnapshotRow row;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final hasName = row.title != context.l10n.snapshotRedactedRowTitle;

    return Semantics(
      container: true,
      // One node, and read as a quotation rather than as controls. The card is
      // an illustration of another device's screen; a reader walking it as
      // three separate labels would have no way to tell it from the settings
      // around it.
      label: [
        context.l10n.surfacesExampleRowSemantics,
        row.title,
        if (row.preview != null) row.preview,
        if (row.senderName case final sender?)
          context.l10n.surfacesFromSender(sender),
        if (row.unreadCount > 0)
          context.l10n.surfacesUnreadCount(row.unreadLabel),
        for (final network in row.networks) network.label,
      ].join('. '),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(WeftSpace.md),
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerHighest,
          borderRadius: WeftRadius.allLg,
          border: Border.all(color: context.colors.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: context.colors.primaryContainer,
              foregroundColor: context.colors.onPrimaryContainer,
              child: hasName
                  ? Text(
                      row.title.characters.first.toUpperCase(),
                      style: context.text.titleSmall,
                    )
                  // Names off takes the avatar with it, so the stand-in is a
                  // glyph rather than an initial — an initial *is* the name.
                  : const Icon(Icons.forum_outlined, size: 18),
            ),
            const SizedBox(width: WeftSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _secondLine(row),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                      fontStyle: row.preview == null
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (row.unreadCount > 0)
                  WeftUnreadBadge(
                    count: row.unreadCount,
                    color: palette.unreadDot,
                    ink: context.colors.onPrimary,
                  ),
                const SizedBox(height: WeftSpace.sm),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final network in row.networks)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 2),
                        child: NetworkGlyph(
                          network: network,
                          size: 14,
                          semanticsLabel: '',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The preview, or the sentence that says why there isn't one.
  ///
  /// Never blank. A row whose second line is empty looks like a rendering bug
  /// rather than like a setting doing its job, and this section exists to make
  /// the setting's effect visible.
  static String _secondLine(SnapshotRow row) {
    final preview = row.preview;
    if (preview == null) return 'No message text is written.';
    final sender = row.senderName;
    return sender == null ? preview : '$sender: $preview';
  }
}

/// The stand-in for an inbox that has nothing a surface may show.
///
/// A group chat rather than a DM, and named as an example rather than as a
/// person, so that a screenshot of this screen never shows a plausible contact
/// name that someone might take for real data.
Chat _placeholderChat(AppL10n l10n) => Chat(
  id: '!example:weft.invalid',
  title: l10n.surfacesExampleChatTitle,
  sources: const [
    ChatSource(roomId: '!example:weft.invalid', network: ChatNetwork.matrix),
  ],
  isGroup: true,
  unreadCount: 3,
  lastMessage: WeftMessage(
    eventId: r'$example',
    roomId: '!example:weft.invalid',
    network: ChatNetwork.matrix,
    senderId: '@example:weft.invalid',
    senderName: l10n.surfacesExampleSender,
    // Fixed rather than `DateTime.now()`: the row does not draw a timestamp, and
    // a value that moved every rebuild would make this widget rebuild-unstable
    // for no visible gain — including in a golden.
    timestamp: DateTime.utc(2026),
    kind: MessageKind.text,
    isOwn: false,
    body: l10n.surfacesExampleBody,
  ),
);
