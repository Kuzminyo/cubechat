package com.cubechat.cubechat

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Installs an update of cubechat from an APK file, keeping lock-screen calls.
 *
 * "After every update the calls switch is off, in the app and in the system"
 * — reported build after build. The installer of an APK decides the state of
 * `USE_FULL_SCREEN_INTENT` for what it installs
 * (`PackageInstaller.SessionParams.setPermissionState`), and on Android 14+
 * that one permission may be set by *any* installer, privileged or not — the
 * platform's own Javadoc says so. The phone's package installer, the one a
 * tap on an APK in a chat or a file manager opens, sets it off. Installed by
 * cubechat itself, it is set on.
 *
 * Only ever this app: an APK naming another package is refused before the
 * installer sees it, and a different signature is refused by the installer.
 * The user confirms in the system's own dialog, as for any install.
 *
 * MIUI's own "show on lock screen" is not a platform permission and no
 * installer can set it; on Xiaomi phones that one still has to be switched on
 * by hand after an update.
 */
object SelfUpdater {
    private const val ACTION = "com.cubechat.cubechat.SELF_UPDATE_STATUS"

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    @Volatile
    private var channel: MethodChannel? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        val ch = MethodChannel(messenger, "cubechat/self_update")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(canInstall(appContext))
                "openInstallSettings" -> result.success(openInstallSettings(appContext))
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success("no_file")
                    } else {
                        worker.execute {
                            val outcome = try {
                                install(appContext, File(path))
                            } catch (e: Exception) {
                                "failed: ${e.javaClass.simpleName}: ${e.message}"
                            }
                            main.post { result.success(outcome) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canInstall(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /** The one switch the user has to turn on first: "install unknown apps". */
    private fun openInstallSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            context.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /** "started", or why not. The outcome of the install itself comes later. */
    private fun install(context: Context, apk: File): String {
        if (!apk.exists()) return "no_file"
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageArchiveInfo(apk.path, 0)
            ?: return "not_an_apk"
        if (info.packageName != context.packageName) return "other_app"

        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        ).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // The point of all this. See the class comment.
                setPermissionState(
                    Manifest.permission.USE_FULL_SCREEN_INTENT,
                    PackageInstaller.SessionParams.PERMISSION_STATE_GRANTED,
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Once cubechat has installed itself it is its own installer of
                // record, and Android 12+ lets that update without asking
                // again. Until then the system asks, which is fine.
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("cubechat.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            val status = PendingIntent.getBroadcast(
                context,
                id,
                Intent(context, SelfUpdateReceiver::class.java).setAction(ACTION),
                flags,
            )
            session.commit(status.intentSender)
        }
        return "started"
    }

    /** Anything but "confirm it" and success — which ends this process. */
    fun report(status: Int, message: String?) {
        main.post {
            channel?.invokeMethod(
                "status",
                mapOf("status" to status, "message" to message),
            )
        }
    }
}

/** Where the package installer answers [SelfUpdater]. */
class SelfUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            if (confirm != null) {
                try {
                    context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (e: Exception) {
                    SelfUpdater.report(PackageInstaller.STATUS_FAILURE, e.toString())
                }
            }
            return
        }
        SelfUpdater.report(status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE))
    }
}
