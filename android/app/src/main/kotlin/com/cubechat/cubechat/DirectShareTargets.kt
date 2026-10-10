package com.cubechat.cubechat

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * Chats in the system share sheet's top row ("Direct Share").
 *
 * Dart hands over the few chats worth offering; each becomes a long-lived
 * dynamic shortcut in the share category declared in res/xml/shortcuts.xml. A
 * tap on one starts [MainActivity] with the shortcut's id in
 * Intent.EXTRA_SHORTCUT_ID, which is the chat id.
 *
 * Excluded from the launcher: the names of people you talk to must not show up
 * in the long-press menu of the app icon on a home screen anyone can look at.
 * Only the share sheet gets them.
 */
internal object DirectShareTargets {
    const val CATEGORY = "com.cubechat.cubechat.directshare.TARGET"
    private const val ACTION = "com.cubechat.cubechat.DIRECT_SHARE"
    private const val MAX_TARGETS = 4

    fun publish(context: Context, targets: List<Pair<String, String>>) {
        if (targets.isEmpty()) {
            ShortcutManagerCompat.removeAllDynamicShortcuts(context)
            return
        }
        val limit = minOf(
            MAX_TARGETS,
            ShortcutManagerCompat.getMaxShortcutCountPerActivity(context),
        )
        val shortcuts = targets.take(limit).map { (id, name) ->
            val person = Person.Builder().setName(name).setKey(id).build()
            ShortcutInfoCompat.Builder(context, id)
                .setShortLabel(name)
                .setLongLabel(name)
                .setIcon(IconCompat.createWithBitmap(avatar(name)))
                .setIntent(
                    Intent(context, MainActivity::class.java).setAction(ACTION),
                )
                .setCategories(setOf(CATEGORY))
                .setPerson(person)
                .setLongLived(true)
                .setExcludedFromSurfaces(ShortcutInfoCompat.SURFACE_LAUNCHER)
                .build()
        }
        ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts)
    }

    /** A round letter badge: no photos are read or kept for this. */
    private fun avatar(name: String): Bitmap {
        val size = 128
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = colorFor(name) }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, fill)
        val letter = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt()
            textSize = size * 0.5f
            typeface = Typeface.DEFAULT_BOLD
            textAlign = Paint.Align.CENTER
        }
        val baseline = size / 2f - (text.descent() + text.ascent()) / 2f
        canvas.drawText(letter, size / 2f, baseline, text)
        return bitmap
    }

    private fun colorFor(name: String): Int {
        val palette = intArrayOf(
            0xFF2E7D6B.toInt(),
            0xFF5C6BC0.toInt(),
            0xFFC77D2E.toInt(),
            0xFFC2556B.toInt(),
            0xFF8E5BC2.toInt(),
            0xFF2F84A8.toInt(),
        )
        return palette[Math.floorMod(name.hashCode(), palette.size)]
    }
}
