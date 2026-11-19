# Improvement log

One line per shipped daily improvement, newest last, in the form
`- <yyyy-mm-dd> · <area> · <one-line change> · <PR link>`. The two sections
under it are what later runs read before choosing: what reviews have taught,
and what was noticed but not done.

## Shipped

- 2026-11-16 · User experience · A jump-to-latest button appears in a chat once you scroll up into older messages · https://github.com/bostrot/sennit/pull/3
- 2026-11-17 · Accessibility · The Mac search field's clear button is a 24pt target and speaks the reader's language · https://github.com/bostrot/sennit/pull/4
- 2026-11-18 · Localization · Reply quotes, link cards, statuses and the message sheet are read out (and the quote drawn) in the app's language; the l10n audit now sees inside `semanticsSentence` · https://github.com/bostrot/sennit/pull/5

- 2026-11-19 · User experience · ⌘↓ (Mac) / Ctrl+End (Windows, Linux) jumps back to the newest message in the open conversation, without taking the key from a half-written draft · PR_LINK

## Lessons from reviews

- 2026-11-16 · First run: there were no earlier `daily-improvement` pull
  requests, open or closed, so there is nothing to learn from yet.
- 2026-11-17 · No review comments yet; #3 was merged as opened. Practical
  note: a CI job that fails on `main` fails on every PR too, so before
  blaming a change, compare against the latest `main` run. Both #3 and #4
  were held up by `main`'s own CI (missing FFmpeg headers on the Linux
  runner, one unformatted file, one unused import), not by their changes.
- 2026-11-18 · Still no review comments; #4 merged as opened, and nothing
  has been closed unmerged. Before picking a backlog item, check it against
  `main`: the "scroll offset kept on a chat switch" entry had already been
  fixed by "Keep switching chats light" (`_startAtNewest` in
  `didUpdateWidget`), so it is struck below.

- 2026-11-19 · Still no review comments; #5 merged as opened, nothing
  closed unmerged. CI moved to GitHub-hosted runners (#7), so the "offline
  self-hosted runner" drafts of earlier runs should not recur. A fresh
  worktree has no generated `AppL10n`: run `flutter gen-l10n` in
  `apps/weft` before the first `flutter test`, or every test fails to load.

## Ideas backlog

- **Count what arrived while scrolled up.** The jump-to-latest button knows
  the reader is away from the bottom but not that anything new landed there.
  A small `UnreadBadge` on it for messages that arrived since they scrolled up
  is the natural second half. Where: `_syncRefresh` / `_announceIncoming` in
  `apps/weft/lib/features/chat/chat_view.dart` already see each arrival;
  `jump_to_latest_button.dart` would take a count. Open question: whether an
  own message sent from another device counts.
- ~~**A key for it on the desktop.**~~ Done 2026-11-19. Left out: a
  *Conversation ▸ Jump to Latest* entry in the Mac menu bar. A menu item with
  ⌘↓ as its key equivalent is handled by AppKit before Flutter sees the key, so
  it would take ⌘↓ from the composer's "caret to end" even mid-draft. It needs
  the item shown without a key equivalent, or a way to let AppKit pass it on.
  Was: Jump to latest has no shortcut. ⌘↓ is what
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
  Found 2026-11-17: the inbox row's muted icon and the menu's Mute/Unmute
  choice read only `chat.muted` (the push rule), so a timed mute set there
  would leave the row looking unmuted and the menu offering "Mute" again.
  Both need to read `notificationPolicyProvider` too — why it is more than a
  menu entry.
- **An unread divider.** Opening a chat with unread messages lands at the
  bottom with no mark of where the new ones begin. Needs the read marker at
  open time, before `_open` marks the chat read. Probably more than one run.
- **Copy a link to a message.** There is no `matrix.to` permalink anywhere in
  the app. Only meaningful for unbridged Matrix rooms, so the action would
  have to hide itself on a bridged leg.
- ~~**Switching chats on the two-pane desktop keeps the old scroll offset?**~~
  Already fixed on `main`: `didUpdateWidget` sets `_startAtNewest`, and
  `_open` jumps to the newest message.
- **The rest of UI-04 and UI-05.** The search field's text box is 19pt tall
  inside its 24pt field (UI-04a, UI-05a/b); with the focus ring now painted
  over the field rather than inset, the `TextField` can take the full
  `MacMetrics.fieldHeight`. "Attach" and "Record voice message" (UI-04c/d) are
  in `chat_view.dart`'s composer; #3 has merged, so that file is free now.
- **Escape empties the Mac search field.** The system's search fields do it;
  `MacSearchField` does not. Check first what Escape is already bound to in
  `shortcuts.dart` so it does not also close the pane.
- **A window per conversation on the Mac.** Element X for iOS added multiple
  windows on Mac and iPad in 26.04.1
  (https://newreleases.io/project/github/element-hq/element-x-ios/release/release%2F26.04.1).
  Far more than a run; worth a design note first.
- **The merged-chats screen is still half English.** The picker titles
  ("Merge which conversation?"), every snack bar ("Merged … with …. They are
  now one conversation.") and `handleLabel`'s "{name} on {network}" in
  `features/merge/merge_screen.dart` are literals the audit cannot see, because
  they reach the screen through a parameter (`_pickHandle(title)`,
  `_decide(…, message)`) rather than a `Text`. The signal explanations behind
  "because …" come from the domain in English too (`MergeSignal.explanation`)
  and need a code-to-words mapping in `l10n_labels.dart`. Also: the audit's
  `_isMachineValue` treats any lowercase single word (`'you'`, `'deleted'`) as
  an identifier, which is how two of the action sheet's words slipped by.
- **Share sheet leftovers.** `share_target_sheet.dart` still builds "Nothing to
  send", "{n} files" and the network list joined with " and " by hand.
- **Copy a link to a message — needs the other half first.** A copied
  `matrix.to/#/!room/$event` link opens only the room in Sennit:
  `links.dart` turns an event permalink into a room `RichMention` and drops
  the event id, so `_openMention` cannot jump to the message. Making inbound
  event links scroll to the message is the first run; the copy action is the
  second.
