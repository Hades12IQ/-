package com.firas.ai.render

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.method.LinkMovementMethod
import android.text.style.*
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.widget.TextView
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.firas.ai.documents.AuthoredDocument
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.conflate

/** All visible text is an Android text surface: native word selection, accessibility and links.
 * A math glyph replaces its original source range rather than erasing that range for copying. */
@Composable
fun RichMessage(
    content: String,
    streaming: Boolean,
    modifier: Modifier = Modifier,
    ink: Color,
    accent: Color,
    background: Color,
    textSizeSp: Float = 17f,
    cacheScope: String = "",
    persistMath: Boolean = true,
    onAskSelection: (String) -> Unit,
    onLink: (String) -> Unit,
) {
    val context = LocalContext.current
    val visible = remember(content) { AuthoredDocument.visibleMessage(content) }
    val latestSource by rememberUpdatedState(visible)
    val latestStreaming by rememberUpdatedState(streaming)
    val latestPersistence by rememberUpdatedState(persistMath)
    val ask by rememberUpdatedState(onAskSelection)
    val link by rememberUpdatedState(onLink)
    val glyphs = remember(ink, textSizeSp, cacheScope) { mutableStateMapOf<String, MathGlyph>() }
    val preview = remember(visible, streaming) { if (streaming) MathScanner.streamingPreview(visible) else visible }
    val parsed = remember(preview, visible) { MarkdownText.parse(preview, visible) }
    // A new token does not cancel an in-flight successful formula. Conflation keeps only the latest
    // source while the serialized worker finishes the current batch; no additional model requests.
    LaunchedEffect(context, ink, textSizeSp, cacheScope) {
        snapshotFlow { Triple(latestSource, latestStreaming, latestPersistence) }.conflate().collect { (raw, live, allowed) ->
            val display = if (live) MathScanner.streamingPreview(raw) else raw
            try {
                MathRasterizer.render(context, MathScanner.spans(display), ink.toArgb(), textSizeSp, cacheScope, allowed && !live) { id, glyph -> glyphs[id] = glyph }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { /* A failed renderer leaves honest selectable source in place. */ }
        }
    }
    AndroidView(
        modifier = modifier,
        factory = { ctx -> SelectableMessageText(ctx).apply {
            setTextIsSelectable(true)
            setPadding(0, 0, 0, 0)
            includeFontPadding = false
            setLineSpacing(3 * resources.displayMetrics.density, 1.18f)
            textDirection = View.TEXT_DIRECTION_FIRST_STRONG
            setBackgroundColor(android.graphics.Color.TRANSPARENT)
            customSelectionActionModeCallback = object : ActionMode.Callback {
                override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean { addAsk(menu); return true }
                override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean { addAsk(menu); return false }
                private fun addAsk(menu: Menu) { if (menu.findItem(ASK_ID) == null) menu.add(Menu.NONE, ASK_ID, 90, "اسأل فراس · Ask Firas") }
                override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
                    if (item.itemId != ASK_ID) return false
                    val start = minOf(selectionStart, selectionEnd).coerceAtLeast(0)
                    val end = maxOf(selectionStart, selectionEnd).coerceAtMost(text.length)
                    if (end > start) ask(text.subSequence(start, end).toString())
                    mode.finish(); return true
                }
                override fun onDestroyActionMode(mode: ActionMode) = Unit
            }
        } },
        update = { view ->
            view.setTextColor(ink.toArgb()); view.setLinkTextColor(accent.toArgb()); view.textSize = textSizeSp
            view.render(parsed, glyphs.toMap(), accent.toArgb(), background.toArgb(), link)
        },
    )
}

private const val ASK_ID = 0x46697261

private class SelectableMessageText(context: android.content.Context) : TextView(context) {
    private var current: MarkdownText.Parsed? = null
    private var installed = emptyMap<String, MathGlyph>()
    private var attachedSpans = emptyList<GlyphSpan>()
    fun render(parsed: MarkdownText.Parsed, glyphs: Map<String, MathGlyph>, accent: Int, background: Int, onLink: (String) -> Unit) {
        if (current == parsed && installed == glyphs) return
        val built = SpannableStringBuilder(parsed.text)
        for (style in parsed.styles) {
            val span: Any = when (style.kind) {
                "bold" -> StyleSpan(android.graphics.Typeface.BOLD)
                "italic" -> StyleSpan(android.graphics.Typeface.ITALIC)
                "code" -> TypefaceSpan("monospace")
                "heading" -> RelativeSizeSpan(style.value.toFloatOrNull() ?: 1.2f)
                "quote" -> QuoteSpan(accent)
                "link" -> object : ClickableSpan() {
                    override fun onClick(widget: View) { onLink(style.value) }
                    override fun updateDrawState(ds: TextPaint) { ds.color = accent; ds.isUnderlineText = true }
                }
                else -> continue
            }
            if (style.end > style.start) built.setSpan(span, style.start, style.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val spans = mutableListOf<GlyphSpan>()
        for (math in parsed.math) {
            val glyph = glyphs[math.span.id] ?: continue
            val span = GlyphSpan(glyph) { (width - paddingLeft - paddingRight).coerceAtLeast(1) }
            built.setSpan(span, math.start, math.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (math.span.display) {
                val paragraphStart = built.lastIndexOf("\n", math.start - 1) + 1
                val nextBreak = built.indexOf("\n", math.end)
                val paragraphEnd = if (nextBreak < 0) built.length else nextBreak + 1
                built.setSpan(AlignmentSpan.Standard(android.text.Layout.Alignment.ALIGN_CENTER),
                    paragraphStart, paragraphEnd, Spanned.SPAN_PARAGRAPH)
            }
            spans += span
        }
        val start = selectionStart; val end = selectionEnd
        val sameText = text.toString() == built.toString()
        setText(built, BufferType.SPANNABLE)
        if (sameText && start >= 0 && end >= start && end <= length()) android.text.Selection.setSelection(text as Spannable, start, end)
        // TextView's selectable movement method also dispatches ClickableSpan links; replacing it
        // with LinkMovementMethod would remove drag/word selection on several Android releases.
        current = parsed; installed = glyphs; attachedSpans = spans
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w != oldw && attachedSpans.isNotEmpty()) { text = text; requestLayout() }
    }
}

private class GlyphSpan(private val glyph: MathGlyph, private val available: () -> Int) : ReplacementSpan() {
    private fun ratio() = minOf(1f, available().toFloat() / glyph.bitmap.width)
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        val scale = ratio(); val above = (glyph.baseline * scale).toInt(); val below = ((glyph.bitmap.height - glyph.baseline) * scale).toInt()
        fm?.apply { ascent = -above; top = ascent; descent = below; bottom = descent }
        return kotlin.math.ceil(glyph.bitmap.width * scale).toInt()
    }
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val scale = ratio(); val origin = y - glyph.baseline * scale
        val old = paint.isFilterBitmap; paint.isFilterBitmap = true
        canvas.drawBitmap(glyph.bitmap, null, RectF(x, origin, x + glyph.bitmap.width * scale, origin + glyph.bitmap.height * scale), paint)
        paint.isFilterBitmap = old
    }
}

