plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
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
    // `ShortcutManagerCompat` and `IconCompat`, for the conversation shortcuts
    // a notification needs before Android will let it become a bubble. Both
    // arrive transitively through the Flutter embedding today; declared
    // explicitly because MainActivity imports them directly, and a transitive
    // dependency that a plugin upgrade drops would break the build with an
    // unresolved import rather than a version conflict.
    implementation("androidx.core:core-ktx:1.13.1")
    // The other half of `isCoreLibraryDesugaringEnabled` above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
