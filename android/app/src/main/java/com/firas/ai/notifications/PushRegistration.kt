package com.firas.ai.notifications

import android.content.Context
import com.firas.ai.data.FirasRepository
import com.firas.ai.data.jsonOf
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal fun installationId(context: Context): String {
    val preferences = context.getSharedPreferences("firas_installation", Context.MODE_PRIVATE)
    return synchronized(PushRegistrationLock) {
        preferences.getString("id", null) ?: UUID.randomUUID().toString().also { check(preferences.edit().putString("id", it).commit()) }
    }
}
private object PushRegistrationLock

/** Android registration has its own server route; an FCM token is never sent to the APNs API. */
suspend fun FirasRepository.registerPushForCurrentAccount(): Boolean {
    if (!state.value.session.signedIn || FirebaseApp.getApps(context).isEmpty()) return false
    val owner = token()
    return try {
        val deviceToken = suspendCancellableCoroutine<String> { continuation ->
            FirebaseMessaging.getInstance().token.addOnSuccessListener { if (continuation.isActive) continuation.resume(it) }
                .addOnFailureListener { if (continuation.isActive) continuation.resumeWithException(it) }
        }
        checkOwner(owner)
        val result = api.obj("POST", "/api/push/android/register", jsonOf("token" to deviceToken, "installationId" to installationId(context), "lang" to state.value.language), epoch = owner.epoch)
        checkOwner(owner); result.optBoolean("ok")
    } catch (error: CancellationException) { throw error }
    catch (_: Exception) { false } // A missing/unreachable push service must not interrupt an answer.
}

internal suspend fun FirasRepository.unregisterPushAtEpoch(epoch: Long) {
    api.obj("POST", "/api/push/android/unregister", jsonOf("installationId" to installationId(context)), epoch = epoch)
}
