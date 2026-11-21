# flutter_inappwebview_android 1.1.3, Android project only

A copy of the `android/` directory of
[flutter_inappwebview_android 1.1.3](https://pub.dev/packages/flutter_inappwebview_android/versions/1.1.3)
(Apache-2.0, see `LICENSE`), used by `settings.gradle.kts` in place of the one
in the pub cache. The plugin's Dart code is still resolved from pub.

The one change: both build types in `build.gradle` name
`proguard-android-optimize.txt` instead of `proguard-android.txt`, which
Android Gradle Plugin 9 rejects while evaluating the file. The library's own
`proguardFiles` do not reach the app (only `consumerProguardFiles` do), so this
changes nothing in what is built.

Delete this directory and the override in `settings.gradle.kts` once a
non-beta release of the plugin ships the fix (1.2.0-beta.3 already has it).
`settings.gradle.kts` fails the build if the resolved version is not 1.1.3.
