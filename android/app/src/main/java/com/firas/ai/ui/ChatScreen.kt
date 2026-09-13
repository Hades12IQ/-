package com.firas.ai.ui

import android.net.Uri
import android.content.Context
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.firas.ai.data.*
import com.firas.ai.documents.AuthoredDocument
import com.firas.ai.render.RichMessage
import com.firas.ai.ui.glass.GlassSurface
import com.firas.ai.ui.glass.LocalGlassState
import dev.chrisbanes.haze.hazeSource
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import org.json.JSONObject

data class ChatActions(val send: (String, List<Uri>, String, Boolean) -> Unit, val stop: (String) -> Unit,
    val export: (ChatMessage, String) -> Unit, val translate: (String) -> Unit,
    val speak: (String) -> Unit, val link: (String) -> Unit, val voice: () -> Unit,
    val openArtifact: (Artifact) -> Unit = {},
    val approve: (JobState, String, String) -> Unit = { _, _, _ -> },
    val openDocument: (NativeDocument) -> Unit = {},
    val openMedia: (MediaItem) -> Unit = {})

@Composable fun ChatScreen(thread: ChatThread?, jobs: List<JobState>, actions: ChatActions, media: List<MediaItem> = emptyList(),
    sessionOwnerId: String? = thread?.ownerId, sessionEpoch: Long = 0) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    val scope = rememberCoroutineScope()
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    val clipboard = LocalClipboardManager.current
    val list = rememberLazyListState()
    val haze = LocalGlassState.current
    val density = LocalDensity.current
    val context = LocalContext.current.applicationContext
    val modelPreferences = remember(context) { context.getSharedPreferences("native-model-selection", Context.MODE_PRIVATE) }
    val modelPreferenceKey = remember(sessionOwnerId, thread?.product) {
        sessionOwnerId?.takeIf { it.isNotBlank() }?.let { "tier:${it.length}:$it:${(thread?.product ?: Product.AI).name}" }
    }
    val inputFocus = remember { FocusRequester() }
    var composerHeight by remember { mutableIntStateOf(160) }
    val composerInset = with(density) { composerHeight.toDp() }
    var draft by rememberSaveable(thread?.id, sessionOwnerId, sessionEpoch) { mutableStateOf("") }
    var quote by remember(thread?.id, sessionOwnerId, sessionEpoch) { mutableStateOf("") }
    var attachments by remember(thread?.id, sessionOwnerId, sessionEpoch) { mutableStateOf(emptyList<Uri>()) }
    var tier by rememberSaveable(thread?.id, sessionOwnerId, sessionEpoch, thread?.product) {
        val lastTier = thread?.messages?.lastOrNull { message -> FirasModelTier.entries.any { it.wire == message.tier } }?.tier
        val savedTier = modelPreferenceKey?.let { modelPreferences.getString(it, null) }
            ?.takeIf { value -> FirasModelTier.entries.any { it.wire == value } }
        mutableStateOf(lastTier ?: savedTier ?: FirasModelTier.NOVA.wire)
    }
    var menu by remember(thread?.id, sessionOwnerId, sessionEpoch) { mutableStateOf<ComposerSheet?>(null) }
    var thinking by rememberSaveable(thread?.id, sessionOwnerId, sessionEpoch) {
        mutableStateOf(modelPreferenceKey?.let { modelPreferences.getBoolean("think:$it", false) } ?: false)
    }
    val selectedTier = FirasModelTier.entries.firstOrNull { it.wire == tier } ?: FirasModelTier.NOVA
    val snackbar = remember { SnackbarHostState() }
    val attachmentOwnerKey = sessionOwnerId?.let { "${it.length}:$it:$sessionEpoch:${thread?.id.orEmpty()}" }
    val picker = rememberComposerAttachmentPicker(attachmentOwnerKey, onPicked = { picked ->
        val combined = (attachments + picked).distinct()
        if (combined.size <= 8) attachments = combined
        else {
            discardComposerCaptures(context, picked.filterNot { it in attachments })
            scope.launch { snackbar.showSnackbar(if (ar) "الحد ثمانية مرفقات. أزل مرفقاً قبل إضافة المزيد." else "Eight attachments maximum. Remove an attachment before adding more.") }
        }
    }, onError = { message -> scope.launch { snackbar.showSnackbar(message) } })
    var follow by remember(thread?.id) { mutableStateOf(true) }
    var sendRevision by remember { mutableIntStateOf(0) }
    val messages = thread?.messages.orEmpty()
    val jobsByTurn = remember(jobs, thread?.id, thread?.ownerId) {
        jobs.filter { it.threadId == thread?.id && it.ownerId == thread?.ownerId }.groupBy { it.cid }
    }
    val running = jobs.firstOrNull { it.threadId == thread?.id && !it.terminal }
    val tail = messages.lastOrNull()
    val tailFiles = tail?.cid?.let { jobsByTurn[it] }.orEmpty().flatMap { it.files }
    val atBottom by remember { derivedStateOf {
        val info = list.layoutInfo
        val last = info.visibleItemsInfo.lastOrNull()
        last == null || !list.canScrollForward || (last.index == info.totalItemsCount - 1 &&
            last.offset + last.size <= info.viewportEndOffset - info.afterContentPadding + 32)
    } }
    LaunchedEffect(list, thread?.id) {
        snapshotFlow { list.isScrollInProgress to atBottom }.distinctUntilChanged().collect { (scrolling, bottom) ->
            if (scrolling) follow = bottom
        }
    }
    LaunchedEffect(thread?.id, messages.size, tail?.content, tailFiles, sendRevision) {
        if (follow) {
            withFrameNanos { }
            if (list.layoutInfo.totalItemsCount > 0) list.scrollToItem(list.layoutInfo.totalItemsCount - 1)
        }
    }
    fun latest(animated: Boolean = true) {
        follow = true
        scope.launch {
            withFrameNanos { }
            if (list.layoutInfo.totalItemsCount == 0) return@launch
            val end = list.layoutInfo.totalItemsCount - 1
            if (animated) list.animateScrollToItem(end) else list.scrollToItem(end)
            follow = true
        }
    }
    Box(Modifier.fillMaxSize().imePadding()) {
        Box(Modifier.fillMaxSize()) {
            LazyColumn(state = list, modifier = Modifier.fillMaxSize().testTag("chat-transcript")
                .then(if (haze != null) Modifier.hazeSource(haze) else Modifier),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 20.dp, bottom = composerInset + 16.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                if (messages.isEmpty()) item(key = "welcome") {
                    Column(Modifier.fillMaxWidth().padding(top = 52.dp, bottom = 36.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        FirasMark()
                        Spacer(Modifier.height(20.dp))
                        Text(when(thread?.product) {
                            Product.CODE -> if(ar) "من الفكرة إلى مشروعك." else "From idea to your project."
                            Product.BRAIN -> if(ar) "افهم مصادرَك بعمق." else "Understand your sources."
                            Product.AGENT -> if(ar) "ما المهمة التي ننجزها؟" else "What shall we get done?"
                            else -> if(ar) "بماذا نفكر اليوم؟" else "What is on your mind?"
                        }, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
                        Text(if(ar) "اكتب طلبك أو أرفق ملفاً للبدء." else "Write a request or attach a file to begin.",
                            color = p.secondary, modifier = Modifier.widthIn(max = 380.dp).padding(top = 12.dp), textAlign = TextAlign.Center)
                    }
                }
                items(messages, key = { "${it.role}:${it.id}" }) { message ->
                    if (message.role == "user") {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            Surface(shape = RoundedCornerShape(24.dp), color = p.bubble,
                                modifier = Modifier.widthIn(max = 560.dp).fillMaxWidth(.9f)) {
                                SelectionContainer { Text(message.visibleContent, Modifier.padding(horizontal = 18.dp, vertical = 14.dp),
                                    style = MaterialTheme.typography.bodyLarge.copy(textDirection = if (ar) TextDirection.ContentOrRtl else TextDirection.ContentOrLtr)) }
                            }
                        }
                    } else {
                        Column(Modifier.fillMaxWidth()) {
                            val content = message.visibleContent
                            val document = remember(content) { AuthoredDocument.extract(content) }
                            val nativeDocument = remember(content) { message.nativeArtifact }
                            val streaming = message.status in setOf(MessageStatus.PREPARING, MessageStatus.STREAMING)
                            val visible = remember(content) { AuthoredDocument.visibleMessage(content) }
                            if (visible.isNotBlank()) RichMessage(content = visible, streaming = streaming,
                                modifier = Modifier.fillMaxWidth(), ink = p.ink, accent = p.accent, background = p.ground,
                                cacheScope = thread?.ownerId.orEmpty(), persistMath = thread?.temporary != true,
                                onAskSelection = { quote = it; inputFocus.requestFocus() }, onLink = actions.link)
                            if (nativeDocument != null) {
                                ChatNativeDocumentCard(nativeDocument, actions.openDocument) {
                                    quote = if (ar) "تعديل الملف: ${nativeDocument.filename}" else "Revise document: ${nativeDocument.filename}"
                                    inputFocus.requestFocus()
                                }
                            } else if (document != null) {
                                Surface(color = p.surface, shape = RoundedCornerShape(20.dp), border = BorderStroke(1.dp,p.border),
                                    modifier = Modifier.fillMaxWidth().padding(top = 10.dp)) {
                                    Column(Modifier.padding(18.dp)) {
                                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                            Icon(Icons.Outlined.Description, null, tint = p.accent)
                                            Column(Modifier.weight(1f)) {
                                                Text(document.title.ifBlank { document.filename }, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                                Text("PDF", style = MaterialTheme.typography.labelMedium, color = p.secondary)
                                            }
                                        }
                                        Button(onClick = { actions.export(message, messages.lastOrNull { it.role == "user" }?.content.orEmpty()) },
                                            enabled = message.status == MessageStatus.COMPLETE, modifier = Modifier.padding(top = 12.dp).heightIn(min = 48.dp)) {
                                            Text(if(ar) "فتح الملف" else "Open document")
                                        }
                                        TextButton(onClick = { quote = if(ar) "تعديل الملف: ${document.filename}" else "Revise document: ${document.filename}" }) {
                                            Text(if(ar) "طلب تعديل" else "Request changes")
                                        }
                                    }
                                }
                            } else if (AuthoredDocument.hasIncomplete(content)) {
                                Text(if(ar) "جارٍ إعداد الملف…" else "Preparing the document…", color = p.secondary)
                            }
                            val turnJobs = jobsByTurn[message.cid].orEmpty()
                            turnJobs.flatMap { it.files }.distinctBy {
                                it.url.ifBlank { "${it.jobId}:${it.index}:${it.name}" }
                            }.forEach { artifact ->
                                ChatArtifactCard(artifact, actions.openArtifact)
                            }
                            turnJobs.filter { it.transportKind == "omnix" && !it.terminal }.forEach { job ->
                                ChatApprovalCard(job, actions.approve)
                            }
                            val turnMedia = remember(content, message.cid, thread?.id, thread?.ownerId, turnJobs, media) {
                                chatMediaForTurn(message, thread, turnJobs, media)
                            }
                            turnMedia.forEach { item -> ChatMediaCard(item, actions.openMedia) }
                            if (streaming && visible.isBlank() && document == null && nativeDocument == null) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    CircularProgressIndicator(Modifier.size(15.dp), strokeWidth = 2.dp)
                                    Text(if(ar) "فراس يعمل…" else "Firas is working…", color = p.secondary)
                                }
                            }
                            message.notice?.let { Text(it.text(if(ar) "ar" else "en"), color = MaterialTheme.colorScheme.error) }
                            if (!streaming && content.isNotBlank()) Row {
                                IconButton(onClick = { clipboard.setText(AnnotatedString(visible)); }) { Icon(Icons.Outlined.ContentCopy, if(ar) "نسخ الرد" else "Copy reply", tint = p.secondary) }
                                IconButton(onClick = { actions.translate(visible) }) { Icon(Icons.Outlined.Translate, if(ar) "ترجمة" else "Translate", tint = p.secondary) }
                                IconButton(onClick = { actions.speak(visible) }) { Icon(Icons.Outlined.VolumeUp, if(ar) "قراءة" else "Read aloud", tint = p.secondary) }
                            }
                        }
                    }
                }
                item(key = "end") { Spacer(Modifier.height(1.dp)) }
            }
            if (messages.isNotEmpty() && !atBottom) GlassSurface(Modifier.align(Alignment.BottomCenter).padding(bottom = composerInset + 12.dp), shape = CircleShape) {
                IconButton(onClick = { latest() }, modifier = Modifier.size(48.dp)) {
                    Icon(Icons.Outlined.ArrowDownward, if(ar) "الانتقال إلى الأحدث" else "Jump to latest", tint = p.ink)
                }
            }
        }
        Column(Modifier.align(Alignment.BottomCenter).widthIn(max = 780.dp).fillMaxWidth()
            .onSizeChanged { composerHeight = it.height }) {
        if (quote.isNotBlank()) Surface(color = p.surface, shape = RoundedCornerShape(14.dp), modifier = Modifier.padding(horizontal = 14.dp)) {
            Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(quote, Modifier.weight(1f), maxLines = 3, overflow = TextOverflow.Ellipsis, color = p.secondary)
                IconButton(onClick = { quote = "" }) { Icon(Icons.Outlined.Close, if(ar) "إزالة المقتطف" else "Remove quotation") }
            }
        }
        if (attachments.isNotEmpty()) Row(Modifier.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if(ar) "مرفقات: ${attachments.size}" else "${attachments.size} attachments", Modifier.weight(1f), color = p.secondary)
            TextButton(onClick = { discardComposerCaptures(context, attachments); attachments = emptyList() }) { Text(if(ar) "إزالة" else "Remove") }
        }
        GlassSurface(shape = RoundedCornerShape(24.dp),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp).then(if(thread?.temporary == true) Modifier.drawWithContent {
                drawContent()
                drawRoundRect(p.accent, cornerRadius = androidx.compose.ui.geometry.CornerRadius(24.dp.toPx()), style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(9.dp.toPx(), 7.dp.toPx()))))
            } else Modifier)) {
            Column(Modifier.padding(8.dp)) {
                BasicTextField(value = draft, onValueChange = { draft = it },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 14.dp, vertical = 12.dp)
                        .focusRequester(inputFocus).testTag("composer-input"),
                    minLines = 1, maxLines = 7, cursorBrush = SolidColor(p.accent),
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = p.ink,
                        textDirection = if (ar) TextDirection.ContentOrRtl else TextDirection.ContentOrLtr),
                    decorationBox = { inner -> Box(Modifier.fillMaxWidth()) {
                        if (draft.isEmpty()) Text(if(ar) "اسأل فراس…" else "Ask Firas…",
                            Modifier.fillMaxWidth(), color = p.secondary.copy(alpha = .75f),
                            style = MaterialTheme.typography.bodyLarge, textAlign = if (ar) TextAlign.Right else TextAlign.Left)
                        inner()
                    } })
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box {
                        IconButton(onClick = { focus.clearFocus(); keyboard?.hide(); menu = ComposerSheet.ADD },
                            modifier = Modifier.size(48.dp).testTag("composer-add")) {
                            Icon(Icons.Outlined.Add, if(ar) "إضافة مرفقات وأدوات" else "Attachments and tools", tint = p.ink)
                        }
                        if (attachments.isNotEmpty()) Badge(Modifier.align(Alignment.TopEnd).padding(3.dp), containerColor = p.accent,
                            contentColor = if (p.light) Color.White else p.ground) { Text(attachments.size.toString()) }
                    }
                    Box {
                        TextButton(onClick = { focus.clearFocus(); keyboard?.hide(); menu = ComposerSheet.MODELS }, modifier = Modifier.testTag("model-picker"),
                            shape = RoundedCornerShape(50), border = BorderStroke(1.dp, p.border),
                            colors = ButtonDefaults.textButtonColors(contentColor = p.ink),
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)) {
                            ModelSymbol(selectedTier, Modifier.padding(end = 6.dp).size(19.dp))
                            Text(selectedTier.label,
                                style = MaterialTheme.typography.labelLarge, maxLines = 1)
                            Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.padding(start = 4.dp).size(18.dp), tint = p.secondary)
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = actions.voice) { Icon(Icons.Outlined.Mic, if(ar) "محادثة صوتية" else "Voice conversation") }
                    if (running?.canCancel == true) FilledIconButton(onClick = { actions.stop(running.id) }, modifier = Modifier.testTag("stop-message")) { Icon(Icons.Outlined.Stop, if(ar) "إيقاف" else "Stop") }
                    else FilledIconButton(enabled = draft.isNotBlank() || attachments.isNotEmpty(), modifier = Modifier.testTag("send-message"), onClick = {
                        val question = if(quote.isNotBlank()) "> ${quote.replace("\n", "\n> ")}\n\n$draft" else draft
                        val files = attachments
                        draft = ""; quote = ""; attachments = emptyList(); follow = true; sendRevision++
                        focus.clearFocus(); keyboard?.hide(); actions.send(question, files, tier, thinking && selectedTier.supportsThinking); latest(false)
                    }) { Icon(Icons.Outlined.ArrowUpward, if(ar) "إرسال" else "Send") }
                }
            }
        }
        Text(if (ar) "قد يخطئ فراس. تحقّق من المعلومات المهمة." else "Firas can make mistakes. Check important information.",
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 8.dp),
            textAlign = TextAlign.Center, color = p.secondary, style = MaterialTheme.typography.labelMedium)
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.TopCenter).padding(16.dp))
    }
    menu?.let { page ->
        ComposerMenuSheet(page, selectedTier, thinking, onThinking = { value ->
            thinking = value
            modelPreferenceKey?.let { modelPreferences.edit().putBoolean("think:$it", value).apply() }
        }, onModel = { option ->
            tier = option.wire
            modelPreferenceKey?.let { modelPreferences.edit().putString(it, option.wire).apply() }
        }, onDismiss = { menu = null }, onModels = { menu = ComposerSheet.MODELS },
            onPhotos = picker.photos, onFiles = picker.files, onCamera = picker.camera.takeIf { picker.cameraAvailable }, onVoice = actions.voice)
    }
}

