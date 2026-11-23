import app.kumori.buildlogic.WebRtcTextureDeliveryFactory
import com.android.build.api.instrumentation.FramesComputationMode
import com.android.build.api.instrumentation.InstrumentationScope

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.kumori.tv"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.kumori.tv"
        minSdk = 28
        targetSdk = 34
        versionName = "1.3.0"
        // Follows the version name (1.2.3 becomes 10203), so a new version always installs
        // as an update and the two can't drift apart.
        versionCode = versionName!!.split(".").map { it.toInt() }.let { (major, minor, patch) -> major * 10000 + minor * 100 + patch }
    }

    // One fixed key lets every new version install over the last one without losing the
    // sign-in. The key is committed on purpose so anyone can build a compatible update;
    // KUMORI_KEYSTORE (and its password variables) override it.
    val keystore = System.getenv("KUMORI_KEYSTORE")?.takeIf { it.isNotBlank() }?.let(::file)?.also {
        // A wrong path must not quietly sign with the committed key instead.
        if (!it.exists()) throw GradleException("KUMORI_KEYSTORE points to ${it.path}, which doesn't exist.")
    }
    signingConfigs {
        create("release") {
            storeFile = keystore ?: file("release.jks")
            storePassword = System.getenv("KUMORI_KEYSTORE_PASSWORD") ?: "gsC0D80K3hH8EkUCTqGTp71U"
            keyAlias = System.getenv("KUMORI_KEY_ALIAS") ?: "kumori"
            keyPassword = System.getenv("KUMORI_KEY_PASSWORD") ?: storePassword
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

// WebRTC's texture path resets the SurfaceTexture size and posts two messages for every
// decoded frame, which drops frames at 120 fps. buildSrc patches it to skip unchanged
// values and to run the decoder texture thread at display priority.
androidComponents.onVariants { variant ->
    variant.instrumentation.transformClassesWith(
        WebRtcTextureDeliveryFactory::class.java,
        InstrumentationScope.ALL,
    ) {}
    variant.instrumentation.setAsmFramesComputationMode(
        FramesComputationMode.COMPUTE_FRAMES_FOR_INSTRUMENTED_METHODS,
    )
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.coil-kt:coil-compose:2.7.0")
    // Installs the Compose and app baseline profiles on sideloaded installs, so the UI runs
    // compiled code from the first launch instead of warming up in the interpreter.
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    implementation("com.google.zxing:core:3.5.3")
    implementation("io.github.webrtc-sdk:android:144.7559.15")
}

// The library for 4K streams is built by scripts/build_nvst.py and is not in git. Without it
// the app still builds and runs, but every 4K stream quietly drops to 1440p, so a release
// build stops here. Pass -Pkumori.withoutNative to build one without it on purpose.
val nativeLibrary = layout.projectDirectory.file("src/main/jniLibs/arm64-v8a/libkumori_nvst.so").asFile
val withoutNative = providers.gradleProperty("kumori.withoutNative").isPresent
tasks.matching { it.name == "preReleaseBuild" || it.name == "preDebugBuild" }.configureEach {
    val release = name == "preReleaseBuild"
    doFirst {
        if (!nativeLibrary.exists()) {
            val message = "libkumori_nvst.so is missing, so this build has no native 4K streaming. Run: python3 scripts/build_nvst.py"
            if (release && !withoutNative) throw GradleException(message) else logger.warn("WARNING: $message")
        }
    }
}
