package com.firas.ai.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.MediaItem as PlayerItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import com.firas.ai.documents.DocumentFiles
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

data class PreviewFile(val file: File, val name: String, val mime: String) {
    val contentType: String get() = mime.substringBefore(';').takeUnless { it == "application/octet-stream" }
        ?: when (name.substringAfterLast('.', "").lowercase()) {
            "pdf" -> "application/pdf"; "png" -> "image/png"; "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"; "mp4" -> "video/mp4"; "mp3" -> "audio/mpeg"; "wav" -> "audio/wav"
            else -> "application/octet-stream"
        }
}

/** One native modal owns its player and pages; closing always removes that exact modal. */
@Composable fun FilePreview(item: PreviewFile, onClose: () -> Unit) {
    val context = LocalContext.current
    val ar = LocalArabic.current
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    var notice by remember(item) { mutableStateOf<String?>(null) }
    var saving by remember(item) { mutableStateOf(false) }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(item.contentType)) { uri ->
        if (uri != null) scope.launch {
            saving = true
            try {
                withContext(Dispatchers.IO) {
                    val source = privateFile(context, item.file)
                    context.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        source.inputStream().use { it.copyTo(output) }
                    } ?: error("Destination unavailable")
                }
                notice = if (ar) "تم حفظ الملف." else "File saved."
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { notice = if (ar) "تعذر حفظ الملف. حاول مجددًا." else "Could not save this file. Try again." }
            finally { saving = false }
        }
    }
    fun openOrShare(share: Boolean) { scope.launch {
        try {
            val prepared = withContext(Dispatchers.IO) {
                val source = privateFile(context, item.file)
                val directory = File(context.cacheDir, "exports").apply { mkdirs() }
                val name = item.name.substringAfterLast('/').substringAfterLast('\\')
                    .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").take(140).ifBlank { "document" }
                File(directory, "${UUID.randomUUID()}-$name").also { source.copyTo(it, overwrite = false) }
            }
            val uri = DocumentFiles.uri(context, prepared)
            val intent = if (share) Intent(Intent.ACTION_SEND).setType(item.contentType).putExtra(Intent.EXTRA_STREAM, uri)
                else Intent(Intent.ACTION_VIEW).setDataAndType(uri, item.contentType)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.clipData = ClipData.newRawUri(item.name, uri)
            context.startActivity(if (share) Intent.createChooser(intent, item.name) else intent)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { notice = if (ar) "لا يوجد تطبيق مناسب لفتح هذا الملف أو مشاركته." else "No available app could open or share this file." }
    } }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = palette.ground) {
            Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(item.name, Modifier.weight(1f), maxLines = 2, style = MaterialTheme.typography.titleMedium)
                    IconButton(onClick = onClose, modifier = Modifier.size(48.dp)) { Icon(Icons.Outlined.Close, if (ar) "إغلاق" else "Close") }
                }
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                    TextButton(onClick = { openOrShare(false) }) { Text(if (ar) "فتح بواسطة" else "Open with") }
                    TextButton(onClick = { openOrShare(true) }) { Icon(Icons.Outlined.Share, null); Text(if (ar) "مشاركة" else "Share") }
                    TextButton(onClick = { save.launch(item.name) }, enabled = !saving) { Icon(Icons.Outlined.SaveAlt, null); Text(if (ar) "حفظ" else "Save") }
                }
                notice?.let { Text(it, Modifier.padding(12.dp), color = palette.secondary) }
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    when {
                        item.contentType == "application/pdf" -> NativePdfPreview(item.file)
                        item.contentType.startsWith("image/") -> ZoomablePicture(item.file, item.name)
                        item.contentType.startsWith("video/") || item.contentType.startsWith("audio/") -> LocalMediaPlayer(item.file)
                        else -> Text(if (ar) "استخدم فتح بواسطة أو حفظ لعرض هذا النوع." else "Use Open with or Save to view this file type.", Modifier.padding(24.dp))
                    }
                }
            }
        }
    }
}

internal fun privateFile(context: Context, source: File): File {
    val file = source.canonicalFile
    require(file.isFile && listOf(context.filesDir, context.cacheDir).any {
        file.path.startsWith(it.canonicalPath + File.separator)
    }) { "File must belong to this application" }
    return file
}

@Composable private fun NativePdfPreview(file: File) {
    val ar = LocalArabic.current
    val pages by produceState<Int?>(null, file) {
        value = withContext(Dispatchers.IO) {
            runCatching { PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)).use { it.pageCount } }.getOrDefault(-1)
        }
    }
    when {
        pages == null -> CircularProgressIndicator()
        pages!! <= 0 -> Text(if (ar) "تعذر قراءة ملف PDF." else "This PDF could not be read.")
        else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            items((0 until pages!!).toList(), key = { it }) { index ->
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    PdfPagePicture(file, index)
                    Text("${index + 1} / $pages", Modifier.padding(8.dp), style = MaterialTheme.typography.labelMedium)
                }
            }
        }
    }
}

@Composable private fun PdfPagePicture(file: File, index: Int) {
    val ar = LocalArabic.current
    val rendered by produceState<Pair<Bitmap?, Boolean>>(null to false, file, index) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)).use { renderer ->
                    renderer.openPage(index).use { page ->
                        val scale = minOf(2f, 1600f / maxOf(page.width, page.height))
                        Bitmap.createBitmap((page.width * scale).toInt().coerceAtLeast(1), (page.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888).also {
                            it.eraseColor(AndroidColor.WHITE); page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        }
                    }
                }
            }.fold(onSuccess = { it to false }, onFailure = { null to true })
        }
    }
    rendered.first?.let { page ->
        ZoomFrame(Modifier.fillMaxWidth().aspectRatio(page.width.toFloat() / page.height)) { modifier ->
            Image(page.asImageBitmap(), if (ar) "الصفحة ${index + 1}" else "Page ${index + 1}", modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
    } ?: Box(Modifier.fillMaxWidth().height(180.dp), contentAlignment = Alignment.Center) {
        Text(if (rendered.second) { if (ar) "تعذر عرض هذه الصفحة. يمكنك حفظ الملف أو فتحه بتطبيق آخر." else "This page could not be rendered. Save the file or open it in another app." }
            else if (ar) "جارٍ عرض الصفحة…" else "Loading page…")
    }
}

@Composable private fun ZoomablePicture(file: File, name: String) {
    ZoomFrame(Modifier.fillMaxSize()) { modifier -> AsyncImage(file, name, modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
}

@Composable private fun ZoomFrame(modifier: Modifier, content: @Composable (Modifier) -> Unit) {
    var zoom by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val transform = rememberTransformableState { scale, pan, _ ->
        zoom = (zoom * scale).coerceIn(1f, 5f)
        offset = if (zoom <= 1f) Offset.Zero else offset + pan
    }
    Box(modifier.clipToBounds().transformable(transform)) {
        content(Modifier.graphicsLayer { scaleX = zoom; scaleY = zoom; translationX = offset.x; translationY = offset.y })
    }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable private fun LocalMediaPlayer(file: File) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val player = remember(file) { ExoPlayer.Builder(context).build().apply {
        setMediaItem(PlayerItem.fromUri(Uri.fromFile(file))); prepare()
    } }
    DisposableEffect(player, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) player.pause() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); player.release() }
    }
    AndroidView(factory = { PlayerView(it).apply { this.player = player; useController = true } },
        update = { it.player = player }, modifier = Modifier.fillMaxSize())
}
