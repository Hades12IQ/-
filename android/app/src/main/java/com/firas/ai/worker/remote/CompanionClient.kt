package com.firas.ai.worker.remote

import com.firas.ai.worker.WorkerPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.ConnectionSpec
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.net.Proxy
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

data class PairingInvitation(val endpoint: String, val pin: String, val companionId: String, val nonce: String, val expiresAt: Long) {
    companion object {
        fun parse(value: String, now: Long = System.currentTimeMillis()): PairingInvitation {
            require(value.length <= 2200) { "Pairing code is too large" }
            val json = JSONObject(value)
            require(json.optInt("version") == 1)
            val endpoint = json.getString("endpoint")
            validateEndpoint(endpoint)
            val pin = json.getString("pin")
            require(Base64.getDecoder().decode(pin).size == 32) { "Invalid certificate fingerprint" }
            val id = json.getString("companionId"); val nonce = json.getString("nonce"); val expiry = json.getLong("expiresAt")
            require(id.matches(Regex("[a-f0-9-]{36}")) && nonce.matches(Regex("[A-Za-z0-9_-]{43}")))
            require(expiry > now && expiry <= now + 5 * 60 * 1000) { "Pairing code expired; create another on the PC" }
            return PairingInvitation(endpoint, pin, id, nonce, expiry)
        }
        fun validateEndpoint(value: String) {
            val uri = URI(value)
            require(uri.scheme == "https" && uri.userInfo == null && uri.rawQuery == null && uri.rawFragment == null && uri.path.isNullOrEmpty() && uri.port in 1..65535) { "Use the exact HTTPS pairing endpoint" }
            val pieces = uri.host?.split('.') ?: emptyList()
            require(pieces.size == 4 && pieces.all { it.toIntOrNull()?.let { number -> number in 0..255 && number.toString() == it } == true }) { "A private IPv4 address is required" }
            val p = pieces.map(String::toInt)
            require(p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] in 16..31) || uri.host == "127.0.0.1") { "This companion uses a private local network" }
        }
    }
}

/** TLS trust is scoped to one explicitly paired public key. Normal app TLS is unchanged. */
class CompanionClient(endpoint: String, pin: String, private val credential: String? = null) {
    private val origin = endpoint.also { PairingInvitation.validateEndpoint(it) }
    private val host = URI(endpoint).host
    private val trust = object : X509TrustManager {
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = throw java.security.cert.CertificateException("Client certificates are not supported")
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val leaf = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("Missing companion certificate")
            leaf.checkValidity()
            val actual = MessageDigest.getInstance("SHA-256").digest(leaf.publicKey.encoded)
            val expected = try { Base64.getDecoder().decode(pin) } catch (_: Exception) { throw java.security.cert.CertificateException("Invalid pin") }
            if (!MessageDigest.isEqual(actual, expected)) throw java.security.cert.CertificateException("Companion identity changed; pair again")
        }
    }
    private val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
    private val client = OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, trust)
        .hostnameVerifier { name, _ -> name == host }.connectionSpecs(listOf(ConnectionSpec.MODERN_TLS))
        .followRedirects(false).followSslRedirects(false).proxy(Proxy.NO_PROXY)
        .connectTimeout(6, TimeUnit.SECONDS).readTimeout(25, TimeUnit.SECONDS).callTimeout(30, TimeUnit.SECONDS).build()
    suspend fun request(path: String, value: JSONObject? = null): JSONObject = withContext(Dispatchers.IO) {
        require(path.startsWith("/v1/") && !path.contains("..") && !path.contains('#') && path.length <= 500)
        val request = Request.Builder().url(origin + path).apply {
            credential?.let { header("Authorization", "Bearer $it") }
            if (value != null) post(value.toString().toRequestBody("application/json".toMediaType()))
        }.build()
        client.newCall(request).execute().use { response ->
            val stream = response.body?.byteStream() ?: error("Companion returned no response")
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (output.size() <= 300000) { val count = stream.read(buffer, 0, minOf(buffer.size, 300001 - output.size())); if (count < 0) break; output.write(buffer, 0, count) }
            val bytes = output.toByteArray()
            require(bytes.size <= 300000) { "Companion response exceeds the limit" }
            val json = try { JSONObject(bytes.toString(Charsets.UTF_8)) } catch (_: Exception) { error("Companion returned an invalid response") }
            if (!response.isSuccessful) error(when (response.code) { 401, 403 -> "Pairing expired, revoked, or the PC account changed"; 409 -> "Task state changed or the request expired; check the PC before retrying"; 429 -> "Too many requests; wait before retrying"; else -> "Companion could not complete this request (${response.code})" })
            json
        }
    }
    fun close() { client.dispatcher.cancelAll(); client.connectionPool.evictAll() }
}
