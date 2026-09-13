package com.firas.ai.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

internal data class ComposerAttachmentPicker(
    val photos: () -> Unit,
    val files: () -> Unit,
    val camera: () -> Unit,
    val cameraAvailable: Boolean,
)

/** Register unconditionally in the composer, so Android can restore pending picker results. */
@Composable
internal fun rememberComposerAttachmentPicker(
    ownerKey: String?,
    onPicked: (List<Uri>) -> Unit,
    onError: (String) -> Unit,
): ComposerAttachmentPicker {
    val context = LocalContext.current
    val ar by rememberUpdatedState(LocalArabic.current)
    val currentOwner by rememberUpdatedState(ownerKey)
    val picked by rememberUpdatedState(onPicked)
    val error by rememberUpdatedState(onError)
    val scope = rememberCoroutineScope()
    var pendingKind by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingOwner by rememberSaveable { mutableStateOf<String?>(null) }
    var invalidated by rememberSaveable { mutableStateOf(false) }
    var cameraPath by rememberSaveable { mutableStateOf<String?>(null) }
    var cameraUri by rememberSaveable { mutableStateOf<String?>(null) }
    val cameraAvailable = remember(context) {
        runCatching { Intent(MediaStore.ACTION_IMAGE_CAPTURE).resolveActivity(context.packageManager) != null }.getOrDefault(false)
    }
    SideEffect {
        if (pendingKind != null && pendingOwner != ownerKey) invalidated = true
    }

    fun report(arabic: String, english: String) = error(if (ar) arabic else english)
    fun clearPending() {
        pendingKind = null; pendingOwner = null; invalidated = false
        cameraPath = null; cameraUri = null
    }
    LaunchedEffect(Unit) {
        // Rotation can interrupt file preparation before Android has a camera result to restore.
        if (pendingKind == "camera" && cameraUri == null) {
            deleteCameraFile(context, cameraPath)
            clearPending()
        }
    }
    fun begin(kind: String): Boolean {
        if (currentOwner.isNullOrBlank()) {
            report("افتح محادثة أولاً حتى تضيف مرفقاً.", "Open a conversation before attaching a file.")
            return false
        }
        if (pendingKind != null) {
            report("أكمل اختيار المرفق الحالي أو ألغِه أولاً.", "Finish or cancel the current attachment picker first.")
            return false
        }
        pendingOwner = currentOwner; pendingKind = kind; invalidated = false
        return true
    }
    fun finishSelection(kind: String, values: List<Uri>) {
        if (pendingKind != kind) return
        val accepted = !invalidated && pendingOwner != null && pendingOwner == currentOwner
        clearPending()
        if (values.isEmpty()) return
        if (!accepted) {
            report("تغيّرت المحادثة؛ اختر المرفقات من جديد.", "The conversation changed. Choose the attachments again.")
            return
        }
        val selected = values.distinct()
        // Older photo-picker fallbacks may ignore the requested selection limit.
        if (selected.size > 8) {
            report("اختَر ثمانية مرفقات كحد أقصى.", "Choose at most eight attachments.")
            return
        }
        if (selected.any { it.scheme != "content" }) {
            report("تعذّر الوصول إلى المرفق. اختره من منتقي الملفات.", "This attachment is unavailable. Choose it through the file picker.")
            return
        }
        picked(selected)
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) {
        finishSelection("photos", it)
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) {
        finishSelection("files", it)
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        if (pendingKind != "camera") return@rememberLauncherForActivityResult
        val path = cameraPath
        val uri = cameraUri?.let(Uri::parse)
        val accepted = !invalidated && pendingOwner != null && pendingOwner == currentOwner
        clearPending()
        uri?.let { revokeCameraGrant(context, it) }
        val file = path?.let { ownCameraFile(context, it) }
        when {
            !success -> deleteCameraFile(context, path)
            !accepted -> {
                deleteCameraFile(context, path)
                report("تغيّرت المحادثة؛ التقط الصورة من جديد.", "The conversation changed. Take the photo again.")
            }
            uri == null || file == null || !file.isFile || file.length() == 0L -> {
                deleteCameraFile(context, path)
                report("الكاميرا ما حفظت الصورة. حاول مرة ثانية.", "The camera did not save a photo. Try again.")
            }
            else -> picked(listOf(uri)) // Keep the successful file for AttachmentReader.
        }
    }

    return ComposerAttachmentPicker(
        photos = {
            if (begin("photos")) try {
                photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            } catch (_: RuntimeException) {
                clearPending(); report("تعذّر فتح الصور. جرّب خيار الملفات.", "Photos could not open. Try Files instead.")
            }
        },
        files = {
            if (begin("files")) try {
                files.launch(arrayOf("*/*"))
            } catch (_: RuntimeException) {
                clearPending(); report("تعذّر فتح منتقي الملفات على هذا الجهاز.", "The file picker could not open on this device.")
            }
        },
        camera = {
            if (!cameraAvailable) report("ماكو كاميرا متاحة. تكدر تختار صورة محفوظة.", "No camera is available. Choose a saved photo instead.")
            else if (begin("camera")) {
                val launchOwner = pendingOwner
                scope.launch {
                    var created: File? = null
                    try {
                        withContext(Dispatchers.IO) {
                            val root = File(context.cacheDir, CAMERA_DIRECTORY)
                            check(root.isDirectory || root.mkdirs())
                            created = File(root, "capture-${UUID.randomUUID()}.jpg").also { check(it.createNewFile()) }
                        }
                        if (invalidated || currentOwner != launchOwner || pendingKind != "camera") {
                            deleteCameraFile(context, created?.path); clearPending()
                            report("تغيّرت المحادثة؛ افتح الكاميرا من جديد.", "The conversation changed. Open the camera again.")
                        } else {
                            val uri = FileProvider.getUriForFile(context, context.packageName + ".files", requireNotNull(created))
                            cameraPath = created?.path; cameraUri = uri.toString()
                            camera.launch(uri)
                        }
                    } catch (cancel: CancellationException) {
                        withContext(NonCancellable + Dispatchers.IO) { deleteCameraFile(context, created?.path) }
                        clearPending(); throw cancel
                    } catch (_: Exception) {
                        cameraUri?.let { revokeCameraGrant(context, Uri.parse(it)) }
                        deleteCameraFile(context, created?.path); clearPending()
                        report("تعذّر تشغيل الكاميرا. جرّب اختيار صورة محفوظة.", "The camera could not open. Try choosing a saved photo.")
                    }
                }
            }
        },
        cameraAvailable = cameraAvailable,
    )
}

