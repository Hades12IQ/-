package com.firas.ai.data

import java.io.File
import java.util.UUID

enum class Product(val wire: String, val title: String) {
    AI("ai", "Firas Chat"), AGENT("agent", "Firas Agent"), CODE("code", "Firas Code"),
    BRAIN("brain", "Firas Brain"), STUDIO("ai", "Firas Studio");
    companion object { fun from(value: String) = entries.firstOrNull { it.name.equals(value, true) } ?: entries.firstOrNull { it.wire == value } ?: AI }
}

data class User(val id: String, val name: String, val email: String, val guest: Boolean = false, val admin: Boolean = false, val subscription: String = "{}")
data class SessionState(val user: User? = null, val restoring: Boolean = true, val epoch: Long = 0) {
    val ownerId: String? get() = user?.id
    val signedIn: Boolean get() = user != null && !user.guest
}
data class UiNotice(val ar: String, val en: String, val error: Boolean = true) { fun text(language: String) = if (language == "en") en else ar }
data class AuthFlow(val stage: String = "idle", val email: String = "", val pendingId: String? = null, val browserUrl: String? = null, val code: String? = null, val expiresAt: Long? = null)
data class ThreadSummary(val id: String, val title: String, val product: Product = Product.AI, val pinned: Boolean = false, val updatedAt: Long = System.currentTimeMillis())
enum class MessageStatus { COMPLETE, PREPARING, STREAMING, FAILED, STOPPED }
data class AnswerVersion(val content: String, val reasoning: String = "", val tier: String = "pro", val language: String = "ar")
data class ChatMessage(
    val id: String, val role: String, val content: String, val cid: String,
    val reasoning: String = "", val tier: String = "pro", val language: String = "ar",
    val status: MessageStatus = MessageStatus.COMPLETE, val versions: List<AnswerVersion> = emptyList(),
    val selectedVersion: Int = -1, val metadata: String = "{}", val notice: UiNotice? = null,
) {
    val visibleContent: String get() = versions.getOrNull(selectedVersion)?.content ?: content
    val visibleReasoning: String get() = versions.getOrNull(selectedVersion)?.reasoning ?: reasoning
}
data class ChatThread(
    val id: String, val ownerId: String, val title: String = "محادثة جديدة", val product: Product = Product.AI,
    val messages: List<ChatMessage> = emptyList(), val serverId: String? = null, val temporary: Boolean = false,
    val pinned: Boolean = false, val updatedAt: Long = System.currentTimeMillis(),
)
data class Attachment(val name: String, val mime: String, val text: String? = null, val base64: String? = null, val id: String = UUID.randomUUID().toString()) {
    val isImage: Boolean get() = mime.startsWith("image/") && base64 != null
}
enum class JobPhase { QUEUED, RUNNING, COMPLETE, FAILED, STOPPED, UNKNOWN }
data class AgentStep(val title: String, val state: String, val output: String = "")
data class Artifact(val name: String, val url: String = "", val type: String = "", val jobId: String? = null, val index: Int? = null)
data class JobState(
    val id: String, val ownerId: String, val cid: String, val threadId: String,
    val kind: String, val product: Product, val title: String, val language: String = "ar",
    val serverChatId: String? = null, val transportKind: String = kind,
    val phase: JobPhase = JobPhase.QUEUED, val startedAt: Long = System.currentTimeMillis(),
    val deadline: Long = startedAt + JobPolicy.deadlineMillis(kind),
    val text: String = "", val reasoning: String = "", val progress: String = "{}",
    val steps: List<AgentStep> = emptyList(), val files: List<Artifact> = emptyList(),
    val mediaKey: String? = null, val mediaRequest: String = "{}", val unknownReads: Int = 0,
    val notified: Boolean = false, val notice: UiNotice? = null,
) {
    val terminal: Boolean get() = phase in setOf(JobPhase.COMPLETE, JobPhase.FAILED, JobPhase.STOPPED)
    val canCancel: Boolean get() = transportKind in setOf("chat", "longdoc", "longfile", "counteddoc", "documentexport", "officefile", "omnix") && !terminal
}
enum class MediaKind(val wire: String) { IMAGE("image"), VIDEO("video"), MUSIC("music") }
data class MediaCommand(
    val kind: MediaKind, val prompt: String, val lyrics: String = "", val seconds: Int = 30,
    val width: Int = 1024, val height: Int = 1024, val image: Attachment? = null,
    val edit: Boolean = false, val title: String = "", val threadId: String? = null,
)
data class MediaItem(val id: String, val ownerId: String, val kind: MediaKind, val key: String, val title: String, val prompt: String = "", val lyrics: String = "", val createdAt: Long = System.currentTimeMillis(), val threadId: String? = null)
data class BrainPage(val page: Int, val text: String, val label: String? = null)
data class BrainSource(val id: String, val title: String, val kind: String = "text", val unit: String = "page", val pages: Int = 0, val chunks: Int = 0, val indexed: Boolean = false)
data class BrainHit(val text: String, val docId: String, val title: String, val page: Int, val chunk: Int, val score: Double = 0.0, val label: String? = null)
data class BrainLibrary(val sources: List<BrainSource> = emptyList(), val guest: Boolean = false, val limits: String = "{}", val used: String = "{}")
data class RepositoryState(
    val session: SessionState = SessionState(), val threads: List<ThreadSummary> = emptyList(),
    val activeThread: ChatThread? = null, val jobs: List<JobState> = emptyList(),
    val media: List<MediaItem> = emptyList(), val brainLibrary: BrainLibrary = BrainLibrary(),
    val authFlow: AuthFlow = AuthFlow(), val loading: Boolean = false, val language: String = "ar",
    val error: UiNotice? = null,
)
sealed interface SubmissionOutcome {
    data class Accepted(val job: JobState) : SubmissionOutcome
    data class Completed(val threadId: String) : SubmissionOutcome
    data class Refused(val notice: UiNotice) : SubmissionOutcome
}
enum class CancelOutcome { STOPPED, NOT_RUNNING, UNSUPPORTED, FAILED }
data class DownloadedArtifact(val file: File, val name: String, val mime: String?)

