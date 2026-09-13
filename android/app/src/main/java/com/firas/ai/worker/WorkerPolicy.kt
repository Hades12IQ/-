package com.firas.ai.worker

import java.security.MessageDigest

object WorkerPolicy {
    const val MAX_STEPS = 24
    const val MAX_TASK = 12000
    const val MAX_FILE_BYTES = 512000
    private val sensitive = Regex("password|passcode|one.?time|verification.?code|credit.?card|cvv|secret|api.?key|كلمة.?المرور|رمز.?التحقق|كلمة.?السر", RegexOption.IGNORE_CASE)
    private val forbidden = Regex("delete|erase|uninstall|factory.?reset|buy.?now|pay.?now|purchase|transfer.?money|حذف|مسح.?الكل|إلغاء.?التثبيت|شراء|ادفع|دفع.?الآن|تحويل.?مال", RegexOption.IGNORE_CASE)
    fun hash(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    fun protectedLabel(value: String): Boolean = sensitive.containsMatchIn(value)
    fun allowedControl(value: String): Boolean = !protectedLabel(value) && !forbidden.containsMatchIn(value)
    fun safeRelativePath(value: String): Boolean = value.length in 1..180 && !value.startsWith('/') && !value.contains('\\') && !value.contains(':') && value.split('/').let { parts -> parts.size <= 6 && parts.all { it.isNotBlank() && it != "." && it != ".." && !it.startsWith('.') && it.none { c -> c.isISOControl() } } }
    fun sameTarget(packageName: String, windowId: Int, signature: String, freshPackage: String, freshWindow: Int, freshSignature: String): Boolean = packageName == freshPackage && windowId == freshWindow && signature == freshSignature
    fun terminalAfterRestart(phase: String): String = if (phase in setOf("planning", "running", "approval")) "interrupted" else phase
    fun chooseModel(ids: List<String>): String? = listOf("gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-2.5-flash").firstOrNull { it in ids }
}
