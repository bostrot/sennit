import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft_domain/weft_domain.dart';

import '../../app/labels.dart';
import '../../app/localisation.dart';
import '../../app/menus.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../services/contacts/device_contacts.dart';
import '../../services/schedule/scheduled_actions.dart';
import '../bridges/bridges_screen.dart';
import '../chat/chat_preview.dart';
import '../chat/chat_view.dart';
import '../merge/merge_screen.dart';
import '../todo/todo_screen.dart';
import '../search/search_screen.dart';
import '../settings/appearance_sheet.dart';
import '../settings/settings_screen.dart';
import 'inbox_shell.dart';
import 'requests_screen.dart';
import 'new_chat_sheet.dart';

/// The sidebar and list widths to actually draw in a window [available] wide.
///
/// The dragged widths are what the reader asked for; these are what fits. The
/// conversation is the `Expanded` pane, so it absorbs every point the other two
/// take — and nothing used to stop them taking all of it. At the 720pt minimum
/// window `macos/Runner/MainFlutterWindow.swift` enforces, the default sidebar
/// and list left the thread 192 points: narrower than the conversation *list*
/// beside it is allowed to shrink to, and too narrow for a bubble to hold a
/// sentence. Found by the Phase 10 walkthrough's `desk-narrow` pass, which
/// photographs the window at exactly that minimum.
///
/// The sidebar gives way first and the list second, each down to its own
/// minimum and no further. That order is the order the panes lose their value:
/// the sidebar is a set of labelled destinations whose current selection the
/// list's own header already names, the list is how you move between
/// conversations, and the conversation is what the window is for. If even the
/// two minimums cannot leave [MacMetrics.detailMinWidth] — a window narrower
/// than macOS will give this app — the thread takes whatever is left rather
/// than a pane collapsing to a sliver.
///
/// Pure, and takes the dragged widths rather than reading them, so the squeeze
/// is a function of the window and not a mutation of the reader's choice:
/// widening the window again restores the widths they dragged to instead of the
/// ones the narrow moment left behind.
///
/// [sidebar] is 0 when it is hidden — View ▸ Hide Sidebar — in which case there
/// is nothing to take from it and the list absorbs the whole squeeze.
(double, double) macPaneWidths({
  required double available,
  required double sidebar,
  required double list,
}) {
  var excess = sidebar + list + MacMetrics.detailMinWidth - available;
  if (excess <= 0) return (sidebar, list);

  final fromSidebar = sidebar == 0
      ? 0.0
      : excess.clamp(0.0, sidebar - MacMetrics.sidebarMinWidth);
  excess -= fromSidebar;
  final fromList = excess.clamp(0.0, list - MacMetrics.listMinWidth);
  return (sidebar - fromSidebar, list - fromList);
}

/// Braid as a Mac window.
///
/// Three panes under one toolbar, which is the shape every desktop messenger
/// and mail client has converged on because it is the one that uses a window:
/// a source list you rarely touch, the conversations in whatever it selects,
/// and the thread. The phone's shell answers the same questions with a filter
/// rail, a scrolling header, a chip row and a floating button — all of them
/// answers to *not having room*, and all of them wrong here.
///
/// The panes are resizable and their widths persist for the session, because a
/// window whose proportions cannot be changed is the other half of looking like
/// a phone app.
class MacInboxShell extends ConsumerStatefulWidget {
  const MacInboxShell({super.key});

  @override
  ConsumerState<MacInboxShell> createState() => _MacInboxShellState();
}

class _MacInboxShellState extends ConsumerState<MacInboxShell> {
  /// The bulk-action bar's height, stated rather than measured.
  ///
  /// It rides with the toolbar over the list, and the list is padded down by
  /// exactly as much as the two of them take — which is a number the layout
  /// needs before either has been laid out.
  static const double _selectionBarHeight = 36;

  double _sidebarWidth = MacMetrics.sidebarWidth;
  double _listWidth = MacMetrics.listWidth;
  bool _networksExpanded = true;

  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Shows [chatId] without reading it, and opens it properly if asked.
  Future<void> _peek(String chatId) async {
    final open = await showChatPreview(context, chatId);
    if (open != true || !mounted) return;
    ref.read(selectedChatProvider.notifier).select(chatId);
  }