internal data class OwnerToken(val id: String?, val epoch: Long)
internal fun newId(): String = UUID.randomUUID().toString()

/** Pure rules are shared by foreground watchers, background reconciliation and regression tests. */
object JobPolicy {
    fun phase(raw: String): JobPhase = when (raw.lowercase()) {
        "queued", "pending", "preparing" -> JobPhase.QUEUED
        "running", "processing", "run", "writing", "planning" -> JobPhase.RUNNING
        "completed", "complete", "done", "success" -> JobPhase.COMPLETE
        "failed", "fail", "error" -> JobPhase.FAILED
        "cancelled", "canceled", "stopped" -> JobPhase.STOPPED
        else -> JobPhase.UNKNOWN
    }
    fun deadlineMillis(kind: String): Long = when (kind) {
        "counteddoc", "officefile", "omnix" -> 7 * 24 * 60 * 60_000L
        "documentexport" -> 30 * 60_000L
        "longdoc", "longfile" -> 6 * 60 * 60_000L
        "agentrun" -> 3 * 60 * 60_000L
        "codebuild" -> 2 * 60 * 60_000L
        "image", "video" -> 20 * 60_000L
        "music" -> 10 * 60_000L
        else -> 30 * 60_000L
    }
    fun pollMillis(kind: String, elapsed: Long): Long = when (kind) {
        "chat", "longdoc" -> if (elapsed < 10_000) 350 else if (elapsed < 40_000) 700 else 1200
        "agentrun" -> 700
        "longfile", "counteddoc", "documentexport", "officefile", "omnix" -> 2000
        "codebuild" -> 4000
        "brainask" -> 3000
        "image" -> if (elapsed < 30_000) 2000 else 5000
        "video" -> if (elapsed < 30_000) 2500 else 6000
        else -> if (elapsed < 30_000) 2000 else 6000
    }
    fun unknownLimit(kind: String) = when (kind) { "agentrun" -> 2; "codebuild", "brainask" -> 1; else -> 3 }
    fun acceptsOwner(expectedId: String?, expectedEpoch: Long, actualId: String?, actualEpoch: Long) = expectedId == actualId && expectedEpoch == actualEpoch
    fun snapshot(previous: String, received: String?, terminal: Boolean): String = received?.takeIf { it.isNotEmpty() || terminal } ?: previous
    fun notificationKey(ownerId: String, jobId: String) = "$ownerId:$jobId:terminal"
    fun canQueue(encodedBytes: Int, temporary: Boolean) = !temporary && encodedBytes <= 550_000
}
