package com.cubechat.cubechat

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Why the last run of the app ended, for the debug log.
 *
 * A crash takes the in-memory log with it, so the one thing a tester sends
 * afterwards is a log that starts at the next launch and says nothing about
 * the fall. Reported on 2026-09-22 as "tapping translate closes the app", with
 * nothing to go on: the plugins' Java code was read and does not throw, the
 * ML Kit libraries are 16 KB aligned, and guessing further would cost a build
 * each.
 *
 * Two sources, because each sees what the other cannot:
 *  - a JVM uncaught-exception handler, installed first thing in
 *    [MainApplication], that writes the stack trace to a file before handing
 *    the exception on to Android's own handler (which still shows the dialog
 *    and kills the process exactly as before);
 *  - Android's own record of how the process exited
 *    (`getHistoricalProcessExitReasons`, API 30+), which also covers native
 *    crashes, ANRs and being killed for memory — none of which reach a JVM
 *    handler.
 *
 * Nothing leaves the phone: this only feeds the debug log, which the user
 * chooses to send.
 */
object ExitRecorder {
    private const val CRASH_FILE = "last_jvm_crash.txt"
    private const val PREFS = "cubechat_exit_recorder"
    private const val SEEN_KEY = "last_reported_exit_ms"

    fun install(context: Context) {
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val trace = error.stackTraceToString().lines().take(60).joinToString("\n")
                File(appContext.filesDir, CRASH_FILE).writeText(
                    "${System.currentTimeMillis()}\n${thread.name}\n$trace",
                )
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, error)
        }
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "cubechat/exit_recorder").setMethodCallHandler { call, result ->
            when (call.method) {
                "lastExits" -> result.success(
                    try {
                        lastExits(appContext)
                    } catch (e: Throwable) {
                        listOf(mapOf("reason" to "probe_failed", "description" to e.toString()))
                    },
                )
                else -> result.notImplemented()
            }
        }
    }

    /** Exits not reported before, newest first, at most three. */
    private fun lastExits(context: Context): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seen = prefs.getLong(SEEN_KEY, 0L)
        val out = mutableListOf<Map<String, Any?>>()

        val crashFile = File(context.filesDir, CRASH_FILE)
        val jvm = if (crashFile.exists()) {
            try {
                crashFile.readText()
            } catch (_: Throwable) {
                null
            } finally {
                crashFile.delete()
            }
        } else {
            null
        }

        var newest = seen
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val exits = am?.getHistoricalProcessExitReasons(context.packageName, 0, 5).orEmpty()
            for (exit in exits) {
                if (exit.timestamp <= seen) continue
                if (exit.timestamp > newest) newest = exit.timestamp
                // A normal close is not news; everything else is.
                if (exit.reason == ApplicationExitInfo.REASON_EXIT_SELF ||
                    exit.reason == ApplicationExitInfo.REASON_USER_REQUESTED
                ) continue
                out.add(
                    mapOf(
                        "at" to exit.timestamp,
                        "reason" to reasonName(exit.reason),
                        "description" to exit.description,
                        "importance" to exit.importance,
                    ),
                )
                if (out.size >= 3) break
            }
        }
        if (jvm != null) {
            val stamp = jvm.substringBefore('\n').toLongOrNull() ?: 0L
            out.add(
                0,
                mapOf(
                    "at" to stamp,
                    "reason" to "jvm_exception",
                    "description" to jvm.substringAfter('\n'),
                ),
            )
        }
        prefs.edit().putLong(SEEN_KEY, newest).apply()
        return out
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_OTHER -> "other"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
        else -> "reason_$reason"
    }
}
