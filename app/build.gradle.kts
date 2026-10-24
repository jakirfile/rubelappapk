plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.ijtc.rre"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "com.ijtc.rre"
        minSdk = 24
        targetSdk = 37
        versionCode = 5
        versionName = "1.11"

    }

    buildTypes {
        release {
            proguardFiles("proguard-rules.pro")
            optimization {
                enable = true
                packageScope = setOf("androidx.**", "kotlin.**", "kotlinx.**")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

dependencies {
    testImplementation(libs.junit)
}

val testDebugUnitTestTasks = tasks.matching { it.name == "testDebugUnitTest" }
val skipInstallAndRun = providers.gradleProperty("skipInstallAndRun")
    .map(String::toBoolean)
    .getOrElse(false)
val installAndRunDebugTask = tasks.register<Exec>("installAndRunDebug") {
    dependsOn("assembleDebug")
    enabled = !skipInstallAndRun
    workingDir(rootProject.projectDir)
    commandLine(
        "cmd.exe",
        "/c",
        "call",
        "\"${rootProject.file("Install-Update-Run.bat").absolutePath}\""
    )
}

tasks.configureEach {
    if (name == "assembleDebug") {
        dependsOn(testDebugUnitTestTasks)
        finalizedBy(installAndRunDebugTask)
    }
}