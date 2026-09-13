package com.firas.ai.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Cookie
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resumeWithException

class FirasFailure(val notice: UiNotice, val status: Int = 0, val code: String = "request_failed") : IOException(notice.en)
internal class OwnerChanged : IOException("Session changed")
internal object Failures {
    val session = UiNotice("تغيّر الحساب. أعد المحاولة من الحساب الحالي.", "Your account changed. Try again from the current account.")
    val network = UiNotice("تعذّر الاتصال. تحقق من الشبكة وحاول مجدداً.", "Could not connect. Check your connection and try again.")
    val incomplete = UiNotice("لم يصل رد كامل. يمكنك إعادة المحاولة.", "A complete response was not received. You can retry.")
    val busy = UiNotice("هناك طلب يعمل في هذه المحادثة. انتظر اكتماله أو أوقفه إن كان الإيقاف متاحاً.", "A request is active in this conversation. Wait for completion or stop it if supported.")
    fun http(status: Int, code: String = ""): FirasFailure {
        val notice = when {
            code == "desktop_auth_denied" -> UiNotice("رُفض تسجيل الدخول من المتصفح.", "Browser sign-in was declined.")
            code == "desktop_auth_expired" -> UiNotice("انتهت صلاحية طلب الدخول. ابدأ طلباً جديداً.", "Sign-in expired. Start a new request.")
            status == 401 -> UiNotice("سجّل الدخول مجدداً للمتابعة.", "Sign in again to continue.")
            status == 403 -> UiNotice("هذا الإجراء غير متاح لهذا الحساب.", "This action is unavailable for this account.")
            status == 429 -> UiNotice("وصلت إلى الحد المتاح حالياً. حاول لاحقاً أو راجع اشتراكك.", "You reached the current limit. Try later or check your plan.")
            status == 413 -> UiNotice("حجم الطلب أكبر من الحد المسموح. قلّل عدد المرفقات أو حجمها.", "The request exceeds the size limit. Use fewer or smaller attachments.")
            status == 404 -> UiNotice("لم يعد هذا المحتوى متاحاً.", "This content is no longer available.")
            status == 409 -> UiNotice("تغيّرت حالة الطلب. حدّث النتيجة وحاول مجدداً.", "The request state changed. Refresh and try again.")
            status in 400..499 -> UiNotice("تعذّر قبول الطلب. راجع البيانات المدخلة وحاول مجدداً.", "The request was not accepted. Check the entered details and retry.")
            else -> UiNotice("الخدمة غير متاحة مؤقتاً. حاول مجدداً بعد قليل.", "The service is temporarily unavailable. Try again shortly.")
        }
        return FirasFailure(notice, status, code.takeIf { it.matches(Regex("[a-z0-9_]{1,64}")) } ?: "request_failed")
    }
}

/** No CookieJar on OkHttp: each request receives a frozen credential snapshot. An old response
 * cannot overwrite the new account's cookie even if it completes during a login transition. */
internal class SessionVault(context: Context) {
    private val preferences = context.getSharedPreferences("firas_session_vault", Context.MODE_PRIVATE)
    private val alias = "firas.session.aes.v1"
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private var cookies = mutableListOf<Cookie>()
    @Volatile var epoch: Long = 0; private set
    var recoveryRequired: Boolean = false; private set