private val chatMediaFence = Regex("(?ms)^\\s*```firas-(image|video|music|song)[ \\t]*\\r?\\n(.*?)\\r?\\n[ \\t]*```[ \\t]*(?:\\r?\\n|$)")

/** Fence metadata may select a real account-owned media row; it never creates one or supplies a URL. */
internal fun chatMediaForTurn(message: ChatMessage, thread: ChatThread?, jobs: List<JobState>, media: List<MediaItem>): List<MediaItem> {
    if (thread == null || message.role != "assistant") return emptyList()
    val references = chatMediaFence.findAll(message.visibleContent).mapNotNull { match ->
        val json = runCatching { JSONObject(match.groupValues[2]) }.getOrNull() ?: return@mapNotNull null
        val kind = when (match.groupValues[1]) { "image" -> MediaKind.IMAGE; "video" -> MediaKind.VIDEO; else -> MediaKind.MUSIC }
        Triple(kind, json.optString("key"), json.optString("jobId"))
            .takeIf { it.second.isNotBlank() && it.third.isNotBlank() }
    }.toList()
    val turnJobs = jobs.filter { it.ownerId == thread.ownerId && it.threadId == thread.id && it.cid == message.cid }
    return media.filter { item ->
        item.ownerId == thread.ownerId && item.threadId == thread.id && (
            turnJobs.any { it.id == item.id && it.kind == item.kind.wire && it.mediaKey == item.key } ||
            references.any { it.first == item.kind && it.second == item.key && it.third == item.id })
    }.distinctBy { it.kind to it.key }
}

