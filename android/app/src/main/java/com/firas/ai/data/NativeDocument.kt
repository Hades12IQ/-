package com.firas.ai.data

import org.json.JSONObject

data class NativeDocument(
    val artifactId: String, val filename: String, val title: String, val sha256: String,
    val pdfBytes: Long, val pageCount: Int, val expectedItems: Int = 0,
    val requiresSolutions: Boolean = false, val solutionsAtEnd: Boolean = false,
    val partial: Boolean = false, val completedItems: Int = 0, val remainingItems: Int = 0,
    val resumeJobId: String? = null, val counted: Boolean = false,
) {
    fun metadata() = jsonOf("format" to "pdf", "serverPdf" to true, "artifactId" to artifactId, "filename" to filename, "title" to title,
        "sha256" to sha256, "pdfBytes" to pdfBytes, "pageCount" to pageCount, "expectedItems" to expectedItems,
        "requiresSolutions" to requiresSolutions, "solutionsAtEnd" to solutionsAtEnd, "counteddoc" to true.takeIf { counted || expectedItems > 0 },
        "partial" to partial.takeIf { it }, "completedItems" to completedItems.takeIf { partial },
        "remainingItems" to remainingItems.takeIf { partial }, "resumeJobId" to resumeJobId)
    companion object {
        private val fence = Regex("(?ms)^\\s*```firas-file\\s*\\r?\\n(.*?)\\r?\\n\\s*```")
        fun parse(content: String): NativeDocument? {
            val json = fence.find(content)?.groupValues?.get(1)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return null
            return fromMetadata(json)
        }
        fun fromMetadata(value: JSONObject): NativeDocument? {
            if (!value.optBoolean("serverPdf")) return null
            val id = value.stringOrNull("artifactId")?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,160}")) } ?: return null
            val hash = value.stringOrNull("sha256")?.lowercase()?.takeIf { it.matches(Regex("[a-f0-9]{64}")) } ?: return null
            val bytes = value.optLong("pdfBytes")
            val pages = value.optInt("pageCount")
            if (bytes !in 1..268_435_456L || pages !in 1..100_000) return null
            val expected = value.optInt("expectedItems")
            val partial = value.optBoolean("partial")
            val completed = value.optInt("completedItems")
            val remaining = value.optInt("remainingItems")
            val resume = value.stringOrNull("resumeJobId")?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,160}")) }
            if (expected !in 0..10_000 || partial && (expected < 1 || completed !in 1 until expected || remaining != expected - completed || resume == null)) return null
            return NativeDocument(id, value.optString("filename", "document.pdf"), value.optString("title", "Document"), hash, bytes, pages,
                expected, value.optBoolean("requiresSolutions"), value.optBoolean("solutionsAtEnd"), partial, completed, remaining, resume, value.optBoolean("counteddoc"))
        }
        fun addToSource(content: String, artifact: NativeDocument): String {
            val match = fence.find(content)
            return if (match == null) "```firas-file\n${artifact.metadata()}\n```\n$content" else content.replaceRange(match.range, "```firas-file\n${artifact.metadata()}\n```")
        }
    }
}

val ChatMessage.nativeArtifact: NativeDocument? get() = NativeDocument.parse(visibleContent)

internal data class NativeDocumentSource(val html: String, val assets: List<Attachment>)
