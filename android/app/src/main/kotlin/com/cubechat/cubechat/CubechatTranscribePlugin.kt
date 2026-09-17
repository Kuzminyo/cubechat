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
 * `EXTRA_AUDIO_SOURCE`, which arrived in API 33, and on-device recognition
 * needs the same release. Below that this returns null and the voice note is
 * simply not transcribable — which is the honest answer rather than a silent
 * trip over the network.
 *
 * Every failure path returns null rather than an error, the same way
 * [CubechatAudioTrimPlugin] does: a phone that cannot do this loses the
 * transcript, not the message.
 */
class CubechatTranscribePlugin(
    private val context: Context,
    private val methodChannel: MethodChannel,
) {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        ) {
            result.success(null)
            return
        }
        // Decoding is real work and must not run on the main thread; the
        // recogniser afterwards must run on it.
        worker.execute {
            val pcm = decodeToPcm(File(path))
            main.post {
                if (pcm == null) {
                    result.success(null)
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

            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val pcmFile = File.createTempFile("transcribe", ".pcm", source.parentFile)
            out = FileOutputStream(pcmFile)
            val info = MediaCodec.BufferInfo()
            var sawInputEnd = false
            var sawOutputEnd = false

            while (!sawOutputEnd) {
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
            return Pcm(pcmFile, sampleRate, channels)
        } catch (e: Exception) {
            return null
        } finally {
            try { out?.close() } catch (e: Exception) {}
            try { codec?.stop(); codec?.release() } catch (e: Exception) {}
            try { extractor.release() } catch (e: Exception) {}
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
            result.success(null)
            return
        }

        // FlutterResult may be answered exactly once; a second call is a crash
        // rather than a warning, and these callbacks can fire more than once.
        var answered = false
        fun answer(text: String?) {
            if (answered) return
            answered = true
            recognizer.destroy()
            pcm.file.delete()
            result.success(text)
        }

        val descriptor = try {
            ParcelFileDescriptor.open(
                pcm.file,
                ParcelFileDescriptor.MODE_READ_ONLY,
            )
        } catch (e: Exception) {
            answer(null)
            return
        }

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

            override fun onError(error: Int) = answer(null)

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
            answer(null)
        } finally {
            try {
                descriptor.close()
            } catch (e: Exception) {
                // The recogniser holds its own dup of the descriptor.
            }
        }
    }
}
