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
import '../../data/chat_repository.dart';
import '../call/chat_call_action.dart';
import '../chat/saved_messages_screen.dart';
import '../chat/retention_sheet.dart';
import '../inbox/label_sheet.dart';
import '../merge/merge_screen.dart';
import 'avatar_viewer.dart';
import 'chat_sound_tile.dart';
import 'nickname_dialog.dart';
import 'native_app_link.dart';
import 'person_memory_screen.dart';
import 'shared_media.dart';

/// Who this conversation is with, across every network at once.
///
/// Opened by tapping the title of a chat's app bar. Laid out the way every
/// phone messenger's contact info is, so the thing being looked for is where
/// it is everywhere else: the identity card and the four verbs people come
/// here for (message, call, mute, search) at the top; what has been shared
/// and where the person can be reached open below it; everything that is set
/// once and then left alone folded into a few named groups; archiving last,
/// apart from the rest.
///
/// Nothing is only here in a group: each group's subtitle names what is in
/// it, so a setting can be found without opening every one.
class ContactProfileScreen extends ConsumerWidget {
  const ContactProfileScreen({super.key, required this.chatId, this.onSearch});

  final String chatId;

  /// Opens the search in the conversation this profile was opened from.
  ///
  /// Null hides the Search action, for a profile opened from somewhere with
  /// no conversation behind it to search.
  final VoidCallback? onSearch;

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

