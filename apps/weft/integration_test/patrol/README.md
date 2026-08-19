# Weft's Patrol suite

The device tests. Everything here runs on a real Android device, a real iOS
device or simulator, or — in a reduced form — on the macOS desktop, against the
disposable Synapse in `tooling/docker`.

The target matrix, what each scenario asserts, and which rows skip which
scenario is [`docs/quality/e2e-matrix.md`](../../../../docs/quality/e2e-matrix.md).
Read that first; this file is only how to run the thing.

## Why this is not `integration_test`

`../matrix_session_test.dart`, `../call_test.dart` and `../attachment_flow_test.dart`
drive a real engine and a real homeserver, and they are still not enough: every
one of their assertions lives inside the Flutter view. The share sheet another
app raises, the permission dialog, the notification in the shade, the
`ACTION_SEND` the OS routes — none of them is drawn by Flutter, so no
`flutter test` can see any of them.

Patrol adds a *platform automator* — UIAutomator on Android, XCUITest on iOS —
running alongside the Dart test process, and that is the only reason it is here.
Scenarios whose assertions are all inside the view belong in `../`, not here.

## Running

One command, from the repository root:

```bash
./tooling/scripts/e2e.sh
```

It starts Synapse, waits for the healthcheck, seeds `@alice` and `@bob`, clears
Weft's data and permissions on the device, pushes a photo into the device's
gallery, runs `patrol test` against whatever device is attached, and tears the
homeserver down. `--keep` leaves it running between runs; `--target <file>` runs
one scenario; `--device <id>` picks a device when more than one is attached;
`--no-media` and `--no-reset` skip the two device steps.
`./tooling/scripts/e2e.sh --help` lists the rest.

Both device steps are prerequisites rather than conveniences. The picker reads
MediaStore, and an empty gallery is a scenario that times out pointing at the
picker instead of at the missing photo. A granted permission survives
`adb install -r` and so does a denial, so without the clear `permissions_test`
passes once on a fresh device and never again.

You need `patrol_cli` on `PATH`, which is a global tool and deliberately *not* a
pubspec dependency:

```bash
dart pub global activate patrol_cli
```

## Layout

| Path | What it is |
|---|---|
| `harness_test.dart` | Proves the harness itself — the bundle runs, the automator answers. Touches nothing of Weft's. |
| `login_test.dart` | Homeserver discovery, a refused password, interactive device verification, sign-out. |
| `messaging_test.dart` | Two accounts, encrypted messages, delivery states, read receipts, inbox order. |
| `chat_actions_test.dart` | Reply, react, edit, redact — each asserted on the peer's timeline. |
| `attachment_test.dart` | A photo picked from the device's own gallery, its upload bubble, the settled bubble, the full-screen viewer, and the hand-off back to the platform. |
| `share_in_test.dart` | `ACTION_SEND` and `ACTION_SEND_MULTIPLE` routed by the OS into Weft's share-target sheet. Android rows only. |
| `permissions_test.dart` | The camera dialog granted and denied natively, and the *absence* of a storage dialog the pickers do not need. |
| `notification_test.dart` | A backgrounded Weft posting to the shade, the tap landing in the right conversation, and reply and mark-as-read pressed from the shade itself. |
| `notification_mute_test.dart` | A muted conversation staying quiet, and mentions-only letting a mention through — each asserted beside a control that had to be noisy. |
| `deeplink_test.dart` | `weft://chat/<id>`, `weft://search?q=` and `weft://user/<id>` fired by the OS as real `ACTION_VIEW`s. Warm start; see below. |
| `support/` | Shared account provisioning, login, teardown, the app driver, the media helpers, device verification and the shade. Setup is not repeated per file. |
| `test_bundle.dart` | **Generated** by `patrol_cli` on every run, and gitignored. Never edit it. |

`support/` is seven files because it answers seven questions — what the world is
(`environment.dart`), who else is in it (`accounts.dart`), how the app is worked
(`app.dart`), what the platform does with a file (`media.dart`), what a scenario
starts from (`scenario.dart`), how this device becomes trusted
(`verification.dart`), and what is in the notification shade (`shade.dart`) — and
`support.dart` re-exports all of them, which is what a scenario imports.

Each scenario file must be independently runnable and must clean up the rooms it
made. The homeserver is shared across a run, so a test that leaves a room behind
poisons the next one — and on a matrix the next one is on a different device,
where the failure is much harder to read.

## Weft's picker is not the photo picker

