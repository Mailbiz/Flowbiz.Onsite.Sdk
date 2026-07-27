plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.flowbiz.onsite.demo"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.flowbiz.onsite.demo"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Environment switch pattern: the host app (not the SDK) picks the
    // collector per build type, so QA builds can't ship pointing at staging
    // and store builds can't point away from prod.
    buildFeatures {
        buildConfig = true
    }
    buildTypes {
        debug {
            buildConfigField("String", "COLLECTOR_URL", "\"https://collector.stg.mbzlabs.me\"")
        }
        release {
            buildConfigField("String", "COLLECTOR_URL", "\"https://collector.mailbiz.one\"")
        }
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":sdk"))

    testImplementation(libs.junit)
}
