package com.cubechat.cubechat

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The channel between Dart's call controller and [IncomingCall].
 *
 * Registered on the Application's engine, like [CubechatPushPlugin], because it
 * has to work with no Activity at all: that is the whole situation it exists
 * for.
 *
 * Dart to here: `show` and `dismiss`. Here to Dart: `answer` and `decline`,
 * each with the call's key. A button pressed before Dart has a handler — the
 * isolate busy starting up — is held and handed over by `takePending`, so an
 * answer is never lost to a race with startup.
 */
class CubechatCallPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private var pending: Pair<String, String>? = null

    init {
        instance = this
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val key = call.argument<String>("key")
                    val name = call.argument<String>("name")
                    if (key == null || name == null) {
                        result.error("args", "key and name are required", null)
                        return@setMethodCallHandler
                    }
                    val labels = IncomingCall.Labels(
                        title = call.argument<String>("title").orEmpty(),
                        answer = call.argument<String>("answer").orEmpty(),
                        decline = call.argument<String>("decline").orEmpty(),
                    )
                    result.success(IncomingCall.show(context, key, name, labels))
                }
                "dismiss" -> {
                    IncomingCall.dismiss(context, call.argument<String>("key"))
                    result.success(null)
                }
                "takePending" -> {
                    val held = pending
                    pending = null
                    result.success(held?.let { mapOf("action" to it.first, "key" to it.second) })
                }
                else -> result.notImplemented()
            }
        }
    }

    /** A button was pressed. Always delivered on the main thread, as channels require. */
    fun deliver(action: String, key: String) {
        main.post {
            pending = action to key
            channel.invokeMethod(
                action,
                mapOf("key" to key),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (pending == action to key) pending = null
                    }

                    override fun error(code: String, message: String?, details: Any?) {}

                    // No handler yet: keep it for takePending.
                    override fun notImplemented() {}
                },
            )
        }
    }

    companion object {
        const val CHANNEL = "cubechat/incoming_call"

        @Volatile
        var instance: CubechatCallPlugin? = null
            private set
    }
}
