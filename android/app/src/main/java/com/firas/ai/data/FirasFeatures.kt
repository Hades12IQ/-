package com.firas.ai.data

import android.util.Base64
import com.firas.ai.notifications.FirasJobWorker
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.security.MessageDigest

internal suspend fun FirasRepository.createMediaImpl(command: MediaCommand): SubmissionOutcome {
    var owner: OwnerToken? = null
    var thread: ChatThread? = null
    var cid: String? = null
    var ownsSubmission = false
    try {
        owner = token()
        if (!state.value.session.signedIn) throw FirasFailure(UiNotice("سجّل الدخول لإنشاء الصور والفيديو والأغاني.", "Sign in to create images, videos and songs."), 403)
        thread = if (command.threadId != null) getThread(command.threadId, owner) ?: throw Failures.http(404) else newThread(Product.STUDIO)
        if (thread.temporary) throw FirasFailure(UiNotice("استخدم محادثة محفوظة لإنشاء ملف وسائط مستمر.", "Use a saved conversation to create background media."))
        if (command.prompt.isBlank() && command.lyrics.isBlank()) throw FirasFailure(UiNotice("اكتب وصفاً لما تريد إنشاءه.", "Describe what you want to create."))
        if (!sending.add(thread.id)) throw FirasFailure(Failures.busy)
        ownsSubmission = true
        if (state.value.jobs.any { it.threadId == thread.id && !it.terminal }) throw FirasFailure(Failures.busy)
        cid = newId()
        val language = state.value.language
        val preparing = when (command.kind) {
            MediaKind.MUSIC -> UiNotice("يتم كتابة الأغنية…", "Writing the song…", false)
            MediaKind.IMAGE -> UiNotice("جارٍ تجهيز الصورة…", "Preparing the image…", false)
            MediaKind.VIDEO -> UiNotice("جارٍ تجهيز الفيديو…", "Preparing the video…", false)
        }
        thread = thread.copy(title = if (thread.messages.isEmpty()) command.prompt.take(80) else thread.title,
            messages = thread.messages + ChatMessage("user-$cid", "user", command.prompt.ifBlank { command.lyrics }, cid, language = language) +
                ChatMessage("assistant-$cid", "assistant", "", cid, language = language, status = MessageStatus.PREPARING, notice = preparing), updatedAt = System.currentTimeMillis())
        saveThread(thread, owner)
        command.image?.let { saveAttachments(thread, listOf(it), owner) }
        thread = ensureServerThread(thread, owner)
        persistServerThread(thread, owner)
        checkOwner(owner)
        if (command.kind == MediaKind.IMAGE) {
            val quota = api.obj("POST", "/api/image/quota", epoch = owner.epoch)
            checkOwner(owner)
            if (quota.optInt("limit", -1) >= 0 && quota.optInt("remaining", 1) <= 0) throw Failures.http(429)
        }
        val request = when (command.kind) {
            MediaKind.IMAGE -> {
                if (command.prompt.length > 1000) throw Failures.http(413)
                jsonOf("prompt" to command.prompt, "w" to command.width.coerceIn(256, 1280), "h" to command.height.coerceIn(256, 1280), "chatId" to thread.serverId)
            }
            MediaKind.VIDEO -> {
                if (command.prompt.length > 2000) throw Failures.http(413)
                jsonOf("prompt" to command.prompt, "seconds" to command.seconds.coerceIn(2, 30), "chatId" to thread.serverId,
                    "image" to command.image?.let { "data:${it.mime};base64,${it.base64?.substringAfter("base64,", it.base64).orEmpty()}" })
            }
            MediaKind.MUSIC -> {
                if (command.lyrics.length > 6000 || command.prompt.length > 8000) throw Failures.http(413)
                jsonOf("prompt" to command.prompt, "lyrics" to command.lyrics, "seconds" to command.seconds.coerceIn(10, 600), "chatId" to thread.serverId)
            }
        }
        if (command.edit && command.kind == MediaKind.IMAGE) {
            val image = command.image?.base64 ?: throw FirasFailure(UiNotice("أرفق الصورة المطلوب تعديلها.", "Attach the image to edit."))
            request.remove("w"); request.remove("h"); request.put("image", image.substringAfter("base64,", image))
            val result = api.obj("POST", "/api/image/edit", request, epoch = owner.epoch, timeoutSeconds = 300)
            checkOwner(owner)
            val key = result.stringOrNull("key")
            val id = result.stringOrNull("jobId") ?: key ?: throw Failures.http(502)
            val job = JobState(id, owner.id!!, cid, thread.id, "image", thread.product, command.prompt.take(80), language, thread.serverId,
                phase = if (key != null) JobPhase.COMPLETE else JobPhase.QUEUED, mediaKey = key, mediaRequest = request.apply { remove("image") }.toString())
            if (job.terminal) landJob(job, owner) else { publishJob(job, owner); startWatcher(job, owner); FirasJobWorker.schedule(context) }
            return if (job.terminal) SubmissionOutcome.Completed(thread.id) else SubmissionOutcome.Accepted(job)
        }
        if (command.kind == MediaKind.MUSIC) {
            val instrumental = command.lyrics.isBlank() && Regex("(?i)\\binstrumental\\b|بدون كلمات|بدون غناء|موسيقى فقط|موسيقي فقط").containsMatchIn(command.prompt)
            val system = "You prepare a song request for Firas AI. Return ONLY one JSON object with title (short, user's language), style (English production/arrangement tags under 1500 characters), lyrics (complete singable words in the user's requested language/dialect, up to6000characters), instrumental (boolean). Do not put prose instructions in lyrics. Preserve supplied lyrics exactly. Generate original lyrics when a vocal song was requested. Leave lyrics empty ONLY when the request explicitly asks instrumental. No markdown fences, no commentary."
            val task = jsonOf("request" to command.prompt, "suppliedLyrics" to command.lyrics, "instrumentalRequested" to instrumental).toString()
            val preparation = request.put("stage", "preparation").put("instrumentalRequested", instrumental).put("userTitle", command.title.ifBlank { command.prompt.take(80) })
            val draft = JobState("pending:$cid", owner.id!!, cid, thread.id, "music", thread.product, command.prompt.take(80), language, thread.serverId, "chat", mediaRequest = preparation.toString())
            val body = jsonOf("messages" to JSONArray().put(jsonOf("role" to "system", "content" to system)).put(jsonOf("role" to "user", "content" to task)),
                "tier" to "mini", "think" to false, "cid" to cid, "chatId" to "", "product" to "ai", "kind" to "chat", "lang" to language, "nomem" to true, "nokb" to true)
            return submitQueue(draft, body, owner)
        }
        val draft = JobState("pending:$cid", owner.id!!, cid, thread.id, command.kind.wire, thread.product, command.title.ifBlank { command.prompt.take(80) }, language, thread.serverId, mediaRequest = request.toString())
        return startMediaRequest(draft, request, owner)
    } catch (error: CancellationException) { throw error }
    catch (error: Exception) {
        if (owner != null && thread != null && cid != null && error !is OwnerChanged) runCatching { updateAssistant(thread.id, cid, owner, null, null, MessageStatus.FAILED, notice(error)) }
        publishError(error, owner?.epoch ?: vault.epoch)
        return SubmissionOutcome.Refused(if (error is OwnerChanged) Failures.session else notice(error))
    } finally { if (ownsSubmission) thread?.let { sending.remove(it.id) } }
}

