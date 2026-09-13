package com.firas.ai.worker.phone

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.firas.ai.worker.WorkerPolicy
import com.firas.ai.worker.WorkerRuntime
import com.firas.ai.worker.WorkerState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** No coordinate injection: all actions target a freshly revalidated semantic control. */
class PhoneAccessibilityService : AccessibilityService() {
    private data class Target(val packageName: String, val window: Int, val path: List<Int>, val signature: String, val label: String)
    private val observed = mutableMapOf<String, Target>()
    private var knownApps = emptySet<String>()
    private var overlay: LinearLayout? = null
    private var renderedApproval: String? = null

    override fun onServiceConnected() { instance = this; _connected.value = true; WorkerRuntime.engine()?.state?.value?.let(::renderState) }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() { WorkerRuntime.stop(); observed.clear() }
    override fun onDestroy() {
        WorkerRuntime.stop(); removeOverlay(); observed.clear()
        if (instance === this) { instance = null; _connected.value = false }
        super.onDestroy()
    }
    private fun blockedPackage(value: String): Boolean = value == packageName || value == "android" || value.contains("systemui") || value.contains("permissioncontroller") || value.contains("packageinstaller") || value == "com.android.settings"
    private fun label(node: AccessibilityNodeInfo): String = if (node.isPassword) "[protected field]" else listOfNotNull(node.contentDescription?.toString(), node.text?.toString(), node.viewIdResourceName).joinToString(" · ").take(250).let { if (WorkerPolicy.protectedLabel(it)) "[protected field]" else it }
    private fun signature(node: AccessibilityNodeInfo): String {
        val bounds = Rect().also { node.getBoundsInScreen(it) }
        return WorkerPolicy.hash(listOf(node.viewIdResourceName, node.className, label(node), bounds.flattenToString(), node.isEnabled, node.isPassword, node.isEditable, node.isClickable, node.isScrollable).joinToString("|"))
    }
    fun apps(): JSONObject {
        @Suppress("DEPRECATION") val rows = packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .filterNot { blockedPackage(it.activityInfo.packageName) }.distinctBy { it.activityInfo.packageName }.take(100)
        knownApps = rows.map { it.activityInfo.packageName }.toSet()
        return JSONObject().put("apps", JSONArray().apply { rows.forEach { put(JSONObject().put("package", it.activityInfo.packageName).put("label", it.loadLabel(packageManager).toString().take(100))) } })
    }
    fun openApp(packageId: String): JSONObject {
        check(packageId in knownApps && !blockedPackage(packageId)) { "Choose an app returned by listApps" }
        val launch = packageManager.getLaunchIntentForPackage(packageId) ?: error("App is unavailable")
        startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); observed.clear()
        return JSONObject().put("opened", packageId)
    }
    fun observe(): JSONObject {
        observed.clear()
        val root = rootInActiveWindow ?: error("No accessible app is in the foreground")
        val app = root.packageName?.toString().orEmpty()
        check(app.isNotEmpty() && !blockedPackage(app)) { "Open the target app; system permissions and Firas controls must be handled by you" }
        val elements = JSONArray()
        val prefix = UUID.randomUUID().toString().take(8)
        var visited = 0
        fun visit(node: AccessibilityNodeInfo, path: List<Int>, depth: Int) {
            if (++visited > 320 || depth > 16 || elements.length() >= 100) return
            if (node.isVisibleToUser && !node.isPassword) {
                val name = label(node)
                if (name != "[protected field]" && (name.isNotBlank() || node.isScrollable)) {
                    val id = "$prefix-${elements.length()}"
                    val actions = JSONArray().apply {
                        if (node.isClickable) put("click")
                        if (node.isEditable) put("input")
                        if (node.isScrollable) { put("scrollForward"); put("scrollBackward") }
                    }
                    if (node.isEnabled && actions.length() > 0 && WorkerPolicy.allowedControl(name)) observed[id] = Target(app, root.windowId, path, signature(node), name)
                    elements.put(JSONObject().put("id", id).put("label", name).put("actions", actions).put("actionable", id in observed))
                }
            }
            if (node.isPassword) return
            for (index in 0 until node.childCount.coerceAtMost(100)) node.getChild(index)?.let { visit(it, path + index, depth + 1) }
        }
        visit(root, emptyList(), 0)
        return JSONObject().put("package", app).put("window", root.windowId).put("elements", elements).put("truncated", visited >= 320 || elements.length() >= 100)
    }
    fun actionDescription(id: String, operation: String, text: String): String {
        val target = observed[id] ?: error("Observe the target again")
        check(operation in setOf("click", "input", "scrollForward", "scrollBackward"))
        check(WorkerPolicy.allowedControl(target.label)) { "This protected action must be performed manually" }
        if (operation == "input") {
            require(text.length <= 8000 && !WorkerPolicy.protectedLabel(text)) { "Sensitive or excessive input must be entered manually" }
        }
        return "${target.packageName}\n$operation · ${target.label}" + if (operation == "input") "\n\n$text" else ""
    }
    fun act(id: String, operation: String, text: String): JSONObject {
        actionDescription(id, operation, text)
        val target = observed[id] ?: error("Observe the target again")
        var node = rootInActiveWindow ?: error("Target app is no longer visible")
        val freshPackage = node.packageName?.toString().orEmpty()
        val freshWindow = node.windowId
        for (index in target.path) node = node.getChild(index) ?: error("Control changed; observe again")
        check(WorkerPolicy.sameTarget(target.packageName, target.window, target.signature, freshPackage, freshWindow, signature(node))) { "Control changed after approval; observe again" }
        check(node.isVisibleToUser && node.isEnabled && !node.isPassword && WorkerPolicy.allowedControl(label(node))) { "Control is protected or unavailable" }
        val accepted = when (operation) {
            "click" -> node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            "input" -> node.isEditable && node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) })
            "scrollForward" -> node.isScrollable && node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
            "scrollBackward" -> node.isScrollable && node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
            else -> false
        }
        observed.clear()
        return JSONObject().put("acceptedBySystem", accepted).put("verificationRequired", true)
    }
    fun back(): JSONObject {
        val root = rootInActiveWindow ?: error("No foreground app")
        check(!blockedPackage(root.packageName?.toString().orEmpty())) { "System controls must be handled manually" }
        observed.clear()
        return JSONObject().put("acceptedBySystem", performGlobalAction(GLOBAL_ACTION_BACK)).put("verificationRequired", true)
    }
    fun renderState(state: WorkerState) {
        if (!state.active) { removeOverlay(); return }
        if (overlay != null && renderedApproval == state.approval?.id) return
        removeOverlay(); renderedApproval = state.approval?.id
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(24, 16, 24, 16)
            setBackgroundColor(0xF21C2028.toInt())
        }
        panel.addView(TextView(this).apply { text = "Firas Worker · ${state.phase}"; setTextColor(0xFFFFFFFF.toInt()); textSize = 15f })
        state.approval?.let { approval ->
            panel.addView(ScrollView(this).apply {
                addView(TextView(this@PhoneAccessibilityService).apply { text = "${approval.title}\n${approval.detail}"; setTextColor(0xFFFFFFFF.toInt()); textSize = 14f; setPadding(0, 12, 0, 12) })
            }, LinearLayout.LayoutParams(-1, (resources.displayMetrics.heightPixels * .25).toInt()))
            val actions = LinearLayout(this)
            actions.addView(Button(this).apply { text = "Allow once · سماح مرة"; setOnClickListener { WorkerRuntime.engine()?.approve(approval.id, true) } }, LinearLayout.LayoutParams(0, -2, 1f))
            actions.addView(Button(this).apply { text = "Deny · رفض"; setOnClickListener { WorkerRuntime.engine()?.approve(approval.id, false) } }, LinearLayout.LayoutParams(0, -2, 1f))
            panel.addView(actions)
        }
        panel.addView(Button(this).apply { text = "Stop · إيقاف"; setOnClickListener { WorkerRuntime.stop() } })
        try {
            getSystemService(WindowManager::class.java).addView(panel, WindowManager.LayoutParams(-1, -2, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT).apply { gravity = Gravity.BOTTOM })
            overlay = panel
        } catch (_: RuntimeException) { WorkerRuntime.engine()?.stop("Cannot show the required Stop control") }
    }
    private fun removeOverlay() {
        overlay?.let { try { getSystemService(WindowManager::class.java).removeView(it) } catch (_: RuntimeException) {} }
        overlay = null; renderedApproval = null
    }
    companion object {
        private var instance: PhoneAccessibilityService? = null
        private val _connected = MutableStateFlow(false)
        val connected = _connected.asStateFlow()
        fun requireService(): PhoneAccessibilityService = instance ?: error("Enable Firas Worker in Android Accessibility settings")
        fun showState(state: WorkerState) { Handler(Looper.getMainLooper()).post { instance?.renderState(state) } }
    }
}
