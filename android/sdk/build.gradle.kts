plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
    signing
}

// SPEC §13 distribution coordinates (Maven Central: com.flowbiz:onsite-sdk).
// The version is kept in lockstep with SdkVersion.CURRENT and the iOS
// SDKVersion.current; the release workflow asserts all of them match the
// vX.Y.Z tag before publishing.
group = "com.flowbiz"
version = "0.1.0"

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

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
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

// Maven Central requires a javadoc artifact; an empty javadoc jar is the
// accepted pattern for Kotlin artifacts published without Dokka (adding
// Dokka would violate the zero-dependency build minimalism; revisit if
// rendered API docs are ever wanted).
val emptyJavadocJar = tasks.register<Jar>("emptyJavadocJar") {
    archiveClassifier.set("javadoc")
}

publishing {
    repositories {
        // Maven Central via the Sonatype Central Portal's OSSRH-compatible
        // staging API. TODO(SPEC §13): com.flowbiz namespace registration in
        // the Central Portal is pending; credentials arrive via CI secrets
        // (CENTRAL_USERNAME / CENTRAL_PASSWORD) — absent locally, which is
        // fine: publishToMavenLocal never touches this repository.
        maven {
            name = "central"
            url = uri("https://ossrh-staging-api.central.sonatype.com/service/local/staging/deploy/maven2/")
            credentials {
                username = providers.environmentVariable("CENTRAL_USERNAME").orNull
                password = providers.environmentVariable("CENTRAL_PASSWORD").orNull
            }
        }
    }
}

// AGP creates the "release" software component after project evaluation,
// so the publication (and its conditional signing) is wired in afterEvaluate
// — the documented AGP pattern.
afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                groupId = "com.flowbiz"
                artifactId = "onsite-sdk"
                version = project.version.toString()
                from(components["release"])
                artifact(emptyJavadocJar)

                pom {
                    name.set("Flowbiz Onsite SDK")
                    description.set(
                        "Native Android tracking SDK for the Flowbiz Onsite platform: typed event " +
                            "tracking with a durable offline queue, session/identity management, " +
                            "push token relay and cart-recovery deep-link decoding."
                    )
                    // TODO(SPEC §13): placeholder URLs — confirm the public repository
                    // location before the first Central release.
                    url.set("https://github.com/flowbiz/flowbiz-onsite-sdk")
                    licenses {
                        license {
                            // Proprietary placeholder (see /LICENSE at the repo root);
                            // flagged for legal review before 1.0 (SPEC §13).
                            name.set("All rights reserved")
                            url.set("https://github.com/flowbiz/flowbiz-onsite-sdk/blob/main/LICENSE")
                            distribution.set("repo")
                        }
                    }
                    developers {
                        developer {
                            id.set("flowbiz")
                            name.set("Flowbiz")
                            // TODO(SPEC §13): placeholder contact — set before the first release.
                            email.set("sdk@flowbiz.example")
                        }
                    }
                    scm {
                        connection.set("scm:git:git://github.com/flowbiz/flowbiz-onsite-sdk.git")
                        developerConnection.set("scm:git:ssh://git@github.com/flowbiz/flowbiz-onsite-sdk.git")
                        url.set("https://github.com/flowbiz/flowbiz-onsite-sdk")
                    }
                }
            }
        }
    }

    // GPG signing for Central (SPEC §13). Activates only when a key is
    // provided — via the signingInMemoryKey/signingInMemoryKeyPassword
    // Gradle properties (CI sets them as ORG_GRADLE_PROJECT_* env vars) —
    // so local builds and :sdk:publishToMavenLocal succeed with no signing
    // setup present.
    val signingKey = providers.gradleProperty("signingInMemoryKey").orNull
    val signingPassword = providers.gradleProperty("signingInMemoryKeyPassword").orNull
    if (signingKey != null) {
        signing {
            useInMemoryPgpKeys(signingKey, signingPassword ?: "")
            sign(publishing.publications["release"])
        }
    }
}