@Composable
private fun ChatMediaCard(item: MediaItem, open: (MediaItem) -> Unit) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    val label = when (item.kind) {
        MediaKind.IMAGE -> if (ar) "صورة" else "Image"
        MediaKind.VIDEO -> if (ar) "فيديو" else "Video"
        MediaKind.MUSIC -> if (ar) "أغنية" else "Song"
    }
    Surface(color = p.surface, shape = RoundedCornerShape(20.dp), border = BorderStroke(1.dp, p.border),
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp).testTag("media-card")) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(when (item.kind) { MediaKind.IMAGE -> Icons.Outlined.Image; MediaKind.VIDEO -> Icons.Outlined.Movie; MediaKind.MUSIC -> Icons.Outlined.MusicNote },
                    null, tint = p.accent)
                Column(Modifier.weight(1f)) {
                    Text(item.title.ifBlank { label }, maxLines = 3, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.titleMedium.copy(textDirection = if (ar) TextDirection.ContentOrRtl else TextDirection.ContentOrLtr))
                    Text(label, style = MaterialTheme.typography.labelMedium, color = p.secondary)
                }
            }
            Button(onClick = { open(item) }, modifier = Modifier.padding(top = 12.dp).heightIn(min = 48.dp).testTag("open-media")) {
                Icon(if (item.kind == MediaKind.IMAGE) Icons.Outlined.OpenInNew else Icons.Outlined.PlayArrow,
                    null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (item.kind == MediaKind.IMAGE) { if (ar) "عرض الصورة" else "View image" }
                    else { if (ar) "تشغيل" else "Play" })
            }
        }
    }
}

