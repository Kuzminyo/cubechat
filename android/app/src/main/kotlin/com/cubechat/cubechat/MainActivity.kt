package com.cubechat.cubechat

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
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
    private var pendingBluetoothResult: MethodChannel.Result? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get(MainApplication.ENGINE_ID)
            ?: super.provideFlutterEngine(context)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Safe on the cached engine: FlutterActivity's implementation returns
        // immediately when the engine came from the host (provideFlutterEngine
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
                    runOnUiThread {
                        try {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BLUETOOTH_POWER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestEnable" -> requestBluetoothEnable(result)
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun requestBluetoothEnable(result: MethodChannel.Result) {
        if (pendingBluetoothResult != null) {
            result.error("busy", "Bluetooth enable request already open", null)
            return
        }

        try {
            val adapter = BluetoothAdapter.getDefaultAdapter()
            if (adapter == null) {
                result.success(false)
                return
            }
            if (adapter.isEnabled) {
                result.success(true)
                return
            }

            pendingBluetoothResult = result
            startActivityForResult(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                REQUEST_ENABLE_BLUETOOTH,
            )
        } catch (_: SecurityException) {
            pendingBluetoothResult = null
            result.success(false)
        } catch (_: Exception) {
            pendingBluetoothResult = null
            result.success(false)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_ENABLE_BLUETOOTH) return

        val pending = pendingBluetoothResult ?: return
        pendingBluetoothResult = null
        val enabled = try {
            resultCode == Activity.RESULT_OK ||
                BluetoothAdapter.getDefaultAdapter()?.isEnabled == true
        } catch (_: SecurityException) {
            resultCode == Activity.RESULT_OK
        }
        pending.success(enabled)
    }

    companion object {
        const val SECURE_CHANNEL = "cubechat/secure_window"
        const val BLUETOOTH_POWER_CHANNEL = "cubechat/bluetooth_power"
        const val REQUEST_ENABLE_BLUETOOTH = 4242
    }
}