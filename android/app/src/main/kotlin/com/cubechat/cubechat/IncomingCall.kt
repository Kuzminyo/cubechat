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
        avatar = picture
        val manager = NotificationManagerCompat.from(context)
        val fullScreen = canUseFullScreen(context)
        val caller = Person.Builder()
            .setName(name)
            .setImportant(true)
            .apply { picture?.let { setIcon(IconCompat.createWithBitmap(it)) } }
            .build()
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
        val posted = try {
            manager.notify(TAG, ID, notification)
            true
        } catch (_: SecurityException) {
            // Notifications were refused. The screen below may still open.
            false
        }
        // **The whole screen, not a banner, on an unlocked phone too.**
        //
        // A full-screen intent only becomes a screen over the lock screen or a
        // dark display; on a phone in use Android turns it into the heads-up,
        // and "a notification with Answer and Decline is not convenient, it has
        // to be a real screen" was the report on exactly that. Android lets an
        // app open an Activity from the background only with the "appear on
        // top" permission, which the user grants in settings - so with it the
        // screen is opened directly, and without it the heads-up is what is
        // left. The notification stays either way: it carries the ringtone, and
        // it is what the lock screen uses.
        // On MIUI its own "pop-up windows in the background" switch is what lets
        // that start through, with or without Android's.
        val mayOpen = canDrawOverlays(context) ||
            (isXiaomiFamily() && miuiAllows(context, MIUI_BACKGROUND_START))
        val opened = mayOpen && openScreen(context, key, name, labels)
        return posted && fullScreen || opened
    }

    private fun openScreen(context: Context, key: String, name: String, labels: Labels): Boolean =
        try {
            context.startActivity(screenIntentFor(context, key, name, labels))
            true
        } catch (_: Exception) {
            // Refused anyway - some vendors add their own gate on top of the
            // permission. The heads-up is still there.
            false
        }

    fun canDrawOverlays(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            android.provider.Settings.canDrawOverlays(context)

    /**
     * Xiaomi, Redmi and Poco add two permissions of their own on top of
     * Android's - "show on lock screen" and "open windows while running in the
     * background" - and without them neither the full-screen intent nor a
     * direct launch opens anything. They cannot be read from an app, only
     * pointed at.
     */
    fun isXiaomiFamily(): Boolean {
        val brand = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        return listOf("xiaomi", "redmi", "poco").any { brand.contains(it) }
    }

    /**
     * MIUI's own switches, read where MIUI keeps them: two app-ops Android has
     * no names for. 10020 is "show on lock screen", 10021 "open new windows
     * while running in the background". Off by default for an app that did not
     * come from Xiaomi's store, and with either off the call screen never opens
     * over a locked phone - which is how "when the screen is locked, the call
     * screen should open" was reported. True when this is not MIUI or the
     * value cannot be read, so nobody is nagged about a switch they do not have.
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
    const val MIUI_BACKGROUND_START = 10021

    /** Take the call off screen: answered, declined, or over elsewhere. */
    fun dismiss(context: Context, key: String?) {
        if (key != null && shownKey != null && key != shownKey) return
        shownKey = null
        avatar = null
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
