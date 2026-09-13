package com.firas.ai.data

import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

suspend fun FirasRepository.liveToken(voice: String, prefer: String? = null): JSONObject {
    val owner = token()
    require(prefer == null || prefer == "gemini")
    val value = api.obj("POST", "/api/live/token", jsonOf("voice" to voice, "prefer" to prefer), epoch = owner.epoch)
    checkOwner(owner); return value
}
suspend fun FirasRepository.transcribe(audioBase64: String, language: String = state.value.language): String {
    val owner = token()
    require(audioBase64.length >= 4000)
    val value = api.obj("POST", "/api/transcribe", jsonOf("audio" to audioBase64, "format" to "wav", "lang" to language), epoch = owner.epoch, timeoutSeconds = 300)
    checkOwner(owner); return value.stringOrNull("text") ?: throw FirasFailure(Failures.incomplete)
}
suspend fun FirasRepository.tts(text: String, language: String = state.value.language): DownloadedArtifact {
    val owner = token()
    require(text.isNotBlank() && text.length <= 1300) { "Split spoken text at a sentence boundary into at most1300characters." }
    val file = File(ownerDirectory(context, owner.id!!), "speech-${newId()}.audio")
    return api.download("/api/tts", emptyMap(), file, owner.epoch, "POST", jsonOf("text" to text, "lang" to language, "gender" to "male")).also { checkOwner(owner) }
}
suspend fun FirasRepository.agentCredits(): JSONObject {
    val owner = token(); val value = api.obj("GET", "/api/agent/credits", epoch = owner.epoch); checkOwner(owner); return value
}
suspend fun FirasRepository.readPassage(docId: String, chunk: Int, window: Int = 2): JSONObject {
    val owner = token(); val value = api.obj("GET", "/api/brain/passage", query = mapOf("doc" to docId, "i" to chunk.toString(), "w" to window.coerceIn(0, 5).toString()), epoch = owner.epoch)
    checkOwner(owner); return value
}
suspend fun FirasRepository.deleteBrainSource(id: String): Boolean = action {
    val owner = token(); api.obj("DELETE", "/api/brain/doc", query = mapOf("id" to id), epoch = owner.epoch); checkOwner(owner); refreshBrainImpl()
}
suspend fun FirasRepository.wholeBrain(question: String, docIds: List<String>, outline: Boolean = false): JSONObject {
    val owner = token(); require(question.length <= 4000)
    val value = api.obj("POST", "/api/brain/whole", jsonOf("q" to question, "docIds" to JSONArray(docIds), "cid" to newId(), "lang" to state.value.language, "mode" to "outline".takeIf { outline }), epoch = owner.epoch, timeoutSeconds = 300)
    checkOwner(owner); return value
}
suspend fun FirasRepository.readMemory(): List<String> {
    val owner = token(); val value = api.obj("GET", "/api/memory", epoch = owner.epoch); checkOwner(owner)
    val rows = value.optJSONArray("memory") ?: return emptyList()
    return (0 until rows.length()).map { rows.optString(it) }
}
suspend fun FirasRepository.deleteMemory(index: Int? = null): Boolean = action {
    val owner = token(); require(index == null || index >= 0)
    api.obj("DELETE", "/api/memory", query = index?.let { mapOf("i" to it.toString()) } ?: emptyMap(), epoch = owner.epoch); checkOwner(owner)
}
suspend fun FirasRepository.changeEmail(currentPassword: String, email: String): Boolean = action {
    val owner = token(); val value = api.obj("POST", "/api/auth/change-email", jsonOf("current" to currentPassword, "email" to email.trim()), epoch = owner.epoch)
    checkOwner(owner); val user = Wire.user(value.getJSONObject("user")); if (user.id != owner.id) throw OwnerChanged()
    mutableState.update { it.copy(session = it.session.copy(user = user)) }
}
suspend fun FirasRepository.changePassword(current: String, password: String): Boolean = action {
    val owner = token(); api.obj("POST", "/api/auth/change-password", jsonOf("current" to current, "password" to password), epoch = owner.epoch); checkOwner(owner)
}
suspend fun FirasRepository.redeemCode(code: String): Boolean = action {
    val owner = token(); api.obj("POST", "/api/redeem", jsonOf("code" to code.trim()), epoch = owner.epoch); checkOwner(owner)
    val user = Wire.user(api.obj("GET", "/api/auth/me", epoch = owner.epoch).getJSONObject("user")); checkOwner(owner)
    if (user.id != owner.id) throw OwnerChanged(); mutableState.update { it.copy(session = it.session.copy(user = user)) }
}
suspend fun FirasRepository.deleteAccount(currentPassword: String): Boolean = action {
    val owner = token(); api.obj("POST", "/api/auth/delete-account", jsonOf("current" to currentPassword), epoch = owner.epoch); checkOwner(owner); logout()
}
suspend fun FirasRepository.shareThread(threadId: String, cid: String? = null): String {
    val owner = token(); val thread = getThread(threadId, owner) ?: throw Failures.http(404)
    if (thread.temporary) throw FirasFailure(UiNotice("لا تُنشر المحادثة المؤقتة.", "Temporary conversations cannot be published."))
    val actual = ensureServerThread(thread, owner); persistServerThread(actual, owner)
    val result = api.obj("POST", "/api/share", jsonOf("chatId" to actual.serverId, "cid" to cid, "title" to actual.title), epoch = owner.epoch)
    checkOwner(owner); val id = result.stringOrNull("id") ?: throw Failures.http(502)
    return api.baseUrl.newBuilder().encodedPath("/").addQueryParameter("share", id).build().toString()
}
suspend fun FirasRepository.githubStatus(): JSONObject { val owner = token(); val value = api.obj("GET", "/api/github/status", epoch = owner.epoch); checkOwner(owner); return value }
suspend fun FirasRepository.githubRepositories(): JSONObject { val owner = token(); val value = api.obj("GET", "/api/github/repos", epoch = owner.epoch); checkOwner(owner); return value }
suspend fun FirasRepository.githubBranches(repo: String): JSONObject { val owner = token(); val value = api.obj("GET", "/api/github/branches", query = mapOf("repo" to repo), epoch = owner.epoch); checkOwner(owner); return value }
suspend fun FirasRepository.githubTree(repo: String, ref: String): JSONObject { val owner = token(); val value = api.obj("GET", "/api/github/tree", query = mapOf("repo" to repo, "ref" to ref), epoch = owner.epoch); checkOwner(owner); return value }
suspend fun FirasRepository.githubFile(repo: String, ref: String, path: String): JSONObject { val owner = token(); val value = api.obj("GET", "/api/github/file", query = mapOf("repo" to repo, "ref" to ref, "path" to path), epoch = owner.epoch); checkOwner(owner); return value }
suspend fun FirasRepository.githubStart(): JSONObject { val owner = token(); val value = api.obj("GET", "/api/github/start", epoch = owner.epoch); checkOwner(owner); return value }
suspend fun FirasRepository.githubDisconnect(): Boolean = action { val owner = token(); api.obj("POST", "/api/github/disconnect", epoch = owner.epoch); checkOwner(owner) }
