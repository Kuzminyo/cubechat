package com.cubechat.cubechat

import android.content.Context
import android.os.PowerManager

/**
 * The screen off while the phone is held to an ear, during a call.
 *
 * Android does this for its own dialler with a proximity wake lock, and it is
 * the same lock any app may take: while it is held the system watches the
 * proximity sensor and turns the display off when something is close to it,
 * back on when it goes. Without it a cheek on the glass was pressing mute and
 * hang up - "when you put it to your ear in a call, the screen should go off".
 *
 * Dart decides when (see `CallController._updateNearEar`); this only holds or
 * lets go. Released with WAIT_FOR_NO_PROXIMITY, so a call that ends with the
 * phone still at the ear lights the screen when it comes away rather than
 * while it is against a face.
 */
object NearEar {
    private var lock: PowerManager.WakeLock? = null

    /** A long call is still bounded: the lock cannot outlive four hours. */
    private const val LONGEST_MS = 4L * 60 * 60 * 1000

    @Synchronized
    fun watch(context: Context, on: Boolean) {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        if (on) {
            if (lock?.isHeld == true) return
            // Tablets and some phones have no proximity sensor at all.
            if (!power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
            lock = power.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "cubechat:near-ear",
            ).apply {
                setReferenceCounted(false)
                acquire(LONGEST_MS)
            }
        } else {
            val held = lock ?: return
            lock = null
            if (held.isHeld) held.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
        }
    }
}
