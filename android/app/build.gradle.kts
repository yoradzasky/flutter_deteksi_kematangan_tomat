plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.tomato_detector"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.tomato_detector"
        
        // Gunakan sintaks 'minSdk =' (bukan minSdkVerison)
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        
        // Kita ganti variabel yang error dengan angka langsung
        versionCode = 1
        versionName = "1.0.0"

        ndk {
            // Ini menyuruh komputer: "Hanya buat untuk Emulator (x86_64) saja!"
            abiFilters.add("x86_64")

        aaptOptions {
        noCompress += "tflite"
        }
    }
}


    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
