package com.firas.ai.render

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

data class MathGlyph(val bitmap: Bitmap, val baseline: Float)

/** Completed formulas are private to the account. Temporary/streaming glyphs never reach disk.
 * Clearing invalidates in-flight writes; successful row-held bitmaps are never recycled. */
object MathGlyphCache {
    private val memory = object : LruCache<String, MathGlyph>(16 * 1024 * 1024) {
        override fun sizeOf(key: String, value: MathGlyph) = value.bitmap.allocationByteCount
    }
    private val diskLock = Mutex()
    @Volatile private var generation = 0L
    fun generationToken(): Long = generation
    fun key(scope: String, style: String, span: MathScanner.Span) = sha("android-katex-0.16.11-v1|$scope|$style|${span.id}")
    @Synchronized fun peek(key: String): MathGlyph? = memory.get(key)
    @Synchronized fun put(key: String, glyph: MathGlyph, expectedGeneration: Long = generation) { if (expectedGeneration == generation) memory.put(key, glyph) }
    suspend fun read(context: Context, key: String): MathGlyph? {
        peek(key)?.let { return it }
        val epoch = generation
        return withContext(Dispatchers.IO) {
            val file = File(context.cacheDir, "math-glyphs/$key.png")
            val result = runCatching {
                val meta = JSONObject(File(file.parentFile, "$key.json").readText())
                val bitmap = BitmapFactory.decodeFile(file.path) ?: return@runCatching null
                if (bitmap.width <= 0 || bitmap.height <= 0 || bitmap.allocationByteCount > 4 * 1024 * 1024) return@runCatching null
                MathGlyph(bitmap, meta.getDouble("baseline").toFloat())
            }.getOrNull()
            if (epoch == generation && result != null) { put(key, result); result } else null
        }
    }
    suspend fun persist(context: Context, key: String, glyph: MathGlyph, expectedGeneration: Long = generation) {
        val epoch = expectedGeneration
        withContext(Dispatchers.IO) { diskLock.withLock {
            if (epoch != generation) return@withLock
            val folder = File(context.cacheDir, "math-glyphs").apply { mkdirs() }
            val png = File(folder, "$key.png"); val temporary = File(folder, "$key.tmp")
            if (png.isFile && File(folder, "$key.json").isFile) return@withLock
            temporary.outputStream().use { glyph.bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            if (epoch != generation) { temporary.delete(); return@withLock }
            if (!temporary.renameTo(png)) { temporary.delete(); return@withLock }
            File(folder, "$key.json").writeText(JSONObject().put("baseline", glyph.baseline).toString())
            // Off the UI thread, once per durable write; bounded by 512 small records.
            val entries = folder.listFiles { f -> f.extension == "png" }.orEmpty().sortedBy { it.lastModified() }
            var bytes = entries.sumOf { it.length() }
            for ((index, f) in entries.withIndex()) {
                if (bytes <= 48 * 1024 * 1024 && entries.size - index <= 512) break
                bytes -= f.length(); f.delete(); File(folder, f.nameWithoutExtension + ".json").delete()
            }
        } }
    }
    suspend fun clear(context: Context) {
        synchronized(this) { generation++; memory.evictAll() }
        withContext(Dispatchers.IO) { diskLock.withLock { File(context.cacheDir, "math-glyphs").listFiles()?.forEach { it.delete() } } }
    }
    fun sha(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}