  void _openSearch([String? query]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialQuery: query ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Held here rather than used: the scheduler's timer only runs while
    // something watches it, and the shell is alive as long as the app is.
    ref.watch(messageSchedulerProvider);
    ref.watch(contactNamesSyncProvider);

    final selectedChatId = ref.watch(selectedChatProvider);
    // Owned by a provider rather than by this state, because View ▸ Hide
    // Sidebar is above the shell and has to reach it.
    final sidebarVisible = ref.watch(macSidebarVisibleProvider);

    final (sidebarWidth, listWidth) = macPaneWidths(
      available: MediaQuery.sizeOf(context).width,
      sidebar: sidebarVisible ? _sidebarWidth : 0,
      list: _listWidth,
    );

    return Scaffold(
      // The window's own background is painted by the panes, and the sidebar
      // deliberately does not paint one — that is what lets the desktop show
      // through it. A scaffold colour here would sit behind the glass and make
      // it glass over a wall.
      backgroundColor: Colors.transparent,
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Row(
          children: [
            if (sidebarVisible) ...[
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: FocusTraversalGroup(child: _sidebar(sidebarWidth)),
              ),
              _Splitter(
                onDrag: (delta) => setState(() {
                  _sidebarWidth = (_sidebarWidth + delta).clamp(
                    MacMetrics.sidebarMinWidth,
                    MacMetrics.sidebarMaxWidth,
                  );
                }),
              ),
            ],
            FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: FocusTraversalGroup(child: _list(listWidth)),
            ),
            _Splitter(
              onDrag: (delta) => setState(() {
                _listWidth = (_listWidth + delta).clamp(
                  MacMetrics.listMinWidth,
                  MacMetrics.listMaxWidth,
                );
              }),
            ),
            Expanded(
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(3),
                child: FocusTraversalGroup(
                  child: ColoredBox(
                    color: context.colors.surface,
                    child: selectedChatId == null
                        ? const _MacEmptyDetail()
                        : ChatView(chatId: selectedChatId),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- the sidebar

  Widget _sidebar(double width) {
    final repository = ref.watch(chatRepositoryProvider);
    final filter = ref.watch(networkFilterProvider);
    final unread = ref.watch(unreadByNetworkProvider);
    final quick = ref.watch(inboxQuickFilterProvider);
    final archived = ref.watch(showArchivedProvider);
    ref.watch(chatLabelsProvider);
    final labels = ref.read(chatLabelsProvider.notifier).all;
    final labelFilter = ref.watch(labelFilterProvider);

    // "All" is the absence of every narrowing, which is also what makes it the
    // way back: one click from any state.
    final nothingNarrowed =
        quick == null && !archived && filter.isEmpty && labelFilter == null;

    void clearAll() {
      if (quick != null) {
        ref.read(inboxQuickFilterProvider.notifier).toggle(quick);
      }
      ref.read(networkFilterProvider.notifier).clear();
      ref.read(labelFilterProvider.notifier).select(null);
      if (archived) ref.read(showArchivedProvider.notifier).toggle();
    }

    return MacSidebar(
      width: width,
      top: MacToolbar(
        // The only pane that carries it: the traffic lights are at the
        // window's starting edge, and this is the pane that is there.
        leadingInset: MacMetrics.trafficLightInset,
        titleWidget: const SizedBox.shrink(),
        actions: [
          // Wrapped so the button has a context of its own to be a popover's
          // anchor. The enclosing one is the whole toolbar, and a popover
          // hanging off the middle of a toolbar points at nothing.
          Builder(
            builder: (anchor) => MacToolbarButton(
              icon: Icons.palette_outlined,
              tooltip: context.l10n.commonAppearance,
              onPressed: () =>
                  showAppearanceSheet(context, anchorContext: anchor),
            ),
          ),
        ],
      ),
      children: [
        MacSidebarRow(
          icon: Icons.all_inbox_rounded,
          label: context.l10n.macSidebarAllConversations,
          selected: nothingNarrowed,
          badge: unread.values.fold<int>(0, (a, b) => a + b),
          onTap: clearAll,
        ),
        for (final (value, label, icon) in [
          (
            InboxQuickFilter.unread,
            context.l10n.inboxFilterUnread,
            Icons.mark_email_unread_outlined,
          ),
          (
            InboxQuickFilter.groups,
            context.l10n.inboxFilterGroups,
            Icons.groups_rounded,
          ),
          (
            InboxQuickFilter.people,
            context.l10n.inboxFilterPeople,
            Icons.person_rounded,
          ),
        ])
          MacSidebarRow(
            icon: icon,
            label: label,
            selected: quick == value && !archived,
            onTap: () {
              if (archived) ref.read(showArchivedProvider.notifier).toggle();
              ref.read(inboxQuickFilterProvider.notifier).toggle(value);
            },
          ),
        MacSidebarRow(
          icon: Icons.archive_outlined,
          label: context.l10n.macSidebarArchived,
          selected: archived,
          onTap: () => ref.read(showArchivedProvider.notifier).toggle(),
        ),
        MacSidebarSection(
          title: context.l10n.macSidebarNetworks,
          expanded: _networksExpanded,
          onToggle: () =>
              setState(() => _networksExpanded = !_networksExpanded),
          children: [
            for (final network in repository.availableNetworks)
              MacSidebarRow(
                leading: NetworkGlyph(network: network, size: 15),
                label: network.label,
                selected: filter.contains(network),
                badge: unread[network] ?? 0,
                semanticsLabel: switch (unread[network] ?? 0) {
                  0 => network.label,
                  final n => context.l10n.macSidebarNetworkUnread(
                    network.label,
                    n,
                  ),
                },
                onTap: () =>
                    ref.read(networkFilterProvider.notifier).toggle(network),
              ),
          ],
        ),
        if (labels.isNotEmpty)
          MacSidebarSection(
            title: context.l10n.macSidebarLabels,
            children: [
              for (final label in labels)
                MacSidebarRow(
                  icon: Icons.label_outline_rounded,
                  label: label,
                  selected: labelFilter == label,
                  onTap: () =>
                      ref.read(labelFilterProvider.notifier).select(label),
                ),
            ],
          ),
        const SizedBox(height: WeftSpace.md),
        // The destinations, at the bottom where a Mac keeps them —
        // below the content the sidebar is actually for, not mixed into it.
        MacSidebarRow(
          icon: Icons.checklist_rounded,
          label: context.l10n.todoTitle,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const TodoScreen())),
        ),
        MacSidebarRow(
          icon: Icons.merge_rounded,
          label: context.l10n.commonMergedChats,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const MergeScreen())),
        ),
        MacSidebarRow(
          icon: Icons.hub_outlined,
          label: context.l10n.commonBridges,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const BridgesScreen()),
          ),
        ),
        MacSidebarRow(
          icon: Icons.settings_outlined,
          label: context.l10n.commonSettings,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------- the conversation list

  Widget _list(double width) {
    final chats = ref.watch(visibleChatsProvider);
    final selectedChatId = ref.watch(selectedChatProvider);
    final mediaHeaders = ref.watch(mediaHeadersProvider);
    final selection = ref.watch(chatSelectionProvider);
    final selecting = ref.read(chatSelectionProvider.notifier).isActive;
    final quick = ref.watch(inboxQuickFilterProvider);
    final archived = ref.watch(showArchivedProvider);
    final networks = ref.watch(networkFilterProvider);

    final title = switch ((archived, quick, networks.isEmpty)) {
      (true, _, _) => context.l10n.macSidebarArchived,
      (_, InboxQuickFilter.unread, _) => context.l10n.inboxFilterUnread,
      (_, InboxQuickFilter.groups, _) => context.l10n.inboxFilterGroups,
      (_, InboxQuickFilter.people, _) => context.l10n.inboxFilterPeople,
      (_, _, false) => networks.map((n) => n.label).join(' · '),
      // Short on purpose. The pane is 300pt wide and shares its toolbar with a
      // search field and two buttons; "All conversations" truncates to "All
      // convers…", which reads worse than the word it was truncating to. The
      // sidebar says the long version, and the sidebar is right beside it.
      _ => context.l10n.macListTitleAll,
    };

    return SizedBox(
      width: width,
      child: ColoredBox(
        color: context.colors.surfaceContainerLowest,
        // Tahoe's scroll edge effect: the list runs *under* the toolbar and
        // shows through its glass, and the toolbar grows a hairline only once
        // something has passed beneath it. A toolbar that always has a
        // separator is the previous decade's window.
        child: MacScrollEdge(
          barHeight:
              MacMetrics.toolbarHeight + (selecting ? _selectionBarHeight : 0),
          bar: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _listToolbar(title),
              if (selecting)
                SizedBox(
                  height: _selectionBarHeight,
                  child: InboxSelectionBar(selected: selection, visible: chats),
                ),
            ],
          ),
          child: chats.isEmpty
              ? const _MacEmptyList()
              : _conversationList(
                  chats,
                  selectedChatId,
                  mediaHeaders,
                  selection,
                ),
        ),
      ),
    );
  }

  Widget _listToolbar(String title) => MacToolbar(
    leading: Consumer(
      builder: (context, ref, _) {
        final visible = ref.watch(macSidebarVisibleProvider);
        return MacToolbarButton(
          icon: visible ? Icons.menu_open_rounded : Icons.menu_rounded,
          tooltip: visible
              ? context.l10n.macHideSidebar
              : context.l10n.macShowSidebar,
          onPressed: () =>
              ref.read(macSidebarVisibleProvider.notifier).toggle(),
        );
      },
    ),
    titleWidget: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Consumer(
        builder: (context, ref, _) {
          // Same sentence as the phone header: until this run's first sync
          // lands, the list is last run's state, and nothing else says so.
          final catchingUp = ref.watch(catchingUpProvider).value ?? false;
          return Text(
            catchingUp ? context.l10n.inboxCatchingUp : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.titleSmall,
          );
        },
      ),
    ),
    actions: [
      MacSearchField(
        controller: _searchController,
        hintText: context.l10n.macSearchHint,
        width: 120,
        focusedWidth: 180,
        // Search has a screen of its own — filters, provenance,
        // every network at once — so the field hands the query to
        // it rather than pretending to filter the list in place.
        onSubmitted: _openSearch,
      ),
      const SizedBox(width: WeftSpace.xs),
      MacToolbarButton(
        icon: Icons.edit_square,
        tooltip: context.l10n.macNewConversation,
        onPressed: () => showNewChatSheet(context, ref),
      ),
    ],
  );

