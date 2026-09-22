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
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale
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
    private data class Pcm(
        val file: File,
        val sampleRate: Int,
        val channels: Int,
        /** Numbers for the failure report: source format, peak, gain. */
        val note: String = "",
    )

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
        val fallbacks = call.argument<List<String>>("fallbacks") ?: emptyList()
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
            val pcm = decodeToPcm(File(path))?.let { conditionForRecognizer(it) }
            main.post {
                if (pcm == null) {
                    busy = false
                    result.error("decode_failed", "Audio could not be decoded", null)
                } else {
                    start(pcm, listOfNotNull(locale) + fallbacks, result)
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
     * The file's own sample rate and channel count come out of here as they
     * are; [conditionForRecognizer] then brings them to what the recogniser
     * actually hears, because saying "48 kHz" truthfully turned out not to be
     * enough (recognizer_7 on every note, 2026-09-21).
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
     * Mono, 16 kHz, at a level the recogniser can hear — whatever the note was.
     *
     * The decode above tells the recogniser the file's own rate, and that was
     * meant to be enough. It was not: once notes became 48 kHz Opus (1090),
     * every "→A" on an Android phone that had the language model came back
     * `recognizer_7`, ERROR_NO_MATCH — the recogniser ran to the end and heard
     * no words. 16 kHz is `EXTRA_AUDIO_SOURCE_SAMPLING_RATE`'s default, and
     * what the on-device recognisers are built for. And the microphone, since
     * 1089, records the way Telegram's does — no automatic gain — so a quiet
     * speaker reaches this well below where a recogniser listens for speech.
     *
     * So: channels averaged to one, the rate brought to 16 kHz by averaging
     * each output sample's span of input (a box filter — crude, and ample for
     * speech, which has nothing above 8 kHz worth keeping), then the whole of
     * it raised until its loudest moment sits at 70% of full scale, by at most
     * eight times. Streamed through files both ways, so a long note costs no
     * more memory than a short one.
     */
    private fun conditionForRecognizer(pcm: Pcm): Pcm? {
        val target = 16_000
        val channels = pcm.channels.coerceAtLeast(1)
        val resampled = File.createTempFile("transcribe16k", ".pcm", context.cacheDir)
        var peak = 0
        try {
            val step = pcm.sampleRate.toDouble() / target
            FileInputStream(pcm.file).buffered(1 shl 16).use { input ->
                FileOutputStream(resampled).buffered(1 shl 16).use { output ->
                    fun emit(value: Int) {
                        val v = value.coerceIn(-32768, 32767)
                        if (kotlin.math.abs(v) > peak) peak = kotlin.math.abs(v)
                        output.write(v and 0xff)
                        output.write((v shr 8) and 0xff)
                    }
                    val frameBytes = 2 * channels
                    val frame = ByteArray(frameBytes)
                    var index = 0L
                    var boundary = step
                    var sum = 0L
                    var count = 0
                    var last = 0
                    while (true) {
                        var read = 0
                        while (read < frameBytes) {
                            val n = input.read(frame, read, frameBytes - read)
                            if (n < 0) break
                            read += n
                        }
                        if (read < frameBytes) break
                        var mixed = 0
                        for (c in 0 until channels) {
                            val lo = frame[2 * c].toInt() and 0xff
                            val hi = frame[2 * c + 1].toInt()
                            mixed += (hi shl 8) or lo
                        }
                        last = mixed / channels
                        sum += last
                        count++
                        index++
                        // Every output sample whose span this input sample
                        // closed. Below 16 kHz a span can be empty, and the
                        // last value is held rather than inventing one.
                        while (index >= boundary) {
                            emit(if (count > 0) (sum / count).toInt() else last)
                            sum = 0
                            count = 0
                            boundary += step
                        }
                    }
                    if (count > 0) emit((sum / count).toInt())
                }
            }
            pcm.file.delete()
            val source = "from=${pcm.sampleRate}Hz/${channels}ch;peak=$peak"
            if (peak == 0) return Pcm(resampled, target, 1, "$source;silent")
            val gain = (0.7 * 32767 / peak).coerceAtMost(8.0)
            if (gain <= 1.05) return Pcm(resampled, target, 1, "$source;gain=1")
            val louder = File.createTempFile("transcribe16kn", ".pcm", context.cacheDir)
            FileInputStream(resampled).buffered(1 shl 16).use { input ->
                FileOutputStream(louder).buffered(1 shl 16).use { output ->
                    while (true) {
                        val lo = input.read()
                        val hi = input.read()
                        if (lo < 0 || hi < 0) break
                        val sample = (hi.toByte().toInt() shl 8) or lo
                        val v = (sample * gain).toInt().coerceIn(-32768, 32767)
                        output.write(v and 0xff)
                        output.write((v shr 8) and 0xff)
                    }
                }
            }
            resampled.delete()
            return Pcm(louder, target, 1, "$source;gain=${"%.1f".format(gain)}")
        } catch (e: Exception) {
            resampled.delete()
            pcm.file.delete()
            return null
        }
    }

    /**
     * The recogniser is bound to the main looper: every call has to be made
     * there, and every callback arrives there.
     *
     * Only reached on Android 13+ — [onCall] answers below that.
     */
    @android.annotation.TargetApi(Build.VERSION_CODES.TIRAMISU)
    private fun start(pcm: Pcm, wanted: List<String>, result: MethodChannel.Result) {
        // FlutterResult may be answered exactly once; a second call is a crash
        // rather than a warning, and these callbacks can fire more than once.
        var answered = false
        var recognizer: SpeechRecognizer? = null
        var descriptor: ParcelFileDescriptor? = null
        var timeout: Runnable? = null
        val began = SystemClock.elapsedRealtime()

        // **What happened, sent back with any failure.** Three builds in a row
        // came back with one number — recognizer_12, then recognizer_7 twice —
        // and nothing to tell apart "the recogniser never read the file",
        // "it read silence" and "it heard sound and found no words". This says
        // how long the audio was and how loud, which language was used, and
        // whether the recogniser reported sound levels, speech starting and
        // speech ending. Numbers and language tags only, never words.
        val bytesPerSecond = 2L * pcm.channels * pcm.sampleRate
        val notes = StringBuilder(
            "audio=${pcm.file.length() * 1000 / bytesPerSecond}ms@${pcm.sampleRate}Hz",
        )
        if (pcm.note.isNotEmpty()) notes.append(';').append(pcm.note)
        fun note(text: String) {
            notes.append(';').append(text)
        }

        fun releaseAttempt() {
            try { recognizer?.destroy() } catch (_: Exception) {}
            recognizer = null
            // startListening queues work on Android's handler. Closing in its
            // finally block races service binding and Binder descriptor copying.
            // Retain the source until completion/error/timeout instead.
            try { descriptor?.close() } catch (_: Exception) {}
            descriptor = null
        }

        fun finish(text: String?, code: String? = null) {
            if (answered) return
            answered = true
            busy = false
            timeout?.let { main.removeCallbacks(it) }
            releaseAttempt()
            pcm.file.delete()
            note("after=${SystemClock.elapsedRealtime() - began}ms")
            if (code == null) result.success(text)
            else result.error(code, "On-device transcription failed", notes.toString())
        }

        timeout = Runnable { finish(null, "timeout") }
        main.postDelayed(timeout, recognitionTimeoutMs)

        fun intentFor(
            language: String?,
            source: ParcelFileDescriptor?,
            segmented: Boolean,
        ) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            if (language != null) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            if (source != null) putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, source)
            // What the descriptor actually holds. These extras are a
            // description, and a wrong one is believed.
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
            // The mode the platform documents for a whole file: the recogniser
            // reads the source to its end and hands back every stretch of
            // speech in it (onSegmentResults), then says it has finished
            // (onEndOfSegmentedSession). Without it a recogniser may stop at
            // the first pause it hears — or, reading a file faster than real
            // time, before it thinks anybody has started talking.
            if (segmented) {
                putExtra(
                    RecognizerIntent.EXTRA_SEGMENTED_SESSION,
                    RecognizerIntent.EXTRA_AUDIO_SOURCE,
                )
            }
        }

        // One try at the file. The first is the ordinary session; if that
        // hears no words (ERROR_NO_MATCH, 7 — every attempt on the reporting
        // phone) the same file goes again as a segmented session.
        fun attempt(language: String?, segmented: Boolean) {
            if (answered) return
            releaseAttempt()
            val mode = if (segmented) "seg" else "one"
            val r = try {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            } catch (e: Exception) {
                finish(null, "unavailable")
                return
            }
            recognizer = r
            val source = try {
                ParcelFileDescriptor.open(pcm.file, ParcelFileDescriptor.MODE_READ_ONLY)
            } catch (_: Exception) {
                finish(null, "source_unavailable")
                return
            }
            descriptor = source

            var ready = false
            var speechBegan = false
            var speechEnded = false
            var levels = 0
            var loudest = -100f
            val segments = mutableListOf<String>()
            fun summary() = "$mode:" +
                (if (ready) "ready," else "") +
                "rms=$levels/max=${"%.1f".format(loudest)}" +
                (if (speechBegan) ",begin" else "") +
                (if (speechEnded) ",end" else "") +
                (if (segmented) ",segments=${segments.size}" else "")
            fun current() = !answered && r === recognizer

            r.setRecognitionListener(object : RecognitionListener {
                override fun onResults(results: Bundle?) {
                    if (!current()) return
                    val text = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                    note(summary())
                    when {
                        !text.isNullOrBlank() -> finish(text)
                        !segmented -> attempt(language, true)
                        segments.isNotEmpty() -> finish(segments.joinToString(" "))
                        else -> finish(null)
                    }
                }

                override fun onSegmentResults(segmentResults: Bundle) {
                    if (!current()) return
                    segmentResults
                        .getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                        ?.takeIf { it.isNotBlank() }
                        ?.let { segments.add(it.trim()) }
                }

                override fun onEndOfSegmentedSession() {
                    if (!current()) return
                    note(summary())
                    if (segments.isNotEmpty()) {
                        finish(segments.joinToString(" "))
                    } else {
                        finish(null, "recognizer_${SpeechRecognizer.ERROR_NO_MATCH}")
                    }
                }

                override fun onError(error: Int) {
                    if (!current()) return
                    note("${summary()},error=$error")
                    when {
                        error == SpeechRecognizer.ERROR_NO_MATCH && !segmented ->
                            attempt(language, true)
                        segments.isNotEmpty() -> finish(segments.joinToString(" "))
                        else -> finish(null, "recognizer_$error")
                    }
                }

                override fun onReadyForSpeech(params: Bundle?) {
                    ready = true
                }

                override fun onBeginningOfSpeech() {
                    speechBegan = true
                }

                override fun onRmsChanged(rmsdB: Float) {
                    levels++
                    if (rmsdB > loudest) loudest = rmsdB
                }

                override fun onEndOfSpeech() {
                    speechEnded = true
                }

                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onPartialResults(partialResults: Bundle?) = Unit
                override fun onEvent(eventType: Int, params: Bundle?) = Unit
            })

            try {
                // `startListening`, not `recognize` — there is no such method.
                // With EXTRA_AUDIO_SOURCE set, listening reads the descriptor
                // instead of the microphone.
                r.startListening(intentFor(language, source, segmented))
            } catch (e: Exception) {
                finish(null, "start_failed")
            }
        }

        // **Which language to listen in, from what this phone actually has.**
        //
        // The app's own language went straight in as EXTRA_LANGUAGE, and a
        // phone whose on-device recogniser has no model for it answers error
        // 12, ERROR_LANGUAGE_NOT_SUPPORTED — every note, every time. Reported
        // as "не може розпізнати" from a phone set to Ukrainian, with the notes
        // spoken in Russian. So the recogniser is asked first which languages
        // it holds, and the first of the wanted ones it has is used. A wanted
        // language it could hold but has not downloaded is fetched for next
        // time. Nothing leaves the phone either way: the model comes from the
        // system's own recognition service, the audio goes nowhere.
        val first = wanted.firstOrNull()
        val checker = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (e: Exception) {
            finish(null, "unavailable")
            return
        }
        recognizer = checker
        try {
            checker.checkRecognitionSupport(
                intentFor(first, null, false),
                context.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        if (answered) return
                        val installed = support.installedOnDeviceLanguages
                        note("wanted=${wanted.joinToString(",")}")
                        note("installed=${installed.joinToString(",")}")
                        val pick = pickLanguage(wanted, installed)
                        if (pick != null) {
                            note("lang=$pick")
                            attempt(pick, false)
                            return
                        }
                        val pending = support.pendingOnDeviceLanguages
                        val fetch = pickLanguage(
                            wanted,
                            support.supportedOnDeviceLanguages + pending,
                        )
                        if (fetch == null) {
                            finish(null, "language_not_supported")
                            return
                        }
                        if (pickLanguage(listOf(fetch), pending) == null) {
                            try {
                                checker.triggerModelDownload(intentFor(fetch, null, false))
                            } catch (_: Exception) {
                            }
                        }
                        note("fetching=$fetch")
                        finish(null, "model_downloading")
                    }

                    // A recogniser that cannot say what it has: try what was
                    // asked for, as before.
                    override fun onError(error: Int) {
                        if (answered) return
                        note("support_error=$error")
                        attempt(first, false)
                    }
                },
            )
        } catch (e: Exception) {
            note("support_threw")
            attempt(first, false)
        }
    }

    /**
     * The first of [wanted] that [available] holds: the exact tag if it is
     * there ("ru-RU"), otherwise the same language in any region ("uk" wants
     * "uk-UA").
     */
    private fun pickLanguage(wanted: List<String>, available: List<String>): String? {
        for (tag in wanted) {
            available.firstOrNull { it.equals(tag, ignoreCase = true) }?.let { return it }
            val language = Locale.forLanguageTag(tag).language
            available.firstOrNull { Locale.forLanguageTag(it).language == language }
                ?.let { return it }
        }
        return null
    }
}
