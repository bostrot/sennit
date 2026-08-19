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

It starts Synapse, waits for the healthcheck, seeds `@alice` and `@bob`, runs
`patrol test` against whatever device is attached, and tears the homeserver
down. `--keep` leaves it running between runs; `--target <file>` runs one
scenario; `--device <id>` picks a device when more than one is attached.
`./tooling/scripts/e2e.sh --help` lists the rest.

You need `patrol_cli` on `PATH`, which is a global tool and deliberately *not* a
pubspec dependency:

```bash
dart pub global activate patrol_cli
```

## Layout

| Path | What it is |
|---|---|
| `harness_test.dart` | Proves the harness itself — the bundle runs, the automator answers. Touches nothing of Weft's. |
| `support/` | Shared account provisioning, login and teardown. Arrives with the first scenario; setup is not repeated per file. |
| `test_bundle.dart` | **Generated** by `patrol_cli` on every run, and gitignored. Never edit it. |

Each scenario file must be independently runnable and must clean up the rooms it
made. The homeserver is shared across a run, so a test that leaves a room behind
poisons the next one — and on a matrix the next one is on a different device,
where the failure is much harder to read.

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