    init {
        val encoded = preferences.getString("encrypted", null)
        if (encoded != null) try {
            val blob = Base64.decode(encoded, Base64.NO_WRAP)
            require(blob.size > 28)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0, 12)))
            val rows = JSONArray(String(cipher.doFinal(blob.copyOfRange(12, blob.size)), Charsets.UTF_8))
            for (index in 0 until rows.length()) {
                val row = rows.getJSONObject(index)
                val builder = Cookie.Builder().name(row.getString("name")).value(row.getString("value"))
                    .path(row.getString("path")).expiresAt(row.getLong("expires"))
                if (row.optBoolean("hostOnly")) builder.hostOnlyDomain(row.getString("domain")) else builder.domain(row.getString("domain"))
                if (row.optBoolean("secure")) builder.secure()
                if (row.optBoolean("httpOnly")) builder.httpOnly()
                val cookie = builder.build()
                if (cookie.expiresAt > System.currentTimeMillis()) cookies.add(cookie)
            }
        } catch (_: Exception) {
            // Failed decryption means signed out, never a plaintext fallback.
            cookies.clear(); preferences.edit().clear().commit(); recoveryRequired = true
            runCatching { keyStore.deleteEntry(alias) }
        }
    }

    private fun key(): SecretKey {
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    private fun persist() {
        val rows = JSONArray()
        for (cookie in cookies) rows.put(JSONObject().put("name", cookie.name).put("value", cookie.value)
            .put("domain", cookie.domain).put("path", cookie.path).put("expires", cookie.expiresAt)
            .put("hostOnly", cookie.hostOnly).put("secure", cookie.secure).put("httpOnly", cookie.httpOnly))
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val blob = cipher.iv + cipher.doFinal(rows.toString().toByteArray(Charsets.UTF_8))
            check(preferences.edit().putString("encrypted", Base64.encodeToString(blob, Base64.NO_WRAP)).commit())
        } catch (_: Exception) {
            cookies.clear(); preferences.edit().clear().commit()
            throw FirasFailure(UiNotice("تعذّر حفظ الجلسة بأمان. أعد تسجيل الدخول.", "The session could not be stored securely. Sign in again."))
        }
    }
    @Synchronized fun snapshot(url: HttpUrl, expectedEpoch: Long): String {
        if (epoch != expectedEpoch) throw OwnerChanged()
        return cookies.filter { it.expiresAt > System.currentTimeMillis() && it.matches(url) }.joinToString("; ") { "${it.name}=${it.value}" }
    }
    @Synchronized fun accept(url: HttpUrl, response: Response, expectedEpoch: Long) {
        if (epoch != expectedEpoch) throw OwnerChanged()
        val received = Cookie.parseAll(url, response.headers).filter { it.name in setOf("firas_session", "firas_guest") }
        if (received.isEmpty()) return
        for (cookie in received) {
            cookies.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
            if (cookie.expiresAt > System.currentTimeMillis()) cookies.add(cookie)
        }
        persist()
    }
    @Synchronized fun newEpoch(clear: Boolean, keepGuest: Boolean = false): Long {
        epoch++
        if (clear) {
            if (keepGuest) cookies.removeAll { it.name != "firas_guest" } else cookies.clear()
            if (cookies.isEmpty()) preferences.edit().clear().commit() else persist()
        }
        return epoch
    }
    @Synchronized fun hasSession() = cookies.any { it.name == "firas_session" && it.expiresAt > System.currentTimeMillis() }
    @Synchronized fun hasGuest() = cookies.any { it.name == "firas_guest" && it.expiresAt > System.currentTimeMillis() }
}

