package com.firas.ai.data

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class CurrentApiParityTest {
    @Test fun lostAcknowledgementReadsReceiptThenRequiresFullResultWithoutAnotherPost() = runBlocking {
        val events = mutableListOf<String>()
        val value = ChatJobProtocol.submit("cid", "chat", true, {}, { events += "persist-attempt" },
            { events += "POST"; throw IOException("lost") },
            { events += "GET"; jsonOf("jobId" to "job_123", "cid" to "cid", "chatId" to "chat", "phase" to "completed") })
        assertEquals(listOf("persist-attempt", "POST", "GET"), events)
        assertEquals("job_123", value.getString("jobId"))
        assertEquals("queued", value.getString("phase"))
        assertFalse(value.has("text"))
    }
    @Test fun resumedUncertainOutboxNeverReplaysEvenWhenLookupFailsWith4xx() = runBlocking {
        var posts = 0
        try {
            ChatJobProtocol.submit("cid", "chat", false, {}, {}, { posts++; JSONObject() }, { throw Failures.http(403) })
            fail("Unknown delivery was accepted")
        } catch (_: ChatJobProtocol.Unconfirmed) { }
        assertEquals(0, posts)
    }
    @Test fun definiteAdmissionRefusalNeverReconcilesOrReplays() = runBlocking {
        var lookups = 0
        try {
            ChatJobProtocol.submit("cid", "chat", true, {}, {}, { throw Failures.http(422) }, { lookups++; JSONObject() })
            fail("Definite refusal was accepted")
        } catch (failure: ChatJobProtocol.Rejected) { assertEquals(422, failure.failure.status) }
        assertEquals(0, lookups)
    }
    @Test fun ownerChangeAfterPostStopsAllFurtherRequests() = runBlocking {
        var current = true
        var lookups = 0
        try {
            ChatJobProtocol.submit("cid", "chat", true, { if (!current) throw OwnerChanged() }, {},
                { current = false; jsonOf("jobId" to "job") }, { lookups++; JSONObject() })
            fail("Old account result was accepted")
        } catch (_: OwnerChanged) { }
        assertEquals(0, lookups)
    }
    @Test fun wrongReceiptIdentityNeverReattaches() {
        val receipt = jsonOf("jobId" to "job_123", "cid" to "cid", "chatId" to "chat", "phase" to "completed")
        assertNotNull(ChatJobProtocol.receipt(receipt, "cid", "chat"))
        assertNull(ChatJobProtocol.receipt(receipt, "other-cid", "chat"))
        assertNull(ChatJobProtocol.receipt(receipt, "cid", "other-chat"))
        assertNull(ChatJobProtocol.receipt(JSONObject(), "cid", "chat"))
    }
    @Test fun statusTailsUseUtf16AndReplaceOnWorkerRestart() {
        val previous = "ع😀"
        assertEquals("3", ChatJobProtocol.tailQuery("j", previous, "") ["from"])
        val tail = jsonOf("text" to " نهاية", "from" to 3, "textLen" to 9, "reasoning" to "ر", "fromR" to 0, "reasoningLen" to 1)
        assertEquals(previous + " نهاية", ChatJobProtocol.reconstruct(tail, previous, "")?.getString("text"))
        assertNull(ChatJobProtocol.reconstruct(JSONObject(tail.toString()).put("from", 2), previous, ""))
        assertNull(ChatJobProtocol.reconstruct(JSONObject(tail.toString()).put("textLen", 100), previous, ""))
        assertEquals("short", ChatJobProtocol.reconstruct(jsonOf("text" to "short", "from" to 0), "a longer old answer", "old")?.getString("text"))
    }
    @Test fun allFiveModelsHaveExactPublicWireValuesAndCapabilities() {
        assertEquals(listOf("mini", "pro", "ultra", "max", "omnix"), FirasModelTier.entries.map { it.wire })
        assertEquals(listOf("luma 1", "nova 1", "titan 1", "atlas 1", "omnix 1"), FirasModelTier.entries.map { it.label })
        assertEquals(listOf(false, true, true, true, false), FirasModelTier.entries.map { it.supportsThinking })
        FirasModelTier.entries.forEach { assertEquals(it, FirasModelTier.fromWire(it.wire)) }
    }
    @Test fun pendingOmnixReceiptSurvivesActualWireAndCannotBindAnotherSession() {
        val request = "a".repeat(32)
        val receipt = OmnixReceipt.parse(jsonOf("owner" to "owner", "conversationId" to "chat", "requestKey" to request))!!
        val message = ChatMessage("assistant-c", "assistant", "", "c", tier = "omnix", status = MessageStatus.PREPARING, metadata = jsonOf("omnix" to receipt.json()).toString())
        assertEquals(receipt, OmnixReceipt.fromMessage(Wire.message(Wire.message(message, true))))
        val result = jsonOf("jobId" to "omxj_${"b".repeat(32)}", "sessionId" to "omxs_${"c".repeat(32)}", "conversationId" to "chat", "requestKey" to request)
        assertTrue(receipt.accepts(result))
        val bound = receipt.bind(result)
        assertFalse(bound.accepts(JSONObject(result.toString()).put("sessionId", "omxs_${"d".repeat(32)}")))
        assertFalse(bound.accepts(JSONObject(result.toString()).put("conversationId", "other")))
        assertNull(OmnixReceipt.parse(receipt.json().put("jobId", "../../other")))
    }
    @Test fun omnixDownloadsRequireTheExactManifestPath() {
        val id = "a".repeat(64)
        assertEquals("/api/omnix/files/$id", OmnixProtocol.filePath(jsonOf("id" to id, "url" to "/api/omnix/files/$id")))
        for (url in listOf("https://evil.invalid/$id", "/api/omnix/files/$id?owner=other", "/api/omnix/files/../$id")) assertNull(OmnixProtocol.filePath(jsonOf("id" to id, "url" to url)))
    }
    @Test fun telegramPairingUsesOnlyCurrentValidBotAndUnexpiredServerCode() {
        assertEquals(123456L, OmnixTelegramPolicy.userId("١٢٣٤٥٦"))
        assertEquals(123456L, OmnixTelegramPolicy.userId("۱۲۳۴۵۶"))
        assertNull(OmnixTelegramPolicy.userId("+123456"))
        assertFalse(OmnixTelegramPolicy.validUserId(4_503_599_627_370_496L))
        val status = jsonOf("ok" to true, "state" to "pairing", "connectionId" to "omxt_${"a".repeat(32)}",
            "bot" to jsonOf("username" to "FixtureBot", "id" to 123456), "pairing" to jsonOf("code" to "b".repeat(32), "expiresAt" to 2000))
        assertEquals("https://t.me/FixtureBot?start=${"b".repeat(32)}", OmnixTelegramPolicy.pairingUrl(status, 1000))
        assertNull(OmnixTelegramPolicy.pairingUrl(status, 2000))
        assertFalse(OmnixTelegramPolicy.mayConfigure(status))
        assertNull(OmnixTelegramPolicy.pairingUrl(JSONObject(status.toString()).put("bot", jsonOf("username" to "evil.invalid/x")), 1000))
    }
}