internal suspend fun FirasRepository.startMediaRequest(draft: JobState, request: JSONObject, owner: OwnerToken): SubmissionOutcome {
    checkOwner(owner)
    // Engine cache identity makes identical media input safe to replay after an uncertain acknowledgement.
    val outbox = jsonOf("job" to Wire.job(draft), "request" to request, "media" to true)
    withContext(Dispatchers.IO) { database.put(owner.id!!, "media-outbox", draft.cid, outbox) }
    publishJob(draft, owner); FirasJobWorker.schedule(context)
    val result = try { api.obj("POST", "/api/${draft.kind}/job", request, epoch = owner.epoch, timeoutSeconds = 12) }
    catch (error: CancellationException) { throw error }
    catch (error: Exception) {
        if (error is OwnerChanged) throw error
        if (error is FirasFailure && error.status in 400..499) {
            checkOwner(owner); database.remove(owner.id!!, "media-outbox", draft.cid)
            landJob(draft.copy(phase = JobPhase.FAILED, notice = error.notice), owner)
            throw error
        }
        val waiting = UiNotice("لم يصل تأكيد إنشاء الوسائط بعد. سيتم التحقق من الطلب نفسه.", "Media submission is not confirmed yet. The same request will be checked.", false)
        updateAssistant(draft.threadId, draft.cid, owner, null, null, MessageStatus.PREPARING, waiting)
        mutableNotices.tryEmit(waiting)
        return SubmissionOutcome.Accepted(draft)
    }
    checkOwner(owner)
    val key = result.stringOrNull("key")
    val phase = JobPolicy.phase(result.optString("phase", "queued"))
    if (phase == JobPhase.FAILED || result.opt("ok") == false) {
        database.remove(owner.id!!, "media-outbox", draft.cid); throw Failures.http(502)
    }
    val id = result.stringOrNull("jobId") ?: key ?: throw Failures.http(502)
    val job = draft.copy(id = id, transportKind = draft.kind, phase = if (phase == JobPhase.COMPLETE && key != null) JobPhase.COMPLETE else JobPhase.QUEUED,
        mediaKey = key, startedAt = System.currentTimeMillis(), deadline = System.currentTimeMillis() + JobPolicy.deadlineMillis(draft.kind), mediaRequest = request.toString())
    publishJob(job, owner)
    database.remove(owner.id!!, "media-outbox", draft.cid)
    if (draft.id != job.id) database.remove(owner.id, "job", draft.id)
    if (job.terminal) landJob(job, owner) else startWatcher(job, owner)
    return if (job.terminal) SubmissionOutcome.Completed(job.threadId) else SubmissionOutcome.Accepted(job)
}

