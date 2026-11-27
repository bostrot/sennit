/// Weft's keyboard model.
///
/// The audit's CROSS-3 finding had two halves. The first — that whole surfaces
/// were unreachable by Tab — is answered by `WeftFocusable` in `weft_design`,
/// at each control. This file is the second: there were no shortcuts at all,
/// and the one key that did do something did the wrong thing, because Enter
/// sent a message and nothing put a line break into a five-line composer.
///
/// Three rules the bindings below are built to:
///
///  * **Nothing unmodified is claimed globally.** Every app-wide binding
///    carries Ctrl/Cmd or Alt, so no shortcut can swallow a character while the
///    composer has focus. The two unmodified keys Weft does use — Enter and
///    Escape — are bound *inside* the chat, where they mean something, and both
///    fall through when they do not: Escape is inert unless the composer is in
///    reply or edit mode, so it still closes the dialog above it.
///  * **The table is the documentation.** [weftKeyBindings] is what builds the
///    [Shortcuts] map *and* what the shortcuts sheet renders, so a binding
///    cannot be added without appearing in the sheet, and the sheet cannot
///    describe a key that does nothing.
///  * **A shortcut that cannot work is disabled, not silent.** Next/previous
///    conversation moves the selection in the detail pane, which a one-pane
///    window does not have — so on a narrow window the action reports itself
///    disabled and the key event carries on to whoever else wants it, rather
///    than being consumed by something the user cannot see happening.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/search/search_screen.dart';
import '../features/settings/shortcuts_sheet.dart';
import 'localisation.dart';
import 'providers.dart';

/// Width at which the inbox and the open conversation sit side by side.
///
/// Public because the shortcuts have to ask the same question the layout does:
/// "next conversation" moves the selection, and on a window with no detail
/// pane there is nothing for the selection to move *in*.
const double kTwoPaneBreakpoint = 900;

/// Open the conversation below the current one in the inbox.
class NextChatIntent extends Intent {
  const NextChatIntent();
}

/// Open the conversation above the current one in the inbox.
class PreviousChatIntent extends Intent {
  const PreviousChatIntent();
}

/// Put the caret in the open conversation's composer.
class FocusComposerIntent extends Intent {
  const FocusComposerIntent();
}

/// Open search, with the field focused.
class FocusSearchIntent extends Intent {
  const FocusSearchIntent();
}

/// Scroll the open conversation back down to its newest message.
class JumpToLatestIntent extends Intent {
  const JumpToLatestIntent();
}

/// Show the list of every binding in this file.
class ShowShortcutsIntent extends Intent {
  const ShowShortcutsIntent();
}

/// Leave reply or edit mode without sending.
///
/// Handled inside the conversation rather than app-wide: Escape belongs to
/// whatever is on top, and a dialog over a chat with a reply half-typed must
/// still close on the first press.
class CancelComposerContextIntent extends Intent {
  const CancelComposerContextIntent();
}

/// Send what is in the composer.
class SendComposerIntent extends Intent {
  const SendComposerIntent();
}

/// Break the line instead of sending it.
class InsertComposerNewlineIntent extends Intent {
  const InsertComposerNewlineIntent();
}

/// One row of the shortcuts sheet, and — when it has an [intent] — one entry in
/// the app-wide [Shortcuts] map.
///
/// A binding with no intent is one a screen owns for itself: Enter, Shift+Enter
/// and Escape are the composer's, and claiming them app-wide would take Enter
/// away from every button in the app. They are listed here anyway because a
/// shortcuts sheet that omits "how do I type a second line" is the sheet not
/// answering the question people actually have.
@immutable
class WeftKeyBinding {
  const WeftKeyBinding({
    required this.description,
    required this.activators,
    this.intent,
  });

  final String description;

  /// Every key combination that does this, in the order the sheet lists them.
  final List<SingleActivator> activators;

  /// Null for a binding a screen installs itself.
  final Intent? intent;
}

