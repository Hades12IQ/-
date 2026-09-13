package com.firas.ai.render

import org.junit.Assert.*
import org.junit.Test

class MathScannerTest {
    @Test fun conservativelyRecoversUnicodeWithoutChangingSource() {
        val source = "dv = cotθ dθ ⇒ v = ln(sinθ)"
        val run = MathScanner.spans(source).single()
        assertEquals(source, run.raw); assertTrue(run.recovered)
        for (command in listOf("\\cot", "\\theta", "\\ln", "\\Rightarrow")) assertTrue(command, command in run.tex)
        val mixed = "بالتعويض: π/4 ln(sin(π/4)) = π/4 ln(1/(√2)) = -π/8\nln2. وهنا ننتهي."
        val runs = MathScanner.spans(mixed)
        assertEquals(2, runs.size); assertEquals("ln2", runs.last().raw); assertTrue("\\sqrt{2}" in runs.first().tex)
        runs.forEach { assertEquals(it.raw, mixed.substring(it.start, it.end)) }
    }
    @Test fun excludesProseCurrencyCodeAndUrls() {
        val values = listOf("Tea is ${'$'}5 and coffee is ${'$'}3.","USD 50; total 20/30.","The sin tax is a policy. Minimum and maximum are words.",
            "```swift\nlet x=2\n// E=mc²\n```", "```text\ndv = cotθ dθ", "`E=mc²`", "`x=2", "~~~tex\n${'$'}x=2${'$'}\n~~~",
            "https://example.test/search?x=2&math=sin2", "www.example.test/q?x=2", "HTTPS://example.test/q?x=2", "[Open](relative?x=2)", "ordinary English and العربية Ελληνικά")
        values.forEach { assertTrue(it, MathScanner.spans(it).isEmpty()) }
    }
    @Test fun streamingPreviewUsesSameAuthorityAndCompletesOnlyTail() {
        val values = listOf(
            "Result ${'$'}x^" to "Result ${'$'}x${'$'}",
            "Result ${'$'}x^\\fr" to "Result ${'$'}x${'$'}",
            "${'$'}${'$'}\\frac{" to "${'$'}${'$'}\\frac{}{}${'$'}${'$'}",
            "${'$'}${'$'}\\frac{1}{" to "${'$'}${'$'}\\frac{1}{}${'$'}${'$'}",
            "\\[\\int_0^{\\pi" to "\\[\\int_0^{\\pi}\\]",
            "\\(x + \\fr" to "\\(x +\\)",
            "${'$'}${'$'}\\sqrt" to "${'$'}${'$'}\\sqrt{}${'$'}${'$'}",
            "${'$'}\\ce{NaOH}" to "${'$'}\\ce{NaOH}${'$'}",
            "${'$'}\\ce{H2SO4" to "${'$'}\\ce{H2SO4}${'$'}",
            "\\(\\pu{2.5 mol/L}" to "\\(\\pu{2.5 mol/L}\\)",
            "${'$'}${'$'}\\begin{aligned}a&=1\\\\b&=2" to "${'$'}${'$'}\\begin{aligned}a&=1\\\\b&=2\\end{aligned}${'$'}${'$'}")
        values.forEach { (raw, expected) -> assertEquals(raw, expected, MathScanner.streamingPreview(raw)); assertEquals(raw,1,MathScanner.spans(expected).size) }
        for (source in listOf("The cost is ${'$'}5", "Pay ${'$'}50.00", "```tex\n${'$'}${'$'}\\frac{", "`${'$'}x^", "Arabic ${'$'}شرح عادي", "ordinary prose")) assertEquals(source,source,MathScanner.streamingPreview(source))
    }
    @Test fun completedAndProvisionalDuplicateIdsStayContentStable() {
        val source="${'$'}x${'$'} ثم ${'$'}y${'$'} ثم ${'$'}x"
        val preview=MathScanner.streamingPreview(source); val spans=MathScanner.spans(preview)
        assertEquals(3,spans.size);assertEquals(spans[0].id,spans[2].id);assertNotEquals(spans[0].id,spans[1].id)
        assertEquals("iaf63f54c86021707",MathScanner.identifier("x",false))
        val fraction="الحل ${'$'}z^{17}${'$'} ثم ${'$'}\\frac{47}{83}"
        assertEquals(2,MathScanner.spans(MathScanner.streamingPreview(fraction)).size)
    }
    @Test fun mathIsProtectedBeforeMarkdownAndCopyKeepsOriginalPreviewSource() {
        val source="**نتيجة** ${'$'}x_1^2${'$'} و [المصدر](firas-cite://doc/4)"
        val parsed=MarkdownText.parse(source)
        assertEquals("نتيجة ${'$'}x_1^2${'$'} و المصدر",parsed.text)
        assertEquals(1,parsed.math.size);assertTrue(parsed.styles.any{it.kind=="link"&&it.value=="firas-cite://doc/4"})
        val raw="الحل ${'$'}\\frac{47}{"
        val preview=MathScanner.streamingPreview(raw)
        val partial=MarkdownText.parse(preview,raw)
        assertEquals(raw,partial.text);assertEquals(1,partial.math.size)
    }
    @Test fun longDelimitedEquationIsNotSplitOrRejectedByWidth() {
        val source="${'$'}${'$'}\\frac{\\pi}{4}\\ln\\left(\\sin\\frac{\\pi}{4}\\right)=\\frac{\\pi}{4}\\ln\\frac{1}{\\sqrt2}=-\\frac{\\pi}{8}\\ln2${'$'}${'$'}"
        assertEquals(source,MathScanner.streamingPreview(source));assertEquals(1,MathScanner.spans(source).size)
        assertTrue(MathScanner.isTypesettable(MathScanner.spans(source).single().tex))
    }
}
