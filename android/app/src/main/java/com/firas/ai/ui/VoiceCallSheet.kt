package com.firas.ai.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.firas.ai.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Push-to-talk conversation using real device recognition, durable Firas jobs and Firas TTS. */
@Composable fun VoiceCallSheet(repository: FirasRepository, onClose: () -> Unit) {
    val context = LocalContext.current
    val ar = LocalArabic.current
    val palette = LocalPalette.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    var recognizer by remember { mutableStateOf<SpeechRecognizer?>(null) }
    var listening by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var speaking by remember { mutableStateOf(false) }
    var rms by remember { mutableFloatStateOf(0f) }
    var transcript by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf<String?>(null) }
    var localTask by remember { mutableStateOf<Job?>(null) }
    val repositoryState by repository.state.collectAsState()
    val owner = repositoryState.session.ownerId
    fun submit(words: String) {
        if (words.isBlank() || working) return
        listening = false; rms = 0f; transcript = words; working = true; notice = null
        localTask = scope.launch {
            try {
                if (repository.state.value.activeThread == null) repository.newThread()
                val before = repository.state.value.activeThread?.messages?.map { it.id }?.toSet().orEmpty()
                val result = repository.send(words, tier = "pro")
                val answer = when (result) {
                    is SubmissionOutcome.Refused -> throw FirasFailure(result.notice)
                    is SubmissionOutcome.Completed -> repository.state.value.activeThread?.messages
                        ?.lastOrNull { it.role == "assistant" && it.id !in before }?.visibleContent.orEmpty()
                    is SubmissionOutcome.Accepted -> {
                        val finished = repository.state.first { state ->
                            state.session.ownerId != owner || state.jobs.any { it.id == result.job.id && it.terminal }
                        }
                        if (finished.session.ownerId != owner) throw CancellationException("Owner changed")
                        val job = finished.jobs.first { it.id == result.job.id }
                        if (job.phase != JobPhase.COMPLETE) throw FirasFailure(job.notice ?: UiNotice("لم يكتمل الرد. يمكنك المحاولة مجددًا.", "The answer did not complete. You can try again."))
                        finished.activeThread?.takeIf { it.id == job.threadId }?.messages
                            ?.lastOrNull { it.role == "assistant" && it.cid == job.cid }?.visibleContent?.takeIf { it.isNotBlank() }
                            ?: job.text
                    }
                }
                if (answer.isBlank()) throw FirasFailure(UiNotice("يمكنك متابعة النتيجة في المحادثة.", "You can view the result in the conversation."))
                SpeechPlayback.speak(context, repository, answer) { speaking = it }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { notice = (error as? FirasFailure)?.notice?.text(if (ar) "ar" else "en")
                ?: if (ar) "تعذر إكمال المحادثة الصوتية. حاول مجددًا." else "The voice turn could not finish. Try again." }
            finally { working = false; speaking = false; localTask = null }
        }
    }
    val onWords by rememberUpdatedState<(String) -> Unit>(::submit)
    val currentArabic by rememberUpdatedState(ar)
    DisposableEffect(context, lifecycle) {
        val engine = if (SpeechRecognizer.isRecognitionAvailable(context)) SpeechRecognizer.createSpeechRecognizer(context) else null
        recognizer = engine
        engine?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) { listening = true }
            override fun onBeginningOfSpeech() { }
            override fun onRmsChanged(rmsdB: Float) { rms = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f) }
            override fun onBufferReceived(buffer: ByteArray?) { }
            override fun onEndOfSpeech() { rms = 0f }
            override fun onError(error: Int) {
                listening = false; rms = 0f
                notice = if (currentArabic) "لم ألتقط كلامًا واضحًا. اضغط الميكروفون وحاول مجددًا." else "I could not recognize clear speech. Tap the microphone and try again."
            }
            override fun onResults(results: Bundle?) {
                listening = false; rms = 0f
                onWords(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty())
            }
            override fun onPartialResults(results: Bundle?) { transcript = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty() }
            override fun onEvent(eventType: Int, params: Bundle?) { }
        })
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) { engine?.cancel(); listening = false; rms = 0f; localTask?.cancel(); SpeechPlayback.stop() }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer); engine?.cancel(); engine?.destroy(); recognizer = null
            localTask?.cancel(); SpeechPlayback.stop()
            // Only the local call reader is stopped. An accepted cloud job continues in chat.
        }
    }
    fun listen() {
        notice = null; transcript = ""
        val engine = recognizer
        if (engine == null) { notice = if (ar) "التعرف على الكلام غير متاح على هذا الجهاز." else "Speech recognition is unavailable on this device."; return }
        try {
            listening = true
            engine.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, if (ar) "ar-IQ" else "en-US")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            })
        } catch (_: Exception) { listening = false; notice = if (ar) "تعذر تشغيل الميكروفون." else "The microphone could not start." }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) listen() else notice = if (ar) "اسمح باستخدام الميكروفون لبدء الكلام." else "Allow microphone access to start speaking."
    }
    val level by animateFloatAsState(if (listening) rms else if (speaking) 0.65f else 0f, label = "voice activity")
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = palette.ground) {
            Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Firas Voice", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                    IconButton(onClick = onClose, modifier = Modifier.size(48.dp)) { Icon(Icons.Outlined.Close, if (ar) "إنهاء المكالمة" else "End call") }
                }
                Spacer(Modifier.weight(1f))
                Canvas(Modifier.size(190.dp)) {
                    val radius = size.minDimension * (0.36f + level * 0.1f)
                    drawCircle(Brush.radialGradient(listOf(palette.accent, palette.accent.copy(alpha = 0.3f), palette.ground)), radius = radius)
                    drawCircle(palette.accent.copy(alpha = 0.16f), radius = radius + 14.dp.toPx())
                }
                Text(when { speaking -> if (ar) "فِراس يتحدث" else "Firas is speaking"; working -> if (ar) "فِراس يفكر…" else "Firas is thinking…"; listening -> if (ar) "أسمعك…" else "Listening…"; else -> if (ar) "اضغط الميكروفون وتحدث" else "Tap the microphone and speak" }, style = MaterialTheme.typography.titleMedium)
                if (transcript.isNotBlank()) Text(transcript, Modifier.padding(top = 18.dp), maxLines = 5, color = palette.secondary)
                notice?.let { Text(it, Modifier.padding(top = 18.dp), color = palette.secondary) }
                Spacer(Modifier.weight(1f))
                if (working) OutlinedButton(onClick = { localTask?.cancel(); SpeechPlayback.stop() }) { Text(if (ar) "إيقاف الصوت" else "Stop voice") }
                else FilledIconButton(onClick = {
                    if (listening) recognizer?.stopListening()
                    else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) listen()
                    else permission.launch(Manifest.permission.RECORD_AUDIO)
                }, modifier = Modifier.size(72.dp)) { Icon(if (listening) Icons.Outlined.Stop else Icons.Outlined.Mic, if (ar) "الميكروفون" else "Microphone", Modifier.size(30.dp)) }
                TextButton(onClick = onClose, modifier = Modifier.padding(top = 16.dp)) { Text(if (ar) "إنهاء المكالمة" else "End call") }
            }
        }
    }
}
