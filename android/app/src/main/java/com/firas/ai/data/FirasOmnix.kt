package com.firas.ai.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.Base64

private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

suspend fun FirasRepository.omnixAccess(): JSONObject {
    val owner = token(); if (!state.value.session.signedIn) throw Failures.http(401)
    return api.obj("GET", "/api/omnix/access", epoch = owner.epoch, timeoutSeconds = 8).also { checkOwner(owner) }
}
suspend fun FirasRepository.requestOmnixAccess(reason: String): JSONObject {
    require(reason.trim().length in 20..1200)
    val owner = token(); if (!state.value.session.signedIn) throw Failures.http(401)
    return api.obj("POST", "/api/omnix/access", jsonOf("reason" to reason.trim()), epoch = owner.epoch, timeoutSeconds = 8).also { checkOwner(owner) }
}

private suspend fun FirasRepository.saveOmnixReceipt(threadId: String, cid: String, receipt: OmnixReceipt, owner: OwnerToken) {
    checkOwner(owner)
    val thread = getThread(threadId, owner) ?: throw OwnerChanged()
    require(receipt.owner == owner.id && receipt.conversationId == thread.serverId)
    val rows = thread.messages.map { row -> if (row.role == "assistant" && row.cid == cid) {
        val metadata = JSONObject(row.metadata).put("omnix", receipt.json())
        row.copy(metadata = metadata.toString(), tier = "omnix")
    } else row }
    val updated = thread.copy(messages = rows)
    saveThread(updated, owner); persistServerThread(updated, owner); checkOwner(owner)
}

