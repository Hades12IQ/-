package com.firas.ai.notifications

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import com.firas.ai.data.JobPhase
import com.firas.ai.data.JobState

object CompletionNotifications {
    const val CHANNEL = "firas_job_results"
    fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
    }
    fun post(context: Context, job: JobState): Boolean {
        if (!job.terminal || !canNotify(context)) return false
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Firas AI results", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Completed conversations, files, images, videos and songs"
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return false
        launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        launch.data = Uri.Builder().scheme("firas").authority("completion").appendPath(job.ownerId).appendPath(job.id).build()
        launch.putExtra("ownerId", job.ownerId).putExtra("jobId", job.id).putExtra("threadId", job.threadId).putExtra("product", job.product.name)
        val pending = PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val success = job.phase == JobPhase.COMPLETE
        val text = if (job.language == "en") {
            if (success) "Your ${job.product.title} result is ready." else "Your ${job.product.title} request needs attention."
        } else if (success) "اكتملت نتيجتك في ${job.product.title}." else "طلبك في ${job.product.title} يحتاج مراجعة."
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_dialog_info)
            .setContentTitle("Firas AI").setContentText(text).setContentIntent(pending).setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS).setVisibility(Notification.VISIBILITY_PRIVATE).setOnlyAlertOnce(true).build()
        return runCatching { manager.notify("${job.ownerId}:${job.id}", 0, notification); true }.getOrDefault(false)
    }
    fun clear(context: Context) { context.getSystemService(NotificationManager::class.java).cancelAll() }
}
