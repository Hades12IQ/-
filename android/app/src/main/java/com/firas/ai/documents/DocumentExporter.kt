package com.firas.ai.documents

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintJob
import android.print.PrintManager
import android.util.Base64
import com.firas.ai.render.LocalWebSurface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.roundToInt

class DocumentExportException(val stage: String, val safeReason: String) : Exception(safeReason)
data class DocumentDiagnostics(val pages: Int, val bytes: Long, val mathCount: Int?, val layout: String)

/** Automatic export uses the authenticated durable PDF service. System printing is an explicit
 * alternative. Android's hidden print callback constructors are deliberately not used. */
object DocumentExporter {
    private val queue = Mutex()
    @Volatile var lastDiagnostics: DocumentDiagnostics? = null
        private set
    suspend fun export(
        context: Context, sourceHtml: String, name: String,
        imageAssets: Map<String, ByteArray> = emptyMap(),
        cloudExport: suspend (String, String, Map<String, ByteArray>) -> File,
    ): File = queue.withLock {
        if (AuthoredDocument.extract(sourceHtml) == null) throw DocumentExportException("source", "المصدر غير مكتمل. / The document source is incomplete.")
        // The repository owns authentication, idempotent enqueue, persisted job IDs and downloads.
        // It must not bind job cancellation to navigation away from this screen.
        val file = cloudExport(sourceHtml, name, imageAssets)
        val pages = withContext(Dispatchers.IO) {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor -> PdfRenderer(descriptor).use { it.pageCount } }
        }
        if (pages < 1 || file.length() < 500) throw DocumentExportException("pages", "تعذر إنتاج صفحات PDF صالحة. / The PDF did not contain valid pages.")
        DocumentFiles.uri(context, file) // Validate the narrow app-private FileProvider root.
        lastDiagnostics = DocumentDiagnostics(pages, file.length(), null, "validated downloaded PDF")
        file
    }

    /** Explicit native print/save sheet. Returns the real system job, not a fabricated PDF path. */
    suspend fun requestSystemPrint(context: Context, sourceHtml: String, name: String, imageAssets: Map<String, ByteArray> = emptyMap()): PrintJob = queue.withLock {
        if (AuthoredDocument.extract(sourceHtml) == null) throw DocumentExportException("source", "المصدر غير مكتمل. / The document source is incomplete.")
        val embedded = withContext(Dispatchers.IO) { DocumentImages.embed(sourceHtml, imageAssets) }
        val page = Paper.from(sourceHtml)
        val nonce = LocalWebSurface.nonce()
        val html = printable(embedded, nonce, page)
        withContext(Dispatchers.Main.immediate) {
                val density = context.resources.displayMetrics.density
                val width = (page.widthCss * density).roundToInt()
                val surface = LocalWebSurface(context, width, (page.heightCss * density).roundToInt())
                var handedOff = false
                try {
                    withTimeout(60_000) {
                        surface.load(html)
                        var ready = false
                        repeat(160) { if (!ready) { delay(50); ready = surface.evaluate("window.__firasReady===true && (!document.fonts || document.fonts.status==='loaded') && Array.from(document.images).every(i=>i.complete)") == true } }
                        if (!ready) throw DocumentExportException("ready", "لم يكتمل تحميل الخطوط أو الصور. / Fonts or images did not finish loading.")
                        val report = surface.evaluate(LocalWebSurface.script(context, "document-layout.js")) as? JSONObject
                            ?: throw DocumentExportException("layout", "تعذر فحص تنسيق المستند. / Document layout could not be checked.")
                        val errors = (surface.evaluate("document.querySelectorAll('.katex-error').length") as? Number)?.toInt() ?: 0
                        val mathCount = (surface.evaluate("document.querySelectorAll('.katex').length") as? Number)?.toInt() ?: 0
                        if (errors > 0) throw DocumentExportException("math", "توجد معادلة تحتاج تصحيحاً قبل التصدير. / An equation needs correction before export.")
                        if (report.optInt("brokenImages") > 0) throw DocumentExportException("images", "إحدى الصور غير متاحة. أرفق الصورة الأصلية ثم أعد المحاولة. / An original image is missing; attach it and retry.")
                        if (report.optInt("mathOverflow") > 0 || report.optInt("bodyOverflow") > 3) throw DocumentExportException("overflow", "بعض المحتوى أعرض من الصفحة. اطلب إعادة ترتيب هذا الجزء ثم أعد التصدير. / Some content exceeds the page width; revise that layout and export again.")
                        delay(50)
                        val delegate = surface.web.createPrintDocumentAdapter(name)
                        val adapter = object : PrintDocumentAdapter() {
                            override fun onStart() = delegate.onStart()
                            override fun onLayout(oldAttributes: PrintAttributes?, newAttributes: PrintAttributes, cancellationSignal: CancellationSignal, callback: LayoutResultCallback, extras: Bundle?) = delegate.onLayout(oldAttributes, newAttributes, cancellationSignal, callback, extras)
                            override fun onWrite(pages: Array<out PageRange>, destination: ParcelFileDescriptor, cancellationSignal: CancellationSignal, callback: WriteResultCallback) = delegate.onWrite(pages, destination, cancellationSignal, callback)
                            override fun onFinish() { try { delegate.onFinish() } finally { surface.close() } }
                        }
                        val manager = context.getSystemService(Context.PRINT_SERVICE) as PrintManager
                        val job = manager.print(name, adapter, page.attributes)
                        handedOff = true
                        job
                    }
                } finally { if (!handedOff) surface.close() }
        }
    }

    private fun printable(source: String, nonce: String, page: Paper): String {
        // A random nonce authorizes ONLY bundled scripts. Authored scripts/event handlers never run.
        var html = source.replace(Regex("<meta\\b[^>]*name\\s*=\\s*['\"]?viewport['\"]?[^>]*>", RegexOption.IGNORE_CASE), "")
        val css = """
            @font-face{font-family:'Firas Arabic';font-style:normal;font-weight:100 900;src:url('${LocalWebSurface.ASSETS}fonts/NotoSansArabic.ttf') format('truetype');font-display:block}
            @font-face{font-family:'Firas Sans';font-style:normal;font-weight:100 900;src:url('${LocalWebSurface.ASSETS}fonts/NotoSans.ttf') format('truetype');font-display:block}
            :where(body){font-family:'Firas Arabic','Firas Sans',sans-serif;font-size:13pt;line-height:1.75}
            :where(html[dir=ltr] body,body[dir=ltr]){font-family:'Firas Sans','Firas Arabic',sans-serif}
            .katex,.katex-display{direction:ltr;unicode-bidi:isolate}.katex-display{break-inside:avoid;page-break-inside:avoid}
            .katex-mathml{display:none!important}html,body{margin:0!important}img,svg{max-width:100%;height:auto}
            @page{margin:0!important}p,li{orphans:3;widows:3}thead{display:table-header-group}tfoot{display:table-footer-group}
            [data-firas-item],[data-firas-solution],figure{break-inside:avoid;page-break-inside:avoid}
        """.trimIndent()
        val injection = LocalWebSurface.policy(nonce) + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"${LocalWebSurface.ASSETS}katex/katex.min.css\">" + LocalWebSurface.assetScripts(nonce)
        val head = Regex("<head\\b[^>]*>", RegexOption.IGNORE_CASE).find(html)
        html = if (head != null) html.substring(0, head.range.last + 1) + injection + html.substring(head.range.last + 1) else injection + html
        html += "<style>$css</style><script nonce=\"$nonce\">document.documentElement.dataset.firasPrintableHeight='${page.heightCss}';</script><script nonce=\"$nonce\" src=\"${LocalWebSurface.ASSETS}document-math.js\"></script>"
        return html
    }

    private data class Paper(val attributes: PrintAttributes, val widthCss: Float, val heightCss: Float) {
        companion object {
            fun from(source: String): Paper {
                val rule = Regex("@page(?:\\s+[^{}]*)?\\s*\\{([^}]*)\\}", RegexOption.IGNORE_CASE).find(source)?.groupValues?.get(1).orEmpty().lowercase()
                var media = when { "a3" in rule -> PrintAttributes.MediaSize.ISO_A3; "a5" in rule -> PrintAttributes.MediaSize.ISO_A5; "letter" in rule -> PrintAttributes.MediaSize.NA_LETTER; "legal" in rule -> PrintAttributes.MediaSize.NA_LEGAL; else -> PrintAttributes.MediaSize.ISO_A4 }
                media = if ("landscape" in rule) media.asLandscape() else media.asPortrait()
                val raw = Regex("(?:^|;)\\s*margin\\s*:\\s*([^;]+)").find(rule)?.groupValues?.get(1)
                val values = raw?.let { Regex("([\\d.]+)\\s*(mm|cm|in|pt)").findAll(it).map { m -> val v = m.groupValues[1].toFloatOrNull() ?: 16f; when (m.groupValues[2]) { "cm" -> v * 10; "in" -> v * 25.4f; "pt" -> v * 25.4f / 72; else -> v } }.toList() }.orEmpty()
                val margins = when (values.size) { 1 -> List(4) { values[0] }; 2 -> listOf(values[0], values[1], values[0], values[1]); 3 -> listOf(values[0], values[1], values[2], values[1]); 4 -> values; else -> listOf(18f,16f,18f,16f) }.map { (it.coerceIn(8f, 35f) / 25.4f * 1000).roundToInt() }
                val native = PrintAttributes.Margins(margins[3], margins[0], margins[1], margins[2])
                val attributes = PrintAttributes.Builder().setMediaSize(media).setResolution(PrintAttributes.Resolution("firas-pdf", "PDF", 600, 600)).setMinMargins(native).setColorMode(PrintAttributes.COLOR_MODE_COLOR).build()
                return Paper(attributes, (media.widthMils - native.leftMils - native.rightMils) / 1000f * 96, (media.heightMils - native.topMils - native.bottomMils) / 1000f * 96)
            }
        }
    }
}

