package com.cubechat.cubechat

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * The first frame of a video, written once as a small JPEG.
 *
 * A clip in the chat, and a circle, show a picture of themselves before they
 * are played - "put the first frame on the circles" - and until now the only
 * way to draw one was to open a video decoder for every clip on screen and
 * leave it paused on frame zero. A decoder is a hardware codec slot and a
 * texture per bubble, held while scrolling past; a frame is a JPEG decoded like
 * any photo. `MediaMetadataRetriever` reads the one frame and lets go.
 *
 * Dart names the output file and caches the answer; see `VideoFrames`.
 */
class VideoFramePlugin(messenger: BinaryMessenger) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "cubechat/video_frame").setMethodCallHandler { call, result ->
            if (call.method != "frame") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val out = call.argument<String>("out")
            val maxSide = call.argument<Number>("maxSide")?.toInt() ?: 480
            if (path == null || out == null) {
                result.success(null)
                return@setMethodCallHandler
            }
            // One at a time, off the platform thread: a chat opening on a
            // screen of clips asks for several at once, and retrievers are
            // not cheap to hold in parallel.
            worker.execute {
                val answer = read(path, out, maxSide)
                main.post { result.success(answer) }
            }
        }
    }

    /**
     * The frame, unless it is on disk already, and the length - which a paused
     * player used to supply for the chip in the corner, and which the file's
     * own metadata answers for nothing.
     */
    private fun read(path: String, out: String, maxSide: Int): Map<String, Any?>? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val duration = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
            val written = File(out).exists() || write(retriever, out, maxSide)
            // The shape the picture is shown in, upright: a phone records
            // portrait as landscape with a rotation tag.
            var width = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull()
            var height = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull()
            val rotation = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            if (rotation == 90 || rotation == 270) {
                val swap = width
                width = height
                height = swap
            }
            mapOf(
                "frame" to written,
                "durationMs" to duration,
                "width" to width,
                "height" to height,
            )
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun write(retriever: MediaMetadataRetriever, out: String, maxSide: Int): Boolean {
        return try {
            val frame: Bitmap = (
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(
                        0,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        maxSide,
                        maxSide,
                    )
                } else {
                    retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                }
                ) ?: return false
            val target = File(out)
            target.parentFile?.mkdirs()
            // Written beside the target and renamed, so a half-written file is
            // never taken for a frame by the next launch.
            val partial = File("$out.part")
            FileOutputStream(partial).use { stream ->
                frame.compress(Bitmap.CompressFormat.JPEG, 82, stream)
            }
            frame.recycle()
            partial.renameTo(target)
        } catch (_: Exception) {
            false
        }
    }
}
