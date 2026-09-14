package com.cubechat.cubechat

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The full-screen incoming call, over the lock screen or a sleeping display.
 *
 * Native rather than Flutter on purpose. The Flutter UI sits behind the app
 * lock — `CallHost` says incoming calls never bypass it — and this screen has to
 * appear on a locked phone. What it shows is only what a dialler shows: who is
 * calling, and two buttons. Nothing of the app behind it.
 *
 * Built in code, not XML, because it is one screen of four views and a layout
 * file would be the larger of the two.
 */
class IncomingCallActivity : Activity() {
    private var key: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()
        IncomingCall.attach(this)
        render(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        render(intent)
    }

    override fun onDestroy() {
        IncomingCall.detach(this)
        super.onDestroy()
    }

    /**
     * Called when the call stops ringing for any reason that is not a button
     * here — the caller gave up, it was answered from the heads-up, the app came
     * forward. A screen left behind for a call that is over would be the worst
     * thing this could do.
     */
    fun finishRinging() {
        runOnUiThread { if (!isFinishing) finish() }
    }

    @Suppress("DEPRECATION")
    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun render(intent: Intent) {
        val callKey = intent.getStringExtra(IncomingCall.EXTRA_KEY)
        // Opened for a call that has already stopped ringing — a tap on a stale
        // heads-up, or the system replaying the full-screen intent late.
        if (callKey == null || callKey != IncomingCall.shownKey) {
            finish()
            return
        }
        key = callKey
        val name = intent.getStringExtra(IncomingCall.EXTRA_NAME).orEmpty()
        val title = intent.getStringExtra(IncomingCall.EXTRA_TITLE).orEmpty()
        val answer = intent.getStringExtra(IncomingCall.EXTRA_ANSWER).orEmpty()
        val decline = intent.getStringExtra(IncomingCall.EXTRA_DECLINE).orEmpty()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            // The app's own deep green, the colour behind every call screen.
            setBackgroundColor(Color.rgb(6, 20, 13))
            setPadding(dp(24), dp(72), dp(24), dp(56))
        }

        root.addView(label(title, 16f, Color.argb(200, 255, 255, 255), Typeface.NORMAL))
        root.addView(spacer(dp(40)))
        root.addView(avatar(name), LinearLayout.LayoutParams(dp(128), dp(128)))
        root.addView(spacer(dp(24)))
        root.addView(label(name, 30f, Color.WHITE, Typeface.BOLD))
        root.addView(View(this), LinearLayout.LayoutParams(0, 0, 1f))

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        buttons.addView(
            action(decline, Color.rgb(229, 57, 53), R.drawable.ic_call_decline) { declineCall() },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        buttons.addView(
            action(answer, Color.rgb(46, 204, 113), R.drawable.ic_call_answer) { answerCall() },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        root.addView(buttons)
        setContentView(root)
    }

    private fun answerCall() {
        val callKey = key ?: return finish()
        // Dart answers now, whether or not the phone is unlocked yet: the audio
        // should start when the button is pressed, the way it does on a phone.
        CubechatCallPlugin.instance?.deliver("answer", callKey)
        IncomingCall.dismiss(this, callKey)
        val open = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard != null && keyguard.isKeyguardLocked &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            // The call screen is inside the app, and the app is behind the
            // phone's lock. Ask for the unlock, then open it.
            keyguard.requestDismissKeyguard(
                this,
                object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        startActivity(open)
                        finish()
                    }

                    override fun onDismissCancelled() = finish()
                    override fun onDismissError() = finish()
                },
            )
        } else {
            startActivity(open)
            finish()
        }
    }

    private fun declineCall() {
        val callKey = key ?: return finish()
        CubechatCallPlugin.instance?.deliver("decline", callKey)
        IncomingCall.dismiss(this, callKey)
        finish()
    }

    private fun label(text: String, size: Float, color: Int, style: Int) =
        TextView(this).apply {
            this.text = text
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            setTypeface(typeface, style)
            gravity = Gravity.CENTER
            maxLines = 2
        }

    private fun spacer(height: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(1, height)
    }

    /** The first letter of the name in a circle, the app's avatar fallback. */
    private fun avatar(name: String): View {
        val initial = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
        return TextView(this).apply {
            text = initial
            gravity = Gravity.CENTER
            setTextColor(Color.rgb(6, 20, 13))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 52f)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.rgb(125, 217, 160))
            }
        }
    }

    private fun action(text: String, color: Int, icon: Int, onTap: () -> Unit): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val button = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(color)
            }
            isClickable = true
            isFocusable = true
            contentDescription = text
            setOnClickListener { onTap() }
            addView(
                ImageView(this@IncomingCallActivity).apply { setImageResource(icon) },
                FrameLayout.LayoutParams(dp(36), dp(36), Gravity.CENTER),
            )
        }
        column.addView(button, LinearLayout.LayoutParams(dp(76), dp(76)))
        column.addView(spacer(dp(12)))
        column.addView(label(text, 15f, Color.WHITE, Typeface.NORMAL))
        return column
    }

    private fun dp(value: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value.toFloat(),
        resources.displayMetrics,
    ).toInt()
}
