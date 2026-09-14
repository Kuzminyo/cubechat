package com.cubechat.cubechat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Decline from the heads-up, without opening anything.
 *
 * The Dart isolate is alive whenever there is a notification to decline — it is
 * what posted it — so this only has to hand the word over and take the
 * notification down.
 */
class IncomingCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val key = intent.getStringExtra(IncomingCall.EXTRA_KEY) ?: return
        when (intent.action) {
            IncomingCall.ACTION_DECLINE -> {
                CubechatCallPlugin.instance?.deliver("decline", key)
                IncomingCall.dismiss(context, key)
            }
            // Hang up from the call in the notification shade.
            CallService.ACTION_HANGUP -> {
                CubechatCallPlugin.instance?.deliver("end", key)
                CallService.stop(context)
            }
        }
    }
}
