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
import kotlin.math.sqrt

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

    /** How long one recogniser session may take before it is given up. */
    private val sessionTimeoutMs = 30_000L

    /** What the decode produced: a raw PCM file and the format it is in. */
    private data class Pcm(
        val file: File,
        val sampleRate: Int,
        val channels: Int,
        /** Numbers for the failure report: source format, peak, gain. */
        val note: String = "",
    )

    /** How one recogniser session ended. */
    private class Outcome(
        val text: String?,
        val segments: List<String>,
        val error: Int?,
        /** The recogniser used segmented mode rather than ignoring the extra. */
        val segmentedHonoured: Boolean,
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
     * The 16 kHz mono note cut into phrases, at its pauses.
     *
     * **Why this exists.** On the reporting phone (2026-09-22, build 1101) the
     * recogniser finally heard a note — and gave back its first phrase only:
     * a sixteen-second note came back as one sentence. An ordinary session
     * ends at the first pause it takes for the end of speaking; that is what
     * it is for, listening to somebody talk into the phone. So the note is
     * handed over one phrase at a time, each a session of its own.
     *
     * A pause is 360 ms or more of frames quieter than the note's own speech
     * — a threshold taken from the note, since one person's pause is another's
     * whisper. The cut goes in the middle of the pause. A stretch with no
     * pause for 20 s is cut at its quietest moment. Stretches with under
     * 200 ms of sound are dropped as clicks and breaths. Each phrase gets a
     * quarter of a second of silence either side, which recognisers expect
     * before the first word. At most forty phrases.
     */
    private fun splitAtPauses(source: File): List<File> {
        val bytes = source.readBytes()
        val n = bytes.size / 2
        if (n == 0) return emptyList()
        fun sample(i: Int): Int = (bytes[2 * i + 1].toInt() shl 8) or (bytes[2 * i].toInt() and 0xff)

        val frame = 320 // 20 ms at 16 kHz
        val frames = (n + frame - 1) / frame
        val energy = DoubleArray(frames) { f ->
            val from = f * frame
            val to = minOf(n, from + frame)
            var sum = 0.0
            for (i in from until to) {
                val v = sample(i).toDouble()
                sum += v * v
            }
            sqrt(sum / (to - from))
        }
        val sorted = energy.sorted()
        val floor = sorted[(frames * 0.2).toInt().coerceAtMost(frames - 1)]
        val loud = sorted[(frames * 0.95).toInt().coerceAtMost(frames - 1)]
        val threshold = maxOf(floor * 2.5, loud * 0.12, 150.0)
        val voiced = BooleanArray(frames) { energy[it] >= threshold }

        val minPause = 18 // 360 ms
        val cuts = mutableListOf<Int>()
        var f = 0
        while (f < frames) {
            if (voiced[f]) {
                f++
                continue
            }
            val start = f
            while (f < frames && !voiced[f]) f++
            if (f - start >= minPause && start > 0 && f < frames) cuts.add(start + (f - start) / 2)
        }

        val bounds = listOf(0) + cuts + frames
        val longest = 20 * 50 // 20 s of frames
        val spans = mutableListOf<Pair<Int, Int>>()
        for (k in 0 until bounds.size - 1) {
            var s = bounds[k]
            val e = bounds[k + 1]
            while (e - s > longest) {
                var best = s + longest
                var bestEnergy = Double.MAX_VALUE
                for (x in s + longest / 2 until s + longest) {
                    if (energy[x] < bestEnergy) {
                        bestEnergy = energy[x]
                        best = x
                    }
                }
                spans.add(s to best)
                s = best
            }
            spans.add(s to e)
        }

        val padding = ByteArray(4000 * 2) // 250 ms of silence
        val out = mutableListOf<File>()
        for ((s, e) in spans) {
            var sounding = 0
            for (x in s until e) if (voiced[x]) sounding++
            if (sounding < 10) continue
            val file = File.createTempFile("phrase", ".pcm", context.cacheDir)
            FileOutputStream(file).buffered(1 shl 16).use { o ->
                o.write(padding)
                val from = s * frame
                val to = minOf(n, e * frame)
                o.write(bytes, from * 2, (to - from) * 2)
                o.write(padding)
            }
            out.add(file)
            if (out.size >= 40) break
        }
        return out
    }

    /**
     * The recogniser is bound to the main looper: every call has to be made
     * there, and every callback arrives there.
     *
     * Two stages. First the whole note in one segmented session — the mode
     * the platform documents for a file, which reads to the end and hands
     * back every stretch of speech. A recogniser that does not support it
     * ignores the extra and stops at the first pause, and says so by
     * answering with onResults instead of onEndOfSegmentedSession; then the
     * note is cut into phrases ([splitAtPauses]) and each is an ordinary
     * session of its own, which is the path this phone is known to hear.
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
        var phrases: List<File> = emptyList()
        var timeout: Runnable? = null
        val began = SystemClock.elapsedRealtime()

        // **What happened, sent back with any failure.** Three builds in a row
        // came back with one number and nothing to tell apart "the recogniser
        // never read the file", "it read silence" and "it heard sound and
        // found no words". This says how long the audio was and how loud,
        // which language was used, and what each stage heard. Numbers and
        // language tags only, never words.
        val bytesPerSecond = 2L * pcm.channels * pcm.sampleRate
        val notes = StringBuilder(
            "audio=${pcm.file.length() * 1000 / bytesPerSecond}ms@${pcm.sampleRate}Hz",
        )
        if (pcm.note.isNotEmpty()) notes.append(';').append(pcm.note)
        fun note(text: String) {
            notes.append(';').append(text)
        }

        fun closeSource() {
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
            try { recognizer?.destroy() } catch (_: Exception) {}
            recognizer = null
            closeSource()
            pcm.file.delete()
            for (file in phrases) file.delete()
            note("after=${SystemClock.elapsedRealtime() - began}ms")
            // A success carries the same numbers as a failure. "It gave back
            // part of the note" was reported twice with a log that said
            // nothing, because a success logged nothing: which stage answered,
            // how many phrases the note was cut into and how many were heard
            // is exactly what that report needs. Still no words in it.
            if (code == null) {
                result.success(mapOf("text" to text, "notes" to notes.toString()))
            } else {
                result.error(code, "On-device transcription failed", notes.toString())
            }
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
            if (segmented) {
                putExtra(
                    RecognizerIntent.EXTRA_SEGMENTED_SESSION,
                    RecognizerIntent.EXTRA_AUDIO_SOURCE,
                )
            }
        }

        // **One recogniser for the whole job, not one per step.** 1099 checked
        // the languages with one instance, destroyed it inside that callback
        // and created a second to listen — and the log came back
        // `recognizer_11`, ERROR_SERVER_DISCONNECTED, 131 ms in, before the
        // recogniser had reported ready. Both instances ride one binding to
        // the system's on-device service, and tearing one down took the
        // service away from the other. 1101 used one instance throughout and
        // heard the note. A fresh instance only when the service did drop.
        var freshRetryUsed = false
        var language: String? = null
        var sessions = 0

        fun isDropped(error: Int?) = error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED ||
            error == SpeechRecognizer.ERROR_CLIENT ||
            error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY

        // One recogniser session over [file]; [onOutcome] is told how it ended.
        fun listen(
            file: File,
            segmented: Boolean,
            fresh: Boolean,
            label: String,
            onOutcome: (Outcome) -> Unit,
        ) {
            if (answered) return
            closeSource()
            val sessionNo = ++sessions
            timeout?.let {
                main.removeCallbacks(it)
                main.postDelayed(it, sessionTimeoutMs)
            }
            val existing = recognizer
            val r = if (existing != null && !fresh) {
                existing
            } else {
                try { existing?.destroy() } catch (_: Exception) {}
                recognizer = null
                try {
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                } catch (e: Exception) {
                    finish(null, "unavailable")
                    return
                }
            }
            recognizer = r
            val source = try {
                ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            } catch (_: Exception) {
                finish(null, "source_unavailable")
                return
            }
            descriptor = source

            var ready = false
            var speechBegan = false
            var levels = 0
            var loudest = -100f
            var honoured = false
            var delivered = false
            val segments = mutableListOf<String>()
            fun current() = !answered && r === recognizer && sessionNo == sessions
            fun summary() = "$label${if (fresh) "+fresh" else ""}:" +
                (if (ready) "ready," else "") +
                "rms=$levels/max=${"%.1f".format(loudest)}" +
                (if (speechBegan) ",begin" else "") +
                (if (segmented) ",seg=${if (honoured) segments.size else "ignored"}" else "")
            fun deliver(outcome: Outcome) {
                if (delivered || !current()) return
                delivered = true
                if (label == "whole" || (outcome.error != null && outcome.error != SpeechRecognizer.ERROR_NO_MATCH)) {
                    note(
                        summary() +
                            (outcome.error?.let { ",error=$it" } ?: "") +
                            (outcome.text?.let { ",text=${it.length}ch" } ?: ""),
                    )
                }
                onOutcome(outcome)
            }

            r.setRecognitionListener(object : RecognitionListener {
                override fun onResults(results: Bundle?) {
                    val text = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                        ?.takeIf { it.isNotBlank() }
                        ?.trim()
                    deliver(Outcome(text, segments.toList(), null, honoured))
                }

                override fun onSegmentResults(segmentResults: Bundle) {
                    if (!current()) return
                    honoured = true
                    segmentResults
                        .getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                        ?.takeIf { it.isNotBlank() }
                        ?.let { segments.add(it.trim()) }
                }

                override fun onEndOfSegmentedSession() {
                    honoured = true
                    deliver(Outcome(null, segments.toList(), null, true))
                }

                override fun onError(error: Int) {
                    deliver(Outcome(null, segments.toList(), error, honoured))
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

                override fun onEndOfSpeech() = Unit
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

        // ---- stage two: phrase by phrase ----------------------------------
        val heard = mutableListOf<String>()
        var index = 0
        var silentPhrases = 0

        // A breath between sessions. Starting the next one straight from the
        // last one's result callback can find the service still closing the
        // previous session and answer "busy" — which used to end the whole
        // note with only what was heard so far.
        val betweenPhrasesMs = 150L

        fun nextPhrase(fresh: Boolean = false, retry: Int = 0) {
            if (answered) return
            if (index >= phrases.size) {
                note("phrases=${phrases.size},heard=${heard.size},silent=$silentPhrases")
                if (heard.isNotEmpty()) {
                    finish(heard.joinToString(" "))
                } else {
                    finish(null, "recognizer_${SpeechRecognizer.ERROR_NO_MATCH}")
                }
                return
            }
            listen(phrases[index], segmented = false, fresh = fresh, label = "p$index") { o ->
                // How much each phrase came back as, in characters, or its error.
                note("p$index=${o.text?.length?.let { "${it}ch" } ?: "e${o.error}"}")
                when {
                    o.text != null -> {
                        heard.add(o.text)
                        index++
                        main.postDelayed({ nextPhrase() }, betweenPhrasesMs)
                    }
                    // A phrase the recogniser found no words in — a laugh, a
                    // breath that crossed the threshold — is skipped, not fatal.
                    o.error == null ||
                        o.error == SpeechRecognizer.ERROR_NO_MATCH ||
                        o.error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                        silentPhrases++
                        index++
                        main.postDelayed({ nextPhrase() }, betweenPhrasesMs)
                    }
                    // Anything else is the service, not the phrase: the same
                    // phrase again, first on the same instance a moment later,
                    // then on a fresh one. Never a reason to stop at half.
                    retry < 2 -> main.postDelayed(
                        { nextPhrase(fresh = retry == 1 || isDropped(o.error), retry = retry + 1) },
                        300L * (retry + 1),
                    )
                    else -> {
                        index++
                        main.postDelayed({ nextPhrase() }, betweenPhrasesMs)
                    }
                }
            }
        }

        fun byPhrases() {
            if (answered) return
            worker.execute {
                val cut = try {
                    splitAtPauses(pcm.file)
                } catch (e: Exception) {
                    emptyList()
                }
                main.post {
                    if (answered) {
                        for (file in cut) file.delete()
                        return@post
                    }
                    phrases = cut
                    // Each phrase's length without its padding, in ms.
                    note(
                        "cut=" + cut.joinToString(",") {
                            ((it.length() - 16_000) / 32).coerceAtLeast(0).toString()
                        },
                    )
                    if (cut.isEmpty()) {
                        note("phrases=0")
                        finish(null)
                        return@post
                    }
                    nextPhrase()
                }
            }
        }

        // ---- stage one: the whole note, segmented -------------------------
        fun whole(fresh: Boolean = false) {
            listen(pcm.file, segmented = true, fresh = fresh, label = "whole") { o ->
                when {
                    o.segmentedHonoured && o.segments.isNotEmpty() ->
                        finish(o.segments.joinToString(" "))
                    isDropped(o.error) && !freshRetryUsed -> {
                        freshRetryUsed = true
                        main.postDelayed({ whole(fresh = true) }, 300)
                    }
                    // Segmented mode ignored (plain onResults: only the first
                    // phrase), refused, or empty: go phrase by phrase.
                    else -> byPhrases()
                }
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
                            language = pick
                            whole()
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
                        language = first
                        whole()
                    }
                },
            )
        } catch (e: Exception) {
            note("support_threw")
            language = first
            whole()
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
