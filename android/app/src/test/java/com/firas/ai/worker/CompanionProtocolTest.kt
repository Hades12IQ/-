package com.firas.ai.worker

import com.firas.ai.worker.remote.PairingInvitation
import org.junit.Assert.*
import org.junit.Test

class CompanionProtocolTest {
    @Test fun endpointMustBeLiteralPrivatePinnedHttps() {
        PairingInvitation.validateEndpoint("https://192.168.1.3:38221")
        PairingInvitation.validateEndpoint("https://10.1.2.3:38221")
        listOf("http://192.168.1.3:3", "https://8.8.8.8:443", "https://example.com:443", "https://192.168.1.3:3/path", "https://user@192.168.1.3:3", "https://192.168.1.3:3?x=1", "https://192.168.999.3:3", "https://192.168.01.3:3").forEach { value ->
            try { PairingInvitation.validateEndpoint(value); fail(value) } catch (_: IllegalArgumentException) {} catch (_: java.net.URISyntaxException) {}
        }
    }
    @Test fun invitationRequiresCompleteUnexpiredIdentity() {
        val base = org.json.JSONObject().put("version", 1).put("endpoint", "https://192.168.1.3:38221").put("pin", java.util.Base64.getEncoder().encodeToString(ByteArray(32)))
            .put("companionId", "00000000-0000-0000-0000-000000000000").put("nonce", "a".repeat(43)).put("expiresAt", 2000L)
        assertEquals(2000L, PairingInvitation.parse(base.toString(), 1000L).expiresAt)
        try { PairingInvitation.parse(base.toString(), 2001L); fail("Expired pairing accepted") } catch (_: IllegalArgumentException) {}
        base.put("pin", "short")
        try { PairingInvitation.parse(base.toString(), 1000L); fail("Malformed pin accepted") } catch (_: IllegalArgumentException) {}
    }
}
