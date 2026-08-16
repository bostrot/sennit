allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Some plugins pin an older compileSdk than their own dependencies require —
// whisper_ggml compiles against 34 while the ffmpeg library it depends on
// demands 35+, which fails the AAR metadata check. compileSdk is backward
// compatible, so lifting every plugin module to the app's level is safe and
// avoids waiting on an upstream release.
//
// This must be registered *before* the `evaluationDependsOn` block below:
// that call evaluates each subproject immediately, and `afterEvaluate` on an
// already-evaluated project is an error.
subprojects {
    afterEvaluate {
        extensions.findByType<com.android.build.gradle.LibraryExtension>()
            ?.let { android ->
                if ((android.compileSdk ?: 0) < 36) {
                    android.compileSdk = 36
                }
            }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
