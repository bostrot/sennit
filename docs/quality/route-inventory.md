---
type: reference
title: Braid Route Inventory
created: 2026-08-28
tags:
  - ui
  - testing
  - regression
related:
  - '[[ui-audit]]'
  - '[[e2e-matrix]]'
---

# Braid Route Inventory

Every surface a person can reach in Braid, and the taps that get them there
from a cold inbox. Written for two readers: the route-walk harness in
[`apps/weft/integration_test/route_walk_test.dart`](../../apps/weft/integration_test/route_walk_test.dart),
which encodes the *Reached by* column as finders, and whoever has to check that
a new screen was not quietly added without a walk step.

Braid draws **two shells**, not one shell with conditions in it — see
`inbox_shell.dart:184`. `context.isMac` picks `MacInboxShell` on macOS and
`InboxShell` everywhere else, and a good third of the chrome differs: a network
rail against a source list, a scrolling header against a toolbar, a FAB against
a toolbar button. The *destinations* are almost entirely shared; the doors are
not. That is what the **Platforms** column records, and why several rows have
two different tap paths.

Panels are the other split. `showWeftPanel` (`weft_design/src/mac/mac_panels.dart:22`)
is one call site with three outcomes: a bottom sheet on touch, a popover
anchored to the control that opened it on macOS when an `anchorContext` was
passed, and a title-bar sheet on macOS when one was not. A row that says
*panel* means all three; the harness asserts the sheet on touch and the popover
on macOS rather than pretending they are the same widget.

## Reading the table

- **Kind** — `screen` is a `MaterialPageRoute` pushed onto the navigator;
  `panel` is `showWeftPanel` (sheet / popover / mac sheet); `dialog` is
  `showDialog`; `menu` is `showMenu` or a `PopupMenuButton`; `overlay` is drawn
  above the navigator by `main.dart`'s `builder` and has no route at all.
- **Reached by** — the tap path from a *cold inbox*: the app launched, signed
  in, sitting on the conversation list with nothing selected. `▸` separates
  taps.
- **Platforms** — `both`, `mobile` (the touch shell: Android, iOS, Windows,
  Linux), `macOS`. "mobile" is the surface, not the OS: Windows and Linux run
  the touch shell deliberately (`weft_design/src/surface.dart:35`).
- **Walk** — whether the route walk visits it, and if not, why not.

## Pre-inbox: the auth gate

`AuthGate` (`features/auth/auth_gate.dart:20`) chooses between five surfaces
from the session state, and none of them is reachable *from* the inbox — you
get there by not being signed in. The walk covers them by overriding the
session provider rather than by tapping, which is why they are listed apart.

| Surface | Defined in | Kind | Reached by | Platforms | Walk |
|---|---|---|---|---|---|
| Splash | `features/auth/auth_gate.dart:101` | screen | Launch, while stores or the session bootstrap | both | no — a frame of loading, asserted by `auth_gate_test.dart` |
| Startup error | `features/auth/auth_gate.dart:130` | screen | Launch with a store that fails to open | both | no — needs an injected failure, not a tap |
| Sign in | `features/auth/login_screen.dart:15` | screen | Launch signed out | both | no — pre-session; covered by the Patrol `login_test` |
| Verify this device | `features/auth/verification_screen.dart:18` | screen | Launch with `WeftSessionState.unverified`; also Settings ▸ Devices ▸ a device ▸ *Verify*; also pushed by `main.dart:317` when another client asks | both | yes, via the devices screen |
| Setup | `features/auth/setup_screen.dart:24` | screen | First launch after sign-in, before `onboardingDone` | both | no — one-shot onboarding, covered by `setup_screen_test.dart` |

## The inbox itself

