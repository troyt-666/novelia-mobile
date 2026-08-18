import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningProperties = Properties()
val releaseSigningPropertiesFile = rootProject.file("key.properties")
if (releaseSigningPropertiesFile.isFile) {
    releaseSigningPropertiesFile.inputStream().use(releaseSigningProperties::load)
}

fun releaseSigningValue(property: String, environment: String): String? =
    (releaseSigningProperties.getProperty(property) ?: System.getenv(environment))
        ?.trim()
        ?.takeIf(String::isNotEmpty)

val releaseStoreFile = releaseSigningValue("storeFile", "NOVELIA_ANDROID_STORE_FILE")
val releaseStorePassword =
    releaseSigningValue("storePassword", "NOVELIA_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("keyAlias", "NOVELIA_ANDROID_KEY_ALIAS")
val releaseKeyPassword =
    releaseSigningValue("keyPassword", "NOVELIA_ANDROID_KEY_PASSWORD")
val releaseSigningValues = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val hasReleaseSigning = releaseSigningValues.all { it != null }
if (!hasReleaseSigning && releaseSigningValues.any { it != null }) {
    throw GradleException(
        "Android release signing is only partially configured. " +
            "Provide storeFile, storePassword, keyAlias, and keyPassword.",
    )
}

android {
    namespace = "dev.novelia.novelia_reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.novelia.novelia_reader"
        // Account sessions use an AES-GCM key held by Android Keystore.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Never create a distributable build with Flutter's shared debug
            // certificate. Without private signing inputs Gradle emits an
            // unsigned release artifact suitable only for compilation checks.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
