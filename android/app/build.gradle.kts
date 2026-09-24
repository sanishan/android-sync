plugins { id("com.android.application"); id("org.jetbrains.kotlin.plugin.compose") }
android {
    namespace = "dev.androidsync"
    compileSdk = 37
    defaultConfig { applicationId = "dev.androidsync"; minSdk = 31; targetSdk = 36; versionCode = 8; versionName = "1.0.0-local" }
    flavorDimensions += "distribution"
    productFlavors {
        create("localFull") {
            dimension = "distribution"
            buildConfigField("boolean", "LOCAL_FULL", "true")
        }
        create("standard") {
            dimension = "distribution"
            applicationIdSuffix = ".standard"
            versionNameSuffix = "-standard"
            buildConfigField("boolean", "LOCAL_FULL", "false")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.08.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.google.zxing:core:3.5.3")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
