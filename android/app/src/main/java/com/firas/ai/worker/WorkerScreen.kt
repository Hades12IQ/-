package com.firas.ai.worker

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.unit.dp
import com.firas.ai.worker.phone.PhoneAccessibilityService
import com.firas.ai.worker.phone.PhoneCaptureService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun WorkerScreen(ownerId: String?, api: WorkerApi, modifier: Modifier = Modifier, initialPc: Boolean = false) {
    var pc by remember(ownerId,initialPc) { mutableStateOf(initialPc) }
    Column(modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(selected = !pc, onClick = { pc = false }, label = { Text("This phone · الهاتف") })
            FilterChip(selected = pc, onClick = { pc = true }, label = { Text("Windows PC · الكمبيوتر") })
        }
        if (pc) com.firas.ai.worker.remote.CompanionScreen(ownerId, Modifier.weight(1f).padding(horizontal = 16.dp))
        else PhoneWorkerScreen(ownerId, api, Modifier.weight(1f))
    }
}

@Composable
private fun PhoneWorkerScreen(ownerId: String?, api: WorkerApi, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val engine = remember { WorkerRuntime.bind(context, ownerId, api) }
    LaunchedEffect(ownerId, api) { WorkerRuntime.bind(context, ownerId, api) }
    val state by engine.state.collectAsState()
    val accessible by PhoneAccessibilityService.connected.collectAsState()
    val capture by PhoneCaptureService.available.collectAsState()
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val list = rememberLazyListState()
    var draft by remember { mutableStateOf("") }
    var uiError by remember { mutableStateOf("") }
    var exportBody by remember { mutableStateOf<Pair<String, String>?>(null) }
    var followLatest by remember { mutableStateOf(true) }
    val nearBottom by remember { derivedStateOf { list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= list.layoutInfo.totalItemsCount - 2 } ?: true } }
    val captureLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val account = WorkerRuntime.owner.value
        if (result.resultCode == Activity.RESULT_OK && result.data != null && account == ownerId && account != null) {
            try { PhoneCaptureService.start(context, account, result.data!!) } catch (_: RuntimeException) { uiError = "Screen sharing could not start · تعذّر بدء مشاركة الشاشة" }
        }
    }
    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri ->
        val pending = exportBody; exportBody = null
        if (uri != null && pending != null && pending.first == WorkerRuntime.owner.value) scope.launch {
            try { withContext(Dispatchers.IO) { check(pending.first == WorkerRuntime.owner.value); context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(pending.second.toByteArray(Charsets.UTF_8)) } ?: error("Cannot open export destination") } }
            catch (_: Exception) { uiError = "Export failed; the original workspace file is preserved.\nتعذّر التصدير؛ الملف الأصلي محفوظ." }
        }
    }
    LaunchedEffect(state.events.size, state.phase) { if (followLatest || nearBottom) { if (list.layoutInfo.totalItemsCount > 0) list.animateScrollToItem(list.layoutInfo.totalItemsCount - 1) }; followLatest = false }
    Column(modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Firas Worker", style = MaterialTheme.typography.headlineSmall)
        Text("This phone · هذا الهاتف", style = MaterialTheme.typography.titleMedium)
        Text("Starts only when you request it. Every action has a visible approval and Stop control.\nيعمل بطلبك فقط، مع مراجعة كل إجراء وزر إيقاف ظاهر.", style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(onClick = { context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }, modifier = Modifier.weight(1f)) { Text(if (accessible) "Accessibility ✓" else "Enable control · تفعيل التحكم") }
            OutlinedButton(onClick = {
                if (capture) PhoneCaptureService.stop(context)
                else captureLauncher.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
            }, enabled = ownerId != null, modifier = Modifier.weight(1f)) { Text(if (capture) "Stop sharing" else "Share screen · مشاركة الشاشة") }
        }
        if (ownerId == null) Text("Sign in to start a task · سجّل الدخول لبدء مهمة", color = MaterialTheme.colorScheme.primary)
        if (uiError.isNotEmpty()) Text(uiError, color = MaterialTheme.colorScheme.error)
        Box(Modifier.weight(1f)) {
            LazyColumn(state = list, modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(bottom = 18.dp)) {
                if (state.task.isNotBlank()) item("task") { Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.primaryContainer) { Text(state.task, modifier = Modifier.padding(14.dp)) } } }
                items(state.events, key = { "event-${it.id}" }) { row -> SelectionContainer { Text(row.text, style = MaterialTheme.typography.bodyMedium) } }
                state.approval?.let { approval -> item(approval.id) {
                    Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(approval.title, style = MaterialTheme.typography.titleMedium)
                            SelectionContainer { Text(approval.detail, style = MaterialTheme.typography.bodySmall) }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button(onClick = { engine.approve(approval.id, true) }) { Text("Allow once · سماح مرة") }
                                OutlinedButton(onClick = { engine.approve(approval.id, false) }) { Text("Deny · رفض") }
                            }
                        }
                    }
                } }
                if (state.summary.isNotEmpty()) item("summary") { SelectionContainer { Text(state.summary) } }
                items(state.files, key = { "file-$it" }) { path ->
                    OutlinedButton(onClick = { scope.launch {
                        try { val account = WorkerRuntime.owner.value ?: return@launch; val body = engine.exportText(path); exportBody = account to body; exportLauncher.launch(path.substringAfterLast('/')) }
                        catch (_: Exception) { uiError = "File unavailable · الملف غير متاح" }
                    } }) { Text("Save · حفظ $path") }
                }
                item("status") { Text(if (state.active) "${state.phase} · ${state.steps}/${WorkerPolicy.MAX_STEPS}" else "Local task · مهمة على الجهاز", style = MaterialTheme.typography.labelSmall) }
            }
            if (!nearBottom) FilledTonalButton(onClick = { scope.launch { list.animateScrollToItem((list.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)) } }, modifier = Modifier.align(Alignment.BottomEnd)) { Text("↓") }
        }
        if (state.active) OutlinedButton(onClick = { engine.stop() }, modifier = Modifier.fillMaxWidth()) { Text("Stop task · إيقاف المهمة") }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.imePadding()) {
            OutlinedTextField(value = draft, onValueChange = { if (it.length <= WorkerPolicy.MAX_TASK) draft = it }, modifier = Modifier.weight(1f), placeholder = { Text("What should Firas do? · ماذا تريد من فراس؟") }, minLines = 1, maxLines = 5, shape = MaterialTheme.shapes.extraLarge)
            Button(onClick = { val task = draft; draft = ""; uiError = ""; followLatest = true; keyboard?.hide(); focus.clearFocus(); engine.start(task) }, enabled = ownerId != null && accessible && draft.isNotBlank() && !state.active) { Text("↑") }
        }
    }
}
