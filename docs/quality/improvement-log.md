# Improvement log

One line per shipped daily improvement, newest last, in the form
`- <yyyy-mm-dd> · <area> · <one-line change> · <PR link>`. The two sections
under it are what later runs read before choosing: what reviews have taught,
and what was noticed but not done.

## Shipped

- 2026-11-16 · User experience · A jump-to-latest button appears in a chat once you scroll up into older messages · https://github.com/bostrot/sennit/pull/3

## Lessons from reviews

- 2026-11-16 · First run: there were no earlier `daily-improvement` pull
  requests, open or closed, so there is nothing to learn from yet.

## Ideas backlog

- **Count what arrived while scrolled up.** The jump-to-latest button knows
  the reader is away from the bottom but not that anything new landed there.
  A small `UnreadBadge` on it for messages that arrived since they scrolled up
  is the natural second half. Where: `_syncRefresh` / `_announceIncoming` in
  `apps/weft/lib/features/chat/chat_view.dart` already see each arrival;
  `jump_to_latest_button.dart` would take a count. Open question: whether an
  own message sent from another device counts.
- **A key for it on the desktop.** Jump to latest has no shortcut. ⌘↓ is what
  other Mac messengers use; it would go through `shortcuts.dart` and
  `shortcuts_sheet.dart` as a `WeftGuardedAction` that reports itself disabled
  at the bottom, per the keyboard rules in `a11y-audit.md`.
- **Timed mute from inside the app.** "Mute for 1 hour" exists only as a
  notification action (`notification_actions.dart`); the inbox menu and the
  contact profile offer on/off only, although
  `NotificationPolicyNotifier.muteChat(until:)` and the "Muted for another …"
  line in Settings ▸ Notifications are already there. A 1 h / 8 h / until I
  turn it back on choice in `inbox_shell.dart` and `contact_profile.dart`.
  Open question: a timed mute is Sennit's own while a plain one is a Matrix
  push rule, so the menu has to be clear about which it writes.
- **An unread divider.** Opening a chat with unread messages lands at the
  bottom with no mark of where the new ones begin. Needs the read marker at
  open time, before `_open` marks the chat read. Probably more than one run.
- **Copy a link to a message.** There is no `matrix.to` permalink anywhere in
  the app. Only meaningful for unbridged Matrix rooms, so the action would
  have to hide itself on a bridged leg.
- **Switching chats on the two-pane desktop keeps the old scroll offset?**
  `didUpdateWidget` calls `_open` for the new chat on the same `State`, and
  nothing visibly resets `_scroll`. Not verified — worth a failing test before
  touching anything.
