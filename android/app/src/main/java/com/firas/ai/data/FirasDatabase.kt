package com.firas.ai.data

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject
import android.util.AtomicFile
import java.io.File
import java.security.MessageDigest

/** Every persistent lookup includes an owner. Temporary content never reaches this class. */
internal class FirasDatabase(context: Context) : SQLiteOpenHelper(context, "firas-native.db", null, 1) {
    private val payloadDirectory = File(context.filesDir, "record-payloads").apply { mkdirs() }
    private fun digest(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it) }
    private fun payloadOwner(owner: String, kind: String, id: String) = digest("$owner\u0000$kind\u0000$id".toByteArray(Charsets.UTF_8))
    private fun decode(owner: String, kind: String, id: String, body: String): JSONObject {
        val value = JSONObject(body)
        if (value.optInt("_payloadVersion") != 1) return value
        val file = value.getString("_payloadFile")
        require(file.matches(Regex("[a-f0-9]{64}-[a-f0-9]{64}")) && file.startsWith(payloadOwner(owner, kind, id) + "-"))
        val bytes = AtomicFile(File(payloadDirectory, file)).readFully()
        check(digest(bytes) == file.substringAfter('-'))
        return JSONObject(String(bytes, Charsets.UTF_8))
    }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE records(owner TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, updated INTEGER NOT NULL, PRIMARY KEY(owner,kind,id))")
        db.execSQL("CREATE INDEX records_owner_kind_updated ON records(owner,kind,updated DESC)")
        db.execSQL("CREATE TABLE notifications(owner TEXT NOT NULL, job TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(owner,job))")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) { /* Version 1 has no migration. Never discard user history. */ }
    @Synchronized fun records(owner: String, kind: String): List<JSONObject> = readableDatabase.query("records", arrayOf("id", "body"), "owner=? AND kind=?", arrayOf(owner, kind), null, null, "updated DESC").use { cursor ->
        buildList { while (cursor.moveToNext()) add(decode(owner, kind, cursor.getString(0), cursor.getString(1))) }
    }
    @Synchronized fun record(owner: String, kind: String, id: String): JSONObject? = readableDatabase.query("records", arrayOf("body"), "owner=? AND kind=? AND id=?", arrayOf(owner, kind, id), null, null, null).use { cursor ->
        if (cursor.moveToFirst()) decode(owner, kind, id, cursor.getString(0)) else null
    }
    @Synchronized fun put(owner: String, kind: String, id: String, body: JSONObject) {
        val bytes = body.toString().toByteArray(Charsets.UTF_8)
        val stored = if (bytes.size > 512_000) {
            // SQLite CursorWindow cannot return a multi-megabyte source/outbox row. An atomic,
            // content-addressed private file preserves it; the DB holds only an owner-bound pointer.
            val name = payloadOwner(owner, kind, id) + "-" + digest(bytes)
            val file = AtomicFile(File(payloadDirectory, name))
            val output = file.startWrite()
            try { output.write(bytes); file.finishWrite(output) } catch (error: Exception) { file.failWrite(output); throw error }
            jsonOf("_payloadVersion" to 1, "_payloadFile" to name).toString()
        } else String(bytes, Charsets.UTF_8)
        val values = ContentValues().apply { put("owner", owner); put("kind", kind); put("id", id); put("body", stored); put("updated", System.currentTimeMillis()) }
        check(writableDatabase.insertWithOnConflict("records", null, values, SQLiteDatabase.CONFLICT_REPLACE) >= 0)
    }
    @Synchronized fun remove(owner: String, kind: String, id: String) {
        writableDatabase.delete("records", "owner=? AND kind=? AND id=?", arrayOf(owner, kind, id))
        val prefix = payloadOwner(owner, kind, id) + "-"
        payloadDirectory.listFiles()?.filter { it.name.startsWith(prefix) && it.name.matches(Regex("[a-f0-9]{64}-[a-f0-9]{64}(?:\\.bak|\\.new)?")) }?.forEach { it.delete() }
    }
    @Synchronized fun saveThread(thread: ChatThread) { if (!thread.temporary) put(thread.ownerId, "thread", thread.id, Wire.thread(thread)) }
    @Synchronized fun thread(owner: String, id: String): ChatThread? = record(owner, "thread", id)?.let { Wire.thread(it, owner) }
    @Synchronized fun threads(owner: String) = records(owner, "thread").map { Wire.thread(it, owner) }
    @Synchronized fun saveJob(job: JobState) = put(job.ownerId, "job", job.id, Wire.job(job))
    @Synchronized fun jobs(owner: String) = records(owner, "job").map { Wire.job(it, owner) }
    @Synchronized fun land(thread: ChatThread, job: JobState) {
        val db = writableDatabase
        db.beginTransaction()
        try { saveThread(thread); saveJob(job); db.setTransactionSuccessful() } finally { db.endTransaction() }
    }
    @Synchronized fun claimNotification(owner: String, id: String): Boolean = writableDatabase.insertWithOnConflict("notifications", null, ContentValues().apply {
        put("owner", owner); put("job", id); put("at", System.currentTimeMillis())
    }, SQLiteDatabase.CONFLICT_IGNORE) >= 0
    @Synchronized fun releaseNotification(owner: String, id: String) { writableDatabase.delete("notifications", "owner=? AND job=?", arrayOf(owner, id)) }
}

