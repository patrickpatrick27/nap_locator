plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

// 1. Load the Key Properties safely
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.training"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        // 2. Only create the "release" config IF the key properties were loaded
        if (keystoreProperties["keyAlias"] != null) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        applicationId = "com.example.training"
        
        // 3. SAFE VERSION LOADING (Prevents crash if pubspec.yaml version is missing)
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        getByName("debug") {
            // --- DEBUG CONFIGURATION ---
            // 1. Changes ID to "com.example.training.debug" so it installs separately from release
            applicationIdSuffix = ".debug"
            
            // 2. Changes App Name to "NAP Finder (Dev)" so you can tell them apart
            resValue("string", "app_name", "NAP Finder (Dev)")
        }

        getByName("release") {
            // --- RELEASE CONFIGURATION ---
            // 1. Keeps original ID "com.example.training"
            // 2. Sets App Name to real name "NAP Finder"
            resValue("string", "app_name", "NAP Finder")

            // 3. Safe Signing Config Assignment
            if (signingConfigs.findByName("release") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
            
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}