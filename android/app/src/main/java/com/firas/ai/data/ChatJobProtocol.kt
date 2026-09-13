package com.firas.ai.data

import kotlinx.coroutines.CancellationException
import org.json.JSONObject
import java.io.IOException

/** Recovery reads a receipt, never another generation POST. Missing acknowledgement stays pending. */
internal object ChatJobProtocol {
    class Unconfirmed : IOException("Job admission is unconfirmed")
    class Rejected(val failure: FirasFailure) : IOException("Job admission was rejected")

    suspend fun submit(cid: String, chatId: String, firstAttempt: Boolean,
                       current: () -> Unit, markAttempted: suspend () -> Unit,
                       post: suspend () -> JSONObject, lookup: suspend () -> JSONObject): JSONObject {
        require(cid.matches(Regex("[A-Za-z0-9_-]{1,64}")))
        current()
        if (firstAttempt) {
            markAttempted(); current()
            try { return post().also { current() } }
            catch (error: CancellationException) { throw error }
            catch (error: OwnerChanged) { throw error }
            catch (error: FirasFailure) { if (error.status in 400..499) throw Rejected(error) }
            catch (_: IOException) { }
        }
        current()
        val found = try { lookup().also { current() } }
        catch (error: CancellationException) { throw error }
        catch (error: OwnerChanged) { throw error }
        catch (_: Exception) { throw Unconfirmed() }
        return receipt(found, cid, chatId) ?: throw Unconfirmed()
    }

    fun receipt(value: JSONObject, cid: String, chatId: String): JSONObject? {
        val id = value.stringOrNull("jobId") ?: return null
        if (!id.matches(Regex("[A-Za-z0-9_-]{1,100}")) || value.stringOrNull("cid") != cid || value.optString("chatId") != chatId) return null
        // Completed receipts contain no answer. Fetch full status before landing a result.
        return jsonOf("jobId" to id, "phase" to "queued")
    }

    fun tailQuery(id: String, text: String, reasoning: String) = mapOf("id" to id, "from" to text.length.toString(), "fromR" to reasoning.length.toString())
    fun reconstruct(value: JSONObject, text: String, reasoning: String): JSONObject? {
        fun join(key: String, offsetKey: String, lengthKey: String, previous: String): String? {
            val offset = if (value.has(offsetKey)) value.optInt(offsetKey, -1) else 0
            if (offset < 0 || offset > 0 && offset != previous.length) return null
            val result = (if (offset > 0) previous else "") + value.optString(key, "")
            if (value.has(lengthKey) && value.optInt(lengthKey, -1) != result.length) return null
            return result
        }
        val fullText = join("text", "from", "textLen", text) ?: return null
        val fullReasoning = join("reasoning", "fromR", "reasoningLen", reasoning) ?: return null
        return JSONObject(value.toString()).put("text", fullText).put("reasoning", fullReasoning)
    }
}
