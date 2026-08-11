import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseProperties = Properties().apply {
    val propsFile = rootProject.file("key.properties")
    if (propsFile.isFile) {
        FileInputStream(propsFile).use { load(it) }
    }
}

fun secret(name: String): String? =
    (project.findProperty(name) as String?)
        ?: System.getenv(name)
        ?: releaseProperties.getProperty(name)

val releaseStoreFile = secret("CUBECHAT_RELEASE_STORE_FILE")
val releaseStorePassword = secret("CUBECHAT_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = secret("CUBECHAT_RELEASE_KEY_ALIAS")
val releaseKeyPassword = secret("CUBECHAT_RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "com.cubechat.cubechat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (uses java.time on older APIs).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cubechat.cubechat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_blue_plus needs >= 21; we bump to 23 (Android 6) to avoid the
        // legacy BLE permission code path entirely.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
            // Sign every scheme, including the old JAR one.
            //
            // At minSdk 24 the build tools drop v1 as redundant — v2 arrived in
            // Android 7 and covers every device that can install this. That is
            // true of the platform installer and not reliably true of the
            // installers people actually tap: several vendor package installers
            // (MIUI's among them) and a number of file managers still read the
            // v1 manifest, and hand back a flat "app not installed" when there
            // isn't one, with nothing to say which check failed.
            //
            // v1 costs a few hundred kilobytes and a couple of seconds. Not
            // having it costs a build that some phones decline for reasons
            // invisible from this side.
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            // Real signing when the secrets are there, the debug keystore when
            // they are not — never nothing.
            //
            // An unsigned release APK is not a weaker build, it is an
            // uninstallable one: Android refuses the package outright. That is
            // why CI shipped a *debug* APK for so long, and a debug build is
            // the wrong thing to hand a tester — the Dart is interpreted rather
            // than AOT-compiled, every assertion is live, and the frame times
            // it reports are not the ones the app actually has. Diagnosing "the
            // UI is GPU-bound" from a debug build is measuring the debugger.
            //
            // Falling back to the debug keystore keeps the APK installable
            // while leaving the release path intact for whenever
            // CUBECHAT_RELEASE_* / key.properties do turn up. It is a
            // sideloading key, not a distribution one: it is not the identity
            // to publish under, and an APK signed with it cannot upgrade one
            // signed with a real key (or vice versa) — that install has to be
            // replaced rather than updated.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
