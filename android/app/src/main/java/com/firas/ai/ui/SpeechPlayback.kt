package com.firas.ai.ui

import android.content.Context
import android.net.Uri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.firas.ai.data.FirasRepository
import com.firas.ai.data.tts
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import java.io.File

/** One foreground speech reader. Switching owner, leaving the app, or closing a call silences it. */
object SpeechPlayback {
    private var task: Job? = null
    fun stop() { task?.cancel(); task = null }

    suspend fun speak(context: Context, repository: FirasRepository, text: String, playing: (Boolean) -> Unit = {}) =
        withContext(Dispatchers.Main.immediate) {
            coroutineScope {
                val owner = repository.token()
                val ownTask = currentCoroutineContext().job
                task?.cancel(); task = ownTask
                val lifecycle = ProcessLifecycleOwner.get().lifecycle
                val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) ownTask.cancel() }
                lifecycle.addObserver(observer)
                val ownerWatch = launch {
                    repository.state.collect {
                        if (it.session.ownerId != owner.id || repository.vault.epoch != owner.epoch) ownTask.cancel()
                    }
                }
                try {
                    for (chunk in speechChunks(text)) {
                        ensureActive(); repository.checkOwner(owner)
                        val result = repository.tts(chunk)
                        try {
                            repository.checkOwner(owner)
                            play(context.applicationContext, result.file, playing)
                        } finally { withContext(Dispatchers.IO + NonCancellable) { result.file.delete() } }
                    }
                } finally {
                    ownerWatch.cancel(); lifecycle.removeObserver(observer); playing(false)
                    if (task === ownTask) task = null
                }
            }
        }

    private suspend fun play(context: Context, file: File, playing: (Boolean) -> Unit) {
        val player = ExoPlayer.Builder(context).build()
        try {
            suspendCancellableCoroutine<Unit> { continuation ->
                player.addListener(object : Player.Listener {
                    override fun onIsPlayingChanged(isPlaying: Boolean) { playing(isPlaying) }
                    override fun onPlaybackStateChanged(state: Int) {
                        if (state == Player.STATE_ENDED && continuation.isActive) continuation.resume(Unit)
                    }
                    override fun onPlayerError(error: PlaybackException) {
                        if (continuation.isActive) continuation.resumeWithException(error)
                    }
                })
                player.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
                player.prepare(); player.playWhenReady = true
            }
        } finally { player.release(); playing(false) }
    }
}

/** Server caps TTS at1300 UTF-16 characters. Never cut a surrogate pair or silently lose a tail. */
internal fun speechChunks(source: String, limit: Int = 1200): List<String> {
    require(limit in 2..1300)
    var text = source.replace(Regex("```[\\s\\S]*?```"), " ").replace(Regex("[*#`]"), "").trim()
    val result = mutableListOf<String>()
    while (text.isNotEmpty()) {
        var end = minOf(limit, text.length)
        if (end < text.length) {
            val pause = text.lastIndexOfAny(charArrayOf('.', '!', '?', '؟', '\n', ' ', '،'), end - 1)
            if (pause >= limit / 2) end = pause + 1
            if (end > 0 && Character.isHighSurrogate(text[end - 1])) end--
        }
        text.substring(0, end).trim().takeIf { it.isNotEmpty() }?.let(result::add)
        text = text.substring(end).trimStart()
    }
    return result
}
