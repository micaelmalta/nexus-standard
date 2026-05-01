plugins {
    kotlin("jvm") version "2.2.0"
    application
    `maven-publish`
    signing
    id("io.github.gradle-nexus.publish-plugin") version "2.0.0"
    id("org.jlleitschuh.gradle.ktlint") version "12.1.2"
}

group = "io.github.micaelmalta"
version = "1.0.0"

repositories { mavenCentral() }

dependencies {
    implementation("org.json:json:20240303")
}

application {
    mainClass.set("nxs.TestKt")
}

tasks.register<JavaExec>("bench") {
    group = "application"
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("nxs.BenchKt")
    args = listOf("../js/fixtures")
}

tasks.register<JavaExec>("conformance") {
    group = "verification"
    description = "Run NXS conformance vectors (expects ../conformance/ from kotlin/)"
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("nxs.ConformanceKt")
    args("../conformance/")
}

kotlin {
    jvmToolchain(21)
}

// No Java sources in this project — suppress the toolchain consistency check.
tasks.withType<JavaCompile> {
    options.release.set(21)
}

// ── Maven publish ─────────────────────────────────────────────────────────────

java {
    withJavadocJar()
    withSourcesJar()
}

publishing {
    publications {
        create<MavenPublication>("mavenJava") {
            from(components["java"])
            artifactId = "nexus-standard"

            pom {
                name.set("nexus-standard")
                description.set("Zero-copy reader for the Nexus Standard (NXS) binary format")
                url.set("https://github.com/micaelmalta/nxs")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
                developers {
                    developer {
                        id.set("micaelmalta")
                        name.set("Micael Malta")
                    }
                }
                scm {
                    connection.set("scm:git:git://github.com/micaelmalta/nxs.git")
                    developerConnection.set("scm:git:ssh://github.com/micaelmalta/nxs.git")
                    url.set("https://github.com/micaelmalta/nxs")
                }
            }
        }
    }
    repositories {
        maven {
            name = "sonatype"
            val releasesUrl = uri("https://s01.oss.sonatype.org/service/local/staging/deploy/maven2/")
            val snapshotsUrl = uri("https://s01.oss.sonatype.org/content/repositories/snapshots/")
            url = if (version.toString().endsWith("SNAPSHOT")) snapshotsUrl else releasesUrl
            credentials {
                username = findProperty("ossrhUsername") as String? ?: System.getenv("OSSRH_USERNAME")
                password = findProperty("ossrhPassword") as String? ?: System.getenv("OSSRH_PASSWORD")
            }
        }
    }
}

signing {
    val signingKey = System.getenv("GPG_SIGNING_KEY")
    val signingPassword = System.getenv("GPG_SIGNING_PASSWORD")
    if (signingKey != null && signingPassword != null) {
        useInMemoryPgpKeys(signingKey, signingPassword)
    }
    sign(publishing.publications["mavenJava"])
}

// ── Nexus staging / release ───────────────────────────────────────────────────

nexusPublishing {
    repositories {
        sonatype {
            nexusUrl.set(uri("https://s01.oss.sonatype.org/service/local/"))
            snapshotRepositoryUrl.set(uri("https://s01.oss.sonatype.org/content/repositories/snapshots/"))
            username.set(System.getenv("OSSRH_USERNAME") ?: "")
            password.set(System.getenv("OSSRH_PASSWORD") ?: "")
        }
    }
}
