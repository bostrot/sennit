import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/labels.dart';
import '../../app/localisation.dart';
import '../../app/nickname_providers.dart';
import '../../app/providers.dart';
import '../../app/reply_reminder_providers.dart';
import '../../app/retention_providers.dart';
import '../../app/saved_messages.dart';
import '../chat/saved_messages_screen.dart';
import '../chat/retention_sheet.dart';
import '../inbox/label_sheet.dart';
import '../merge/merge_screen.dart';
import 'avatar_viewer.dart';
import 'nickname_dialog.dart';
import 'native_app_link.dart';
import 'person_memory_screen.dart';
import 'shared_media.dart';

/// Who this conversation is with, across every network at once.
///
/// Opened by tapping the title of a chat's app bar: the identity card
/// (name, Matrix id, phone), what has been shared in the conversation, one row
/// per network handle, and the knobs that belong to the *person* rather than
/// to any single message — send network, labels, mute, archive, and the way
/// into merge management.
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
    final reminders = ref.watch(replyReminderSettingsProvider);
    final rooms = {for (final source in chat.sources) source.roomId};
    final savedHere = filterSavedMessages(
      ref.watch(savedMessagesProvider),
      rooms: rooms,
    );

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
                  _ProfileAvatar(
                    chat: chat,
                    headers: ref.watch(mediaHeadersProvider),
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
            SharedContentSections(chatId: chat.id),
            if (savedHere.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.bookmarks_outlined),
                title: Text(context.l10n.savedMessagesTitle),
                subtitle: Text(
                  context.l10n.savedMessagesCount(savedHere.length),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SavedMessagesScreen(rooms: rooms),
                  ),
                ),
              ),
            ChatMemorySections(chat: chat, header: _SectionHeader.new),
            if (handles.isNotEmpty) ...[
              _SectionHeader(context.l10n.contactOnTheseNetworks),
              for (final handle in handles) _HandleTile(handle: handle),
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
            _NicknameTile(chat: chat),
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
            // Only while reminders are on: a switch for a feature that is off
            // would be a switch that does nothing.
            if (reminders.enabled)
              SwitchListTile(
                secondary: const Icon(Icons.notifications_paused_outlined),
                title: Text(context.l10n.replyRemindersTitle),
                subtitle: Text(context.l10n.contactReplyRemindersSubtitle),
                value: !reminders.isExcluded(chat.id),
                onChanged: (on) => ref
                    .read(replyReminderSettingsProvider.notifier)
                    .setChatExcluded(chat.id, excluded: !on),
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

/// The way into the user's private name and picture for this conversation.
class _NicknameTile extends ConsumerWidget {
  const _NicknameTile({required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nicknames = ref.watch(chatNicknamesProvider);
    final nickname = nicknames.nameFor(chat);
    final repository = ref.watch(chatRepositoryProvider);
    // What the networks call it: the repository's chat has no nickname on it.
    final original =
        chat.roomIds
            .map(repository.chatForRoom)
            .whereType<Chat>()
            .firstOrNull
            ?.title ??
        chat.title;
    return ListTile(
      leading: const Icon(Icons.badge_outlined),
      title: Text(context.l10n.nicknameTitle),
      subtitle: Text(
        nickname == null
            ? context.l10n.nicknameSubtitle
            : context.l10n.nicknameSubtitleSet(original),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showNicknameDialog(context, chat: chat, original: original),
    );
  }
}

/// One of the person's accounts, and the way into it in the network's own
/// app when there is one.
class _HandleTile extends StatelessWidget {
  const _HandleTile({required this.handle});

  final NetworkHandle handle;

  @override
  Widget build(BuildContext context) {
    final link = nativeAppLink(handle);
    final openIn = context.l10n.contactOpenInApp(handle.network.label);
    void open() => openSharedLink(context, link.toString());
    return ListTile(
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
      onTap: link == null ? null : open,
      trailing: link == null
          ? null
          : IconButton(
              tooltip: openIn,
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: open,
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

/// The big avatar at the top, which opens the picture full screen when there
/// is one.
///
/// Without a picture it is initials in a circle, and a screen showing the same
/// initials larger is a tap that leads nowhere, so then it is not a button.
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.chat, required this.headers});

  final Chat chat;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    final avatar = WeftAvatar(
      label: chat.title,
      imageUrl: chat.avatarUrl,
      imageHeaders: headers,
      networks: chat.networks,
      size: 96,
    );
    final imageUrl = chat.avatarUrl;
    if (imageUrl == null) return avatar;

    void open() =>
        openAvatarViewer(context, name: chat.title, imageUrl: imageUrl);
    // The avatar keeps its own label (who, on which networks); the hint is
    // what a tap does, the way the chat title says it opens these details.
    return Semantics(
      button: true,
      hint: context.l10n.contactPhotoOpen,
      onTap: open,
      child: Tooltip(
        message: context.l10n.contactPhotoOpen,
        excludeFromSemantics: true,
        child: InkResponse(
          onTap: open,
          customBorder: const CircleBorder(),
          excludeFromSemantics: true,
          child: avatar,
        ),
      ),
    );
  }
}
