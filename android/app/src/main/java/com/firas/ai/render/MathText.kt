package com.firas.ai.render

/** Only called after MathScanner accepted a recovered mathematical run. */
object MathText {
    private val greek = "αβγδεζηθικλμνξπρστυφχψωΓΔΘΛΞΠΣΥΦΨΩϑϕϵ".toList().zip("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi pi rho sigma tau upsilon phi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega vartheta varphi varepsilon".split(' ')).toMap()
    private val symbols = mapOf('⇒' to "\\Rightarrow ", '⇔' to "\\Leftrightarrow ", '≤' to "\\le ", '≥' to "\\ge ", '≠' to "\\ne ", '≈' to "\\approx ", '×' to "\\times ", '÷' to "\\div ", '·' to "\\cdot ", '−' to "-", '′' to "'")
    fun recoveredTeX(source: String): String {
        val upper = "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁽⁾"; val lower = "₀₁₂₃₄₅₆₇₈₉₊₋₍₎"; val normal = "0123456789+-()"
        var i = 0
        return buildString {
            while (i < source.length) {
                val c = source[i]
                when {
                    c in greek -> { append("\\${greek[c]} "); i++ }
                    c in symbols -> { append(symbols[c]); i++ }
                    c in upper || c in lower -> { val table = if (c in upper) upper else lower; append(if (c in upper) "^{" else "_{"); while (i < source.length && source[i] in table) append(normal[table.indexOf(source[i++])]); append('}') }
                    c == '√' -> {
                        var start = i + 1; while (start < source.length && source[start] == ' ') start++
                        var end = start
                        if (start < source.length && source[start] == '(') { var depth = 1; end++; while (end < source.length && depth > 0) { if (source[end] == '(') depth++; if (source[end] == ')') depth--; end++ }; if (depth == 0) { append("\\sqrt{${recoveredTeX(source.substring(start + 1, end - 1))}}"); i = end; continue } }
                        if (start < source.length) { end = start + 1; if (source[start].isDigit()) while (end < source.length && (source[end].isDigit() || source[end] == '.')) end++; append("\\sqrt{${recoveredTeX(source.substring(start, end))}}"); i = end } else { append(c); i++ }
                    }
                    c in 'a'..'z' || c in 'A'..'Z' -> { var end = i + 1; while (end < source.length && (source[end] in 'a'..'z' || source[end] in 'A'..'Z')) end++; val word = source.substring(i, end); append(if (word in MathScanner.functions) "\\$word " else word); i = end }
                    else -> { append(c); i++ }
                }
            }
        }.trim()
    }
}
