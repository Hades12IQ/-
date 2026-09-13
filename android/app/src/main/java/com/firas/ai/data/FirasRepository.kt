package com.firas.ai.data

import android.content.Context
import com.firas.ai.notifications.CompletionNotifications
import com.firas.ai.notifications.FirasJobWorker
import com.firas.ai.notifications.registerPushForCurrentAccount
import com.firas.ai.notifications.unregisterPushAtEpoch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import android.util.Base64
import java.util.concurrent.ConcurrentHashMap

class FirasRepository private constructor(context: Context) {
    internal val context = context.applicationContext
    internal val vault = SessionVault(this.context)
    internal val api = FirasApi(vault)
    internal val database = FirasDatabase(this.context)
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    internal val mutableState = MutableStateFlow(RepositoryState())
    val state = mutableState.asStateFlow()
    internal val mutableNotices = MutableSharedFlow<UiNotice>(extraBufferCapacity = 16)
    val notices = mutableNotices.asSharedFlow()
    internal val watchers = ConcurrentHashMap<String, Job>()
    internal val sending = ConcurrentHashMap.newKeySet<String>()
    internal val pollLocks = ConcurrentHashMap<String, Mutex>()
    private val restoreLock = Mutex()
    private val authLock = Mutex()
    private var restored = false
    private var browserVerifier: String? = null
    private var browserRequestId: String? = null
    @Volatile internal var foreground = false

    companion object {
        @Volatile private var instance: FirasRepository? = null
        fun get(context: Context): FirasRepository = instance ?: synchronized(this) {
            instance ?: FirasRepository(context.applicationContext).also { instance = it }
        }
    }

    fun setLanguage(language: String) { mutableState.update { it.copy(language = if (language == "en") "en" else "ar") } }
    fun clearError() { mutableState.update { it.copy(error = null) } }
    fun setForeground(value: Boolean) {
        foreground = value
        if (value) scope.launch { if (!restored) restoreSession(); resumePendingJobs() }
        else if (state.value.jobs.any { !it.terminal }) FirasJobWorker.schedule(context)
    }
    internal fun token(): OwnerToken {
        val session = state.value.session
        if (session.user == null) throw Failures.http(401)
        return OwnerToken(session.ownerId, session.epoch).also(::checkOwner)
    }
    internal fun checkOwner(token: OwnerToken) {
        val session = state.value.session
        if (!JobPolicy.acceptsOwner(token.id, token.epoch, session.ownerId, session.epoch) || token.epoch != vault.epoch) throw OwnerChanged()
    }
    internal fun notice(error: Throwable): UiNotice = (error as? FirasFailure)?.notice ?: Failures.network
    internal fun publishError(error: Throwable, epoch: Long = vault.epoch) {
        if (error is OwnerChanged || epoch != vault.epoch) return
        val value = notice(error)
        mutableState.update { it.copy(error = value) }; mutableNotices.tryEmit(value)
    }
    internal suspend fun action(block: suspend () -> Unit): Boolean {
        val epoch = vault.epoch
        return try { block(); true } catch (error: CancellationException) { throw error } catch (error: Exception) { publishError(error, epoch); false }
    }
    private fun beginIdentityTransition(clearCookies: Boolean): Long {
        val epoch = vault.newEpoch(clearCookies, keepGuest = true)
        watchers.values.forEach { it.cancel() }; watchers.clear(); sending.clear()
        temporaryAssets.clear()
        CompletionNotifications.clear(context)
        browserVerifier = null; browserRequestId = null
        val language = state.value.language
        mutableState.value = RepositoryState(session = SessionState(restoring = false, epoch = epoch), language = language, loading = true)
        return epoch
    }
    private suspend fun adopt(user: User, epoch: Long) {
        if (epoch != vault.epoch) throw OwnerChanged()
        val cachedThreads = withContext(Dispatchers.IO) { database.threads(user.id) }
        val jobs = withContext(Dispatchers.IO) { database.jobs(user.id) }
        val media = withContext(Dispatchers.IO) { database.records(user.id, "media").map { Wire.media(it, user.id) } }
        if (epoch != vault.epoch) throw OwnerChanged()
        mutableState.update { it.copy(session = SessionState(user, false, epoch), threads = cachedThreads.map(Wire::summary), jobs = jobs, media = media, authFlow = AuthFlow(), loading = false, error = null) }
        restored = true
        FirasJobWorker.schedule(context)
        scope.launch { refreshHistory(); refreshBrainLibrary(); resumePendingJobs(); registerPushForCurrentAccount() }
    }