/// Every binding Weft has, in the order the sheet shows them.
///
/// [useMetaKey] picks Cmd over Ctrl. Registering both would be simpler and is
/// wrong on macOS, where Ctrl+F moves the caret forward a character inside a
/// text field — a shortcut that stole it would break editing in the composer to
/// save one branch here.
List<WeftKeyBinding> weftKeyBindings(AppL10n l10n, {bool? useMetaKey}) {
  final meta = useMetaKey ?? _platformUsesMetaKey;
  SingleActivator primary(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
  }) =>
      SingleActivator(key, control: !meta, meta: meta, shift: shift, alt: alt);

  return [
    WeftKeyBinding(
      description: l10n.shortcutNextChat,
      activators: [
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true),
        primary(LogicalKeyboardKey.pageDown),
      ],
      intent: const NextChatIntent(),
    ),
    WeftKeyBinding(
      description: l10n.shortcutPreviousChat,
      activators: [
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true),
        primary(LogicalKeyboardKey.pageUp),
      ],
      intent: const PreviousChatIntent(),
    ),
    WeftKeyBinding(
      description: l10n.inboxSearchAll,
      activators: [
        primary(LogicalKeyboardKey.keyF),
        primary(LogicalKeyboardKey.keyK),
      ],
      intent: const FocusSearchIntent(),
    ),
    WeftKeyBinding(
      description: l10n.shortcutWriteMessage,
      activators: [primary(LogicalKeyboardKey.keyM, shift: true)],
      intent: const FocusComposerIntent(),
    ),
    // The chat's jump-to-latest button, from the keyboard. ⌘↓ on a Mac and
    // Ctrl+End elsewhere, because those are what "to the end" already means
    // there — and in a text field too, which is why the action stands aside
    // until the caret has nowhere further down to go.
    WeftKeyBinding(
      description: l10n.chatJumpToLatest,
      activators: [
        if (meta)
          const SingleActivator(LogicalKeyboardKey.arrowDown, meta: true)
        else
          const SingleActivator(LogicalKeyboardKey.end, control: true),
      ],
      intent: const JumpToLatestIntent(),
    ),
    WeftKeyBinding(
      description: l10n.shortcutsTitle,
      activators: [primary(LogicalKeyboardKey.slash)],
      intent: const ShowShortcutsIntent(),
    ),
    // The composer's three. Documented here, bound there — see the library
    // comment above for why they are not in the app-wide map.
    WeftKeyBinding(
      description: l10n.shortcutSend,
      activators: const [SingleActivator(LogicalKeyboardKey.enter)],
    ),
    WeftKeyBinding(
      description: l10n.shortcutNewLine,
      activators: const [
        SingleActivator(LogicalKeyboardKey.enter, shift: true),
      ],
    ),
    WeftKeyBinding(
      description: l10n.shortcutCancelReply,
      activators: const [SingleActivator(LogicalKeyboardKey.escape)],
    ),
  ];
}

/// The app-wide map: every binding in [weftKeyBindings] that carries an intent.
///
/// Built from the same list rather than a second table of its own, which is
/// what stops a shortcut being documented in the sheet and bound to nothing.
/// The locale is [weftPlatformL10n] rather than the app's resolved one because
/// this map reads only activators and intents — the descriptions it walks past
/// never reach a screen, so which language they were built in cannot matter.
Map<ShortcutActivator, Intent> weftShortcutMap({bool? useMetaKey}) {
  return {
    for (final binding in weftKeyBindings(
      weftPlatformL10n(),
      useMetaKey: useMetaKey,
    ))
      if (binding.intent case final intent?)
        for (final activator in binding.activators) activator: intent,
  };
}

/// Paste into the composer, whatever is on the clipboard.
///
/// A separate intent from the framework's `PasteTextIntent` because the
/// question it answers is different: a clipboard holding a screenshot should
/// attach a picture, and one holding text should paste text. The action decides
/// which, and hands the second case straight back to the framework.
class PasteIntoComposerIntent extends Intent {
  const PasteIntoComposerIntent();
}