Worth knowing before reading `attachment_test.dart` or `permissions_test.dart`,
because it decides what both of them can assert. `AttachmentPicker` calls
`ImagePicker().pickMultipleMedia()`, and `ImagePickerAndroid`'s
`useAndroidPhotoPicker` defaults to `false` — Weft never sets it — so the intent
is `ACTION_GET_CONTENT`, served by **DocumentsUI** on every API level rather than
by Android's photo picker. Two consequences:

- Patrol's default gallery selectors switch to the photo picker's resource ids
  at API 34, so `native.pickImageFromGallery()` would be looking for the wrong
  app on the A35 rows. `pickFirstPhoto` taps DocumentsUI directly instead.
- `ACTION_GET_CONTENT` is the Storage Access Framework, so **no permission is
  ever asked for**. The manifest declares no media permission either. The
  storage dialog Phase 09 asks about does not exist; `permissions_test` asserts
  its absence and exercises grant and deny on the camera, which Weft does ask
  for because the manifest declares `CAMERA` for calls.

## Nothing posts a notification until this device is trusted

`main.dart` starts the notification service on `WeftSessionState.ready` and on
no other state, so a device that took the *Continue without verifying* door
never posts anything. Verifying against a second session is **not** enough on
its own: `needsVerification` asks whether *our own* device key reads as
verified, while SAS marks the keys the other end sent — so on an account with no
cross-signing identity neither `directVerified` nor `crossVerified` can ever
become true.

`ChatScenario.start(notifying: true)` is the way through, and it is three steps
because the app needs all three: the control session mints a cross-signing
identity, the app drives an emoji comparison against it through its own devices
screen (which is what signs this device into that identity), and Weft is
restarted — because nothing re-derives the session state in place. It then
answers the rationale sheet with *Turn on notifications* and grants the OS
dialog. `support/verification.dart` has the citations.

Two consequences for anyone adding a scenario. First, this costs a bootstrap, a
verification and an app restart, so only ask for it when the scenario is about
notifications. Second, **never pump a frame while Weft is backgrounded**:
`LiveTestWidgetsFlutterBinding.pump` awaits a completer only a drawn frame
completes, a stopped activity draws none, and there is no timeout on the wait —
it is a hang, not a failure. `support/shade.dart` waits on timers throughout for
that reason, and `backgroundApp` registers a teardown that brings Weft back so
the *next* scenario's launch does not hang instead.

## Deep links are warm start only

A Patrol test runs inside the app under test: `PatrolJUnitRunner.setUp` launches
the activity once and every Dart test runs in that process. Killing Weft to make
the next link a cold start would kill the isolate the test is running on. So the
cold-start path is unreachable from this suite on every row, and it is recorded
as not-executed rather than approximated. `deeplink_test.dart` fires real
`ACTION_VIEW` intents at a running Weft, which is the other half and is genuinely
routed by the OS.

## Two things a scenario cannot do through the UI

Both are gaps in the app rather than in the harness, and `support/accounts.dart`
works around them in the open rather than quietly:

- **Weft cannot start a conversation.** There is no start-chat flow and no
  accept-invite affordance — nothing in the app reads `Membership.invite`. So a
  scenario that needs a conversation has the app account's *own* second session
  (`TestAccount.control`) create it, which makes the app a member from the
  moment the room exists rather than an invitee waiting for a button that does
  not exist.
- **Weft posts a read receipt from one place only**, the inbox row's tap
  handler. A message arriving in a conversation that is already open is never
  receipted, so `messaging_test` sends *before* opening the chat. It is testing
  the path the app has, and the header of that test says so.

## Reading state a screen does not spell out

The suite asserts on accessible names in three places — the sign-in error
banner, the delivery tick, the SAS emoji — and that is deliberate rather than a
shortcut around missing keys. A delivered tick and a read tick are the same
13dp glyph in two colours; the label beside it is the only place the difference
exists in words, for a test and for a screen reader alike. `semanticsEnabled` is
on by default in `patrolTest`, which is what makes `find.bySemanticsLabel` work.

## Addressing the homeserver

`localhost:8008` is the *device's* loopback, not the host's. `e2e.sh` picks the
right address for the target, but if you invoke `patrol test` by hand:

| Target | `--dart-define=WEFT_HOMESERVER=` |
|---|---|
| Android emulator | `10.0.2.2:8008` |
| Android device | the host's LAN address, or `adb reverse tcp:8008 tcp:8008` first |
| iOS simulator | `localhost:8008` |
| macOS | `localhost:8008` |

Configuration reaches the tests as `String.fromEnvironment`, never
`Platform.environment`: a compiled test binary on a device has no shell to read.
