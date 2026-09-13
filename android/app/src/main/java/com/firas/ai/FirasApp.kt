package com.firas.ai

import android.app.Application
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import org.json.JSONObject

class FirasApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Firebase client configuration is a build input. Server/provider credentials never enter the app.
        val options = runCatching {
            val config = JSONObject(assets.open("firebase-client.json").bufferedReader().use { it.readText() })
            val project = config.getJSONObject("project_info")
            val clients = config.getJSONArray("client")
            val client = (0 until clients.length()).map { clients.getJSONObject(it) }.first {
                it.getJSONObject("client_info").getJSONObject("android_client_info").getString("package_name") == packageName
            }
            FirebaseOptions.Builder()
                .setApplicationId(client.getJSONObject("client_info").getString("mobilesdk_app_id"))
                .setProjectId(project.getString("project_id"))
                .setGcmSenderId(project.getString("project_number"))
                .setApiKey(client.getJSONArray("api_key").getJSONObject(0).getString("current_key"))
                .build()
        }.getOrNull()
        if (FirebaseApp.getApps(this).isEmpty() && options != null) FirebaseApp.initializeApp(this, options)
    }
}
