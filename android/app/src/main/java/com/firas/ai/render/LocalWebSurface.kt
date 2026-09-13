package com.firas.ai.render

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebResourceError
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONTokener
import java.io.ByteArrayInputStream
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A dedicated local rendering surface with no cookies, JS bridge, remote resources or navigation.
 * It is attached outside the visible window so Chromium continues to produce real layouts. */
class LocalWebSurface(context: Context, widthPx: Int, heightPx: Int = 400) : AutoCloseable {
    private data class LocalDocument(val url: String, val bytes: ByteArray)
    @Volatile private var document: LocalDocument? = null
    val web = WebView(context)
    private val host: ViewGroup
    init {
        val activity = context.activity() ?: error("Rendering requires an active screen")
        host = activity.window.decorView as ViewGroup
        web.setBackgroundColor(Color.TRANSPARENT)
        web.isFocusable = false
        web.isVerticalScrollBarEnabled = false
        web.isHorizontalScrollBarEnabled = false
        web.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        web.translationX = -100_000f
        web.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            databaseEnabled = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
            textZoom = 100
            builtInZoomControls = false
            displayZoomControls = false
            useWideViewPort = false
            loadWithOverviewMode = false
        }
        web.webViewClient = client(null)
        host.addView(web, FrameLayout.LayoutParams(widthPx, heightPx))
        resize(widthPx, heightPx)
    }
    fun resize(width: Int, height: Int) {
        web.layoutParams = web.layoutParams.apply { this.width = width; this.height = height }
        web.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        web.layout(0, 0, width, height)
    }
    private fun client(loaded: ((Throwable?) -> Unit)?) = object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
            !request.isForMainFrame || request.url.toString() != document?.url
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
            val uri = request.url
            val local = document
            if (request.isForMainFrame && request.method == "GET" && local != null && uri.toString() == local.url) {
                return WebResourceResponse("text/html", "utf-8", 200, "OK",
                    mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"), ByteArrayInputStream(local.bytes))
            }
            val path = uri.path.orEmpty().removePrefix("/assets/render/")
            if (uri.scheme == "https" && uri.host == HOST && uri.path.orEmpty().startsWith("/assets/render/") &&
                path.matches(Regex("[A-Za-z0-9/_.-]+")) && path.split('/').none { it == ".." }) {
                val mime = when (path.substringAfterLast('.')) { "js" -> "text/javascript"; "css" -> "text/css"; "woff2" -> "font/woff2"; "ttf" -> "font/ttf"; "png" -> "image/png"; else -> "text/plain" }
                val stream = runCatching { view.context.applicationContext.assets.open("render/$path") }.getOrNull()
                if (stream != null) return WebResourceResponse(mime, "utf-8", 200, "OK", mapOf("Access-Control-Allow-Origin" to ORIGIN), stream)
            }
            return WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
        }
        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) loaded?.invoke(IllegalStateException("Local rendering page failed (${error.errorCode})"))
        }
        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
            if (request.isForMainFrame) loaded?.invoke(IllegalStateException("Local rendering page returned ${response.statusCode}"))
        }
        override fun onPageFinished(view: WebView, url: String) {
            if (url == document?.url) loaded?.invoke(null)
            else if (url.startsWith("chrome-error:")) loaded?.invoke(IllegalStateException("Local rendering page was replaced by an error page"))
        }
    }
    suspend fun load(html: String) = suspendCancellableCoroutine<Unit> { continuation ->
        val local = LocalDocument("$ORIGIN/document/${nonce()}", html.toByteArray(Charsets.UTF_8))
        document = local
        web.webViewClient = client { error ->
            if (continuation.isActive) {
                if (error == null) continuation.resume(Unit) else continuation.resumeWithException(error)
            }
        }
        // Intercept the main document as well as its bundled resources. Never treat an error page as loaded HTML.
        web.loadUrl(local.url)
        continuation.invokeOnCancellation { web.post { web.stopLoading() } }
    }
    suspend fun evaluate(script: String): Any? = suspendCancellableCoroutine { continuation ->
        web.evaluateJavascript(script) { value ->
            if (continuation.isActive) continuation.resume(runCatching { JSONTokener(value).nextValue() }.getOrNull())
        }
    }
    override fun close() { web.stopLoading(); host.removeView(web); web.destroy(); document = null }
    companion object {
        const val HOST = "appassets.androidplatform.net"
        const val ORIGIN = "https://appassets.androidplatform.net"
        const val ASSETS = "$ORIGIN/assets/render/"
        fun script(context: Context, name: String) = context.assets.open("render/$name").bufferedReader().use { it.readText() }
        fun nonce() = java.util.UUID.randomUUID().toString().replace("-", "")
        fun policy(nonce: String) = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'nonce-$nonce'; style-src $ORIGIN 'unsafe-inline'; font-src $ORIGIN data:; img-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'\">"
        fun assetScripts(nonce: String) = listOf("katex/katex.min.js", "katex/mhchem.min.js", "typesetting.js").joinToString("") { "<script nonce=\"$nonce\" src=\"$ASSETS$it\"></script>" }
    }
}

private fun Context.activity(): Activity? = when (this) { is Activity -> this; is ContextWrapper -> baseContext.activity(); else -> null }
