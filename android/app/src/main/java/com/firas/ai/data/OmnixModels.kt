package com.firas.ai.data

import org.json.JSONObject

data class OmnixReceipt(val owner: String, val conversationId: String, val requestKey: String,
                        val jobId: String = "", val sessionId: String = "", val submission: String = "pending") {
    val valid get() = owner.isNotEmpty() && owner.length <= 128 && conversationId.matches(Regex("[A-Za-z0-9_-]{1,128}")) &&
        requestKey.matches(Regex("[A-Za-z0-9_-]{16,128}")) && (jobId.isEmpty() || jobId.matches(Regex("omxj_[a-f0-9]{32}"))) &&
        (sessionId.isEmpty() || sessionId.matches(Regex("omxs_[a-f0-9]{32}")))
    fun json() = jsonOf("owner" to owner, "conversationId" to conversationId, "requestKey" to requestKey, "jobId" to jobId, "sessionId" to sessionId, "submission" to submission)
    fun accepts(value: JSONObject) = valid && value.optString("conversationId") == conversationId && value.optString("requestKey") == requestKey &&
        value.optString("jobId").matches(Regex("omxj_[a-f0-9]{32}")) && value.optString("sessionId").matches(Regex("omxs_[a-f0-9]{32}")) &&
        (jobId.isEmpty() || value.optString("jobId") == jobId) && (sessionId.isEmpty() || value.optString("sessionId") == sessionId)
    fun bind(value: JSONObject): OmnixReceipt { require(accepts(value)); return copy(jobId = value.getString("jobId"), sessionId = value.getString("sessionId"), submission = "admitted") }
    companion object {
        fun parse(value: JSONObject?): OmnixReceipt? = value?.let {
            OmnixReceipt(it.optString("owner"), it.optString("conversationId"), it.optString("requestKey"), it.stringOrNull("jobId") ?: "", it.stringOrNull("sessionId") ?: "", it.stringOrNull("submission") ?: "pending").takeIf { receipt -> receipt.valid }
        }
        fun fromMessage(message: ChatMessage): OmnixReceipt? = runCatching { parse(JSONObject(message.metadata).optJSONObject("omnix")) }.getOrNull()
        fun fromJob(job: JobState): OmnixReceipt? = runCatching { parse(JSONObject(job.mediaRequest).optJSONObject("receipt")) }.getOrNull()
    }
}

object OmnixProtocol {
    fun terminal(state: String) = state in setOf("completed", "failed", "cancelled", "canceled", "interrupted")
    fun phase(state: String) = when (state) {
        "completed" -> JobPhase.COMPLETE
        "failed", "interrupted" -> JobPhase.FAILED
        "cancelled", "canceled" -> JobPhase.STOPPED
        "queued" -> JobPhase.QUEUED
        else -> JobPhase.RUNNING
    }
    fun filePath(value: JSONObject): String? {
        val id = value.optString("id")
        return ("/api/omnix/files/" + id).takeIf { id.matches(Regex("[a-f0-9]{64}")) && value.optString("url") == it }
    }
    fun approval(job: JobState): JSONObject? = runCatching { JSONObject(job.progress).optJSONObject("result")?.optJSONObject("approval") }.getOrNull()
}
