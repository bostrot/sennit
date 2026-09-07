import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/labels.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../app/retention_providers.dart';
import '../chat/retention_sheet.dart';
import '../inbox/label_sheet.dart';
import '../merge/merge_screen.dart';

/// Who this conversation is with, across every network at once.
///
/// Opened by tapping the avatar in a chat's app bar: the identity card
/// (name, Matrix id, phone), one row per network handle, and the knobs that
/// belong to the *person* rather than to any single message — send network,
/// labels, mute, archive, and the way into merge management.
class ContactProfileScreen extends ConsumerWidget {
  const ContactProfileScreen({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the live list so mute/archive/send-network flips render without
    // reopening the screen.
    final chat = (ref.watch(chatsProvider).value ?? const <Chat>[])
        .where((c) => c.id == chatId)
        .firstOrNull;
    if (chat == null) {
      return Scaffold(
        appBar: WeftAppBar(),
        body: Center(child: Text(context.l10n.contactGone)),
      );
    }

    final repository = ref.watch(chatRepositoryProvider);
    final graph = repository.identityGraph;
    final handles = chat.contactId == null
        ? <NetworkHandle>[]
        : graph.handlesInContact(chat.contactId!);
    final phone = handles
        .map((h) => h.phoneE164)
        .whereType<String>()
        .firstOrNull;
    final matrixIds = {
      for (final h in handles)
        if (h.matrixUserId.isNotEmpty) h.matrixUserId,
    };
    ref.watch(chatLabelsProvider);
    final labels = ref.watch(chatLabelsProvider.notifier).ofChat(chat.id);

    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.contactTitle)),
      body: WeftReadingPane(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.only(bottom: WeftSpace.xl),
          children: [
            const SizedBox(height: WeftSpace.lg),
            Center(
              child: Column(
                children: [
                  WeftAvatar(
                    label: chat.title,
                    imageUrl: chat.avatarUrl,
                    imageHeaders: ref.watch(mediaHeadersProvider),
                    networks: chat.networks,
                    size: 96,
                  ),
                  const SizedBox(height: WeftSpace.md),
                  Text(
                    chat.title,
                    style: context.text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (chat.isMerged)
                    Padding(
                      padding: const EdgeInsets.only(top: WeftSpace.xs),
                      child: Text(
                        context.l10n.chatMergedNetworks(
                          chat.networks.map((n) => n.label).join(', '),
                        ),
                        style: context.text.labelMedium?.copyWith(
                          color: context.palette.mergedAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: WeftSpace.lg),
            if (phone != null)
              ListTile(
                leading: const Icon(Icons.phone_rounded),
                title: Text(phone),
                subtitle: Text(context.l10n.contactPhone),
              ),
            for (final id in matrixIds)
              ListTile(
                leading: const Icon(Icons.alternate_email_rounded),
                title: Text(id),
                subtitle: Text(context.l10n.contactMatrixUser),
              ),
            if (handles.isNotEmpty) ...[
              _SectionHeader(context.l10n.contactOnTheseNetworks),
              for (final handle in handles)
                ListTile(
                  leading: Icon(
                    Icons.circle,
                    size: 14,
                    color: context.palette.networkColor(handle.network),
                  ),
                  title: Text(handle.displayName ?? handle.remoteId),
                  subtitle: Text(
                    handle.remoteId == (handle.displayName ?? '')
                        ? handle.network.label
                        : context.l10n.handleOnNetwork(
                            handle.network.label,
                            handle.remoteId,
                          ),
                  ),
                ),
            ],
            _SectionHeader(context.l10n.contactConversationsIn),
            for (final source in chat.sources)
              ListTile(
                leading: Icon(
                  Icons.forum_rounded,
                  color: context.palette.networkColor(source.network),
                ),
                title: Text(source.network.label),
                subtitle: Text(
                  source.roomId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            _SectionHeader(context.l10n.contactForThisContact),
            if (chat.networks.length > 1)
              ListTile(
                leading: const Icon(Icons.send_rounded),
                title: Text(context.l10n.contactSendVia),
                subtitle: Text(
                  chat.hasExplicitSendNetwork
                      ? (chat.sendNetwork?.label ?? '')
                      : context.l10n.contactSendViaAutomatic(
                          chat.sendNetwork?.label ?? '',
                        ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final network = await showWeftPanel<ChatNetwork>(
                    context: context,
                    showDragHandle: true,
                    builder: (context) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final n in chat.networks)
                            ListTile(
                              leading: Icon(
                                Icons.circle,
                                size: 14,
                                color: context.palette.networkColor(n),
                              ),
                              title: Text(n.label),
                              selected: n == chat.sendNetwork,
                              onTap: () => Navigator.of(context).pop(n),
                            ),
                        ],
                      ),
                    ),
                  );
                  if (network != null) {
                    await repository.setSendNetwork(chat.id, network);
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.label_outline_rounded),
              title: Text(context.l10n.contactLabels),
              subtitle: Text(
                labels.isEmpty
                    ? context.l10n.contactNoLabels
                    : (labels.toList()..sort()).join(', '),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showLabelSheet(context, ref, {chat.id}),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(context.l10n.retentionTitle),
              subtitle: Text(
                retentionSummary(
                  context,
                  ref.watch(retentionPoliciesProvider).forChat(chat.id),
                ),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showRetentionSheet(context, chat.id),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_off_outlined),
              title: Text(context.l10n.commonMute),
              value: chat.muted,
              onChanged: (muted) => repository.setMuted(chat.id, muted: muted),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.archive_outlined),
              title: Text(context.l10n.inboxArchive),
              value: chat.archived,
              onChanged: (archived) =>
                  repository.setArchived(chat.id, archived: archived),
            ),
            ListTile(
              leading: const Icon(Icons.merge_rounded),
              title: Text(context.l10n.contactManageMerges),
              subtitle: Text(context.l10n.contactManageMergesSubtitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MergeScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.lg,
        WeftSpace.lg,
        WeftSpace.lg,
        WeftSpace.xs,
      ),
      child: Text(
        title,
        style: context.text.labelLarge?.copyWith(
          color: context.colors.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