  Widget _conversationList(
    List<Chat> chats,
    String? selectedChatId,
    Map<String, String>? mediaHeaders,
    Set<String> selection,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: WeftSpace.xs),
    // The requests row rides at the top of the list rather than in the toolbar,
    // for the same reason it does on the touch shell: the one thing it has to
    // survive is being ignored, and a badge in the corner of a toolbar is
    // exactly what someone scanning their conversations does not see. It draws
    // nothing at all when nothing is waiting.
    itemCount: chats.length + 1,
    itemBuilder: (context, index) {
      if (index == 0) return const RequestsEntry();
      final i = index - 1;
      final chat = chats[i];
      final picked = selection.contains(chat.id);
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        // Silent to a screen reader. A `GestureDetector` that declares any tap
        // recogniser exports a tappable node, and a right-click-only one
        // exports it with nothing to say — an unnamed control the width of the
        // row, sitting over the named one. The route walk found ten of them on
        // the Mac inbox and nine more in a conversation. The menu itself loses
        // nothing: every verb in it is reachable from the row's own actions,
        // and a pointer is the only thing that can raise it.
        excludeFromSemantics: true,
        onSecondaryTapUp: (details) => unawaited(
          showChatContextMenu(context, ref, chat, details.globalPosition),
        ),
        child: ChatTile(
          chat: chat,
          avatarHeaders: mediaHeaders,
          typing: ref.read(chatRepositoryProvider).typingIn(chat.id).isNotEmpty,
          online:
              ref.read(chatRepositoryProvider).presenceFor(chat.id)?.online ??
              false,
          selected: picked || chat.id == selectedChatId,
          checked: selection.isEmpty ? null : picked,
          leading: selection.isEmpty
              ? null
              : Checkbox(
                  value: picked,
                  onChanged: (_) =>
                      ref.read(chatSelectionProvider.notifier).toggle(chat.id),
                ),
          timeLabel: formatInboxTime(
            chat.lastMessage?.timestamp,
            now: ref.watch(clockProvider)(),
            justNow: context.l10n.inboxTimeNow,
          ),
          // Hold to look without spending the unread marker. The phone's
          // long-press enters selection, which is a thumb's idiom; a pointer
          // has a right-click menu for that and nothing else bound to holding.
          onLongPress: () => unawaited(_peek(chat.id)),
          onTap: () {
            if (selection.isNotEmpty) {
              ref.read(chatSelectionProvider.notifier).toggle(chat.id);
              return;
            }
            ref.read(selectedChatProvider.notifier).select(chat.id);
          },
        ),
      );
    },
  );
}

