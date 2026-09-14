package com.cubechat.cubechat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * A call in progress, in the notification shade - the way Telegram keeps one
 * there, with the name, the running time and a red Hang up.
 *
 * It is a foreground service rather than only a notification, for two reasons
 * that are each enough. Android 11 and later silence the microphone of an app
 * that is not on screen unless a foreground service of the `microphone` type is
 * running: a call answered from the lock screen, or continued after pressing
 * Home, would otherwise go on with the other side hearing nothing. And an
 * ongoing `CallStyle` notification - the one with the green chip in the status
 * bar - is only allowed to a foreground service.
 */
class CallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = current ?: run {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = build(this, state)
        try {
            ServiceCompat.startForeground(
                this,
                ID,
                notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            // Refused - started from the background with no user action behind
            // it. The call still shows in the shade, without the service.
            android.util.Log.w("CallService", "startForeground refused: ${e.message}")
            postPlain(this, state)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
    }

    data class State(
        val key: String,
        val name: String,
        val avatar: Bitmap?,
        val since: Long,
        val title: String,
        val hangUp: String,
    )

    companion object {
        private const val CHANNEL = "cubechat_ongoing_call_v1"
        private const val ID = 7310
        const val ACTION_HANGUP = "com.cubechat.cubechat.HANGUP_CALL"

        @Volatile
        private var current: State? = null

        fun show(context: Context, state: State) {
            val same = current?.key == state.key
            current = state
            ensureChannel(context, state.title)
            if (same) {
                // Already running: only the notification changes (the name
                // arrived, or the call connected and the clock starts).
                try {
                    NotificationManagerCompat.from(context).notify(ID, build(context, state))
                } catch (_: SecurityException) {
                }
                return
            }
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, CallService::class.java),
                )
            } catch (e: Exception) {
                android.util.Log.w("CallService", "start refused: ${e.message}")
                postPlain(context, state)
            }
        }

        fun stop(context: Context) {
            current = null
            IncomingCall.callOver()
            try {
                context.stopService(Intent(context, CallService::class.java))
            } catch (_: Exception) {
            }
            NotificationManagerCompat.from(context).cancel(ID)
        }

        private fun build(context: Context, state: State): android.app.Notification {
            val person = Person.Builder()
                .setName(state.name)
                .setImportant(true)
                .apply { state.avatar?.let { setIcon(IconCompat.createWithBitmap(it)) } }
                .build()
            val open = PendingIntent.getActivity(
                context,
                7311,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(state.name)
                .setContentText(state.title)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setWhen(state.since)
                .setContentIntent(open)
                .setStyle(NotificationCompat.CallStyle.forOngoingCall(person, hangUpIntent(context, state.key)))
                .build()
        }

        /** Without the service a CallStyle is refused, so this is a plain one. */
        private fun postPlain(context: Context, state: State) {
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(state.name)
                .setContentText(state.title)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setUsesChronometer(true)
                .setWhen(state.since)
                .addAction(0, state.hangUp, hangUpIntent(context, state.key))
                .build()
            try {
                NotificationManagerCompat.from(context).notify(ID, notification)
            } catch (_: SecurityException) {
            }
        }

        private fun hangUpIntent(context: Context, key: String): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                7312,
                Intent(context, IncomingCallReceiver::class.java)
                    .setAction(ACTION_HANGUP)
                    .putExtra(IncomingCall.EXTRA_KEY, key),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        /** Quiet: this is a call already happening, not one asking for attention. */
        private fun ensureChannel(context: Context, name: String) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager ?: return
            if (manager.getNotificationChannel(CHANNEL) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, name, NotificationManager.IMPORTANCE_LOW).apply {
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }
    }
}
