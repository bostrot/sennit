import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/labels.dart';
import '../../services/contacts/device_contacts.dart';
import '../../services/schedule/scheduled_actions.dart';
import '../../app/providers.dart';
import '../../app/shortcuts.dart';
import '../bridges/bridges_screen.dart';
import '../chat/chat_preview.dart';
import '../chat/chat_view.dart';
import '../merge/merge_screen.dart';
import '../status/status_bar.dart';
import 'label_sheet.dart';
import 'mac_shell.dart';
import 'new_chat_sheet.dart';
import '../search/search_screen.dart';
import '../settings/appearance_sheet.dart';
import '../settings/settings_screen.dart';

/// Whether this platform drives with a pointer — right-click then owns the
/// per-conversation verbs, mirroring what long-press-selection offers.
bool get _isDesktopPointer =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };

/// The conversation's verbs, at the cursor.
///
/// Public because both shells raise the same menu: right-clicking a row means
/// the same thing whichever layout drew it, and a second copy of these seven
/// actions would drift from this one.
Future<void> showChatContextMenu(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  Offset position,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final repository = ref.read(chatRepositoryProvider);

  PopupMenuItem<String> item(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) => PopupMenuItem(
    value: value,
    height: MacMetrics.menuItemHeight,
    child: Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: WeftSpace.sm),
        Text(label, style: color == null ? null : TextStyle(color: color)),
      ],
    ),
  );

  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: [
      // First, because it is the one verb here that changes nothing — and the
      // reason it exists is that every other way of looking at a conversation
      // marks it read.
      item('peek', Icons.visibility_outlined, 'Peek'),
      if (chat.unreadCount > 0)
        item('read', Icons.mark_email_read_outlined, 'Mark read')
      else
        item('unread', Icons.mark_email_unread_outlined, 'Mark unread'),
      if (chat.muted)
        item('unmute', Icons.notifications_active_outlined, 'Unmute')
      else
        item('mute', Icons.notifications_off_outlined, 'Mute'),
      if (chat.archived)
        item('unarchive', Icons.unarchive_outlined, 'Unarchive')
      else
        item('archive', Icons.archive_outlined, 'Archive'),
      item('label', Icons.label_outline_rounded, 'Labels…'),
      item('select', Icons.check_circle_outline_rounded, 'Select'),
      item(
        'delete',
        Icons.delete_outline_rounded,
        'Delete',
        color: Theme.of(context).colorScheme.error,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'peek':
      await showChatPreview(context, chat.id);
    case 'read':
      await repository.markRead(chat.id);
    case 'unread':
      await repository.markUnread(chat.id);
    case 'mute':
      await repository.setMuted(chat.id, muted: true);
    case 'unmute':
      await repository.setMuted(chat.id, muted: false);
    case 'archive':
      await repository.setArchived(chat.id, archived: true);
    case 'unarchive':
      await repository.setArchived(chat.id, archived: false);
    case 'label':
      await showLabelSheet(context, ref, {chat.id});
    case 'select':
      ref.read(chatSelectionProvider.notifier).toggle(chat.id);
    case 'delete':
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Delete "${chat.title}"?'),
          content: const Text(
            'The conversation leaves this app. History on the network is '
            'not affected.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialog).colorScheme.error,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true) await repository.deleteChat(chat.id);
  }
}

/// Today shows a clock; this week a weekday; older a date. Matches how people
/// actually reason about when a message arrived.
///
/// [now] is required rather than defaulted, and that is the whole fix: it used
/// to be a constant instant in the body of this function — the one the demo
/// fixtures are dated against, put there so goldens would settle. Every real
/// message is newer than that instant, so every real conversation came out as
/// "Now". A default here would be a place for the same mistake to be made
/// again quietly; a required argument makes each caller say which clock it
/// means.
String? formatInboxTime(DateTime? ts, {required DateTime now}) {
  if (ts == null) return null;
  final delta = now.difference(ts);
  if (delta.inMinutes < 1) return 'Now';
  if (delta.inHours < 24) return DateFormat.Hm().format(ts);
  if (delta.inDays < 7) return DateFormat.E().format(ts);
  return DateFormat.yMd().format(ts);
}

/// The app's home: network rail, inbox, and — when there's room — the open
/// conversation beside it.
class InboxShell extends ConsumerWidget {
  const InboxShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Two shells, not one shell with thirty conditions in it. The desktop
    // layout shares this app's providers, its repository and its components,
    // and none of its chrome — a rail is not a narrow sidebar and a header
    // that scrolls away is not a toolbar, so expressing one as the other would
    // be a worse description of both.
    if (context.isMac) return const MacInboxShell();

    final repository = ref.watch(chatRepositoryProvider);
    // Not used here — *held* here: the scheduler's timer only runs while
    // something watches it, and the shell is alive as long as the app is.
    ref.watch(messageSchedulerProvider);
    // Same shape: keeps address-book names applied while the app shows chats.
    ref.watch(contactNamesSyncProvider);
    final filter = ref.watch(networkFilterProvider);
    final unread = ref.watch(unreadByNetworkProvider);
    final selectedChatId = ref.watch(selectedChatProvider);

    final wide = MediaQuery.sizeOf(context).width >= kTwoPaneBreakpoint;

    // Ordered rather than reading order, which is what the default policy
    // gives: reading order is derived from where things are on screen, so it
    // flips with the text direction and would put the detail pane before the
    // inbox under Arabic. Rail, then list, then detail is the order the panes
    // *mean*, in any direction — and each pane is its own group, so Tab walks
    // one to the end before entering the next instead of zig-zagging between
    // them.
    return Scaffold(
      // On a phone the whole window is the inbox and the FAB floats over it;
      // in two-pane layouts it would land on the chat pane's composer, so
      // there it lives inside the inbox pane instead (see below).
      floatingActionButton: wide
          ? null
          : Consumer(
              builder: (context, ref, _) => FloatingActionButton(
                tooltip: 'New chat',
                onPressed: () => showNewChatSheet(context, ref),
                child: const Icon(Icons.edit_rounded),
              ),
            ),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Row(
          children: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(1),
              child: FocusTraversalGroup(
                child: NetworkRail(
                  networks: repository.availableNetworks,
                  selected: filter,
                  unreadByNetwork: unread,
                  onToggle: (n) =>
                      ref.read(networkFilterProvider.notifier).toggle(n),
                  onShowAll: () =>
                      ref.read(networkFilterProvider.notifier).clear(),
                ),
              ),
            ),
            Expanded(
              flex: wide ? 2 : 1,
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: FocusTraversalGroup(
                  child: wide
                      ? Stack(
                          children: [
                            const _InboxPane(),
                            PositionedDirectional(
                              end: WeftSpace.lg,
                              bottom: WeftSpace.lg,
                              child: Consumer(
                                builder: (context, ref, _) =>
                                    FloatingActionButton(
                                      tooltip: 'New chat',
                                      onPressed: () =>
                                          showNewChatSheet(context, ref),
                                      child: const Icon(Icons.edit_rounded),
                                    ),
                              ),
                            ),
                          ],
                        )
                      : const _InboxPane(),
                ),
              ),
            ),
            if (wide) ...[
              VerticalDivider(width: 1, color: context.palette.border),
              Expanded(
                flex: 3,
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(3),
                  child: FocusTraversalGroup(
                    child: selectedChatId == null
                        ? const _EmptyDetail()
                        : ChatView(chatId: selectedChatId),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InboxPane extends ConsumerWidget {
  const _InboxPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(visibleChatsProvider);
    final filter = ref.watch(networkFilterProvider);
    final selectedChatId = ref.watch(selectedChatProvider);
    final mediaHeaders = ref.watch(mediaHeadersProvider);
    final wide = MediaQuery.sizeOf(context).width >= kTwoPaneBreakpoint;

    final selection = ref.watch(chatSelectionProvider);
    final selecting = ref.read(chatSelectionProvider.notifier).isActive;

    // The rail handles its own insets and should keep painting behind the
    // status bar; only the inbox column must start below it — and the edge the
    // rail is on is the window's *starting* edge, which is the physical right
    // one in an RTL window. `SafeArea` takes physical edges only, so this is
    // one of the two places in the app where the direction is read rather than
    // expressed.
    final rtl = Directionality.of(context) == TextDirection.rtl;

    return SafeArea(
      left: rtl,
      right: !rtl,
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The action bar replaces the header rather than stacking under it,
          // so the row of destructive actions is never off screen.
          if (selecting) InboxSelectionBar(selected: selection, visible: chats),
          Expanded(
            // One scroll surface for everything above the chats too: the
            // title, the stories and the filter rows ride away with the list
            // (they were a fixed third of a phone's height), while search
            // floats back in with the first downward gesture.
            child: CustomScrollView(
              slivers: [
                if (!selecting) ...[
                  SliverToBoxAdapter(child: _InboxHeader(activeFilter: filter)),
                  SliverAppBar(
                    floating: true,
                    snap: true,
                    automaticallyImplyLeading: false,
                    backgroundColor: context.colors.surface,
                    surfaceTintColor: Colors.transparent,
                    titleSpacing: WeftSpace.lg,
                    title: const _SearchField(),
                  ),
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(top: WeftSpace.md),
                      child: StatusBar(),
                    ),
                  ),
                  SliverToBoxAdapter(child: _FilterRows(activeFilter: filter)),
                ],
                if (chats.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyInbox(),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsetsDirectional.only(
                      bottom: WeftSpace.xl,
                    ),
                    sliver: SliverList.builder(
                      itemCount: chats.length,
                      itemBuilder: (context, i) {
                        final chat = chats[i];
                        final picked = selection.contains(chat.id);
                        return _StaggeredIn(
                          index: i,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onSecondaryTapUp: _isDesktopPointer
                                ? (details) => unawaited(
                                    showChatContextMenu(
                                      context,
                                      ref,
                                      chat,
                                      details.globalPosition,
                                    ),
                                  )
                                : null,
                            child: ChatTile(
                              chat: chat,
                              avatarHeaders: mediaHeaders,
                              typing: ref
                                  .read(chatRepositoryProvider)
                                  .typingIn(chat.id)
                                  .isNotEmpty,
                              online:
                                  ref
                                      .read(chatRepositoryProvider)
                                      .presenceFor(chat.id)
                                      ?.online ??
                                  false,
                              selected:
                                  picked || (wide && chat.id == selectedChatId),
                              // The tick's state has to reach the row's merged
                              // node: the `Checkbox` below is inside it and
                              // therefore silent, which is an improvement on
                              // announcing "checkbox" with no conversation name.
                              checked: selecting ? picked : null,
                              leading: selecting
                                  ? Checkbox(
                                      value: picked,
                                      onChanged: (_) => ref
                                          .read(chatSelectionProvider.notifier)
                                          .toggle(chat.id),
                                    )
                                  : null,
                              // Hold to look, not to select. Reading a chat
                              // marks it read, and holding was the only
                              // gesture free to answer "who was that?"
                              // without spending the unread marker; picking
                              // several conversations is a rarer thing and now
                              // has a button of its own in the inbox menu.
                              onLongPress: selecting
                                  ? () => ref
                                        .read(chatSelectionProvider.notifier)
                                        .toggle(chat.id)
                                  : () => unawaited(
                                      showChatPreview(context, chat.id),
                                    ),
                              timeLabel: formatInboxTime(
                                chat.lastMessage?.timestamp,
                                now: ref.watch(clockProvider)(),
                              ),
                              onTap: () {
                                // While selecting, a tap toggles rather than opens
                                // — otherwise the mode is a trap you fall out of.
                                if (selecting) {
                                  ref
                                      .read(chatSelectionProvider.notifier)
                                      .toggle(chat.id);
                                  return;
                                }
                                ref
                                    .read(selectedChatProvider.notifier)
                                    .select(chat.id);
                                ref
                                    .read(chatRepositoryProvider)
                                    .markRead(chat.id);
                                if (!wide) {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => ChatView(chatId: chat.id),
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bulk actions for the selected chats.
class InboxSelectionBar extends ConsumerWidget {
  const InboxSelectionBar({
    super.key,
    required this.selected,
    required this.visible,
  });

  final Set<String> selected;
  final List<Chat> visible;

  Future<void> _apply(
    WidgetRef ref,
    Future<void> Function(String chatId) action,
  ) async {
    for (final id in selected) {
      await action(id);
    }
    ref.read(chatSelectionProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.read(chatRepositoryProvider);
    final archived = ref.watch(showArchivedProvider);
    final allSelected = selected.length == visible.length;

    return Material(
      color: context.colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.sm,
          vertical: WeftSpace.xs,
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => ref.read(chatSelectionProvider.notifier).clear(),
            ),
            Text(
              '${selected.length}',
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            // Seven actions no longer fit a phone across; the row scrolls
            // from its end so the count stays put and Delete — the one worth
            // being careful with — is where the thumb starts.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: allSelected ? 'Select none' : 'Select all',
                      icon: Icon(
                        allSelected
                            ? Icons.deselect_rounded
                            : Icons.select_all_rounded,
                      ),
                      onPressed: () {
                        final notifier = ref.read(
                          chatSelectionProvider.notifier,
                        );
                        if (allSelected) {
                          notifier.clear();
                        } else {
                          notifier.selectAll(visible.map((c) => c.id));
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Mark read',
                      icon: const Icon(Icons.mark_email_read_outlined),
                      onPressed: () => _apply(ref, repository.markRead),
                    ),
                    IconButton(
                      tooltip: 'Mark unread',
                      icon: const Icon(Icons.mark_email_unread_outlined),
                      onPressed: () => _apply(ref, repository.markUnread),
                    ),
                    // One toggle, read off the selection: with every
                    // selected chat already muted the same button unmutes —
                    // there used to be no way back at all from here.
                    Builder(
                      builder: (context) {
                        final chosen = visible
                            .where((c) => selected.contains(c.id))
                            .toList();
                        final allMuted =
                            chosen.isNotEmpty && chosen.every((c) => c.muted);
                        return IconButton(
                          tooltip: allMuted ? 'Unmute' : 'Mute',
                          icon: Icon(
                            allMuted
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                          ),
                          onPressed: () => _apply(
                            ref,
                            (id) => repository.setMuted(id, muted: !allMuted),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Label',
                      icon: const Icon(Icons.label_outline_rounded),
                      onPressed: () async {
                        final label = await showLabelSheet(
                          context,
                          ref,
                          selected,
                        );
                        if (label != null) {
                          ref
                              .read(chatLabelsProvider.notifier)
                              .toggle(selected, label);
                          ref.read(chatSelectionProvider.notifier).clear();
                        }
                      },
                    ),
                    IconButton(
                      tooltip: archived ? 'Unarchive' : 'Archive',
                      icon: Icon(
                        archived
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                      ),
                      onPressed: () => _apply(
                        ref,
                        (id) => repository.setArchived(id, archived: !archived),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Leave and delete',
                      icon: Icon(
                        Icons.delete_outline,
                        color: context.colors.error,
                      ),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(
                              'Delete ${selected.length} conversation(s)?',
                            ),
                            content: const Text(
                              'This leaves and forgets the rooms. The history is gone '
                              'from this account and cannot be recovered here. '
                              'Archiving hides a chat without losing anything.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: context.colors.error,
                                ),
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed ?? false) {
                          await _apply(ref, repository.deleteChat);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxHeader extends ConsumerWidget {
  const _InboxHeader({required this.activeFilter});

  final Set<ChatNetwork> activeFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.lg,
        WeftSpace.lg,
        WeftSpace.md,
        WeftSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  activeFilter.isEmpty
                      ? 'Conversations'
                      : activeFilter.map((n) => n.label).join(' · '),
                  style: context.text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Appearance',
                icon: const Icon(Icons.palette_outlined),
                onPressed: () => showAppearanceSheet(context),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (choice) {
                  final navigator = Navigator.of(context);
                  switch (choice) {
                    case 'select':
                      ref.read(chatSelectionProvider.notifier).begin();
                    case 'read_all':
                      final repository = ref.read(chatRepositoryProvider);
                      final unread = ref
                          .read(visibleChatsProvider)
                          .where((c) => c.unreadCount > 0);
                      for (final chat in unread) {
                        unawaited(repository.markRead(chat.id));
                      }
                    case 'archived':
                      ref.read(showArchivedProvider.notifier).toggle();
                    case 'merge':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MergeScreen(),
                        ),
                      );
                    case 'bridges':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const BridgesScreen(),
                        ),
                      );
                    case 'settings':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                  }
                },
                // Four entries: the three things you do *to the inbox*, and
                // the door to everything else. Eleven destinations used to
                // live here, with "Devices" between "Show archived" and
                // "Keyboard shortcuts" — configuration now has a screen of
                // its own with room to be grouped and explained.
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'select',
                    child: Text('Select conversations'),
                  ),
                  const PopupMenuItem(
                    value: 'read_all',
                    child: Text('Mark all as read'),
                  ),
                  PopupMenuItem(
                    value: 'archived',
                    // The one entry in this menu that is a *state* rather than
                    // a destination. Its label changes between two sentences
                    // and nothing said which of them was currently true, so a
                    // reader could not tell "you are looking at archived chats"
                    // from "you can look at archived chats".
                    child: Semantics(
                      checked: ref.watch(showArchivedProvider),
                      child: Text(
                        ref.watch(showArchivedProvider)
                            ? 'Show active chats'
                            : 'Show archived',
                      ),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'merge',
                    child: Text('Merged chats'),
                  ),
                  const PopupMenuItem(value: 'bridges', child: Text('Bridges')),
                  const PopupMenuItem(
                    value: 'settings',
                    child: Text('Settings'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Everything that narrows the list, in one scrolling strip: labels, the
/// quick filters, and the way out of a network filter. Lives under the search
/// bar and scrolls away with the list, so on a phone the conversations own
/// the screen the moment the reader moves.
class _FilterRows extends ConsumerWidget {
  const _FilterRows({required this.activeFilter});

  final Set<ChatNetwork> activeFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quick = ref.watch(inboxQuickFilterProvider);

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.lg,
        0,
        WeftSpace.md,
        WeftSpace.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (value, label) in const [
                  (InboxQuickFilter.unread, 'Unread'),
                  (InboxQuickFilter.groups, 'Groups'),
                  (InboxQuickFilter.people, 'People'),
                ]) ...[
                  FilterChip(
                    label: Text(label),
                    selected: quick == value,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => ref
                        .read(inboxQuickFilterProvider.notifier)
                        .toggle(value),
                  ),
                  const SizedBox(width: WeftSpace.sm),
                ],
                if (activeFilter.isNotEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Clear network filter'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        ref.read(networkFilterProvider.notifier).clear(),
                  ),
              ],
            ),
          ),
          const _LabelFilterRow(),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context) {
    // A tap-through rather than an inline field: search deserves its own
    // screen, with filters and result provenance.
    //
    // Which is exactly why it must not *announce* itself as a text field. An
    // `InputDecorator` is a field's clothing with no field inside it, so a
    // reader was told to type somewhere that cannot take typing. It is a
    // button, and what it does is open a screen.
    void open() => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));

    // `WeftFocusable` rather than a bare `Semantics`, because excluding the
    // subtree — which is what removes the phantom text field — takes the
    // `InkWell`'s *focus* semantics with it as well as its tap. Tab still
    // stopped here and the node it stopped on had no name, so the one control
    // between the rail and the list was a silent stop on the way past. The
    // shared widget carries the label, the focus node, the ring and
    // Enter/Space together, which is the point of it.
    return WeftFocusable(
      onTap: open,
      label: 'Search all conversations',
      borderRadius: WeftRadius.allMd,
      child: Tooltip(
        message: 'Search all conversations',
        excludeFromSemantics: true,
        child: InkWell(
          borderRadius: WeftRadius.allMd,
          // The ripple stays; the focus does not. Two focusables over the same
          // box would be two Tab stops on one control, and the ring belongs to
          // the one that carries the name.
          canRequestFocus: false,
          onTap: open,
          child: InputDecorator(
            decoration: const InputDecoration(
              hintText: 'Search all conversations',
              prefixIcon: Icon(Icons.search_rounded, size: 20),
            ),
            // Without this the hint is never painted: `isEmpty` defaults to
            // false, which tells the decorator the field it is dressing has
            // content, and a hint over content would be unreadable. There is no
            // field and no content, so the box drew a magnifier and nothing
            // else — the placeholder was in the tree at zero opacity, which is
            // why the contrast sweep found a run of 16dp text at 1:1.
            isEmpty: true,
            child: const SizedBox(height: 20),
          ),
        ),
      ),
    );
  }
}

/// Fades and lifts list items in, capped so a long inbox doesn't take a second
/// to finish assembling.
class _StaggeredIn extends StatelessWidget {
  const _StaggeredIn({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // `context.motion`, not `WeftMotion`: the constants are the design
    // durations and this is the app's single most motion-y list. Under
    // `MediaQuery.disableAnimations` every duration below collapses to zero, so
    // the inbox appears rather than marching in — which is what the setting is
    // asking for.
    final motion = context.motion;
    final delay = motion.stagger * (index.clamp(0, 12));
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: motion.normal + delay,
      curve: motion.enter,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) {
    // One node, not three. An empty state is a single sentence — a heading, a
    // reason and a way out — and reading it as an unlabelled glyph followed by
    // two unrelated fragments is how "there is nothing here" becomes "there is
    // something wrong here".
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.xl),
        child: MergeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Icon(
                  Icons.filter_alt_off_rounded,
                  size: 40,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: WeftSpace.md),
              Text(
                'Nothing on these networks',
                style: context.text.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: WeftSpace.xs),
              Text(
                'Clear the rail filter to see every conversation.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colors.surfaceContainerLowest,
      child: Center(
        child: MergeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The mark is decoration in the strictest sense: it repeats the
              // words underneath it and adds nothing a reader could act on.
              ExcludeSemantics(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: WeftRadius.allXl,
                    gradient: LinearGradient(
                      // Directional so the sheen runs from the mark's leading
                      // corner in either direction. Cosmetic, but a gradient
                      // that lights the wrong corner is the sort of thing that
                      // makes a mirrored screen look subtly assembled wrong.
                      begin: AlignmentDirectional.topStart,
                      end: AlignmentDirectional.bottomEnd,
                      colors: [context.colors.primary, context.colors.tertiary],
                    ),
                  ),
                  child: Icon(
                    Icons.forum_rounded,
                    color: context.colors.onPrimary,
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(height: WeftSpace.lg),
              Text('Pick a conversation', style: context.text.titleMedium),
              const SizedBox(height: WeftSpace.xs),
              Text(
                'Every network, one thread.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The label chips under the search field — drawn only once labels exist.
///
/// Single-select, like the rail in its default mode: a label answers "which
/// slice of my life", and slices of a life rarely intersect on purpose.
class _LabelFilterRow extends ConsumerWidget {
  const _LabelFilterRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatLabelsProvider);
    final labels = ref.read(chatLabelsProvider.notifier).all;
    if (labels.isEmpty) return const SizedBox.shrink();
    final selected = ref.watch(labelFilterProvider);

    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final label in labels) ...[
              FilterChip(
                label: Text(label),
                selected: selected == label,
                visualDensity: VisualDensity.compact,
                onSelected: (_) =>
                    ref.read(labelFilterProvider.notifier).select(label),
              ),
              const SizedBox(width: WeftSpace.sm),
            ],
          ],
        ),
      ),
    );
  }
}
