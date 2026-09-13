package com.firas.ai.data

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DataReliabilityTest {
    @Test fun browserProofUsesTheServerChallengeAndNeverPutsVerifierInBrowserUrl() {
        val verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", BrowserSignInProof.challenge(verifier))
        val id = "A".repeat(43)
        assertTrue(BrowserSignInProof.allowedBrowserUrl("https://firasai.org/desktop-auth?id=$id", "https://firasai.org/", id))
        assertFalse(BrowserSignInProof.allowedBrowserUrl("https://firasai.org.evil.invalid/desktop-auth?id=$id", "https://firasai.org/", id))
        assertFalse(BrowserSignInProof.allowedBrowserUrl("https://firasai.org/desktop-auth?id=$id&verifier=$verifier", "https://firasai.org/", id))
        assertFalse(BrowserSignInProof.allowedBrowserUrl("https://user@firasai.org/desktop-auth?id=$id", "https://firasai.org/", id))
        assertFalse(BrowserSignInProof.allowedBrowserUrl("http://firasai.org/desktop-auth?id=$id", "https://firasai.org/", id))
        val generated = List(64) { BrowserSignInProof.verifier() }
        assertEquals(64, generated.toSet().size)
        assertTrue(generated.all { it.matches(Regex("[A-Za-z0-9_-]{43}")) })
    }
    @Test fun staleCompletionCannotLandAfterSignOutOrReauthenticationToTheSameAccount() {
        assertTrue(JobPolicy.acceptsOwner("memberA", 4, "memberA", 4))
        assertFalse(JobPolicy.acceptsOwner("memberA", 4, "memberB", 5))
        assertFalse(JobPolicy.acceptsOwner("memberA", 4, null, 5))
        assertFalse(JobPolicy.acceptsOwner("memberA", 4, "memberA", 6))
    }
    @Test fun repeatedJobSnapshotsReplaceInsteadOfDuplicatingTokens() {
        var current = ""
        for (snapshot in listOf("a", "ab", "ab", "abc", "abc")) current = JobPolicy.snapshot(current, snapshot, false)
        assertEquals("abc", current)
        assertEquals("abc", JobPolicy.snapshot(current, null, false))
        assertEquals("", JobPolicy.snapshot(current, "", true)) // An empty terminal result must not bless partial output.
        assertEquals(JobPhase.COMPLETE, JobPolicy.phase("completed"))
        assertEquals(JobPhase.RUNNING, JobPolicy.phase("run"))
        assertEquals(JobPhase.UNKNOWN, JobPolicy.phase("unrecognized-future-state"))
    }
    @Test fun queueBudgetUsesBytesAndTemporaryNeverCreatesADurablePointer() {
        val ascii = "a".repeat(550_000)
        assertTrue(JobPolicy.canQueue(ascii.toByteArray().size, false))
        assertFalse(JobPolicy.canQueue((ascii + "a").toByteArray().size, false))
        assertFalse(JobPolicy.canQueue("ع".repeat(300_000).toByteArray().size, false))
        assertFalse(JobPolicy.canQueue(10, true))
    }
    @Test fun notificationIdentityAndRealCancelAreOwnerScoped() {
        assertNotEquals(JobPolicy.notificationKey("memberA", "sameJob"), JobPolicy.notificationKey("memberB", "sameJob"))
        val image = JobState("i", "a", "c", "t", "image", Product.AI, "Image")
        assertFalse(image.canCancel)
        assertTrue(image.copy(kind = "chat", transportKind = "chat").canCancel)
        assertFalse(image.copy(kind = "chat", transportKind = "chat", phase = JobPhase.COMPLETE).canCancel)
        assertTrue(isMediaPreparation(image.copy(transportKind = "chat", mediaRequest = "{\"stage\":\"preparation\"}")))
    }
    @Test fun completeHiddenDocumentAndSelectedVersionSurviveActualWireRoundTrip() {
        val source = "```firas-file\n{\"filename\":\"مسائل.pdf\"}\n```\n```html\n<!doctype html><html><body>" +
            (1..1000).joinToString("") { "<section data-firas-item=\"$it\">السؤال $it ∫ x^$it dx</section>" } + "</body></html>\n```"
        val revised = source.replace("السؤال 1 ∫", "المسألة 1 ∫")
        val original = ChatMessage("assistant-c1", "assistant", source, "c1", versions = listOf(AnswerVersion(revised)), selectedVersion = 0)
        val restored = Wire.message(Wire.message(original, true))
        assertEquals(source, restored.content)
        assertEquals(revised, restored.visibleContent)
        assertFalse(Wire.message(original).has("localStatus"))
        val user = Wire.message(JSONObject("{\"role\":\"user\",\"cid\":\"c1\",\"content\":\"request\"}"))
        val assistant = Wire.message(JSONObject("{\"role\":\"assistant\",\"cid\":\"c1\",\"content\":\"answer\"}"))
        assertNotEquals(user.id, assistant.id)
    }
    @Test fun translationChunksPreserveEveryArabicNewlineAndEmoji() {
        val source = ("عربي English 🧑🏽‍💻 🧪\n".repeat(800)) + "آخر كلمة"
        val chunks = TranslationChunks.split(source, 97)
        assertEquals(source, chunks.joinToString(""))
        assertTrue(chunks.all { it.length <= 97 && !Character.isHighSurrogate(it.last()) && !Character.isLowSurrogate(it.first()) })
    }
    @Test fun clearMediaIntentsRouteWhileDocumentsNegationAndLyricsStayText() {
        for (text in listOf("اصنعلي اغنية حزينة", "create a sad song", "crée une chanson triste", "crea una canción triste", "erstelle ein Lied", "bir şarkı oluştur", "دروست بكه گۆراني")) assertEquals(text, MediaKind.MUSIC, IntentPolicy.media(text))
        for (text in listOf("ارسم صورة قطة", "create an image of a cat", "生成一张图片")) assertEquals(text, MediaKind.IMAGE, IntentPolicy.media(text))
        assertEquals(MediaKind.VIDEO, IntentPolicy.media("سوي فيديو قصير"))
        for (text in listOf("لا تصنع صورة", "translate this song", "explain how to create an image", "اكتب كلمات اغنية", "create a python script to make a video", "صمملي ملف عن الرياضيات وبيه صور", "create a booklet with photos")) assertNull(text, IntentPolicy.media(text))
        assertEquals("pdf", IntentPolicy.documentFormat("صمملي ملف عن الرياضيات وبيه صور"))
        assertTrue(IntentPolicy.wantsDocumentRevision("الخط صغير بالملف، كبره"))
        assertFalse(IntentPolicy.wantsDocumentRevision("ليش الخط صغير بالملف؟"))
    }
    @Test fun unicodeMediaWordsRequireWholeTokensOnEveryRuntime() {
        assertEquals(MediaKind.MUSIC, IntentPolicy.media("bir şarkı oluştur"))
        assertEquals(MediaKind.MUSIC, IntentPolicy.media("üret bir müzik"))
        assertEquals(MediaKind.IMAGE, IntentPolicy.media("çiz bir resim"))
        for (text in listOf("create şarkıcı", "create musicé", "écreate a song", "create _song", "create song2")) {
            assertNull(text, IntentPolicy.media(text))
        }
    }
}
