plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val helperSigningEnvironment = listOf(
    "DEVICE_BRIDGE_HELPER_KEYSTORE",
    "DEVICE_BRIDGE_HELPER_STORE_PASSWORD",
    "DEVICE_BRIDGE_HELPER_KEY_ALIAS",
    "DEVICE_BRIDGE_HELPER_KEY_PASSWORD",
).associateWith { providers.environmentVariable(it).orNull }
val configuredSigningValues = helperSigningEnvironment.filterValues { !it.isNullOrBlank() }
check(configuredSigningValues.isEmpty() || configuredSigningValues.size == helperSigningEnvironment.size) {
    "Set all DEVICE_BRIDGE_HELPER_* signing variables or none of them."
}
val hasInternalReleaseSigning = configuredSigningValues.size == helperSigningEnvironment.size

android {
    namespace = "dev.debugutility.helper"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.debugutility.helper"
        minSdk = 30
        targetSdk = 35
        versionCode = 4
        versionName = "0.4.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        if (hasInternalReleaseSigning) {
            create("internalRelease") {
                storeFile = file(helperSigningEnvironment.getValue("DEVICE_BRIDGE_HELPER_KEYSTORE")!!)
                storePassword = helperSigningEnvironment.getValue("DEVICE_BRIDGE_HELPER_STORE_PASSWORD")
                keyAlias = helperSigningEnvironment.getValue("DEVICE_BRIDGE_HELPER_KEY_ALIAS")
                keyPassword = helperSigningEnvironment.getValue("DEVICE_BRIDGE_HELPER_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasInternalReleaseSigning) {
                signingConfig = signingConfigs.getByName("internalRelease")
            }
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