@Composable
private fun ChatNativeDocumentCard(document: NativeDocument, open: (NativeDocument) -> Unit, revise: () -> Unit) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    val context = LocalContext.current
    val size = remember(document.pdfBytes, context) { android.text.format.Formatter.formatShortFileSize(context, document.pdfBytes) }
    Surface(color = p.surface, shape = RoundedCornerShape(20.dp), border = BorderStroke(1.dp, p.border),
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp).testTag("native-document-card")) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.Description, null, tint = p.accent)
                Column(Modifier.weight(1f)) {
                    Text(document.title.ifBlank { document.filename }, maxLines = 3, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.titleMedium.copy(textDirection = if (ar) TextDirection.ContentOrRtl else TextDirection.ContentOrLtr))
                    if (document.title.isNotBlank() && document.title != document.filename) Text(document.filename,
                        maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium,
                        color = p.secondary)
                    Text(if (ar) "PDF · \u2068${document.pageCount} صفحة\u2069 · \u2066$size\u2069" else "PDF · ${document.pageCount} pages · $size",
                        style = MaterialTheme.typography.labelMedium, color = p.secondary)
                    if (document.partial) {
                        Text(if (ar) "نسخة جزئية" else "Partial document", style = MaterialTheme.typography.labelMedium, color = p.accent)
                        if (document.expectedItems > 0 && document.completedItems > 0) Text(
                            if (ar) "أُنجز ${document.completedItems} من ${document.expectedItems} · المتبقي ${document.remainingItems}"
                            else "${document.completedItems} of ${document.expectedItems} completed · ${document.remainingItems} remaining",
                            style = MaterialTheme.typography.labelMedium, color = p.secondary)
                    }
                }
            }
            // A validated artifact is usable even if a larger request has stopped or is still continuing.
            Button(onClick = { open(document) }, modifier = Modifier.padding(top = 12.dp).heightIn(min = 48.dp)
                .testTag("open-native-document")) {
                Icon(Icons.Outlined.OpenInNew, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (ar) "فتح الملف" else "Open document")
            }
            TextButton(onClick = revise, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(if (ar) "طلب تعديل" else "Request changes")
            }
        }
    }
}

