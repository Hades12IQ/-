package com.firas.ai.documents

import org.json.JSONObject

/** Authored source is the editable original. A card filename alone is never a complete artifact. */
data class AuthoredDocument(val sourceHtml: String, val filename: String, val title: String) {
    companion object {
        private data class Fence(val label: String, val start: Int, val end: Int, val source: String, val closed: Boolean)
        private fun fences(value: String): List<Fence> {
            val lines = Regex("(?m)^.*(?:\\r?\\n|$)").findAll(value).filter { it.value.isNotEmpty() }
            val result = mutableListOf<Fence>()
            var start = -1; var bodyStart = 0; var marker = '`'; var length = 0; var label = ""
            for (line in lines) {
                val text = line.value.trim()
                val candidate = text.firstOrNull()
                val run = if (candidate == '`' || candidate == '~') text.takeWhile { it == candidate }.length else 0
                if (start < 0 && run >= 3) { start = line.range.first; bodyStart = line.range.last + 1; marker = candidate!!; length = run; label = text.drop(run).trim().lowercase() }
                else if (start >= 0 && candidate == marker && run >= length && text.drop(run).isBlank()) {
                    result += Fence(label, start, line.range.last + 1, value.substring(bodyStart, line.range.first), true); start = -1
                }
            }
            if (start >= 0) result += Fence(label, start, value.length, value.substring(bodyStart), false)
            return result
        }
        private fun complete(source: String, fenceClosed: Boolean): Boolean {
            val lower = source.trim().lowercase()
            if (lower.isEmpty()) return false
            return if ("<html" in lower || "<!doctype" in lower) "</html>" in lower && ("<body" !in lower || "</body>" in lower) else fenceClosed
        }
        private fun bareRange(value: String, fences: List<Fence>): IntRange? {
            val start = value.indexOfFirst { !it.isWhitespace() }; if (start < 0) return null
            fun documentAt(index: Int): IntRange? {
                val at = value.indexOfFirstFrom(index) { !it.isWhitespace() }
                if (at < 0) return null
                val head = value.substring(at, minOf(value.length, at + 40)).lowercase()
                return if (head.startsWith("<!doctype html") || head.startsWith("<html")) at until value.length else null
            }
            documentAt(start)?.let { return it }
            val first = fences.firstOrNull { it.start == start && it.label == "firas-file" && it.closed } ?: return null
            if (runCatching { JSONObject(first.source) }.isFailure) return null
            return documentAt(first.end)
        }
        fun extract(content: String): AuthoredDocument? {
            val blocks = fences(content)
            val html = blocks.firstOrNull { it.label in setOf("html", "html5") }
            val source = if (html != null) html.source.takeIf { complete(it, html.closed) } else bareRange(content, blocks)?.let { content.substring(it) }?.takeIf { complete(it, false) }
            source ?: return null
            val metadata = blocks.firstOrNull { it.label == "firas-file" && it.closed }?.let { runCatching { JSONObject(it.source) }.getOrNull() }
            val filename = metadata?.optString("filename")?.takeIf { it.isNotBlank() } ?: metadata?.optString("name")?.takeIf { it.isNotBlank() } ?: "Firas-document.pdf"
            val title = metadata?.optString("title")?.takeIf { it.isNotBlank() } ?: filename.substringBeforeLast('.')
            return AuthoredDocument(source, filename, title)
        }
        fun hasIncomplete(content: String): Boolean {
            val blocks = fences(content)
            blocks.firstOrNull { it.label in setOf("html", "html5") }?.let { return !complete(it.source, it.closed) }
            return bareRange(content, blocks)?.let { !complete(content.substring(it), false) } ?: false
        }
        fun visibleMessage(content: String): String {
            val blocks = fences(content)
            val hidden = blocks.filter { it.label in setOf("html", "html5", "firas-file", "firas-image", "firas-video", "firas-song", "firas-music", "firas-agent", "firas-computer") }.map { it.start until it.end }.toMutableList()
            bareRange(content, blocks)?.let { hidden += it }
            if (hidden.isEmpty()) return content
            val out = StringBuilder(); var cursor = 0
            for (range in hidden.sortedBy { it.first }) {
                if (range.first > cursor) out.append(content.substring(cursor, range.first))
                cursor = maxOf(cursor, range.last + 1)
            }
            if (cursor < content.length) out.append(content.substring(cursor))
            return out.toString().trim()
        }
        private inline fun String.indexOfFirstFrom(from: Int, predicate: (Char) -> Boolean): Int { for (i in from until length) if (predicate(this[i])) return i; return -1 }
    }
}