internal object Wire {
    fun user(value: JSONObject): User {
        val id = value.stringOrNull("id") ?: throw Failures.http(502)
        return User(id, value.optString("name"), value.optString("email"), value.optBoolean("guest") || id.startsWith("g_"), value.optBoolean("admin"), value.optJSONObject("sub")?.toString() ?: "{}")
    }
    fun message(value: JSONObject, index: Int = 0): ChatMessage {
        val role = value.optString("role", "assistant")
        val cid = value.stringOrNull("cid") ?: value.stringOrNull("id") ?: "legacy-$index"
        val versions = value.optJSONArray("alts")?.objects()?.map { AnswerVersion(it.optString("content"), it.optString("reasoning"), it.optString("tier", "pro"), it.optString("lang", "ar")) }.orEmpty()
        return ChatMessage(value.optString("id", "$role-$cid"), role, value.optString("content"), cid,
            value.optString("reasoning"), value.optString("tier", "pro"), value.optString("lang", "ar"),
            runCatching { MessageStatus.valueOf(value.optString("localStatus", "COMPLETE")) }.getOrDefault(MessageStatus.COMPLETE),
            versions, value.optInt("altAt", -1), value.toString(), value.optJSONObject("localNotice")?.let { UiNotice(it.optString("ar"), it.optString("en")) })
    }
    fun message(value: ChatMessage, local: Boolean = false): JSONObject {
        val old = runCatching { JSONObject(value.metadata) }.getOrDefault(JSONObject())
        val result = JSONObject()
        for (name in listOf("files", "imageThumbs", "mode", "askAnswered", "retryOf", "retried", "mergedFrom")) if (old.has(name)) result.put(name, old.get(name))
        OmnixReceipt.parse(old.optJSONObject("omnix"))?.let { result.put("omnix", it.json()) }
        result.put("role", value.role).put("content", value.content).put("cid", value.cid).put("reasoning", value.reasoning).put("tier", value.tier).put("lang", value.language)
        if (value.versions.isNotEmpty()) result.put("alts", JSONArray(value.versions.map { jsonOf("content" to it.content, "reasoning" to it.reasoning, "tier" to it.tier, "lang" to it.language) })).put("altAt", value.selectedVersion)
        if (local) { result.put("id", value.id).put("localStatus", value.status.name); value.notice?.let { result.put("localNotice", jsonOf("ar" to it.ar, "en" to it.en)) } }
        return result
    }
    fun product(value: JSONObject): Product {
        value.stringOrNull("product")?.let { return Product.from(it) }
        fun enabled(key: String) = value.has(key) && !value.isNull(key) && value.opt(key) != false
        return when { enabled("codeProj") -> Product.CODE; enabled("brainNb") -> Product.BRAIN; enabled("agent") -> Product.AGENT; else -> Product.AI }
    }
    fun thread(value: JSONObject, owner: String): ChatThread = ChatThread(
        value.optString("localId", value.optString("id")), owner, value.optString("title", "محادثة جديدة"), product(value),
        value.optJSONArray("messages")?.objects()?.mapIndexed { index, row -> message(row, index) }.orEmpty(),
        if (value.has("localId")) value.stringOrNull("serverId") else value.stringOrNull("id"), false,
        value.optBoolean("pinned"), value.optLong("updatedAt", value.optLong("updated", System.currentTimeMillis())))
    fun thread(value: ChatThread): JSONObject = jsonOf("localId" to value.id, "id" to value.id, "title" to value.title, "product" to value.product.name,
        "messages" to JSONArray(value.messages.map { message(it, true) }), "serverId" to value.serverId, "pinned" to value.pinned, "updatedAt" to value.updatedAt)
    fun summary(value: ChatThread) = ThreadSummary(value.id, value.title, value.product, value.pinned, value.updatedAt)
    fun job(value: JobState): JSONObject = jsonOf("id" to value.id, "cid" to value.cid, "threadId" to value.threadId, "kind" to value.kind, "product" to value.product.name,
        "title" to value.title, "lang" to value.language, "serverChatId" to value.serverChatId, "transportKind" to value.transportKind, "phase" to value.phase.name,
        "startedAt" to value.startedAt, "deadline" to value.deadline, "text" to value.text, "reasoning" to value.reasoning, "progress" to value.progress,
        "mediaKey" to value.mediaKey, "mediaRequest" to value.mediaRequest, "unknownReads" to value.unknownReads, "notified" to value.notified,
        "steps" to JSONArray(value.steps.map { jsonOf("title" to it.title, "state" to it.state, "output" to it.output) }),
        "files" to JSONArray(value.files.map { jsonOf("name" to it.name, "url" to it.url, "type" to it.type, "jobId" to it.jobId, "index" to it.index) }),
        "notice" to value.notice?.let { jsonOf("ar" to it.ar, "en" to it.en) })
    fun job(value: JSONObject, owner: String): JobState = JobState(
        value.getString("id"), owner, value.optString("cid"), value.optString("threadId"), value.optString("kind", "chat"), Product.from(value.optString("product")), value.optString("title"), value.optString("lang", "ar"),
        value.stringOrNull("serverChatId"), value.optString("transportKind", value.optString("kind", "chat")),
        runCatching { JobPhase.valueOf(value.optString("phase")) }.getOrDefault(JobPhase.UNKNOWN), value.optLong("startedAt"), value.optLong("deadline"),
        value.optString("text"), value.optString("reasoning"), value.optString("progress", "{}"),
        value.optJSONArray("steps")?.objects()?.map { AgentStep(it.optString("title"), it.optString("state"), it.optString("output")) }.orEmpty(),
        value.optJSONArray("files")?.objects()?.map { Artifact(it.optString("name"), it.optString("url"), it.optString("type"), it.stringOrNull("jobId"), if (it.has("index")) it.optInt("index") else null) }.orEmpty(),
        value.stringOrNull("mediaKey"), value.optString("mediaRequest", "{}"), value.optInt("unknownReads"), value.optBoolean("notified"),
        value.optJSONObject("notice")?.let { UiNotice(it.optString("ar"), it.optString("en")) })
    fun media(value: MediaItem) = jsonOf("id" to value.id, "kind" to value.kind.name, "key" to value.key, "title" to value.title, "prompt" to value.prompt, "lyrics" to value.lyrics, "createdAt" to value.createdAt, "threadId" to value.threadId)
    fun media(value: JSONObject, owner: String) = MediaItem(value.getString("id"), owner, MediaKind.valueOf(value.getString("kind")), value.getString("key"), value.optString("title"), value.optString("prompt"), value.optString("lyrics"), value.optLong("createdAt"), value.stringOrNull("threadId"))
    fun brainSource(value: JSONObject) = BrainSource(value.optString("id"), value.optString("title"), value.optString("kind", "text"), value.optString("unit", "page"), value.optInt("pages"), value.optInt("chunks"), value.optBoolean("indexed"))
}
