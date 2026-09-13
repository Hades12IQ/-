package com.firas.ai.render

/** The single authority for math boundaries. Offsets use Android's UTF-16 text/selection convention.
 * Rendering may repair TeX, but [Span.raw] and the persisted response remain untouched. */
object MathScanner {
    data class Span(val start: Int, val end: Int, val raw: String, val tex: String, val display: Boolean, val recovered: Boolean = false) {
        val id: String get() = identifier(tex, display)
    }
    private data class Pending(val start: Int, val left: String, val right: String)
    private data class Scan(val spans: List<Span>, val pending: Pending?)
    val functions = setOf("sin", "cos", "tan", "cot", "sec", "csc", "ln", "log", "exp", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh")
    private const val greek = "αβγδεζηθικλμνξπρστυφχψωΓΔΘΛΞΠΣΥΦΨΩϑϕϵ"
    private const val scripts = "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁽⁾₀₁₂₃₄₅₆₇₈₉₊₋₍₎"
    private val textGroup = Regex("""\\(?:text|textrm|textbf|textit|mathrm|mbox|operatorname)\s*\{[^{}]*\}""")
    private val blankLine = Regex("\\r?\\n[ \\t]*\\r?\\n")
    private val pairs = listOf("$$" to "$$", "\\[" to "\\]", "\\(" to "\\)", "$" to "$")
    fun spans(text: String): List<Span> = scan(text).spans
    fun identifier(tex: String, display: Boolean): String {
        var hash = 0xcbf29ce484222325uL
        tex.toByteArray(Charsets.UTF_8).forEach { hash = (hash xor it.toUByte().toULong()) * 0x100000001b3uL }
        return (if (display) "d" else "i") + hash.toString(16)
    }
    private fun ascii(c: Char) = c in 'a'..'z' || c in 'A'..'Z'
    private fun arabic(s: String) = s.any { it.code in 0x0600..0x06ff || it.code in 0x0750..0x077f || it.code in 0xfb50..0xfdff || it.code in 0xfe70..0xfeff }
    private fun stripped(s: String): String { var out = s; repeat(6) { out = out.replace(textGroup, " ") }; return out }
    private fun bracket(body: String, display: Boolean) = body.isNotBlank() && !arabic(stripped(body)) && (display || (!blankLine.containsMatchIn(body) && body.count { it == '\n' } <= 2))
    private fun inline(body: String, after: Char?) = body.isNotBlank() && !body.first().isWhitespace() && !blankLine.containsMatchIn(body) && body.count { it == '\n' } <= 2 &&
        !(body.first() in '0'..'9' && after != null && after in '0'..'9') && !arabic(stripped(body)) &&
        !(body.split(Regex("\\s+")).size >= 4 && body.none { it in "\\^_{}=" })

    private fun scan(s: String): Scan {
        val out = mutableListOf<Span>()
        var i = 0
        var pending: Pending? = null
        var fence: Pair<Char, Int>? = null
        while (i < s.length) {
            if (i == 0 || s[i - 1] == '\n') {
                val end = s.indexOf('\n', i).let { if (it < 0) s.length else it }
                val line = s.substring(i, end).trimEnd('\r')
                val indent = line.takeWhile { it == ' ' || it == '\t' }.length
                val tail = line.drop(indent)
                val mark = tail.firstOrNull()
                if (indent < 4 && (mark == '`' || mark == '~')) {
                    val run = tail.takeWhile { it == mark }.length
                    if (run >= 3) {
                        if (fence == null) fence = mark!! to run
                        else if (fence.first == mark && run >= fence.second && tail.drop(run).isBlank()) fence = null
                        i = (end + 1).coerceAtMost(s.length); continue
                    }
                }
                if (fence != null) { i = (end + 1).coerceAtMost(s.length); continue }
            }
            val c = s[i]
            if (i > 0 && c == '(' && s[i - 1] == ']') {
                var depth = 1; i++
                while (i < s.length && s[i] != '\n' && depth > 0) {
                    if (s[i] == '\\') { i = (i + 2).coerceAtMost(s.length); continue }
                    if (s[i] == '(') depth++; if (s[i] == ')') depth--; i++
                }; continue
            }
            if (s.regionMatches(i, "https://", 0, 8, true) || s.regionMatches(i, "http://", 0, 7, true) || s.regionMatches(i, "www.", 0, 4, true)) {
                while (i < s.length && !s[i].isWhitespace() && s[i] !in ")>") i++
                continue
            }
            if (c == '`') {
                val n = s.substring(i).takeWhile { it == '`' }.length
                val end = s.indexOf("`".repeat(n), i + n)
                i = if (end >= 0) end + n else s.indexOf('\n', i + n).let { if (it < 0) s.length else it }
                continue
            }
            val pair = pairs.firstOrNull { s.startsWith(it.first, i) }
            if (pair != null) {
                val from = i + pair.first.length
                var j = from; var close = -1
                val limit = if (pair.first == "$" ) s.length else minOf(s.length, from + if (pair.first == "\\(") 900 else 4000)
                while (j < limit) {
                    if (pair.second.startsWith('$') && s[j] == '\\') { j += 2; continue }
                    if (s.startsWith(pair.second, j)) { close = j; break }; j++
                }
                val display = pair.first == "$$" || pair.first == "\\["
                if (close >= 0) {
                    val body = s.substring(from, close)
                    val end = close + pair.second.length
                    if (if (pair.first == "$") inline(body, s.getOrNull(end)) else bracket(body, display)) {
                        out += Span(i, end, s.substring(i, end), balanced(body).trim(), display); i = end; continue
                    }
                } else if (unfinished(s.substring(from), pair.first != "$")) {
                    pending = Pending(i, pair.first, pair.second); break
                }
                i += pair.first.length; continue
            }
            if (c == '\\') { i = (i + 2).coerceAtMost(s.length); continue }
            val recovered = recoveredEnd(s, i)
            if (recovered != null) {
                val raw = s.substring(i, recovered)
                out += Span(i, recovered, raw, MathText.recoveredTeX(raw), false, true); i = recovered; continue
            }
            i++
        }
        return Scan(out, pending)
    }

    private fun unfinished(raw: String, explicit: Boolean): Boolean {
        if (raw.isEmpty() || raw.length > 4000 || (!explicit && raw.first().isWhitespace()) || raw.any { it == '$' || it == '`' } || blankLine.containsMatchIn(raw)) return false
        var body = stripped(raw).trim()
        if (body.isEmpty() || arabic(body)) return false
        body = body.replace(Regex("""\\(?:ce|pu)\{[^{}]*(?:\}|$)"""), "x")
            .replace(Regex("""\\(?:begin|end)\{[a-zA-Z*]+\}"""), "")
            .replace(Regex("""\\[a-zA-Z]+"""), "x")
        if (Regex("[a-zA-Z]+").findAll(body).any { it.value.length > 2 && it.value !in functions }) return false
        return explicit || !raw.first().isDigit() || raw.any { it in "\\=+−-*/^_√" || it in greek }
    }

    /** A view-only synthetic tail. Never persist or submit this as source. */
    fun streamingPreview(source: String): String {
        val p = scan(source).pending ?: return source
        var body = source.substring(p.start + p.left.length).trim().trimEnd('^', '_').trimEnd()
        val command = Regex("""\\([a-zA-Z]*)$""").find(body)
        if (command != null && command.groupValues[1] !in completeCommands) body = body.substring(0, command.range.first).trimEnd()
        body = body.trimEnd('^', '_').trimEnd()
        if (body.isEmpty()) return source
        body = completeArguments(balanced(body))
        val environments = mutableListOf<String>()
        Regex("""\\(begin|end)\{([a-zA-Z*]+)\}""").findAll(body).forEach { m ->
            if (m.groupValues[1] == "begin") environments += m.groupValues[2]
            else if (environments.lastOrNull() == m.groupValues[2]) environments.removeAt(environments.lastIndex)
        }
        environments.asReversed().forEach { body += "\\end{$it}" }
        return if (isTypesettable(body)) source.substring(0, p.start) + p.left + body + p.right else source
    }
    private val arity = mapOf("frac" to 2,"dfrac" to 2,"tfrac" to 2,"binom" to 2,"sqrt" to 1,"text" to 1,"mathrm" to 1,"mathbf" to 1,"mathbb" to 1,"vec" to 1,"hat" to 1,"bar" to 1,"overline" to 1,"underline" to 1,"boxed" to 1,"ce" to 1,"pu" to 1)
    private val completeCommands = arity.keys + functions + ("int iint iiint oint sum prod lim infty partial nabla pi theta alpha beta gamma delta epsilon lambda mu sigma phi omega Delta Omega Gamma zeta eta iota kappa nu xi rho tau upsilon chi psi varepsilon vartheta varphi varrho varsigma hbar ell imath jmath Theta Lambda Xi Pi Sigma Upsilon Phi Psi quad qquad cdot times pm mp".split(' '))
    private fun completeArguments(s: String): String {
        val additions = mutableMapOf<Int, String>()
        Regex("""\\([a-zA-Z]+)""").findAll(s).forEach { m ->
            val count = arity[m.groupValues[1]] ?: return@forEach
            var cursor = m.range.last + 1
            for (remaining in count downTo 1) {
                while (cursor < s.length && s[cursor].isWhitespace()) cursor++
                if (cursor == s.length || s[cursor] == '}') {
                    additions[cursor] = (additions[cursor] ?: "") + "{}".repeat(remaining); break
                }
                if (s[cursor] == '{') { var depth = 1; cursor++; while (cursor < s.length && depth > 0) { if (s[cursor] == '{') depth++; if (s[cursor] == '}') depth--; cursor++ } }
                else if (s[cursor] == '\\') { cursor++; while (cursor < s.length && ascii(s[cursor])) cursor++ }
                else cursor++
            }
        }
        return buildString { for (i in 0..s.length) { append(additions[i] ?: ""); if (i < s.length) append(s[i]) } }
    }
    private fun balanced(s: String): String {
        var depth = 0
        return buildString {
            s.forEachIndexed { i, c ->
                if (c == '{' && (i == 0 || s[i - 1] != '\\')) { depth++; append(c) }
                else if (c == '}' && (i == 0 || s[i - 1] != '\\')) { if (depth > 0) { depth--; append(c) } }
                else append(c)
            }; append("}".repeat(depth))
        }
    }
    fun isTypesettable(tex: String): Boolean = tex.isNotBlank() && '$' !in tex && tex.takeLastWhile { it == '\\' }.length % 2 == 0 && balanced(tex) == tex

    private fun recoveredEnd(s: String, start: Int): Int? {
        fun letter(c: Char) = ascii(c) || c in greek
        if (start > 0 && (letter(s[start - 1]) || s[start - 1].isDigit() || s[start - 1] == '\\')) return null
        if (!(letter(s[start]) || s[start].isDigit() || s[start] in "−-√(")) return null
        var i = start; val groups = mutableListOf<Char>(); var relation = false; var hasGreek = false
        var function = false; var operation = false; var scripted = false; var needsAtom = true; var hasAtom = false; var best: Int? = null
        val limit = minOf(s.length, start + 900)
        while (i < limit) {
            val c = s[i]
            when {
                c == ' ' || c == '\t' -> { i++; continue }
                ascii(c) -> { var end = i + 1; while (end < limit && ascii(s[end])) end++; val word = s.substring(i, end)
                    if (word in functions) { function = true; needsAtom = true }
                    else if (word.length == 1 || word in setOf("dv","du","dx","dy","dz","dt","dr","ds","mc")) { hasAtom = true; needsAtom = false }
                    else break; i = end }
                c in '0'..'9' -> { i++; while (i < limit && s[i] in '0'..'9') i++; if (i + 1 < limit && s[i] == '.' && s[i + 1] in '0'..'9') { i++; while (i < limit && s[i] in '0'..'9') i++ }; hasAtom = true; needsAtom = false }
                c in greek -> { hasGreek = true; hasAtom = true; needsAtom = false; i++ }
                c in scripts && hasAtom && !needsAtom -> { scripted = true; i++ }
                c == '√' -> { function = true; needsAtom = true; i++ }
                c in "([{ " -> { groups += when (c) { '(' -> ')'; '[' -> ']'; else -> '}' }; needsAtom = true; i++ }
                c in ")]}" -> { if (groups.lastOrNull() != c || needsAtom) break; groups.removeAt(groups.lastIndex); needsAtom = false; i++ }
                c in "=⇒⇔≤≥≠≈" && hasAtom && !needsAtom -> { if (s.getOrNull(i + 1) in listOf('=', '>')) break; relation = true; needsAtom = true; i++ }
                c in "+−-*/×÷·^_" -> { if (!((hasAtom && !needsAtom) || c in "-−+")) break; operation = true; needsAtom = true; i++ }
                c in "′!" && hasAtom && !needsAtom -> { operation = true; i++ }
                else -> break
            }
            if (groups.isEmpty() && hasAtom && !needsAtom && (relation || function || scripted || (hasGreek && operation))) best = i
        }
        return best
    }
}
