plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Kumori Link runs on an Android box and sends its controllers to Kumori on an Apple TV.
// No libraries beyond Kotlin: it starts fast and has nothing between the pad and the socket.
android {
    namespace = "app.kumori.link"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.kumori.link"
        minSdk = 24
        targetSdk = 34
        versionName = "0.3.0"
        versionCode = versionName!!.split(".").map { it.toInt() }.let { (major, minor, patch) -> major * 10000 + minor * 100 + patch }
    }

    // Same committed key as the main app, so updates install over each other.
    val keystore = System.getenv("KUMORI_KEYSTORE")?.takeIf { it.isNotBlank() }?.let(::file)?.also {
        if (!it.exists()) throw GradleException("KUMORI_KEYSTORE points to ${it.path}, which doesn't exist.")
    }
    signingConfigs {
        create("release") {
            storeFile = keystore ?: file("../app/release.jks")
            storePassword = System.getenv("KUMORI_KEYSTORE_PASSWORD") ?: "gsC0D80K3hH8EkUCTqGTp71U"
            keyAlias = System.getenv("KUMORI_KEY_ALIAS") ?: "kumori"
            keyPassword = System.getenv("KUMORI_KEY_PASSWORD") ?: storePassword
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { buildConfig = true }
}