internal class FirasApi(private val vault: SessionVault, base: String = "https://firasai.org") {
    val baseUrl: HttpUrl = base.toHttpUrl().also { require(it.isHttps || it.host in setOf("127.0.0.1", "localhost")) }
    private val client = OkHttpClient.Builder().connectTimeout(12, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(300, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).build()

    fun url(path: String, query: Map<String, String> = emptyMap()): HttpUrl {
        require(path.startsWith("/api/") && !path.startsWith("//") && !path.contains("#"))
        val url = baseUrl.resolve(path) ?: error("Invalid API path")
        require(url.host == baseUrl.host && url.scheme == baseUrl.scheme && url.port == baseUrl.port)
        return url.newBuilder().apply { for ((key, value) in query) addQueryParameter(key, value) }.build()
    }
    private fun request(method: String, path: String, body: JSONObject?, query: Map<String, String>, epoch: Long): Request {
        val url = url(path, query)
        val request = Request.Builder().url(url).header("Accept", "application/json").header("Cache-Control", "no-cache")
        val cookie = vault.snapshot(url, epoch)
        if (cookie.isNotEmpty()) request.header("Cookie", cookie)
        return request.method(method, if (method in setOf("GET", "HEAD")) null else (body ?: JSONObject()).toString().toRequestBody("application/json; charset=utf-8".toMediaType())).build()
    }
    private suspend fun execute(request: Request, epoch: Long, timeoutSeconds: Long = 30): Response = suspendCancellableCoroutine { continuation ->
        if (vault.epoch != epoch) { continuation.resumeWithException(OwnerChanged()); return@suspendCancellableCoroutine }
        val call = client.newBuilder().readTimeout(timeoutSeconds, TimeUnit.SECONDS).build().newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(if (vault.epoch != epoch) OwnerChanged() else e)
            }
            override fun onResponse(call: Call, response: Response) {
                if (!continuation.isActive) { response.close(); return }
                try {
                    vault.accept(request.url, response, epoch)
                    @Suppress("DEPRECATION")
                    continuation.resume(response) { response.close() }
                } catch (error: Exception) { response.close(); if (continuation.isActive) continuation.resumeWithException(error) }
            }
        })
    }
    suspend fun json(method: String, path: String, body: JSONObject? = null, query: Map<String, String> = emptyMap(), epoch: Long = vault.epoch, timeoutSeconds: Long = 30): Any = withContext(Dispatchers.IO) {
        execute(request(method, path, body, query, epoch), epoch, timeoutSeconds).use { response ->
            val raw = response.body?.string().orEmpty()
            if (vault.epoch != epoch) throw OwnerChanged()
            val parsed = runCatching { if (raw.trimStart().startsWith("[")) JSONArray(raw) else JSONObject(raw) }.getOrNull()
            if (!response.isSuccessful) throw Failures.http(response.code, (parsed as? JSONObject)?.optString("error").orEmpty())
            parsed ?: throw FirasFailure(UiNotice("وصل رد غير صالح من الخدمة. حاول مجدداً.", "The service returned an invalid response. Try again."))
        }
    }
    suspend fun obj(method: String, path: String, body: JSONObject? = null, query: Map<String, String> = emptyMap(), epoch: Long = vault.epoch, timeoutSeconds: Long = 30): JSONObject =
        json(method, path, body, query, epoch, timeoutSeconds) as? JSONObject ?: throw Failures.http(502)

    suspend fun upload(path: String, bytes: ByteArray, mime: String, headers: Map<String, String>, epoch: Long): JSONObject = withContext(Dispatchers.IO) {
        require(path.matches(Regex("/api/omnix/inputs/[A-Za-z0-9_-]{16,128}/[A-Za-z0-9_-]{16,128}")))
        require(bytes.isNotEmpty() && bytes.size <= 20 * 1024 * 1024 && !mime.contains('\r') && !mime.contains('\n'))
        val builder = request("POST", path, null, emptyMap(), epoch).newBuilder()
        for ((name, value) in headers) {
            require(name.lowercase() in setOf("x-omnix-conversation", "x-omnix-size", "x-omnix-filename", "x-omnix-sha256"))
            require(!value.contains('\r') && !value.contains('\n'))
            builder.header(name, value)
        }
        execute(builder.post(bytes.toRequestBody(mime.toMediaType())).build(), epoch, 300).use { response ->
            val parsed = runCatching { JSONObject(response.body?.string().orEmpty()) }.getOrNull()
            if (vault.epoch != epoch) throw OwnerChanged()
            if (!response.isSuccessful) throw Failures.http(response.code, parsed?.optString("error").orEmpty())
            parsed ?: throw Failures.http(502)
        }
    }

    suspend fun stream(path: String, body: JSONObject, epoch: Long, onDelta: suspend (String, String) -> Unit) = withContext(Dispatchers.IO) {
        execute(request("POST", path, body, emptyMap(), epoch).newBuilder().header("Accept", "text/event-stream").build(), epoch, 300).use { response ->
            if (!response.isSuccessful) throw Failures.http(response.code)
            if (!response.header("Content-Type").orEmpty().contains("text/event-stream")) throw Failures.http(502)
            val source = response.body?.source() ?: throw Failures.http(502)
            var sawDone = false
            val frame = StringBuilder()
            suspend fun consume() {
                val data = frame.toString(); frame.setLength(0)
                if (data == "[DONE]") { sawDone = true; return }
                if (data.isBlank()) return
                val event = runCatching { JSONObject(data) }.getOrNull() ?: return
                if (event.has("error")) throw Failures.http(502)
                val delta = event.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("delta") ?: return
                onDelta(delta.optString("content"), delta.optString("reasoning"))
            }
            while (!source.exhausted() && !sawDone) {
                if (vault.epoch != epoch) throw OwnerChanged()
                val line = source.readUtf8Line() ?: break
                if (line.isEmpty()) consume() else if (line.startsWith("data:")) {
                    if (frame.isNotEmpty()) frame.append('\n')
                    frame.append(line.removePrefix("data:").removePrefix(" "))
                }
            }
            if (frame.isNotEmpty()) consume()
            if (!sawDone) throw FirasFailure(Failures.incomplete)
        }
    }

    suspend fun download(path: String, query: Map<String, String>, destination: File, epoch: Long, method: String = "GET", body: JSONObject? = null): DownloadedArtifact = withContext(Dispatchers.IO) {
        execute(request(method, path, body, query, epoch), epoch, 60).use { response ->
            if (!response.isSuccessful) throw Failures.http(response.code)
            val body = response.body ?: throw Failures.http(502)
            val temporary = File(destination.parentFile, destination.name + ".part")
            try {
                temporary.outputStream().use { output -> body.byteStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) { val n = input.read(buffer); if (n < 0) break; if (vault.epoch != epoch) throw OwnerChanged(); output.write(buffer, 0, n) }
                } }
                if (vault.epoch != epoch) throw OwnerChanged()
                if (destination.exists()) destination.delete()
                check(temporary.renameTo(destination))
                DownloadedArtifact(destination, destination.name, body.contentType()?.toString())
            } finally { temporary.delete() }
        }
    }
}

internal fun jsonOf(vararg fields: Pair<String, Any?>): JSONObject = JSONObject().apply { for ((key, value) in fields) if (value != null) put(key, value) }
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).mapNotNull { optJSONObject(it) }
internal fun JSONObject.stringOrNull(key: String) = optString(key).takeIf { it.isNotBlank() && it != "null" }