| Surface | Defined in | Kind | Reached by | Platforms | Walk |
|---|---|---|---|---|---|
| Inbox (touch) | `features/inbox/inbox_shell.dart:174` | screen | The cold start | mobile | yes |
| Inbox (Mac window) | `features/inbox/mac_shell.dart:37` | screen | The cold start | macOS | yes |
| Inbox selection mode | `features/inbox/inbox_shell.dart:457` | in-place | ⋮ ▸ *Select* (touch) · right-click a row ▸ *Select* (macOS) | both | yes |
| Chat context menu | `features/inbox/inbox_shell.dart:44` | menu | Right-click a conversation row | both — pointer only | yes on macOS |
| Peek (chat preview) | `features/chat/chat_preview.dart:24` | overlay route | Long-press a row (touch) · right-click ▸ *Peek* (macOS) | both | yes |
| Labels | `features/inbox/label_sheet.dart:9` | panel | Selection mode ▸ label button · right-click ▸ *Labels…* | both | yes |
| Delete conversation | `features/inbox/inbox_shell.dart:125` | dialog | Right-click ▸ *Delete* · selection mode ▸ delete | both | yes |
| Status viewer | `features/status/status_viewer.dart:21` | screen | Tap a status ring above the filter row | mobile | yes |
| Hide-this-sender | `features/status/status_bar.dart:34` | panel | Long-press a status ring | mobile | yes |
| Search | `features/search/search_screen.dart:22` | screen | Tap the search field (touch) · ⌘F, or type in the toolbar field and press Return (macOS) | both | yes |
| New conversation | `features/inbox/new_chat_sheet.dart:28` | screen | FAB (touch) · toolbar compose button (macOS) | both | yes |
| By ID or number | `features/inbox/new_chat_sheet.dart:253` | dialog | New conversation ▸ *By ID or number* | both | yes |
| New group | `features/inbox/new_chat_sheet.dart:359` | dialog | New conversation ▸ *New group* | both | yes |
| Pick a network | `features/inbox/new_chat_sheet.dart:136` | panel | New conversation ▸ a person who is on more than one network | both | yes |
| Message requests | `features/inbox/requests_screen.dart:99` | screen | Tap the *Message requests* row above the conversations (present only when one is waiting) | both | yes |
| Appearance | `features/settings/appearance_sheet.dart:20` | panel | Header palette button (touch) · sidebar toolbar palette button (macOS) · Settings ▸ Appearance | both | yes |

## The conversation

Everything below is reached from an open chat. On touch that is *tap a
conversation row*; on macOS the thread is the third pane and is already open
once a row is selected, so the same surfaces hang off a pane rather than a
pushed route.

| Surface | Defined in | Kind | Reached by | Platforms | Walk |
|---|---|---|---|---|---|
| Chat | `features/chat/chat_view.dart:66` | screen (touch) / pane (macOS) | Tap a conversation row | both | yes |
| Thread | `features/chat/chat_view.dart:66` (`threadRootId`) | screen | Chat ▸ tap a thread indicator under a message | both | yes |
| Contact details | `features/contact/contact_profile.dart:18` | screen | Chat ▸ tap the title | both | yes |
| Merged chats | `features/merge/merge_screen.dart:17` | screen | Chat ▸ merge button · Contact details ▸ *Merged chats* · ⋮ ▸ *Merged chats* · sidebar ▸ *Merged chats* · Settings ▸ Merged chats | both | yes |
| Pick a handle to merge | `features/merge/merge_screen.dart:86` | panel | Merged chats ▸ a suggestion ▸ *Merge* | both | yes |
| Message actions | `features/chat/message_actions_sheet.dart:83` | panel | Long-press a message (touch) | mobile | yes |
| Message menu (desktop) | `features/chat/message_actions_sheet.dart:302` | menu | Right-click a message · the ⋯ button on a hovered bubble | macOS | yes |
| Delete message | `features/chat/message_actions_sheet.dart:441` | dialog | Message actions ▸ *Delete* | both | yes |
| Who reacted | `features/chat/reaction_bar.dart:219` | panel | Tap an existing reaction chip | both | yes |
| Emoji picker | `features/chat/emoji_picker_sheet.dart:51` | panel | Bubble ▸ react button ▸ *More* | both | yes |
| Edit history | `features/chat/edit_history_sheet.dart:21` | panel | Tap the *edited* marker on a message that has one | both | yes |
| Select text | `features/chat/chat_view.dart:1042` | dialog | Message actions ▸ *Select text* | mobile | yes |
| Text selection | `features/chat/chat_view.dart:927` | state (not a route) | Drag across the thread with a pointer | desktop — pointer only | yes on macOS, step `89-chat-selection` |
| Remind me | `features/chat/chat_view.dart:664` | panel | Message actions ▸ *Remind me* | both | yes |
| Pick a transcript language | `features/chat/chat_view.dart:1535` | panel | Voice note ▸ ⋯ ▸ *Transcribe again* | both | yes |
| Confirm this link | `features/chat/chat_view.dart:988` | dialog | Tap a link whose text and target disagree | both | yes |
| New poll | `features/chat/chat_view.dart:4132` | dialog | Attach ▸ *Poll* | both | yes |
| Propose a time | `features/chat/chat_view.dart:1920` | dialog | Agenda chip ▸ *Propose a time* | both | yes |
| Attach | `features/chat/attachment_source_sheet.dart:15` | panel | Composer ▸ paperclip | both | yes |
| Attachment preview | `features/chat/attachment_preview_sheet.dart:28` | panel | Attach ▸ a source that returns files | both | no — needs a real picker; covered by `attachment_flow_test.dart` |
| Paperless picker | `features/chat/paperless_picker_sheet.dart:15` | panel | Attach ▸ *Paperless* (only with an endpoint configured) | both | no — needs a configured endpoint |
| Media viewer | `features/chat/media_viewer.dart:79` | overlay route | Tap a photo or video bubble | both | yes |
| Voice recording bar | `features/chat/voice_recording_bar.dart:21` | in-place | Hold the mic button | mobile | no — needs a microphone grant |
| Scheduled send | `features/chat/chat_view.dart` (`showWeftPanel<DateTime>`) | panel | Hold the send button | both | yes |

