package com.cubechat.cubechat

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The FCM half of the doorbell — the Android counterpart of
 * `CubechatPushPlugin.swift`, deliberately down to the channel name.
 *
 * A phone whose task has been swiped away receives nothing on the builds where
 * the manufacturer also kills the foreground service, which is most of them.
 * FCM is the one mechanism Google provides for "wake up, there is a message",
 * and like APNs it needs a token that only the system can hand out.
 *
 * This plugin is the whole of the native side: ask for the notification
 * permission where one is required, fetch the token, hand it to Dart. What
 * happens to the token afterwards — signing it into a Nostr event and posting
 * that to the push service — stays in Dart, because that is where the identity
 * key lives and it is not going to be lifted out for this.
 *
 * Registered on the *Application*'s engine rather than the Activity's, because
 * that engine runs Dart `main()` headless before any Activity exists (see
 * [MainApplication]) and `PushEnabled` re-asserts the switch from there on
 * every launch. Installed on the Activity instead, that call would land on a
 * channel nobody had created yet and come back as "this build has no push
 * support" — on a build that has it.
 *
 * Only the permission dialog needs a window, so only that part waits for an
 * Activity; [attach] hands one over when there is one.
 */
class CubechatPushPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL_NAME = "cubechat/push"

        /** Matches nothing in particular; only this plugin reads it back. */
        private const val PERMISSION_REQUEST = 9713

        /**
         * The tag the push service stamps on the banner it asks Google to draw
         * — `android.notification.tag` in `sendFcm`, and the two halves of this
         * contract have to stay in step. The id beside it is 0 because that is
         * what the Firebase SDK passes to `notify` for a message it displays
         * itself.
         */
        private const val DOORBELL_TAG = "cubechat"
        private const val DOORBELL_ID = 0

        /** So the Activity can find the one the Application registered. */
        @Volatile
        var instance: CubechatPushPlugin? = null
            private set
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    /** Whatever Activity is on screen, or null while the app runs headless. */
    private var activity: Activity? = null

    /** Set while a permission dialog is up, so its answer has somewhere to go. */
    private var pending: MethodChannel.Result? = null

    init {
        instance = this
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "register" -> register(result)
                // iOS carries the app-icon badge here. Android draws its own
                // count on the launcher from the notification itself, so there
                // is nothing to set — answered rather than left to throw a
                // MissingPluginException into the Dart log every time.
                "setBadge" -> result.success(null)
                // Dart tells us whether the app is on screen, because the
                // service that decides whether to ring the doorbell is
                // constructed by the system per message and can see nothing the
                // app has built. See [CubechatFcmService.foreground].
                "setForeground" -> {
                    CubechatFcmService.foreground =
                        call.arguments as? Boolean ?: false
                    result.success(null)
                }
                // The app has just drawn the real notification for a message
                // the doorbell also rang about. Only this side can take the
                // placeholder down: it was posted by the Firebase SDK, not by
                // flutter_local_notifications, so nothing in Dart owns it.
                "dismissDoorbell" -> {
                    try {
                        NotificationManagerCompat.from(context)
                            .cancel(DOORBELL_TAG, DOORBELL_ID)
                    } catch (_: Exception) {
                        // A duplicate banner is not worth an exception on the
                        // path that shows every message notification.
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Called by [MainActivity] when it comes up. */
    fun attach(activity: Activity) {
        this.activity = activity
    }

    /**
     * Called by [MainActivity] on its way out — by the one going away, which
     * during a rotation is not necessarily the one currently held. Clearing
     * unconditionally there would take the incoming Activity's window away a
     * moment after it was lent.
     */
    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        this.activity = null
        // A dialog cannot outlive the window it was raised from. Answered
        // rather than dropped, so the Dart side's switch settles back instead
        // of waiting on a future that will never complete.
        pending?.success(null)
        pending = null
    }

    /**
     * What the user has already decided, without asking them again.
     *
     * `granted` / `denied` / `undecided`, the same three words iOS answers, so
     * the Dart side needs no platform branch to read it.
     *
     * Below Android 13 there is no notification permission at all and posting
     * one needs no consent, so the honest answer there is `granted` — unless
     * notifications have been switched off for the app in settings, which
     * `NotificationManagerCompat` reports and which means exactly `denied`.
     */
    private fun status(): String {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            return "denied"
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "granted"
        return if (notificationsPermitted()) "granted" else "undecided"
    }

    private fun notificationsPermitted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED

    /**
     * Ask if we must, then fetch the token.
     *
     * The permission and the token are separate things on Android — a token is
     * issued whether or not notifications may be shown — but asking for one
     * without the other would leave the service ringing a phone that cannot
     * draw anything, which is indistinguishable from being broken.
     */
    private fun register(result: MethodChannel.Result) {
        if (notificationsPermitted()) {
            fetchToken(result)
            return
        }
        val host = activity
        if (host == null) {
            // Launch re-assertion, running before the window exists. Not an
            // error worth showing: the switch is already off in this state, and
            // the next tap on it happens with an Activity on screen.
            result.success(null)
            return
        }
        if (pending != null) {
            result.error("busy", "a permission request is already in flight", null)
            return
        }
        pending = result
        ActivityCompat.requestPermissions(
            host,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST,
        )
    }

    /**
     * Called by the Activity when a permission dialog is answered. True when
     * this was ours, so the Activity knows not to pass it on.
     */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val result = pending ?: return true
        pending = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        // Not an error: a decision. The caller turns its switch back off, the
        // same way it does for a refusal on iOS.
        if (!granted) result.success(null) else fetchToken(result)
        return true
    }

    private fun fetchToken(result: MethodChannel.Result) {
        FirebaseMessaging.getInstance().token
            .addOnCompleteListener { task ->
                val token = if (task.isSuccessful) task.result else null
                if (!token.isNullOrEmpty()) {
                    result.success(token)
                    return@addOnCompleteListener
                }
                // The two that actually happen: a build with no
                // google-services.json behind it, and a device with no Google
                // Play services at all. Both are "this phone cannot be rung",
                // and both deserve to say so rather than fail silently.
                val message = task.exception?.localizedMessage ?: "no token"
                result.error("fcm", message, null)
            }
    }
}
