/// What the device suite is told about the world it runs in, and how long it is
/// willing to wait for that world to answer.
///
/// Every value here is a `String.fromEnvironment` or a constant, and never a
/// `Platform.environment` read. A compiled Flutter test binary on a device has
/// no shell to read an environment from — `tooling/scripts/e2e.sh` passes these
/// through `patrol test --dart-define`, and getting that wrong produces a
/// connection error that reads like a homeserver which never came up.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

/// The address *the device* reaches Synapse on.
///
/// Not necessarily the address this machine uses. `localhost:8008` is the
/// device's own loopback, so an Android emulator is given `10.0.2.2:8008` and a
/// physical device either the host's LAN address or `adb reverse`. `e2e.sh`
/// picks it; the table is in `docs/quality/e2e-matrix.md`.
const String kHomeserver = String.fromEnvironment(
  'WEFT_HOMESERVER',
  defaultValue: 'localhost:8008',
);

/// The password `tooling/docker/seed.sh` registered both accounts with.
const String kTestPassword = String.fromEnvironment(
  'WEFT_TEST_PASSWORD',
  defaultValue: 'weft-test-password',
);

/// The homeserver's `server_name`, which is the domain half of every user id.
///
/// Separate from [kHomeserver] because they are genuinely different facts: the
/// compose file names the server `localhost` whatever port or alias a device
/// reaches it on, so `@alice:localhost` stays correct from an emulator that
/// connects to `10.0.2.2:8008`.
const String kServerName = String.fromEnvironment(
  'WEFT_SERVER_NAME',
  defaultValue: 'localhost',
);

/// The account the *app* signs in as. Everything driven through the UI is this
/// user.
const String kAppUser = 'alice';

/// The account the *peer* signs in as — a headless session in the test process,
/// never the app.
const String kPeerUser = 'bob';

/// A localpart as the full Matrix id the homeserver knows it by.
String matrixUserId(String localpart) => '@$localpart:$kServerName';

/// What the OS calls Weft.
///
/// The `applicationId` in `android/app/build.gradle.kts`, the
/// `PRODUCT_BUNDLE_IDENTIFIER` of the `Runner` target, and the two ids in the
/// pubspec's `patrol:` block — all four are this string, and the native
/// automator needs it to tell Weft's own windows from the ones the OS puts in
/// front of them.
const String kAppId = 'com.bostrot.weft';

/// What the launcher calls Weft, which is not the same thing.
///
/// `android:label` in the manifest, lower-case, and it is what a system share
/// sheet writes under the app's icon — so it is how a test taps "share this to
/// Weft" in a chooser that is not Weft's to draw.
const String kAndroidAppLabel = 'weft';

/// How long a UI transition that waits on nothing but Flutter may take.
const Duration kUiDeadline = Duration(seconds: 20);

/// How long a *native* surface may take to appear.
///
/// Generous for the same reason [kSyncDeadline] is, and then some: the first
/// tap of a run launches another application. Android's documents picker and
/// its share sheet are cold-started processes on an emulator that is already
/// busy running Weft, and ten seconds — Patrol's own default — is comfortably
/// less than that takes.
const Duration kNativeDeadline = Duration(seconds: 60);

/// How long a UI transition that waits on the *homeserver* may take.
///
/// Generous on purpose. A device is slower than a laptop, an emulator slower
/// again, and the first sync after a login pulls the whole account down — a
/// deadline tuned on a desktop is the single most common source of failures
/// that look like bugs and are not.
const Duration kSyncDeadline = Duration(seconds: 60);

/// How long the whole of sign-in may take, from the login screen to the inbox.
///
/// Longer than [kSyncDeadline] because it contains one: a fresh login uploads
/// device keys, performs a first sync, and — on the first run against a clean
/// homeserver — generates one-time keys before either.
const Duration kSignInDeadline = Duration(seconds: 120);

/// How long to leave between one test's app and the next one's.
///
/// `flutter_test` unmounts the whole tree between tests
/// (`binding.dart`'s `runApp(Container(...))`, before and after every body), so
/// each scenario launches Weft for itself — and the unmount is what disposes the
/// previous `ProviderScope` and with it `WeftMatrixSession`. `dispose` is async
/// and a provider's `onDispose` cannot await it, while sqflite serialises open
/// and close per *path* and does not reference-count: relaunching into the same
/// database file while the previous close is still queued hands the new session
/// a database the old one is about to close underneath it.
///
/// A pause is not a proof, and this is the one place in the suite that waits on
/// a clock rather than on a condition. There is nothing observable to wait for —
/// the future being raced is one no caller holds. Raise it from the command line
/// if a row shows `database_closed` on its second test.
const Duration kRelaunchGrace = Duration(
  milliseconds: int.fromEnvironment(
    'WEFT_RELAUNCH_GRACE_MS',
    defaultValue: 2000,
  ),
);

/// How long a scenario may take before Patrol kills it.
///
/// Per test rather than per file. Two logins, a room creation and an encrypted
/// round trip is minutes on a cold emulator, and the default 30 s would fail
/// every row in the matrix for the same wrong reason.
const Timeout kScenarioTimeout = Timeout(Duration(minutes: 8));

/// Patrol's own waits, raised from the 10 s defaults.
///
/// `settleTimeout` is *lowered* instead: the default `SettlePolicy.trySettle`
/// runs after every tap, and Weft has several legitimately infinite animations
/// on screen — the splash spinner, the sign-in button's progress ring — so every
/// tap during startup would otherwise spend the full settle timeout achieving
/// nothing before carrying on.
const PatrolTesterConfig kWeftPatrolConfig = PatrolTesterConfig(
  existsTimeout: Duration(seconds: 30),
  visibleTimeout: Duration(seconds: 30),
  settleTimeout: Duration(seconds: 5),
  printLogs: true,
);

/// A body no other run, and no other test in this run, can have written.
///
/// Every assertion in this suite finds a message by its text, and the homeserver
/// is shared across a whole matrix run: a fixed string like "hello" would be
/// matched against a message some other row sent an hour ago, in a room this
/// test does not know about. The counter covers two sends in the same
/// microsecond; the timestamp covers two runs.
String uniqueBody(String prefix) =>
    '$prefix ${DateTime.now().microsecondsSinceEpoch}-${_bodyCounter++}';

int _bodyCounter = 0;
