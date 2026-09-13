package com.firas.ai.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.firas.ai.data.*
import com.firas.ai.ui.glass.GlassSurface
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** An editor beside the existing Code conversation; requests still use its actual selected model. */
@Composable fun CodeWorkspaceScreen(
    thread: ChatThread,
    repository: FirasRepository,
    onBack: () -> Unit,
    onExport: (File, String) -> Unit,
    initialTier: String = thread.messages.lastOrNull()?.tier ?: "pro",
) {
    val state by repository.state.collectAsState()
    key(thread.ownerId, thread.id, state.session.epoch) {
        val session = remember { runCatching { repository.codeWorkspaceSession(thread) }.getOrNull() }
        if (session != null && session.accepts(state)) {
            CodeWorkspaceContent(session, state.activeThread ?: thread, repository, state, onBack, onExport, initialTier)
        } else Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(tr("افتح محادثة محفوظة في فراس كود لاستخدام مساحة الملفات.", "Open a saved Firas Code conversation to use the workspace."))
            Button(onClick = onBack) { Text(tr("رجوع", "Back")) }
        }
    }
}

@Composable private fun CodeWorkspaceContent(
    session: CodeWorkspaceSession, thread: ChatThread, repository: FirasRepository, state: RepositoryState,
    onBack: () -> Unit, onExport: (File, String) -> Unit, initialTier: String,
) {
    val ar = LocalArabic.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var saved by remember { mutableStateOf(CodeWorkspace()) }
    var draft by remember { mutableStateOf(CodeWorkspace()) }
    var selectedPath by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var review by remember { mutableStateOf<CodeWorkspaceReview?>(null) }
    var newFile by remember { mutableStateOf(false) }
    var newPath by remember { mutableStateOf("") }
    var deleteFile by remember { mutableStateOf(false) }
    var leaving by remember { mutableStateOf(false) }
    var answersMenu by remember { mutableStateOf(false) }
    var modelsMenu by remember { mutableStateOf(false) }
    var tier by remember { mutableStateOf(FirasModelTier.entries.firstOrNull { it.wire == initialTier } ?: FirasModelTier.NOVA) }
    var prompt by remember { mutableStateOf("") }
    val dirty = draft != saved
    val active = state.jobs.any { it.ownerId == session.ownerId && it.threadId == session.threadId && !it.terminal }
    val editorFile = draft.files.firstOrNull { it.path == selectedPath }
    val answers = thread.messages.filter { it.role == "assistant" && it.status == MessageStatus.COMPLETE && it.visibleContent.isNotBlank() }.asReversed()
    fun current() = session.accepts(repository.state.value)
    fun failure(error: Exception) {
        if (error is CancellationException) throw error
        if (!current()) return
        message = when (error) {
            is CodeWorkspaceFailure -> error.notice.text(if (ar) "ar" else "en")
            is FirasFailure -> error.notice.text(if (ar) "ar" else "en")
            else -> if (ar) "تعذرت العملية. ملفاتك الحالية محفوظة دون تغيير." else "The operation could not finish. Your saved files are unchanged."
        }
    }
    fun requestBack() { if (dirty) leaving = true else onBack() }
    LaunchedEffect(session) {
        try {
            val value = repository.loadCodeWorkspace(session)
            if (current()) { saved = value; draft = value; selectedPath = value.files.firstOrNull()?.path; loaded = true }
        } catch (error: Exception) { failure(error) }
    }
    BackHandler { if (review != null) review = null else requestBack() }
    val importZip = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null && loaded && !busy && !dirty) scope.launch {
            busy = true; message = null
            val base = saved
            try {
                val incoming = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use(CodeWorkspacePolicy::readZip)
                        ?: throw java.io.IOException("Input unavailable")
                }
                if (current() && saved == base) review = CodeWorkspacePolicy.review(base, incoming.files, if (ar) "استيراد ZIP" else "Import ZIP")
            } catch (error: Exception) { failure(error) }
            finally { busy = false }
        }
    }
    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        GlassSurface(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = ::requestBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, if (ar) "رجوع" else "Back") }
                Column(Modifier.weight(1f)) {
                    Text(if (ar) "ملفات المشروع" else "Project files", style = MaterialTheme.typography.titleMedium)
                    Text(thread.title, style = MaterialTheme.typography.labelMedium, color = LocalPalette.current.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                IconButton(onClick = { newPath = ""; newFile = true }, enabled = loaded && !busy && draft.files.size < CodeWorkspacePolicy.MAX_FILES) {
                    Icon(Icons.Outlined.NoteAdd, if (ar) "ملف جديد" else "New file")
                }
                IconButton(onClick = { importZip.launch(arrayOf("application/zip", "application/x-zip-compressed")) }, enabled = loaded && !busy && !dirty) {
                    Icon(Icons.Outlined.FileUpload, if (ar) "استيراد ZIP" else "Import ZIP")
                }
                IconButton(onClick = {
                    scope.launch {
                        busy = true; message = null
                        try { val file = repository.exportCodeWorkspace(session, saved); if (current()) onExport(file, "application/zip") }
                        catch (error: Exception) { failure(error) }
                        finally { busy = false }
                    }
                }, enabled = loaded && !busy && !dirty && saved.files.isNotEmpty()) {
                    Icon(Icons.Outlined.FileDownload, if (ar) "تصدير ZIP" else "Export ZIP")
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f)) {
                OutlinedButton(onClick = { answersMenu = true }, enabled = loaded && !busy && !dirty && answers.isNotEmpty(), modifier = Modifier.fillMaxWidth()) {
                    Text(if (ar) "مراجعة ملفات الردود" else "Review answer files", maxLines = 1)
                }
                DropdownMenu(answersMenu, { answersMenu = false }) {
                    answers.take(30).forEachIndexed { index, answer -> DropdownMenuItem(text = {
                        Column {
                            Text(if (ar) "رد ${answers.size - index}" else "Answer ${answers.size - index}")
                            Text(answer.visibleContent.lineSequence().firstOrNull { it.isNotBlank() }.orEmpty(), maxLines = 1,
                                overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall)
                        }
                    }, onClick = {
                        answersMenu = false; message = null
                        scope.launch {
                            busy = true
                            val base = saved
                            try {
                                val proposed = withContext(Dispatchers.Default) { CodeWorkspacePolicy.review(base,
                                    CodeWorkspacePolicy.namedFiles(answer.visibleContent), if (ar) "ملفات الرد" else "Answer files") }
                                if (current() && saved == base) review = proposed
                            } catch (error: Exception) { failure(error) }
                            finally { busy = false }
                        }
                    }) }
                }
            }
            if (dirty) Button(onClick = {
                scope.launch {
                    busy = true; message = null
                    val candidate = draft
                    try { val value = repository.saveCodeWorkspace(session, saved, candidate); if (current()) { saved = value; message = if (ar) "تم حفظ الملفات." else "Files saved." } }
                    catch (error: Exception) { failure(error) }
                    finally { busy = false }
                }
            }, enabled = !busy && loaded) { Text(if (ar) "حفظ" else "Save") }
        }
        if (dirty) Text(if (ar) "تعديلات غير محفوظة — احفظها قبل المراجعة أو الإرسال." else "Unsaved changes — save before reviewing or sending.",
            style = MaterialTheme.typography.labelMedium, color = LocalPalette.current.secondary)
        message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        if (busy || !loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (draft.files.isEmpty()) {
            Column(Modifier.weight(1f).fillMaxWidth(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Outlined.FolderOpen, null, Modifier.size(40.dp), tint = LocalPalette.current.accent)
                Spacer(Modifier.height(12.dp))
                Text(if (ar) "ابدأ بملف، أو استورد مشروع ZIP" else "Start with a file, or import a ZIP project")
                Text(if (ar) "Python، Kotlin، Swift وغيرها من الملفات النصية" else "Python, Kotlin, Swift and other text files",
                    style = MaterialTheme.typography.bodySmall, color = LocalPalette.current.secondary)
            }
        } else {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(draft.files, key = { it.path }) { file ->
                    FilterChip(selected = selectedPath == file.path, onClick = { selectedPath = file.path }, label = { Text(file.path, fontFamily = FontFamily.Monospace) })
                }
            }
            editorFile?.let { file ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("${file.content.length} / ${CodeWorkspacePolicy.MAX_FILE_CHARS}", Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = LocalPalette.current.secondary)
                    IconButton(onClick = { deleteFile = true }, enabled = !busy) { Icon(Icons.Outlined.DeleteOutline, if (ar) "حذف الملف" else "Delete file") }
                }
                OutlinedTextField(file.content, { value ->
                    if (value.length <= CodeWorkspacePolicy.MAX_FILE_CHARS) draft = draft.copy(files = draft.files.map { if (it.path == file.path) it.copy(content = value) else it })
                    else message = if (ar) "وصل الملف إلى حد 60,000 محرف." else "The file reached its 60,000-character limit."
                }, enabled = !busy, modifier = Modifier.weight(1f).fillMaxWidth(), textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 14.sp, textDirection = TextDirection.Ltr),
                    label = { Text(file.path, maxLines = 1, overflow = TextOverflow.Ellipsis) })
            }
        }
        GlassSurface(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
            Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                OutlinedTextField(prompt, { if (it.length <= 8000) prompt = it }, modifier = Modifier.fillMaxWidth(), maxLines = 4,
                    enabled = loaded && !busy && !active, label = { Text(if (ar) "اطلب إنشاء الملفات أو تعديل المشروع" else "Create files or revise this project") })
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Box {
                        TextButton(onClick = { modelsMenu = true }, enabled = !busy && !active) { Text(tier.label); Icon(Icons.Outlined.ExpandMore, null) }
                        DropdownMenu(modelsMenu, { modelsMenu = false }) {
                            FirasModelTier.entries.forEach { model -> DropdownMenuItem(text = { Text(model.label) }, onClick = { tier = model; modelsMenu = false }) }
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    Button(onClick = {
                        scope.launch {
                            busy = true; message = null
                            try {
                                when (val outcome = repository.sendCodeWorkspace(session, saved, prompt, tier.wire)) {
                                    is SubmissionOutcome.Refused -> if (current()) message = outcome.notice.text(if (ar) "ar" else "en")
                                    else -> if (current()) { prompt = ""; message = if (ar) "بدأ العمل. سيظهر الرد في محادثة فراس كود ويمكنك مراجعة ملفاته هنا." else "Work started. The answer will appear in Firas Code; review its files here when ready." }
                                }
                            } catch (error: Exception) { failure(error) }
                            finally { busy = false }
                        }
                    }, enabled = loaded && !busy && !dirty && !active && prompt.isNotBlank()) {
                        Text(if (active) { if (ar) "جارٍ العمل…" else "Working…" } else if (ar) "إرسال" else "Send")
                    }
                }
            }
        }
    }
    if (newFile) AlertDialog(onDismissRequest = { newFile = false }, title = { Text(if (ar) "ملف جديد" else "New file") }, text = {
        OutlinedTextField(newPath, { newPath = it }, singleLine = true, label = { Text(if (ar) "المسار، مثل src/main.py" else "Path, e.g. src/main.py") })
    }, confirmButton = { TextButton(onClick = {
        try {
            val name = CodeWorkspacePolicy.path(newPath.trim())
            draft = CodeWorkspacePolicy.validate(draft.copy(files = draft.files + CodeWorkspaceFile(name, "")))
            selectedPath = name; newFile = false; message = null
        } catch (error: Exception) { newFile = false; failure(error) }
    }) { Text(if (ar) "إضافة" else "Add") } }, dismissButton = { TextButton(onClick = { newFile = false }) { Text(if (ar) "إلغاء" else "Cancel") } })
    if (deleteFile) AlertDialog(onDismissRequest = { deleteFile = false }, title = { Text(if (ar) "حذف الملف المحدد؟" else "Delete this file?") }, text = { Text(selectedPath.orEmpty()) },
        confirmButton = { TextButton(onClick = {
            draft = draft.copy(files = draft.files.filter { it.path != selectedPath }); selectedPath = draft.files.firstOrNull()?.path; deleteFile = false
        }) { Text(if (ar) "حذف" else "Delete") } }, dismissButton = { TextButton(onClick = { deleteFile = false }) { Text(if (ar) "إلغاء" else "Cancel") } })
    if (leaving) AlertDialog(onDismissRequest = { leaving = false }, title = { Text(if (ar) "لديك تعديلات غير محفوظة" else "You have unsaved changes") },
        text = { Text(if (ar) "ارجع للمحرر لحفظها، أو اترك هذه التعديلات فقط." else "Return to the editor to save, or discard these unsaved changes.") },
        confirmButton = { TextButton(onClick = onBack) { Text(if (ar) "ترك التعديلات" else "Discard changes") } },
        dismissButton = { TextButton(onClick = { leaving = false }) { Text(if (ar) "رجوع للمحرر" else "Keep editing") } })
    review?.let { proposed -> CodeWorkspaceReviewDialog(saved, proposed, busy, { review = null }, { selected ->
        scope.launch {
            busy = true; message = null
            try {
                val candidate = CodeWorkspacePolicy.apply(saved, proposed, selected)
                val result = repository.saveCodeWorkspace(session, saved, candidate)
                if (current()) { saved = result; draft = result; selectedPath = selected.firstOrNull() ?: result.files.firstOrNull()?.path; review = null }
            } catch (error: Exception) { failure(error); review = null }
            finally { busy = false }
        }
    }) }
}

