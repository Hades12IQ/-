package com.firas.ai.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream
import android.util.Xml
import org.xmlpull.v1.XmlPullParser

/** Reads only explicit SAF selections, with bounded input and extracted text. */
object AttachmentReader {
    private const val MAX_BYTES = 16 * 1024 * 1024
    private const val MAX_TEXT = 1_000_000

    suspend fun read(context: Context, uris: List<Uri>): List<Attachment> = withContext(Dispatchers.IO) {
        if (uris.size > 8) throw failure("أرفق حتى ثمانية ملفات في الرسالة.", "Attach up to eight files per message.")
        var total = 0L
        uris.map { uri ->
            if (uri.scheme != "content") throw failure("اختر الملف من مدير الملفات.", "Choose the file through the document picker.")
            val resolver = context.contentResolver
            var name = "attachment"
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn) && cursor.getLong(sizeColumn) > MAX_BYTES) throw oversized()
                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameColumn >= 0) name = cursor.getString(nameColumn).orEmpty().take(180)
                }
            }
            val bytes = resolver.openInputStream(uri)?.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    total += n
                    if (output.size() + n > MAX_BYTES || total > 24L * 1024 * 1024) throw oversized()
                    output.write(buffer, 0, n)
                }
                output.toByteArray()
            } ?: throw failure("تعذر قراءة الملف.", "The selected file could not be read.")
            val mime = resolver.getType(uri).orEmpty().ifBlank { "application/octet-stream" }
            val ext = name.substringAfterLast('.', "").lowercase()
            if (mime.startsWith("image/")) {
                Attachment(name, mime, base64 = Base64.encodeToString(bytes, Base64.NO_WRAP))
            } else {
                val text = when {
                    mime == "application/pdf" || ext == "pdf" -> {
                        PDFBoxResourceLoader.init(context.applicationContext)
                        PDDocument.load(bytes).use { document ->
                            if (document.numberOfPages > 500) throw oversized()
                            PDFTextStripper().getText(document)
                        }
                    }
                    ext in setOf("docx", "pptx", "xlsx") -> officeText(bytes, ext)
                    mime.startsWith("text/") || ext in setOf("json", "js", "ts", "tsx", "jsx", "py", "swift", "kt", "java", "c", "cpp", "h", "css", "html", "md", "csv", "xml", "yaml", "yml", "sql", "rs", "go", "sh", "r", "tex") -> bytes.toString(Charsets.UTF_8)
                    else -> throw failure("هذا النوع يحتاج تحويله إلى PDF أو نص أولاً.", "Convert this file to PDF or text before attaching it.")
                }
                if (text.length > MAX_TEXT) throw oversized()
                if (text.isBlank()) throw failure("لم أجد نصاً قابلاً للقراءة. للملف الممسوح ضوئياً، أرفق الصفحات كصور.", "No readable text was found. Attach scanned pages as images.")
                Attachment(name, mime, text = text)
            }
        }
    }

    private fun officeText(bytes: ByteArray, extension: String): String {
        val parts = sortedMapOf<String, String>()
        var expanded = 0
        ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val selected = when (extension) {
                    "docx" -> entry.name == "word/document.xml"
                    "pptx" -> entry.name.matches(Regex("ppt/slides/slide[0-9]+\\.xml"))
                    else -> entry.name == "xl/sharedStrings.xml" || entry.name.matches(Regex("xl/worksheets/sheet[0-9]+\\.xml"))
                }
                if (!selected) continue
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(8192)
                while (true) {
                    val n = zip.read(chunk)
                    if (n < 0) break
                    expanded += n
                    if (expanded > MAX_BYTES) throw oversized()
                    buffer.write(chunk, 0, n)
                }
                val parser = Xml.newPullParser()
                parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
                parser.setInput(ByteArrayInputStream(buffer.toByteArray()), null)
                val text = StringBuilder()
                var accepting = false
                while (parser.eventType != XmlPullParser.END_DOCUMENT) {
                    when (parser.eventType) {
                        XmlPullParser.DOCDECL -> throw failure("الملف يتضمن تعريف XML غير مسموح.", "This document contains an unsupported XML declaration.")
                        XmlPullParser.START_TAG -> accepting = parser.name == "t" || (extension == "xlsx" && parser.name == "v")
                        XmlPullParser.TEXT -> if (accepting) {text.append(parser.text).append(' '); if(text.length>MAX_TEXT) throw oversized()}
                        XmlPullParser.END_TAG -> {accepting=false; if(parser.name in setOf("p","row")) text.append('\n')}
                    }
                    parser.nextToken()
                }
                parts[entry.name] = text.toString()
            }
        }
        return parts.entries.joinToString("\n\n") { (name,text) -> "[$name]\n$text" }
    }

    private fun oversized() = failure("الملف كبير جداً لهذه الرسالة. قسّمه إلى ملفات أصغر.", "This attachment is too large. Split it into smaller files.")
    private fun failure(ar: String, en: String) = FirasFailure(UiNotice(ar, en))
}
