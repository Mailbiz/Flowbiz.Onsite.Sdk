plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.flowbiz.onsite"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // Zero runtime dependencies by design (SPEC §1) — Kotlin stdlib + platform APIs only.
    testImplementation(libs.junit)
    // Real org.json for local unit tests (the android.jar stub throws); test-only, not shipped.
    testImplementation(libs.json)
}
