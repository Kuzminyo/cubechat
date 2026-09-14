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
                        ongoing = call.argument<String>("ongoing").orEmpty(),
                        hangUp = call.argument<String>("hangUp").orEmpty(),
                        speaker = call.argument<String>("speaker").orEmpty(),
                        microphone = call.argument<String>("microphone").orEmpty(),
                    )
                    result.success(
                        IncomingCall.show(
                            context,
                            key,
                            name,
                            labels,
                            decodeAvatar(call.argument<ByteArray>("avatar")),
                        ),
                    )
                }
                "dismiss" -> {
                    IncomingCall.dismiss(context, call.argument<String>("key"))
                    result.success(null)
                }
                // What stands between a call and a real screen on this phone.
                "access" -> result.success(
                    mapOf(
                        "fullScreenIntent" to IncomingCall.canUseFullScreen(context),
                        "xiaomi" to IncomingCall.isXiaomiFamily(),
                        "xiaomiLockScreen" to IncomingCall.miuiAllows(
                            context,
                            IncomingCall.MIUI_SHOW_WHEN_LOCKED,
                        ),
                    ),
                )
                "ringStart" -> {
                    CallRinger.start(context)
                    result.success(null)
                }
                "ringStop" -> {
                    CallRinger.stop()
                    result.success(null)
                }
                "ringbackStart" -> {
                    CallRinger.ringback()
                    result.success(null)
                }
                "endTone" -> {
                    CallRinger.ended()
                    result.success(null)
                }
                "ongoing" -> {
                    val key = call.argument<String>("key")
                    if (key == null) {
                        result.error("args", "key is required", null)
                        return@setMethodCallHandler
                    }
                    CallService.show(
                        context,
                        CallService.State(
                            key = key,
                            name = call.argument<String>("name").orEmpty(),
                            avatar = decodeAvatar(call.argument<ByteArray>("avatar")),
                            since = call.argument<Number>("since")?.toLong()
                                ?: System.currentTimeMillis(),
                            title = call.argument<String>("title").orEmpty(),
                            hangUp = call.argument<String>("hangUp").orEmpty(),
                        ),
                    )
                    result.success(null)
                }
                "ongoingStop" -> {
                    CallService.stop(context)
                    result.success(null)
                }
                "openFullScreenSettings" -> result.success(
                    if (android.os.Build.VERSION.SDK_INT >= 34) {
                        openSettings(
                            android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                            withPackage = true,
                        )
                    } else {
                        false
                    },
                )
                "openVendorSettings" -> result.success(openVendorSettings())
                "takePending" -> {
                    val held = pending
                    pending = null
                    result.success(held?.let { mapOf("action" to it.first, "key" to it.second) })
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * A JPEG from Dart, as a round picture a notification can use.
     *
     * Cropped to its centre square first - it used to be squeezed to 256 by
     * 256 whatever its shape - and then cut to a circle with transparent
     * corners, because the shade draws what it is given: "make the avatar
     * round in the shade" came with a square one in the screenshot. The call
     * screens clip it round themselves, so the circle costs them nothing.
     */
    private fun decodeAvatar(bytes: ByteArray?): android.graphics.Bitmap? {
        if (bytes == null || bytes.isEmpty()) return null
        return try {
            val raw = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: return null
            val edge = minOf(raw.width, raw.height)
            val side = minOf(edge, 256)
            val round = android.graphics.Bitmap.createBitmap(
                side,
                side,
                android.graphics.Bitmap.Config.ARGB_8888,
            )
            val canvas = android.graphics.Canvas(round)
            val paint = android.graphics.Paint(
                android.graphics.Paint.ANTI_ALIAS_FLAG or android.graphics.Paint.FILTER_BITMAP_FLAG,
            )
            canvas.drawOval(0f, 0f, side.toFloat(), side.toFloat(), paint)
            paint.xfermode = android.graphics.PorterDuffXfermode(
                android.graphics.PorterDuff.Mode.SRC_IN,
            )
            val left = (raw.width - edge) / 2
            val top = (raw.height - edge) / 2
            canvas.drawBitmap(
                raw,
                android.graphics.Rect(left, top, left + edge, top + edge),
                android.graphics.Rect(0, 0, side, side),
                paint,
            )
            round
        } catch (_: Exception) {
            null
        }
    }

    private fun openSettings(action: String, withPackage: Boolean): Boolean = try {
        val intent = android.content.Intent(action)
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        if (withPackage) {
            intent.data = android.net.Uri.parse("package:${context.packageName}")
        }
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    /**
     * MIUI's own permission page for this app, where "show on lock screen" and
     * "pop-up windows in the background" live. Not a public API, so it falls
     * back to the ordinary app settings page when the activity is not there.
     */
    private fun openVendorSettings(): Boolean {
        val miui = android.content.Intent("miui.intent.action.APP_PERM_EDITOR")
            .setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.permissions.PermissionsEditorActivity",
            )
            .putExtra("extra_pkgname", context.packageName)
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(miui)
            true
        } catch (_: Exception) {
            openSettings(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                withPackage = true,
            )
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