internal suspend fun FirasRepository.finishMediaPreparation(job: JobState, owner: OwnerToken) {
    checkOwner(owner)
    val original = JSONObject(job.mediaRequest)
    val raw = job.text.trim().removePrefix("```json").removePrefix("```").removeSuffix("```").trim()
    val plan = runCatching { JSONObject(raw) }.getOrNull()
    val supplied = original.optString("lyrics")
    val lyrics = supplied.ifBlank { plan?.optString("lyrics").orEmpty() }
    val instrumental = original.optBoolean("instrumentalRequested")
    val style = plan?.stringOrNull("style")
    if (style == null || style.length > 2000 || lyrics.length > 6000 || !instrumental && lyrics.isBlank()) {
        // Never silently turn a requested vocal song into an instrumental.
        landJob(job.copy(phase = JobPhase.FAILED, text = "", mediaRequest = original.put("stage", "failed").toString(), notice = UiNotice("لم تكتمل كتابة كلمات الأغنية. أعد المحاولة.", "The song lyrics were not completed. Please retry.")), owner)
        return
    }
    val title = plan.stringOrNull("title") ?: job.title
    val request = jsonOf("prompt" to style, "lyrics" to if (instrumental) "" else lyrics, "seconds" to original.optInt("seconds", 30), "chatId" to job.serverChatId, "title" to title)
    updateAssistant(job.threadId, job.cid, owner, "", "", MessageStatus.PREPARING, UiNotice("جارٍ تلحين الأغنية…", "Composing the song…", false))
    try { startMediaRequest(job.copy(text = "", reasoning = "", title = title, transportKind = "music", mediaRequest = request.toString(), phase = JobPhase.QUEUED), request, owner) }
    catch (error: CancellationException) { throw error }
    catch (error: Exception) {
        if (error is OwnerChanged) throw error
        // The media outbox retains exact planned lyrics and retries without another writing charge.
        publishError(error, owner.epoch)
    }
}

internal suspend fun FirasRepository.landMediaItem(job: JobState, owner: OwnerToken): String {
    if (job.phase != JobPhase.COMPLETE) return ""
    val key = job.mediaKey ?: throw FirasFailure(Failures.incomplete)
    val request = runCatching { JSONObject(job.mediaRequest) }.getOrDefault(JSONObject())
    val kind = MediaKind.entries.first { it.wire == job.kind }
    val item = MediaItem(job.id, owner.id!!, kind, key, job.title, request.optString("prompt"), request.optString("lyrics"), threadId = job.threadId)
    checkOwner(owner)
    withContext(Dispatchers.IO) { database.put(owner.id, "media", item.id, Wire.media(item)) }
    checkOwner(owner)
    mutableState.update { it.copy(media = (it.media.filterNot { old -> old.id == item.id || old.kind == item.kind && old.key == item.key } + item).sortedByDescending { row -> row.createdAt }) }
    val metadata = jsonOf("key" to key, "jobId" to job.id, "title" to job.title, "prompt" to item.prompt, "lyrics" to item.lyrics,
        "seconds" to request.optInt("seconds"), "w" to request.optInt("w"), "h" to request.optInt("h"))
    return "```firas-${kind.wire}\n$metadata\n```"
}

