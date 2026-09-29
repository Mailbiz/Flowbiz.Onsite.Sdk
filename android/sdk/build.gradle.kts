plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
    signing
}

// The version is kept in lockstep with SdkVersion.CURRENT and the iOS
// SDKVersion.current; the release workflow asserts all of them match the
// vX.Y.Z tag before publishing.
group = "br.com.flowbiz"
version = "0.1.0"

android {
    namespace = "br.com.flowbiz.onsite"
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
    // Zero runtime dependencies by design — Kotlin stdlib + platform APIs only.
    testImplementation(libs.junit)
    // Real org.json for local unit tests (the android.jar stub throws); test-only, not shipped.
    testImplementation(libs.json)
}

// Maven Central requires a javadoc artifact; an empty javadoc jar is the
// accepted pattern for Kotlin artifacts published without Dokka.
val emptyJavadocJar = tasks.register<Jar>("emptyJavadocJar") {
    archiveClassifier.set("javadoc")
}

publishing {
    repositories {
        // Maven Central via the Sonatype Central Portal's OSSRH-compatible
        // staging API. Credentials arrive via CI secrets — absent locally,
        // which is fine: publishToMavenLocal never touches this repository.
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
                groupId = "br.com.flowbiz"
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
                    url.set("https://github.com/Mailbiz/Flowbiz.Onsite.Sdk")
                    organization {
                        name.set("Flowbiz")
                        url.set("https://www.flowbiz.com.br/")
                    }
                    licenses {
                        license {
                            name.set("The Apache License, Version 2.0")
                            url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                            distribution.set("repo")
                        }
                    }
                    developers {
                        developer {
                            id.set("flowbiz")
                            name.set("Flowbiz")
                            email.set("derik.lopez@flowbiz.com.br")
                            organization.set("Flowbiz")
                            organizationUrl.set("https://www.flowbiz.com.br/")
                        }
                    }
                    scm {
                        connection.set("scm:git:git://github.com/Mailbiz/Flowbiz.Onsite.Sdk.git")
                        developerConnection.set("scm:git:ssh://git@github.com/Mailbiz/Flowbiz.Onsite.Sdk.git")
                        url.set("https://github.com/Mailbiz/Flowbiz.Onsite.Sdk")
                    }
                }
            }
        }
    }

    // GPG signing for Central, only when a key is provided (CI sets these
    // Gradle properties as ORG_GRADLE_PROJECT_* env vars), so local builds
    // and :sdk:publishToMavenLocal succeed with no signing setup present.
    val signingKey = providers.gradleProperty("signingInMemoryKey").orNull
    val signingPassword = providers.gradleProperty("signingInMemoryKeyPassword").orNull
    if (signingKey != null) {
        signing {
            useInMemoryPgpKeys(signingKey, signingPassword ?: "")
            sign(publishing.publications["release"])
        }
    }
}
