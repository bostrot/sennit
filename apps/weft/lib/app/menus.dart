import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../features/bridges/bridges_screen.dart';
import '../features/inbox/new_chat_sheet.dart';
import '../features/merge/merge_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/shortcuts_sheet.dart';
import 'providers.dart';
import 'shortcuts.dart';

/// Whether the desktop shell is showing its source list.
///
/// A provider rather than the shell's own state, because the menu bar is above
/// the shell and View ▸ Hide Sidebar has to reach it. It is also the only
/// window state a menu owns, which is why there is one of these and not a
/// window-state object.
class MacSidebarVisible extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}

final macSidebarVisibleProvider = NotifierProvider<MacSidebarVisible, bool>(
  MacSidebarVisible.new,
);

/// Braid's menu bar.
///
/// A Mac app without one is not a Mac app: the menu bar is where the system
/// expects to find every verb, where a user goes to *discover* a keyboard
/// shortcut, and what makes the app scriptable and searchable through Help.
/// Its absence is as loud as a floating action button.
///
/// A pass-through on every other surface — [PlatformMenuBar] renders nothing
/// off macOS, and building the menus there would be dead weight in the tree.
///
/// The items dispatch through the same intents the keyboard does, resolved
/// against the navigator's context. That is deliberate: a menu item that
/// duplicated the shortcut's work would be a second implementation of it, and
/// the two would drift the first time either changed.
class WeftMenuBar extends ConsumerWidget {
  const WeftMenuBar({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  BuildContext? get _context => navigatorKey.currentContext;

  void _push(Widget screen) {
    navigatorKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  /// Runs [intent] the way the shortcut for it would.
  void _invoke(Intent intent) {
    final context = _context;
    if (context == null) return;
    Actions.maybeInvoke(context, intent);
  }

  /// Runs a text-editing intent against whatever holds the caret.
  ///
  /// The focused field, not the navigator: Copy means copy *this* selection,
  /// and the actions that implement it are registered by `EditableText` at the
  /// focus, not by anything above it.
  void _editing(Intent intent) {
    final context = primaryFocus?.context;
    if (context == null) return;
    Actions.maybeInvoke(context, intent);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!context.isMac) return child;

    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          // The application menu, whatever it is labelled — macOS replaces the
          // label with the app's name and always draws it first.
          label: 'Braid',
          menus: [
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.about,
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Settings…',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.comma,
                    meta: true,
                  ),
                  onSelected: () => _push(const SettingsScreen()),
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.servicesSubmenu,
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hide,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hideOtherApplications,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.showAllApplications,
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.quit,
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: 'File',
          menus: [
            PlatformMenuItem(
              label: 'New Conversation…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                meta: true,
              ),
              onSelected: () {
                final target = _context;
                if (target != null) {
                  showNewChatSheet(target, ref);
                }
              },
            ),
            PlatformMenuItem(
              label: 'Search…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyF,
                meta: true,
              ),
              onSelected: () => _push(const SearchScreen()),
            ),
          ],
        ),
        PlatformMenu(
          label: 'Edit',
          menus: [
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Cut',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyX,
                    meta: true,
                  ),
                  onSelected: () => _editing(
                    const CopySelectionTextIntent.cut(
                      SelectionChangedCause.keyboard,
                    ),
                  ),
                ),
                PlatformMenuItem(
                  label: 'Copy',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyC,
                    meta: true,
                  ),
                  onSelected: () => _editing(CopySelectionTextIntent.copy),
                ),
                PlatformMenuItem(
                  label: 'Paste',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyV,
                    meta: true,
                  ),
                  onSelected: () => _editing(
                    const PasteTextIntent(SelectionChangedCause.keyboard),
                  ),
                ),
                PlatformMenuItem(
                  label: 'Select All',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyA,
                    meta: true,
                  ),
                  onSelected: () => _editing(
                    const SelectAllTextIntent(SelectionChangedCause.keyboard),
                  ),
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: 'View',
          menus: [
            PlatformMenuItem(
              label: ref.watch(macSidebarVisibleProvider)
                  ? 'Hide Sidebar'
                  : 'Show Sidebar',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyS,
                meta: true,
                control: true,
              ),
              onSelected: () =>
                  ref.read(macSidebarVisibleProvider.notifier).toggle(),
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: ref.watch(showArchivedProvider)
                      ? 'Show Active Conversations'
                      : 'Show Archived',
                  onSelected: () =>
                      ref.read(showArchivedProvider.notifier).toggle(),
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.toggleFullScreen,
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: 'Conversation',
          menus: [
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Next Conversation',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.arrowDown,
                    alt: true,
                  ),
                  onSelected: () => _invoke(const NextChatIntent()),
                ),
                PlatformMenuItem(
                  label: 'Previous Conversation',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.arrowUp,
                    alt: true,
                  ),
                  onSelected: () => _invoke(const PreviousChatIntent()),
                ),
              ],
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Mark All as Read',
                  onSelected: () {
                    final repository = ref.read(chatRepositoryProvider);
                    for (final chat in ref.read(visibleChatsProvider)) {
                      if (chat.unreadCount > 0) repository.markRead(chat.id);
                    }
                  },
                ),
                PlatformMenuItem(
                  label: 'Merged Chats…',
                  onSelected: () => _push(const MergeScreen()),
                ),
                PlatformMenuItem(
                  label: 'Bridges…',
                  onSelected: () => _push(const BridgesScreen()),
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: 'Window',
          menus: const [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: 'Help',
          menus: [
            PlatformMenuItem(
              label: 'Keyboard Shortcuts',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.slash,
                meta: true,
              ),
              onSelected: () {
                final target = _context;
                if (target != null) showShortcutsSheet(target);
              },
            ),
          ],
        ),
      ],
      child: child,
    );
  }
}