@Composable private fun CodeWorkspaceReviewDialog(base: CodeWorkspace, review: CodeWorkspaceReview, busy: Boolean,
                                                  close: () -> Unit, apply: (Set<String>) -> Unit) {
    val ar = LocalArabic.current
    var selected by remember(review) { mutableStateOf(review.writes.map { it.path }.toSet()) }
    var preview by remember(review) { mutableStateOf(review.writes.first().path) }
    androidx.compose.ui.window.Dialog(onDismissRequest = { if (!busy) close() },
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().padding(12.dp), shape = MaterialTheme.shapes.extraLarge, color = LocalPalette.current.ground) {
            Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(review.label, style = MaterialTheme.typography.titleLarge)
                Text(if (ar) "اختر الملفات وراجع المصدر قبل التطبيق. الملفات الأخرى تبقى محفوظة." else "Choose files and review their source before applying. Other files stay saved.", style = MaterialTheme.typography.bodySmall)
                LazyColumn(Modifier.heightIn(max = 180.dp)) {
                    items(review.writes, key = { it.path }) { file ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(file.path in selected, { checked -> selected = if (checked) selected + file.path else selected - file.path }, enabled = !busy)
                            TextButton(onClick = { preview = file.path }, modifier = Modifier.weight(1f)) {
                                Text(file.path, maxLines = 2, fontFamily = FontFamily.Monospace)
                            }
                            Text(if (base.files.any { it.path == file.path }) { if (ar) "تعديل" else "Change" } else if (ar) "جديد" else "New", style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(preview, fontFamily = FontFamily.Monospace, color = LocalPalette.current.accent)
                    val old = base.files.firstOrNull { it.path == preview }
                    if (old != null) {
                        Text(if (ar) "المصدر الحالي" else "Current source", style = MaterialTheme.typography.titleMedium)
                        WorkspaceSource(old.content)
                    }
                    Text(if (ar) "المصدر المقترح" else "Proposed source", style = MaterialTheme.typography.titleMedium)
                    WorkspaceSource(review.writes.first { it.path == preview }.content)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = close, enabled = !busy) { Text(if (ar) "إلغاء" else "Cancel") }
                    Button(onClick = { apply(selected) }, enabled = !busy && selected.isNotEmpty()) {
                        Text(if (ar) "تطبيق ${selected.size} ملف" else "Apply ${selected.size} files")
                    }
                }
            }
        }
    }
}
@Composable private fun WorkspaceSource(source: String) {
    Surface(color = LocalPalette.current.surface, shape = MaterialTheme.shapes.medium) {
        SelectionContainer { Text(source.ifEmpty { "∅" }, Modifier.fillMaxWidth().padding(12.dp), style = TextStyle(fontFamily = FontFamily.Monospace,
            fontSize = 13.sp, lineHeight = 20.sp, textDirection = TextDirection.Ltr)) }
    }
}
