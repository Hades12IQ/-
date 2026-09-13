package com.firas.ai

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.runtime.*
import androidx.core.view.WindowCompat
import com.firas.ai.data.FirasRepository
import com.firas.ai.ui.FirasRoot
import com.firas.ai.ui.FirasTheme
import com.firas.ai.ui.UiPreferences

class MainActivity : ComponentActivity() {
    private lateinit var repository: FirasRepository
    private var destination by mutableStateOf<Intent?>(null)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        repository = FirasRepository.get(applicationContext)
        val preferences = UiPreferences(applicationContext)
        destination = intent
        setContent { FirasTheme(preferences) {
            SideEffect {
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = preferences.theme == "light"
                    isAppearanceLightNavigationBars = preferences.theme == "light"
                }
            }
            FirasRoot(repository, preferences, destination, { destination = null }, ::openBrowser)
        } }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); destination = intent }
    override fun onStart() { super.onStart(); if (::repository.isInitialized) repository.setForeground(true) }
    override fun onStop() { if (::repository.isInitialized) repository.setForeground(false); super.onStop() }
    private fun openBrowser(url: String) {
        val uri = Uri.parse(url)
        if (uri.scheme !in setOf("https", "http")) return
        runCatching { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(this, uri) }
            .onFailure { runCatching { startActivity(Intent(Intent.ACTION_VIEW, uri)) } }
    }
}
