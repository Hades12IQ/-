package com.firas.ai.worker

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.firas.ai.worker.phone.PhoneWorkerEngine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/** Uses the application's authenticated session; never accepts cookies or provider keys. */
interface WorkerApi {
    suspend fun get(path: String): JSONObject
    suspend fun post(path: String, body: JSONObject): JSONObject
}

data class WorkerEvent(val id: Long, val text: String)
data class WorkerApproval(val id: String, val title: String, val detail: String)
data class WorkerState(
    val owner: String? = null, val runId: String? = null, val task: String = "",
    val phase: String = "idle", val summary: String = "", val steps: Int = 0,
    val events: List<WorkerEvent> = emptyList(), val approval: WorkerApproval? = null,
    val files: List<String> = emptyList(), val model: String = "",
) {
    val active: Boolean get() = phase in setOf("planning", "running", "approval")
}

/** The application must bind on every identity change, including while this screen is hidden. */
object WorkerRuntime {
    private var instance: PhoneWorkerEngine? = null
    private val _owner = MutableStateFlow<String?>(null)
    val owner = _owner.asStateFlow()
    @Synchronized fun bind(context: Context, ownerId: String?, api: WorkerApi): PhoneWorkerEngine {
        val engine = instance ?: PhoneWorkerEngine(context.applicationContext) { _owner.value }.also { instance = it }
        if (_owner.value != ownerId) {
            engine.stop("Account changed · تغيّر الحساب")
            com.firas.ai.worker.phone.PhoneWorkerNotifications.clear(context)
            _owner.value = ownerId
            com.firas.ai.worker.remote.CompanionRuntime.bind(context, ownerId)
            engine.bind(ownerId, api)
        } else engine.bind(ownerId, api)
        return engine
    }
    fun engine(): PhoneWorkerEngine? = instance
    fun stop() {
        if (Looper.myLooper() == Looper.getMainLooper()) instance?.stop("Stopped · تم الإيقاف")
        else Handler(Looper.getMainLooper()).post { instance?.stop("Stopped · تم الإيقاف") }
    }
}