object DocumentImages {
    /** Resolves only real stable IDs in an export copy. The editable source retains its references. */
    fun embed(source: String, assets: Map<String, ByteArray>): String {
        var total = 0
        val encoded = mutableMapOf<String, String>()
        return Regex("([\"'])firas-asset:(?://)?([A-Za-z0-9_.-]+)\\1").replace(source) { match ->
            val id = match.groupValues[2]
            val uri = encoded.getOrPut(id) {
                val bytes = assets[id] ?: throw DocumentExportException("images", "الصورة الأصلية لهذا المستند غير متاحة. / An original document image is missing.")
                if (bytes.size > 30_000_000) throw DocumentExportException("images", "الصورة أكبر من حد التصدير. / Image exceeds the export limit.")
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw DocumentExportException("images", "بيانات الصورة غير صالحة. / Invalid image data.")
                var sample = 1; while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 3000) sample *= 2
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: throw DocumentExportException("images", "تعذر قراءة الصورة. / Image could not be decoded.")
                val stream = ByteArrayOutputStream()
                val format = if (bitmap.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
                bitmap.compress(format, 90, stream); bitmap.recycle()
                val output = stream.toByteArray(); total += output.size
                if (output.size > 8_000_000 || total > 24_000_000) throw DocumentExportException("images", "حجم صور المستند كبير جداً. / Document images exceed the export limit.")
                "data:image/${if (format == Bitmap.CompressFormat.PNG) "png" else "jpeg"};base64," + Base64.encodeToString(output, Base64.NO_WRAP)
            }
            match.groupValues[1] + uri + match.groupValues[1]
        }
    }
}