/// The draggable boundary between two panes.
///
/// Four points wide with a wider hit area, and it changes the cursor — which
/// is the only thing that tells a pointer the boundary can be moved at all.
class _Splitter extends StatefulWidget {
  const _Splitter({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) {
          // The primary delta is in physical direction; in a mirrored window
          // dragging the boundary left has to *grow* the leading pane.
          final rtl = Directionality.of(context) == TextDirection.rtl;
          widget.onDrag(rtl ? -details.delta.dx : details.delta.dx);
        },
        child: SizedBox(
          width: 5,
          child: Center(
            child: AnimatedContainer(
              duration: context.motion.instant,
              width: _active ? 2 : 0.5,
              color: _active ? context.colors.primary : context.palette.divider,
            ),
          ),
        ),
      ),
    );
  }
}

class _MacEmptyList extends StatelessWidget {
  const _MacEmptyList();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(WeftSpace.xl),
      child: MergeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.macEmptyListTitle,
              style: context.text.titleSmall,
            ),
            const SizedBox(height: WeftSpace.xs),
            Text(
              context.l10n.macEmptyListBody,
              textAlign: TextAlign.center,
              style: context.text.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The detail pane with nothing in it.
///
/// Quiet where the phone's is illustrated: on a desktop this state is what the
/// user sees every time they launch, and a 64pt gradient badge that has to be
/// looked past twenty times a day is a decoration with a cost.
class _MacEmptyDetail extends StatelessWidget {
  const _MacEmptyDetail();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: MergeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.forum_outlined,
                size: 34,
                color: context.colors.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: WeftSpace.md),
            Text(
              context.l10n.macEmptyDetailTitle,
              style: context.text.titleSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              context.l10n.inboxEmptyDetailBody,
              style: context.text.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
