package com.cubechat.cubechat

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        CubechatBlePeripheralPlugin(
            context = applicationContext,
            methodChannel = MethodChannel(messenger, "cubechat/ble_peripheral"),
            eventChannel = EventChannel(messenger, "cubechat/ble_peripheral/events"),
        )

        // Background foreground-service control + battery-optimisation helpers.
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
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    result.success(requestIgnoreBatteryOptimizations())
                }
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
        return try {
            // Opens the system dialog asking the user to exempt us from
            // battery optimisation — needed on Samsung/One UI to keep the
            // foreground service alive after the app is swiped away.
            @Suppress("BatteryLife")
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
            true
        } catch (e: Exception) {
            // Some OEMs hide the direct-request action; fall back to the
            // general battery-optimisation settings list.
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (_: Exception) {
                false
            }
        }
    }
}
