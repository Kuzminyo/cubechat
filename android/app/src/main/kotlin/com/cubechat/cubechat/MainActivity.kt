package com.cubechat.cubechat

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.view.WindowManager
import com.crazecoder.openfile.OpenFilePlugin
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
        reviveOpenFilePlugin(flutterEngine)
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

        // The same two facts iOS reports: which Maps key this build carries,
        // and what the install is called. Release APKs from CI shipped with an
        // empty key for months and drew a black map with no error anywhere.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BUILD_INFO_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "buildFacts" -> result.success(
                    mapOf(
                        "mapsKeyTail" to mapsKeyTail(),
                        "bundleId" to packageName,
                    ),
                )
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

    /**
     * Puts the `open_file` method channel back after an Activity has come and
     * gone.
     *
     * open_filex creates its channel in onAttachedToEngine and *destroys* it in
     * onDetachedFromActivity — but never recreates it, because
     * onAttachedToActivity only stores the Activity and does not call its own
     * setup() again. In an ordinary app the asymmetry is invisible: the engine
     * dies with the Activity, so a channel torn down on detach was never going
     * to be needed again.
     *
     * cubechat's engine outlives the Activity by design (see MainApplication —
     * it is what keeps the mesh running after a swipe from recents). So the
     * first time the Activity goes away — swiped away, or simply a
     * configuration change, which routes through the same method — the channel
     * is removed from a Dart isolate that carries on running, and every later
     * tap on a received file raises
     * `MissingPluginException(No implementation found for method open_file on
     * channel open_file)`. Reported from the field as files that opened fine
     * to begin with and then stopped for the rest of the install: accurate,
     * and it needed the Activity to have been recreated once to reproduce.
     *
     * Removing and re-adding the plugin runs onAttachedToEngine again, which is
     * the call that builds the channel. The engine's registry hands an
     * already-attached Activity straight back to an ActivityAware plugin as it
     * is added, so the re-added instance comes up complete. This runs on every
     * attach, including the first, where it is a harmless replacement of a
     * channel that was about to be identical.
     */
    private fun reviveOpenFilePlugin(flutterEngine: FlutterEngine) {
        try {
            flutterEngine.plugins.remove(OpenFilePlugin::class.java)
            flutterEngine.plugins.add(OpenFilePlugin())
        } catch (e: Throwable) {
            // Opening files is worth a log line, never a crash on launch. The
            // Dart side already falls back to the share sheet when the channel
            // is missing, which is where this leaves it.
            android.util.Log.e("MainActivity", "open_file revive failed", e)
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

    /**
     * The manifest is where the Maps key ends up on Android, so the manifest is
     * what gets asked — this reports what the *installed* app holds rather than
     * what a build file said at compile time.
     */
    private fun mapsKeyTail(): String = try {
        @Suppress("DEPRECATION")
        val info = packageManager.getApplicationInfo(
            packageName,
            android.content.pm.PackageManager.GET_META_DATA,
        )
        val key = info.metaData?.getString("com.google.android.geo.API_KEY").orEmpty()
        if (key.isEmpty()) "missing" else key.takeLast(4)
    } catch (_: Exception) {
        "unknown"
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
        const val BUILD_INFO_CHANNEL = "cubechat/build_info"
        const val BLUETOOTH_POWER_CHANNEL = "cubechat/bluetooth_power"
        const val REQUEST_ENABLE_BLUETOOTH = 4242
    }
}