plugins {
    id("com.android.application")
}

android {
    namespace = "com.junowoz.filefoundry.screen"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.junowoz.filefoundry.screen"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Not debuggable; signed with this Mac's Android debug key for direct installs.
            // Swap for a dedicated release key before distributing through a store.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    testImplementation("junit:junit:4.13.2")
}