private const val CAMERA_DIRECTORY = "composer-camera"
private fun ownCameraFile(context: Context, path: String): File? = runCatching {
    val root = File(context.cacheDir, CAMERA_DIRECTORY).canonicalFile
    val file = File(path).canonicalFile
    file.takeIf { it.parentFile == root && it.name.matches(Regex("capture-[a-f0-9-]{36}\\.jpg")) }
}.getOrNull()
private fun deleteCameraFile(context: Context, path: String?) {
    if (path != null) runCatching { ownCameraFile(context, path)?.delete() }
}
private fun revokeCameraGrant(context: Context, uri: Uri) {
    runCatching { context.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
}

/** Discard only exact camera capture URIs minted by this app's narrowly scoped FileProvider. */
internal fun discardComposerCaptures(context: Context, uris: List<Uri>) {
    val authority = context.packageName + ".files"
    uris.distinct().forEach { uri ->
        if (uri.scheme != "content" || uri.encodedAuthority != authority ||
            uri.encodedQuery != null || uri.encodedFragment != null) return@forEach
        val segments = uri.pathSegments
        if (segments.size != 2 || segments[0] != "composer_camera") return@forEach
        val file = ownCameraFile(context, File(File(context.cacheDir, CAMERA_DIRECTORY), segments[1]).path)
            ?: return@forEach
        if (uri.encodedPath != "/composer_camera/${Uri.encode(file.name)}") return@forEach
        revokeCameraGrant(context, uri)
        deleteCameraFile(context, file.path)
    }
}
