package com.cubechat.cubechat

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.core.content.IntentCompat
import java.io.File
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

    /** Files from the share sheet, copied into our cache, until Dart takes them. */
    private var pendingShare: List<Map<String, String>>? = null
    private var shareChannel: MethodChannel? = null

    private class PendingSave(val source: File, val result: MethodChannel.Result)

    /**
     * The push plugin lives on the Application's engine (it has to answer
     * before any Activity exists — see [CubechatPushPlugin]). All it wants from
     * here is a window to raise the notification-permission dialog from, lent
     * for as long as this Activity is alive and taken back after.
     */
    private val pushPlugin: CubechatPushPlugin?
        get() = CubechatPushPlugin.instance

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
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeShared" -> {
                        result.success(pendingShare)
                        pendingShare = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
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
            LAUNCHER_ICON_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "currentIcon" -> result.success(
                    pendingLauncherIcon ?: try {
                        shownLauncherIcon()
                    } catch (error: Exception) {
                        android.util.Log.w(TAG, "launcher icon read failed", error)
                        null
                    },
                )
                // Every alias as the package manager holds it — the raw setting
                // and the manifest's own `enabled` — not the pending pick. Raw
                // rather than resolved so the Dart reconcile decides what
                // DEFAULT (0, "never touched") means, where a test can pin it.
                // It only ever *queues* a switch through setIcon; nothing here
                // or there toggles a component while the user is looking.
                "aliasStates" -> result.success(
                    try {
                        LAUNCHER_ICONS.keys.map { icon ->
                            mapOf(
                                "icon" to icon,
                                "setting" to packageManager
                                    .getComponentEnabledSetting(aliasComponent(icon)),
                                "manifestEnabled" to manifestEnabled(icon),
                            )
                        }
                    } catch (error: Exception) {
                        android.util.Log.w(TAG, "launcher icon read failed", error)
                        null
                    },
                )
                "setIcon" -> {
                    val icon = call.argument<String>("icon")
                    if (icon == null || icon !in LAUNCHER_ICONS) {
                        result.success(false)
                    } else {
                        // Queued, not applied: see onStop.
                        pendingLauncherIcon = icon
                        result.success(true)
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OPEN_IN_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openIn" -> result.success(handOffFile(call.argument<String>("path")))
                "saveAs" -> saveAs(
                    call.argument<String>("path"),
                    call.argument<String>("name"),
                    result,
                )
                "openInText" -> result.success(
                    handOffText(
                        call.argument<String>("text"),
                        call.argument<String>("subject"),
                    ),
                )
                else -> result.notImplemented()
            }
        }

        pushPlugin?.attach(this)
    }

    override fun onDestroy() {
        pushPlugin?.detach(this)
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        ensureLauncherEntry()
        answerFromIntent(intent)
        shareFromIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        answerFromIntent(intent)
        shareFromIntent(intent)
    }

    /**
     * "Share → CubeChat". The content URIs are only readable while the grant
     * lasts, so each file is copied into our own cache first — off the main
     * thread, since a video is hundreds of megabytes — and then Dart is told.
     * At most fifty, AirDrop's own limit.
     */
    private fun shareFromIntent(intent: Intent?) {
        if (intent == null) return
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java),
            )
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(
                    intent,
                    Intent.EXTRA_STREAM,
                    Uri::class.java,
                ) ?: emptyList()
            else -> return
        }
        // Spent, so a recreate does not share the same files again.
        intent.action = null
        if (uris.isEmpty()) return
        Thread {
            val copied = uris.take(50).mapNotNull { copyShared(it) }
            runOnUiThread {
                pendingShare = copied
                shareChannel?.invokeMethod("shared", null)
            }
        }.start()
    }

    private fun copyShared(uri: Uri): Map<String, String>? = try {
        var name = "file"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) name = cursor.getString(0) ?: name }
        val mime = contentResolver.getType(uri) ?: "application/octet-stream"
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val out = File(dir, "${System.nanoTime()}-${name.replace('/', '_').replace('\\', '_')}")
        val input = contentResolver.openInputStream(uri) ?: throw java.io.IOException("no stream")
        input.use { source -> out.outputStream().use { source.copyTo(it) } }
        mapOf("path" to out.absolutePath, "name" to name, "mime" to mime)
    } catch (_: Exception) {
        null
    }

    /**
     * Answer pressed on the incoming-call heads-up. The notification opens this
     * Activity rather than a receiver because answering should bring the app
     * forward, and Android 12 forbids a receiver from starting an Activity on a
     * notification's behalf. See [IncomingCall.answerIntent].
     */
    private fun answerFromIntent(intent: Intent?) {
        if (intent?.action != IncomingCall.ACTION_ANSWER) return
        val key = intent.getStringExtra(IncomingCall.EXTRA_KEY) ?: return
        // Spent, so a recreate — a rotation, a theme change — does not answer
        // the same call a second time.
        intent.action = null
        CubechatCallPlugin.instance?.deliver("answer", key)
        IncomingCall.dismiss(this, key)
    }

    /**
     * The notification permission's answer, on its way back to the Dart side
     * that asked for it. Everything else here is somebody else's request code
     * and goes to super, which is what feeds permission_handler.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (pushPlugin?.onPermissionResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    /**
     * The same, for a line of text — a contact card, a link.
     *
     * Same fault, same fix: without the flag the app the user picks opens
     * inside cubechat's task. There is no file here, so no provider and no
     * grant; only the text and where it should land.
     */
    private fun handOffText(text: String?, subject: String?): Boolean {
        if (text.isNullOrEmpty()) return false
        return try {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
                if (!subject.isNullOrEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
            }
            val chooser = Intent.createChooser(send, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Hand a file to whichever app the user picks, and *go there*.
     *
     * The share sheet already did the first half. What it did not do is the
     * second: share_plus calls `activity.startActivity(chooser)` with no
     * FLAG_ACTIVITY_NEW_TASK, and an activity launched that way joins the
     * *calling* task. So picking Telegram put Telegram's compose screen inside
     * cubechat's task — a second card in the recents switcher wearing
     * cubechat's icon and showing somebody else's app, with no way back to the
     * conversation except through it.
     *
     * The flag is the whole fix: with it the chooser's target lands in the task
     * its own affinity names, which is the app the user chose.
     *
     * Answers false when there is nothing to send or nothing installed that
     * will take it, so the Dart side can fall back to the share sheet rather
     * than leaving a tap that did nothing.
     */
    private fun handOffFile(path: String?): Boolean {
        if (path.isNullOrEmpty()) return false
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(this, "$packageName.openin", file)
            val extension = file.extension.lowercase()
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: "*/*"
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }


    /**
     * Put a copy of a file wherever the user picks — Downloads, a folder, a
     * USB stick, Drive — through the system's own "save as" screen.
     *
     * The backup used to reach this through FilePicker.saveFile, which on a
     * phone wants the whole file handed over as bytes. With photos and video
     * in the backup that is hundreds of megabytes in the Dart heap, so the
     * phone path was switched to the share sheet — and saving a copy to the
     * phone itself stopped being possible: the sheet sends to apps, it does
     * not put a file in a folder. Reported as "не открывает, куда сохранить".
     *
     * Here only a path crosses the channel. The copy is a stream from the
     * staged file into whatever the picker returned, on a thread of its own,
     * so the size of the archive costs disk and time but never memory.
     *
     * Answers "saved", "cancelled" or "failed".
     */
    private fun saveAs(path: String?, name: String?, result: MethodChannel.Result) {
        if (pendingSave != null) {
            result.error("busy", "a save is already open", null)
            return
        }
        val source = path?.let(::File)
        if (source == null || !source.exists()) {
            result.success("failed")
            return
        }
        try {
            val create = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                // A made-up extension has no MIME type of its own; octet-stream
                // is what every document provider accepts without renaming it.
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, name ?: source.name)
            }
            pendingSave = PendingSave(source, result)
            @Suppress("DEPRECATION")
            startActivityForResult(create, REQUEST_SAVE_AS)
        } catch (_: Exception) {
            pendingSave = null
            result.success("failed")
        }
    }

    private fun finishSave(resultCode: Int, data: Intent?) {
        val pending = pendingSave ?: return
        pendingSave = null
        val target = data?.data
        if (resultCode != Activity.RESULT_OK || target == null) {
            pending.result.success("cancelled")
            return
        }
        Thread {
            val outcome = try {
                contentResolver.openOutputStream(target, "w")?.use { out ->
                    pending.source.inputStream().use { input -> input.copyTo(out, 1 shl 16) }
                    "saved"
                } ?: "failed"
            } catch (_: Exception) {
                "failed"
            }
            // The main looper rather than this Activity's: the copy can outlast
            // the Activity that started it, and the reply belongs to the engine.
            Handler(Looper.getMainLooper()).post { pending.result.success(outcome) }
        }.start()
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
     * The icon picked in settings is switched when the user leaves the app,
     * not while they are looking at it.
     *
     * The launcher entry is an activity-alias, and the task a launcher tap
     * starts is recorded under the alias's name. Disabling that alias makes
     * the system remove every task recorded under it — even with
     * DONT_KILL_APP, which spares the process and not the task
     * (RecentTasks.cleanupDisabledPackageTasksLocked). Switched on the tap,
     * the app would close under the finger. Switched here the task goes from
     * recents while it is out of sight; the engine is the Application's, so the
     * next tap on the new icon attaches to the same running isolate.
     *
     * Only when every one of our tasks has MainActivity on top: a photo picker
     * or document screen stops this Activity too, while running inside our
     * task, and removing the task then would throw away the picker and the
     * result it was about to return. The incoming-call screen, likewise.
     *
     * What this cannot fix: every home-screen shortcut made before the first
     * switch points at ThemeIconEmerald, and the switch disables it. Stock
     * Launcher3 re-points or replaces such a shortcut on PACKAGE_CHANGED; a
     * launcher that keeps its cached item (reported on Xiaomi after a switch
     * made from recents, then a swipe) answers "app is disabled" until its
     * model reloads — a reboot. Keeping Emerald enabled instead would mean two
     * cubechats in the drawer for every other theme, and a LAUNCHER entry
     * cannot be hidden any other way: LauncherApps refuses to start a
     * component without the category, so a pin to one would break everywhere.
     */
    override fun onStop() {
        super.onStop()
        val icon = pendingLauncherIcon ?: return
        if (isChangingConfigurations || !onlyMainActivityOnTop()) return
        pendingLauncherIcon = null
        try {
            applyLauncherIcon(icon)
        } catch (error: Exception) {
            android.util.Log.w(TAG, "launcher icon switch failed", error)
        }
    }

    private fun onlyMainActivityOnTop(): Boolean = try {
        val tasks = getSystemService(android.app.ActivityManager::class.java)
            ?.appTasks.orEmpty()
        tasks.all { task ->
            val top = task.taskInfo.topActivity
            top == null || top.className == MainActivity::class.java.name
        }
    } catch (_: Exception) {
        false
    }

    private fun aliasComponent(icon: String): ComponentName = ComponentName(
        packageName,
        // Aliases are named against the manifest namespace, which is not
        // necessarily the installed package name.
        "${MainActivity::class.java.name.substringBeforeLast('.')}.${LAUNCHER_ICONS.getValue(icon)}",
    )

    private fun isAliasEnabled(icon: String): Boolean =
        when (packageManager.getComponentEnabledSetting(aliasComponent(icon))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            // Untouched: whatever the manifest says.
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> manifestEnabled(icon)
            else -> false
        }

    /**
     * The alias's `android:enabled` as installed, read from the package rather
     * than assumed, so a manifest edit cannot silently disagree with this file.
     * MATCH_DISABLED_COMPONENTS, or a disabled alias is "not found". Falls back
     * to the rule the manifest follows today: only Emerald ships enabled.
     */
    private fun manifestEnabled(icon: String): Boolean = try {
        val component = aliasComponent(icon)
        val info = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            packageManager.getActivityInfo(
                component,
                PackageManager.ComponentInfoFlags.of(
                    PackageManager.MATCH_DISABLED_COMPONENTS.toLong(),
                ),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getActivityInfo(component, PackageManager.MATCH_DISABLED_COMPONENTS)
        }
        info.enabled
    } catch (_: Exception) {
        icon == DEFAULT_LAUNCHER_ICON
    }

    /** The icon the launcher shows now, or null if no alias is enabled. */
    private fun shownLauncherIcon(): String? =
        LAUNCHER_ICONS.keys.firstOrNull { isAliasEnabled(it) }

    /**
     * Enables the wanted alias and disables the rest, toggling only what
     * differs — a component re-enabled for nothing is one some launchers treat
     * as a new app, dropping the home-screen shortcut.
     *
     * Two separate calls on every API level, the new alias enabled first, so
     * a death between them leaves two entries (finished on the next start by
     * the Dart reconcile) and never none.
     *
     * Build 1113 used the API 33+ batch setComponentEnabledSettings here, and
     * on the owner's Samsung the icon stopped following the theme and the old
     * home-screen icon answered "app is disabled" — the launcher never caught
     * up with a switch that had happened. 1111's two calls worked on the same
     * phone. In AOSP both reach the same setEnabledSettings and coalesce into
     * one delayed PACKAGE_CHANGED, so the difference is One UI's, not ours to
     * reason about: the proven order stays, and the batch is not re-proposed.
     */
    private fun applyLauncherIcon(icon: String) {
        if (!isAliasEnabled(icon)) {
            packageManager.setComponentEnabledSetting(
                aliasComponent(icon),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
        for (other in LAUNCHER_ICONS.keys) {
            if (other != icon && isAliasEnabled(other)) {
                packageManager.setComponentEnabledSetting(
                    aliasComponent(other),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }

    /**
     * A launcher entry exists before anything else runs. With every alias
     * disabled the app has no icon at all and can only be reached from a
     * notification or the share sheet — which is how this gets to run — so the
     * default is enabled on the spot. Enabling touches no task, so unlike a
     * disable it is safe while the user is looking. Anything subtler (two
     * enabled, the wrong one) is left to the Dart reconcile, which queues it
     * for onStop like any other switch.
     */
    private fun ensureLauncherEntry() {
        try {
            if (LAUNCHER_ICONS.keys.none { isAliasEnabled(it) }) {
                android.util.Log.w(TAG, "no launcher alias enabled; restoring the default")
                packageManager.setComponentEnabledSetting(
                    aliasComponent(DEFAULT_LAUNCHER_ICON),
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        } catch (error: Exception) {
            android.util.Log.w(TAG, "launcher entry check failed", error)
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
        if (requestCode == REQUEST_SAVE_AS) {
            finishSave(resultCode, data)
            return
        }
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
        const val SHARE_CHANNEL = "cubechat/share"
        const val BUILD_INFO_CHANNEL = "cubechat/build_info"
        const val BLUETOOTH_POWER_CHANNEL = "cubechat/bluetooth_power"
        const val OPEN_IN_CHANNEL = "cubechat/open_in"
        const val LAUNCHER_ICON_CHANNEL = "cubechat/launcher_icon"
        private const val TAG = "MainActivity"

        /**
         * Each icon Dart can ask for, and the manifest alias that carries it.
         * Emerald is the one enabled in the manifest: a fresh install's icon.
         */
        private val LAUNCHER_ICONS = mapOf(
            "emerald" to "ThemeIconEmerald",
            "indigo" to "ThemeIconIndigo",
            "amber" to "ThemeIconAmber",
            "rose" to "ThemeIconRose",
            "fuchsia" to "ThemeIconFuchsia",
            "violet" to "ThemeIconViolet",
            "ocean" to "ThemeIconOcean",
            "slate" to "ThemeIconSlate",
        )
        private const val DEFAULT_LAUNCHER_ICON = "emerald"

        /**
         * The icon waiting for the user to leave the app (see onStop). Held
         * here rather than on the instance for the same reason as
         * pendingSave below: the Activity can be recreated in between.
         */
        @Volatile
        private var pendingLauncherIcon: String? = null
        const val REQUEST_ENABLE_BLUETOOTH = 4242
        const val REQUEST_SAVE_AS = 4243

        /**
         * A "save as" waiting on the system's create-document screen.
         *
         * Held here rather than on the instance: the picker is another app's
         * screen, and this Activity can be recreated behind it — a rotation,
         * or memory pressure. The engine and its channel outlive that (see
         * MainApplication), so the answer can still be delivered; what must
         * not be lost is who is waiting for it, or the backup screen would sit
         * busy for the rest of the run.
         */
        private var pendingSave: PendingSave? = null
    }
}