internal suspend fun FirasRepository.sendOmnix(text: String, attachments: List<Attachment>): SubmissionOutcome {
    var owner: OwnerToken? = null
    var threadId: String? = null
    var createdCID: String? = null
    var draft: JobState? = null
    var posting = false
    var owns = false
    try {
        owner = token()
        if (!state.value.session.signedIn) throw Failures.http(401)
        var thread = state.value.activeThread ?: newThread()
        threadId = thread.id
        if (thread.temporary || thread.product !in setOf(Product.AI, Product.CODE)) throw FirasFailure(UiNotice("أومنكس يحتاج محادثة محفوظة في فراس جات أو فراس كود.", "Omnix needs a saved Firas Chat or Firas Code conversation."), 400)
        require(text.isNotBlank() && text.length <= 60_000 && attachments.size <= 10)
        if (!sending.add(thread.id)) throw FirasFailure(Failures.busy)
        owns = true
        if (state.value.jobs.any { it.threadId == thread.id && !it.terminal }) throw FirasFailure(Failures.busy)
        val access = api.obj("GET", "/api/omnix/access", epoch = owner.epoch, timeoutSeconds = 8); checkOwner(owner)
        if (access.optString("status") != "approved") throw FirasFailure(UiNotice("يحتاج أومنكس موافقة الوصول لهذا الحساب.", "Omnix access approval is required for this account."), 403, "omnix_approval_required")
        val cloud = api.obj("GET", "/api/omnix/cloud", epoch = owner.epoch, timeoutSeconds = 8); checkOwner(owner)
        if (!cloud.optBoolean("ready") || cloud.optString("state") != "ready") throw FirasFailure(UiNotice("مساحة أومنكس السحابية غير جاهزة بعد.", "Your Omnix cloud workspace is not ready yet."), 409, "omnix_cloud_preparing")
        thread = ensureServerThread(thread, owner)
        val serverId = thread.serverId ?: throw Failures.http(502)
        val cid = newId().replace("-", "")
        createdCID = cid
        val previous = thread.messages.asReversed().mapNotNull(OmnixReceipt::fromMessage).firstOrNull { it.owner == owner.id && it.conversationId == serverId && it.sessionId.isNotEmpty() }
        var receipt = OmnixReceipt(owner.id!!, serverId, cid, sessionId = previous?.sessionId ?: "", submission = "preparing")
        val rows = thread.messages + ChatMessage("user-$cid", "user", text, cid, tier = "omnix", language = state.value.language) +
            ChatMessage("assistant-$cid", "assistant", "", cid, tier = "omnix", language = state.value.language, status = MessageStatus.PREPARING, metadata = jsonOf("omnix" to receipt.json()).toString())
        thread = thread.copy(messages = rows, title = if (thread.messages.isEmpty()) text.take(80) else thread.title)
        saveThread(thread, owner); persistServerThread(thread, owner); checkOwner(owner)
        val uploaded = JSONArray()
        var total = 0L
        for (attachment in attachments) {
            checkOwner(owner)
            var name = attachment.name
            var mime = attachment.mime
            val bytes = when {
                attachment.base64 != null -> Base64.getDecoder().decode(attachment.base64.substringAfter("base64,", attachment.base64))
                attachment.text != null -> { name += ".txt"; mime = "text/plain"; attachment.text.toByteArray(Charsets.UTF_8) }
                else -> throw Failures.http(400, "omnix_original_attachment_unavailable")
            }
            if (mime.startsWith("image/")) {
                val png = bytes.take(8) == listOf(137,80,78,71,13,10,26,10).map { it.toByte() }
                val jpeg = bytes.take(3) == listOf(255,216,255).map { it.toByte() }
                require(png || jpeg)
                name = name.substringBeforeLast('.', name) + if (png) ".png" else ".jpg"
                mime = if (png) "image/png" else "image/jpeg"
            }
            total += bytes.size
            require(bytes.isNotEmpty() && bytes.size <= 20 * 1024 * 1024 && total <= 25 * 1024 * 1024)
            require(name.length <= 180 && name.toByteArray(Charsets.UTF_8).size <= 240 && name == name.trim() && !name.startsWith('.') && !name.contains(Regex("[\\x00-\\x1f\\x7f/\\\\:\\u202a-\\u202e\\u2066-\\u2069]")))
            val hash = digest(bytes)
            val input = api.upload("/api/omnix/inputs/$cid/" + newId().replace("-", ""), bytes, mime,
                mapOf("x-omnix-conversation" to serverId, "x-omnix-size" to bytes.size.toString(), "x-omnix-filename" to URLEncoder.encode(name, "UTF-8").replace("+", "%20"), "x-omnix-sha256" to hash), owner.epoch)
            checkOwner(owner)
            require(input.optString("id").matches(Regex("[a-f0-9]{64}")) && input.optString("requestKey") == cid && input.optString("name") == name && input.optLong("size") == bytes.size.toLong() && input.optString("sha256") == hash)
            uploaded.put(input.getString("id"))
        }
        receipt = receipt.copy(submission = "pending")
        saveOmnixReceipt(thread.id, cid, receipt, owner)
        val confirmed = Wire.thread(api.obj("GET", "/api/chats/$serverId", epoch = owner.epoch), owner.id!!); checkOwner(owner)
        val index = confirmed.messages.indexOfFirst { it.role == "assistant" && OmnixReceipt.fromMessage(it) == receipt }
        require(index > 0 && confirmed.messages[index - 1].role == "user" && confirmed.messages[index - 1].cid == cid)
        draft = JobState("pending:$cid", owner.id!!, cid, thread.id, "omnix", thread.product, thread.title, state.value.language, serverId, mediaRequest = jsonOf("receipt" to receipt.json()).toString())
        publishJob(draft, owner)
        posting = true
        val response = api.obj("POST", "/api/omnix/runs", jsonOf("requestKey" to cid, "text" to text, "product" to thread.product.wire, "conversationId" to serverId,
            "sessionId" to receipt.sessionId.takeIf { it.isNotEmpty() }, "attachments" to uploaded), epoch = owner.epoch, timeoutSeconds = 8)
        checkOwner(owner)
        val job = bindOmnixJob(draft, receipt.bind(response), owner)
        pollOmnixJob(job, owner)
        startWatcher(job, owner)
        return SubmissionOutcome.Accepted(job)
    } catch (error: CancellationException) { throw error }
    catch (error: Exception) {
        if (error is OwnerChanged) return SubmissionOutcome.Refused(Failures.session)
        if (posting && owner != null && draft != null) {
            runCatching { pollOmnixJob(draft, owner) }
            startWatcher(draft, owner)
            return SubmissionOutcome.Accepted(draft)
        }
        if (owner != null && threadId != null && createdCID != null) {
            val last = getThread(threadId, owner)?.messages?.firstOrNull { it.role == "assistant" && it.cid == createdCID }
            val receipt = last?.let(OmnixReceipt::fromMessage)
            if (last != null && receipt != null && receipt.jobId.isEmpty()) runCatching {
                saveOmnixReceipt(threadId, last.cid, receipt.copy(submission = "not_started"), owner)
                updateAssistant(threadId, last.cid, owner, null, null, MessageStatus.FAILED, notice(error))
            }
        }
        publishError(error, owner?.epoch ?: vault.epoch)
        return SubmissionOutcome.Refused(notice(error))
    } finally { if (owns) threadId?.let { sending.remove(it) } }
}

