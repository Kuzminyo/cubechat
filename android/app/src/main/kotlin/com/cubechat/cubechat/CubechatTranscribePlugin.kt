package com.cubechat.cubechat

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
        main.post { start(path, locale, result) }
    }

    /**
     * The recogniser is bound to the main looper: every call has to be made
     * there, and every callback arrives there.
     */
    private fun start(path: String, locale: String?, result: MethodChannel.Result) {
        val recognizer = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (e: Exception) {
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
            result.success(text)
        }

        val descriptor = try {
            ParcelFileDescriptor.open(
                File(path),
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
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, 2)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
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
            recognizer.recognize(intent)
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
