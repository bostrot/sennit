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
