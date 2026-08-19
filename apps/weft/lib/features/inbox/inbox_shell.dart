import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../app/shortcuts.dart';
import '../bridges/bridges_screen.dart';
import '../chat/chat_view.dart';
import '../merge/merge_screen.dart';
import '../search/search_screen.dart';
import '../settings/appearance_sheet.dart';
import '../settings/devices_screen.dart';
import '../settings/security_screen.dart';
import '../settings/endpoints_screen.dart';
import '../settings/link_previews_screen.dart';
import '../settings/mcp_screen.dart';
import '../settings/notifications_screen.dart';
import '../settings/shortcuts_sheet.dart';
import '../settings/sms_screen.dart';

/// The app's home: network rail, inbox, and — when there's room — the open
/// conversation beside it.
class InboxShell extends ConsumerWidget {
  const InboxShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(chatRepositoryProvider);
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
                child: FocusTraversalGroup(child: const _InboxPane()),
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
    final selecting = selection.isNotEmpty;

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
          if (selecting)
            _SelectionBar(selected: selection, visible: chats)
          else
            _InboxHeader(activeFilter: filter),
          Expanded(
            child: chats.isEmpty
                ? const _EmptyInbox()
                : ListView.builder(
                    padding: const EdgeInsetsDirectional.only(
                      bottom: WeftSpace.xl,
                    ),
                    itemCount: chats.length,
                    itemBuilder: (context, i) {
                      final chat = chats[i];
                      final picked = selection.contains(chat.id);
                      return _StaggeredIn(
                        index: i,
                        child: ChatTile(
                          chat: chat,
                          avatarHeaders: mediaHeaders,
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
                          onLongPress: () => ref
                              .read(chatSelectionProvider.notifier)
                              .toggle(chat.id),
                          timeLabel: _formatTime(chat.lastMessage?.timestamp),
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
                            ref.read(chatRepositoryProvider).markRead(chat.id);
                            if (!wide) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ChatView(chatId: chat.id),
                                ),
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Today shows a clock; this week a weekday; older a date. Matches how people
  /// actually reason about when a message arrived.
  static String? _formatTime(DateTime? ts) {
    if (ts == null) return null;
    final now = DateTime(2026, 8, 15, 16, 42);
    final delta = now.difference(ts);
    if (delta.inMinutes < 1) return 'Now';
    if (delta.inHours < 24) return DateFormat.Hm().format(ts);
    if (delta.inDays < 7) return DateFormat.E().format(ts);
    return DateFormat.yMd().format(ts);
  }
}

/// Bulk actions for the selected chats.
class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({required this.selected, required this.visible});

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
            const Spacer(),
            IconButton(
              tooltip: allSelected ? 'Select none' : 'Select all',
              icon: Icon(
                allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
              ),
              onPressed: () {
                final notifier = ref.read(chatSelectionProvider.notifier);
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
              tooltip: 'Mute',
              icon: const Icon(Icons.notifications_off_outlined),
              onPressed: () =>
                  _apply(ref, (id) => repository.setMuted(id, muted: true)),
            ),
            IconButton(
              tooltip: archived ? 'Unarchive' : 'Archive',
              icon: Icon(
                archived ? Icons.unarchive_outlined : Icons.archive_outlined,
              ),
              onPressed: () => _apply(
                ref,
                (id) => repository.setArchived(id, archived: !archived),
              ),
            ),
            IconButton(
              tooltip: 'Leave and delete',
              icon: Icon(Icons.delete_outline, color: context.colors.error),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Delete ${selected.length} conversation(s)?'),
                    content: const Text(
                      'This leaves and forgets the rooms. The history is gone '
                      'from this account and cannot be recovered here. '
                      'Archiving hides a chat without losing anything.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: context.colors.error,
                        ),
                        onPressed: () => Navigator.of(context).pop(true),
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
    );
  }
}

class _InboxHeader extends ConsumerWidget {
  const _InboxHeader({required this.activeFilter});

  final Set<ChatNetwork> activeFilter;

  /// The three platforms a physical keyboard is a given on.
  ///
  /// The shortcuts still work on a tablet with one attached — they are bound
  /// app-wide — but an entry advertising them on a phone is a menu row that
  /// opens a sheet full of keys the device does not have.
  static bool get _hasKeyboard => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

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
                    case 'notifications':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const NotificationsScreen(),
                        ),
                      );
                    case 'endpoints':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const EndpointsScreen(),
                        ),
                      );
                    case 'link_previews':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const LinkPreviewsScreen(),
                        ),
                      );
                    case 'mcp':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const McpScreen(),
                        ),
                      );
                    case 'devices':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DevicesScreen(),
                        ),
                      );
                    case 'security':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SecurityScreen(),
                        ),
                      );
                    case 'sms':
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SmsScreen(),
                        ),
                      );
                    case 'shortcuts':
                      showShortcutsSheet(context);
                  }
                },
                itemBuilder: (_) => [
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
                    value: 'notifications',
                    child: Text('Notifications'),
                  ),
                  const PopupMenuItem(
                    value: 'endpoints',
                    child: Text('Search & transcription'),
                  ),
                  const PopupMenuItem(
                    value: 'link_previews',
                    child: Text('Link previews'),
                  ),
                  const PopupMenuItem(value: 'mcp', child: Text('MCP server')),
                  // The same condition `smsRepositoryProvider` is built under,
                  // stated rather than read: an entry that could only ever
                  // explain its own absence is worse than no entry, and asking
                  // the provider here would construct a method channel — and
                  // read the settings store — for a menu that may never open.
                  if (!kDemoMode &&
                      defaultTargetPlatform == TargetPlatform.android)
                    const PopupMenuItem(value: 'sms', child: Text('SMS')),
                  const PopupMenuItem(value: 'devices', child: Text('Devices')),
                  const PopupMenuItem(
                    value: 'security',
                    child: Text('Encryption'),
                  ),
                  // The other way into the shortcuts sheet, and the one that
                  // matters: Ctrl/Cmd + / only helps someone who already knows
                  // there is a keyboard model to look for. Stated as a
                  // platform condition rather than read off a provider, the
                  // same way the SMS entry above is — a phone with no keyboard
                  // attached has nothing to show here.
                  if (_hasKeyboard)
                    const PopupMenuItem(
                      value: 'shortcuts',
                      child: Text('Keyboard shortcuts'),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: WeftSpace.md),
          const _SearchField(),
          const SizedBox(height: WeftSpace.md),
          if (activeFilter.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ActionChip(
                avatar: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Clear filter'),
                onPressed: () =>
                    ref.read(networkFilterProvider.notifier).clear(),
              ),
            ),
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
