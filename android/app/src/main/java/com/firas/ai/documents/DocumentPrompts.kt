package com.firas.ai.documents

object DocumentPrompts {
    fun system(request: String): String = buildString {
        append("""
            Mathematics: write every inline mathematical expression between ${'$'}...${'$'} or \(...\), and display derivations between ${'$'}${'$'}...${'$'}${'$'}. Keep prose outside delimiters, use \text{} for words inside math, and explicit \ce{} / \pu{} for chemistry and units. Finish each expression before prose; do not put equations in code fences. The client renders local KaTeX with mhchem. Do not explain the rendering implementation to the user.

            When asked to create a PDF, deliver the actual complete authored document, not a promise, download URL, fabricated artifact ID, or empty metadata. Write one firas-file JSON fence with filename ending .pdf and title, immediately followed by one html fence containing a full <!doctype html><html><head><style>...</style></head><body>...</body></html>. The application hides this source and exports a native paginated PDF. Complete all requested content before closing the document. Do not use external libraries/scripts, templates, remote fonts, or JavaScript to create content; put real semantic content in HTML. KaTeX, chemistry support and multilingual fonts are supplied locally. Use quoted firas-asset://ID image references only for real supplied assets. Never invent an image URL or claim an image is included when it is absent.

            Design specifically for the user's purpose, language, paper, typography and requested visual direction. Use clear hierarchy, readable body text (12–14pt by default, larger if requested), generous physical margins and genuine flowing pages. Avoid an unsolicited oversized cover, ornamental gold borders, invented dates or copyright. More content or larger text means more pages, not tiny type or cropped overflow. Set @page size and margins where relevant, use width:100% and box-sizing:border-box; never fixed page heights or overflow:hidden on content. Keep an equation and its item label together using break-inside:avoid, allow long sections to flow, and use semantic tables with thead for real data. For every three integrals on three lines, create three vertical rows, not three narrow columns. Preserve all requested images, math, sections, numbering, solutions and ordering.

            For Word, slides and spreadsheets, follow the destination's supported native file contract rather than sending an HTML page as that format. Structure Word with semantic headings and coherent page flow; slides with readable content per slide and consistent alignment; spreadsheets with meaningful column types, usable widths, correct formulas and headers. Never claim a format was generated unless its actual source/artifact accompanies the response.
        """.trimIndent())
        DocumentItemRequest.parse(request)?.let { item ->
            append("\n\nThis document requires exactly ${item.count} distinct numbered ${item.noun}. Put data-firas-item=\"N\" on each complete item container, N=1 through ${item.count}, in reading order. Do not put this marker on labels without their actual problem. Include the full nonempty problem in each container, no placeholders or ellipses.")
            if (item.solutions) append(" After all items, provide the full matching numbered solutions in a final section, data-firas-solution=\"N\" on each complete solution container, in the same 1 through ${item.count} order. A title or filename saying ${item.count} is not completion. Verify exact count, no missing IDs, no repeated statements and every requested solution before closing the HTML.")
        }
    }
    fun revision(sourceHtml: String, request: String): String {
        require(sourceHtml.toByteArray().size <= 300_000) { "The original document is too large to revise without truncation." }
        require(AuthoredDocument.extract(sourceHtml) != null) { "The complete original source is required to revise this document." }
        return "Revise this SAME document according to the user's request. Preserve every unaffected paragraph, formula, layout decision, asset ID and sequence; do not rebuild a different document or omit content. Screenshots are edit references unless the user explicitly asks to insert them. Return the complete revised source using the PDF contract.\nUser request:\n$request\n<original-document-source>\n$sourceHtml\n</original-document-source>"
    }
}

