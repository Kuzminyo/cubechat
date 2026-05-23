package com.cubechat.cubechat

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Pre-warms and caches a single FlutterEngine that lives in the Application,
 * not the Activity. This is what lets cubechat keep receiving messages after
 * the app is swiped away from recents: swiping destroys the Activity (and the
 * usual per-Activity engine), but a cached engine survives as long as the
 * process does — and [MeshForegroundService] keeps the process alive. The
 * Dart isolate (MessagingService, Noise sessions, BLE plugins) therefore
 * keeps running headless and can answer a peer that connects + writes while
 * we're "closed".
 *
 * MainActivity attaches to this same engine (see provideFlutterEngine) instead
 * of spinning up its own, so UI state is preserved across open/close too.
 */
class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Prewarm failures must NOT crash the process (which, on a background
        // sticky-restart, would loop into "keeps stopping"). If anything here
        // throws, leave the cache empty — MainActivity then spins up its own
        // engine the normal way.
        try {
            val engine = FlutterEngine(this)
            // Run main() now, headless. Flutter renders to no surface until the
            // Activity attaches a view; the Dart side (and BLE) runs regardless.
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
            // Register all pubspec plugins (flutter_blue_plus, permission_handler,
            // record, audioplayers, …). A cached engine doesn't auto-register, so
            // we must do it ourselves.
            GeneratedPluginRegistrant.registerWith(engine)
            registerCustomChannels(engine)
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        } catch (e: Throwable) {
            android.util.Log.e("MainApplication", "engine prewarm failed", e)
        }
    }

    private fun registerCustomChannels(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        CubechatBlePeripheralPlugin(
            context = applicationContext,
            methodChannel = MethodChannel(messenger, "cubechat/ble_peripheral"),
            eventChannel = EventChannel(messenger, "cubechat/ble_peripheral/events"),
        )
        MethodChannel(messenger, "cubechat/background").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    MeshForegroundService.start(applicationContext)
                    result.success(true)
                }
                "stop" -> {
                    MeshForegroundService.stop(applicationContext)
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" ->
                    result.success(isIgnoringBatteryOptimizations())
                "requestIgnoreBatteryOptimizations" ->
                    result.success(requestIgnoreBatteryOptimizations())
                else -> result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        // Launched from Application context → must add NEW_TASK.
        return try {
            @Suppress("BatteryLife")
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            applicationContext.startActivity(intent)
            true
        } catch (e: Exception) {
            try {
                applicationContext.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    companion object {
        const val ENGINE_ID = "cubechat_engine"
    }
}
