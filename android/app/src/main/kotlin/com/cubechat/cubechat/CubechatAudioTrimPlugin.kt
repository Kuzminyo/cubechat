package com.cubechat.cubechat

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Cuts a section out of a recorded voice message.
 *
 * Voice notes are AAC-LC in an MP4 container, which cannot be trimmed by
 * slicing bytes: the sample tables in `moov` describe every frame's offset and
 * size, so a truncated file is a corrupt one. Rewriting those tables by hand
 * would mean shipping an MP4 editor, so this re-muxes instead — the platform
 * already has both halves of that.
 *
 * It is a *re-mux*, not a re-encode: compressed frames are copied across
 * untouched, so the cut costs no quality and takes milliseconds. AAC has no
 * inter-frame dependencies, so every frame is a seek point and the cut lands
 * where the user put it rather than at the nearest keyframe.
 *
 * Failure is always reported as a null result rather than an exception. The
 * caller sends the untrimmed recording instead, so a device that cannot do
 * this loses the trim, not the message.
 */
class CubechatAudioTrimPlugin(private val methodChannel: MethodChannel) {

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        methodChannel.setMethodCallHandler { call, result -> onCall(call, result) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "trim") {
            result.notImplemented()
            return
        }
        val source = call.argument<String>("source")
        val dest = call.argument<String>("dest")
        val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
        val endMs = call.argument<Number>("endMs")?.toLong() ?: 0L
        if (source == null || dest == null || endMs <= startMs) {
            result.success(null)
            return
        }
        // Muxing reads and writes whole files; doing it on the platform thread
        // would block the UI for the length of the recording.
        worker.execute {
            val trimmed = runCatching {
                trim(source, dest, startMs * 1000, endMs * 1000)
            }.getOrNull()
            main.post { result.success(trimmed) }
        }
    }

    private fun trim(source: String, dest: String, startUs: Long, endUs: Long): String? {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(source)
            val track = audioTrack(extractor) ?: return null
            val format = extractor.getTrackFormat(track)
            extractor.selectTrack(track)

            // MediaMuxer refuses to start on top of an existing file.
            File(dest).delete()
            muxer = MediaMuxer(dest, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outTrack = muxer.addTrack(format)
            muxer.start()

            val capacity = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            } else {
                DEFAULT_BUFFER
            }
            val buffer = ByteBuffer.allocate(capacity.coerceAtLeast(DEFAULT_BUFFER))
            val info = android.media.MediaCodec.BufferInfo()

            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

            var wrote = false
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val time = extractor.sampleTime
                if (time > endUs) break
                if (time >= startUs) {
                    info.offset = 0
                    info.size = size
                    // Restamp from zero, or players show the clip starting
                    // wherever the cut began.
                    info.presentationTimeUs = time - startUs
                    info.flags = extractor.sampleFlags
                    muxer.writeSampleData(outTrack, buffer, info)
                    wrote = true
                }
                if (!extractor.advance()) break
            }
            if (!wrote) return null
            return dest
        } finally {
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            runCatching { extractor.release() }
        }
    }

    private fun audioTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) return i
        }
        return null
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        worker.shutdown()
    }

    private companion object {
        const val DEFAULT_BUFFER = 64 * 1024
    }
}
