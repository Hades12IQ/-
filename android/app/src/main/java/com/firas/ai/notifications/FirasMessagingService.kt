package com.firas.ai.notifications

import android.content.Intent
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class FirasMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        // Payloads are wake-up hints only: authenticated reconciliation reads canonical owner-bound
        // jobs and emits one local notification. Never display provider/raw payload text as a result.
        FirasJobWorker.wakeFromPush(applicationContext)
    }
    override fun onNewToken(token: String) {
        // The application registration hook retrieves the current token directly from Firebase;
        // it is never copied into a URL, notification, analytics event or plaintext preference.
        sendBroadcast(Intent(ACTION_TOKEN_CHANGED).setPackage(packageName))
        FirasJobWorker.wakeFromPush(applicationContext)
    }
    companion object { const val ACTION_TOKEN_CHANGED = "com.firas.ai.FCM_TOKEN_CHANGED" }
}
