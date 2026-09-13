package com.firas.ai.data

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
private fun fileSha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { stream -> val bytes = ByteArray(64 * 1024); while (true) { val count = stream.read(bytes); if (count < 0) break; digest.update(bytes, 0, count) } }
    return digest.digest().joinToString("") { "%02x".format(it) }
}
private fun validPdf(file: File, artifact: NativeDocument): Boolean = runCatching {
    file.length() == artifact.pdfBytes && file.inputStream().use { input -> ByteArray(5).also { check(input.read(it) == 5) }.contentEquals("%PDF-".toByteArray()) } && fileSha256(file) == artifact.sha256
}.getOrDefault(false)

suspend fun FirasRepository.downloadNativeDocument(artifact: NativeDocument): File {
    val owner = token()
    require(artifact.pdfBytes in 1..268_435_456L)
    val directory = File(context.cacheDir, "exports/${sha256(owner.id!!.toByteArray())}").apply { mkdirs() }
    val file = File(directory, "${artifact.sha256}.pdf")
    if (withContext(Dispatchers.IO) { validPdf(file, artifact) }) { checkOwner(owner); return file }
    api.download("/api/chat/job/file", mapOf("id" to artifact.artifactId, "binary" to "pdf"), file, owner.epoch)
    checkOwner(owner)
    val valid = withContext(Dispatchers.IO) { validPdf(file, artifact) }
    checkOwner(owner)
    if (!valid) {
        withContext(Dispatchers.IO) { file.delete() }
        throw FirasFailure(UiNotice("لم يجتز ملف PDF فحص الاكتمال. أعد تنزيله؛ لم يُفتح ملف غير موثوق.", "The PDF failed its integrity check. Download it again; the invalid file was not opened."))
    }
    return file
}

internal suspend fun FirasRepository.hydrateNativeSource(artifact: NativeDocument, owner: OwnerToken): NativeDocumentSource {
    checkOwner(owner)
    val response = api.obj("GET", "/api/chat/job/file", query = mapOf("id" to artifact.artifactId, "source" to "html"), epoch = owner.epoch, timeoutSeconds = 60)
    checkOwner(owner)
    val source = response.stringOrNull("sourceHtml") ?: throw FirasFailure(Failures.incomplete)
    val bytes = source.toByteArray(Charsets.UTF_8)
    if (bytes.size > 32 * 1024 * 1024) throw Failures.http(413)
    val expectedHash = response.stringOrNull("sourceSha256") ?: throw FirasFailure(Failures.incomplete)
    if (sha256(bytes) != expectedHash.lowercase()) throw FirasFailure(Failures.incomplete)
    val assets = response.optJSONArray("assets")?.objects()?.map { value ->
        val id = value.getString("id"); require(id.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        Attachment(id, value.optString("mime", "image/jpeg"), base64 = value.getString("base64"), id = id)
    }.orEmpty()
    return NativeDocumentSource(source, assets)
}

/** Conversion is a durable server job, without a model call and without sending a session to a WebView. */
suspend fun FirasRepository.exportDocument(sourceHtml: String, filename: String, imageAssets: Map<String, ByteArray> = emptyMap()): File {
    val owner = token()
    val thread = state.value.activeThread ?: newThread(Product.AI)
    if (thread.temporary) throw FirasFailure(UiNotice("استخدم الطباعة المحلية للمحادثة المؤقتة، أو أنشئ الملف في محادثة محفوظة.", "Use local system printing for a temporary conversation, or create the file in a saved conversation."))
    require(sourceHtml.toByteArray(Charsets.UTF_8).size <= 32 * 1024 * 1024)
    if (imageAssets.size > 6 || imageAssets.values.any { it.size > 2 * 1024 * 1024 } || imageAssets.values.sumOf { it.size.toLong() } > 8 * 1024 * 1024) {
        throw FirasFailure(UiNotice("حد تصدير الصور هو ست صور، صورتها الواحدة حتى ٢ ميغابايت والمجموع حتى ٨ ميغابايت. لم تُصغّر الصور تلقائياً.", "PDF export accepts six images, up to2MiB each and8MiB total. The images were not automatically reduced."), 413)
    }
    val original = thread.messages.lastOrNull { it.role == "assistant" && it.visibleContent.contains(sourceHtml) }
    original?.nativeArtifact?.let { return downloadNativeDocument(it) }
    val cid = newId()
    val cleanName = filename.substringAfterLast('/').substringAfterLast('\\').take(140).let { if (it.endsWith(".pdf", true)) it else "$it.pdf" }
    val body = jsonOf("kind" to "documentexport", "sourceHtml" to sourceHtml, "filename" to cleanName, "format" to "pdf",
        "pdfImages" to JSONArray(imageAssets.map { (id, bytes) -> require(id.matches(Regex("[A-Za-z0-9_-]{1,128}"))); jsonOf("id" to id, "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP)) }),
        "messages" to JSONArray().put(jsonOf("role" to "user", "content" to "Export document")), "cid" to cid, "chatId" to "", "product" to "ai", "lang" to state.value.language, "tier" to "mini", "think" to false)
    if (body.toString().toByteArray(Charsets.UTF_8).size > 25_000_000) throw Failures.http(413)
    val draft = JobState("pending:$cid", owner.id!!, cid, thread.id, "documentexport", thread.product, cleanName, state.value.language,
        transportKind = "documentexport", mediaRequest = jsonOf("stage" to "documentexport", "targetMessageId" to original?.id).toString())
    submitQueue(draft, body, owner)
    while (true) {
        checkOwner(owner)
        val job = state.value.jobs.firstOrNull { it.cid == cid && it.threadId == thread.id } ?: throw FirasFailure(Failures.incomplete)
        if (job.terminal) {
            if (job.phase != JobPhase.COMPLETE) throw FirasFailure(job.notice ?: Failures.incomplete)
            val artifact = NativeDocument.parse(job.text) ?: throw FirasFailure(Failures.incomplete)
            return downloadNativeDocument(artifact)
        }
        if (job.id.startsWith("pending:")) resumePendingJobsImpl() else pollJob(job, owner)
        delay(1000)
    }
}

internal suspend fun FirasRepository.landNativeExport(job: JobState, owner: OwnerToken) {
    if (job.kind != "documentexport" || job.phase != JobPhase.COMPLETE) return
    val target = runCatching { JSONObject(job.mediaRequest).stringOrNull("targetMessageId") }.getOrNull() ?: return
    val artifact = NativeDocument.parse(job.text) ?: throw FirasFailure(Failures.incomplete)
    val thread = getThread(job.threadId, owner) ?: return
    val original = thread.messages.firstOrNull { it.id == target } ?: return
    // Attach the signed artifact metadata without discarding the editable HTML or selected version.
    val updated = if (original.selectedVersion in original.versions.indices) original.copy(versions = original.versions.mapIndexed { index, version ->
        if (index == original.selectedVersion) version.copy(content = NativeDocument.addToSource(version.content, artifact)) else version
    }) else original.copy(content = NativeDocument.addToSource(original.content, artifact))
    saveThread(thread.copy(messages = thread.messages.map { if (it.id == target) updated else it }), owner)
}
