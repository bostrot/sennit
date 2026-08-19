// The macOS entry point for Weft's Patrol suite — the desktop counterpart of
// `../../ios/RunnerUITests/RunnerUITests.m` and of
// `../../android/app/src/androidTest/.../MainActivityTest.java`.
//
// `PATROL_INTEGRATION_TEST_MACOS_RUNNER` is a macro that writes the whole test
// class: it asks the running app which Dart tests the bundle contains and
// synthesises one XCTest method per test, so each scenario gets its own name in
// the report instead of collapsing into one red line. There is nothing to add
// to it and nothing project-specific in it.
//
// Objective-C rather than Swift because the macro is a C preprocessor macro
// that declares an ObjC class; there is no Swift form of it.
//
// ## Why this target exists at all, when macOS has no native automator
//
// `docs/quality/e2e-matrix.md` is explicit that macOS is not a Patrol row in the
// sense that matters most — Patrol's platform automation is Android, iOS and
// Web, so there is no permission-dialog driving, no Notification Center and no
// NSOpenPanel handling here. What macOS *does* run is every scenario whose
// assertions live inside the Flutter view, plus deep links, which Launch
// Services delivers to a running app.
//
// Running even those needs this target. `patrol test -d macos` shells out to
// `xcodebuild build-for-testing -scheme Runner` and then looks for a
// `Runner_macosx*.xctestrun`; with no UI-test bundle in the scheme's test
// action there is nothing to produce one, and the run dies on "No .xctestrun
// file was found". `flutter test -d macos` is not an alternative: it installs
// `IntegrationTestWidgetsFlutterBinding` before the test file loads, and
// `PatrolBinding` is a `LiveTestWidgetsFlutterBinding` — the two cannot coexist.
//
// Unlike the iOS bundle beside it, this one needs **no signing identity**. The
// project signs macOS ad hoc (`CODE_SIGN_IDENTITY = "-"` at the project level)
// and a locally-run XCUITest bundle is happy with that, which is why the MAC
// row of the matrix is executable on an ordinary developer machine and a GitHub
// `macos-*` runner while the iOS rows wait on ADR-002.

@import XCTest;
@import patrol;
@import ObjectiveC.runtime;

PATROL_INTEGRATION_TEST_MACOS_RUNNER(RunnerUITests)
