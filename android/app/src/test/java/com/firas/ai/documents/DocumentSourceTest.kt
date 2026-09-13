package com.firas.ai.documents

import org.junit.Assert.*
import org.junit.Test

class DocumentSourceTest {
    private val html="<!doctype html><html lang=\"en\"><head><style>body{font-size:16pt}</style></head><body><p>Real document content</p></body></html>"
    private fun envelope(source:String=html,newline:String="\n")="```firas-file${newline}{\"filename\":\"test.pdf\",\"title\":\"Test\"}${newline}```${newline}${source}"
    @Test fun metadataAndBareHtmlAreCompleteWithoutLeakingSource() {
        for(nl in listOf("\n","\r\n")){
            val content=envelope(newline=nl);val doc=AuthoredDocument.extract(content)!!
            assertEquals(html,doc.sourceHtml);assertEquals("test.pdf",doc.filename);assertEquals("",AuthoredDocument.visibleMessage(content))
        }
        assertNull(AuthoredDocument.extract("An example follows: $html"))
        assertNull(AuthoredDocument.extract("```firas-file\n{\"filename\":\"test.pdf\"}\n```"))
    }
    @Test fun unfinishedDesignStaysHiddenAndCannotBecomeReady() {
        val content="```firas-file\n{\"filename\":\"test.pdf\"}\n```\n```html\n<html><body><p>Incomplete"
        assertTrue(AuthoredDocument.hasIncomplete(content));assertNull(AuthoredDocument.extract(content));assertEquals("",AuthoredDocument.visibleMessage(content))
        assertFalse(DocumentCompletion.validate(content,"Create 100 integrals and solutions").isComplete)
        assertEquals("Normal ``` words",AuthoredDocument.visibleMessage("Normal ``` words"))
    }
    @Test fun matchedFenceLengthAndCrlfPreserveSource() {
        val content="~~~~html\r\n$html\r\n~~~\r\n~~~~"
        val doc=AuthoredDocument.extract(content)!!
        assertTrue(doc.sourceHtml.startsWith(html));assertTrue(doc.sourceHtml.contains("~~~"))
    }
    @Test fun quantitiesAreNotPagesOrGroupingCounts() {
        val req="اصنعلي ملف pdf بي ١٠٠ تكامل صعب كل 3 تكاملات ب3 اسطر واريد حلول التكاملات بالنهاية"
        assertEquals(100,DocumentItemRequest.parse(req)?.count);assertTrue(DocumentItemRequest.parse(req)!!.solutions)
        assertEquals(1000,DocumentItemRequest.parse("1000 extremely difficult integrals and all solutions at the end")?.count)
        assertNull(DocumentItemRequest.parse("Write a 100 page PDF with every 3 integrals on three lines"))
        assertNull(DocumentItemRequest.parse("20 questions and 30 problems"))
        assertFalse(DocumentItemRequest.parse("100 questions without solutions")!!.solutions)
    }
    private fun collection(count:Int,solutions:Boolean=true):String = "<!doctype html><html><body>"+(1..count).joinToString(""){"<article data-firas-item=\"$it\"><b>Problem #$it</b><p>Evaluate x^${it+1}.</p></article>"}+if(solutions)(1..count).joinToString(""){"<article data-firas-solution=\"$it\"><p>x^${it+2}/${it+2} + C.</p></article>"}+"</body></html>" else "</body></html>"
    @Test fun sourceCountSolutionsOrderAndDuplicatesGateReadiness() {
        val req="100 integrals with solutions at the end";val complete=collection(100)
        assertTrue(DocumentCompletion.validate(envelope(complete),req).isVerified)
        assertFalse(DocumentCompletion.validate(envelope(collection(99)),req).isComplete)
        assertFalse(DocumentCompletion.validate(envelope(collection(100,false)),req).isComplete)
        assertFalse(DocumentCompletion.validate(envelope(complete.replace("data-firas-item=\"2\"","data-firas-item=\"1\"")),req).isComplete)
        assertFalse(DocumentCompletion.validate(envelope(complete.replace("Evaluate x^3.","Evaluate x^2.")),req).isComplete)
        val legacy=DocumentCompletion.validate(html,req);assertTrue(legacy.isComplete);assertFalse(legacy.isVerified)
    }
    @Test fun revisionKeepsFullPriorSourceAndPromptHasExactCount() {
        val revision=DocumentPrompts.revision(html,"Remove only the heading")
        assertTrue(revision.contains(html));assertTrue(revision.contains("Preserve every unaffected"))
        val prompt=DocumentPrompts.system("1000 integrals with solutions")
        assertTrue(prompt.contains("exactly 1000"));assertTrue(prompt.contains("data-firas-solution"));assertTrue(prompt.contains("\\ce{}"))
    }
}
