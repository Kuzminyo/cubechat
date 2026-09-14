package com.cubechat.cubechat

import android.app.AppOpsManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
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
 * Two surfaces, one notification, and the system chooses between them the way
 * it does for the dialler: a `CATEGORY_CALL` notification with a full-screen
 * intent becomes [IncomingCallActivity] over the lock screen or a sleeping
 * display, and the heads-up with Answer and Decline on a phone in use.
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
    const val EXTRA_ONGOING = "callOngoing"
    const val EXTRA_HANG_UP = "callHangUp"
    const val EXTRA_SPEAKER = "callSpeaker"

    /**
     * Matches `CallTimings.noAnswer` in Dart. The system takes the notification
     * down on its own after this, so a phone whose process died mid-ring does
     * not keep ringing for a call that is long over.
     */
    private const val TIMEOUT_MS = 45_000L

    /** Words from Dart, which owns the translations. */
    data class Labels(
        val title: String,
        val answer: String,
        val decline: String,
        val ongoing: String = "",
        val hangUp: String = "",
        val speaker: String = "",
    )

    /** The call on screen now, so a late dismiss for an older one is ignored. */
    @Volatile
    var shownKey: String? = null
        private set

    /** Who is calling, for the call that gets answered without the app. */
    @Volatile
    private var shownName: String = ""

    @Volatile
    private var shownLabels: Labels? = null

    private var screen: WeakReference<IncomingCallActivity>? = null

    /**
     * The caller's picture for the screen, held here rather than in the intent:
     * an avatar is tens of kilobytes and an intent is not where that goes.
     */
    @Volatile
    var avatar: Bitmap? = null
        private set

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
    fun show(
        context: Context,
        key: String,
        name: String,
        labels: Labels,
        picture: Bitmap? = null,
    ): Boolean {
        ensureChannel(context, labels.title)
        shownKey = key
        shownName = name
        shownLabels = labels
        avatar = picture
        val manager = NotificationManagerCompat.from(context)
        val fullScreen = canUseFullScreen(context)
        val caller = Person.Builder()
            .setName(name)
            .setImportant(true)
            .apply { picture?.let { setIcon(IconCompat.createWithBitmap(it)) } }
            .build()
        val answer = answerIntent(context, key, name, labels)
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
            // The round picture beside the name. CallStyle takes its picture
            // from the Person, but some shades - MIUI's among them - draw the
            // large icon instead, and that one was the square in the report.
            .apply { picture?.let { setLargeIcon(it) } }

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
                    answer,
                ),
            )
        } else {
            builder
                .addAction(0, labels.decline, declineIntent(context, key))
                .addAction(0, labels.answer, answer)
        }

        val notification = builder.build()
        // Ring and buzz until someone acts, the way a call does, instead of the
        // single chime a notification gets.
        notification.flags = notification.flags or android.app.Notification.FLAG_INSISTENT
        val posted = try {
            manager.notify(TAG, ID, notification)
            true
        } catch (_: SecurityException) {
            false
        }
        // **No screen of our own on a phone in use - the shade only.**
        //
        // 1045 opened [IncomingCallActivity] directly whenever "appear on top"
        // was granted, so on an unlocked phone the call came up twice: the
        // heads-up, and the whole screen behind it. "Remove the screen, leave
        // only the shade" came back with a screenshot of exactly that. The
        // full-screen intent above still gives the lock screen and a dark
        // display their screen - that decision is the system's, as it is for
        // the dialler - and nothing here second-guesses it any more. Which also
        // means "appear on top" is no longer asked for at all.
        return posted && fullScreen
    }

    /**
     * Xiaomi, Redmi and Poco add a permission of their own on top of Android's -
     * "show on lock screen" - and without it the full-screen intent opens
     * nothing over a locked phone. It cannot be granted by an app, only
     * pointed at.
     */
    fun isXiaomiFamily(): Boolean {
        val brand = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        return listOf("xiaomi", "redmi", "poco").any { brand.contains(it) }
    }

    /**
     * MIUI's own switches, read where MIUI keeps them: app-ops Android has no
     * names for. 10020 is "show on lock screen". Off by default for an app that
     * did not come from Xiaomi's store. True when this is not MIUI or the value
     * cannot be read, so nobody is nagged about a switch they do not have.
     */
    fun miuiAllows(context: Context, op: Int): Boolean {
        if (!isXiaomiFamily()) return true
        return try {
            val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val check = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            val mode = check.invoke(ops, op, android.os.Process.myUid(), context.packageName) as Int
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            true
        }
    }

    const val MIUI_SHOW_WHEN_LOCKED = 10020

    /** Take the call off screen: answered, declined, or over elsewhere. */
    fun dismiss(context: Context, key: String?) {
        if (key != null && shownKey != null && key != shownKey) return
        shownKey = null
        NotificationManagerCompat.from(context).cancel(TAG, ID)
        screen?.get()?.finishRinging()
    }

    /** The call is over: a lock-screen call screen still showing it goes too. */
    fun callOver() {
        avatar = null
        screen?.get()?.finishCall()
    }

    /**
     * **Answered from the lock screen, and nothing asks for the unlock.**
     *
     * "To take a call you have to unlock the phone, very inconvenient" was the
     * report. Answer used to open the app, and the app is behind the lock, so
     * Android put the PIN pad up first and the call waited behind it. Now the
     * answer on a locked phone is a broadcast: the call is taken right there,
     * its foreground service starts in the same moment - a notification action
     * is one of the few things Android lets start a microphone service from the
     * background - and the call goes on in the shade with Hang up. The app
     * opens when the phone is unlocked and the call is tapped.
     *
     * On a phone that is already unlocked, Answer still opens the app, which
     * is what somebody holding it expects. Which of the two is chosen when the
     * call starts ringing.
     */
    fun answerInBackground(context: Context, key: String) {
        if (key != shownKey) return
        val labels = shownLabels
        CallService.show(
            context,
            CallService.State(
                key = key,
                name = shownName,
                avatar = avatar,
                since = System.currentTimeMillis(),
                title = labels?.ongoing.orEmpty(),
                hangUp = labels?.hangUp.orEmpty(),
            ),
        )
        CubechatCallPlugin.instance?.deliver("answer", key)
        dismiss(context, key)
    }

    private fun answerIntent(
        context: Context,
        key: String,
        name: String,
        labels: Labels,
    ): PendingIntent {
        if (isLocked(context)) {
            return PendingIntent.getBroadcast(
                context,
                REQUEST_ANSWER,
                Intent(context, IncomingCallReceiver::class.java)
                    .setAction(ACTION_ANSWER)
                    .putExtra(EXTRA_KEY, key),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        // An Activity rather than a broadcast here, because answering on a
        // phone in use should bring the app forward — and Android 12 forbids a
        // receiver from starting an Activity on a notification's behalf.
        val intent = Intent(context, MainActivity::class.java)
            .setAction(ACTION_ANSWER)
            .putExtra(EXTRA_KEY, key)
            .putExtra(EXTRA_NAME, name)
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

    private fun screenIntentFor(
        context: Context,
        key: String,
        name: String,
        labels: Labels,
    ): Intent = Intent(context, IncomingCallActivity::class.java)
        .putExtra(EXTRA_KEY, key)
        .putExtra(EXTRA_NAME, name)
        .putExtra(EXTRA_TITLE, labels.title)
        .putExtra(EXTRA_ANSWER, labels.answer)
        .putExtra(EXTRA_DECLINE, labels.decline)
        .putExtra(EXTRA_ONGOING, labels.ongoing)
        .putExtra(EXTRA_HANG_UP, labels.hangUp)
        .putExtra(EXTRA_SPEAKER, labels.speaker)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)

    private fun screenIntent(
        context: Context,
        key: String,
        name: String,
        labels: Labels,
    ): PendingIntent {
        val intent = screenIntentFor(context, key, name, labels)
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
