package com.firas.ai.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.firas.ai.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable fun StudioScreen(state: RepositoryState, create: (MediaCommand) -> Unit, open: (MediaItem) -> Unit) {
    val ar = LocalArabic.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var kind by rememberSaveable { mutableStateOf(MediaKind.IMAGE) }
    var prompt by rememberSaveable { mutableStateOf("") }
    var lyrics by rememberSaveable { mutableStateOf("") }
    var reference by remember { mutableStateOf<Attachment?>(null) }
    var edit by rememberSaveable { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            loading = true
            try { reference = AttachmentReader.read(context, listOf(uri)).firstOrNull { it.isImage } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { error = if (ar) "تعذر قراءة الصورة. جرّب صورة أخرى." else "Could not read this image. Try another." }
            finally { loading = false }
        }
    }
    val active = state.jobs.filter { !it.terminal && it.kind in setOf("image", "video", "music") }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                MediaKind.entries.forEach { value -> FilterChip(selected = kind == value, onClick = { kind = value }, label = {
                    Text(when (value) { MediaKind.IMAGE -> if (ar) "صورة" else "Image"; MediaKind.VIDEO -> if (ar) "فيديو" else "Video"; MediaKind.MUSIC -> if (ar) "أغنية" else "Song" })
                }) }
            }
        }
        item { OutlinedTextField(prompt, { prompt = it }, label = { Text(if (ar) "صف ما تريد صنعه" else "Describe what you want to create") }, minLines = 3, maxLines = 8, modifier = Modifier.fillMaxWidth()) }
        if (kind == MediaKind.MUSIC) item { OutlinedTextField(lyrics, { lyrics = it }, label = { Text(if (ar) "كلمات الأغنية — اختياري" else "Lyrics — optional") }, minLines = 3, maxLines = 8, modifier = Modifier.fillMaxWidth()) }
        if (kind != MediaKind.MUSIC) item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = { picker.launch("image/*") }, enabled = !loading) { Icon(Icons.Outlined.AddPhotoAlternate, null); Text(if (ar) "صورة مرجعية" else "Reference image") }
                reference?.let { TextButton(onClick = { reference = null; edit = false }) { Text(if (ar) "إزالة" else "Remove") } }
            }
            reference?.let { Text(it.name, color = LocalPalette.current.secondary) }
            if (kind == MediaKind.IMAGE && reference != null) Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(edit, { edit = it }); Text(if (ar) "تعديل الصورة المرفقة" else "Edit attached image")
            }
        }
        error?.let { message -> item { Text(message, color = MaterialTheme.colorScheme.error) } }
        item {
            Button(onClick = {
                error = null
                create(MediaCommand(kind, prompt.trim(), lyrics = if (kind == MediaKind.MUSIC) lyrics else "", seconds = if (kind == MediaKind.VIDEO) 5 else 60,
                    image = if (kind == MediaKind.MUSIC) null else reference, edit = kind == MediaKind.IMAGE && edit && reference != null))
            }, enabled = prompt.isNotBlank() && !loading && active.isEmpty(), modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(if (ar) "إنشاء" else "Create")
            }
        }
        items(active, key = { "job-${it.id}" }) { job ->
            Surface(shape = MaterialTheme.shapes.large, color = LocalPalette.current.surface) {
                Row(Modifier.fillMaxWidth().padding(18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                    Text(when (job.kind) { "music" -> if (ar) "يتم تلحين الأغنية…" else "Composing your song…"; "video" -> if (ar) "يتم صنع الفيديو…" else "Creating your video…"; else -> if (ar) "يتم صنع الصورة…" else "Creating your image…" })
                }
            }
        }
        item { Text(if (ar) "أعمالك" else "Your creations", style = MaterialTheme.typography.titleLarge) }
        items(state.media.filter { it.ownerId == state.session.ownerId }.sortedByDescending { it.createdAt }, key = { it.id }) { media ->
            ListItem(headlineContent = { Text(media.title) }, supportingContent = { Text(when (media.kind) {
                MediaKind.IMAGE -> if (ar) "صورة" else "Image"; MediaKind.VIDEO -> if (ar) "فيديو" else "Video"; MediaKind.MUSIC -> if (ar) "أغنية" else "Song"
            }) }, leadingContent = { Icon(when (media.kind) { MediaKind.IMAGE -> Icons.Outlined.Image; MediaKind.VIDEO -> Icons.Outlined.Movie; MediaKind.MUSIC -> Icons.Outlined.MusicNote }, null) },
                trailingContent = { Icon(Icons.Outlined.OpenInFull, if (ar) "عرض" else "Open") }, modifier = Modifier.clickable { open(media) },
                colors = ListItemDefaults.colors(containerColor = LocalPalette.current.surface))
        }
    }
}
