package com.cubechat.cubechat

import android.content.Context
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Turns a recorded voice note into text, on this phone.
 *
 * On-device only, and not as an optimisation: a cloud recogniser would mean
 * posting the decrypted contents of a private message to somebody else's API,
 * which is the one thing this app exists not to do. That rules out the ordinary
 * [SpeechRecognizer], which may go to the network — this uses
 * `createOnDeviceSpeechRecognizer`, which cannot.
 *
 * **Android 13 or newer.** Feeding a *file* to the recogniser needs
 * `EXTRA_AUDIO_SOURCE`, which arrived in API 33. Below that the voice note is
 * simply not transcribable — which is the honest answer rather than a silent
 * trip over the network.
 *
 * Unsupported devices and native errors return a code to Dart diagnostics;
 * the controller keeps the message and presents an unavailable transcript.
 */
class CubechatTranscribePlugin(
    private val context: Context,
    private val methodChannel: MethodChannel,
) {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var busy = false

    // A stalled recognizer must release its file and native session. This is a
    // wall-clock ceiling, not an assumption about when speech ends.
    private val recognitionTimeoutMs = 90_000L

    /** What the decode produced: a raw PCM file and the format it is in. */
    private data class Pcm(val file: File, val sampleRate: Int, val channels: Int)

    init {
        methodChannel.setMethodCallHandler { call, result -> onCall(call, result) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "transcribe") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        val locale = call.argument<String>("locale")
        if (path == null || !File(path).exists()) {
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.error("android_version", "File recognition needs Android 13", null)
            return
        }
        val available = try {
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        } catch (_: Exception) { false }
        if (!available) {
            result.error("local_recognizer_unavailable", "No on-device recognizer", null)
            return
        }
        if (busy) {
            result.error("busy", "A transcription is already running", null)
            return
        }
        busy = true
        // Decoding is real work and must not run on the main thread; the
        // recogniser afterwards must run on it.
        worker.execute {
            val pcm = decodeToPcm(File(path))
            main.post {
                if (pcm == null) {
                    busy = false
                    result.error("decode_failed", "Audio could not be decoded", null)
                } else {
                    start(pcm, locale, result)
                }
            }
        }
    }

    /**
     * Voice notes are AAC in an MP4 container; the recogniser wants raw PCM.
     *
     * Handing it the m4a directly compiles, runs, and transcribes noise — the
     * `EXTRA_AUDIO_SOURCE_*` extras describe what the descriptor holds, and
     * saying "16-bit PCM" over compressed frames is simply a lie the recogniser
     * believes.
     *
     * The file's own sample rate and channel count are carried through rather
     * than resampled to 16 kHz: the extras exist to say what the audio is, and
     * a hand-rolled resampler would be a worse answer than telling the truth.
     */
    private fun decodeToPcm(source: File): Pcm? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var out: FileOutputStream? = null
        var pcmFile: File? = null
        var completed = false
        try {
            extractor.setDataSource(source.path)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    track = i
                    format = f
                    break
                }
            }
            if (track < 0 || format == null) return null
            extractor.selectTrack(track)

            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            pcmFile = File.createTempFile("transcribe", ".pcm", context.cacheDir)
            out = FileOutputStream(pcmFile)
            val info = MediaCodec.BufferInfo()
            var sawInputEnd = false
            var sawOutputEnd = false

            val deadline = SystemClock.elapsedRealtime() + recognitionTimeoutMs
            while (!sawOutputEnd) {
                if (SystemClock.elapsedRealtime() >= deadline) return null
                if (!sawInputEnd) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex) ?: return null
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEnd = true
                        } else {
                            codec.queueInputBuffer(
                                inIndex, 0, size, extractor.sampleTime, 0,
                            )
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val decoded = codec.outputFormat
                    sampleRate = decoded.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = decoded.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    if (decoded.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        decoded.getInteger(MediaFormat.KEY_PCM_ENCODING) !=
                        android.media.AudioFormat.ENCODING_PCM_16BIT) return null
                }
                if (outIndex >= 0) {
                    val buffer = codec.getOutputBuffer(outIndex)
                    if (buffer != null && info.size > 0) {
                        val chunk = ByteArray(info.size)
                        buffer.position(info.offset)
                        buffer.get(chunk)
                        out.write(chunk)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        sawOutputEnd = true
                    }
                }
            }
            out.flush()
            completed = true
            return Pcm(pcmFile, sampleRate, channels)
        } catch (e: Exception) {
            return null
        } finally {
            try { out?.close() } catch (e: Exception) {}
            try { codec?.stop() } catch (e: Exception) {}
            try { codec?.release() } catch (e: Exception) {}
            try { extractor.release() } catch (e: Exception) {}
            if (!completed) pcmFile?.delete()
        }
    }

    /**
     * The recogniser is bound to the main looper: every call has to be made
     * there, and every callback arrives there.
     */
    private fun start(pcm: Pcm, locale: String?, result: MethodChannel.Result) {
        val recognizer = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (e: Exception) {
            pcm.file.delete()
            busy = false
            result.error("unavailable", "On-device speech recognition unavailable", null)
            return
        }

        // FlutterResult may be answered exactly once; a second call is a crash
        // rather than a warning, and these callbacks can fire more than once.
        var answered = false
        var descriptor: ParcelFileDescriptor? = null
        var timeout: Runnable? = null
        fun answer(text: String?, code: String? = null) {
            if (answered) return
            answered = true
            busy = false
            timeout?.let { main.removeCallbacks(it) }
            try { recognizer.destroy() } catch (_: Exception) {}
            // startListening queues work on Android's handler. Closing in its
            // finally block races service binding and Binder descriptor copying.
            // Retain the source until completion/error/timeout instead.
            try { descriptor?.close() } catch (_: Exception) {}
            pcm.file.delete()
            if (code == null) result.success(text)
            else result.error(code, "On-device transcription failed", null)
        }

        descriptor = try {
            ParcelFileDescriptor.open(pcm.file, ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (_: Exception) {
            answer(null, "source_unavailable")
            return
        }
        timeout = Runnable { answer(null, "timeout") }
        main.postDelayed(timeout, recognitionTimeoutMs)

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            if (locale != null) putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, descriptor)
            // What the descriptor actually holds, read off the file rather
            // than assumed. These extras are a description, and a wrong one is
            // believed.
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, pcm.channels)
            putExtra(
                RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING,
                android.media.AudioFormat.ENCODING_PCM_16BIT,
            )
            putExtra(
                RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE,
                pcm.sampleRate,
            )
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }

        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                val text = results
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                answer(if (text.isNullOrBlank()) null else text)
            }

            override fun onError(error: Int) = answer(null, "recognizer_$error")

            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onPartialResults(partialResults: Bundle?) = Unit
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })

        try {
            // `startListening`, not `recognize` — there is no such method. With
            // EXTRA_AUDIO_SOURCE set, listening reads the descriptor instead of
            // the microphone.
            recognizer.startListening(intent)
        } catch (e: Exception) {
            answer(null, "start_failed")
        }
    }
}
