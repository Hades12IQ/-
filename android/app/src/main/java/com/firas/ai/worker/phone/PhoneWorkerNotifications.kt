package com.firas.ai.worker.phone

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.firas.ai.worker.WorkerState

object PhoneWorkerNotifications {
    fun publish(context: Context, state: WorkerState) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("firas_worker_complete", "Worker completion", NotificationManager.IMPORTANCE_DEFAULT))
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.putExtra("firas_destination", "worker") ?: return
        val tap = PendingIntent.getActivity(context, 425, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val text = if (state.phase == "completed") "Your phone task is complete · اكتملت مهمة الهاتف" else "Your phone task needs attention · تحتاج مهمة الهاتف مراجعة"
        try { manager.notify("firas-worker", state.runId?.hashCode() ?: 425, Notification.Builder(context, "firas_worker_complete").setSmallIcon(android.R.drawable.ic_menu_info_details).setContentTitle("Firas Worker").setContentText(text).setContentIntent(tap).setAutoCancel(true).build()) }
        catch (_: SecurityException) { }
    }
    fun clear(context: Context) { val manager = context.getSystemService(NotificationManager::class.java); manager.activeNotifications.filter { it.tag == "firas-worker" }.forEach { manager.cancel(it.tag, it.id) } }
}