private suspend fun FirasRepository.bindOmnixJob(job: JobState, receipt: OmnixReceipt, owner: OwnerToken): JobState {
    val bound = job.copy(id = receipt.jobId.ifEmpty { job.id }, mediaRequest = jsonOf("receipt" to receipt.json()).toString())
    publishJob(bound, owner)
    if (bound.id != job.id) database.remove(owner.id!!, "job", job.id)
    saveOmnixReceipt(job.threadId, job.cid, receipt, owner)
    return bound
}

internal suspend fun FirasRepository.pollOmnixJob(job: JobState, owner: OwnerToken) {
    var receipt = OmnixReceipt.fromJob(job) ?: throw Failures.http(502)
    checkOwner(owner); require(receipt.owner == owner.id)
    var actual = job
    if (receipt.jobId.isEmpty()) {
        val discovery = api.obj("GET", "/api/omnix/conversations/" + receipt.conversationId, epoch = owner.epoch, timeoutSeconds = 8); checkOwner(owner)
        require(discovery.optString("conversationId") == receipt.conversationId)
        val cancelled = discovery.optJSONArray("cancelledRequests")
        if (cancelled != null && (0 until cancelled.length()).any { cancelled.optString(it) == receipt.requestKey }) {
            landJob(job.copy(phase = JobPhase.STOPPED, notified = true), owner); return
        }
        val match = discovery.optJSONArray("jobs")?.objects()?.firstOrNull { receipt.accepts(it) } ?: return
        receipt = receipt.bind(match)
        actual = bindOmnixJob(job, receipt, owner)
    }
    // Discovery only contains receipts; terminal jobs also require this authoritative GET.
    val value = api.obj("GET", "/api/omnix/runs/" + receipt.jobId, epoch = owner.epoch, timeoutSeconds = 8); checkOwner(owner)
    require(receipt.accepts(value))
    val result = value.optJSONObject("result")
    val progress = value.optJSONObject("progress")
    val phase = OmnixProtocol.phase(value.optString("state"))
    val output = result?.stringOrNull("output") ?: progress?.optJSONArray("says")?.let { array -> (0 until array.length()).joinToString("\n\n") { array.optString(it) } }.orEmpty()
    val files = if (result?.optString("filesStatus") == "ready") result.optJSONArray("files")?.objects()?.mapNotNull { row ->
        OmnixProtocol.filePath(row)?.let { Artifact(row.optString("name", "File"), it, jobId = receipt.jobId) }
    }.orEmpty() else emptyList()
    val updated = actual.copy(phase = phase, text = output, progress = value.toString(), files = files,
        steps = progress?.optJSONArray("plan")?.objects()?.map { AgentStep(it.optString("title"), it.optString("s"), it.optString("resultPreview")) }.orEmpty())
    if (updated.terminal && (phase != JobPhase.COMPLETE || result != null && result.optString("filesStatus") != "unavailable")) landJob(updated, owner)
    else { publishJob(updated.copy(phase = if (updated.terminal) JobPhase.RUNNING else phase), owner); updateAssistant(job.threadId, job.cid, owner, output, "", MessageStatus.STREAMING) }
    if (actual.id != job.id) state.value.jobs.firstOrNull { it.id == actual.id && !it.terminal }?.let { startWatcher(it, owner) }
}

internal suspend fun FirasRepository.restoreOmnixJobs(thread: ChatThread, owner: OwnerToken) {
    if (thread.temporary) return
    for (message in thread.messages.filter { it.role == "assistant" }) {
        val receipt = OmnixReceipt.fromMessage(message) ?: continue
        if (receipt.owner != owner.id || receipt.conversationId != thread.serverId || receipt.submission == "not_started") continue
        if (receipt.submission == "preparing") {
            updateAssistant(thread.id, message.cid, owner, null, null, MessageStatus.FAILED,
                UiNotice("توقّف تجهيز الطلب قبل إرساله. يمكنك إرساله مجدداً.", "Preparation stopped before submission. You can send this request again."))
            continue
        }
        if (state.value.jobs.any { it.cid == message.cid && it.threadId == thread.id }) continue
        val job = JobState(receipt.jobId.ifEmpty { "pending:${receipt.requestKey}" }, owner.id!!, message.cid, thread.id, "omnix", thread.product, thread.title,
            message.language, thread.serverId, mediaRequest = jsonOf("receipt" to receipt.json()).toString(), notified = true)
        publishJob(job, owner); startWatcher(job, owner)
    }
}

