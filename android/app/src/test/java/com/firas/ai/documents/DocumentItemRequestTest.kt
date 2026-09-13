package com.firas.ai.documents

import com.firas.ai.data.DocumentJobPolicy
import com.firas.ai.data.Product
import org.junit.Assert.*
import org.junit.Test

class DocumentItemRequestTest {
    @Test fun exactLiveThreeIntegralRequestUsesCountedJobWithoutSmallCountCutoff() {
        val request = "Create a PDF with exactly 3 distinct simple integrals and their solutions at the end."
        val parsed = DocumentItemRequest.parse(request)!!
        assertEquals(3, parsed.count)
        assertTrue(parsed.solutions)
        assertEquals(3, DocumentJobPolicy.resolve(request, Product.AI, emptyList())?.count)
    }
    @Test fun thousandHardNonRepeatingIntegralsKeepTotalAndIgnoreRowGrouping() {
        for (request in listOf(
            "Create a PDF with 1000 very hard non-repeating integrals, 3 per row",
            "Create a PDF with 1,000 extremely difficult non‑repeating integrals, every 3 integrals on one line",
            "Create a PDF with 1000 distinct complex integrals and 3 integrals per row",
            "Create a PDF with 10 JEE like level D integrals, without repeating"
        )) assertEquals(if (request.contains("10 JEE")) 10 else 1000, DocumentItemRequest.parse(request)?.count)
    }
    @Test fun boundedArabicAndPersianDescriptorsAndDigitsAreRecognized() {
        assertEquals(1000, DocumentItemRequest.parse("اصنع PDF بي ١٠٠٠ غير مكررة معادلة")?.count)
        assertEquals(100, DocumentItemRequest.parse("اريد ١٠٠ صعبة جداً تكاملات")?.count)
        assertEquals(1000, DocumentItemRequest.parse("۱۰۰۰ خیلی سخت انتگرال")?.count)
        assertEquals(1000, DocumentItemRequest.parse("PDF بي ١٬٠٠٠ مختلفة معادلة و 3 معادلات بكل سطر")?.count)
    }
    @Test fun pageDimensionsYearsAndPerRowQuantitiesNeverBecomeItemTargets() {
        for (request in listOf(
            "Create a 100 page PDF about integrals, A4 paper, year 2026",
            "Use A4 paper and 100 pages, 3 simple integrals per page",
            "Create a PDF with every 3 distinct simple integrals on three lines",
            "Create a PDF with 3 simple integrals on each row",
            "اصنع 100 صفحة و 3 معادلات بكل سطر",
            "Review year 2026 advanced equations",
            "100 pages describing hard integrals",
            "3.5 integrals",
            "100–1000 integrals",
            "20 questions and 30 problems"
        )) assertNull(request, DocumentItemRequest.parse(request))
    }
    @Test fun descriptorsDoNotCrossParagraphsOrConsumeUnboundedProse() {
        assertNull(DocumentItemRequest.parse("100\npages explain\nsimple integrals"))
        assertNull(DocumentItemRequest.parse("100 requests about interesting work containing difficult integrals"))
        assertNull(DocumentItemRequest.parse("100 very very very very very very very very very hard integrals"))
        assertFalse(DocumentItemRequest.parse("100 simple questions without solutions")!!.solutions)
        assertEquals(1, DocumentItemRequest.parse("1 simple equation")?.count)
    }
}