/// Copy what the reader is pointing at in a conversation.
///
/// One intent for two things, because to the person pressing the key they are
/// one thing. With text selected across the thread it copies the selection;
/// with nothing selected and a bubble focused it copies that message — the
/// behaviour "Copy" in the actions sheet has always had.
///
/// A separate intent from the framework's [CopySelectionTextIntent] rather than
/// an override of it, and this is the whole reason: a message bubble is not an
/// `EditableText`, `SelectableRegion`'s copy action knows only about the
/// selection, and neither can answer "copy the message under the caret". The
/// chat registers this one and decides; everything above it — the Mac menu bar,
/// the Ctrl+C binding on Windows and Linux — just sends it.
class CopyMessageIntent extends Intent {
  const CopyMessageIntent();
}

/// Copy, in a conversation, on a platform with no menu bar to claim it.
///
/// macOS never gets here: `PlatformMenuBar` hands ⌘C to AppKit, which invokes
/// the Edit menu item directly and the key event never reaches the focus tree.
/// Windows and Linux have no menu bar, so the binding has to live in the
/// widget tree — installed *around the message list only*, so a composer with
/// the caret in it keeps the framework's own copy.
const Map<ShortcutActivator, Intent> messageCopyShortcuts = {
  SingleActivator(LogicalKeyboardKey.keyC, meta: true): CopyMessageIntent(),
  SingleActivator(LogicalKeyboardKey.keyC, control: true): CopyMessageIntent(),
};

/// The composer's shortcuts, installed around the field itself.
///
/// Around the field and not app-wide, and this is the whole reason KEY-04 was a
/// bug rather than an oversight: `textInputAction: TextInputAction.send` hands
/// Enter to the platform's text input, which calls `performAction` and inserts
/// nothing — so a five-line composer had no way to reach line two. Handling the
/// key here means the framework marks it handled and the embedder never
/// forwards it, which is what lets Shift+Enter mean something different from
/// Enter. A soft keyboard sends no key events at all and still goes through
/// `onSubmitted`, so a phone is unaffected either way.
/// [composerShortcutsFor] with Return bound to sending, which is what it was
/// before the behaviour became a setting.
const Map<ShortcutActivator, Intent> composerShortcuts = {
  SingleActivator(LogicalKeyboardKey.enter): SendComposerIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): SendComposerIntent(),
  SingleActivator(LogicalKeyboardKey.enter, shift: true):
      InsertComposerNewlineIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
      InsertComposerNewlineIntent(),
  // Both modifiers, unconditionally: ⌘V is paste on a Mac and Ctrl+V on
  // Windows and Linux, and neither combination means anything else in a text
  // field on the platform that does not use it.
  SingleActivator(LogicalKeyboardKey.keyV, meta: true):
      PasteIntoComposerIntent(),
  SingleActivator(LogicalKeyboardKey.keyV, control: true):
      PasteIntoComposerIntent(),
};

/// [composerShortcuts] in a browser, where paste is the browser's own.
///
/// Sennit Web cannot ask for the clipboard: over the phone's plain-http link
/// the clipboard API is not there at all, and over the relay reading it asks
/// for a permission. Binding ⌘V/Ctrl+V here marked the key handled, so the
/// browser never pasted either, and the composer took nothing. Left unbound,
/// the key reaches the browser's text field, which pastes the way any page
/// does. Images are not lost by this: Sennit Web sends no attachments.
final Map<ShortcutActivator, Intent> browserComposerShortcuts = {
  for (final MapEntry(:key, :value) in composerShortcuts.entries)
    if (value is! PasteIntoComposerIntent) key: value,
};

