package com.firas.ai.worker.phone

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.view.WindowManager
import com.firas.ai.worker.WorkerRuntime
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayOutputStream

/** A fresh OS consent starts one projection session. No token or screenshot is persisted. */
class PhoneCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var owner: String? = null
    private val thread = HandlerThread("FirasCapture")
    private lateinit var handler: Handler
    @Volatile private var pending: CompletableDeferred<ByteArray>? = null
    override fun onCreate() { super.onCreate(); thread.start(); handler = Handler(thread.looper) }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { WorkerRuntime.stop(); stopSelf(); return START_NOT_STICKY }
        val token = if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra("consent", Intent::class.java) else @Suppress("DEPRECATION") (intent?.getParcelableExtra("consent") as? Intent)
        val account = intent?.getStringExtra("owner")
        if (token == null || account.isNullOrEmpty() || account != WorkerRuntime.owner.value || projection != null) { stopSelf(); return START_NOT_STICKY }
        owner = account
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Worker screen sharing", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 421, Intent(this, PhoneCaptureService::class.java).setAction(STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notice = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("Firas Worker")
            .setContentText("Screen sharing active · مشاركة الشاشة فعالة").setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop · إيقاف", stop).build()).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(421, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION) else startForeground(421, notice)
        try {
            projection = getSystemService(MediaProjectionManager::class.java).getMediaProjection(Activity.RESULT_OK, token)
            projection!!.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Handler(android.os.Looper.getMainLooper()).post { if (instance === this@PhoneCaptureService && owner == WorkerRuntime.owner.value) WorkerRuntime.stop(); stopSelf() }
                }
                override fun onCapturedContentResize(width: Int, height: Int) { if (width > 0 && height > 0) resize(width, height) }
            }, handler)
            val bounds = if (Build.VERSION.SDK_INT >= 30) getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds else android.graphics.Rect(0, 0, resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels)
            installReader(bounds.width(), bounds.height())
            display = projection!!.createVirtualDisplay("Firas Worker", reader!!.width, reader!!.height, resources.configuration.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader!!.surface, null, handler)
            instance = this; _available.value = true
        } catch (_: RuntimeException) { stopSelf() }
        return START_NOT_STICKY
    }
    private fun installReader(width: Int, height: Int) {
        val scale = minOf(1.0, 1600.0 / maxOf(width, height))
        val w = (width * scale).toInt().coerceAtLeast(1); val h = (height * scale).toInt().coerceAtLeast(1)
        reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2).also { source ->
            source.setOnImageAvailableListener({ images ->
                val image = try { images.acquireLatestImage() } catch (_: IllegalStateException) { null } ?: return@setOnImageAvailableListener
                image.use {
                    val request = pending ?: return@use
                    pending = null
                    if (owner != WorkerRuntime.owner.value) { request.completeExceptionally(IllegalStateException("Account changed")); stopSelf(); return@use }
                    try {
                        val plane = image.planes[0]
                        val rowWidth = plane.rowStride / plane.pixelStride
                        val padded = Bitmap.createBitmap(rowWidth, image.height, Bitmap.Config.ARGB_8888)
                        padded.copyPixelsFromBuffer(plane.buffer)
                        val cropped = Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
                        val output = ByteArrayOutputStream()
                        cropped.compress(Bitmap.CompressFormat.JPEG, 75, output)
                        if (cropped !== padded) cropped.recycle(); padded.recycle()
                        request.complete(output.toByteArray())
                    } catch (_: RuntimeException) { request.completeExceptionally(IllegalStateException("Screen capture unavailable")) }
                }
            }, handler)
        }
    }
    private fun resize(width: Int, height: Int) {
        if (display == null) return
        val previous = reader
        installReader(width, height)
        display?.resize(reader!!.width, reader!!.height, resources.configuration.densityDpi)
        display?.surface = reader!!.surface
        previous?.close()
    }
    private suspend fun nextImage(): ByteArray {
        check(owner != null && owner == WorkerRuntime.owner.value && projection != null) { "Screen-sharing permission is unavailable" }
        val request = CompletableDeferred<ByteArray>()
        check(pending == null) { "A capture is already pending" }
        pending = request
        return try { withTimeout(6000) { request.await() } } finally { if (pending === request) pending = null }
    }
    override fun onDestroy() {
        if (instance === this) { instance = null; _available.value = false }
        pending?.completeExceptionally(IllegalStateException("Screen sharing stopped")); pending = null
        display?.release(); display = null; reader?.close(); reader = null
        projection?.stop(); projection = null; thread.quitSafely(); super.onDestroy()
    }
    companion object {
        private const val CHANNEL = "firas_worker_capture"
        private const val STOP = "com.firas.ai.worker.STOP_CAPTURE"
        @Volatile private var instance: PhoneCaptureService? = null
        private val _available = MutableStateFlow(false)
        val available = _available.asStateFlow()
        fun start(context: Context, owner: String, consent: Intent) {
            check(owner == WorkerRuntime.owner.value)
            context.startForegroundService(Intent(context, PhoneCaptureService::class.java).putExtra("owner", owner).putExtra("consent", consent))
        }
        fun stop(context: Context) { context.stopService(Intent(context, PhoneCaptureService::class.java)) }
        suspend fun snapshot(): ByteArray = (instance ?: error("Enable screen sharing with Android's consent dialog first")).nextImage()
    }
}
