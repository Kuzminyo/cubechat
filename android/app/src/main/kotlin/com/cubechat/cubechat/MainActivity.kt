package com.cubechat.cubechat

import android.content.Context
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Attaches to the long-lived cached engine created in [MainApplication]
 * instead of creating its own. Because the engine is owned by the
 * Application, FlutterActivity won't destroy it when the Activity is
 * finished/swiped — so the Dart isolate (and BLE) keeps running in the
 * background. Channels + plugins are registered once on that engine in
 * MainApplication, so there's nothing to configure here.
 *
 * Except the secure-window flag, which has to live on the Activity because
 * that is what owns the Window. It is set and cleared around the view-once
 * photo viewer rather than held for the whole app: FLAG_SECURE blacks out the
 * app in the recents thumbnail too, and a messenger that shows a blank card in
 * the task switcher for its entire life is worse to use for no gain.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get(MainApplication.ENGINE_ID)
            ?: super.provideFlutterEngine(context)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Safe on the cached engine: FlutterActivity's implementation returns
        // immediately when the engine came from the host (`provideFlutterEngine`
        // above), so it will not register the generated plugins a second time
        // over the set MainApplication already installed.
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    // runOnUiThread: window flags are UI-thread-only, and the
                    // platform channel already arrives there — but the Activity
                    // may be finishing, in which case touching the Window
                    // throws rather than failing quietly.
                    runOnUiThread {
                        try {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val SECURE_CHANNEL = "cubechat/secure_window"
    }
}