/// The composer's keys, given what Return is set to do.
///
/// Both arrangements bind the same two intents; which key carries which is the
/// whole of the setting. The modifier chord sends in both, because a person who
/// has turned Return into a newline still needs a way to send that does not
/// involve reaching for the mouse — and Cmd+Return is what every editor with
/// this setting uses.
Map<ShortcutActivator, Intent> composerShortcutsFor({
  required bool sendOnEnter,
}) => {
  const SingleActivator(LogicalKeyboardKey.enter, meta: true):
      const SendComposerIntent(),
  const SingleActivator(LogicalKeyboardKey.enter, control: true):
      const SendComposerIntent(),
  const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
      const SendComposerIntent(),
  const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
      const SendComposerIntent(),
  if (sendOnEnter) ...{
    const SingleActivator(LogicalKeyboardKey.enter): const SendComposerIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter):
        const SendComposerIntent(),
    const SingleActivator(LogicalKeyboardKey.enter, shift: true):
        const InsertComposerNewlineIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
        const InsertComposerNewlineIntent(),
  } else ...{
    const SingleActivator(LogicalKeyboardKey.enter):
        const InsertComposerNewlineIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter):
        const InsertComposerNewlineIntent(),
    const SingleActivator(LogicalKeyboardKey.enter, shift: true):
        const InsertComposerNewlineIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
        const InsertComposerNewlineIntent(),
  },
  const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
      const PasteIntoComposerIntent(),
  const SingleActivator(LogicalKeyboardKey.keyV, control: true):
      const PasteIntoComposerIntent(),
};

/// Replaces the selection in [controller] with a line break.
///
/// The composing region is cleared rather than carried over: on a platform with
/// an IME the range describes the text that was there before the edit, and
/// leaving it behind makes the next keystroke overwrite the newline that was
/// just inserted.
void insertComposerNewline(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) {
    controller.value = TextEditingValue(
      // l10n-ignore: the user's own draft with a line break added.
      text: '${value.text}\n',
      selection: TextSelection.collapsed(offset: value.text.length + 1),
    );
    return;
  }
  controller.value = TextEditingValue(
    text: value.text.replaceRange(selection.start, selection.end, '\n'),
    selection: TextSelection.collapsed(offset: selection.start + 1),
  );
}

/// The open conversation's composer, for the shortcut that focuses it.
///
/// A registry rather than an [Actions] handler in the chat, because of where
/// the focus is when the shortcut is pressed: on a two-pane desktop the user is
/// in the inbox list, which is a *sibling* of the conversation, so no ancestor
/// of the focused widget can reach the composer's node. There is one open
/// conversation at a time either way — inline on a wide window, pushed on a
/// narrow one — and the last one to register is the one on screen.
class ComposerHandle {
  FocusNode? _node;
  Object? _owner;

  /// Claims the handle for [owner]'s [node].
  void register(Object owner, FocusNode node) {
    _owner = owner;
    _node = node;
  }

  /// Releases it, if [owner] still holds it.
  ///
  /// Guarded, because a route push builds the new conversation before the old
  /// one is disposed: unregistering unconditionally would clear the handle the
  /// incoming screen had just taken.
  void release(Object owner) {
    if (identical(_owner, owner)) {
      _owner = null;
      _node = null;
    }
  }

  bool get isAvailable => _node?.canRequestFocus ?? false;

  /// Moves focus to the composer. False when there is no conversation open.
  bool focus() {
    final node = _node;
    if (node == null || !node.canRequestFocus) return false;
    node.requestFocus();
    return true;
  }
}

final composerHandleProvider = Provider<ComposerHandle>(
  (ref) => ComposerHandle(),
);

/// Text waiting to be put into a conversation's composer.
///
/// "Send a message to Anna saying I'm late" arrives as a link with the words
/// in it, and the conversation it names may not be on screen yet — on a cold
/// start it is seconds from existing. So the text is parked here under the
/// chat id and the conversation takes it when it opens, or at once if it is
/// already open. It is never sent from here: the user reads it and presses
/// send, which is the confirmation an App Action has no other way to ask for.
class ComposerPrefill extends ChangeNotifier {
  final Map<String, String> _pending = {};

  /// Parks [text] for [chatId], replacing anything parked there before.
  void offer(String chatId, String text) {
    if (text.trim().isEmpty) return;
    _pending[chatId] = text.trim();
    notifyListeners();
  }

  /// The text parked for any of [chatIds], removed so it is used once.
  ///
  /// Several ids because a conversation answers to more than one: the id the
  /// link resolved to and the one the screen settled on after a merge.
  String? take(Iterable<String> chatIds) {
    for (final id in chatIds) {
      final text = _pending.remove(id);
      if (text != null) return text;
    }
    return null;
  }
}

