package com.cubechat.cubechat

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * The phone's own ringtone and vibration, for a call ringing while the app is
 * on screen.
 *
 * "No sound when it rings" was reported twice. The first ring was a sound file
 * played through the app's media plugin, and that path could stay silent - the
 * plugin's context is shared with voice notes, and a ringtone that depends on
 * what a voice note left behind is not a ringtone. This is the system's: the
 * ringtone the person chose, on the ring stream, at the ring volume, silent in
 * silent mode and buzzing in vibrate mode, exactly like the dialler.
 */
object CallRinger {
    private var ringtone: Ringtone? = null
    private var vibrating: Vibrator? = null
    private val main = Handler(Looper.getMainLooper())

    /** Before Android 9 a ringtone cannot loop on its own; this restarts it. */
    private val replay = object : Runnable {
        override fun run() {
            val tone = ringtone ?: return
            if (!tone.isPlaying) tone.play()
            main.postDelayed(this, 1000)
        }
    }

    fun start(context: Context) {
        main.post {
            stopNow()
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            val mode = audio?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL
            if (mode == AudioManager.RINGER_MODE_SILENT) return@post
            if (mode == AudioManager.RINGER_MODE_NORMAL) playTone(context)
            vibrate(context)
        }
    }

    fun stop() {
        main.post { stopNow() }
    }

    private var tones: ToneGenerator? = null

    /**
     * The long tones a caller hears while the other phone rings.
     *
     * `ToneGenerator` on the voice-call stream, the dialler's own source: it
     * is synthesised in the media server, follows the in-call volume and the
     * route the call is using, and - unlike a player - changes neither the
     * audio mode nor the focus. That is the whole reason there was no ringback
     * before: the app's player writes the mode process-wide and would have
     * pulled the audio out from under WebRTC as the call connected (see
     * `AudioCallTones`). The country's own cadence comes from the tone itself.
     */
    fun ringback() {
        main.post {
            stopNow()
            generator()?.startTone(ToneGenerator.TONE_SUP_RINGTONE)
        }
    }

    /**
     * Three short tones when a call ends, once: the "line dropped" sound.
     * Congestion's cadence, 250 ms on and off, is the short beeping people
     * expect from a phone whose call is over.
     */
    fun ended() {
        main.post {
            stopNow()
            generator()?.startTone(ToneGenerator.TONE_SUP_CONGESTION, END_TONE_MS)
            main.postDelayed(releaseTones, END_TONE_MS + 200L)
        }
    }

    private val releaseTones = Runnable { releaseGenerator() }

    private fun generator(): ToneGenerator? {
        tones?.let { return it }
        return try {
            ToneGenerator(AudioManager.STREAM_VOICE_CALL, TONE_VOLUME).also { tones = it }
        } catch (_: RuntimeException) {
            // The media server refused a generator - it has a small pool. A
            // silent ringback is not worth failing the call over.
            null
        }
    }

    private fun releaseGenerator() {
        try {
            tones?.stopTone()
            tones?.release()
        } catch (_: Exception) {
        }
        tones = null
    }

    private const val END_TONE_MS = 1400
    private const val TONE_VOLUME = 80

    private fun playTone(context: Context) {
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(
                context,
                RingtoneManager.TYPE_RINGTONE,
            ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val tone = RingtoneManager.getRingtone(context, uri) ?: return
            tone.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                tone.isLooping = true
            } else {
                main.postDelayed(replay, 1000)
            }
            tone.play()
            ringtone = tone
        } catch (_: Exception) {
            // No ringtone set, or the media server refused. The vibration and
            // the screen still say it.
        }
    }

    private fun vibrate(context: Context) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        } ?: return
        if (!vibrator.hasVibrator()) return
        val pattern = longArrayOf(0, 800, 800)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createWaveform(pattern, 0),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .build(),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, 0)
            }
            vibrating = vibrator
        } catch (_: Exception) {
        }
    }

    private fun stopNow() {
        main.removeCallbacks(replay)
        main.removeCallbacks(releaseTones)
        releaseGenerator()
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
        try {
            vibrating?.cancel()
        } catch (_: Exception) {
        }
        vibrating = null
    }
}