@Composable
private fun ChatArtifactCard(artifact: Artifact, open: (Artifact) -> Unit) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    Surface(color = p.surface, shape = RoundedCornerShape(20.dp), border = BorderStroke(1.dp, p.border),
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp).testTag("artifact-card")) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.Description, null, tint = p.accent)
                Column(Modifier.weight(1f)) {
                    Text(artifact.name, maxLines = 3, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.titleMedium.copy(textDirection = TextDirection.ContentOrLtr))
                    val type = artifact.type.ifBlank { artifact.name.substringAfterLast('.', "").uppercase() }
                    if (type.isNotBlank()) Text(type, style = MaterialTheme.typography.labelMedium, color = p.secondary)
                }
            }
            Button(onClick = { open(artifact) }, modifier = Modifier.padding(top = 12.dp).heightIn(min = 48.dp)
                .testTag("open-artifact")) {
                Icon(Icons.Outlined.OpenInNew, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (ar) "فتح الملف" else "Open file")
            }
        }
    }
}

@Composable
private fun ChatApprovalCard(job: JobState, approve: (JobState, String, String) -> Unit) {
    val approval = remember(job.progress) { OmnixProtocol.approval(job) } ?: return
    val requestId = approval.optString("requestId")
    val advertised = approval.optJSONArray("choices") ?: return
    val choices = (0 until advertised.length()).map { advertised.optString(it) }
        .filter { it == "once" || it == "deny" }.distinct()
    if (requestId.isBlank() || choices.isEmpty()) return
    val p = LocalPalette.current
    val ar = LocalArabic.current
    val command = approval.optString("command")
    val reason = approval.optString("reason")
    Surface(color = p.surface, shape = RoundedCornerShape(20.dp), border = BorderStroke(1.dp, p.border),
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp).testTag("omnix-approval")) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(if (ar) "موافقتك مطلوبة" else "Your approval is needed", style = MaterialTheme.typography.titleMedium)
            if (reason.isNotBlank()) Text(reason, style = MaterialTheme.typography.bodyLarge.copy(
                textDirection = if (ar) TextDirection.ContentOrRtl else TextDirection.ContentOrLtr))
            if (command.isNotBlank()) SelectionContainer {
                Text(command, Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, textDirection = TextDirection.Ltr))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if ("once" in choices) Button(onClick = { approve(job, requestId, "once") },
                    enabled = approval.optBoolean("commandComplete") && command.isNotBlank(),
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("approve-once")) {
                    Text(if (ar) "السماح مرة واحدة" else "Allow once")
                }
                if ("deny" in choices) OutlinedButton(onClick = { approve(job, requestId, "deny") },
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("approve-deny")) {
                    Text(if (ar) "رفض" else "Deny")
                }
            }
        }
    }
}
