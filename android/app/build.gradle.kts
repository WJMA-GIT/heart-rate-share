plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.wjmagit.heartrateshare" // Keep aligned with AppConfig.applicationId.
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    defaultConfig {
        applicationId = "com.wjmagit.heartrateshare"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    buildTypes {
        release {
            // CI signing configuration is intentionally absent. Never commit keys.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter { source = "../.." }
