package com.cubechat.cubechat

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Decides whether the doorbell is worth ringing, which the system cannot.
 *
 * The service sends a data-only message now rather than one with a
 * `notification` block. That is the whole point: a `notification` block is
 * drawn by the system before any of this app's code runs, so a phone whose
 * process was alive and about to show a proper notification — sender, face,
 * text — showed the generic one first and had it taken away a moment later.
 * Asked for as: the wake-up banner only when the app is really closed, and
 * ordinary notifications every other time.
 *
 * A data message with `priority: high` wakes a process that has been swiped
 * away exactly as an alert does, so nothing is lost in the case the doorbell
 * exists for. What is gained is this decision.
 *
 * **The compatibility cost, said plainly.** A build older than this one has no
 * service to receive a data message, and its default handler draws nothing — so
 * an older install stops getting push the day the server changes shape. That is
 * a real break and it is why this went out with the server change in the same
 * build.
 */
class CubechatFcmService : FirebaseMessagingService() {
    companion object {
        /**
         * Whether the app is on screen, told by Dart on every lifecycle change.
         *
         * Static because this service is constructed by the system, per message,
         * with no access to anything the app has built.
         */
        @Volatile
        var foreground: Boolean = false

        /** Where the placeholder is posted, so the app can take it down. */
        const val DOORBELL_TAG = "cubechat"
        const val DOORBELL_ID = 0

        /// Long enough for a live app to have shown its own notification.
        ///
        /// The app has to decrypt the message from the relay before it can say
        /// anything about it, and that is a network round trip. Under a second
        /// is optimistic; much over two is a doorbell that arrives late enough
        /// to feel like a second message.
        private const val GRACE_MS = 2200L
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // On screen: whatever is worth saying, the app is already saying. A
        // banner over the conversation it is about is noise.
        if (foreground) return

        val body = message.data["body"]?.takeIf { it.isNotEmpty() }
            ?: getString(R.string.push_default_body)

        // Wait, then look. The app being *alive* is not the question — the
        // question is whether it managed to show something, and only the
        // notification drawer knows that. A process the system started for this
        // very message is alive too, and it has nothing to show yet.
        //
        // Blocking is allowed here: onMessageReceived runs on a background
        // thread the library owns, and it gives us ten seconds.
        try {
            Thread.sleep(GRACE_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return
        }
        if (foreground) return
        if (appAlreadySaidSomething()) return

        ring(body)
    }

    /**
     * Whether a notification from this app is already in the drawer.
     *
     * Only ours, and only in the channel messages use — a file-transfer or a
     * foreground-service notice is not somebody writing, and treating one as
     * "handled" would swallow the doorbell for a real message.
     *
     * Below Android 23 there is no way to ask, and the honest answer is to ring:
     * a duplicate is a nuisance and silence is a lost message.
     */
    private fun appAlreadySaidSomething(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val manager = getSystemService(Context.NOTIFICATION_SERVICE)
            as? NotificationManager ?: return false
        return try {
            manager.activeNotifications.any { posted ->
                posted.notification?.channelId == MESSAGES_CHANNEL &&
                    posted.tag != DOORBELL_TAG
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun ring(body: String) {
        val manager = NotificationManagerCompat.from(this)
        if (!manager.areNotificationsEnabled()) return
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pending = open?.let {
            android.app.PendingIntent.getActivity(
                this,
                0,
                it,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                    android.app.PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val notification = NotificationCompat.Builder(this, MESSAGES_CHANNEL)
            // The monochrome mask, not the launcher icon.
            //
            // Android draws a small icon from its ALPHA CHANNEL alone and
            // throws the colours away, so a full-colour launcher icon arrives
            // as a solid block — reported from a Xiaomi as a black square. The
            // drawable that fixes it was added in 977 and wired into the
            // Flutter plugin only, which covers every notification the app
            // draws itself and misses this one: the doorbell, drawn by this
            // service when the app is closed, which is the only banner most
            // people ever see.
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.push_default_title))
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        try {
            manager.notify(DOORBELL_TAG, DOORBELL_ID, notification)
        } catch (_: SecurityException) {
            // The permission was taken away between the check and the post.
        }
    }
}

/// The channel NotificationService pre-creates at launch, named here so the
/// doorbell lands in the same place as every other message notification.
private const val MESSAGES_CHANNEL = "cubechat_messages"
