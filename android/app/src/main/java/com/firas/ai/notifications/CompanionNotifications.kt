package com.firas.ai.notifications

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.firas.ai.data.FirasDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** Local delivery after an authenticated PC poll; this is not a cloud push channel. */
internal object CompanionNotifications {
    private const val CHANNEL = "firas_pc_results"
    private const val TAG = "firas-pc:"

    suspend fun postOnce(
        context: Context, account: String, companionId: String, runId: String,
        phase: String, currentOwner: () -> String?,
    ) {
        if (phase !in setOf("done", "error", "needs_action", "limit", "interrupted") ||
            currentOwner() != account || !CompletionNotifications.canNotify(context)) return
        val key = "pc:$companionId:$runId"
        var claimed = false
        var posted = false
        try {
            // Remember the claim even if the caller is cancelled during the disk write.
            withContext(NonCancellable + Dispatchers.IO) {
                claimed = FirasDatabase(context).use { it.claimNotification(account, key) }
            }
            if (!claimed) return
            // Returning to Main makes the identity check and post one uninterrupted step.
            withContext(Dispatchers.Main.immediate) {
                if (currentOwner() != account || !CompletionNotifications.canNotify(context)) return@withContext
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.createNotificationChannel(NotificationChannel(CHANNEL, "Firas PC results", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Completed tasks on your paired Windows PC"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                })
                if (manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return@withContext
                val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return@withContext
                launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                launch.data = Uri.Builder().scheme("firas").authority("pc-completion")
                    .appendPath(account).appendPath(companionId).appendPath(runId).build()
                launch.putExtra("firas_destination", "worker").putExtra("firas_worker_target", "pc")
                    .putExtra("ownerId", account).putExtra("runId", runId)
                val pending = PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val text = if (phase == "done") "Your PC task is complete · اكتملت مهمة الكمبيوتر"
                    else "Your PC task needs attention · تحتاج مهمة الكمبيوتر مراجعة"
                val notice = Notification.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.ic_menu_info_details)
                    .setContentTitle("Firas Worker").setContentText(text).setContentIntent(pending)
                    .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_STATUS)
                    .setOnlyAlertOnce(true).setAutoCancel(true).build()
                manager.notify("$TAG$account:$companionId:$runId", 0, notice)
                posted = true
            }
        } finally {
            // Permission/channel changes or failed delivery remain eligible for a later poll.
            if (claimed && !posted) withContext(NonCancellable + Dispatchers.IO) {
                FirasDatabase(context).use { it.releaseNotification(account, key) }
            }
        }
    }

    fun clear(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.activeNotifications.filter { it.tag?.startsWith(TAG) == true }
            .forEach { manager.cancel(it.tag, it.id) }
    }
}