## Calls

The call surfaces are drawn by `CallOverlay` (`features/call/call_overlay.dart`),
which sits *above* the navigator so a ringing call appears over whatever route
is open. They are driven by call state rather than by a tap, so the walk drives
them through the call-service fake rather than through the UI.

| Surface | Defined in | Kind | Reached by | Platforms | Walk |
|---|---|---|---|---|---|
| Call | `features/call/call_screen.dart:27` | screen | Chat ▸ call button; also the minimised bar ▸ tap | both | yes, via the fake engine |
| Incoming call | `features/call/incoming_call_sheet.dart:29` | overlay | A call arriving | both | yes, via the fake engine |
| Incoming call (full screen) | `features/call/incoming_call_sheet.dart:264` | screen | A call arriving while the screen is locked | mobile | no — a platform full-screen intent |
| Minimised call bar | `features/call/call_overlay.dart` | overlay | Navigate away from an active call | both | yes |
| External call app | `features/call/external_call.dart` | — | Chat ▸ call button on a bridged network | both | no — hands off to another app |

## Settings

One screen with five sections (`features/settings/settings_screen.dart:38`),
reached from ⋮ ▸ *Settings* on touch and from the sidebar's bottom group on
macOS. Every row below is a push from it unless said otherwise.

| Surface | Defined in | Kind | Reached by | Platforms | Walk |
|---|---|---|---|---|---|
| Settings | `features/settings/settings_screen.dart:38` | screen | ⋮ ▸ *Settings* · sidebar ▸ *Settings* | both | yes |
| Merged chats | `features/merge/merge_screen.dart:17` | screen | Settings ▸ *Merged chats* | both | yes |
| Bridges | `features/bridges/bridges_screen.dart:54` | screen | Settings ▸ *Bridges* · ⋮ ▸ *Bridges* · sidebar ▸ *Bridges* | both | yes |
| Add a bridge by domain | `features/bridges/bridges_screen.dart:191` | dialog | Bridges ▸ *Add* | both | yes |
| Bridge sign-in | `features/bridges/bridge_login_flow.dart:30` | screen | Bridges ▸ a detected bridge ▸ *Sign in* | both | yes |
| Bridge bot login | `features/bridges/bot_login_screen.dart:23` | screen | Bridges ▸ a bridge whose flow is a bot conversation | both | yes |
| SMS | `features/settings/sms_screen.dart:30` | screen | Settings ▸ *SMS* | Android only (`settings_screen.dart:111`) | yes on Android |
| Give up the SMS role | `features/settings/sms_screen.dart:248` | dialog | SMS ▸ *Stop being the SMS app* | Android only | yes on Android |
| Notifications | `features/settings/notifications_screen.dart:60` | screen | Settings ▸ *Notifications* | both | yes |
| Open system settings | `features/settings/notifications_screen.dart:905` | dialog | Notifications ▸ a channel whose OS permission is off | mobile | no — needs a denied OS permission |
| Turn on notifications | `features/settings/notifications_screen.dart:935` | dialog | Notifications ▸ the master switch, unasked | mobile | yes |
| Keyboard shortcuts | `features/settings/shortcuts_sheet.dart:18` | panel | Settings ▸ *Keyboard shortcuts* · ⌘/ | desktop only (`settings_screen.dart:41`) | yes on macOS |
| Endpoints | `features/settings/endpoints_screen.dart:24` | screen | Settings ▸ *Search and transcription* | both | yes |
| Models | `features/settings/models_screen.dart:26` | screen | Settings ▸ *Models* · Endpoints ▸ *Models* | both | yes |
| Auto-reply | `features/settings/auto_reply_screen.dart:24` | screen | Settings ▸ *Auto-reply* | both | yes |
| Auto-reply rule editor | `features/settings/auto_reply_screen.dart:235` | screen | Auto-reply ▸ *New rule*, or the pencil beside a rule | both | yes |
| Delete rule | `features/settings/auto_reply_screen.dart:437` | dialog | Auto-reply ▸ a rule ▸ the bin | both | no — a confirmation over the editor, covered by `auto_reply_screen_test.dart` |
| Link previews | `features/settings/link_previews_screen.dart:19` | screen | Settings ▸ *Link previews* | both | yes |
| Devices | `features/settings/devices_screen.dart:23` | screen | Settings ▸ *Devices* | both | yes |
| Rename this device | `features/settings/devices_screen.dart:129` | dialog | Devices ▸ a device ▸ *Rename* | both | yes |
| Confirm sign-out | `features/settings/devices_screen.dart:189` | dialog | Devices ▸ a device ▸ *Sign out* | both | yes |
| Re-authenticate | `features/settings/devices_screen.dart:115` | dialog | Confirm sign-out, when the homeserver asks | both | no — needs a homeserver that demands it |
| Verify a device | `features/auth/verification_screen.dart:18` | screen | Devices ▸ a device ▸ *Verify* | both | yes |
| Encryption | `features/settings/security_screen.dart:21` | screen | Settings ▸ *Encryption* | both | yes |
| Set a passphrase | `features/settings/security_screen.dart:137` | dialog | Encryption ▸ *Set up backup* | both | yes |
| Replace the backup | `features/settings/security_screen.dart:178` | dialog | Encryption ▸ *Set up backup* with one already there | both | yes |
| Backup & restore | `features/settings/backup_screen.dart:77` | screen | Settings ▸ *Backup* | both | yes |
| Choose a passphrase | `features/settings/backup_screen.dart:471` | dialog | Backup ▸ *Create backup* | both | yes |
| Creating backup / Restoring | `features/settings/backup_screen.dart:421` | dialog | Backup ▸ *Create backup* ▸ *Create*; Backup ▸ a restore ▸ *Restore* | both | yes |
| This backup | `features/settings/backup_screen.dart:624` | dialog | Backup ▸ *Choose a file* ▸ a `.braid` file | both | yes, with a faked picker |
| Restore passphrase | `features/settings/backup_screen.dart:569` | dialog | This backup ▸ *Continue* | both | yes, with a faked picker |
| How should this be restored? | `features/settings/backup_screen.dart:677` | dialog | Restore passphrase ▸ *Continue* | both | yes, with a faked picker |
| Delete what is on this device? | `features/settings/backup_screen.dart:756` | dialog | How should this be restored? ▸ *Replace what is here* ▸ *Restore* | both | yes, with a faked picker |
| Restore finished | `features/settings/backup_screen.dart:788` | dialog | Any finished restore | both | yes, with a faked picker |
| Companion surfaces | `features/settings/surfaces_screen.dart:33` | screen | Settings ▸ *Widgets and watch* | both | yes |
| Integrations | `features/settings/integrations_screen.dart:48` | screen | Settings ▸ *Home Assistant and Paperless* | both | yes |
| MCP | `features/settings/mcp_screen.dart:14` | screen | Settings ▸ *MCP server* | both | yes |
| Revoke this key | `features/settings/mcp_screen.dart:73` | dialog | MCP ▸ a key ▸ *Revoke* | both | yes |
| Audit log | `features/settings/mcp_screen.dart:143` | dialog | MCP ▸ *Audit log* | both | yes |

## Surfaces the OS raises

Not reachable by tapping inside Braid, and therefore not in the route walk at
all. They belong to the Patrol suite — see
[`integration_test/patrol/README.md`](../../apps/weft/integration_test/patrol/README.md).

| Surface | Defined in | Raised by |
|---|---|---|
| Share into Braid | `features/share/share_target_sheet.dart:39` | Another app's `ACTION_SEND`, or the iOS Share Extension |
| Notification rationale | `features/notifications/notification_rationale_sheet.dart:18` | The first session that becomes `ready` on a platform that prompts |
| Permission dialogs | — | The OS, on camera and notifications |
| Notification shade | — | The OS |

## Counting

Sixty-one surfaces. Forty-seven are walked; the fourteen that are not each
have a reason in the **Walk** column, and none of them is "we forgot" — they
are pre-session screens, surfaces gated on a real device grant, and the four
the OS raises rather than Braid.

When a phase adds a screen it adds a row here and a step in
`route_walk_test.dart`. The walk fails on a `Scaffold` it cannot reach, which
is the mechanism that keeps this file honest.