    final l10n = context.l10n;
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
      appBar: WeftAppBar(title: Text(l10n.contactTitle)),
      body: WeftReadingPane(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.only(bottom: WeftSpace.xl),
          children: [
            const SizedBox(height: WeftSpace.lg),
            _ProfileHeader(chat: chat, phone: phone),
            const SizedBox(height: WeftSpace.lg),
            _QuickActions(chat: chat, onSearch: onSearch),
            const SizedBox(height: WeftSpace.sm),
            SharedContentSections(chatId: chat.id),
            if (savedHere.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.bookmarks_outlined),
                title: Text(l10n.savedMessagesTitle),
                subtitle: Text(l10n.savedMessagesCount(savedHere.length)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SavedMessagesScreen(rooms: rooms),
                  ),
                ),
              ),
            _SectionHeader(l10n.contactOnTheseNetworks),
            for (final handle in handles) _HandleTile(handle: handle),
            ListTile(
              leading: const Icon(Icons.merge_rounded),
              title: Text(l10n.contactManageMerges),
              subtitle: Text(l10n.contactManageMergesSubtitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MergeScreen()),
              ),
            ),
            const SizedBox(height: WeftSpace.sm),
            const Divider(height: 1),
            _Group(
              key: const ValueKey('contact-group-chat'),
              icon: Icons.tune_rounded,
              title: l10n.contactGroupChat,
              subtitle: l10n.contactGroupChatSubtitle,
              children: [
                _NicknameTile(chat: chat),
                if (chat.networks.length > 1)
                  ListTile(
                    leading: const Icon(Icons.send_rounded),
                    title: Text(l10n.contactSendVia),
                    subtitle: Text(
                      chat.hasExplicitSendNetwork
                          ? (chat.sendNetwork?.label ?? '')
                          : l10n.contactSendViaAutomatic(
                              chat.sendNetwork?.label ?? '',
                            ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _pickSendNetwork(context, repository, chat),
                  ),
                ListTile(
                  leading: const Icon(Icons.label_outline_rounded),
                  title: Text(l10n.contactLabels),
                  subtitle: Text(
                    labels.isEmpty
                        ? l10n.contactNoLabels
                        : (labels.toList()..sort()).join(', '),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showLabelSheet(context, ref, {chat.id}),
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(l10n.retentionTitle),
                  subtitle: Text(
                    retentionSummary(
                      context,
                      ref.watch(retentionPoliciesProvider).forChat(chat.id),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showRetentionSheet(context, chat.id),
                ),
              ],
            ),
            _Group(
              key: const ValueKey('contact-group-notifications'),
              icon: Icons.notifications_outlined,
              title: l10n.contactGroupNotifications,
              subtitle: l10n.contactGroupNotificationsSubtitle,
              children: [
                ChatSoundTile(chat: chat),
                // Only while reminders are on: a switch for a feature that is
                // off would be a switch that does nothing.
                if (reminders.enabled)
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_paused_outlined),
                    title: Text(l10n.replyRemindersTitle),
                    subtitle: Text(l10n.contactReplyRemindersSubtitle),
                    value: !reminders.isExcluded(chat.id),
                    onChanged: (on) => ref
                        .read(replyReminderSettingsProvider.notifier)
                        .setChatExcluded(chat.id, excluded: !on),
                  ),
              ],
            ),
            _Group(
              key: const ValueKey('contact-group-memory'),
              icon: Icons.auto_awesome_outlined,
              title: l10n.personMemorySettingsTitle,
              subtitle: l10n.contactGroupMemorySubtitle,
              children: [
                ChatMemorySections(chat: chat, header: _SectionHeader.new),
              ],
            ),
            // Ids and room addresses: what a bridge or a homeserver admin asks
            // for, and noise to anyone else, so closed until asked for.
            _Group(
              key: const ValueKey('contact-group-technical'),
              icon: Icons.info_outline_rounded,
              title: l10n.contactGroupTechnical,
              subtitle: l10n.contactGroupTechnicalSubtitle,
              children: [
                for (final id in matrixIds)
                  ListTile(
                    leading: const Icon(Icons.alternate_email_rounded),
                    title: _Address(id),
                    subtitle: Text(l10n.contactMatrixUser),
                  ),
                _SectionHeader(l10n.contactConversationsIn),
                for (final source in chat.sources)
                  ListTile(
                    leading: Icon(
                      Icons.forum_rounded,
                      color: context.palette.networkColor(source.network),
                    ),
                    title: Text(source.network.label),
                    subtitle: _Address(source.roomId),
                  ),
              ],
            ),
            const Divider(height: 1),
            const SizedBox(height: WeftSpace.lg),
            // Last and apart: the one row here that takes the conversation
            // out of the inbox.
            SwitchListTile(
              secondary: const Icon(Icons.archive_outlined),
              title: Text(l10n.inboxArchive),
              value: chat.archived,
              onChanged: (archived) =>
                  repository.setArchived(chat.id, archived: archived),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSendNetwork(
    BuildContext context,
    ChatRepository repository,
    Chat chat,
  ) async {
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
  }
}

/// The face, the name, the networks and the number: who this is.
class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader({required this.chat, required this.phone});

  final Chat chat;
  final String? phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phone = this.phone;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
      child: Column(
        children: [
          _ProfileAvatar(chat: chat, headers: ref.watch(mediaHeadersProvider)),
          const SizedBox(height: WeftSpace.md),
          Text(
            chat.title,
            style: context.text.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Text(
              chat.isMerged
                  ? context.l10n.chatMergedNetworks(
                      chat.networks.map((n) => n.label).join(', '),
                    )
                  : chat.networks.map((n) => n.label).join(', '),
              style: context.text.labelMedium?.copyWith(
                color: chat.isMerged
                    ? context.palette.mergedAccent
                    : context.colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (phone != null)
            Padding(
              padding: const EdgeInsets.only(top: WeftSpace.xs),
              child: Tooltip(
                message: context.l10n.contactPhone,
                child: SelectableText(
                  phone,
                  // A number in E.164 is read left to right in every
                  // language; in an Arabic layout the plus would jump to the
                  // end.
                  textDirection: TextDirection.ltr,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The verbs people open a contact for, one tap each.
class _QuickActions extends ConsumerWidget {
  const _QuickActions({required this.chat, required this.onSearch});

  final Chat chat;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final call = chatCallAction(context, ref, chat);
    final onSearch = this.onSearch;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: WeftSpace.md),
      // A wrap rather than a row: at the largest text sizes four labels do
      // not fit side by side, and a second line of actions beats a word
      // broken in half.
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          _QuickAction(
            icon: Icons.chat_bubble_outline_rounded,
            label: l10n.contactActionMessage,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          if (call != null)
            _QuickAction(
              icon: call.icon,
              label: l10n.contactActionCall,
              tooltip: call.tooltip,
              onPressed: call.onPressed,
            ),
          _QuickAction(
            icon: chat.muted
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            label: chat.muted ? l10n.commonUnmute : l10n.commonMute,
            onPressed: () => ref
                .read(chatRepositoryProvider)
                .setMuted(chat.id, muted: !chat.muted),
          ),
          if (onSearch != null)
            _QuickAction(
              icon: Icons.search_rounded,
              label: l10n.contactActionSearch,
              tooltip: l10n.chatSearch,
              onPressed: () {
                Navigator.of(context).pop();
                onSearch();
              },
            ),
        ],
      ),
    );
  }
}

/// One quick action: a tinted icon over its name.
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final String label;

  /// Longer than [label] where the label alone would not say enough, like
  /// why a call cannot be placed.
  final String? tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final foreground = enabled
        ? context.colors.primary
        : context.colors.onSurface.withValues(alpha: 0.38);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 80, maxWidth: 128),
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        hint: tooltip,
        onTap: onPressed,
        excludeSemantics: true,
        child: Tooltip(
          message: tooltip ?? label,
          excludeFromSemantics: true,
          child: InkWell(
            onTap: onPressed,
            borderRadius: WeftRadius.allMd,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.xs,
                vertical: WeftSpace.sm,
              ),
              child: Column(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: context.colors.secondaryContainer.withValues(
                        alpha: enabled ? 1 : 0.5,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: foreground),
                  ),
                  const SizedBox(height: WeftSpace.xs),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: context.text.labelMedium?.copyWith(
                      color: enabled ? null : foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A folded group of settings, its subtitle naming what is inside.
class _Group extends StatelessWidget {
  const _Group({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      // No borders: the open group reads as part of the list it is in.
      shape: const Border(),
      collapsedShape: const Border(),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      childrenPadding: const EdgeInsets.only(bottom: WeftSpace.sm),
      children: children,
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

/// A Matrix id or room address, selectable so it can be copied.
///
/// Read left to right in every language — in an Arabic layout the sigil would
/// otherwise jump to the far end — while still sitting on the layout's start
/// edge.
class _Address extends StatelessWidget {
  const _Address(this.address);

  final String address;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      address,
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textAlign: Directionality.of(context) == TextDirection.rtl
          ? TextAlign.right
          : TextAlign.left,
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
