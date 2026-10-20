import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
// 只有真正打 release 包时才要求签名配置：开源贡献者跑 debug / 测试不该被
// 私有 keystore 拦住，否则 clone 下来连单元测试都编译不了。
val buildingRelease = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true) || it.contains("bundle", ignoreCase = true)
}
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
} else if (buildingRelease) {
    throw GradleException("Release signing configuration is required: android/key.properties is missing")
}

fun requiredSigningProperty(name: String): String =
    keystoreProperties.getProperty(name)
        ?: throw GradleException("Release signing property is missing: $name")

android {
    namespace = "com.firewatch.watchdog"
    // flutter_secure_storage 11 requires API 37 at compile time.
    // A higher compile SDK remains backward-compatible with the app's min/target SDK.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.firewatch.watchdog"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.create("release") {
                    keyAlias = requiredSigningProperty("keyAlias")
                    keyPassword = requiredSigningProperty("keyPassword")
                    storeFile = file(requiredSigningProperty("storeFile"))
                    storePassword = requiredSigningProperty("storePassword")
                }
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    testImplementation("junit:junit:4.13.2")

    // 水印相机：CameraX 1.6.2 起 camera-effects 为稳定版，
    // OverlayEffect 可把 Canvas 绘制的水印直接烧进预览、照片与录像。
    val cameraX = "1.6.2"
    implementation("androidx.camera:camera-core:$cameraX")
    implementation("androidx.camera:camera-camera2:$cameraX")
    implementation("androidx.camera:camera-lifecycle:$cameraX")
    implementation("androidx.camera:camera-video:$cameraX")
    implementation("androidx.camera:camera-view:$cameraX")
    implementation("androidx.camera:camera-effects:$cameraX")
}

flutter {
    source = "../.."
}
