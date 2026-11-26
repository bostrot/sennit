import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat, Intl;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/draft_providers.dart';
import '../../app/labels.dart';
import '../../app/localisation.dart';
import '../../services/contacts/device_contacts.dart';
import '../../services/schedule/scheduled_actions.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../app/shortcuts.dart';
import '../bridges/bridges_screen.dart';
import '../chat/chat_preview.dart';
import '../chat/chat_view.dart';
import '../merge/merge_screen.dart';
import '../todo/todo_screen.dart';
import '../status/status_bar.dart';
import 'label_sheet.dart';
import 'mac_shell.dart';
import 'new_chat_sheet.dart';
import 'requests_screen.dart';
import '../search/search_screen.dart';
import '../settings/appearance_sheet.dart';
import '../settings/sennit_web_screen.dart' show SennitWebIndicator;
import '../settings/settings_screen.dart';

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
  // The menu's words, in the reader's language: these seven were English
  // literals, in an app that is otherwise translated into six.
  final l10n = context.l10n;

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
      item('peek', Icons.visibility_outlined, l10n.inboxMenuPeek),
      if (chat.unreadCount > 0)
        item('read', Icons.mark_email_read_outlined, l10n.inboxMarkRead)
      else
        item('unread', Icons.mark_email_unread_outlined, l10n.inboxMarkUnread),
      if (chat.muted)
        item('unmute', Icons.notifications_active_outlined, l10n.commonUnmute)
      else
        item('mute', Icons.notifications_off_outlined, l10n.commonMute),
      if (chat.archived)
        item('unarchive', Icons.unarchive_outlined, l10n.inboxUnarchive)
      else
        item('archive', Icons.archive_outlined, l10n.inboxArchive),
      item('label', Icons.label_outline_rounded, l10n.inboxMenuLabels),
      item(
        'select',
        Icons.check_circle_outline_rounded,
        l10n.inboxMenuSelectChat,
      ),
      item(
        'delete',
        Icons.delete_outline_rounded,
        l10n.commonDelete,
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
          title: Text(dialog.l10n.inboxDeleteChatTitle(chat.title)),
          content: Text(dialog.l10n.inboxDeleteChatBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(dialog.l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialog).colorScheme.error,
              ),
              child: Text(dialog.l10n.commonDelete),
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
String? formatInboxTime(
  DateTime? ts, {
  required DateTime now,
  required String justNow,
}) {
  if (ts == null) return null;
  final delta = now.difference(ts);
  if (delta.inMinutes < 1) return justNow;
  final formats = _InboxTimeFormats.current();
  if (delta.inHours < 24) return formats.clock.format(ts);
  if (delta.inDays < 7) return formats.weekday.format(ts);
  return formats.date.format(ts);
}

/// The three formatters [formatInboxTime] chooses between, built once per
/// locale rather than once per row per frame.
///
/// A `DateFormat` parses its pattern and looks up its locale's symbols when
/// it is constructed, and the label is asked for by every visible row on
/// every rebuild. Keyed on `Intl`'s current locale, which is the one a bare
/// `DateFormat.Hm()` would have read, so switching language still reformats.
class _InboxTimeFormats {
  _InboxTimeFormats._(this.locale)
    : clock = DateFormat.Hm(),
      weekday = DateFormat.E(),
      date = DateFormat.yMd();

  final String locale;
  final DateFormat clock;
  final DateFormat weekday;
  final DateFormat date;

  static _InboxTimeFormats? _cached;

  static _InboxTimeFormats current() {
    final locale = Intl.getCurrentLocale();
    final cached = _cached;
    if (cached != null && cached.locale == locale) return cached;
    return _cached = _InboxTimeFormats._(locale);
  }
}

/// Remembers the widget built for each conversation's row.
///
/// Flutter skips a subtree whose widget is the *same object* it already has,
/// and only then. A list rebuilt because one conversation moved hands every
/// visible row a new widget — equal in every field, but new — and so rebuilds
/// all of them: a dozen rows of a hundred widgets each, for one changed badge.
/// Handing back the widget from last time, when nothing it was built from has
/// changed, is what makes the list's rebuild cost the rows that differ.
///
/// [inputs] is everything the row is built from besides the chat — a record,
/// so it compares by value. Anything the builder closes over must be in it or
/// be stable for the life of the list, and must not be the row's own
/// `BuildContext`: the widget is reused after that element is gone. Its
/// position is deliberately not an input — see [indexOf].
class ChatRowMemo {
  final Map<String, (Chat, Object, Widget)> _rows = {};

  /// Where the row keyed [key] is in [chats] now, for a list's
  /// `findChildIndexCallback`. Rows are keyed `ValueKey(chat.id)`.
  int? indexOf(Key key, List<Chat> chats, {int offset = 0}) {
    if (key is! ValueKey<String>) return null;
    if (!identical(chats, _indexedChats)) {
      _indexedChats = chats;
      _indexById = {for (var i = 0; i < chats.length; i++) chats[i].id: i};
    }
    final index = _indexById[key.value];
    return index == null ? null : index + offset;
  }

  List<Chat>? _indexedChats;
  Map<String, int> _indexById = const {};

  Widget row(Chat chat, Object inputs, Widget Function() build) {
    final cached = _rows[chat.id];
    if (cached != null &&
        cached.$2 == inputs &&
        cached.$1.sameContentAs(chat)) {
      return cached.$3;
    }
    // Bounded by forgetting everything now and then rather than by tracking
    // use: a row that is asked for again is rebuilt once, which is what
    // happened on every build before there was a memo at all.
    if (_rows.length > 400) _rows.clear();
    final built = build();
    _rows[chat.id] = (chat, inputs, built);
    return built;
  }
}

/// An inbox row that keeps *itself* current.
///
/// Three things on a row change without the conversation changing: whether
/// someone in it is typing, whether its person is online, and what "12:04"
/// has become now that a minute has passed. None of them is in the [Chat], so
/// the list used to pick them up the only way it could — by rebuilding every
/// visible row after every sync. This asks the same three questions on the
/// same heartbeat, one row at a time, and rebuilds the row whose answer moved.
class LiveChatTile extends ConsumerWidget {
  const LiveChatTile({
    super.key,
    required this.chat,
    required this.onTap,
    this.selected = false,
    this.onLongPress,
    this.avatarHeaders,
    this.leading,
    this.checked,
  });

  final Chat chat;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final Map<String, String>? avatarHeaders;
  final Widget? leading;
  final bool? checked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final justNow = context.l10n.inboxTimeNow;
    final now = ref.watch(clockProvider);
    // Selected *off* the chat list so it is re-asked whenever the repository
    // has synced; the list itself is not what is being read.
    final (typing, online, timeLabel) = ref.watch(
      chatsProvider.select((_) {
        final repository = ref.read(chatRepositoryProvider);
        return (
          repository.typingIn(chat.id).isNotEmpty,
          repository.presenceFor(chat.id)?.online ?? false,
          formatInboxTime(
            chat.lastMessage?.timestamp,
            now: now(),
            justNow: justNow,
          ),
        );
      }),
    );
    final draft = ref.watch(draftsProvider.select((d) => d[chat.id]));
    return ChatTile(
      chat: chat,
      avatarHeaders: avatarHeaders,
      typing: typing,
      draft: draft,
      online: online,
      selected: selected,
      checked: checked,
      leading: leading,
      onLongPress: onLongPress,
      timeLabel: timeLabel,
      onTap: onTap,
    );
  }
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

    // Not used here — *held* here: the scheduler's timer only runs while
    // something watches it, and the shell is alive as long as the app is.
    ref.watch(messageSchedulerProvider);
    // Same shape: keeps address-book names applied while the app shows chats.
    ref.watch(contactNamesSyncProvider);
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
                tooltip: context.l10n.inboxNewChatTooltip,
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
                // The rail watches for itself. Its badges move with every
                // message that arrives anywhere, and read from this build
                // they took the whole shell — on a two-pane window, the open
                // conversation included — round with them.
                child: Consumer(
                  builder: (context, ref, _) => NetworkRail(
                    networks: ref.watch(availableNetworksProvider),
                    selected: ref.watch(networkFilterProvider),
                    unreadByNetwork: ref.watch(unreadByNetworkProvider),
                    onToggle: (n) =>
                        ref.read(networkFilterProvider.notifier).toggle(n),
                    onShowAll: () =>
                        ref.read(networkFilterProvider.notifier).clear(),
                  ),
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
                                      tooltip: context.l10n.inboxNewChatTooltip,
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
              VerticalDivider(width: 1, color: context.palette.divider),
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

class _InboxPane extends ConsumerStatefulWidget {
  const _InboxPane();

  @override
  ConsumerState<_InboxPane> createState() => _InboxPaneState();
}

class _InboxPaneState extends ConsumerState<_InboxPane> {
  final _rows = ChatRowMemo();

  @override
  Widget build(BuildContext context) {
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
            child: _InboxEntrance(
              child: CustomScrollView(
                slivers: [
                  if (!selecting) ...[
                    SliverToBoxAdapter(
                      child: _InboxHeader(activeFilter: filter),
                    ),
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
                    SliverToBoxAdapter(
                      child: _FilterRows(activeFilter: filter),
                    ),
                    // Under the filters and above the conversations, so it is
                    // the first row of the list rather than a fifth thing in the
                    // header — and so a request cannot be filtered away by a
                    // rail selection the user made for another purpose.
                    const SliverToBoxAdapter(child: RequestsEntry()),
                  ],
                  if (chats.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyInbox(),
                    )
                  else
                    SliverPadding(
                      // Both layouts, because both float a compose button over
                      // this list: one pane hands it to `Scaffold` above, two
                      // panes position it into the pane's own `Stack` at the same
                      // 16pt inset. The second is easy to miss precisely because
                      // it is not in the `floatingActionButton` slot — and it
                      // covers the last conversation just as completely.
                      padding: const EdgeInsetsDirectional.only(
                        bottom: WeftSpace.fabClearance,
                      ),
                      sliver: SliverList.builder(
                        itemCount: chats.length,
                        // Rows are keyed by conversation and found by it, so
                        // one that moves — a message arrives and its chat
                        // jumps to the top — takes its element with it.
                        // Without this the list matches rows by position, and
                        // every row the jump displaced is handed another
                        // conversation's widget and rebuilt from scratch.
                        findChildIndexCallback: (key) =>
                            _rows.indexOf(key, chats),
                        // The row's own context is deliberately not used
                        // below: a remembered row outlives the element that
                        // first built it, and its callbacks must not.
                        itemBuilder: (_, i) {
                          final chat = chats[i];
                          final picked = selection.contains(chat.id);
                          final selected =
                              picked || (wide && chat.id == selectedChatId);
                          return _rows.row(
                            chat,
                            (picked, selected, selecting, wide, mediaHeaders),
                            () => _StaggeredIn(
                              key: ValueKey(chat.id),
                              index: i,
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                // Silent to a screen reader, for the reason
                                // `mac_shell.dart` gives: a right-click-only
                                // detector exports an unnamed tappable node the
                                // size of the row, over the named one.
                                excludeFromSemantics: true,
                                onSecondaryTapUp: context.hasPointer
                                    ? (details) => unawaited(
                                        showChatContextMenu(
                                          context,
                                          ref,
                                          chat,
                                          details.globalPosition,
                                        ),
                                      )
                                    : null,
                                child: LiveChatTile(
                                  chat: chat,
                                  avatarHeaders: mediaHeaders,
                                  selected: selected,
                                  // The tick's state has to reach the row's merged
                                  // node: the `Checkbox` below is inside it and
                                  // therefore silent, which is an improvement on
                                  // announcing "checkbox" with no conversation name.
                                  checked: selecting ? picked : null,
                                  leading: selecting
                                      ? Checkbox(
                                          value: picked,
                                          onChanged: (_) => ref
                                              .read(
                                                chatSelectionProvider.notifier,
                                              )
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
                                            .read(
                                              chatSelectionProvider.notifier,
                                            )
                                            .toggle(chat.id)
                                      : () => unawaited(
                                          showChatPreview(context, chat.id),
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
                                      unawaited(
                                        pushChat(
                                          Navigator.of(context),
                                          chat.id,
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
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
    final l10n = context.l10n;
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
              tooltip: l10n.commonCancel,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => ref.read(chatSelectionProvider.notifier).clear(),
            ),
            Text(
              l10n.inboxSelectedCount(selected.length),
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
                      tooltip: allSelected
                          ? l10n.inboxSelectNone
                          : l10n.inboxSelectAll,
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
                      tooltip: l10n.inboxMarkRead,
                      icon: const Icon(Icons.mark_email_read_outlined),
                      onPressed: () => _apply(ref, repository.markRead),
                    ),
                    IconButton(
                      tooltip: l10n.inboxMarkUnread,
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
                          tooltip: allMuted
                              ? l10n.commonUnmute
                              : l10n.commonMute,
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
                      tooltip: l10n.inboxLabelTooltip,
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
                      tooltip: archived
                          ? l10n.inboxUnarchive
                          : l10n.inboxArchive,
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
                      tooltip: l10n.inboxLeaveAndDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        color: context.colors.error,
                      ),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(
                              l10n.inboxDeleteManyTitle(selected.length),
                            ),
                            content: Text(l10n.inboxDeleteManyBody),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: Text(l10n.commonCancel),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: context.colors.error,
                                ),
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: Text(l10n.commonDelete),
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
                      ? context.l10n.inboxTitleConversations
                      : activeFilter.map((n) => n.label).join(' · '),
                  style: context.text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // The inbox draws from the local database the moment the app
              // opens; until the first sync of this run lands, what it shows
              // is last run's state. This is the only thing that says so.
              if (ref.watch(catchingUpProvider).value ?? false)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: WeftSpace.sm),
                  child: Text(
                    context.l10n.inboxCatchingUp,
                    style: context.text.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              const SennitWebIndicator(),
              IconButton(
                tooltip: context.l10n.commonAppearance,
                icon: const Icon(Icons.palette_outlined),
                onPressed: () => showAppearanceSheet(context),
              ),
              PopupMenuButton<String>(
                tooltip: context.l10n.commonMore,
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
                    case 'todo':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const TodoScreen(),
                        ),
                      );
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
                  PopupMenuItem(
                    value: 'select',
                    child: Text(context.l10n.inboxMenuSelect),
                  ),
                  PopupMenuItem(
                    value: 'read_all',
                    child: Text(context.l10n.inboxMenuMarkAllRead),
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
                            ? context.l10n.inboxMenuShowActive
                            : context.l10n.inboxMenuShowArchived,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'todo',
                    child: Text(context.l10n.todoTitle),
                  ),
                  PopupMenuItem(
                    value: 'merge',
                    child: Text(context.l10n.commonMergedChats),
                  ),
                  PopupMenuItem(
                    value: 'bridges',
                    child: Text(context.l10n.commonBridges),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    child: Text(context.l10n.commonSettings),
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
    final archived = ref.watch(showArchivedProvider);

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
                for (final (value, label) in [
                  (InboxQuickFilter.unread, context.l10n.inboxFilterUnread),
                  (InboxQuickFilter.groups, context.l10n.inboxFilterGroups),
                  (InboxQuickFilter.people, context.l10n.inboxFilterPeople),
                  (
                    InboxQuickFilter.needsReply,
                    context.l10n.inboxFilterNeedsReply,
                  ),
                  (InboxQuickFilter.drafts, context.l10n.inboxFilterDrafts),
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
                // Composes with the networks picked in the header, so the
                // archive of one network is two taps away.
                FilterChip(
                  avatar: const Icon(Icons.archive_outlined, size: 16),
                  label: Text(context.l10n.inboxFilterArchived),
                  selected: archived,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) =>
                      ref.read(showArchivedProvider.notifier).toggle(),
                ),
                const SizedBox(width: WeftSpace.sm),
                if (activeFilter.isNotEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.close_rounded, size: 16),
                    label: Text(context.l10n.inboxClearNetworkFilter),
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
      label: context.l10n.inboxSearchAll,
      borderRadius: WeftRadius.allMd,
      child: Tooltip(
        message: context.l10n.inboxSearchAll,
        excludeFromSemantics: true,
        child: InkWell(
          borderRadius: WeftRadius.allMd,
          // The ripple stays; the focus does not. Two focusables over the same
          // box would be two Tab stops on one control, and the ring belongs to
          // the one that carries the name.
          canRequestFocus: false,
          onTap: open,
          child: InputDecorator(
            decoration: InputDecoration(
              hintText: context.l10n.inboxSearchAll,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
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

/// Fades and lifts a row into place as the inbox first appears.
///
/// *As the inbox appears*, and not after. The animation runs when a row's
/// element is created, and a lazy list creates one for every row that scrolls
/// into view — so every conversation below the fold used to arrive
/// transparent and twelve pixels low, on a 12-row delay, and spend a third of
/// a second drifting into place while the list was already moving under the
/// finger. That is a scroll that visibly lags its own content, and a
/// `saveLayer` per half-faded row per frame to draw it.
///
/// The rows built in the list's first moments march in as before; a row built
/// later simply is where it belongs.
class _StaggeredIn extends StatefulWidget {
  const _StaggeredIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_StaggeredIn> createState() => _StaggeredInState();
}

class _StaggeredInState extends State<_StaggeredIn> {
  /// Decided once, when the row is created, and never revisited: a row that
  /// arrived by scrolling must not start animating because the list rebuilt.
  late final bool _animate = _InboxEntrance.of(context)?.admit() ?? false;

  @override
  Widget build(BuildContext context) {
    if (!_animate) return widget.child;
    // `context.motion`, not `WeftMotion`: the constants are the design
    // durations and this is the app's single most motion-y list. Under
    // `MediaQuery.disableAnimations` every duration below collapses to zero, so
    // the inbox appears rather than marching in — which is what the setting is
    // asking for.
    final motion = context.motion;
    final delay = motion.stagger * (widget.index.clamp(0, 12));
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
      child: widget.child,
    );
  }
}

/// The window in which rows of the inbox below it animate in.
///
/// Opens when the first row is built and closes a moment later, which is long
/// enough to take in everything the first frame lays out and short enough
/// that nothing a scroll reveals is inside it.
class _InboxEntrance extends StatefulWidget {
  const _InboxEntrance({required this.child});

  final Widget child;

  static _InboxEntranceState? of(BuildContext context) =>
      context.findAncestorStateOfType<_InboxEntranceState>();

  @override
  State<_InboxEntrance> createState() => _InboxEntranceState();
}

class _InboxEntranceState extends State<_InboxEntrance> {
  static const Duration _window = Duration(milliseconds: 120);

  Timer? _closing;
  bool _closed = false;

  /// Whether a row created now is part of the entrance.
  bool admit() {
    if (_closed) return false;
    _closing ??= Timer(_window, () => _closed = true);
    return true;
  }

  @override
  void dispose() {
    _closing?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
                context.l10n.inboxEmptyTitle,
                style: context.text.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: WeftSpace.xs),
              Text(
                context.l10n.inboxEmptyBody,
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
              Text(
                context.l10n.inboxEmptyDetailTitle,
                style: context.text.titleMedium,
              ),
              const SizedBox(height: WeftSpace.xs),
              Text(
                context.l10n.inboxEmptyDetailBody,
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