internal suspend fun FirasRepository.cancelOmnixJob(job: JobState, owner: OwnerToken): CancelOutcome {
    val receipt = OmnixReceipt.fromJob(job) ?: return CancelOutcome.FAILED
    checkOwner(owner); require(receipt.owner == owner.id)
    val value = if (receipt.jobId.isEmpty()) api.obj("POST", "/api/omnix/conversations/${receipt.conversationId}/cancel-request", jsonOf("requestKey" to receipt.requestKey), epoch = owner.epoch, timeoutSeconds = 8)
        else api.obj("POST", "/api/omnix/runs/${receipt.jobId}/cancel", JSONObject(), epoch = owner.epoch, timeoutSeconds = 8)
    checkOwner(owner)
    if (receipt.jobId.isEmpty()) require(value.optString("requestKey") == receipt.requestKey) else require(receipt.accepts(value))
    val stopped = value.optBoolean("cancelled") || value.optString("state") in setOf("cancelled", "canceled")
    if (stopped) landJob(job.copy(phase = JobPhase.STOPPED, notified = true), owner) else pollOmnixJob(job, owner)
    return if (stopped) CancelOutcome.STOPPED else CancelOutcome.NOT_RUNNING
}

suspend fun FirasRepository.approveOmnix(jobId: String, requestId: String, choice: String): Boolean = action {
    val owner = token(); require(choice in setOf("once", "deny"))
    val job = state.value.jobs.firstOrNull { it.id == jobId && it.ownerId == owner.id && !it.terminal } ?: throw Failures.http(404)
    val receipt = OmnixReceipt.fromJob(job) ?: throw Failures.http(400)
    val approval = OmnixProtocol.approval(job) ?: throw Failures.http(409)
    require(approval.optString("requestId") == requestId && approval.optJSONArray("choices")?.let { options -> (0 until options.length()).any { options.optString(it) == choice } } == true)
    require(choice == "deny" || approval.optBoolean("commandComplete"))
    api.obj("POST", "/api/omnix/runs/${receipt.jobId}/approval", jsonOf("requestId" to requestId, "choice" to choice), epoch = owner.epoch, timeoutSeconds = 8)
    checkOwner(owner); pollOmnixJob(job, owner)
}

internal suspend fun FirasRepository.downloadOmnixArtifact(artifact: Artifact): DownloadedArtifact {
    val owner = token()
    val job = state.value.jobs.firstOrNull { it.id == artifact.jobId && it.ownerId == owner.id } ?: throw Failures.http(404)
    val receipt = OmnixReceipt.fromJob(job) ?: throw Failures.http(400)
    val value = api.obj("GET", "/api/omnix/runs/${receipt.jobId}", epoch = owner.epoch, timeoutSeconds = 8); checkOwner(owner)
    require(receipt.accepts(value))
    val result = value.optJSONObject("result") ?: throw Failures.http(404)
    require(result.optString("filesStatus") == "ready")
    val file = result.optJSONArray("files")?.objects()?.firstOrNull { OmnixProtocol.filePath(it) == artifact.url } ?: throw Failures.http(404)
    val directory = File(context.cacheDir, "omnix/" + digest(owner.id!!.toByteArray())).apply { mkdirs() }
    val destination = File(directory, file.getString("id") + "-" + artifact.name.substringAfterLast('/').substringAfterLast('\\').take(120))
    val downloaded = api.download(artifact.url, emptyMap(), destination, owner.epoch); checkOwner(owner)
    val valid = withContext(Dispatchers.IO) {
        (!file.has("size") || destination.length() == file.optLong("size")) &&
            (file.stringOrNull("sha256") == null || digest(destination.readBytes()) == file.optString("sha256"))
    }
    checkOwner(owner)
    if (!valid) { destination.delete(); throw Failures.http(502, "omnix_file_integrity") }
    return downloaded.copy(name = artifact.name)
}
