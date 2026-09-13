package com.firas.ai.worker.remote

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.unit.dp

@Composable
fun CompanionScreen(ownerId: String?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val controller = remember { CompanionRuntime.bind(context, ownerId) }
    LaunchedEffect(ownerId) { CompanionRuntime.bind(context, ownerId) }
    val state by controller.state.collectAsState()
    var invitation by remember { mutableStateOf("") }
    var task by remember { mutableStateOf("") }
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    Column(modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Windows PC · كمبيوتر Windows", style = MaterialTheme.typography.titleMedium)
        Text("Use the same local network. Keep the PC awake with Firas running.\nاستخدم نفس الشبكة المحلية وأبقِ الكمبيوتر وتطبيق فراس يعملان.", style = MaterialTheme.typography.bodySmall)
        if (!state.linked) {
            Text("On the PC: Android → Pair or manage Android phone → Create pairing code. Paste it below, then confirm the device on the PC.", style = MaterialTheme.typography.bodyMedium)
            OutlinedTextField(invitation, { if (it.length <= 2200) invitation = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Pairing code · رمز الاقتران") }, maxLines = 5)
            Button(onClick = { controller.pair(invitation); invitation = ""; keyboard?.hide(); focus.clearFocus() }, enabled = ownerId != null && invitation.isNotBlank() && !state.busy) { Text("Pair · اقتران") }
            if (state.phase == "pairing") Text("Confirm this device on the PC · وافق على الجهاز من الكمبيوتر")
        } else {
            Text(state.endpoint, style = MaterialTheme.typography.labelSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { controller.poll() }, enabled = !state.busy) { Text("Reconnect · اتصال") }
                OutlinedButton(onClick = { controller.unlink() }, enabled = !state.busy) { Text("Unpair · فك الاقتران") }
            }
        }
        if (state.error.isNotEmpty()) SelectionContainer { Text(state.error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(bottom = 12.dp)) {
            val run = state.run
            val events = run?.optJSONArray("events")
            if (events != null) items(events.length(), key = { "event-${events.optJSONObject(it)?.optInt("seq") ?: it}" }) { index ->
                val row = events.optJSONObject(index)
                SelectionContainer { Text("${row?.optString("title").orEmpty()}\n${row?.optString("text").orEmpty()}", style = MaterialTheme.typography.bodyMedium) }
            }
            run?.optJSONObject("approval")?.let { approval -> item("approval-${approval.optString("id")}") {
                Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(approval.optString("title"), style = MaterialTheme.typography.titleMedium)
                        SelectionContainer { Text(approval.optString("detail"), style = MaterialTheme.typography.bodySmall) }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { controller.control("approval", approval, "once") }, enabled = !state.busy) { Text("Allow once · سماح مرة") }
                            OutlinedButton(onClick = { controller.control("approval", approval, "deny") }, enabled = !state.busy) { Text("Deny · رفض") }
                        }
                    }
                }
            } }
            if (!run?.optString("summary").isNullOrBlank()) item("summary") { SelectionContainer { Text(run!!.optString("summary")) } }
            item("phase") { Text(state.phase, style = MaterialTheme.typography.labelSmall) }
        }
        if (state.run?.optBoolean("active") == true || state.phase == "disconnected") Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { controller.control("stop") }, enabled = !state.busy) { Text("Stop · إيقاف") }
            OutlinedButton(onClick = { controller.control(if (state.phase == "paused") "resume" else "pause") }, enabled = !state.busy) { Text(if (state.phase == "paused") "Resume · استئناف" else "Pause · تعليق") }
        }
        if (state.pendingStart) Button(onClick = { controller.start("") }, enabled = !state.busy) { Text("Recover same request · استعادة نفس الطلب") }
        if (state.linked && !state.pendingStart) Row(Modifier.imePadding(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(task, { if (it.length <= 12000) task = it }, modifier = Modifier.weight(1f), placeholder = { Text("Task for this PC · مهمة للكمبيوتر") }, maxLines = 4, shape = MaterialTheme.shapes.extraLarge)
            Button(onClick = { controller.start(task); task = ""; keyboard?.hide(); focus.clearFocus() }, enabled = task.isNotBlank() && !state.busy && state.run?.optBoolean("active") != true) { Text("↑") }
        }
    }
}
