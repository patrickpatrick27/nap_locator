plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

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
        create("release") {
            // --- STRICT CHECK: CRASH IF KEYS MISSING ---
            if (!keystorePropertiesFile.exists()) {
                 throw GradleException("❌ BUILD STOPPED: key.properties not found! Check your GitHub Secrets.")
            }
            
            // Force load keys. If any are missing, it will crash and tell us which one.
            keyAlias = keystoreProperties.getProperty("keyAlias") ?: throw GradleException("❌ Missing keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword") ?: throw GradleException("❌ Missing keyPassword")
            storeFile = file(keystoreProperties.getProperty("storeFile") ?: throw GradleException("❌ Missing storeFile"))
            storePassword = keystoreProperties.getProperty("storePassword") ?: throw GradleException("❌ Missing storePassword")
            
            // Valid Signatures for Android 11+
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    defaultConfig {
        applicationId = "com.example.training"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        getByName("debug") {
            // Your separation logic
            applicationIdSuffix = ".debug"
            resValue("string", "app_name", "NAP Finder (Dev)")
        }

        getByName("release") {
            resValue("string", "app_name", "NAP Finder")
            
            // FORCE the release config. Do not use 'if'.
            signingConfig = signingConfigs.getByName("release")
            
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}