data class DocumentItemRequest(val count: Int, val noun: String, val solutions: Boolean) {
    companion object {
        fun parse(request: String): DocumentItemRequest? {
            val text = java.text.Normalizer.normalize(request, java.text.Normalizer.Form.NFKC)
                .map { c -> when (c) { in '٠'..'٩' -> '0' + (c - '٠'); in '۰'..'۹' -> '0' + (c - '۰'); else -> c } }.joinToString("").lowercase(java.util.Locale.ROOT)
                .replace(Regex("[أإآٱ]"), "ا").replace('ة', 'ه').replace(Regex("[\\u064B-\\u065F\\u0670ـ]"), "")
            val nouns = "integrals?|problems?|questions?|exercises?|equations?|تكامل(?:ات)?|مسائل|مساله|اسئله|سؤال|تمارين|تمرين|معادلات|معادله|انتگرال(?:ها)?|مسئله|تمرین(?:ها)?"
            // Only known descriptors may sit between a quantity and an item noun. Never bridge
            // arbitrary prose (e.g. '100 pages about integrals') or cross into another line.
            val descriptor = "very|extremely|really|highly|hard|difficult|challenging|advanced|distinct|unique|different|original|novel|numbered|simple|easy|basic|complex|tricky|tough|math|mathematical|definite|indefinite|improper|solved|unsolved|worked|practice|" +
                "non[-‐‑– \\t]?(?:repeating|repeated|duplicate)|jee(?:[- \\t]like)?|(?:level|grade)[ \\t]+[a-z](?:\\+)?|" +
                "جدا|للغايه|صعب(?:ه)?|سهله?|بسيط(?:ه)?|معقد(?:ه)?|متقدم(?:ه)?|مختلف(?:ه)?|مميز(?:ه)?|فريد(?:ه)?|جديد(?:ه)?|رياضي(?:ه)?|" +
                "غير[ \\t]+(?:مكرر(?:ه)?|متكرر(?:ه)?)|خیلی|بسیار|سخت|ساده|متفاوت|پیشرفته|بدون[ \\t]+تکرار"
            val modifiers = "(?:(?:$descriptor)[ \\t]+){0,8}"
            val quantity = "(?:[0-9]{1,3}(?:[,٬][0-9]{3})+|[0-9]{1,5})"
            fun number(value: String) = value.replace(",", "").replace("٬", "").toIntOrNull()
            val candidates = Regex("(?<![\\p{L}\\p{N}.,٬])($quantity)[ \\t-]*$modifiers($nouns)(?![\\p{L}\\p{N}])", RegexOption.IGNORE_CASE).findAll(text)
                .filter { m ->
                    val before = text.substring(maxOf(0, m.range.first - 64), m.range.first)
                    val after = text.substring(m.range.last + 1, minOf(text.length, m.range.last + 81))
                    val groupedBefore = Regex("(?:\\b(?:every|each|per|groups?[ \\t]+of|sets?[ \\t]+of|year)|كل|بكل|لكل|سنه|عام)[ \\t]*$").containsMatchIn(before)
                    val groupedAfter = Regex("^[ \\t]*(?:(?:per|on|in)[ \\t]+(?:(?:each|every|one|a)[ \\t]+)?(?:row|line|page|group)|(?:في|بكل|لكل)[ \\t]*(?:كل[ \\t]*)?(?:سطر|صفحه|صف|مجموعه)|بالسطر|بالصفحه)(?![\\p{L}])").containsMatchIn(after)
                    val range = Regex("[0-9][ \\t]*(?:[-–—/]|to|or|الى|او)[ \\t]*$").containsMatchIn(before)
                    !groupedBefore && !groupedAfter && !range
                }
                .filter { number(it.groupValues[1]) in 1..10000 }.toList()
            val match = candidates.firstOrNull() ?: return null
            val count = number(match.groupValues[1])!!
            if (candidates.any { number(it.groupValues[1]) != count }) return null
            val noSolutions = Regex("\\b(?:without|no|omit|exclude)\\s+(?:(?:the|any|worked|full)\\s+)*(?:solutions?|answers?)\\b|(?:بدون|دون|بلا)\\s*(?:ال)?(?:حلول|حل|اجوب[ةه]|أجوب[ةه])").containsMatchIn(text)
            val solutions = Regex("solutions?|answers?|حلول|حلها|حلولها|اجوب|أجوب|حل(?:\\s|$)", RegexOption.IGNORE_CASE).containsMatchIn(text)
            return DocumentItemRequest(count, match.groupValues[2], solutions && !noSolutions)
        }
    }
}
