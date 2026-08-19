// The iOS entry point for Weft's Patrol suite — the XCUITest counterpart of
// `android/app/src/androidTest/.../MainActivityTest.java`.
//
// `PATROL_INTEGRATION_TEST_IOS_RUNNER` is a macro that writes the whole test
// class: it asks the running app which Dart tests the bundle contains and
// synthesises one XCTest method per test, so each scenario gets its own name in
// the report instead of thirteen collapsing into one red line. There is nothing
// to add to it and nothing project-specific in it.
//
// Objective-C rather than Swift because the macro is a C preprocessor macro
// that declares an ObjC class; there is no Swift form of it.
//
// This target is authored but **unsigned** — see
// `docs/decisions/adr-002-ios-signing-handoff.md`. A UI test bundle needs its
// own provisioning profile, distinct from the app's, and no signing identity
// exists in this repository. Until one does, the iOS rows of
// `docs/quality/e2e-matrix.md` are not-executed rather than failing.

@import XCTest;
@import patrol;
@import ObjectiveC.runtime;

PATROL_INTEGRATION_TEST_IOS_RUNNER(RunnerUITests)
