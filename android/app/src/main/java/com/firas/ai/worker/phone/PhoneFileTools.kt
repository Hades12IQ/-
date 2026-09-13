package com.firas.ai.worker.phone

import android.content.Context
import android.util.AtomicFile
import com.firas.ai.worker.WorkerPolicy
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Files are confined to the current account's app-owned workspace. Export uses an OS picker. */
class PhoneFileTools(context: Context, owner: String) {
    private val root = File(context.filesDir, "worker/${WorkerPolicy.hash(owner)}/files").apply { mkdirs() }.canonicalFile
    private fun resolve(path: String): File {
        require(WorkerPolicy.safeRelativePath(path)) { "Invalid workspace path" }
        val file = File(root, path).canonicalFile
        require(file.path.startsWith(root.path + File.separator)) { "Path escapes workspace" }
        return file
    }
    fun list(): List<String> = root.walkTopDown().maxDepth(7).filter { it.isFile && !it.name.endsWith(".bak") && !it.name.endsWith(".new") }.take(100).map { it.relativeTo(root).invariantSeparatorsPath }.toList()
    fun read(path: String): String {
        val file = resolve(path)
        require(file.isFile && file.length() <= WorkerPolicy.MAX_FILE_BYTES) { "File missing or too large" }
        return file.readText(Charsets.UTF_8)
    }
    fun fingerprint(path: String): String = resolve(path).let { if (it.exists()) WorkerPolicy.hash(read(path)) else "missing" }
    fun write(path: String, content: String, expected: String): JSONObject {
        require(content.toByteArray(Charsets.UTF_8).size <= WorkerPolicy.MAX_FILE_BYTES) { "File exceeds workspace limit" }
        check(fingerprint(path) == expected) { "File changed after approval; observe it again" }
        val file = resolve(path)
        check(file.parentFile?.mkdirs() == true || file.parentFile?.isDirectory == true)
        if (file.exists()) {
            val recovery = File(root, "recovery/${System.currentTimeMillis()}-${file.name}")
            recovery.parentFile?.mkdirs()
            file.copyTo(recovery, overwrite = false)
        }
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try { stream.write(content.toByteArray(Charsets.UTF_8)); atomic.finishWrite(stream) }
        catch (error: Throwable) { atomic.failWrite(stream); throw error }
        return JSONObject().put("path", path).put("bytes", file.length()).put("sha256", fingerprint(path))
    }
}
