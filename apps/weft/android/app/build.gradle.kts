import java.util.Properties

plugins {
    id("com.android.application")
    // Declared explicitly rather than left to the Flutter Gradle Plugin, which
    // applies `kotlin-android` for a module that does not name it. The Compose
    // compiler plugin below has to be applied *after* KGP, and "after" is only
    // a thing that can be said about plugins this block lists.
    id("org.jetbrains.kotlin.android")
    // Glance. See settings.gradle.kts for why the Compose compiler is in a
    // Flutter app at all.
    id("org.jetbrains.kotlin.plugin.compose")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads android/key.properties (gitignored) first and the
// environment second — the latter is how CI provides it. With neither, the
// debug keystore signs, so `flutter run --release` works on a fresh checkout
// without any setup.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { stream -> load(stream) }
}

fun signingValue(key: String, env: String): String? =
    keystoreProperties.getProperty(key) ?: System.getenv(env)

android {
    namespace = "com.bostrot.weft"
    // flutter_secure_storage compiles against SDK 37; Flutter's default is
    // still 36. compileSdk is backward compatible, so pin to the higher one.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications, which schedules against
        // `java.time` and so needs the desugared JDK library on every API level
        // Weft supports. Without it the whole Android build fails at
        // `checkDebugAarMetadata` — not at runtime — so it is the notification
        // plugin's hard prerequisite rather than a nicety.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bostrot.weft"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Patrol's runner, not AndroidX's default. It starts the app under
        // instrumentation, stands up the native automator that drives
        // UIAutomator outside the Flutter view, and enumerates the Dart tests
        // in the bundle so each becomes its own JUnit case. See
        // `src/androidTest/.../MainActivityTest.java`.
        testInstrumentationRunner = "pl.leancode.patrol.PatrolJUnitRunner"
        // Every Dart test is a separate instrumentation invocation, so app
        // state — the sqflite session database above all — would otherwise
        // survive from one scenario into the next. `docs/quality/e2e-matrix.md`
        // requires each test to be independently runnable; this is the half of
        // that promise the harness can keep on its own.
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
    }

    // The snapshot parser, compiled from `android/shared/` into this module and
    // into `:wear`. Not a library module and not a dependency between the two
    // apps: they are two APKs that ship separately, neither is a library for the
    // other, and the one file they share has `org.json` as its entire dependency
    // surface. The same arrangement `ios/Shared/` has, where
    // `SnapshotContainer.swift` is a member of four Xcode targets.
    sourceSets["main"].kotlin.srcDir("../shared/src/main/kotlin")

    buildFeatures {
        // Glance composables only. There is no Compose UI in Weft — the app is
        // Flutter — but a `GlanceAppWidget` is compiled by the Compose compiler
        // like any other `@Composable`, and AGP will not run it without this.
        compose = true
    }

    testOptions {
        // `clearPackageData` is an orchestrator argument: without the
        // orchestrator it is silently ignored, and the tests leak state into
        // each other in a way that only shows up as a second run failing.
        execution = "ANDROIDX_TEST_ORCHESTRATOR"
    }

    signingConfigs {
        create("release") {
            val storePath = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
            if (storePath != null) {
                storeFile = file(storePath)
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (signingConfigs.getByName("release").storeFile != null) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            // R8 runs on release; the rules keep the classes native code
            // resolves reflectively (ONNX Runtime above all — see the file).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // `ShortcutManagerCompat` and `IconCompat`, for the conversation shortcuts
    // a notification needs before Android will let it become a bubble. Both
    // arrive transitively through the Flutter embedding today; declared
    // explicitly because MainActivity imports them directly, and a transitive
    // dependency that a plugin upgrade drops would break the build with an
    // unresolved import rather than a version conflict.
    implementation("androidx.core:core-ktx:1.13.1")
    // Hands the conversation shortcuts `ShareShortcuts` pushes to Google's
    // surfaces as well as the launcher — the assistant (Gemini, Assistant)
    // only learns who can be messaged in Sennit from shortcuts it receives
    // through this library. It adds no API of its own: it registers a listener
    // that `ShortcutManagerCompat.pushDynamicShortcut` and the removals call.
    implementation("androidx.core:core-google-shortcuts:1.1.0")
    // The home screen widgets. Glance is the only way to build an AppWidget
    // without hand-writing `RemoteViews` against a layout XML per state, and
    // this widget has five states.
    //
    // 1.1.1 rather than the 1.2/1.3 pre-releases on purpose: this is a surface
    // that runs in the *launcher's* process, where a regression is a crash the
    // user attributes to their home screen rather than to Weft, and there is
    // nothing in the newer line these two widgets need.
    implementation("androidx.glance:glance-appwidget:1.1.1")
    // Deliberately *not* `androidx.glance:glance-material3`. It is the obvious
    // way to build a `ColorProviders` — hand it a `lightColorScheme` and a
    // `darkColorScheme` — but it does not expose Compose Material 3 to its
    // consumers, so using it means adding `androidx.compose.material3` here,
    // which drags Compose UI, Foundation and Animation into an APK whose entire
    // user interface is Flutter. `WeftWidgetTokens` builds the same palette out
    // of colour resources instead; see the comment there.
    // The Wearable Data Layer, and the only reason this APK links Play
    // services. It is confined to `com.bostrot.weft.wear` — the store the Glance
    // providers read must not acquire this dependency, which is what
    // `WeftSnapshotStore.notifySurfaces` says and this is the other half of.
    //
    // Play services is present on the overwhelming majority of Android phones
    // and absent on some; every call through `WeftWearBridge` is wrapped for
    // exactly that, because a device with no Play services and no watch is not
    // an error state, it is most Weft users.
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
    // Sign-in in the person's own browser (BrowserAuth.kt). 1.9 is the
    // first with Auth Tabs, which return the redirect to Sennit alone; the
    // in-app web view plugin brings 1.8, and this lifts it.
    implementation("androidx.browser:browser:1.9.0")
    // The other half of `isCoreLibraryDesugaringEnabled` above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // The other half of `execution = "ANDROIDX_TEST_ORCHESTRATOR"`. It is an
    // APK installed alongside the test APK rather than a library linked into
    // it, which is why it is `androidTestUtil` and not
    // `androidTestImplementation`. The Patrol runtime itself arrives through
    // the `patrol` Flutter plugin's own Gradle module and is not declared here.
    androidTestUtil("androidx.test:orchestrator:1.5.1")
}

flutter {
    source = "../.."
}
