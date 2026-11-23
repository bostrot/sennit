# Improvement log

One line per shipped daily improvement, newest last, in the form
`- <yyyy-mm-dd> · <area> · <one-line change> · <PR link>`. The two sections
under it are what later runs read before choosing: what reviews have taught,
and what was noticed but not done.

## Shipped

- 2026-11-16 · User experience · A jump-to-latest button appears in a chat once you scroll up into older messages · https://github.com/bostrot/sennit/pull/3
- 2026-11-17 · Accessibility · The Mac search field's clear button is a 24pt target and speaks the reader's language · https://github.com/bostrot/sennit/pull/4
- 2026-11-18 · Localization · Reply quotes, link cards, statuses and the message sheet are read out (and the quote drawn) in the app's language; the l10n audit now sees inside `semanticsSentence` · https://github.com/bostrot/sennit/pull/5

- 2026-11-19 · User experience · ⌘↓ (Mac) / Ctrl+End (Windows, Linux) jumps back to the newest message in the open conversation, without taking the key from a half-written draft · https://github.com/bostrot/sennit/pull/8

- 2026-11-20 · Bug fix · Older history asked for from inside layout waits for the frame to finish, so reaching the top of a chat no longer rebuilds it mid-frame · https://github.com/bostrot/sennit/pull/9

- 2026-11-23 · Localization · The share sheet's title, summary line ("Reading 3 files…", "2 files", "Nothing to send", the quoted text), "via WhatsApp" and the networks a screen reader hears on each row follow the app's language · https://github.com/bostrot/sennit/pull/29

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

- 2026-11-20 · #8 merged with only CI notes; nothing closed unmerged. A
  flaky failure that comes and goes is worth chasing for its cause: the
  "loading older history mid-layout" bug hid behind the listener's
  wall-clock cooldown, failing about one run in five. A test that sets up
  the state directly (reader past the end, cooldown elapsed) made it fail
  every time.

- 2026-11-23 · #9 merged with only CI notes; nothing closed unmerged, and
  no issues open. Strings built in a helper method (`_title`, `_summary`)
  rather than passed straight to a `Text` are as invisible to the l10n audit
  as the ones passed through a parameter: grep a screen for `'[A-Z]` and
  `' and '` before trusting the audit's silence.

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
- ~~**Share sheet leftovers.**~~ Done 2026-11-23. Was: `share_target_sheet.dart`
  still builds "Nothing to send", "{n} files" and the network list joined with
  " and " by hand.
- **File sizes ignore the language's decimal mark.** `formatAttachmentSize`
  (`packages/weft_attachments/lib/src/format.dart`) writes "2.4 MB" in every
  language; German and French expect "2,4 MB". It is pure Dart with no locale,
  so the fix is either a locale-aware twin in the app using `NumberFormat`, or
  a `decimalSeparator` parameter. Used by the share sheet, the attachment
  sheet and message bubbles.
- **Chinese lists of three networks use ", ".** `networkNames` in
  `l10n_labels.dart` joins all but the last with `', '`; Chinese wants `、`.
  A `networkNamesSeparator` key (", " in most files, "、" in zh) would fix it.
- **Tap an avatar to see it full size.** Element X Android 26.06.3 made the
  avatar in a member sheet open a preview
  (https://newreleases.io/project/github/element-hq/element-x-android/release/v26.06.3).
  Check whether `contact_profile.dart`'s avatar does anything on tap.
- **Copy a link to a message — needs the other half first.** A copied
  `matrix.to/#/!room/$event` link opens only the room in Sennit:
  `links.dart` turns an event permalink into a room `RichMention` and drops
  the event id, so `_openMention` cannot jump to the message. Making inbound
  event links scroll to the message is the first run; the copy action is the
  second.
- ~~**Loading older history can call `setState` during layout.**~~ Done
  2026-11-20 (`_loadOlderSoon`). Left as it is: `keyboard_test.dart`'s
  `scrollIntoHistory` still stops short of the top; it no longer has to.
  Was: Found
  2026-11-19 while testing the jump-to-latest key: when the timeline's
  content dimensions change with the reader within a screen of the top, the
  ballistic scroll that `applyNewDimensions` starts dispatches a
  `ScrollStartNotification` from inside layout, and the listener in
  `chat_view.dart` calls `_loadOlder`, whose first line is a `setState`.
  Debug builds assert ("Build scheduled during frame"); release builds lag a
  frame. Deferring the call with `addPostFrameCallback` (or checking
  `SchedulerBinding.schedulerPhase`) is likely the whole fix, with a widget
  test that jumps to `maxScrollExtent` as the reproduction.
- **Let people refuse invites from strangers.** Matrix clients have started
  shipping invite blocking (seen in This Week in Matrix, 2026-09-25:
  https://matrix.org/blog/2026/09/25/this-week-in-matrix-2026-09-25/).
  Sennit has chat requests (`chat_requests_test.dart`); check which MSC the
  servers support and whether a "block invites from people you don't share a
  room with" switch fits there. Probably a design note first.
