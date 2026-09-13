package com.firas.ai.worker.remote

import android.content.Context
import android.os.Build
import com.firas.ai.notifications.CompanionNotifications
import com.firas.ai.worker.WorkerPolicy
import com.firas.ai.worker.WorkerRuntime
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.util.UUID

data class CompanionState(val linked: Boolean = false, val busy: Boolean = false, val phase: String = "unpaired", val error: String = "", val endpoint: String = "", val run: JSONObject? = null, val pendingStart: Boolean = false)
class CompanionController(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(CompanionState())
    val state = _state.asStateFlow()
    private var owner: String? = null
    private var record: JSONObject? = null
    private var store: PairedDeviceStore? = null
    private var client: CompanionClient? = null
    private var operation: Job? = null
    private var polling: Job? = null
    fun bind(account: String?) {
        if (owner == account) return
        operation?.cancel(); polling?.cancel(); client?.close(); client = null; record = null
        CompanionNotifications.clear(context)
        owner = account; store = account?.let { PairedDeviceStore(context, it) }; _state.value = CompanionState()
        val storage = store ?: return
        scope.launch {
            try {
                val saved = withContext(Dispatchers.IO) { storage.load() }
                if (owner != account || account != WorkerRuntime.owner.value || saved == null) return@launch
                check(saved.optString("ownerBinding") == WorkerPolicy.hash(account!!))
                record = saved; client = authenticated(saved)
                _state.value = CompanionState(linked = true, phase = "ready", endpoint = saved.getString("endpoint"), pendingStart = saved.has("pendingStart"))
                if (saved.optString("runId").isNotEmpty()) poll()
            } catch (_: Exception) { if (owner == account) _state.value = CompanionState(error = "Pairing storage is unavailable; pair again on this account") }
        }
    }
    private fun authenticated(value: JSONObject) = CompanionClient(value.getString("endpoint"), value.getString("pin"), value.getString("token"))
    private suspend fun check(account: String) { currentCoroutineContext().ensureActive(); check(owner == account && WorkerRuntime.owner.value == account) { "Account changed" } }
    fun pair(code: String) {
        val account = owner ?: return
        if (_state.value.busy) return
        operation = scope.launch {
            _state.value = _state.value.copy(busy = true, phase = "pairing", error = "")
            try {
                val invite = PairingInvitation.parse(code)
                val connection = CompanionClient(invite.endpoint, invite.pin)
                client?.close(); client = connection
                val claim = connection.request("/v1/pair/claim", JSONObject().put("nonce", invite.nonce).put("label", Build.MODEL.take(70)))
                check(account)
                var joined: JSONObject? = null
                repeat(60) {
                    if (joined == null) {
                        check(account)
                        val result = connection.request("/v1/pair/result", JSONObject().put("claimId", claim.getString("claimId")).put("secret", claim.getString("secret")))
                        check(account)
                        when (result.optString("phase")) { "paired" -> joined = result; "denied" -> error("Pairing was declined on the PC"); else -> delay(2000) }
                    }
                }
                val result = joined ?: error("Pairing confirmation expired")
                check(result.getString("companionId") == invite.companionId && result.getString("ownerBinding") == WorkerPolicy.hash(account)) { "The PC is signed into a different Firas account" }
                val saved = JSONObject().put("endpoint", invite.endpoint).put("pin", invite.pin).put("companionId", invite.companionId)
                    .put("deviceId", result.getString("deviceId")).put("token", result.getString("token")).put("ownerBinding", result.getString("ownerBinding"))
                val storage = store ?: error("Account changed")
                withContext(Dispatchers.IO) { storage.save(saved) }; check(account)
                record = saved; client?.close(); client = authenticated(saved)
                _state.value = CompanionState(linked = true, phase = "ready", endpoint = invite.endpoint)
            } catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) { if (owner == account) _state.value = _state.value.copy(error = error.message?.take(300) ?: "Cannot pair with this PC", phase = "unpaired") }
            finally { if (owner == account) _state.value = _state.value.copy(busy = false) }
        }
    }
    fun start(task: String) {
        val account = owner ?: return; val saved = record ?: return; val connection = client ?: return
        if (_state.value.busy || _state.value.run?.optBoolean("active") == true) return
        operation = scope.launch {
            _state.value = _state.value.copy(busy = true, error = "")
            try {
                // Persist before sending: after an uncertain response the recovery button
                // retries this exact ID/body, never a second paid task.
                val pending = saved.optJSONObject("pendingStart") ?: JSONObject().put("requestId", UUID.randomUUID().toString()).put("createdAt", System.currentTimeMillis()).put("task", task.trim()).also {
                    require(task.isNotBlank() && task.length <= WorkerPolicy.MAX_TASK)
                    saved.put("pendingStart", it)
                    val storage = store ?: error("Account changed"); withContext(Dispatchers.IO) { storage.save(saved) }
                }
                check(account)
                _state.value = _state.value.copy(pendingStart = true)
                val result = connection.request("/v1/worker/start", pending)
                check(account)
                saved.put("runId", result.getString("runId")).put("notifyRunId", result.getString("runId")).remove("pendingStart")
                val storage = store ?: error("Account changed"); withContext(Dispatchers.IO) { storage.save(saved) }; check(account)
                _state.value = _state.value.copy(pendingStart = false, phase = "running", run = null)
                poll()
            } catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) { if (owner == account) _state.value = _state.value.copy(error = (error.message ?: "Connection failed") + "\nThe start may have reached the PC. Recover this request or check the PC before a new task.", pendingStart = saved.has("pendingStart")) }
            finally { if (owner == account) _state.value = _state.value.copy(busy = false) }
        }
    }
    fun poll() {
        val account = owner ?: return; val saved = record ?: return; val connection = client ?: return
        val id = saved.optString("runId"); if (id.isEmpty()) return
        polling?.cancel()
        polling = scope.launch {
            var failures = 0
            while (isActive && owner == account && failures < 20) {
                try {
                    val result = connection.request("/v1/worker/state?runId=$id")
                    check(account); failures = 0
                    check(result.optString("runId") == id) { "PC returned a different task" }
                    _state.value = _state.value.copy(run = result, phase = result.optString("phase"), error = "")
                    if (result.optBoolean("active") && saved.optString("notifyRunId") != id) {
                        // Observe a live restored task before making it notification-eligible.
                        saved.put("notifyRunId", id)
                        val storage = store ?: error("Account changed")
                        withContext(Dispatchers.IO) { storage.save(saved) }; check(account)
                    }
                    if (!result.optBoolean("active")) {
                        if (saved.optString("notifyRunId") == id) {
                            try {
                                CompanionNotifications.postOnce(context, account, saved.getString("companionId"), id, result.optString("phase")) {
                                    owner?.takeIf { it == WorkerRuntime.owner.value }
                                }
                            } catch (cancel: CancellationException) { throw cancel }
                            catch (_: Exception) { /* Notification failure must not turn a finished PC task into a connection error. */ }
                        }
                        return@launch
                    }
                    delay(2200)
                } catch (cancel: CancellationException) { throw cancel }
                catch (_: Exception) { check(account); failures++; _state.value = _state.value.copy(phase = "disconnected", error = "PC is unreachable. Its remote task pauses after a lost connection.\nالكمبيوتر غير متصل؛ تتوقف الخطوات التالية عند انقطاع الاتصال."); delay(4000) }
            }
        }
    }
    fun control(action: String, approval: JSONObject? = null, decision: String? = null) {
        val account = owner ?: return; val saved = record ?: return; val connection = client ?: return
        if (_state.value.busy) return
        operation = scope.launch {
            _state.value = _state.value.copy(busy = true, error = "")
            try {
                val body = JSONObject().put("requestId", UUID.randomUUID().toString()).put("runId", saved.getString("runId"))
                approval?.let { body.put("approvalId", it.getString("id")).put("revision", it.getString("revision")).put("decision", decision) }
                check(account); connection.request("/v1/worker/$action", body); check(account); poll()
            } catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) { if (owner == account) _state.value = _state.value.copy(error = error.message?.take(400) ?: "Review the current action on the PC") }
            finally { if (owner == account) _state.value = _state.value.copy(busy = false) }
        }
    }
    fun unlink() {
        val account = owner ?: return; val connection = client; val storage = store
        operation?.cancel(); polling?.cancel()
        operation = scope.launch {
            try { connection?.request("/v1/devices/revoke", JSONObject()) } catch (_: Exception) { }
            connection?.close(); withContext(Dispatchers.IO) { storage?.clear() }
            if (owner == account) { record = null; client = null; _state.value = CompanionState(error = "Pairing removed here. If the PC was offline, revoke the device there too.") }
        }
    }
}
object CompanionRuntime {
    private var controller: CompanionController? = null
    fun bind(context: Context, owner: String?): CompanionController = (controller ?: CompanionController(context.applicationContext).also { controller = it }).also { it.bind(owner) }
}