/// Held for the app's lifetime, like [composerHandleProvider]; the open
/// conversation listens to it directly.
final composerPrefillProvider = Provider<ComposerPrefill>(
  (ref) => ComposerPrefill(),
);

/// The open conversation's way back to its newest message, for the shortcut
/// that takes it.
///
/// A registry for the same reason as [ComposerHandle]: on a two-pane window
/// the focus can be in the inbox, a sibling of the conversation, and the key
/// should still bring the conversation on screen back down.
class LatestMessageHandle {
  Object? _owner;
  bool Function()? _isAway;
  VoidCallback? _jump;

  /// Claims the handle for [owner]. [isAway] says whether there is anywhere
  /// to jump to; [jump] goes there.
  void register(
    Object owner, {
    required bool Function() isAway,
    required VoidCallback jump,
  }) {
    _owner = owner;
    _isAway = isAway;
    _jump = jump;
  }

  /// Releases it, if [owner] still holds it — see [ComposerHandle.release].
  void release(Object owner) {
    if (identical(_owner, owner)) {
      _owner = null;
      _isAway = null;
      _jump = null;
    }
  }

  /// True only while a conversation is open *and* scrolled away from its
  /// newest message — the same moment its button is on screen.
  bool get isAvailable => _isAway?.call() ?? false;

  /// Scrolls back down. False when there was nowhere to go.
  bool jump() {
    final jump = _jump;
    if (jump == null || !isAvailable) return false;
    jump();
    return true;
  }
}

final latestMessageHandleProvider = Provider<LatestMessageHandle>(
  (ref) => LatestMessageHandle(),
);

/// Whether the focused text field still has somewhere for the caret to go
/// with "to the end" — that is, it is not collapsed at the end of the text.
///
/// ⌘↓ and Ctrl+End are the text field's own keys first. Taking them from a
/// half-written draft would strand the caret mid-sentence; once it is already
/// at the end (or the field is empty) the key has nothing left to do there, and
/// carrying on to the end of the conversation is what it reads as.
bool focusedTextCanMoveToEnd() {
  final editable = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  if (editable == null) return false;
  final value = editable.textEditingValue;
  final selection = value.selection;
  return !(selection.isValid &&
      selection.isCollapsed &&
      selection.baseOffset >= value.text.length);
}

/// An [Action] built from a callback that can also say it is not available.
///
/// [CallbackAction] is always enabled, and always-enabled is the wrong answer
/// more often than it looks. A *disabled* action lets [Shortcuts] report the
/// key as unhandled, so it carries on to whoever else wants it: Alt+Down on a
/// one-pane window reaches the scroll view instead of being eaten by a pane
/// that is not on screen, and Escape over a dialog closes the dialog rather
/// than clearing a reply nobody can see.
class WeftGuardedAction<T extends Intent> extends Action<T> {
  WeftGuardedAction({required this.onInvoke, this.enabled});

  final void Function() onInvoke;
  final bool Function()? enabled;

  @override
  bool isEnabled(T intent) => enabled?.call() ?? true;

  @override
  Object? invoke(T intent) {
    onInvoke();
    return null;
  }
}

