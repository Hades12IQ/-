package com.firas.ai.documents

object DocumentCompletion {
    data class Result(val isComplete: Boolean, val isVerified: Boolean, val itemCount: Int = 0, val solutionCount: Int = 0, val issue: String? = null) {
        val message: String get() = if (isComplete) "" else "المستند غير مكتمل بعد. أكمل إنشاء المحتوى ثم افتحه مجدداً. / The document is incomplete. Continue generation, then open it again."
    }
    private data class Record(val id: Int, val position: Int, val text: String)
    fun validate(content: String, request: String): Result {
        val doc = AuthoredDocument.extract(content) ?: return Result(false, false, issue = "source_missing_or_incomplete")
        val source = doc.sourceHtml
        val text = plain(source)
        if (text.isBlank() && !Regex("<(?:img|svg)\\b", RegexOption.IGNORE_CASE).containsMatchIn(source)) return Result(false, false, issue = "empty_source")
        val expected = DocumentItemRequest.parse(request) ?: return Result(true, false)
        val items = records(source, "item"); val answers = records(source, "solution")
        val marked = Regex("data-firas-(?:item|solution)\\s*=", RegexOption.IGNORE_CASE).containsMatchIn(source)
        // Older authored files may use CSS counters or TeX tags. Unknown numbering is exportable,
        // explicitly unverified; a metadata claim never enters this path as document content.
        if (!marked) return Result(true, false)
        val wanted = (1..expected.count).toList()
        fun result(issue: String?) = Result(issue == null, issue == null, items.size, answers.size, issue)
        if (items.map { it.id } != wanted) return result("item_count_order_or_duplicates")
        if (items.any { it.text.isBlank() }) return result("empty_item")
        val canonical = items.map { canonical(it.text) }
        if (canonical.toSet().size != canonical.size) return result("repeated_statement")
        if (expected.solutions) {
            if (answers.map { it.id } != wanted) return result("solution_count_order_or_duplicates")
            if (answers.any { it.text.isBlank() }) return result("empty_solution")
            if (answers.first().position < items.last().position) return result("solutions_before_items_complete")
        }
        return result(null)
    }
    private fun records(source: String, kind: String): List<Record> {
        val pattern = Regex("""<([a-z][a-z0-9]*)\b[^>]*\bdata-firas-$kind\s*=\s*["'](\d+)["'][^>]*>""", RegexOption.IGNORE_CASE)
        return pattern.findAll(source).map { match ->
            val from = match.range.last + 1
            val tag = match.groupValues[1]
            var depth = 1; var end = from
            val tags = Regex("</?$tag\\b[^>]*>", RegexOption.IGNORE_CASE).findAll(source, from)
            for (token in tags) { if (token.value.startsWith("</")) depth-- else if (!token.value.endsWith("/>")) depth++; if (depth == 0) { end = token.range.first; break } }
            Record(match.groupValues[2].toIntOrNull() ?: -1, match.range.first, plain(source.substring(from, end)))
        }.toList()
    }
    private fun plain(value: String) = value.replace(Regex("<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>", RegexOption.IGNORE_CASE), " ")
        .replace(Regex("<!--[\\s\\S]*?-->"), " ").replace(Regex("<[^>]*>"), " ")
        .replace("&nbsp;", " ").replace("&amp;", "&").replace(Regex("\\s+"), " ").trim()
    private fun canonical(value: String) = value.lowercase().replace(Regex("^(?:integral|problem|question|exercise|solution|تكامل|مسألة)?\\s*[-#№]?\\s*0*\\d+\\s*[.):-]?\\s*"), "").replace(Regex("\\s+"), "")
}
