import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.example.spic"
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
        applicationId = "com.example.spic"
        // Заменяем flutter.minSdkVersion на конкретное значение:
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val storeFilePath = keystoreProperties["storeFile"] as String?
            val storePasswordValue = keystoreProperties["storePassword"] as String?
            val keyAliasValue = keystoreProperties["keyAlias"] as String?
            val keyPasswordValue = keystoreProperties["keyPassword"] as String?

            if (
                storeFilePath.isNullOrBlank() ||
                storePasswordValue.isNullOrBlank() ||
                keyAliasValue.isNullOrBlank() ||
                keyPasswordValue.isNullOrBlank()
            ) {
                throw GradleException(
                    "Release signing is not configured. Create android/key.properties " +
                        "with storeFile, storePassword, keyAlias and keyPassword. " +
                        "Release builds must never use the debug signing key."
                )
            }

            storeFile = rootProject.file(storeFilePath)
            storePassword = storePasswordValue
            keyAlias = keyAliasValue
            keyPassword = keyPasswordValue
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
