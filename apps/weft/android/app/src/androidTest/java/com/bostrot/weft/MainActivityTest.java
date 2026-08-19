package com.bostrot.weft;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import pl.leancode.patrol.PatrolJUnitRunner;

/**
 * The Android entry point for Weft's Patrol suite.
 *
 * <p>There is exactly one of these and it is not a test in any ordinary sense —
 * it is the bridge between JUnit on the device and the Dart tests in
 * {@code integration_test/patrol/}. {@code listDartTests()} asks the running app
 * which Dart tests the bundle contains and returns them as JUnit parameters, so
 * each Dart test becomes its own JUnit case with its own name in the report. A
 * single {@code @Test} that ran the whole bundle would collapse thirteen
 * scenarios into one red or green line, which is precisely what a device matrix
 * cannot afford.
 *
 * <p>Written in Java rather than Kotlin on purpose: {@code @Parameters} is a
 * static method returning {@code Object[]}, and every Patrol upgrade note is
 * written against this file verbatim. There is nothing project-specific in it
 * beyond {@link MainActivity}.
 *
 * <p>Nothing here starts the homeserver. {@code tooling/scripts/e2e.sh} does
 * that before {@code patrol test} is invoked, and the Dart side reads its
 * address from {@code --dart-define=WEFT_HOMESERVER} — which on an emulator is
 * {@code 10.0.2.2:8008}, not {@code localhost:8008}. See
 * {@code docs/quality/e2e-matrix.md}.
 */
@RunWith(Parameterized.class)
public class MainActivityTest {
    @Parameters(name = "{0}")
    public static Object[] testCases() {
        PatrolJUnitRunner instrumentation =
                (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
        return instrumentation.listDartTests();
    }

    private final String dartTestName;

    public MainActivityTest(String dartTestName) {
        this.dartTestName = dartTestName;
    }

    @Test
    public void runDartTest() {
        PatrolJUnitRunner instrumentation =
                (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.runDartTest(dartTestName);
    }
}
