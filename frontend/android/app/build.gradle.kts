import java.net.URI
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dangdang.dangdang_diary"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dangdang.dangdang_diary"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

// A release APK must never silently use the Dart localhost development default.
// Flutter passes both --dart-define and --dart-define-from-file here as Base64.
val releaseDartDefines = providers.gradleProperty("dart-defines").orElse("")
val validateReleaseBaseUrl by tasks.registering {
    doLast {
        val baseUrl = releaseDartDefines.get().split(',')
            .filter { it.isNotBlank() }
            .map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
            .lastOrNull { it.startsWith("BASE_URL=") }
            ?.substringAfter('=')
        require(!baseUrl.isNullOrBlank()) {
            "Release APK requires --dart-define=BASE_URL=https://YOUR_SERVER_HOST " +
                "(the phone-accessible Nginx entry, without /api/v1 or a trailing slash)."
        }
        val uri = runCatching { URI(baseUrl) }.getOrNull()
        require(uri != null && uri.scheme in listOf("http", "https") &&
            !uri.host.isNullOrBlank() && uri.rawPath.isNullOrEmpty() &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null) {
            "BASE_URL must be an http(s) origin with an optional port, " +
                "without credentials, paths, query parameters or a trailing slash."
        }
    }
}

tasks.matching { it.name == "compileFlutterBuildRelease" || it.name == "preReleaseBuild" }
    .configureEach { dependsOn(validateReleaseBaseUrl) }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
