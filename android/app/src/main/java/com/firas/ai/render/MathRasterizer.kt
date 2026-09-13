package com.firas.ai.render

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import kotlin.math.ceil

/** A serialized isolated renderer. One batch owns one offscreen surface; visible rows are native. */
object MathRasterizer {
    private val lock = Mutex()
    suspend fun render(context: Context, spans: List<MathScanner.Span>, ink: Int, fontSp: Float, scope: String, persist: Boolean, onGlyph: (String, MathGlyph) -> Unit) {
        if (spans.isEmpty()) return
        val metrics = context.resources.displayMetrics
        val generation = MathGlyphCache.generationToken()
        val fontCss = fontSp * metrics.scaledDensity / metrics.density
        val style = "$ink|$fontCss|${metrics.density}"
        val missing = mutableListOf<Pair<MathScanner.Span, String>>()
        spans.distinctBy { it.id }.forEach { span ->
            val key = MathGlyphCache.key(scope, style, span)
            val glyph = MathGlyphCache.peek(key) ?: if (persist && scope.isNotEmpty()) MathGlyphCache.read(context, key) else null
            if (glyph != null && generation == MathGlyphCache.generationToken()) {
                onGlyph(span.id, glyph)
                // A formula first rendered while streaming becomes durable only on completion.
                if (persist && scope.isNotEmpty()) MathGlyphCache.persist(context, key, glyph, generation)
            } else if (MathScanner.isTypesettable(span.tex)) missing += span to key
        }
        if (missing.isEmpty()) return
        lock.withLock { withContext(Dispatchers.Main.immediate) {
            val surface = LocalWebSurface(context, ceil(2048 * metrics.density).toInt().coerceAtMost(4096), 512)
            try {
                withTimeout(15_000) {
                    val nonce = LocalWebSurface.nonce()
                    val color = "#%06x".format(ink and 0xffffff)
                    surface.load("<!doctype html><html><head>${LocalWebSurface.policy(nonce)}<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"${LocalWebSurface.ASSETS}katex/katex.min.css\">${LocalWebSurface.assetScripts(nonce)}<style>html,body{margin:0;padding:0;background:transparent;color:$color;font-size:${fontCss}px}#math{display:inline-block;padding:3px;white-space:nowrap}.katex-display{margin:0}.katex{direction:ltr;unicode-bidi:isolate}.katex-mathml{display:none}</style></head><body><span id=\"math\"></span></body></html>")
                    check(surface.evaluate("document.readyState === 'complete' && !!document.getElementById('math') && typeof katex === 'object' && typeof attempt === 'function'") == true) {
                        "Local math renderer did not finish loading its bundled resources"
                    }
                    for ((span, key) in missing) {
                        val cached = MathGlyphCache.peek(key)
                        if (generation != MathGlyphCache.generationToken()) break
                        if (cached != null) {
                            onGlyph(span.id, cached)
                            if (persist && scope.isNotEmpty()) MathGlyphCache.persist(context, key, cached, generation)
                            continue
                        }
                        val json = JSONObject().put("tex", span.tex).put("display", span.display)
                        val started = surface.evaluate("""(function(){window.__glyph=null;var a=$json,h=document.getElementById('math');h.innerHTML='';var ok=attempt(tidy(a.tex),a.display,h,'$color')||attempt(repair(a.tex),a.display,h,'$color');if(!ok)return false;var done=false;function finish(){if(done)return;done=true;var r=h.getBoundingClientRect();window.__glyph={width:r.width,height:r.height,baseline:r.height-3};}setTimeout(finish,1500);function settle(){requestAnimationFrame(function(){requestAnimationFrame(finish)})}if(document.fonts)document.fonts.ready.then(settle,settle);else settle();return true})()""")
                        if (started != true) continue
                        var result: JSONObject? = null
                        repeat(70) { if (result == null) { delay(25); result = surface.evaluate("window.__glyph") as? JSONObject } }
                        val dimensions = result ?: continue
                        val width = ceil(dimensions.optDouble("width") * metrics.density).toInt()
                        val height = ceil(dimensions.optDouble("height") * metrics.density).toInt()
                        if (width !in 1..4096 || height !in 1..4096 || width.toLong() * height > 1_048_576L) continue
                        surface.resize(width, height)
                        delay(32)
                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        surface.web.draw(Canvas(bitmap))
                        val glyph = MathGlyph(bitmap, (dimensions.optDouble("baseline") * metrics.density).toFloat())
                        if (generation != MathGlyphCache.generationToken()) break
                        MathGlyphCache.put(key, glyph, generation)
                        onGlyph(span.id, glyph)
                        if (persist && scope.isNotEmpty()) MathGlyphCache.persist(context, key, glyph, generation)
                    }
                }
            } finally { surface.close() }
        } }
    }
}
