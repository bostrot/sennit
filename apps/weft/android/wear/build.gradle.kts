plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The Wear OS companion. A **separate APK for a separate device**, which is why
// it is a separate module rather than a source set of `:app`: the phone build is
// driven by the Flutter Gradle Plugin and carries a Flutter engine, an NDK, a
// WebRTC stack and sixty plugins, and none of that belongs on a watch.
//
// It also does not apply `dev.flutter.flutter-gradle-plugin`, and that is the
// whole architectural claim of this module in one line: there is no Dart here,
// no Matrix session, and no way to decrypt anything. The watch renders a
// snapshot the phone chose to send it and asks the phone to send messages on its
// behalf. See `docs/architecture/companion-surfaces.md`.
android {
    // Distinct from the phone's, so the two `R` classes and the two
    // `BuildConfig`s cannot be confused for each other in a file that shares a
    // source directory with both.
    namespace = "com.bostrot.weft.wear"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // **The same applicationId as the phone app, deliberately.** Wear OS
        // pairs a watch app to a phone app by package name and signing
        // certificate — that is the entire mechanism — and a watch APK with an
        // id of its own is an app the Data Layer will happily deliver nothing
        // to, silently, forever.
        applicationId = "com.bostrot.weft"
        // Wear OS 3. Below it there is no Compose for Wear, no ProtoLayout tile
        // and no Data Layer worth targeting, and a Wear 2 watch runs its own
        // embedded-APK distribution model that this module deliberately does not
        // participate in.
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    // The snapshot parser and the Data Layer contract, compiled from the same
    // files `:app` compiles. Not a dependency between the modules — neither of
    // these two APKs is a library for the other — and not a copy. See
    // `android/shared/src/main/kotlin/com/bostrot/weft/snapshot/SnapshotPayload.kt`.
    sourceSets["main"].kotlin.srcDir("../shared/src/main/kotlin")

    buildFeatures {
        compose = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed with the debug key, matching `:app`. The pairing rule above
            // makes this more than a convenience: a watch APK signed with a
            // different certificate than the phone APK is not the same app, and
            // the Data Layer will not connect them.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.3")

    // Compose for Wear. `androidx.wear.compose` rather than
    // `androidx.compose.material3`: they are not the same library and the
    // difference is not cosmetic — `ScalingLazyColumn` is what makes a list
    // readable on a round screen, and a phone `LazyColumn` on a watch clips its
    // first and last rows against the bezel.
    implementation("androidx.wear.compose:compose-material:1.4.1")
    implementation("androidx.wear.compose:compose-foundation:1.4.1")
    implementation("androidx.wear.compose:compose-navigation:1.4.1")

    // The Data Layer, which is the only way anything reaches this device.
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
    // `Task.await()`. Play services speaks `Task` and everything above speaks
    // `suspend`; without this the bridge between them is a callback pyramid
    // inside a `TileService` request the system is already timing out.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.8.1")

    // Dictation. `RemoteInputIntentHelper` builds the intent that opens the
    // system's input picker — voice, keyboard, emoji, drawn characters,
    // whichever the watch has — rather than this module deciding that dictation
    // is the only way anyone replies.
    implementation("androidx.wear:wear-input:1.1.0")

    // The tile. Tiles 1.4 renders through ProtoLayout, which is a *description*
    // of a layout serialised to the system's own renderer — there is no Compose
    // in a tile's process, which is the same constraint Glance has on the phone
    // and for the same reason.
    implementation("androidx.wear.tiles:tiles:1.4.1")
    // `TileService` answers with a `ListenableFuture`. Everything this tile
    // needs is a `SharedPreferences` read, so the future is already resolved
    // when it is created — `ResolvableFuture` is that, without dragging Guava
    // proper in for one call.
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    implementation("androidx.wear.protolayout:protolayout:1.2.1")
    implementation("androidx.wear.protolayout:protolayout-material:1.2.1")
    implementation("androidx.wear.protolayout:protolayout-expression:1.2.1")

    // The complication. `SuspendingComplicationDataSourceService` is the ktx
    // half; without it every data source is a callback the system times out.
    implementation("androidx.wear.watchface:watchface-complications-data-source-ktx:1.2.1")
}
