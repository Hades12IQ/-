package com.firas.ai.data

import org.json.JSONObject

/** Pairing replies stay in the open settings screen, never in chat or preferences. */
object OmnixTelegramPolicy {
    val states = setOf("not_configured", "pairing", "connected", "setup_uncertain", "approval_expired", "owner_id_required", "disconnecting", "disconnect_uncertain", "disconnected", "setting_up")
    fun validUserId(id: Long) = id in 1 until 4_503_599_627_370_496L
    fun validToken(token: String) = token.matches(Regex("[1-9][0-9]{4,19}:[A-Za-z0-9_-]{30,200}"))
    fun userId(text: String): Long? = text.trim().map { c -> when (c) {
        in '\u0660'..'\u0669' -> ('0'.code + c.code - '\u0660'.code).toChar()
        in '\u06f0'..'\u06f9' -> ('0'.code + c.code - '\u06f0'.code).toChar()
        else -> c
    } }.joinToString("").takeIf { it.matches(Regex("[1-9][0-9]{0,15}")) }?.toLongOrNull()?.takeIf(::validUserId)
    fun validStatus(value: JSONObject): Boolean {
        val state = value.optString("state")
        val id = value.stringOrNull("connectionId")
        val username = value.optJSONObject("bot")?.stringOrNull("username")
        return value.optBoolean("ok") && state in states && (id == null || id.matches(Regex("omxt_[a-f0-9]{32}"))) &&
            (state !in setOf("pairing", "connected") || id != null) &&
            (!value.has("telegramUserId") || value.isNull("telegramUserId") || validUserId(value.optLong("telegramUserId"))) &&
            (username == null || username.matches(Regex("[A-Za-z][A-Za-z0-9_]{4,31}")))
    }
    fun mayConfigure(value: JSONObject) = validStatus(value) && value.optBoolean("cloudReady") && value.optBoolean("canConfigure") && value.optString("state") in setOf("not_configured", "disconnected")
    fun canDisconnect(value: JSONObject) = validStatus(value) && value.optString("state") in setOf("pairing", "connected", "setup_uncertain", "approval_expired", "owner_id_required", "setting_up")
    fun pairingUrl(value: JSONObject, now: Long = System.currentTimeMillis()): String? {
        if (!validStatus(value) || value.optString("state") != "pairing") return null
        val pairing = value.optJSONObject("pairing") ?: return null
        val code = pairing.optString("code")
        val expiry = pairing.optLong("expiresAt")
        val username = value.optJSONObject("bot")?.stringOrNull("username") ?: return null
        if (!code.matches(Regex("[A-Za-z0-9_-]{32}")) || expiry <= now || expiry >= 9_007_199_254_740_991L) return null
        return "https://t.me/$username?start=$code"
    }
}

private suspend fun FirasRepository.telegramRequest(method: String, path: String, body: JSONObject? = null): JSONObject {
    val owner = token()
    if (!state.value.session.signedIn) throw Failures.http(401)
    val result = api.obj(method, path, body, epoch = owner.epoch, timeoutSeconds = 8)
    checkOwner(owner)
    if (!OmnixTelegramPolicy.validStatus(result)) throw Failures.http(502, "telegram_response_invalid")
    return result
}

suspend fun FirasRepository.omnixTelegramStatus(): JSONObject = telegramRequest("GET", "/api/omnix/telegram")
suspend fun FirasRepository.omnixTelegramConfigure(botToken: String, telegramUserId: Long): JSONObject {
    require(OmnixTelegramPolicy.validToken(botToken.trim()) && OmnixTelegramPolicy.validUserId(telegramUserId))
    // Exactly one mutation; the settings flow follows uncertain delivery with a status GET.
    return telegramRequest("POST", "/api/omnix/telegram", jsonOf("botToken" to botToken.trim(), "telegramUserId" to telegramUserId))
}
suspend fun FirasRepository.omnixTelegramDisconnect(): JSONObject = telegramRequest("POST", "/api/omnix/telegram/disconnect", JSONObject())
