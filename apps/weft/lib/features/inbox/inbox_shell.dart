import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';
import '../bridges/bridges_screen.dart';
import '../chat/chat_view.dart';
import '../merge/merge_screen.dart';
import '../search/search_screen.dart';
import '../settings/appearance_sheet.dart';
import '../settings/devices_screen.dart';
import '../settings/endpoints_screen.dart';
import '../settings/link_previews_screen.dart';
import '../settings/mcp_screen.dart';
import '../settings/notifications_screen.dart';

/// Width at which the inbox and the open conversation sit side by side.
const double _twoPaneBreakpoint = 900;

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

    final wide = MediaQuery.sizeOf(context).width >= _twoPaneBreakpoint;

    return Scaffold(
      body: Row(
        children: [
          NetworkRail(
            networks: repository.availableNetworks,
            selected: filter,
            unreadByNetwork: unread,
            onToggle: (n) => ref.read(networkFilterProvider.notifier).toggle(n),
            onShowAll: () => ref.read(networkFilterProvider.notifier).clear(),
          ),
          Expanded(flex: wide ? 2 : 1, child: const _InboxPane()),
          if (wide) ...[
            VerticalDivider(width: 1, color: context.palette.divider),
            Expanded(
              flex: 3,
              child: selectedChatId == null
                  ? const _EmptyDetail()
                  : ChatView(chatId: selectedChatId),
            ),
          ],
        ],
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
    final wide = MediaQuery.sizeOf(context).width >= _twoPaneBreakpoint;

    final selection = ref.watch(chatSelectionProvider);
    final selecting = selection.isNotEmpty;

    return SafeArea(
      // The rail handles its own insets and should keep painting behind the
      // status bar; only the inbox column must start below it.
      left: false,
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
                    padding: const EdgeInsets.only(bottom: WeftSpace.xl),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
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
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'archived',
                    child: Text(
                      ref.watch(showArchivedProvider)
                          ? 'Show active chats'
                          : 'Show archived',
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
                  const PopupMenuItem(value: 'devices', child: Text('Devices')),
                ],
              ),
            ],
          ),
          const SizedBox(height: WeftSpace.md),
          const _SearchField(),
          const SizedBox(height: WeftSpace.md),
          if (activeFilter.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
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
    return InkWell(
      borderRadius: WeftRadius.allMd,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
      child: InputDecorator(
        decoration: const InputDecoration(
          hintText: 'Search all conversations',
          prefixIcon: Icon(Icons.search_rounded, size: 20),
        ),
        child: const SizedBox(height: 20),
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
    final delay = WeftMotion.stagger * (index.clamp(0, 12));
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: WeftMotion.normal + delay,
      curve: WeftMotion.enter,
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_off_rounded,
              size: 40,
              color: context.colors.onSurfaceVariant,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: WeftRadius.allXl,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [context.colors.primary, context.colors.tertiary],
                ),
              ),
              child: Icon(
                Icons.forum_rounded,
                color: context.colors.onPrimary,
                size: 30,
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
    );
  }
}
