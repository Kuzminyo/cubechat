package com.cubechat.cubechat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the cubechat process alive while the app is backgrounded so the BLE
 * peripheral (advertising + GATT server) and central scanning keep running —
 * i.e. another phone can still discover us and write to us when the app isn't
 * in the foreground. Android only spares a process with an active foreground
 * service from being reclaimed under memory pressure, and a foreground service
 * must show an ongoing notification.
 *
 * START_STICKY + stopWithTask=false (manifest) ask the OS to keep/restart the
 * service across task removal. On aggressive OEMs (Samsung) the user must also
 * exempt the app from battery optimisation — the Dart side prompts for that.
 */
class MeshForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        return START_STICKY
    }

    private fun startAsForeground() {
        createChannel()
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Cubechat active")
            .setContentText("Staying reachable over Bluetooth mesh")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    "Mesh activity",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps Cubechat reachable over Bluetooth in the background"
                    setShowBadge(false)
                }
                mgr.createNotificationChannel(ch)
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "cubechat_mesh"
        const val NOTIF_ID = 4201

        fun start(ctx: Context) {
            val i = Intent(ctx, MeshForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(i)
                } else {
                    ctx.startService(i)
                }
            } catch (e: Exception) {
                // Android 12+ throws ForegroundServiceStartNotAllowedException
                // if we try to start from the background (e.g. headless engine
                // boot). The Dart side re-applies on app resume, which is an
                // allowed state, so swallow it here.
                android.util.Log.w("MeshFGS", "startForegroundService blocked: ${e.message}")
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, MeshForegroundService::class.java))
        }
    }
}