internal suspend fun FirasRepository.refreshBrainImpl() {
    val owner = token()
    val value = api.obj("GET", "/api/brain/docs", epoch = owner.epoch)
    checkOwner(owner)
    mutableState.update { it.copy(brainLibrary = BrainLibrary(value.optJSONArray("docs")?.objects()?.map(Wire::brainSource).orEmpty(), value.optBoolean("guest"), value.optJSONObject("limits")?.toString() ?: "{}", value.optJSONObject("used")?.toString() ?: "{}")) }
}
internal suspend fun FirasRepository.importBrainImpl(title: String, kind: String, unit: String, pages: List<BrainPage>, ocr: Boolean): BrainSource {
    val owner = token()
    require(kind in setOf("pdf", "docx", "pptx", "xlsx", "text", "image") && unit in setOf("page", "slide", "sheet", "section"))
    require(pages.isNotEmpty())
    var id: String? = null
    var total = 0
    for ((part, rows) in pages.chunked(1200).withIndex()) {
        checkOwner(owner)
        val body = jsonOf("title" to title, "kind" to kind, "unit" to unit, "pages" to JSONArray(rows.map { jsonOf("p" to it.page, "l" to it.label, "text" to it.text) }), "docId" to id, "ocr" to true.takeIf { ocr && part == 0 })
        val value = api.obj("POST", "/api/brain/doc", body, epoch = owner.epoch, timeoutSeconds = 300)
        checkOwner(owner); id = value.stringOrNull("id") ?: throw Failures.http(502); total = value.optInt("total", value.optInt("chunks"))
    }
    refreshBrainImpl()
    return state.value.brainLibrary.sources.firstOrNull { it.id == id } ?: BrainSource(id!!, title, kind, unit, pages.size, total, true)
}
internal suspend fun FirasRepository.askBrainImpl(question: String, docIds: List<String>, tier: String): SubmissionOutcome {
    if (state.value.activeThread?.product != Product.BRAIN) newThread(Product.BRAIN)
    return submitText(question, emptyList(), tier, false, "brainask", docIds)
}
internal suspend fun FirasRepository.searchBrainImpl(query: String, docIds: List<String>, cid: String): List<BrainHit> {
    val owner = token()
    val result = api.obj("POST", "/api/brain/search", jsonOf("q" to query, "docIds" to JSONArray(docIds), "cid" to cid, "k" to 8), epoch = owner.epoch)
    checkOwner(owner)
    return result.optJSONArray("hits")?.objects()?.map { BrainHit(it.optString("text"), it.optString("docId"), it.optString("title"), it.optInt("page"), it.optInt("ci"), it.optDouble("score", 0.0), it.stringOrNull("label")) }.orEmpty()
}
internal suspend fun FirasRepository.translateImpl(text: String, target: String): String {
    val owner = token()
    require(target.isNotBlank() && target.length <= 80)
    val translated = StringBuilder()
    for (chunk in TranslationChunks.split(text)) {
        checkOwner(owner)
        if (chunk.isBlank()) { translated.append(chunk); continue }
        val result = api.obj("POST", "/api/translate", jsonOf("text" to chunk, "to" to target), epoch = owner.epoch, timeoutSeconds = 300)
        checkOwner(owner)
        val value = result.stringOrNull("text") ?: throw FirasFailure(Failures.incomplete)
        translated.append(value)
    }
    checkOwner(owner); return translated.toString()
}
object TranslationChunks {
    fun split(text: String, limit: Int = 7000): List<String> {
        require(limit >= 2)
        val result = mutableListOf<String>(); var start = 0
        while (start < text.length) {
            var end = (start + limit).coerceAtMost(text.length)
            if (end < text.length && Character.isHighSurrogate(text[end - 1])) end--
            if (end < text.length) { val boundary = text.lastIndexOf('\n', end - 1); if (boundary > start + limit / 2) end = boundary + 1 }
            result.add(text.substring(start, end)); start = end
        }
        return result
    }
}