/// Installs Weft's app-wide keyboard bindings around [child].
///
/// Above the navigator, so the bindings work on a pushed conversation, a
/// settings screen and the inbox alike — and below the theme, so the sheet it
/// opens is drawn in the app's own colours.
class WeftShortcuts extends ConsumerStatefulWidget {
  const WeftShortcuts({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// How the actions reach a screen. Everything above the navigator is outside
  /// it, so `Navigator.of(context)` from here would find nothing.
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  @override
  ConsumerState<WeftShortcuts> createState() => _WeftShortcutsState();
}

class _WeftShortcutsState extends ConsumerState<WeftShortcuts> {
  /// Search is already open.
  ///
  /// Pressing Cmd+F twice used to be two screens deep, and the second Escape
  /// landed the user back on a search they thought they had left.
  bool _searchOpen = false;

  NavigatorState? get _navigator => widget.navigatorKey.currentState;
  BuildContext? get _context => widget.navigatorKey.currentContext;

  /// Whether there is a detail pane for a selection to move in.
  bool get _twoPane {
    final context = _context;
    if (context == null) return false;
    return MediaQuery.sizeOf(context).width >= kTwoPaneBreakpoint;
  }

  void _moveChat(int delta) {
    final chats = ref.read(visibleChatsProvider);
    if (chats.isEmpty) return;
    final current = ref.read(selectedChatProvider);
    final index = chats.indexWhere((chat) => chat.id == current);
    // From nowhere, "next" is the top of the list rather than the second row:
    // the user has not been anywhere yet, so there is nothing to be after.
    final next = index < 0
        ? (delta > 0 ? 0 : chats.length - 1)
        : (index + delta).clamp(0, chats.length - 1);
    final chat = chats[next];
    if (chat.id == current) return;
    ref.read(selectedChatProvider.notifier).select(chat.id);
    ref.read(chatRepositoryProvider).markRead(chat.id);
  }

  void _openSearch() {
    final navigator = _navigator;
    if (navigator == null || _searchOpen) return;
    _searchOpen = true;
    navigator
        .push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()))
        .whenComplete(() => _searchOpen = false);
  }

  void _showShortcuts() {
    final context = _context;
    if (context == null) return;
    unawaited(showShortcutsSheet(context));
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: weftShortcutMap(),
      child: Actions(
        actions: <Type, Action<Intent>>{
          NextChatIntent: WeftGuardedAction<NextChatIntent>(
            onInvoke: () => _moveChat(1),
            enabled: () => _twoPane,
          ),
          PreviousChatIntent: WeftGuardedAction<PreviousChatIntent>(
            onInvoke: () => _moveChat(-1),
            enabled: () => _twoPane,
          ),
          FocusSearchIntent: WeftGuardedAction<FocusSearchIntent>(
            onInvoke: _openSearch,
          ),
          FocusComposerIntent: WeftGuardedAction<FocusComposerIntent>(
            onInvoke: () => ref.read(composerHandleProvider).focus(),
            enabled: () => ref.read(composerHandleProvider).isAvailable,
          ),
          JumpToLatestIntent: WeftGuardedAction<JumpToLatestIntent>(
            onInvoke: () => ref.read(latestMessageHandleProvider).jump(),
            enabled: () =>
                ref.read(latestMessageHandleProvider).isAvailable &&
                !focusedTextCanMoveToEnd(),
          ),
          ShowShortcutsIntent: WeftGuardedAction<ShowShortcutsIntent>(
            onInvoke: _showShortcuts,
          ),
        },
        child: widget.child,
      ),
    );
  }
}

bool get _platformUsesMetaKey =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// [activator] as the sheet prints it — "⌘ + F", "Alt + Arrow Down".
String describeShortcut(SingleActivator activator) {
  final meta = _platformUsesMetaKey;
  return [
    if (activator.control) meta ? '⌃' : 'Ctrl',
    if (activator.meta) meta ? '⌘' : 'Meta',
    if (activator.alt) meta ? '⌥' : 'Alt',
    if (activator.shift) meta ? '⇧' : 'Shift',
    _triggerLabel(activator.trigger),
  ].join(' + ');
}

String _triggerLabel(LogicalKeyboardKey key) {
  // `keyLabel` is empty for a handful of keys and gives the raw name for a few
  // more; these are the ones Weft actually binds.
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return 'Enter';
  }
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.arrowUp) return 'Arrow Up';
  if (key == LogicalKeyboardKey.arrowDown) return 'Arrow Down';
  if (key == LogicalKeyboardKey.pageUp) return 'Page Up';
  if (key == LogicalKeyboardKey.pageDown) return 'Page Down';
  if (key == LogicalKeyboardKey.end) return 'End';
  final label = key.keyLabel;
  return label.isEmpty ? key.debugName ?? '?' : label;
}
