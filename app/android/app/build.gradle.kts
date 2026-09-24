// ============================================================================
// GlobeOrFlat — Android app module (Flutter Kotlin-DSL template, tuned).
// SPDX-License-Identifier: MIT
//
// minSdk 23 is a HARD requirement: the GOFv1 device key is an EC P-256 pair
// in the hardware-backed Android Keystore (SHA256withECDSA), see
// MainActivity.kt / keystore_service.dart. geolocator also requires 23.
//
// Release signing: falls back to the debug key (Flutter template default) so
// the GitHub-Actions APK is installable out of the box. For Play Store
// uploads add keystore.properties + a signingConfigs block later.
// ============================================================================

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.globeorflat.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "dev.globeorflat.app"
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO(play-store): real signing config via keystore.properties.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