internal fun ownerDirectory(context: android.content.Context, owner: String): File {
    val digest = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray()).joinToString("") { "%02x".format(it) }
    return File(context.filesDir, "owner-assets/$digest").apply { mkdirs() }
}
internal suspend fun FirasRepository.saveAttachments(thread: ChatThread, attachments: List<Attachment>, owner: OwnerToken) {
    for (attachment in attachments.filter { it.isImage }) {
        checkOwner(owner)
        require(attachment.id.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        val bytes = withContext(Dispatchers.IO) { Base64.decode(attachment.base64!!.substringAfter("base64,", attachment.base64), Base64.DEFAULT) }
        checkOwner(owner)
        if (thread.temporary) { temporaryAssets["${owner.epoch}:${thread.id}:${attachment.id}"] = bytes; continue }
        withContext(Dispatchers.IO) {
            checkOwner(owner)
            val directory = ownerDirectory(context, owner.id!!)
            val file = File(directory, attachment.id)
            val pending = File(directory, "${attachment.id}.part")
            try { pending.writeBytes(bytes); checkOwner(owner); check(pending.renameTo(file)) } finally { pending.delete() }
            database.put(owner.id, "asset", attachment.id, jsonOf("id" to attachment.id, "threadId" to thread.id, "name" to attachment.name, "mime" to attachment.mime))
        }
    }
}
internal val temporaryAssets = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()
suspend fun FirasRepository.documentAssets(threadId: String): Map<String, ByteArray> {
    val owner = token(); val thread = getThread(threadId, owner) ?: return emptyMap()
    if (thread.temporary) return temporaryAssets.filterKeys { it.startsWith("${owner.epoch}:$threadId:") }.mapKeys { it.key.substringAfterLast(':') }
    val result = withContext(Dispatchers.IO) {
        val directory = ownerDirectory(context, owner.id!!)
        database.records(owner.id, "asset").filter { it.optString("threadId") == threadId }.mapNotNull { row ->
            val id = row.optString("id")
            if (!id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) null else File(directory, id).takeIf { it.isFile }?.let { id to it.readBytes() }
        }.toMap()
    }
    checkOwner(owner); return result
}
internal suspend fun FirasRepository.downloadMediaImpl(item: MediaItem): DownloadedArtifact {
    val owner = token()
    if (item.ownerId != owner.id) throw OwnerChanged()
    val route = when (item.kind) { MediaKind.IMAGE -> "/api/image"; MediaKind.VIDEO -> "/api/video/file"; MediaKind.MUSIC -> "/api/music/file" }
    val query = mapOf((if (item.kind == MediaKind.IMAGE) "key" else "id") to item.key)
    val extension = when (item.kind) { MediaKind.IMAGE -> "png"; MediaKind.VIDEO -> "mp4"; MediaKind.MUSIC -> "mp3" }
    val safeId = MessageDigest.getInstance("SHA-256").digest(item.key.toByteArray()).joinToString("") { "%02x".format(it) }
    return api.download(route, query, File(ownerDirectory(context, owner.id!!), "$safeId.$extension"), owner.epoch).also { checkOwner(owner) }
}
internal suspend fun FirasRepository.downloadArtifactImpl(artifact: Artifact): DownloadedArtifact {
    val owner = token()
    val name = artifact.name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").take(140).ifBlank { "document" }
    val destination = File(ownerDirectory(context, owner.id!!), "${newId()}-$name")
    if (artifact.jobId != null && artifact.index != null) return api.download("/api/agent/artifact", mapOf("id" to artifact.jobId, "index" to artifact.index.toString(), "download" to "1"), destination, owner.epoch).also { checkOwner(owner) }
    val uri = URI(api.baseUrl.toString()).resolve(artifact.url)
    require(uri.scheme == "https" && uri.host == api.baseUrl.host && uri.path.startsWith("/api/"))
    return api.download(uri.rawPath + (uri.rawQuery?.let { "?$it" } ?: ""), emptyMap(), destination, owner.epoch).also { checkOwner(owner) }
}
