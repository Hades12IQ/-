package com.firas.ai.ui

import org.junit.Assert.*
import org.junit.Test

class SpeechChunksTest {
    @Test fun longArabicAndEnglishKeepTheirEndingWithinTheServerLimit() {
        val text = ("معادلة واضحة. A complete sentence! ".repeat(140) + "FINAL-SENTENCE-9427")
        val chunks = speechChunks(text)
        assertTrue(chunks.size > 2)
        assertTrue(chunks.all { it.isNotBlank() && it.length <= 1200 })
        assertEquals(text.filterNot(Char::isWhitespace), chunks.joinToString("").filterNot(Char::isWhitespace))
        assertTrue(chunks.last().endsWith("FINAL-SENTENCE-9427"))
    }

    @Test fun aLongWordCannotSplitAnEmojiSurrogatePair() {
        val text = "a".repeat(1199) + "😀" + "b".repeat(1400)
        val chunks = speechChunks(text)
        assertEquals(text, chunks.joinToString(""))
        assertTrue(chunks.all { it.length <= 1200 })
        assertTrue(chunks.none { Character.isHighSurrogate(it.last()) || Character.isLowSurrogate(it.first()) })
    }

    @Test fun codeIsNotReadAsNarrationAndEmptyProseDoesNotCallTts() {
        assertEquals("Answer. Done.", speechChunks("Answer. ```kotlin\nval secret = 1\n``` Done.").single().replace(Regex("\\s+"), " "))
        assertTrue(speechChunks("   ").isEmpty())
    }
}
