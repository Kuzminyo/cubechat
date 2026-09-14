package com.cubechat.cubechat

import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import java.lang.ref.WeakReference

/**
 * The incoming call as the phone itself would show it, when the app is not on
 * screen.
 *
 * Asked for as "a separate screen like the system phone, answer and decline,
 * when the app is minimised or closed". Until now a call to a phone whose app
 * was in the background did nothing visible at all: the Dart isolate received
 * the invite — the engine outlives the Activity, see [MainApplication] — and
 * rang a call screen nobody could see.
 *
 * Two surfaces, one notification. A `CATEGORY_CALL` notification with a
 * full-screen intent is what Android turns into [IncomingCallActivity] over the
 * lock screen or a sleeping display, and into a heads-up with Answer and
 * Decline on an unlocked one — the same split the dialler gets, decided by the
 * system rather than by guessing here.
 *
 * Driven entirely from Dart through [CubechatCallPlugin]: only Dart can decrypt
 * the invite, so only Dart knows a call exists and whose it is.
 */
object IncomingCall {
    /** v1 in the id because a channel's sound cannot be changed once created. */
    const val CHANNEL = "cubechat_calls_v1"
    const val TAG = "cubechat_call"
    const val ID = 7301

    const val ACTION_ANSWER = "com.cubechat.cubechat.ANSWER_CALL"
    const val ACTION_DECLINE = "com.cubechat.cubechat.DECLINE_CALL"
    const val EXTRA_KEY = "callKey"
    const val EXTRA_NAME = "callName"
    const val EXTRA_TITLE = "callTitle"
    const val EXTRA_ANSWER = "callAnswer"
    const val EXTRA_DECLINE = "callDecline"

    /**
     * Matches `CallTimings.noAnswer` in Dart. The system takes the notification
     * down on its own after this, so a phone whose process died mid-ring does
     * not keep ringing for a call that is long over.
     */
    private const val TIMEOUT_MS = 45_000L

    /** Words from Dart, which owns the translations. */
    data class Labels(val title: String, val answer: String, val decline: String)

    /** The call on screen now, so a late dismiss for an older one is ignored. */
    @Volatile
    var shownKey: String? = null
        private set

    private var screen: WeakReference<IncomingCallActivity>? = null

    fun attach(activity: IncomingCallActivity) {
        screen = WeakReference(activity)
    }

    fun detach(activity: IncomingCallActivity) {
        if (screen?.get() === activity) screen = null
    }

    /**
     * Ring. Returns whether the system will let the full-screen screen appear;
     * false means the heads-up alone, which still answers and declines.
     */
    fun show(context: Context, key: String, name: String, labels: Labels): Boolean {
        ensureChannel(context, labels.title)
        shownKey = key
        val manager = NotificationManagerCompat.from(context)
        val fullScreen = canUseFullScreen(context)
        val caller = Person.Builder().setName(name).setImportant(true).build()
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(name)
            .setContentText(labels.title)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setTimeoutAfter(TIMEOUT_MS)
            .addPerson(caller)
            .setContentIntent(screenIntent(context, key, name, labels))
            .setFullScreenIntent(screenIntent(context, key, name, labels), true)

        // CallStyle is what draws the green and red buttons the dialler has.
        // Android 12+ refuses a CallStyle that is neither a foreground service
        // nor full-screen, and 14 can take full-screen away from an app — so
        // without it this falls back to two ordinary actions rather than to a
        // notification the system drops.
        if (fullScreen || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            builder.setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    caller,
                    declineIntent(context, key),
                    answerIntent(context, key),
                ),
            )
        } else {
            builder
                .addAction(0, labels.decline, declineIntent(context, key))
                .addAction(0, labels.answer, answerIntent(context, key))
        }

        val notification = builder.build()
        // Ring and buzz until someone acts, the way a call does, instead of the
        // single chime a notification gets.
        notification.flags = notification.flags or android.app.Notification.FLAG_INSISTENT
        return try {
            manager.notify(TAG, ID, notification)
            fullScreen
        } catch (_: SecurityException) {
            // Notifications were refused. Nothing more can be shown from here.
            false
        }
    }

    /** Take the call off screen: answered, declined, or over elsewhere. */
    fun dismiss(context: Context, key: String?) {
        if (key != null && shownKey != null && key != shownKey) return
        shownKey = null
        NotificationManagerCompat.from(context).cancel(TAG, ID)
        screen?.get()?.finishRinging()
    }

    /**
     * Answer: open the app over whatever was on screen, and tell Dart.
     *
     * An Activity intent rather than a broadcast, because answering is the one
     * action that should bring the app forward — and Android 12 forbids a
     * receiver from starting an Activity on a notification's behalf.
     */
    fun answerIntent(context: Context, key: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(ACTION_ANSWER)
            .putExtra(EXTRA_KEY, key)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            REQUEST_ANSWER,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Decline stays in the background: nothing about it needs the app open. */
    fun declineIntent(context: Context, key: String): PendingIntent {
        val intent = Intent(context, IncomingCallReceiver::class.java)
            .setAction(ACTION_DECLINE)
            .putExtra(EXTRA_KEY, key)
        return PendingIntent.getBroadcast(
            context,
            REQUEST_DECLINE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun screenIntent(
        context: Context,
        key: String,
        name: String,
        labels: Labels,
    ): PendingIntent {
        val intent = Intent(context, IncomingCallActivity::class.java)
            .putExtra(EXTRA_KEY, key)
            .putExtra(EXTRA_NAME, name)
            .putExtra(EXTRA_TITLE, labels.title)
            .putExtra(EXTRA_ANSWER, labels.answer)
            .putExtra(EXTRA_DECLINE, labels.decline)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)
        return PendingIntent.getActivity(
            context,
            REQUEST_SCREEN,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * Android 14 lets the user — and Play — take full-screen intents away from
     * an app that is not a dialler or an alarm clock. Asked rather than assumed,
     * so the fallback above is chosen honestly.
     */
    fun canUseFullScreen(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as? NotificationManager ?: return false
        return manager.canUseFullScreenIntent()
    }

    fun isLocked(context: Context): Boolean {
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE)
            as? KeyguardManager ?: return false
        return keyguard.isKeyguardLocked
    }

    /**
     * The system ringtone, not the app's own tone, and a channel the user can
     * find in settings under the name they read on the call.
     *
     * The ringtone and not our file because this is the one sound on a phone
     * that people set on purpose, and it is also the one that Do Not Disturb,
     * silent mode and the ring volume already know how to treat.
     */
    private fun ensureChannel(context: Context, name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as? NotificationManager ?: return
        if (manager.getNotificationChannel(CHANNEL) != null) return
        val channel = NotificationChannel(CHANNEL, name, NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 800, 800, 800, 800)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    private const val REQUEST_ANSWER = 7302
    private const val REQUEST_DECLINE = 7303
    private const val REQUEST_SCREEN = 7304
}
