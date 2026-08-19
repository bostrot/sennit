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
unauthenticated one, and the audit entries; the tunnel toggle is asserted to be
*absent or disabled*, not exercised.

---

## The scenarios

Thirteen files under `apps/weft/integration_test/patrol/`, plus a shared
`patrol/support/`. Each is independently runnable and cleans up the rooms it
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

**`merge_test.dart`** — two source chats for one contact produce a suggestion
with visible evidence; accept collapses them into one correctly ordered thread;
unmerge restores both. The ordering assertion is the watermark invariant from
`MergedTimeline` seen from the outside.

**`search_test.dart`** — send, query, assert hybrid search returns them.
Includes a voice message with a transcript, to prove transcript indexing end to
end. Transcription needs an STT endpoint; with none configured the transcript
leg is not-executed and says so.

**`bridges_test.dart`** — the bridges screen renders health probes against the
local homeserver, and the QR login flow shows both a rendered QR and a copyable
payload. **No bridge runs in `tooling/docker`** (`tooling/docker/README.md:36-43`
— the mock bridge is still outstanding), so the probe asserted is the
*unreachable* one rendered as a readable sentence, which is the honest available
assertion until a bridge exists to probe.

**`mcp_test.dart`** — start the server from settings, authenticated request
succeeds on the loopback endpoint, unauthenticated is rejected 401, both appear
in the audit view. Tunnel per skip reason ⑦.

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

Eight scenarios across `notification_test.dart`, `notification_mute_test.dart`
and `deeplink_test.dart`, over the same `support/`, which grew two files:
`verification.dart` — how this device becomes trusted, which turns out to be the
precondition for posting anything at all — and `shade.dart`, the notification
shade itself. Nothing here was executed.

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

## Results

Filled in by the last task of Phase 09. Every cell is **not executed**. For the
first nine scenarios the reason is no longer *not written* — they are written,
and what that means is recorded above for the
[core three](#what-was-verified-and-what-was-not), the
[media three](#what-was-verified-for-these-scenarios) and the
[notification and deep-link three](#what-was-verified-for-these-scenarios-1) —
it is that no row on this host can run them: `patrol_cli` is absent, the Android
system images are API 36 only, and there is no iOS runtime. For the remaining
four the reason is still that the scenario does not exist yet.

| Scenario | A28-P | A28-T | A33-P | A33-T | A35-P | A35-T | I16-P | I16-T | I17-P | I17-T | MAC |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `login_test` | · | · | · | · | · | · | · | · | · | · | · |
| `messaging_test` | · | · | · | · | · | · | · | · | · | · | · |
| `chat_actions_test` | · | · | · | · | · | · | · | · | · | · | · |
| `attachment_test` | · | · | · | · | · | · | · | · | · | · | n/a |
| `share_in_test` | · | · | · | · | · | · | n/a | n/a | n/a | n/a | n/a |
| `permissions_test` | · | · | · | · | · | · | · | · | · | · | n/a |
| `notification_test` | · | · | · | · | · | · | · | · | · | · | n/a |
| `notification_mute_test` | · | · | · | · | · | · | · | · | · | · | n/a |
| `deeplink_test` | · | · | · | · | · | · | · | · | · | · | · |
| `merge_test` | · | · | · | · | · | · | · | · | · | · | · |
| `search_test` | · | · | · | · | · | · | · | · | · | · | · |
| `bridges_test` | · | · | · | · | · | · | · | · | · | · | · |
| `mcp_test` | · | · | · | · | · | · | · | · | · | · | · |

Legend for the filled table: **pass** executed and passed · **fail** executed
and failed, with the reason · **·** not executed, with what is missing ·
**n/a** platform-inapplicable per the skip reasons above.
