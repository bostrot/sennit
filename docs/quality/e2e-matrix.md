---
type: reference
title: Patrol Device Matrix
created: 2026-08-19
tags:
  - testing
  - patrol
  - e2e
related:
  - '[[A11y-Audit]]'
  - '[[Notifications]]'
  - '[[Share-Surfaces]]'
  - '[[Calling]]'
  - '[[Adr-002-Ios-Signing-Handoff]]'
---

# Patrol Device Matrix

What the device suite is for, what it will run on, and — row by row — which
scenarios apply and which are skipped because the platform does not have the
thing being tested.

This is the target definition, written before any test exists. The last task of
Phase 09 comes back to [Results](#results) and fills it in with what was
actually executed on what. **Nothing below claims a test passes.** Every cell
starts as *not executed*, and a cell only changes because someone watched it
change.

The suite exists for one reason: the last four phases put their risk *outside*
the Flutter view. A share sheet raised by another app, a notification tapped
from the shade, a permission dialog, an `ACTION_SEND` fired by the OS, the
default-SMS role prompt — no `flutter test` can reach any of them, because none
of them is drawn by Flutter. Patrol can, because its native automator drives
UIAutomator and XCUITest alongside the Dart test process.

M10's other half is [[A11y-Audit]], which comes at the same app from the
opposite direction: every screen read line by line, nothing on a device. Between
them they are this phase's whole quality track — one audits what cannot be
executed, the other executes what cannot be audited — and neither has yet met
the thing it is really about. The audit has never been heard through a screen
reader; this suite has never run a row of the matrix below.

One area is outside this matrix on purpose: **calling**. [[Calling]] records
what Phase 07 established — a real 1:1 call placed between two accounts on this
same local Synapse, invite through hangup, in an encrypted room — and the one
thing it could not: no media has ever crossed a peer connection, because the
connection is a fake in every test. A Patrol scenario would not change that.
Two devices with real microphones and a TURN server would, and there is no
`call_test.dart` under `patrol/` because neither is here. `integration_test/
call_test.dart`'s three tests remain where calling's coverage is.

---

## What this phase inherits

### The existing integration tests

`apps/weft/integration_test/` holds three files and **9 tests** on a real
engine:

| File | Tests | Needs |
|---|---|---|
| `matrix_session_test.dart` | 5 | live Synapse |
| `call_test.dart` | 3 | live Synapse |
| `attachment_flow_test.dart` | 1 | a real engine only (`WEFT_DEMO=true`) |

`matrix_session_test.dart` is the one the Patrol suite is descended from, and
four things in its setup are load-bearing enough that the Patrol support helper
must repeat them rather than re-derive them:

1. **Configuration arrives as `String.fromEnvironment`**, not as a `Platform.
   environment` read: `WEFT_HOMESERVER` (default `localhost:8008`) and
   `WEFT_TEST_PASSWORD` (default `weft-test-password`). A compiled Flutter test
   binary on a device has no shell environment to read, which is exactly why it
   is a `--dart-define`. Patrol passes these through `patrol test --dart-define`
   unchanged.
2. **Every session gets its own SQLite *file* under a temp dir**, never
   `inMemoryDatabasePath`. The comment at `matrix_session_test.dart:30-36`
   records why, and it is not a style preference: sqflite caches open databases
   by path, so two sessions asking for `:memory:` in one process are handed the
   same database, the second client restores the first one's stored session, and
   login fails with *"User is already logged in"*. Every two-account scenario in
   this suite (messaging, chat actions, share-in, notifications, merge) is a
   two-session-in-one-process scenario and will hit this immediately.
3. **Sync is driven, not awaited.** `_awaitRoom` and `_awaitMessage` poll with
   `client.oneShotSync()` against a deadline (30 s and 45 s). A device is slower
   than a laptop and an emulator is slower again; the helpers move to
   `patrol/support/` and keep the deadline as a parameter.
4. **The whole encrypted round trip depends on vodozemac being present**, which
   the test asserts rather than assumes (`session.encryptionEnabled`, with the
   reason string *"vodozemac should be available on this platform"*). On Android
   that is the Rust cross-compile from the README's `rustup target add` note, and
   it is the single most likely reason a first Android device run fails in a way
   that looks like a Matrix bug.

Also inherited: the tests currently run with `-d macos` / `-d linux` against a
desktop target. Patrol replaces the runner, not the assertions.

### The disposable homeserver

`tooling/docker/compose.yaml` runs `matrixdotorg/synapse:latest` as
`weft-synapse` on `http://localhost:8008`, with a `curl /health` healthcheck
(3 s interval, 30 retries, 10 s start period) — which is why CI can `up -d
--wait` instead of sleeping. A second server, `synapse-remote` on 8009, exists
behind the `federation` profile and is not needed here.

`seed.sh` registers `@alice:localhost` and `@bob:localhost` with
`register_new_matrix_user` inside the container, password `weft-test-password`,
and is idempotent — a second run prints *"already exists"* and exits 0.

Three facts the `e2e.sh` script in task 2 has to handle, all of which bite on a
clean machine:

- **`tooling/docker/synapse-data/` is gitignored** (`.gitignore:20`). A fresh
  clone has no `homeserver.yaml`, and `compose up` on a missing config fails.
  The generate step from `tooling/docker/README.md` — and the registration block
  CI appends in `ci.yaml:162-172` — are prerequisites, not documentation.
- **`seed.sh` does not create a room.** `tooling/docker/README.md:27-28` says it
  "creates `@alice` and `@bob` … and a shared encrypted room". It does not:
  `seed.sh` is two `register` calls and a here-doc. Nothing depends on the claim
  today, because `matrix_session_test.dart` creates its own room — and every
  scenario here does too, since a test that cleans up after itself cannot share
  a fixture room with the next one. The README line is wrong and should be
  corrected rather than implemented.
- **`register_new_matrix_user` needs `registration_shared_secret`**, which the
  generated config supplies. The local config on this host has the key twice —
  once from `generate`, once from the appended test block — which Synapse
  tolerates but which means the shared secret in the file is not the one anyone
  wrote down.

### The CI shape the device job slots into

`.github/workflows/ci.yaml` is five jobs on `push: [main]` and every
`pull_request`, with `FLUTTER_VERSION: "3.44.0"` in `env` and a
cancel-in-progress concurrency group:

| Job | Runner | What it is |
|---|---|---|
| `analyze` | ubuntu | `dart format --set-exit-if-changed` + `flutter analyze` |
| `unit` | ubuntu | `dart test` over 12 pure packages, named explicitly |
| `widget` | ubuntu | `flutter test` for `weft_matrix`, `weft_store`, `weft_design`, then the app |
| `a11y` | ubuntu | `test/a11y`, `test/goldens`, `weft_design` — a deliberate subset of `widget`, for the report |
| `integration` | ubuntu | Synapse + Linux desktop toolchain + `xvfb-run flutter test integration_test/*_test.dart -d linux` |

Conventions the new `e2e.yaml` should keep rather than reinvent: the
`FLUTTER_VERSION` env pin, `subosito/flutter-action@v2` with `cache: true`,
`actions/upload-artifact@v4` guarded by `if: failure()` and
`if-no-files-found: ignore`, and a *"logs on failure"* step that dumps the
homeserver (`ci.yaml:193-195`). The `integration` job is also the model for the
Synapse setup steps, including the appended `rc_login` rate-limit override —
without it, a suite that logs two accounts in per test trips Synapse's login
limiter and fails in a way that reads like a wrong password.

What CI does **not** have today: any Android, iOS or macOS runner. Every job is
`ubuntu-latest`. The device matrix is entirely new runner surface, which is why
task 6 gates it on `workflow_dispatch` + nightly rather than on push.

> **Landed.** `.github/workflows/e2e.yaml` — see [CI](#ci) for what each job
> does, the macOS UI-test target it needed, and what about it is verified.

### The intents the tests fire from outside

From `apps/weft/lib/app/intents.dart` and
`apps/weft/android/app/src/main/AndroidManifest.xml`:

| Shape | Declared as | Parsed to |
|---|---|---|
| `weft://chat/<id>` | `<data android:scheme="weft"/>`, macOS/iOS `CFBundleURLSchemes` | `OpenChatLink` → pushes `ChatView` |
| `weft://user/<id>` | same | `OpenUserLink` → **debugPrint only, see below** |
| `weft://search?q=…` | same | `OpenSearchLink` → pushes `SearchScreen` |
| `weft://` (bare) | same | `OpenInboxLink` → pops to root |
| `https://weft.bostrot.com/chat/<id>` | `autoVerify="true"` App Link | same as `weft://chat/` |
| `sms:` `smsto:` `mms:` `mmsto:` | `ACTION_SENDTO` filter | `ComposeSmsLink` → pops to root, composer pending |
| `ACTION_SEND` | 7 mime types incl. `text/plain`, `image/*`, `application/*` | `SharedPayload` → share target sheet |
| `ACTION_SEND_MULTIPLE` | `image/*`, `video/*`, `*/*` | same |
| Direct Share tap | `EXTRA_SHORTCUT_ID` → `targetChatId` | share sheet's *confirm* step, chat pre-selected |

`apps/weft/test/intents_test.dart` holds **20 tests**, of which **9** cover
`WeftLink.parse` shapes; the other 11 are `ComposeSmsLink` (7) and
`SharedPayload` (4). (Phase 09's task list says "12 unit tests"; the file is the
authority.) The E2E layer must not re-test parsing — it verifies *delivery*:
that the OS hands the intent to the right activity, that a cold start replays
it, and that the router lands on the screen.

> [!IMPORTANT]
> **`weft://user/<id>` does not navigate.** `main.dart:260-263` matches
> `OpenUserLink` and does nothing but `debugPrint` — the start-chat flow it
> needs does not exist. Task 5 asks that each deep link "lands on the right
> screen". For user links the right screen *is* wherever the app already was,
> and `deeplink_test.dart` must assert that honestly (the link is delivered, the
> app does not crash, no route is pushed) rather than assert a screen the app
> has never opened. Weakening this into a passing navigation assertion would be
> the test lying about a known gap. The same applies to `sms:` links, which
> `main.dart:264-271` pops to root by design.

---

## The matrix

Eleven rows. Six Android, four iOS, one desktop.

| Id | Row | Form factor | Why it is in the matrix |
|---|---|---|---|
| **A28-P** | Android API 28 (9 Pie), phone | phone | The floor. `minSdk` is Flutter's default **24**, so 28 is not the oldest supported — it is the oldest with a *system image worth running*: pre-`MessagingStyle` shortcut behaviour, no notification runtime permission, no scoped storage. |
| **A28-T** | Android API 28, tablet | ≥900 dp | Two-pane inbox (`kTwoPaneBreakpoint = 900`, `inbox_shell.dart:37`) on the oldest API. |
| **A33-P** | Android API 33 (13), phone | phone | `POST_NOTIFICATIONS` becomes a runtime permission here. The single most consequential Android behaviour change for Weft. |
| **A33-T** | Android API 33, tablet | ≥900 dp | Two-pane + runtime notification permission together. |
| **A35-P** | Android API 35 (15), phone | phone | Current. Predictive back, edge-to-edge by default, foreground-service type enforcement (`CallForegroundService` declares `phoneCall`). |
| **A35-T** | Android API 35, tablet | ≥900 dp | Two-pane on current. |
| **I16-P** | iOS 16, iPhone | phone | Oldest in matrix; deployment target is **13.0**, so 16 is a pragmatic floor rather than the true one. |
| **I16-T** | iOS 16, iPad | ≥900 dp | Two-pane on iPadOS. |
| **I17-P** | iOS 17, iPhone | phone | Current-1. |
| **I17-T** | iOS 17, iPad | ≥900 dp | Two-pane on current-1. |
| **MAC** | macOS 11+ desktop | window, resizable | The platform Weft is developed on and the only one where the test process and the app share a machine. |

Deployment targets, for the record: `IPHONEOS_DEPLOYMENT_TARGET = 13.0`,
`MACOSX_DEPLOYMENT_TARGET = 11.0`, `compileSdk = 37`, `minSdk = 24`.

### The macOS row is not a Patrol row

Patrol's own documentation is explicit: *"Platform automation is currently
available on Android, iOS, and Web."* `patrol` 4.9.0 lists macOS among its
supported platforms and `patrol_cli` 4.7.0 can target it, but there is **no
native automator on macOS** — no permission dialog handling, no Notification
Center, no NSOpenPanel driving.

That is not a reason to drop the row. It is a reason to be precise about what it
is: on macOS the suite runs as ordinary `integration_test` widget-level driving
(`$(…)`, `PatrolTester`) against a real engine and a real homeserver, exactly
like `matrix_session_test.dart` does today. Every scenario whose assertions live
inside the Flutter view runs there and runs fast. Every scenario whose *point*
is a native surface is marked N/A for macOS below, and the reason is always the
same one.

One macOS exception worth taking: **deep links can be fired without a native
automator**, because the test process is on the same machine as the app.
`Process.run('open', ['weft://chat/<id>'])` from inside the test delivers a real
OS-routed link to the running app. Warm start only — a cold start is impossible
when the test binary *is* the app process.

### Applicability

`✓` applies · `—` platform-inapplicable (with the reason keyed below) ·
`◐` applies in a reduced form, stated in the scenario section.

| Scenario | A28-P | A28-T | A33-P | A33-T | A35-P | A35-T | I16-P | I16-T | I17-P | I17-T | MAC |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `login_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `messaging_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `chat_actions_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `attachment_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — ①|
| `share_in_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — ② | — ② | — ② | — ② | — ② |
| `permissions_test` | ◐ ③| ◐ ③| ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — ① |
| `notification_test` | ◐ ④| ◐ ④| ✓ | ✓ | ✓ | ✓ | ◐ ⑤| ◐ ⑤| ◐ ⑤| ◐ ⑤| — ① |
| `notification_mute_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — ① |
| `deeplink_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ ⑥|
| `merge_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `search_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `bridges_test` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `mcp_test` | ◐ ⑦| ◐ ⑦| ◐ ⑦| ◐ ⑦| ◐ ⑦| ◐ ⑦| ◐ ⑦| ◐ ⑦| ◐ ⑦| ◐ ⑦| ✓ |

**Skip reasons**

① **No native automator on macOS.** The scenario's assertions are all on
surfaces Flutter does not draw — a system photo picker, a permission alert,
Notification Center. Patrol cannot reach any of them on macOS, so the test would
have to be rewritten into something that no longer tests the thing. Not run
rather than faked.

② **iOS has no share-in.** The Share Extension is not built — `README.md`'s
status table says so, and [ADR-002](../decisions/adr-002-ios-signing-handoff.md)
holds the App Group and bundle ids it needs. There is no `ACTION_SEND` on iOS
and nothing for a test to fire. macOS likewise has no share target. Revisit when
the extension has an Xcode target and a profile.

③ **API 28 has no notification runtime permission.** `POST_NOTIFICATIONS`
arrived in API 33.

> [!NOTE]
> **Superseded in its second half, 2026-08-19.** This reason originally also
> said that API 28's storage half "still applies", because a pre-scoped-storage
> picker would ask for `READ_EXTERNAL_STORAGE`. It does not: Weft's picker is
> `ACTION_GET_CONTENT`, which asks for nothing on *any* API level — see
> [finding 1](#three-findings-that-changed-what-these-tests-can-assert). What
> `permissions_test` exercises across every row is the camera dialog, granted and
> denied, plus the assertion that the gallery raises none. The row stays `◐`
> because the notification permission this reason is really about still does not
> exist on API 28.

④ **API 28 predates the notification surfaces the test asserts on.** Conversation
shortcuts and bubbles are API 30+; `MessagingStyle` exists but is not
conversation-ranked. The shade is still readable and tappable, so the
open-the-right-chat half runs; the shortcut and ranking assertions are skipped
on this row with that reason recorded per test, not per file.

⑤ **iOS notification actions differ, and push is not configured.** Direct reply
from the shade exists on iOS via `UNTextInputNotificationAction` and Weft wires
it, but an iOS *simulator* cannot receive an APNs push and Weft has no push
gateway configured in this repository. What runs on iOS is the
foreground/backgrounded-with-app-alive path that
`flutter_local_notifications` posts locally — real notifications, real taps,
without the gateway leg. The gateway leg is not-executed everywhere, on every
row, and is recorded as such rather than as a pass.

⑥ **macOS runs the deep links and nothing else of this group.** Fired with
`open`, delivered by Launch Services, asserted in the Flutter view. Warm start —
but that is not a macOS limitation: the test process is the app process on
*every* row, so cold start is unreachable throughout and the `◐` here is about
the shade scenarios macOS cannot run at all, not about the links.

⑦ **The MCP tunnel is desktop-only; the loopback server is not.**
`McpHttpServer.start` binds `InternetAddress.loopbackIPv4` via `shelf_io.serve`,
which works in an app process on Android and iOS. The Cloudflare tunnel is
`Process.start('cloudflared', …)` (`cloudflared.dart:81`) — iOS forbids spawning
subprocesses outright and Android has no such binary. On mobile rows
`mcp_test` covers server start, the authenticated request, the rejected
unauthenticated one, and the audit entries; the tunnel is asserted to be
*stopped and untried*, not exercised.

> [!NOTE]
> **Corrected, 2026-08-19.** This originally said the tunnel toggle would be
> asserted "absent or disabled". It is neither. `_TunnelTile` is rendered on
> every platform as soon as the server is running, with an enabled **Start**
> button, and pressing it on a phone reaches `Process.start('cloudflared', …)`
> — which iOS forbids outright. What `mcp_test` asserts is what is true: the
> tunnel reads *"Off. Requires cloudflared on this machine."* and Weft has not
> tried to start it, because `start()` only reaches the supervisor when
> `mcp.tunnel_enabled` says so and it does not by default. Hiding the control
> where it cannot work is a product decision, not a test fixture.

---

## The scenarios

Thirteen files under `apps/weft/integration_test/patrol/`, holding **39
scenarios** between them, plus a shared `patrol/support/` and a
`harness_test.dart` that is not a scenario — it is the two checks that answer
"is any of this real". Each file is independently runnable and cleans up the rooms it
made — a failed run must not poison the next one, which on a shared homeserver
means leaving no room and no lingering device behind.

### Core messaging

**`login_test.dart`** — homeserver discovery against `localhost:8008` (and
`10.0.2.2:8008` from an Android emulator, see [Addressing](#addressing-the-homeserver-from-a-device)),
login as `@alice`, device verification, logout leaving no session. The wrong-
password path is already covered by `matrix_session_test.dart:106`; here it is
the *screen* that must show it.

**`messaging_test.dart`** — two accounts, encrypted room, message both ways.
Asserts delivery-state transitions (sending → sent → delivered), read receipts,
and that the recipient's inbox reorders. Two sessions in one process: see the
sqflite trap above.

**`chat_actions_test.dart`** — reply, react, edit, redact (Phase 05), each
asserted on the *peer's* timeline, not only locally.

### Attachments and media

**`attachment_test.dart`** — the real system gallery picker, upload progress
bubble, settled bubble, full-screen viewer, hand back to the platform. Needs a
seeded image in the device gallery; `e2e.sh` pushes one (`adb push` /
`simctl addmedia`) before the run, because an empty gallery is a hang rather
than a failure. Written up in
[The attachment and media scenarios](#the-attachment-and-media-scenarios) —
which also records why it does *not* go through
`native.pickImageFromGallery()`, and why "save back out" is Share on a phone.

**`share_in_test.dart`** — `ACTION_SEND` with a file URI routed by the OS,
share-target sheet appears, chat selected, message arrives on the peer. Then
`SEND_MULTIPLE`. Android rows only. The chooser is raised through Weft's own
`SharePlus` call, because a device-side test cannot fire an arbitrary intent;
[finding 2](#three-findings-that-changed-what-these-tests-can-assert) is exact
about what that does and does not weaken.

**`permissions_test.dart`** — the native dialog handled by the automator,
including the **deny** path leaving the app usable. Deny is the half that
matters: an app that only works when every dialog is accepted has untested error
surface exactly where users are most cautious. The dialog is the *camera's* —
Weft's pickers raise none at all, and that absence is asserted rather than
assumed.

Across all three: **assert on the peer's received event**, not on local UI. A
silently-failed upload renders a perfectly convincing local bubble.

### Notifications and deep links

Written up in
[The notification and deep-link scenarios](#the-notification-and-deep-link-scenarios),
which records the precondition none of this had before — that a device has to be
*cross-signed*, not merely verified, before Weft posts anything at all.

**`notification_test.dart`** — background the app, peer sends, notification
appears in the shade, tap it, the right conversation opens. Then direct-reply
and mark-as-read from the shade. All three Android actions bring Weft to the
foreground by design (`README.md`) — the test asserts that, it does not work
around it. The *merged* half of "the correct merged conversation" belongs to
`merge_test`; what this asserts is that the tap follows the link rather than the
inbox's top row.

**`notification_mute_test.dart`** — a muted chat produces nothing; an explicit
mention in a mentions-only chat produces one. Asserting an *absence* needs a
bounded wait and a positive control in the same test, or it passes when
notifications are broken entirely.

**`deeplink_test.dart`** — `weft://chat/<id>`, `weft://user/<id>` and
`weft://search?q=` fired from outside as real `ACTION_VIEW`s. Reuses the shapes
from `intents_test.dart` and verifies delivery, not parsing. See the callout
above about `user/` and `sms:`. **Warm start only, on every row** — not just on
macOS: a Patrol test runs inside the app under test, so killing Weft to make a
cold start kills the test. Recorded as not-executed rather than approximated.

### Merge, search, bridges, MCP

Written up in
[The merge, search, bridge and MCP scenarios](#the-merge-search-bridge-and-mcp-scenarios),
which records the prerequisite the Android matrix did not have — that Weft could
not have opened a cleartext socket to the homeserver from *any* Android row — and
the three services that are answered by a loopback stub inside the app's process.

**`merge_test.dart`** — two source chats for one contact produce a suggestion
with visible evidence; accept collapses them into one correctly ordered thread;
unmerge restores both. The ordering assertion is the watermark invariant from
`MergedTimeline` seen from the outside. The peers are registered per scenario
rather than seeded, because a merge decision outlives the app and two fixed peers
make the unmerge scenario poison the suggestion one on the next run.

**`search_test.dart`** — send, query, assert hybrid search returns them.
Includes a voice message with a transcript, to prove transcript indexing end to
end. Transcription needs an STT endpoint; one is stood up on loopback, so the
transcript leg is written rather than deferred — what it does not prove is
anything about speech recognition.

**`bridges_test.dart`** — the bridges screen renders health probes against the
local homeserver, and the QR login flow shows both a rendered QR and a copyable
payload. **No bridge runs in `tooling/docker`** (`tooling/docker/README.md:36-43`
— the mock bridge is still outstanding), so the *unreachable* probe is answered
by Synapse itself, which is a genuine socket and a genuine Matrix error, and the
reachable one by a provisioning-v3 stub in this process.

**`mcp_test.dart`** — start the server from settings, authenticated request
succeeds on the loopback endpoint, unauthenticated is rejected 401. Tunnel per
skip reason ⑦.

> **"Both appear in the audit view" is not true.** Auth is checked in the
> transport and the audit log is written by the registry, so a 401 never reaches
> the thing that writes an entry. The scenario asserts the absence and produces
> the denial the log *can* show — see
> [finding 1](#five-findings). It is a gap in the feature, not in the test.

### Addressing the homeserver from a device

Not a scenario, but the thing that will break first. `localhost:8008` means the
*device's* loopback, not the host's:

| Row | Homeserver URL |
|---|---|
| Android emulator | `10.0.2.2:8008` — the emulator's alias for the host loopback |
| Android physical device | the host's LAN address, `adb reverse tcp:8008 tcp:8008` for loopback |
| iOS simulator | `localhost:8008` — the simulator shares the host network stack |
| iOS physical device | host LAN address; no `adb reverse` equivalent |
| macOS | `localhost:8008` |

Weft resolves a bare host to `http` for loopback (`matrix_session_test.dart:63-68`
asserts it); `10.0.2.2` is not loopback by that rule, so the scheme handling
needs checking on the first Android run rather than assuming.

---

## The harness

Landed 2026-08-19. Six pieces, listed with what was verified and — where it was
not — what would verify it.

| Piece | Where | Verified by |
|---|---|---|
| `patrol` dev dependency | `apps/weft/pubspec.yaml` | `flutter pub get`, `flutter analyze` |
| Patrol config | `apps/weft/pubspec.yaml`, `patrol:` block | read against `patrol_cli`'s own `pubspec_reader.dart` |
| Dart suite root | `apps/weft/integration_test/patrol/` | `flutter analyze` clean |
| Android instrumentation | `android/app/src/androidTest/…/MainActivityTest.java`, `android/app/build.gradle.kts` | **not built here** — needs a Gradle instrumentation build |
| iOS UI-test target | `ios/Runner.xcodeproj`, `ios/RunnerUITests/RunnerUITests.m`, `ios/Podfile` | `xcodebuild -list` sees the target; **not compiled** — no simulator runtime, no signing identity |
| One-command runner | `tooling/scripts/e2e.sh` | run end to end against the live container with a stubbed `patrol` |

### Resolved versions

`patrol` added no version pressure at all: five packages entered the lock and
**not one existing package changed version**. The `analyzer` conflict that cost
this workspace ObjectBox and Drift did not recur, and the reason it did not is
structural rather than lucky — `patrol`'s closure contains no analyzer, and
`patrol_cli`, which does contain a command-line toolchain, is a global
executable that must never appear in a pubspec.

| Package | Version | How it arrived |
|---|---|---|
| `patrol` | 4.9.0 | direct dev dependency |
| `patrol_finders` | 3.6.0 | via `patrol` |
| `patrol_log` | 0.10.1 | via `patrol` / `patrol_finders` |
| `dispose_scope` | 2.1.0 | via `patrol_log` |
| `equatable` | 2.1.0 | via `patrol` and `patrol_log` |
| `patrol_cli` | 4.7.0 | **global tool**, `dart pub global activate patrol_cli` — not installed on this host |

`patrol` 4.9.0 wants `sdk >=3.8.0 <4.0.0` and `flutter >=3.32.0`; this project is
Dart 3.12.0 / Flutter 3.44.0, so both are satisfied with room. `patrol_cli`
4.7.0 wants the same SDK range.

### Three decisions worth knowing about

**The suite is not in `patrol_cli`'s default directory.** `patrol_cli` 4.7.0
defaults `test_directory` to a top-level `patrol_test/`; the pubspec sets it to
`integration_test/patrol` instead. That keeps the device suite beside the
integration tests it descends from, and — the load-bearing half — out of reach
of `flutter test integration_test`, which the `integration` CI job already runs
and which cannot execute a Patrol test. Because the directory is not one of
`patrol_cli`'s known roots it also generates an entrypoint proxy at
`integration_test/patrol_test_bundle.dart`; that name does not end in
`_test.dart`, so `flutter test` skips it. Both generated files are gitignored.

**CocoaPods, not Swift Package Manager.** `patrol_cli` 4.7.0's headline feature
is SPM support and its iOS setup guide leads with it. This project has SPM
disabled — `flutter_vodozemac`'s xcframework loses its `Versions/Current`
symlink through the SPM path and code signing breaks — so `RunnerUITests` is
wired through the Podfile with `inherit! :complete`. `:complete` and not
`:search_paths` because, unlike `RunnerTests`, this target *links* patrol:
`RunnerUITests.m` is `@import patrol;` and a macro expansion. Patrol's guide also
adds `use_modular_headers!`; it is deliberately omitted, because `use_frameworks!`
already builds every pod as a module and turning it on would change how the
whole verified pod graph is built.

**The existing `integration` job had to change.** `flutter test integration_test`
recurses, so the new directory would have been swept into the job that already
runs on every push — and a Patrol test cannot survive that. `patrolTest` calls
`PatrolBinding.ensureInitialized` while the file is being *loaded*, and that is a
Live binding; the automated binding `flutter test` installs cannot coexist with
it. The failure is a binding conflict at load time, so it takes the whole run
down rather than one file, and `--exclude-tags` cannot prevent it because
registration has already happened by then. `ci.yaml` now runs
`integration_test/*_test.dart`, which is the same three files and picks up new
top-level ones without further edits. The same glob is now in `README.md` and in
`matrix_session_test.dart`'s header, because the old command is broken as
written.

`patrol` does offer a `PATROL_TEST_DISCOVERY` dart-define that turns every test
body into a no-op so a host run can register them. It is deliberately not used:
it would make thirteen device scenarios report **green** on a Linux CI runner
that executed none of them, which is precisely the failure mode this document
exists to prevent.

### What the iOS target still needs

Authored and unsigned, per Phase 09's own instruction. `RunnerUITests` carries no
`DEVELOPMENT_TEAM`, and a UI-test bundle needs its **own** provisioning profile —
distinct from the app's and from the two extensions' — because it installs as a
second application alongside the app under test. Until that exists the four iOS
rows are *not executed* rather than failing, and no amount of harness work moves
them. See [ADR-002](../decisions/adr-002-ios-signing-handoff.md).

Also unverified for the same reason: that `@import patrol;` resolves under
`use_frameworks!` without `use_modular_headers!`. It is the reasoned choice, not
a compiled one, and the first `pod install` on a machine with an SDK will say.

---

## The core scenarios

Landed 2026-08-19: `login_test.dart` (3), `messaging_test.dart` (3) and
`chat_actions_test.dart` (4) — ten scenarios over a shared `support/`.

**None of them has been executed.** `patrol_cli` is not on this host and no
matrix row is runnable here; the whole of what was verified is
[below](#what-was-verified-and-what-was-not). Every cell in [Results](#results)
stays *not executed*.

### The shape

The app is signed in as `@alice` and driven entirely through its own screens.
The other participant is a headless `WeftMatrixSession` in the same process, and
so is a *second* session of the app's own account. Every scenario asserts at both
ends: a send is checked on the peer's timeline as well as in the app, because a
silently-failed send renders a perfectly convincing local bubble, and a read is
checked as a receipt the peer receives, because "the badge went away" is a
statement about one device.

### Four things the app cannot do, which the suite had to work around

Each is a real gap, found while writing against the app rather than around it.
None is fixed here — three belong to later phases and one to a later task.

1. **Weft cannot start a conversation, and cannot accept an invitation.** The
   start-chat flow behind `OpenUserLink` does not exist, and nothing anywhere in
   the app reads `Membership.invite` — `MatrixChatRepository` renders every room
   the client knows about without distinguishing an invitation from a joined
   room. So a scenario cannot make a conversation through the UI at all. The
   suite's answer is `TestAccount.control`, the app account's own second
   session: it creates the room, which makes the app's device a member from the
   first moment rather than an invitee. Ordering is load-bearing — the app must
   be signed in *before* the room is made, or its device keys have not been
   published and the peer shares its megolm session with every device except the
   one under test.
2. **`DeliveryState.read` is unreachable in the live path.** `_deliveryFor`
   (`mapping.dart:349-359`) maps event status to sending / sent / delivered /
   failed and nothing anywhere applies a read receipt to it, though the comment
   beside it says read state "is applied separately". The word `Read` therefore
   exists in `deliveryStateLabel`, in the demo repository and in the goldens, and
   never on a real message. `messaging_test` asserts the sequence is monotonic
   and ends at `Delivered`; it does not assert a `Read` tick the app has never
   drawn.
3. **A read receipt is sent from one place only.** `markRead` is called by the
   inbox row's tap handler and by the selection bar, so a message that arrives
   while its conversation is already open is never receipted. `messaging_test`
   sends before opening the chat for that reason, and its header says so rather
   than the test looking like it chose an order arbitrarily.
4. **An unverified session never starts notifications.** `main.dart:299-315`
   starts the notification service on `WeftSessionState.ready` only, and a device
   that skipped verification stays `unverified` indefinitely — so no pusher is
   registered and no notification is posted. This one matters to task 4 rather
   than here: `notification_test` must verify the device first, or it will be
   asserting on a shade that Weft was never going to write to.

### Where the assertions come from

Three of them read an *accessible name* rather than a pixel, and that is a
deliberate reuse of what the a11y phase built rather than a shortcut around
missing test keys:

| What | Where it is read | Why nothing else would do |
|---|---|---|
| A refused sign-in | the banner's live region, `Sign-in failed. …` | `_ErrorBanner` is private and its message is one `Text` among several |
| A delivery state | the bubble's meta node, `Sent 14:32, Delivered` | delivered and read are the same 13dp glyph in two colours |
| The SAS emoji | `SasEmojiCell.name` | the comparison *is* the seven names, in order, on both devices |

Everything else is found by what is on screen. Two finders are worth naming
because they are what make a two-pane row work at all: a message bubble is the
only `WeftFocusable` Weft builds with `button: false` — it is a group, not a
control — which separates it from the inbox row beside it that contains the same
words; and the composer is the last `TextField` in the tree, because the panes
run rail, inbox, conversation and the inbox's search box is an `InputDecorator`
with nothing inside it.

### What was verified, and what was not

| Checked | How |
|---|---|
| The suite analyses and is formatted | `flutter analyze` clean, `dart format --set-exit-if-changed` clean |
| Nothing existing regressed | `flutter test` in `apps/weft`, **915 pass** |
| Every app symbol the suite reaches still exists | the analyzer, against `weft`, `weft_design`, `weft_matrix`, `weft_domain` and `matrix` 10.1.0 |
| The macOS app builds with Patrol linked in | `flutter test -d macos` built `weft.app` with the `patrol` pod and `CocoaAsyncSocket`; `macos/Podfile.lock` now records it |
| **Not** checked: anything the tests assert | no row was executed — see below |

**`flutter test -d macos` cannot run a Patrol test either.** Worth recording,
because it is the obvious shortcut and it does not work: the flutter tool's
device runner initialises `IntegrationTestWidgetsFlutterBinding` before the test
file is loaded, and `PatrolBinding` is a `LiveTestWidgetsFlutterBinding` —

> `Failed assertion: '_debugInitializedType == null': Binding is already
> initialized to IntegrationTestWidgetsFlutterBinding`

`--dart-define=PATROL_HOT_RESTART=true` does not help; it skips the wait for a
native execution request, not the binding. Even the macOS row therefore needs
`patrol_cli`, which is a global tool this host does not have. That is a decision
for task 7, along with the Android system images.

---

## The attachment and media scenarios

Landed 2026-08-19: `attachment_test.dart` (3), `share_in_test.dart` (3) and
`permissions_test.dart` (2) — eight scenarios over the same `support/`, which
grew two files: `media.dart` (the pickers, the upload bubble, the native
surfaces, the share sheet) and `scenario.dart` (the app-plus-peer-plus-room
opening that the first three files each had a private copy of, now written once
and used by all five).

[[Share-Surfaces]] is the architecture these three exercise from the outside:
the Android `SEND`/`SEND_MULTIPLE` filters, the staged copy a `content://` URI
is streamed into, the share-target sheet, and the iOS Share Extension that does
not exist yet — which is skip reason ② and the reason `share_in_test` is an
Android-only file.

**None of them has been executed**, for the reasons already recorded: no
`patrol_cli` on this host and no runnable matrix row. What *was* run here is
[below](#what-was-verified-for-these-scenarios).

### Three findings that changed what these tests can assert

**1. Weft does not open Android's photo picker, and therefore never asks for a
storage permission.** `AttachmentPicker.pick` calls
`ImagePicker().pickMultipleMedia()`; `ImagePickerAndroid.useAndroidPhotoPicker`
is `false` by default and Weft never sets it, so the intent is
`ACTION_GET_CONTENT` with `EXTRA_ALLOW_MULTIPLE` — the Storage Access Framework,
served by **DocumentsUI**, on API 28 and API 35 alike. The manifest declares
neither `READ_EXTERNAL_STORAGE` nor `READ_MEDIA_IMAGES`. iOS is the same shape
for the same reason: `PHPickerViewController` is out-of-process and prompts for
nothing.

That retires skip reason ③'s premise about the storage half of
`permissions_test`: there is no storage dialog on any row, not because API 28
predates something but because the app does not use a permission-gated picker at
all. `permissions_test` asserts the *absence* — a picker that prompts is a
picker Weft did not mean to open — and exercises grant and deny against the
permission Weft genuinely does raise here, `CAMERA`. `image_picker` requests it
whenever the manifest declares it, and Weft's declares it for calls.

It also breaks Patrol's own helper on the newest rows: `AutomatorServer`'s
default gallery selectors are DocumentsUI resource ids below API 34
(`com.google.android.documentsui:id/icon_thumb`) and photo-picker ids from 34 up
(`com.google.android.providers.media.module:id/icon_thumbnail`). On A35 rows
`native.pickImageFromGallery()` would wait for a picker Weft never opened.
`support/media.dart`'s `pickFirstPhoto` taps DocumentsUI directly instead, on
every API level.

*Not fixed here, and worth someone's attention:* a messenger whose "Photo or
video" row opens the file browser rather than the photo grid on Android 13+ is a
product decision that looks like an oversight. Turning `useAndroidPhotoPicker`
on is one line — and it would change what these two tests drive, which is why it
is a decision rather than a drive-by.

**2. There is no way to fire an arbitrary intent from a device-side test, so the
share-in scenarios raise the chooser through Weft itself.** `am start` needs a
shell the compiled test binary does not have; Patrol's automator exposes
`openUrl`, which is `ACTION_VIEW`. What it can do is ask the platform to *begin*
a share — the same `SharePlus` call `PlatformMediaExporter.share` makes — and
then tap Weft in the system chooser with the native automator.

The seam is exactly one thing: the originating application is Weft rather than a
third party. Everything downstream is the OS's and is exercised in full —
resolving against the manifest's `ACTION_SEND` / `ACTION_SEND_MULTIPLE` filters,
the `content://` grant the app cannot read unless it is given it, starting
`MainActivity`, `onNewIntent` on a `singleTop` activity, the platform side's copy
out of the grant, and the sheet Dart draws over the result.

Two risks the first Android run will settle, recorded rather than assumed:
Android's Sharesheet is expected to list the calling app (nothing sets
`EXTRA_EXCLUDE_COMPONENTS`), and `MainActivity` carries `taskAffinity=""`, so a
chooser launching it with `FLAG_ACTIVITY_NEW_TASK` may create a second activity
rather than reaching `onNewIntent` on the instrumented one. If it does, that is a
finding about Weft's share-in on *every* sharing app, not a harness problem to
work around.

**3. "Save it back out" is Share on a phone, and that is the app being right.**
`MediaExporter.canSave` is `false` on Android and iOS — `file_selector` has no
save dialog there — and the viewer reads the flag rather than offering a button
that throws. So `attachment_test` asserts the Save action is *absent* and that
Share hands the file to a window the OS owns. The desktop Save dialog belongs to
the MAC row, which does not run this scenario at all (skip reason ①).

### What each scenario does

| File | Scenarios |
|---|---|
| `attachment_test.dart` | gallery pick → preview → upload bubble → settled picture → peer holds an encrypted `m.image`; viewer opens, Save is absent, Share reaches a system window; a photo keeps its place in the order between two typed messages |
| `share_in_test.dart` | one file through the chooser into the share sheet and onto the peer; `SEND_MULTIPLE` arriving as two events in the order shared; a caption typed on the confirmation step landing *before* its file |
| `permissions_test.dart` | the gallery pick raising no permission dialog at all; the camera denied → *"Could not open the picker."* → the conversation still sends, then asked again and granted → `takeCameraPhoto` → the peer holds the photo |

Two constraints the scenarios are shaped around:

- **The gallery must not be empty.** A test process on a device has no `adb` and
  no `simctl`, so `tooling/scripts/e2e.sh` pushes the app's own 512pt icon to
  `/sdcard/Pictures/weft-e2e-photo.png` and fires
  `MEDIA_SCANNER_SCAN_FILE` (or `simctl addmedia` on an iOS simulator). The name
  reaches the suite as `--dart-define=WEFT_SEEDED_PHOTO`, so the script owns it
  and the two cannot drift.
- **Permission state outlives a test.** A grant survives `adb install -r`, and so
  does a denial. `permissions_test` therefore does deny-then-grant in one
  scenario — the only order that is true of a device in any state except
  "already granted" — and `e2e.sh` now runs `pm clear` before the suite so that
  state is the one the scenario expects.

### What was verified for these scenarios

| Checked | How |
|---|---|
| The suite analyses and is formatted | `flutter analyze` clean (including no deprecated `$.native` use — the suite is on `platformAutomator`), `dart format --set-exit-if-changed` clean |
| Nothing existing regressed | `flutter test` in `apps/weft`, **915 pass**, unchanged |
| The gallery seeding actually indexes the photo | run against the live emulator: after the broadcast, `content query --uri content://media/external/images/media` returns `weft-e2e-photo.png, image/png, 36406`. API 36 — the broadcast receiver long predates API 28, but 28/33/35 were not run |
| `e2e.sh` drives the new device steps | run end to end against the live container with a stubbed `patrol`: homeserver healthy, accounts seeded, `pm clear`, photo pushed and scanned, and the emulator row resolved to `http://10.0.2.2:8008` with all three `--dart-define`s |
| **Not** checked: anything the eight scenarios assert | no row was executed |

---

## The notification and deep-link scenarios

Nine scenarios across `notification_test.dart` (3),
`notification_mute_test.dart` (2) and `deeplink_test.dart` (4), over the same
`support/`, which grew two files: `verification.dart` — how this device becomes
trusted, which turns out to be the precondition for posting anything at all —
and `shade.dart`, the notification shade itself. Nothing here was executed.

[[Notifications]] is what these nine assert against: the pusher registration,
the sync-and-push pipeline, the per-network channels, `MessagingStyle` and the
conversation shortcut, the decision layer's suppression rules, and the tap
routing that has to survive a merged chat. Everything in that document is
covered by 61 + 78 unit and widget tests and by one hand-driven session on a
device; what these scenarios add is the half only the OS can answer — that the
shade really received it, that a tap really routed, that a reply typed into the
shade really became an encrypted event. **None of that has run.**

> [!NOTE]
> **Count corrected, 2026-08-19.** This section said "eight scenarios"; the
> three files hold **nine** `patrolTest` bodies. The tree is the authority, and
> the [Results](#results) table below is built by reading it rather than by
> adding up the prose.

### The finding that reshaped the whole task

Task 3 recorded that "an unverified session never starts notifications" and
that `notification_test` "must verify the device first". The first half is
right and the second half does not work.

`main.dart:299-315` starts the notification service on `WeftSessionState.ready`
and on no other state, and `WeftMatrixSession.needsVerification`
(`session.dart:226-235`) asks whether **our own** device key reads as
`verified`. `DeviceKeys.verified` is `directVerified || crossVerified`
(`device_keys_list.dart:173`). An interactive verification sets neither of them
for the local device: `_verifyKeys` marks the keys the **other** end sent
(`key_verification.dart:786`) — its device key, and its master key when it has
one — and never one's own. On an account with no cross-signing identity, which
is every account `tooling/docker/seed.sh` registers, there is therefore *no
route at all* from `unverified` to `ready`, and a scenario that verified against
a plain second session would have waited out its deadline on an empty shade.

What does work is the route a user takes, in three steps:

1. **The control session mints a cross-signing identity**
   (`TestAccount.enableCrossSigning`, which is `MatrixKeyBackup.createRecovery`
   — the same call the Encryption screen's *Set up a recovery key* makes). It
   now holds the private halves.
2. **The app drives an emoji comparison against it** through its own devices
   screen. Two things follow from one exchange: the app verifies the account's
   *master* key, and the control — whose cross-signing keys are cached, so
   `crossSigning.sign` runs rather than `askSSSS`
   (`key_verification.dart:805-810`) — signs the app's device with the
   self-signing key. That is a valid chain, so `crossVerified` becomes true.
3. **Weft is restarted.** Nothing re-derives the session state in place:
   `_emit(_deriveState())` is called from `initialize()` and from the login-state
   stream and nowhere else (`session.dart:114,186,202`), so a device that becomes
   verified while the app is running stays `unverified` to every listener.

`makeSessionReady` does all three, reads the devices list first so an already
verified device skips them, and asserts the verification gate is gone after the
restart — because that assertion is the one that fails loudly if any link in the
chain above is wrong. `ChatScenario.start(notifying: true)` wraps it and takes
the OS permission.

### Four more findings

1. **A pump while Weft is backgrounded is a hang, not a failure.**
   `LiveTestWidgetsFlutterBinding.pump` schedules a frame and awaits a completer
   that only a *drawn* frame completes
   (`flutter_test/src/binding.dart:2994-3016`), with no timeout on it. A stopped
   Android activity draws nothing. Every wait between `backgroundApp` and Weft
   coming back therefore runs on a `Timer`, and `backgroundApp` registers a
   teardown that foregrounds the app so the *next* scenario's launch does not
   hang instead. The same argument applied to `media.dart`'s existing
   `awaitForeignWindow` / `awaitWeftForeground`, which waited by pumping while
   another application owned the screen; both now wait on a timer.
2. **Patrol's `getNotifications()` can legitimately return nothing.** It reads
   `android:id/title` and `android:id/text` (`Automator.kt:558-570`), the ids of
   the *classic* notification layout. Weft posts `MessagingStyle` with a
   `shortcutId`, which from API 30 SystemUI draws with the conversation layout
   and ids of its own. `shade.dart` reads `getNativeViews` instead and matches
   against every string on screen; `getNotifications()` survives only as the
   contents of a failure message.
3. **There is no per-chat mentions-only control.**
   `ChatNotificationOverride.mentionsOnly` exists, `evaluateNotification` reads
   it, and `notifications_screen.dart` promises that "a single chat can disagree
   with this from its own screen" — but nothing in `lib/` ever writes one. The
   scenario drives the global switch, which reaches the same rule
   (`rules.dart:734`). Recorded rather than implemented: adding the control is a
   product decision, not a test fix.
4. **Cold start is unreachable from a Patrol test, on every row.**
   `PatrolJUnitRunner.setUp` launches the app once, in `@Parameters`, and every
   Dart test runs in that process; killing Weft to make the next link a cold
   start kills the isolate the test is running on. So `deeplink_test` fires real
   `ACTION_VIEW`s at a running Weft — `Automator.kt:139-146` starts a genuine
   `Intent.ACTION_VIEW` with `CATEGORY_BROWSABLE` from the instrumentation's
   context, resolved by the system against the manifest's `weft` scheme filter —
   and the cold-start half is recorded as not-executed rather than approximated.
   What is uncovered by it is one join: `MainActivity` stashing the launching
   intent (`MainActivity.kt:41-44`) and `WeftIntents.deliverInitialIntent`
   replaying it.

### What each scenario does

| File | Scenarios |
|---|---|
| `notification_test.dart` | a backgrounded Weft posts a message to the shade under the conversation's title, and tapping it opens *that* conversation rather than the newer one beside it; a reply typed into the shade's own field arrives on the peer and marks the chat read; *Mark read* posts an `m.read` the peer receives and takes the notification down |
| `notification_mute_test.dart` | a muted conversation stays out of the shade while an unmuted one in the same window does not; mentions-only silences ordinary chatter and lets a message naming `@alice:localhost` through |
| `deeplink_test.dart` | `weft://chat/<id>` opens that conversation; `weft://search?q=` opens search on that query; `weft://user/<id>` is delivered and pushes nothing, which is what the app does today; a chat link this account cannot resolve reports itself rather than crashing the router |

Three constraints the scenarios are shaped around:

- **Every absence is asserted beside a presence.** Suppression leaves no trace,
  so "no notification appeared" is equally true of a working mute and of a
  notification path that never ran. `expectShadeSilent` sends the control first,
  waits for *it* to reach the shade, and only then believes the silence.
- **The muted message must not be a mention.** `mentionsBypassMute` defaults to
  true and its switch says why — "mute a busy group and still get paged in it" —
  so asserting silence on a mention would be asserting a bug.
- **No conversation is opened before the app goes away.**
  `evaluateNotification`'s `alreadyRead` rule suppresses anything not newer than
  the read marker, and Weft posts a receipt from the inbox row's tap handler.

### What is not asserted, and why

- **The killed-process path.** Weft notifies from sync while it is running;
  being notified while *closed* needs sygnal and a Firebase project, neither of
  which exists here. These scenarios background the app rather than killing it.
  The gateway leg is not-executed on every row.
- **That the conversation a tap opens is a *merged* one.** The link is
  `weft://chat/<Chat.id>` and for a merged contact that id is
  `merged:<contactId>`; building the merge is `merge_test`'s subject. What is
  asserted here is the property the merged case rests on — the tap lands in the
  conversation the message arrived in, and a second conversation is in the inbox
  so a router that ignored the link has somewhere wrong to go.
- **Notification actions on iOS.** Weft registers
  `UNTextInputNotificationAction` and it is a real feature there, but reaching it
  means long-pressing a banner and Patrol exposes no such gesture. The iOS rows
  run the tap scenario and skip the two action scenarios, which is skip reason ⑤.

### What was verified for these scenarios

| Checked | How |
|---|---|
| The suite analyses and is formatted | `dart analyze integration_test/patrol` clean, `dart format --set-exit-if-changed` clean |
| Nothing existing regressed | `flutter test` in `apps/weft`, **915 pass**, unchanged |
| `login_test` still owns its verification scenario | the emoji drive moved to `support/verification.dart` and `login_test` calls it; every assertion it made is still made, in the same order |
| **Not** checked: anything the eight scenarios assert | no row was executed — `patrol_cli` is not on this host and no matrix row is runnable |

---

## The merge, search, bridge and MCP scenarios

Twelve scenarios across four files, closing the suite. **Nothing was
executed** — `patrol_cli` is still not on this host and no matrix row is
runnable — but rather less of this rests on inspection than the three sections
above it: three of the four files talk to a service, all three services are
`HttpServer`s inside the app's process, and `apps/weft/test/e2e_stubs_test.dart`
drives every one of them with Weft's own client on every push.

### One prerequisite the Android matrix did not have

**Weft could not have reached the homeserver from any Android row.** Weft targets
API 36; from API 28 the platform's default network security config sets
`cleartextTrafficPermitted="false"`, and the merged debug manifest carried
neither a `usesCleartextTraffic` attribute nor a `networkSecurityConfig` —
nothing in the Flutter embedding or in any plugin supplies one. Every connection
to `http://10.0.2.2:8008` would have failed with *"CLEARTEXT communication to
10.0.2.2 not permitted by network security policy"*, which surfaces as a
homeserver that appears never to have come up: the wrong diagnosis, on every
scenario, on every Android row.

`android/app/src/debug/AndroidManifest.xml` now sets it, and the merge was
verified rather than assumed — `:app:processDebugManifest` produces a manifest
carrying `usesCleartextTraffic="true"`, and `:app:processReleaseManifest`
produces one that still does not. Debug only is the point: Patrol installs the
debug variant, so the whole suite is covered, and a release Weft refusing
cleartext is the correct default for a messenger and not something a test
harness should relax.

### Three services that do not exist, answered in this process

A mautrix bridge, a Whisper endpoint and an embeddings endpoint. Weft hosts none
of them by design and `tooling/docker` runs none of them; waiting for all three
is waiting forever, and asserting nothing is worse.
`integration_test/patrol/support/stubs.dart` binds an `HttpServer` to the
device's own loopback — the test process *is* the app's process — and answers
them. The division is stated in the file and holds throughout:

- **Everything on Weft's side of the socket is real** and is what is being
  asserted: the settings screen, the provider built from it, the `http` client,
  the multipart encoder, the JSON decoding, the error mapping, the queue, the
  index, the widget that draws the answer.
- **The other side is not a bridge, a model or a GPU.** The stub decides what a
  QR payload is, what a clip says and which two sentences are neighbours. No
  assertion depends on the quality of any of those answers.

`test/e2e_stubs_test.dart` closes the loop that a device would otherwise have to:
seven tests, run on every push with no device, driving `BridgeProvisioningClient`,
`OpenAiCompatibleTranscriptionProvider` and `OpenAiCompatibleEmbeddingProvider`
against the stubs over a real socket. A wire-shape mistake fails there in a
minute instead of on a device in an afternoon.

### Five findings

1. **`mcp_test`'s brief is not achievable as written, and the reason is a real
   gap.** The task asks that an authenticated request and an unauthenticated one
   *both* appear in the audit view. They cannot. Auth is checked in the
   transport and the audit log is written by the registry:
   `WeftMcpHttpServer.handler` returns 401 before `WeftToolRegistry.call` is
   reached, so a request with no key — or with a revoked one — leaves no trace
   anywhere in the app. This matters past the test. The MCP screen's own copy
   promises every call "is scope-checked, rate-limited and logged", and
   `McpAuditLog`'s doc comment calls itself what "the user checks after a key
   leaks" — but the shape a leak takes from outside, somebody trying keys that do
   not work, is exactly the shape it cannot show. The scenarios assert the
   absence rather than working around it, and produce the *denial* the log can
   show: a key the server recognises and then refuses for want of a scope. Not
   fixed — it is a change to the server's auth path.
2. **A merge decision outlives the app, so the peers cannot be `@bob` and
   `@carol`.** A decision is recorded against a pair of handle ids, a Matrix
   handle's id is the peer's user id, and `IdentityGraph.unmerge` deliberately
   records a *rejection* against every former group-mate so the scorer cannot
   re-suggest what the user just took apart. With two fixed peers the unmerge
   scenario poisons the suggestion scenario on the *next* run of the file: the
   second run fails and the first passed. `merge_test` registers a throwaway pair
   per scenario instead, which needs `rc_registration` raised — Synapse's stock
   burst is three, verified against the container: the fourth registration in a
   run answers `{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":4266}`. `e2e.sh`
   and `ci.yaml` now raise it alongside `rc_login`.
3. **On a bare Synapse the name is the only merge signal there is.** Five of
   `MergeScorer`'s six need a bridge — a phone number in a ghost's localpart, an
   email, a fetched avatar hash, shared groups. `nameExact` is weighted 0.62
   against a 0.55 bar precisely because in practice a name is all a bridge
   exposes, and it is what the scenarios use: two peers with the same two-word
   display name, set *before* they join so the member event carries it. The peers
   also have to speak before the app looks, or lazy-loaded members leave the
   handle with a localpart for a name — one word, which the scorer does not treat
   as evidence at all.
4. **A `uniqueBody` is not searchable, which would have read as a broken
   index.** `toFtsMatchQuery` strips `-` out of every query token while FTS5
   tokenised the indexed body *on* it, so searching for the literal string a test
   just sent returns nothing. Every marker in `search_test` is a `uniqueToken` —
   one word, letters and digits — added to `environment.dart` for this.
5. **A semantic query answers with as much of the index as fits.**
   `FlatVectorIndex` scores every stored vector and returns the best
   `candidateDepth` with no similarity floor, so rows orthogonal to the query
   come back at a similarity of exactly zero, each labelled "meaning" in the UI.
   It is why the semantic scenario asserts presence rather than a count, and why
   the keyword scenarios explicitly turn embeddings *off* first — otherwise "1
   result" would be a claim about run order. Not fixed: a floor is a ranking
   decision, not a test fixture.

Two smaller ones, recorded where they were found rather than acted on:
`TranscriptionService.transcribe` re-indexes a transcript under
`chatId: message.roomId` and `chatTitle: message.senderName`, which is right for
an unmerged chat and wrong for a merged one — the repository's own `indexMessages`
resolves `chatForRoom(roomId)?.id` for exactly this reason. And
`macos/Runner/Release.entitlements` has no `com.apple.security.network.server`,
which the debug one does: a release macOS Weft cannot bind the MCP server's
socket at all. Neither affects the suite, which runs debug builds.

### What each scenario does

**`merge_test.dart`** — a suggestion naming both handles with its evidence chip
and its 62%; accepting it collapsing two inbox rows into one and interleaving
both legs in timestamp order (the `MergedTimeline` watermark seen from outside);
unmerging giving both rows back; and *"Not the same person"* still holding after
the screen is left and re-entered.

**`search_test.dart`** — a message unfindable until its conversation is opened
and findable afterwards, with the result opening the chat it came from; a voice
note transcribed through the bubble's own Transcribe button and then found by a
word only the transcript contains; and a semantic hit for a query sharing no word
with the message, reached through the *Backfill now* button, which is the only
thing in Weft that drains the embedding queue.

**`bridges_test.dart`** — a bridge pointed at this container's own address,
whose card prints Synapse's `Unrecognized request` verbatim (quoted from a live
probe, not guessed) with *Sign in* disabled; a reachable bridge rendering its
network name and both a connected and a bad-credentials login with the bridge's
own reason; and the QR flow's rendered code, its payload in selectable text, and
*Copy code* asserted by reading the system clipboard back.

**`mcp_test.dart`** — a key minted through the dialog (read off the screen,
because a salted hash is all Weft keeps), the server started from the switch, its
port read from the subtitle, and then real JSON-RPC over `127.0.0.1`: a scoped
call answered, an unauthenticated one 401'd with `WWW-Authenticate`, exactly one
audit line for the two, a scope refusal logged as `DENIED`, and a revoked key
dead on the very next request.

### What was verified for these scenarios

| Checked | How |
|---|---|
| The stub servers answer what the real clients expect | `test/e2e_stubs_test.dart`, **7 tests**, against a real loopback socket |
| Android can open a cleartext socket at all | `:app:processDebugManifest` → `usesCleartextTraffic="true"`; `:app:processReleaseManifest` → absent |
| Synapse answers the bridge probe as asserted | live container: `GET /_matrix/provision/v3/whoami` → 404 `{"errcode":"M_UNRECOGNIZED","error":"Unrecognized request"}` |
| Registration works the way `registerAccount` drives it | live container: 401 + session, then `m.login.dummy` → 200 |
| The stock registration limit really would have bitten | live container: 4th registration → `M_LIMIT_EXCEEDED`; with `rc_registration` raised, six in a row → 200 |
| `setDisplayName` reaches the profile | live container: `PUT /profile/{user}/displayname` → 200, `GET /profile/{user}` reads it back |
| `e2e.sh` still runs end to end | driven against the live container with a stubbed `patrol` binary; the new `rc_registration` block appends, and Synapse restarts healthy with it |
| The suite analyses and is formatted | `dart analyze integration_test/patrol` clean, `flutter analyze` clean, `dart format --set-exit-if-changed` clean |
| Nothing existing regressed | `flutter test` in `apps/weft`, **922 pass** (915 + the 7 new) |
| **Not** checked: anything the twelve scenarios assert | no row was executed — `patrol_cli` is not on this host and no matrix row is runnable |

---

## CI

`.github/workflows/e2e.yaml`. Three jobs, eleven rows, one entry point: every
job is a toolchain plus a single call to `tooling/scripts/e2e.sh`, so CI and a
laptop run the same command against the same `tooling/docker` homeserver rather
than two setups that drift.

| Job | Runner | Rows | Gate |
|---|---|---|---|
| `android` | `ubuntu-latest` × 6 | A28-P/T, A33-P/T, A35-P/T | fails the workflow |
| `macos` | `macos-15` | MAC | fails the workflow |
| `ios` | `macos-15` × 4 | I16-P/T, I17-P/T | `continue-on-error` |

`workflow_dispatch` (with a `rows` chooser and an optional single `--target`)
plus a nightly `17 3 * * *`, and **not** `push`. That is a budget decision:
eleven rows each build the app from source, including the vodozemac Rust
cross-compile for four ABIs, on runner types `ci.yaml` does not use at all.

### One prerequisite the macOS row did not have

`macos/Runner.xcodeproj` had **no `RunnerUITests` target**. Task 2 authored the
iOS one; macOS was left out, reasonably, because [macOS is not a Patrol
row](#the-macos-row-is-not-a-patrol-row) in the sense that matters — there is no
platform automator there. But the MAC row still runs nine scenarios, and
[task 3 established](#what-was-verified-and-what-was-not) that even those need
`patrol_cli`: `flutter test -d macos` installs
`IntegrationTestWidgetsFlutterBinding` before the file loads and `PatrolBinding`
is a `LiveTestWidgetsFlutterBinding`, so the two cannot coexist.

And `patrol test -d macos` runs `xcodebuild build-for-testing -scheme Runner`
and then looks for `build/macos_integ/Build/Products/Runner_macosx<sdk>*.xctestrun`
(`macos_test_backend.dart:209`, `:235`), executing
`-only-testing RunnerUITests/RunnerUITests`. With no UI-test bundle in the
scheme's test action there is nothing to produce that file, and the run dies on
*"No .xctestrun file was found"* — which reads as a broken Patrol install. So a
macOS job without this target would have been decorative, and the MAC row would
have stayed not-executed for a reason nobody had written down.

The target is now authored, and unlike the iOS one it is **built rather than
asserted**. It also needs no signing identity: the project signs macOS ad hoc
(`CODE_SIGN_IDENTITY = "-"` at the project level) and a locally-run XCUITest
bundle accepts that, which is why the MAC row is executable on an ordinary
developer machine and a GitHub runner while the iOS rows wait on ADR-002.

### Three things about the Android job worth knowing before reading it

1. **KVM, or the row times out rather than fails.** Without the udev rule the
   x86_64 emulator falls back to software emulation and a one-minute boot takes
   twenty. The AVD is also cached, keyed on API level and device profile.
2. **The Rust targets are a prerequisite of the *build*, not of a test.** All
   four ABIs and not just the emulator's `x86_64`: a Flutter debug APK carries
   every ABI in the app's filter, so cargokit builds every one. The README's
   `RUSTC` pin is applied as `rustup which rustc` — resolved rather than
   hardcoded, and harmless when PATH was already right.
3. **`-camera-back emulated`, against the action's default of `none`.**
   `permissions_test` drives the `CAMERA` dialog through grant *and* deny, and
   `image_picker` does not ask for permission to use a camera the device does
   not have. The default would have turned that scenario into a timeout.

The tablet rows use the `pixel_c` profile (2560×1800 at xhdpi ≈ 1280 dp) because
the two-pane inbox needs a genuine ≥900 dp width (`kTwoPaneBreakpoint`); the
phone rows use `pixel_5` at 393 dp.

### The homeserver on a macOS runner

GitHub's macOS runner images ship **no Docker daemon**, and there is no second
way in. PyPI publishes `matrix-synapse` as manylinux and musllinux wheels only —
checked against the index, latest 1.159.0, seven files, not one of them
`macosx` — so `pip install` would build the Rust extension from the sdist on
every run; and homebrew-core has no synapse formula at all (404).

So the homeserver needs a Linux VM, and the `macos` and `ios` jobs start one
with Colima. That is the choice that leaves `compose.yaml`, `seed.sh` and
`e2e.sh` working unchanged, instead of growing a second macOS-only homeserver
path that would drift from the one every other job uses. `docker compose` is the
plugin form, which Homebrew's `docker-compose` does not install into
`~/.docker/cli-plugins` by itself — the job symlinks it.

### Why the iOS job reports instead of blocking

Two things are missing and only one of them is CI's to fix.

**Signing**, which is ADR-002's, and which is why the job is
`continue-on-error`: a red iOS row must not hide a green Android matrix.

**The runtimes**, which nobody had accounted for. The matrix asks for iOS 16 and
17. A `macos-15` image ships whatever runtime its Xcode came with, and that is
neither — it is an iOS 18.x runtime whose simulators have the *same device
names*. Booting "iPhone 15" on that image and writing the result into an I17
cell is precisely the mistake [Environment reality](#environment-reality-on-this-host)
forbids in its Android half. The job therefore selects a simulator by pinning
the runtime's major version (`iOS-<major>-`) and, when there is no match, fails
that row with a plain *"NOT EXECUTED — this runner image has no iOS N runtime"*
and the `xcodebuild -downloadPlatform iOS -buildVersion` incantation that would
make it real. Verified against a synthetic device list: the I17 rows select the
17.5 iPhone 15 and **not** the 18.2 simulator of the same name, and I16-T with
no iPad on 16 resolves to empty rather than to something plausible.

### Subsets, and where they are defined

`e2e.sh --subset android|ios|macos` expands the applicability table above into
`--target` flags, so the workflow names a platform and the *script* owns the
list. One place, next to the homeserver logic that already had to know about
platforms. `--target` is now repeatable and both it and `--subset` reject a path
that is not a file — `patrol test` accepts a non-existent target and runs
nothing, which on a matrix reads as a green row.

`android` is all thirteen scenarios; `ios` drops `share_in` (skip reason ②);
`macos` is the nine whose assertions are inside the Flutter view, plus
`deeplink`. `harness_test` is in all three: it is the cheapest answer to "is the
harness alive on this row", and a row where it fails needs no further diagnosis.

### What was verified for the CI configuration, and what was not

The workflow itself **has not run** — that needs a push to GitHub and eleven
runners, and this host is not either. What was checked here:

| Checked | How |
|---|---|
| The macOS UI-test target actually builds | `xcodebuild build-for-testing -workspace Runner.xcworkspace -scheme Runner -configuration Debug -derivedDataPath ../build/macos_integ` with patrol's own `OTHER_SWIFT_FLAGS`/`OTHER_LDFLAGS` → **TEST BUILD SUCCEEDED**, `RunnerUITests.xctest` signed *Sign to Run Locally* |
| …and produces the file patrol then looks for | `Runner_macosx26.4-arm64.xctestrun`, matching the `Runner_macosx${sdkVersion}*` glob, with `BlueprintName = RunnerUITests` and `IsUITestBundle = true` — so `-only-testing RunnerUITests/RunnerUITests` resolves |
| The pbxproj edit is additive | 169 insertions, **0 deletions**; `xcodebuild -list` sees `RunnerUITests` |
| `pod install` integrates the new target | `Pods-Runner-RunnerUITests.{debug,release,profile}.xcconfig` wired as base configurations; **no pod version moved** — the only Podfile.lock change is the PODFILE CHECKSUM |
| The workflow is valid YAML with the shape the task asked for | parsed; `workflow_dispatch` + `schedule`, 6 + 1 + 4 rows, per-job `timeout-minutes` 90/60/75, `continue-on-error` on iOS only |
| Every embedded shell block parses | `bash -n` over all 22 `run:`/`script:` bodies with the `${{ }}` expressions substituted out |
| The iOS runtime selector picks the right runtime, and refuses the wrong one | run against a synthetic `simctl … --json` (see above) and against this host's empty runtime list — empty output, exit 0, under `bash -eo pipefail` |
| `e2e.sh` still runs end to end | driven against the **live** Synapse container with a stubbed `patrol`: healthcheck awaited, accounts seeded, the `macos` subset expanded to its nine targets, `localhost:8008` resolved |
| The subset and target guards work | `--subset windows` and `--target …/nope_test.dart` both fail before a container is started |
| Nothing regressed | `flutter analyze` clean, `dart analyze integration_test/patrol` clean, `dart format --set-exit-if-changed` clean, `flutter test` in `apps/weft` **922 pass** (unchanged) |
| **Not** checked | the workflow on a GitHub runner; Colima on a macOS runner; any emulator image below API 36; whether XCUITest's automation permissions are satisfied on a hosted macOS runner without interaction |

That last row is the one to expect trouble from. Colima on a hosted macOS runner
and macOS XCUITest automation are both *documented* to work and neither is
witnessed here, so the first real nightly is where they get tested. If the macOS
row fails, check those two before reading it as a Weft failure.

---

## Environment reality on this host

Recorded 2026-08-19, so a later reader knows what "not executed" meant at the
time rather than guessing.

| Thing | State |
|---|---|
| Docker | 29.4.0, present. `weft-synapse` config exists at `tooling/docker/synapse-data/` with registration open. |
| Android SDK / adb | 1.0.41, present. |
| Android system images installed | **`android-36.1` only.** Not 28, not 33, not 35. |
| Android emulator running | `emulator-5554`, `sdk_gphone64_arm64`, **API 36 / Android 16**, arm64. |
| AVDs defined | `Medium_Phone_API_36.1`, `pgo_vault_test`. No tablet AVD. |
| Xcode | 26.4.1 (17E202). |
| iOS simulator runtimes | **none installed** — `xcrun simctl list runtimes` is empty. |
| JDK on `PATH` | none; Flutter resolves Android Studio's bundled JBR. Patrol's Gradle instrumentation build depends on that resolution holding. |
| Physical Android device | none attached. |
| Push gateway / Firebase config | neither. |
| Bridge | none. |
| iOS signing identity | none — see ADR-002. |

Read against the matrix, that means: **not one of the eleven rows can be run as
specified on this host today.** The closest available is an API 36 phone
emulator, which is a row the matrix does not have and which is not a substitute
for API 28 or 35. Task 7 decides whether to add API 33/35 images (each ~1.5 GB,
arm64 images exist for all three) or to record the Android rows as not-executed
with the image list as the missing thing. What is *not* acceptable is running
API 36 and writing it into an API 35 cell.

---

## Risks the harness task should expect

1. **Swift Package Manager is disabled in this project, and Patrol 4.7 leads with
   SPM.** `README.md` explains why: `flutter_vodozemac`'s xcframework loses its
   `Versions/Current` symlink through the SPM path and code signing breaks.
   `patrol_cli` 4.7.0's headline is *"adds Swift Package Manager support for iOS
   and macOS"*. CocoaPods setup remains supported and is the path this repo must
   take; expect the iOS setup docs to describe the SPM one first.
2. **Analyzer pins.** The workspace has already lost ObjectBox and Drift to
   `analyzer` constraint conflicts (`README.md`, *"There is no ORM and no vector
   database"*), and a pub workspace is a single resolution unit. `patrol` itself
   does not depend on `analyzer` — its dependency list is `boolean_selector`,
   `equatable`, `http`, `http_multi_server`, `json_annotation`, `meta`,
   `patrol_finders`, `patrol_log`, `shelf`, `test_api`, `web` — which is the
   encouraging half. `patrol_cli` is a *global* tool and must never be a pubspec
   dependency, which is the other half. Record resolved versions when it lands.
3. **The Rust cross-compile is a prerequisite of every Android row.** The
   README's `RUSTC=` pin exists because Homebrew's rustc shadows rustup's on
   PATH and fails with a misleading `E0463`. A CI Android job that skips it fails
   in the build, not in a test.
4. **Login rate limiting.** Two accounts per test across thirteen tests is a lot
   of `/login` in a short window. `ci.yaml:168-172` already raises `rc_login`;
   `e2e.sh` must apply the same override locally or the suite will fail
   mid-matrix with 429s that look like flakes.

   > **And `rc_registration`**, which this list did not know when it was
   > written: `merge_test` registers two throwaway peers per scenario and
   > Synapse's stock burst is three. Both overrides are now in `e2e.sh` and in
   > `ci.yaml`.
5. **Notifications need a foreground app or a gateway.** Weft notifies while
   running; being notified while *closed* needs sygnal and a Firebase project,
   neither of which exists here. `notification_test` backgrounds the app rather
   than killing it, and the killed-process path stays not-executed.

   > **And a cross-signed device**, which this list did not know when it was
   > written. `ready` — the state the service starts on — needs the device's
   > *own* key to read as verified, and an emoji comparison does not do that on
   > an account with no cross-signing identity. See
   > [the finding that reshaped the whole task](#the-finding-that-reshaped-the-whole-task).
   > A notification row that fails on an empty shade should be checked there
   > first: it is far more likely than a broken pipeline.

---

## The run

The suite was executed for the first time on 2026-08-19. What follows is what
the device did, not what the files say it should do.

Two things changed before anything could run at all, and both were real:
`patrol_cli` 4.7.0 was installed (`dart pub global activate patrol_cli` — the
version the pubspec was written against, and no resolution moved), and a macOS
blocker was found and fixed. The homeserver came up healthy from
`tooling/docker` on the first try and stayed up for every run.

### The device that ran, and the eleven rows that did not

**No row of the matrix above was executed.** The emulator on this host is
`emulator-5554`, `sdk_gphone64_arm64`, **API 36 / Android 16** — the only system
image installed. API 36 is not A28, not A33 and not A35, and writing an API 36
result into an API 35 cell is precisely what
[Environment reality](#environment-reality-on-this-host) forbids. So the results
below are reported as their own off-matrix row, **A36-P**, and every cell of the
eleven-row table stays *not executed*.

What A36-P is worth: it is a genuine Android device running the real app, the
real native automator, the real Synapse and the real encryption, so a scenario
that fails there is almost certainly broken on A35 too. What it is not worth:
it says nothing about API 28's DocumentsUI, about a tablet layout, or about any
behaviour that changed between 28 and 36 — which is most of what the Android
rows exist to separate.

### macOS: two blockers, one fixed, one needing a human

The MAC row is **not executed**, and the reason is now known precisely rather
than suspected. `patrol test -d macos` builds cleanly — *"Completed building app
with entrypoint test_bundle.dart for macos"*, the `RunnerUITests` target task 6
authored — and then fails twice over.

1. **A TCC file-access prompt nobody can answer. Fixed.** `patrol_cli` hardcodes
   `-derivedDataPath ../build/macos_integ` (`app_options.dart:449`), so the
   XCUITest runner app is built *inside the checkout* — and this checkout is
   under `~/Documents`, a TCC-protected folder. `RunnerUITests-Runner.app` is
   ad-hoc signed and launched by launchd, so it is its own responsible process
   and inherits no consent from the shell. Its first `dlopen` blocked in the
   kernel sandbox and stayed there for five minutes:

   ```
   -[XCTestDriver _loadTestBundleFromURL:error:] → dlopen → __open
     → hook_vnode_check_open (Sandbox)
       → approval_solicit → __WAITING_ON_APPROVAL_FROM_SANDBOXD__
   ```

   read out of the hang spindump xcodebuild itself collected, and corroborated
   by `tccd` logging an unanswered request attributed to
   `com.bostrot.weft.RunnerUITests.xctrunner`. xcodebuild reports this as *"The
   test runner timed out while preparing to run tests"*, which reads like a
   broken Patrol install and is not one. `e2e.sh` now relocates
   `build/{macos,ios}_integ` to a symlink under `$TMPDIR` when — and only when —
   the checkout sits under `~/Documents`, `~/Desktop` or `~/Downloads`. Verified:
   with the relocation the five-minute hang disappears entirely and the run
   proceeds to the next stage in 71 s. CI is unaffected; a GitHub runner checks
   out to `/Users/runner/work`, which is not protected.

2. **An interactive Accessibility grant. Not fixed, and not fixable from here.**
   Past the first blocker the runner reaches XCTest's automation handshake and
   dies on *"Timed out while enabling automation mode."* `testmanagerd` logs
   *"Test session with pid N requesting automation mode"* and never answers;
   `universalAccessAuthWarn` — the process that draws *"… would like to control
   this computer using accessibility features"* — activates at exactly that
   moment, and `tccd` evaluates `kTCCServiceAccessibility` to **Auth:Unknown
   (None)**. That is a consent dialog waiting for a click. It cannot be granted
   from a shell: writing `TCC.db` needs Full Disk Access (this shell does not
   have it), and clicking the dialog needs the very permission being asked for.

   **To make the MAC row run**, a human has to approve it once: run
   `./tooling/scripts/e2e.sh --device macos --subset macos` at the keyboard and
   allow the prompt, or add `RunnerUITests-Runner` under *System Settings →
   Privacy & Security → Accessibility*. This is the risk task 6 recorded about
   hosted macOS runners, now witnessed on a local machine — so the nightly's
   macOS job should be expected to hit it too.

iOS remains not executed for the reason it always had: `xcrun simctl list
runtimes` is empty, and ADR-002 still owns the signing identity.

### A36-P, per scenario

`harness_test` first, because it is the answer to "is any of this real":

| Scenario | Result | Time |
|---|---|--:|
| the test bundle runs on the device | **pass** | 1 s |
| the platform automator answers outside the Flutter view | **pass** | 5 s |

So the whole chain works on Android: `patrol_cli` bundles the Dart tests, Gradle
assembles the instrumentation APK with `PatrolJUnitRunner`, the runner launches
Weft, `listDartTests` reports each scenario separately, and the native automator
drives Home and back — the thing `integration_test` cannot do and the reason
Patrol is in this repo at all.

Then the scenarios, in the order they ran:

| Scenario | Result | Time | Note |
|---|---|--:|---|
| `login_test` refuses a wrong password, then signs in | **pass** | 21 s | |
| `login_test` verifies this device against another session | **pass** | 45 s | failed first; a suite bug, fixed — ① |
| `login_test` signing this device out leaves no session behind | **fail** | 38 s | app defect — ② |
| `messaging_test` an encrypted message reaches the peer and settles as delivered | **fail** | 113 s | reached `Sent`, never `Delivered` — ③ |
| `messaging_test` a message from the peer is read, and the peer sees the receipt | **pass** | 52 s | |
| `messaging_test` the inbox reorders when an older conversation gets the newest message | **pass** | 55 s | |
| `chat_actions_test` a reply quotes the peer's message | **fail** | 88 s | the chat never appeared in the inbox — ⑤ |
| `chat_actions_test` a reaction reaches the peer as an annotation | **pass** | 58 s | failed first; an app defect, fixed — ④ |
| `chat_actions_test` an edit replaces the words on the peer's timeline | **fail** | 81 s | bubble never admitted it was edited |
| `chat_actions_test` a redaction removes the message for the peer | **fail** | 121 s | message never disappeared |
| `attachment_test` a photo picked from the gallery reaches the peer encrypted | **fail** | 481 s | hung after the native pick — ⑥ |
| `attachment_test` the sent photo opens full screen and can be handed back | **fail** | 482 s | same |
| `share_in_test`, `permissions_test`, `notification_test`, `notification_mute_test`, `deeplink_test`, `merge_test`, `search_test`, `bridges_test`, `mcp_test` | **not executed** | — | the run was stopped — ⑦ |

Six passes, seven failures, nineteen scenarios not reached. Nothing here is a
scenario that was "marked passing"; every pass above is a line the device
printed.

⑦ The run was stopped deliberately after `attachment_test`'s second scenario.
Both media scenarios burned their **full eight-minute** scenario timeout on the
same hang, and the six media scenarios still queued would have spent
approximately another fifty minutes re-demonstrating a failure already
characterised in ⑥. That is a decision about this session's time, not a
judgement that those scenarios pass — they are recorded as not executed, and
`share_in`, `permissions`, `notification`, `deeplink`, `merge`, `search`,
`bridges` and `mcp` have **never been run on any device**.

### What the run found

Four findings, two of them fixed here and verified against the device.

1. **A suite bug that read exactly like a broken feature. Fixed.**
   `verifyThisDeviceAgainst` finished the emoji comparison, both ends reached
   `done`, both derived the same short authentication string — and then timed
   out waiting for the devices list to call the helper session verified. The
   verification was correct the whole time. The devices screen is a
   `ListView(children: ...)`, whose `SliverChildListDelegate` **only builds the
   rows in the viewport**, and `sortDevices` puts everything that
   `needsAttention` above everything that does not (`devices.dart:152`).
   Verifying a device therefore *moves it* — past every unverified session on
   the account, and this suite leaves one behind per run, so on this homeserver
   that was past **seventeen** of them and off the bottom of the built range.
   `Finder.evaluate()` cannot see a row that was never built, so the assertion
   was reading scroll offset and reporting it as trust.

   Diagnosed by dumping every built tile before and after the comparison: the
   helper row was present before (`Weft E2E control ¦ Not verified ¦
   MTIWGJNTBV`) and absent after, while the *control's own* key store said
   `GIQAOBPGDN direct=true verified=true` — the app's device, correctly
   verified, from the other end. `pumpUntilDeviceVerified` in `support/app.dart`
   now scrolls to the row before asserting on it. The scenario passed on the
   next run and on the one after that.

2. **Signing out of Weft raises an unhandled exception, and Weft has no other
   way out.** Not fixed — see below. `deleteDevices` revokes the running
   client's own access token behind its back and leaves it syncing; the sync
   loop then fails with `M_UNKNOWN_TOKEN`, `Client._handleSoftLogout` tries to
   refresh a token the deleted device no longer has, and — having cleared the
   session — **rethrows** into the unawaited future `_sync` was started in
   (`client.dart:2350,2390`). On the device that is
   `M_UNKNOWN_TOKEN: refresh token does not exist`, every time.

   It matters more than it looks: the devices screen's *Sign out* on **This
   device** is the app's entire sign-out flow — `grep` finds no other caller of
   `WeftMatrixSession.logout()` anywhere in `lib/`, and that method is never
   called at all. So every user meets this.

   A fix was written and reverted, on purpose. Routing the current device
   through `logout()` inside `MatrixDeviceManager` removes the unhandled
   exception and is almost certainly right — `Client.clear()` reaches
   `onLoginStateChanged.add(LoginState.loggedOut)` unconditionally
   (`client.dart:2319`), so the session state stays deterministic — but the
   scenario still failed afterwards, on a *different* wait: the app did not
   return to the login screen within 60 s. That is a second defect behind the
   first, and shipping an unverified change to the only sign-out path in the app
   to half-fix it is worse than recording it. Both belong in one follow-up, with
   the devices screen's pushed route as the first suspect for why the login
   screen never arrives.

3. **A sent message stops at `Sent` and never becomes `Delivered`.** Not
   diagnosed. `_deliveryFor` maps `EventStatus.synced` to
   `DeliveryState.delivered` (`mapping.dart:349-359`), so the bubble is saying
   the homeserver accepted the event but never echoed it back down `/sync`
   within 60 s — on a local Synapse, with the peer receiving the message
   perfectly well in the same scenario. Worth suspecting the same sync-loop
   health that ② disturbs, since this scenario ran immediately after it.

4. **Weft aimed a garbage collector at its own database. Fixed.**
   `_openDatabase` passed `fileStorageLocation: directory.uri` — the directory
   that holds `weft.sqlite` — together with
   `deleteFilesAfterDuration: 30 days`. The SDK's file store periodically lists
   that directory and `delete()`s every plain file older than the window,
   excluding nothing (`database_file_storage_io.dart:63-80`).

   The visible symptom was a flake with no connection to anything under test:
   `PathNotFoundException: Cannot delete file … weft.sqlite-journal`, thrown out
   of an unawaited future when sqlite removed its journal between the `list()`
   and the `delete()`. It failed **three** scenarios across these runs —
   `login_test`'s verification once, and two of `chat_actions_test`'s four —
   each time with an error about a file none of them had ever heard of.

   The unseen half is worse: nothing stops the same sweep deleting
   `weft.sqlite` itself, which is only safe while it keeps being written. The
   account at risk is the dormant one — open Weft after a month away and the
   sweep is entitled to delete the database, the device keys in it, and with
   them every encrypted message this device could still read. The attachment
   cache now gets a `files/` subdirectory of its own.

   Verified against the device: `chat_actions_test` re-run with the fix produced
   **zero** `weft.sqlite-journal` exceptions where the previous run had two, and
   *a reaction reaches the peer as an annotation on the right event* — which had
   failed on nothing but that exception — passed.

5. **Three chat scenarios fail on their own subject.** Not diagnosed, and not
   flakes: a reply could not open the conversation at all (`openChat` never
   found the inbox row for a room the peer had just created), an edit never
   made the bubble admit it was edited, and a redaction never made the message
   disappear. These are the next thing to look at, and they are the reason the
   quality track cannot yet claim Phase 05's chat actions work end to end.

6. **The gallery picker hangs after the photo is chosen.** Not diagnosed.
   `pickFirstPhoto` reaches DocumentsUI, the seeded `weft-e2e-photo.png` is
   there (the gallery seeding in `e2e.sh` works — `content query` confirmed the
   row), the native tap succeeds, and then nothing happens until the
   eight-minute scenario timeout. Whether the picker never returns to Weft or
   the upload bubble never appears needs a screenshot at the moment it hangs,
   which is the first thing to do next.

### What was verified for this task, and what was not

| Checked | How |
|---|---|
| The homeserver comes up and stays healthy | `docker compose up -d --wait` → `weft-synapse Up (healthy)`; unchanged across nine device runs |
| The Patrol toolchain works on Android | `harness_test` 2/2, including the native automator |
| The macOS TCC file-access hang is real, and the relocation fixes it | hang spindump (`__WAITING_ON_APPROVAL_FROM_SANDBOXD__`), `tccd` request for the runner's bundle id; after relocation the 300 s bootstrap hang is gone |
| The macOS Accessibility blocker is real | `testmanagerd` "requesting automation mode" → 60 s timeout, `universalAccessAuthWarn` activating at that moment, `kTCCServiceAccessibility` → `Auth:Unknown (None)` |
| The devices-list scroll fix works | the verification scenario passed twice after failing twice, with no other change |
| The file-store fix works | `chat_actions_test`: two `weft.sqlite-journal` failures before, zero after; one scenario converted from fail to pass |
| Nothing regressed | `flutter analyze` clean, `dart format --set-exit-if-changed` clean, `dart analyze integration_test/patrol` clean, and the unit suites — see the commit |
| **Not** checked | every one of the eleven matrix rows; 27 of the 39 scenarios, nine files of which have never run anywhere; any iOS anything; the macOS row past the automation handshake; whether findings ③, ⑤ and ⑥ are app defects or suite defects |

That last cell is the honest headline. This task moved the suite from *nothing
executed* to *twelve scenarios executed on an off-matrix Android emulator*, and
found four defects doing it — two of them in Weft, one of them a data-loss
hazard. It did not establish that the matrix passes, on any row.

> [!NOTE]
> **Counts corrected, 2026-08-19, closing the phase.** This section originally
> said "thirteen scenarios executed … nineteen not executed" out of
> "thirty-two". Counted against the tree — 41 `patrolTest` bodies, of which 2
> are `harness_test`'s — the suite holds **39 scenarios**, of which **12** ran
> and **27** did not. The earlier figures counted the two-check `harness_test`
> as a single scenario and undercounted the files nobody reached. The pass and
> fail *results* above are unchanged and are what the device printed; only the
> arithmetic around them moved. Every table in [Results](#results) is generated
> from the tree.

---

## Results

Filled in 2026-08-19, closing Phase 09. This is the table the whole document was
built to be able to fill in honestly, and the honest answer is that **not one of
the eleven matrix rows has been executed**. Twelve of the 39 scenarios ran, all
of them on an **API 36** phone emulator that is not a row of this matrix, and
they are reported in their own **A36-P** column rather than written into an A35
cell.

Legend: **pass** executed and passed · **fail** executed and failed, keyed to a
reason below · **·** not executed, keyed to what is missing per row ·
**n/a** platform-inapplicable, keyed to the [skip reasons](#applicability).

The last column is off-matrix and is not part of the eleven. It is here because
a scenario that fails on a real Android device with the real automator, the real
Synapse and real encryption is almost certainly broken on A35 too — and because
leaving it out would make the table look like nothing has ever been run, which
is also untrue.

### Per scenario, per row

| # | Scenario | A28-P | A28-T | A33-P | A33-T | A35-P | A35-T | I16-P | I16-T | I17-P | I17-T | MAC | A36-P |
|--:|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| | **`login_test`** | | | | | | | | | | | | |
| 1 | refuses a wrong password on the screen, then signs in | · | · | · | · | · | · | · | · | · | · | · | **pass** |
| 2 | verifies this device against another session of the same account | · | · | · | · | · | · | · | · | · | · | · | **pass** |
| 3 | signing this device out leaves no session behind | · | · | · | · | · | · | · | · | · | · | · | **fail** Ⓐ |
| | **`messaging_test`** | | | | | | | | | | | | |
| 4 | an encrypted message reaches the peer and settles as delivered | · | · | · | · | · | · | · | · | · | · | · | **fail** Ⓑ |
| 5 | a message from the peer is read, and the peer sees the receipt | · | · | · | · | · | · | · | · | · | · | · | **pass** |
| 6 | the inbox reorders when an older conversation gets the newest message | · | · | · | · | · | · | · | · | · | · | · | **pass** |
| | **`chat_actions_test`** | | | | | | | | | | | | |
| 7 | a reply quotes the peer's message on the peer's timeline | · | · | · | · | · | · | · | · | · | · | · | **fail** Ⓒ |
| 8 | a reaction reaches the peer as an annotation on the right event | · | · | · | · | · | · | · | · | · | · | · | **pass** |
| 9 | an edit replaces the words on the peer's timeline | · | · | · | · | · | · | · | · | · | · | · | **fail** Ⓒ |
| 10 | a redaction removes the message for the peer as well | · | · | · | · | · | · | · | · | · | · | · | **fail** Ⓒ |
| | **`attachment_test`** | | | | | | | | | | | | |
| 11 | a photo picked from the device gallery reaches the peer encrypted | · | · | · | · | · | · | · | · | · | · | n/a ① | **fail** Ⓓ |
| 12 | the sent photo opens full screen and can be handed back to the platform | · | · | · | · | · | · | · | · | · | · | n/a ① | **fail** Ⓓ |
| 13 | a photo shares the conversation with the text around it | · | · | · | · | · | · | · | · | · | · | n/a ① | · Ⓔ |
| | **`share_in_test`** | | | | | | | | | | | | |
| 14 | a file shared from outside arrives on the peer as an image | · | · | · | · | · | · | n/a ② | n/a ② | n/a ② | n/a ② | n/a ② | · Ⓔ |
| 15 | `SEND_MULTIPLE` arrives as one event per file, in the order shared | · | · | · | · | · | · | n/a ② | n/a ② | n/a ② | n/a ② | n/a ② | · Ⓔ |
| 16 | a shared file can be sent with a caption typed on the way | · | · | · | · | · | · | n/a ② | n/a ② | n/a ② | n/a ② | n/a ② | · Ⓔ |
| | **`permissions_test`** | | | | | | | | | | | | |
| 17 | picking from the gallery asks for no permission at all | · | · | · | · | · | · | · | · | · | · | n/a ① | · Ⓔ |
| 18 | the camera permission is denied, the app survives it, then granted | · | · | · | · | · | · | · ⓘ | · ⓘ | · ⓘ | · ⓘ | n/a ① | · Ⓔ |
| | **`notification_test`** | | | | | | | | | | | | |
| 19 | a backgrounded Weft posts to the shade, and the tap opens that chat | · ④ | · ④ | · | · | · | · | · ⑤ | · ⑤ | · ⑤ | · ⑤ | n/a ① | · Ⓔ |
| 20 | a reply typed into the shade reaches the peer | · | · | · | · | · | · | n/a ⑤ | n/a ⑤ | n/a ⑤ | n/a ⑤ | n/a ① | · Ⓔ |
| 21 | marking read from the shade posts a receipt and clears the notification | · | · | · | · | · | · | n/a ⑤ | n/a ⑤ | n/a ⑤ | n/a ⑤ | n/a ① | · Ⓔ |
| | **`notification_mute_test`** | | | | | | | | | | | | |
| 22 | a muted conversation stays out of the shade while an unmuted one does not | · | · | · | · | · | · | · ⑤ | · ⑤ | · ⑤ | · ⑤ | n/a ① | · Ⓔ |
| 23 | mentions-only silences the chatter and lets a mention through | · | · | · | · | · | · | · ⑤ | · ⑤ | · ⑤ | · ⑤ | n/a ① | · Ⓔ |
| | **`deeplink_test`** | | | | | | | | | | | | |
| 24 | `weft://chat/<id>` fired by the OS opens that conversation | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · Ⓔ |
| 25 | `weft://search?q=` fired by the OS opens search on that query | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · Ⓔ |
| 26 | `weft://user/<id>` is delivered and pushes nothing, which is the app today | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · Ⓔ |
| 27 | a link for a conversation this account is not in says so | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · ⑥ | · Ⓔ |
| | **`merge_test`** | | | | | | | | | | | | |
| 28 | a suggestion names both handles and shows the evidence behind it | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| 29 | accepting a suggestion collapses both chats into one ordered thread | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| 30 | unmerging gives both conversations back | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| 31 | "Not the same person" retires a suggestion for good | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| | **`search_test`** | | | | | | | | | | | | |
| 32 | a message becomes findable once its conversation has been opened | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| 33 | a voice message is findable by words that were only ever spoken | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| 34 | semantic search returns a message containing none of the typed words | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| | **`bridges_test`** | | | | | | | | | | | | |
| 35 | a bridge that is not a bridge reports what the server actually said | · | · | · | · | · | · | · | · | · | · | · | · Ⓔ |
| 36 | a reachable bridge renders its network and the state of each login | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓔ |
| 37 | the QR login shows a scannable code and a payload that can be copied | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓕ | · Ⓔ |
| | **`mcp_test`** | | | | | | | | | | | | |
| 38 | the server answers a key it knows, refuses one it does not, and logs one | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · | · Ⓔ |
| 39 | a key is refused by scope, logged as denied, and dead once revoked | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · ⑦ | · | · Ⓔ |

`harness_test.dart` is not in the table because it is not a scenario. Its two
checks — the bundle runs on the device, and the platform automator answers
outside the Flutter view — both **passed** on A36-P and have not been run
anywhere else. They are the reason anything above them can be believed.

**Three refinements the per-scenario table earns**, all of which the file-level
[applicability table](#applicability) had to state as a `◐`:

- **Skip reason ⑤ splits.** `shade.dart` declares `shadeIsReachable` (Android
  and iOS) separately from `shadeActionsAreReachable` (Android only), so on the
  four iOS rows scenario 19 applies and scenarios 20 and 21 are **n/a** — Patrol's
  automator has no gesture that expands a banner to reach an action button. The
  ⑤ still marked on 19 and on 22–23 is the other half of that reason: no APNs
  push in this repository, so what runs on iOS is the locally-posted path only.
- **Skip reason ⑥ is not a macOS reason.** It is a reason about *cold start*,
  and cold start is unreachable on **every** row, because `PatrolJUnitRunner`
  launches the app once and every Dart test runs in that process. All four
  deep-link scenarios are `✓` on macOS — `Process.run('open', …)` gives a real
  OS-routed link — and all four are warm-start-only everywhere.
- **Skip reason ③ attaches to no scenario.** It was written about API 28 having
  no `POST_NOTIFICATIONS`, and marked `permissions_test` `◐` for it — but
  neither of that file's two scenarios touches the notification permission.
  `shade.dart`'s `osPredatesNotificationPermission` reads the API level off the
  device and handles it inside the notification files. Both `permissions_test`
  scenarios apply in full on A28.

**ⓘ** Scenario 18 needs a camera. `permissions_test` skips it when the device is
an iOS *simulator*, which has none and whose `UIImagePickerController` refuses
the camera source outright — so on the four iOS rows as CI runs them (simulators)
it will report skipped rather than passed. On a physical iPhone or iPad it
applies. The Android rows are unaffected: `e2e.yaml` sets
`-camera-back emulated` for exactly this.

### Why each cell is not executed

| Rows | What is missing | Who can supply it |
|---|---|---|
| **A28-P, A28-T, A33-P, A33-T, A35-P, A35-T** | An Android system image for API 28, 33 and 35, and a ≥900 dp AVD profile for the three tablet rows. The only image installed on this host is **API 36**. | A CI run. `.github/workflows/e2e.yaml` provisions all six rows through `reactivecircus/android-emulator-runner`; it has **never been dispatched** and never run on its nightly. One push and six runners answers all six rows. |
| **I16-P, I16-T, I17-P, I17-T** | An **iOS simulator runtime** — `xcrun simctl list runtimes` is empty on this host, so there is nothing to boot. A **signing identity** for the `RunnerUITests` bundle is the second requirement and is what [ADR-002](../decisions/adr-002-ios-signing-handoff.md) now carries; on a *simulator* it is probably not needed, and that "probably" is untested here for want of a runtime to try it on. On a physical iPhone or iPad it certainly is. | The runtime, a CI run or `xcodebuild -downloadPlatform iOS`; the identity, whoever holds the Apple Developer account. The `ios` job is `continue-on-error` precisely so these four report instead of blocking. |
| **MAC** | One **interactive Accessibility grant** for `RunnerUITests-Runner`, and nothing else. The build works, the `.xctestrun` is produced, the TCC file-access hang is fixed; XCTest then dies on *"Timed out while enabling automation mode"* with `kTCCServiceAccessibility` reading `Auth:Unknown (None)`. | A human at this keyboard, once: run `./tooling/scripts/e2e.sh --device macos --subset macos` and allow the prompt, or add the runner under *System Settings → Privacy & Security → Accessibility*. Expect the nightly's macOS job to need the same on its runner. |
| **A36-P**, scenarios 13–39 | Nothing but time. The run was stopped after scenario 12 rather than spend ~50 more minutes watching six media scenarios re-demonstrate the hang in Ⓓ. | A re-run, once Ⓓ is diagnosed. |

Two things are missing from **every** row, and no device supplies them:

- **Ⓕ A real bridge account.** `bridges_test` scenarios 36 and 37 talk to a
  `BridgeStub` — an `HttpServer` in the app's own process speaking the mautrix
  provisioning API — because `tooling/docker` runs no bridge and nobody here has
  a WhatsApp, Signal or Telegram account to bridge. What is asserted is that
  Weft reads a well-formed provisioning response correctly. **That a real
  mautrix bridge answers in that shape is not tested anywhere in this
  repository.** Scenario 35 is the exception and is the more honest of the
  three: it probes the *real* Synapse, which is not a bridge, and asserts Weft
  reports what the server actually said.
- **The push gateway leg.** Skip reason ⑤'s second half. Weft has no push
  gateway URL and no Firebase config in this repository, so every notification
  scenario on every row exercises the locally-posted path. A notification that
  arrives on a *suspended* app, through Sygnal and APNs/FCM, is not-executed
  everywhere and is recorded as such rather than inferred from the tests that
  pass.

### What ran, and why the seven failures failed

Twelve scenarios, **5 pass / 7 fail**, plus `harness_test` 2/2. Full timings and
diagnosis are in [The run](#the-run); this is the key the table above points at.

| Key | Scenarios | Failure | Where it stands |
|---|---|---|---|
| **Ⓐ** | 3 | `deleteDevices` revokes the running client's own token, the sync loop hits `M_UNKNOWN_TOKEN`, and `_handleSoftLogout` **rethrows** into an unawaited future. | **App defect, open.** The devices screen's *Sign out* on **This device** is Weft's entire sign-out flow — `WeftMatrixSession.logout()` has no caller in `lib/` — so every user meets it. A fix was written, run and reverted: it removes the exception and the app still does not reach the login screen, which is a second defect behind the first. Both belong in one follow-up. |
| **Ⓑ** | 4 | The bubble reaches `Sent` and never `Delivered` — the homeserver accepted the event but did not echo it back down `/sync` within 60 s, on a local Synapse, while the peer received it perfectly well in the same scenario. | **Undiagnosed.** Ran immediately after Ⓐ, so the same disturbed sync loop is the first suspect. Not a weakened assertion: `DeliveryState.delivered` is what `_deliveryFor` maps `EventStatus.synced` to, and that is the right thing to assert. |
| **Ⓒ** | 7, 9, 10 | A reply could not open the conversation at all (`openChat` never found the inbox row for a room the peer had just created); an edit never made the bubble admit it was edited; a redaction never made the message disappear. | **Undiagnosed, and the reason this track cannot yet claim Phase 05's chat actions work end to end.** Three of `chat_actions_test`'s four. The fourth (8) passes, so the file's shared setup is not the explanation. |
| **Ⓓ** | 11, 12 | Both hung for their full **eight-minute** timeout after the native pick succeeded. DocumentsUI opens, the seeded photo is there, the tap lands — then nothing. | **Undiagnosed.** Whether the picker never returns to Weft or the upload bubble never appears needs a screenshot at the moment of the hang. First thing to do next. |
| **Ⓔ** | 13–39 | — | **Not executed on any device, anywhere.** Nine files have never run: `share_in`, `permissions`, `notification`, `notification_mute`, `deeplink`, `merge`, `search`, `bridges`, `mcp`. |

Two failures found earlier in the same session were **fixed and re-run green**,
and are not in the table because they are no longer failures: the devices-list
scroll bug in the suite (finding 1 of [What the run found](#what-the-run-found))
and Weft aiming the SDK's file-store garbage collector at its own database
(finding 4) — the second a data-loss hazard for a dormant account, found only
because a device ran the code.

### Coverage, in one paragraph

39 scenarios exist. 12 have been executed, all on one off-matrix emulator; 5 of
those passed. **0 of 11 matrix rows** have been executed. 9 of the 13 scenario
files have never run on any device. The suite has found 4 defects, 2 of which
were fixed and verified on the device, and it has not yet demonstrated that any
row of this matrix passes. Everything needed to change that is either a CI
dispatch (Android), a signing identity plus a runtime (iOS), or one click at a
keyboard (macOS).
