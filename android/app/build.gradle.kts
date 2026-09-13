import java.security.KeyStore
import java.security.PrivateKey

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val previewKeystorePath = providers.environmentVariable("FIRAS_PREVIEW_KEYSTORE").orNull
check(previewKeystorePath != null || providers.environmentVariable("GITHUB_ACTIONS").orNull != "true") {
    "GitHub preview builds require FIRAS_PREVIEW_KEYSTORE; refusing an ephemeral signing identity."
}
val previewKeystore = previewKeystorePath?.let { path ->
    require(path.isNotBlank()) { "FIRAS_PREVIEW_KEYSTORE must name a readable signing keystore." }
    val store = file(path)
    require(store.isFile && store.canRead()) { "The configured preview signing keystore is missing or unreadable." }
    val valid = runCatching {
        val password = "android".toCharArray()
        val keyStore = KeyStore.getInstance(store, password)
        keyStore.getKey("AndroidDebugKey", password) is PrivateKey &&
            keyStore.getCertificate("AndroidDebugKey") != null
    }.getOrDefault(false)
    require(valid) { "The configured preview keystore does not contain the required usable signing key." }
    store
}

android {
    namespace = "com.firas.ai"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.firas.ai"
        minSdk = 26
        targetSdk = 36
        versionCode = providers.gradleProperty("firasBuild").orNull?.toInt() ?: 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "API_ORIGIN", "\"https://firasai.org\"")
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    signingConfigs {
        if (previewKeystore != null) {
            getByName("debug") {
                storeFile = previewKeystore
                storePassword = "android"
                keyAlias = "AndroidDebugKey"
                keyPassword = "android"
            }
        }
    }
    buildTypes {
        debug { manifestPlaceholders["cleartextTraffic"] = "true" }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            manifestPlaceholders["cleartextTraffic"] = "false"
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.12.01"))
    implementation("dev.chrisbanes.haze:haze:1.6.10")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-ui:1.5.1")
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.12.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
