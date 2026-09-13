package com.firas.ai.data

import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

object BrowserSignInProof {
    private val token = Regex("[A-Za-z0-9_-]{43}")
    fun verifier(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
    fun challenge(verifier: String): String {
        require(token.matches(verifier))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))
    }
    fun allowedBrowserUrl(url: String, origin: String, id: String): Boolean = runCatching {
        val actual = URI(url); val base = URI(origin)
        token.matches(id) && actual.scheme == "https" && actual.host == base.host && actual.port == base.port &&
            actual.rawUserInfo == null && actual.rawFragment == null && actual.path == "/desktop-auth" && actual.rawQuery == "id=$id"
    }.getOrDefault(false)
}