/** Markdown syntax is removed only in the displayed value. Math is protected first by MathScanner. */
object MarkdownText {
    data class Style(val start: Int, val end: Int, val kind: String, val value: String = "")
    data class Math(val start: Int, val end: Int, val span: MathScanner.Span)
    data class Parsed(val text: String, val styles: List<Style>, val math: List<Math>)
    fun parse(display: String, original: String = display): Parsed {
        val runs = MathScanner.spans(display)
        val protected = StringBuilder(); var previous = 0
        runs.forEachIndexed { index, span -> protected.append(display.substring(previous, span.start)); protected.append('\uE000').append(index).append('\uE001'); previous = span.end }
        protected.append(display.substring(previous))
        val out = StringBuilder(); val styles = mutableListOf<Style>(); val math = mutableListOf<Math>()
        var fence: Char? = null
        fun appendInline(value: String, depth: Int = 0) {
            var i = 0
            while (i < value.length) {
                if (value[i] == '\uE000') {
                    val end = value.indexOf('\uE001', i + 1); val index = if (end > i) value.substring(i + 1, end).toIntOrNull() else null
                    if (index != null && index in runs.indices) {
                        val span = runs[index]
                        // The preview's synthetic braces/delimiters must never enter selected copy.
                        val raw = if (span.end > original.length || display != original && span.end == display.length) original.substring(span.start.coerceAtMost(original.length)) else span.raw
                        if (span.display && out.isNotEmpty() && out.last() != '\n') out.append('\n')
                        val start = out.length
                        val actualStart = out.length; out.append(raw)
                        math += Math(actualStart, out.length, span)
                        if (span.display) out.append('\n')
                        i = end + 1; continue
                    }
                }
                if (depth < 4 && value[i] == '[') {
                    val close = value.indexOf("](", i + 1); val end = if (close >= 0) value.indexOf(')', close + 2) else -1
                    if (end > close && close > i) { val start = out.length; appendInline(value.substring(i + 1, close), depth + 1); styles += Style(start, out.length, "link", value.substring(close + 2, end)); i = end + 1; continue }
                }
                val marker = listOf("**", "__", "`", "*", "_").firstOrNull { value.startsWith(it, i) }
                if (marker != null && depth < 4) {
                    val end = value.indexOf(marker, i + marker.length)
                    if (end > i + marker.length) { val start = out.length; val inner = value.substring(i + marker.length, end); if (marker == "`") out.append(inner) else appendInline(inner, depth + 1); styles += Style(start, out.length, if (marker == "`") "code" else if (marker.length == 2) "bold" else "italic"); i = end + marker.length; continue }
                }
                out.append(value[i++])
            }
        }
        val lines = protected.toString().split('\n')
        lines.forEachIndexed { index, raw ->
            var line = raw.trimEnd('\r'); val trimmed = line.trimStart()
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                val mark = trimmed.first(); if (fence == null) fence = mark else if (fence == mark) fence = null
            } else if (fence != null) { val start = out.length; out.append(line); styles += Style(start, out.length, "code"); if (index < lines.lastIndex) out.append('\n') }
            else {
                val heading = Regex("^(#{1,6})\\s+").find(line)
                val quote = line.startsWith("> ")
                if (heading != null) line = line.substring(heading.value.length)
                if (quote) line = line.drop(2)
                if (Regex("^\\s*[-*+]\\s+").containsMatchIn(line)) line = line.replaceFirst(Regex("^\\s*[-*+]\\s+"), "• ")
                val start = out.length; appendInline(line)
                if (heading != null) { styles += Style(start, out.length, "bold"); styles += Style(start, out.length, "heading", if (heading.groupValues[1].length == 1) "1.35" else "1.18") }
                if (quote) styles += Style(start, out.length, "quote")
                if (index < lines.lastIndex) out.append('\n')
            }
        }
        return Parsed(out.toString(), styles, math)
    }
}
