pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // The Compose compiler, for Glance. Since Kotlin 2.0 it ships as a Gradle
    // plugin versioned in lockstep with KGP rather than as a compiler-extension
    // version pinned in the module — so this string and the one above are one
    // version written twice and must move together.
    //
    // Weft's own UI is Flutter and always will be; this is here only because a
    // `GlanceAppWidget` is a `@Composable`, drawn by the launcher in a process
    // with no Flutter engine in it. See `app/src/main/kotlin/.../widget/`.
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.20" apply false
}

include(":app")

// flutter_inappwebview_android 1.1.3 asks for `proguard-android.txt`, which
// AGP 9 refuses while it evaluates the plugin's build file, so a release build
// stops before it starts. Its Android project is built from a copy that differs
// only in naming `proguard-android-optimize.txt` instead (see
// `third_party/flutter_inappwebview_android/README.md`); the plugin's Dart code
// still comes from pub. Remove this once the plugin ships the fix.
findProject(":flutter_inappwebview_android")?.let { plugin ->
    if (!plugin.projectDir.path.contains("flutter_inappwebview_android-1.1.3")) {
        throw GradleException(
            "flutter_inappwebview_android is no longer 1.1.3 (${plugin.projectDir}): " +
                "drop the patched copy in third_party/ and this override, or refresh it.",
        )
    }
    plugin.projectDir = file("third_party/flutter_inappwebview_android")
}

// The Wear OS companion: a separate APK for a separate device, built by
// `./gradlew :wear:assembleDebug` and *not* by `flutter build apk`, which only
// ever asks for `:app`. It applies no Flutter plugin and contains no Dart — see
// `wear/build.gradle.kts` and `wear/README.md`.
include(":wear")
