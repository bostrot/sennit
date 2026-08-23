import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';

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
      appBar: AppBar(title: const Text('Widgets & watch')),
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: [
          const PrivacyNotice(
            message:
                'A widget and a watch cannot decrypt your messages, so Braid has '
                'to write what they show into a file outside the encrypted '
                'store. That file sits on this device where the system, and any '
                'backup of this device, can read it — and a home screen is '
                'read by whoever is standing next to you. Nothing is written '
                'until you switch a surface on below, and you choose how much '
                'of a conversation goes into it.',
          ),
          const SizedBox(height: WeftSpace.lg),

          SwitchListTile(
            title: const PrivacyGatedTitle(
              title: 'Home screen widgets',
              warning:
                  'Turning this on writes your recent conversations to a file '
                  'outside the encrypted store, which backups can read.',
            ),
            subtitle: const Text(
              'Adds an unread-count tile and a recent-conversations list you '
              'can place on your home screen.',
            ),
            value: settings.widgets,
            onChanged: (v) => _write(ref, settings.copyWith(widgets: v)),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: const PrivacyGatedTitle(
              title: 'Watch',
              warning:
                  'Turning this on writes your recent conversations to a file '
                  'outside the encrypted store, which backups can read.',
            ),
            subtitle: const Text(
              'Sends the same list to a paired watch. Replies you dictate are '
              'handed back to this phone to send — the watch never holds your '
              'account.',
            ),
            value: settings.watch,
            onChanged: (v) => _write(ref, settings.copyWith(watch: v)),
            contentPadding: EdgeInsets.zero,
          ),

          if (settings.anySurface) ...[
            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'What a row shows',
              subtitle:
                  'Both are off to begin with. With both off, a surface is told '
                  'how many unread messages you have and nothing else — no '
                  'names, no words, no faces.',
            ),
            SwitchListTile(
              title: const PrivacyGatedTitle(
                title: 'Message previews',
                warning:
                    'Turning this on puts the text of your most recent messages '
                    'on your home screen.',
              ),
              subtitle: const Text(
                'The first line of the newest message in each conversation.',
              ),
              value: settings.includePreviews,
              onChanged: (v) =>
                  _write(ref, settings.copyWith(includePreviews: v)),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              title: const PrivacyGatedTitle(
                title: 'Names and faces',
                warning:
                    'Turning this on puts the names and profile pictures of the '
                    'people you talk to on your home screen.',
              ),
              subtitle: const Text(
                'Who each conversation is with, who sent the last message, and '
                'their picture. Off, every row is labelled '
                '“$kRedactedRowTitle”.',
              ),
              value: settings.includeSenderNames,
              onChanged: (v) =>
                  _write(ref, settings.copyWith(includeSenderNames: v)),
              contentPadding: EdgeInsets.zero,
            ),

            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'Networks',
              subtitle:
                  'An excluded network never reaches a widget or a watch, '
                  'whatever the switches above say. A conversation that carries '
                  'an excluded network is left out whole — there is no half of '
                  'a merged row to show.',
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
              title: 'What leaves the encrypted store',
              subtitle:
                  'Your own top conversation, drawn the way a widget row draws '
                  'it, with the switches above applied. This is the whole of '
                  'what a surface is given.',
            ),
            _SnapshotRowPreview(settings: settings),
          ],
        ],
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
    final subject = chats.firstWhere(
      (chat) => chat.networks.every(policy.allows),
      orElse: () => _placeholderChat,
    );
    final isPlaceholder = identical(subject, _placeholderChat);
    final row = buildSnapshotRow(subject, policy);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WidgetRowCard(row: row),
        const SizedBox(height: WeftSpace.sm),
        Text(
          isPlaceholder
              ? 'An example — no conversation here is allowed onto a surface '
                    'yet, either because there are none or because every one of '
                    'them is on an excluded network.'
              : 'Your most recent conversation that a surface is allowed to '
                    'show.',
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
    final hasName = row.title != kRedactedRowTitle;

    return Semantics(
      container: true,
      // One node, and read as a quotation rather than as controls. The card is
      // an illustration of another device's screen; a reader walking it as
      // three separate labels would have no way to tell it from the settings
      // around it.
      label: [
        'Example widget row.',
        row.title,
        if (row.preview != null) row.preview,
        if (row.senderName != null) 'from ${row.senderName}',
        if (row.unreadCount > 0) '${row.unreadLabel} unread',
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
final Chat _placeholderChat = Chat(
  id: '!example:weft.invalid',
  title: 'Weekend plans',
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
    senderName: 'Sam',
    // Fixed rather than `DateTime.now()`: the row does not draw a timestamp, and
    // a value that moved every rebuild would make this widget rebuild-unstable
    // for no visible gain — including in a golden.
    timestamp: DateTime.utc(2026),
    kind: MessageKind.text,
    isOwn: false,
    body: 'Still on for Saturday?',
  ),
);