    suspend fun restoreSession() = restoreLock.withLock {
        if (restored) return@withLock
        val epoch = vault.epoch
        mutableState.update { it.copy(session = SessionState(restoring = true, epoch = epoch)) }
        try {
            val response = when {
                vault.hasSession() -> api.obj("GET", "/api/auth/me", epoch = epoch)
                vault.hasGuest() -> api.obj("POST", "/api/guest", epoch = epoch)
                else -> null
            }
            if (response != null) adopt(Wire.user(response.getJSONObject("user")), epoch)
            else { restored = true; mutableState.update { it.copy(session = SessionState(restoring = false, epoch = epoch)) } }
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) {
            if (error is FirasFailure && error.status in setOf(401, 403)) { beginIdentityTransition(true); restored = true }
            else publishError(error, epoch)
            if (epoch == vault.epoch) mutableState.update { it.copy(session = it.session.copy(restoring = false), loading = false) }
        }
    }
    suspend fun login(email: String, password: String): Boolean = authLock.withLock {
        val epoch = beginIdentityTransition(true)
        try { adopt(Wire.user(api.obj("POST", "/api/auth/login", jsonOf("email" to email.trim(), "password" to password), epoch = epoch).getJSONObject("user")), epoch); true }
        catch (error: CancellationException) { throw error }
        catch (error: Exception) { publishError(error, epoch); if (epoch == vault.epoch) mutableState.update { it.copy(loading = false) }; false }
    }
    suspend fun startGuest(): Boolean = authLock.withLock {
        val epoch = beginIdentityTransition(state.value.session.signedIn)
        try { adopt(Wire.user(api.obj("POST", "/api/guest", epoch = epoch).getJSONObject("user")), epoch); true }
        catch (error: CancellationException) { throw error }
        catch (error: Exception) { publishError(error, epoch); if (epoch == vault.epoch) mutableState.update { it.copy(loading = false) }; false }
    }
    suspend fun signup(name: String, email: String, password: String): Boolean = authLock.withLock {
        val epoch = beginIdentityTransition(true)
        try {
            val result = api.obj("POST", "/api/auth/signup", jsonOf("name" to name.trim(), "email" to email.trim(), "password" to password), epoch = epoch)
            result.optJSONObject("user")?.let { adopt(Wire.user(it), epoch) } ?: run {
                if (epoch != vault.epoch) throw OwnerChanged()
                val pid = result.stringOrNull("pid") ?: throw Failures.http(502)
                mutableState.update { it.copy(authFlow = AuthFlow("verify", email.trim(), pid), loading = false) }
            }; true
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { publishError(error, epoch); if (epoch == vault.epoch) mutableState.update { it.copy(loading = false) }; false }
    }
    suspend fun pollSignup(pid: String = state.value.authFlow.pendingId.orEmpty()): Boolean = action {
        require(pid.isNotBlank())
        val epoch = vault.epoch
        val result = api.obj("POST", "/api/auth/verify-status", jsonOf("pid" to pid), epoch = epoch)
        if (epoch != vault.epoch || state.value.authFlow.pendingId != pid) throw OwnerChanged()
        result.optJSONObject("user")?.let { adopt(Wire.user(it), epoch) }
        if (result.optBoolean("expired") || result.optBoolean("gone") || result.optString("status") in setOf("expired", "gone")) throw Failures.http(410, "desktop_auth_expired")
    }
    suspend fun verifySignup(token: String): Boolean = authLock.withLock {
        val epoch = beginIdentityTransition(true)
        try { adopt(Wire.user(api.obj("POST", "/api/auth/verify-signup", jsonOf("token" to token), epoch = epoch).getJSONObject("user")), epoch); true }
        catch (error: CancellationException) { throw error } catch (error: Exception) { publishError(error, epoch); mutableState.update { it.copy(loading = false) }; false }
    }
    suspend fun resendVerification(email: String): Boolean = action { api.obj("POST", "/api/auth/resend-code", jsonOf("email" to email.trim())) }
    suspend fun forgotPassword(email: String): Boolean = action { api.obj("POST", "/api/auth/forgot", jsonOf("email" to email.trim())) }
    suspend fun resetPassword(uid: String, resetToken: String, password: String): Boolean = authLock.withLock {
        val epoch = beginIdentityTransition(true)
        try { adopt(Wire.user(api.obj("POST", "/api/auth/reset", jsonOf("uid" to uid, "token" to resetToken, "password" to password), epoch = epoch).getJSONObject("user")), epoch); true }
        catch (error: CancellationException) { throw error } catch (error: Exception) { publishError(error, epoch); mutableState.update { it.copy(loading = false) }; false }
    }
    suspend fun beginBrowserLogin(): Boolean = authLock.withLock {
        val epoch = beginIdentityTransition(true)
        try {
            val verifier = BrowserSignInProof.verifier()
            val challenge = BrowserSignInProof.challenge(verifier)
            val result = api.obj("POST", "/api/desktop-auth/start", jsonOf("challenge" to challenge, "lang" to state.value.language), epoch = epoch)
            if (epoch != vault.epoch) throw OwnerChanged()
            val uri = android.net.Uri.parse(result.getString("browserUrl"))
            require(BrowserSignInProof.allowedBrowserUrl(uri.toString(), api.baseUrl.toString(), result.getString("id")))
            browserVerifier = verifier; browserRequestId = result.getString("id")
            mutableState.update { it.copy(authFlow = AuthFlow("browser", browserUrl = uri.toString(), code = result.getString("code"), expiresAt = result.getLong("expiresAt")), loading = false) }; true
        } catch (error: CancellationException) { throw error } catch (error: Exception) { publishError(error, epoch); mutableState.update { it.copy(loading = false) }; false }
    }
    suspend fun pollBrowserLogin(): Boolean = action {
        val id = browserRequestId ?: return@action
        val verifier = browserVerifier ?: return@action
        val epoch = vault.epoch
        val result = api.obj("POST", "/api/desktop-auth/poll", jsonOf("id" to id, "verifier" to verifier), epoch = epoch)
        if (epoch != vault.epoch || browserRequestId != id) throw OwnerChanged()
        if (result.optString("status") == "approved") { val user = Wire.user(result.getJSONObject("user")); browserVerifier = null; browserRequestId = null; adopt(user, epoch) }
    }
    suspend fun cancelBrowserLogin(): Boolean = action {
        val id = browserRequestId; val verifier = browserVerifier
        browserVerifier = null; browserRequestId = null
        mutableState.update { it.copy(authFlow = AuthFlow(), loading = false) }
        if (id != null && verifier != null) api.obj("POST", "/api/desktop-auth/cancel", jsonOf("id" to id, "verifier" to verifier))
    }
    suspend fun logout(): Boolean = authLock.withLock {
        val guest = state.value.session.user?.guest == true
        val epoch = beginIdentityTransition(false)
        try {
            if (!guest) runCatching { unregisterPushAtEpoch(epoch) }
            api.obj(if (guest) "DELETE" else "POST", if (guest) "/api/guest" else "/api/auth/logout", epoch = epoch)
        }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { /* Local sign-out still removes credentials when offline. */ }
        finally { val clearEpoch = vault.newEpoch(true, keepGuest = !guest); restored = true; mutableState.update { it.copy(session = SessionState(restoring = false, epoch = clearEpoch), loading = false) } }
        true
    }

    suspend fun newThread(product: Product = Product.AI, temporary: Boolean = false): ChatThread {
        val owner = token()
        val thread = ChatThread(newId(), owner.id!!, if (state.value.language == "en") "New conversation" else "محادثة جديدة", product, temporary = temporary)
        saveThread(thread, owner)
        mutableState.update { it.copy(activeThread = thread) }
        return thread
    }
    internal suspend fun saveThread(thread: ChatThread, owner: OwnerToken) {
        checkOwner(owner)
        if (!thread.temporary) withContext(Dispatchers.IO) { database.saveThread(thread) }
        checkOwner(owner)
        mutableState.update { current -> current.copy(
            activeThread = if (current.activeThread?.id == thread.id) thread else current.activeThread,
            threads = if (thread.temporary) current.threads else (current.threads.filterNot { it.id == thread.id } + Wire.summary(thread)).sortedWith(compareByDescending<ThreadSummary> { it.pinned }.thenByDescending { it.updatedAt })) }
    }
    internal suspend fun getThread(id: String, owner: OwnerToken): ChatThread? {
        checkOwner(owner)
        state.value.activeThread?.takeIf { it.id == id }?.let { return it }
        val result = withContext(Dispatchers.IO) { database.thread(owner.id!!, id) }
        checkOwner(owner); return result
    }
    suspend fun refreshHistory(): Boolean = action {
        val owner = token()
        if (!state.value.session.signedIn) return@action
        val response = api.json("GET", "/api/chats", epoch = owner.epoch) as? JSONArray ?: throw Failures.http(502)
        val locals = withContext(Dispatchers.IO) { database.threads(owner.id!!) }
        checkOwner(owner)
        val serverRows = response.objects().map { row ->
            val local = locals.firstOrNull { it.serverId == row.optString("id") }
            ThreadSummary(local?.id ?: row.optString("id"), row.optString("title"), Wire.product(row), row.optBoolean("pinned"), row.optLong("updatedAt", row.optLong("updated", local?.updatedAt ?: 0)))
        }
        val all = serverRows + locals.filter { it.serverId == null }.map(Wire::summary)
        checkOwner(owner)
        mutableState.update { it.copy(threads = all.distinctBy { row -> row.id }.sortedWith(compareByDescending<ThreadSummary> { it.pinned }.thenByDescending { it.updatedAt })) }
    }
    suspend fun openThread(id: String): Boolean = action {
        val owner = token()
        val local = withContext(Dispatchers.IO) { database.thread(owner.id!!, id) }
        checkOwner(owner)
        val summary = state.value.threads.firstOrNull { it.id == id }
        val initial = local ?: ChatThread(id, owner.id!!, summary?.title.orEmpty(), summary?.product ?: Product.AI, serverId = id)
        mutableState.update { it.copy(activeThread = initial, loading = true) }
        try {
            if (state.value.session.signedIn && initial.serverId != null) {
                val result = api.obj("GET", "/api/chats/${initial.serverId}", epoch = owner.epoch)
                checkOwner(owner)
                var fetched = Wire.thread(result, owner.id!!).copy(id = id)
                val activeJobs = state.value.jobs.filter { it.threadId == id && !it.terminal }
                for (job in activeJobs) fetched = fetched.copy(messages = mergeMessages(fetched.messages, initial.messages.filter { it.cid == job.cid }))
                saveThread(fetched, owner)
                restoreOmnixJobs(fetched, owner)
            }
        } finally { if (owner.epoch == vault.epoch && state.value.activeThread?.id == id) mutableState.update { it.copy(loading = false) } }
    }
    internal fun mergeMessages(existing: List<ChatMessage>, additions: List<ChatMessage>): List<ChatMessage> {
        val rows = existing.toMutableList()
        for (message in additions) { val index = rows.indexOfFirst { it.cid == message.cid && it.role == message.role }; if (index >= 0) rows[index] = message else rows.add(message) }
        return rows
    }
    internal suspend fun ensureServerThread(thread: ChatThread, owner: OwnerToken): ChatThread {
        checkOwner(owner)
        if (thread.temporary || !state.value.session.signedIn || thread.serverId != null) return thread
        val body = jsonOf("title" to thread.title, "messages" to JSONArray(thread.messages.filter { it.role == "user" || it.status == MessageStatus.COMPLETE }.map { Wire.message(it) }), "clientId" to thread.id,
            "agent" to (true.takeIf { thread.product == Product.AGENT }), "codeProj" to (true.takeIf { thread.product == Product.CODE }), "brainNb" to (true.takeIf { thread.product == Product.BRAIN }))
        val result = api.obj("POST", "/api/chats", body, epoch = owner.epoch)
        checkOwner(owner)
        val serverId = result.stringOrNull("id") ?: throw Failures.http(502)
        val latest = getThread(thread.id, owner) ?: thread
        val updated = latest.copy(serverId = serverId)
        saveThread(updated, owner); return updated
    }
    internal suspend fun persistServerThread(thread: ChatThread, owner: OwnerToken) {
        if (thread.temporary || !state.value.session.signedIn) return
        checkOwner(owner)
        val actual = ensureServerThread(thread, owner)
        val id = actual.serverId ?: return
        val remote = api.obj("GET", "/api/chats/$id", epoch = owner.epoch)
        checkOwner(owner)
        val localRows = (getThread(thread.id, owner) ?: actual).messages.filter { it.role == "user" || it.status == MessageStatus.COMPLETE || it.status == MessageStatus.STOPPED ||
            OmnixReceipt.fromMessage(it)?.let { receipt -> receipt.owner == owner.id && receipt.conversationId == id } == true }
        val merged = mergeMessages(Wire.thread(remote, owner.id!!).messages, localRows)
        api.obj("PUT", "/api/chats/$id", jsonOf("messages" to JSONArray(merged.map { Wire.message(it) }), "title" to actual.title), epoch = owner.epoch)
        checkOwner(owner)
    }
    suspend fun deleteThread(id: String): Boolean = action {
        val owner = token(); val thread = getThread(id, owner)
        if (state.value.jobs.any { it.threadId == id && !it.terminal }) throw FirasFailure(Failures.busy)
        val serverId = thread?.serverId ?: id.takeIf { state.value.session.signedIn }
        if (serverId != null && thread?.temporary != true) api.obj("DELETE", "/api/chats/$serverId", epoch = owner.epoch)
        checkOwner(owner); withContext(Dispatchers.IO) { database.remove(owner.id!!, "thread", id) }; checkOwner(owner)
        mutableState.update { it.copy(threads = it.threads.filterNot { row -> row.id == id }, activeThread = it.activeThread?.takeUnless { row -> row.id == id }) }
    }
    suspend fun pinThread(id: String, pinned: Boolean): Boolean = action {
        val owner = token(); val thread = getThread(id, owner) ?: return@action
        if (thread.serverId != null && state.value.session.signedIn) api.obj("PUT", "/api/chats/${thread.serverId}", jsonOf("pinned" to pinned), epoch = owner.epoch)
        checkOwner(owner); saveThread(thread.copy(pinned = pinned), owner)
    }

    suspend fun send(text: String, attachments: List<Attachment> = emptyList(), tier: String = "pro", think: Boolean = false): SubmissionOutcome = sendImpl(text, attachments, tier, think)
    suspend fun cancelJob(id: String): CancelOutcome = cancelJobImpl(id)
    suspend fun refreshJobs(): Boolean = action { reconcileJobsImpl() }
    suspend fun resumePendingJobs() = resumePendingJobsImpl()
    suspend fun createMedia(command: MediaCommand): SubmissionOutcome = createMediaImpl(command)
    suspend fun refreshBrainLibrary(): Boolean = action { refreshBrainImpl() }
    suspend fun importBrain(title: String, kind: String, unit: String, pages: List<BrainPage>, ocr: Boolean = false): BrainSource = importBrainImpl(title, kind, unit, pages, ocr)
    suspend fun askBrain(question: String, docIds: List<String> = emptyList(), tier: String = "pro"): SubmissionOutcome = askBrainImpl(question, docIds, tier)
    suspend fun searchBrain(query: String, docIds: List<String> = emptyList(), cid: String = newId()): List<BrainHit> = searchBrainImpl(query, docIds, cid)
    suspend fun translate(text: String, target: String): String = translateImpl(text, target)
    suspend fun downloadArtifact(artifact: Artifact): DownloadedArtifact = if (artifact.url.startsWith("/api/omnix/files/")) downloadOmnixArtifact(artifact) else downloadArtifactImpl(artifact)
    suspend fun downloadMedia(item: MediaItem): DownloadedArtifact = downloadMediaImpl(item)
    suspend fun selectAnswerVersion(messageId: String, version: Int): Boolean = action {
        val owner = token(); val thread = state.value.activeThread ?: return@action
        val message = thread.messages.firstOrNull { it.id == messageId && it.role == "assistant" } ?: return@action
        require(version in -1 until message.versions.size)
        val updated = thread.copy(messages = thread.messages.map { if (it.id == messageId) it.copy(selectedVersion = version) else it })
        saveThread(updated, owner); persistServerThread(updated, owner)
    }
    suspend fun workerGet(path: String): JSONObject { require(path == "/api/worker/models"); val owner = token(); val value = api.obj("GET", path, epoch = owner.epoch); checkOwner(owner); return value }
    suspend fun workerPost(path: String, body: JSONObject): JSONObject { require(path == "/api/worker/gemini"); val owner = token(); val value = api.obj("POST", path, body, epoch = owner.epoch, timeoutSeconds = 300); checkOwner(owner); return value }
}
