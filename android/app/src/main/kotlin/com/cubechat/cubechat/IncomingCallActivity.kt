package com.cubechat.cubechat

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Chronometer
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The full-screen incoming call, over the lock screen or a sleeping display -
 * and, once answered there, the call itself until the phone is unlocked.
 *
 * Native rather than Flutter on purpose. The Flutter UI sits behind the app
 * lock — `CallHost` says incoming calls never bypass it — and this screen has to
 * appear on a locked phone. What it shows is only what a dialler shows: who is
 * calling, and the buttons. Nothing of the app behind it.
 *
 * Built in code, not XML, because it is one screen of a handful of views and a
 * layout file would be the larger of the two.
 */
class IncomingCallActivity : Activity() {
    private var key: String? = null

    /** Answered here, on a locked phone: this is the call screen now. */
    private var inCall = false
    private var speakerOn = false
    private var unlockWatch: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()
        IncomingCall.attach(this)
        render(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!inCall) render(intent)
    }

    override fun onDestroy() {
        unlockWatch?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        unlockWatch = null
        IncomingCall.detach(this)
        super.onDestroy()
    }

    /**
     * Called when the call stops ringing for any reason that is not a button
     * here — the caller gave up, it was answered from the heads-up, the app came
     * forward. A screen left behind for a call that is over would be the worst
     * thing this could do. Not once the call was answered here: then the
     * ringing stopping is this screen's own doing.
     */
    fun finishRinging() {
        runOnUiThread { if (!inCall && !isFinishing) finish() }
    }

    /** The call answered here is over. */
    fun finishCall() {
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

        val root = frame(title, name)
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

    /** The column every state of this screen shares: a line, the face, the name. */
    private fun frame(title: String, name: String, clock: View? = null): LinearLayout {
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
        if (clock != null) {
            root.addView(spacer(dp(10)))
            root.addView(clock)
        }
        root.addView(View(this), LinearLayout.LayoutParams(0, 0, 1f))
        return root
    }

    private fun answerCall() {
        val callKey = key ?: return finish()
        // Dart answers now, whether or not the phone is unlocked: the audio
        // should start when the button is pressed, the way it does on a phone.
        CubechatCallPlugin.instance?.deliver("answer", callKey)
        if (IncomingCall.isLocked(this)) {
            // **No PIN pad between the button and the call.** This used to ask
            // for the unlock and open the app behind it; "to take a call you
            // have to unlock the phone" was the report. The call stays on this
            // screen, over the lock, until it ends or the phone is unlocked -
            // the way the dialler's does.
            inCall = true
            IncomingCall.dismiss(this, callKey)
            renderInCall()
            watchUnlock()
            return
        }
        IncomingCall.dismiss(this, callKey)
        openApp()
    }

    private fun renderInCall() {
        val name = intent.getStringExtra(IncomingCall.EXTRA_NAME).orEmpty()
        val ongoing = intent.getStringExtra(IncomingCall.EXTRA_ONGOING).orEmpty()
        val hangUp = intent.getStringExtra(IncomingCall.EXTRA_HANG_UP).orEmpty()
        val speaker = intent.getStringExtra(IncomingCall.EXTRA_SPEAKER).orEmpty()
        val clock = Chronometer(this).apply {
            base = SystemClock.elapsedRealtime()
            setTextColor(Color.argb(210, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            gravity = Gravity.CENTER
            start()
        }
        val root = frame(ongoing, name, clock)
        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        lateinit var speakerButton: View
        speakerButton = action(speaker, speakerColor(), R.drawable.ic_call_speaker) {
            val callKey = key ?: return@action
            speakerOn = !speakerOn
            CubechatCallPlugin.instance?.deliver("speaker", callKey)
            (speakerButton.tag as? GradientDrawable)?.setColor(speakerColor())
        }
        buttons.addView(
            speakerButton,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        buttons.addView(
            action(hangUp, Color.rgb(229, 57, 53), R.drawable.ic_call_decline) { hangUpCall() },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        root.addView(buttons)
        setContentView(root)
    }

    private fun speakerColor(): Int =
        if (speakerOn) Color.rgb(125, 217, 160) else Color.argb(60, 255, 255, 255)

    /** Unlocked with the call on: the rest of the call belongs to the app. */
    private fun watchUnlock() {
        if (unlockWatch != null) return
        val watch = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = openApp()
        }
        unlockWatch = watch
        val filter = IntentFilter(Intent.ACTION_USER_PRESENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(watch, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(watch, filter)
        }
    }

    private fun openApp() {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        finish()
    }

    private fun hangUpCall() {
        val callKey = key ?: return finish()
        CubechatCallPlugin.instance?.deliver("end", callKey)
        finish()
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
        IncomingCall.avatar?.let { picture ->
            // The caller's own face, clipped round like everywhere in the app.
            return ImageView(this).apply {
                setImageBitmap(picture)
                scaleType = ImageView.ScaleType.CENTER_CROP
                clipToOutline = true
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Color.rgb(125, 217, 160))
                }
            }
        }
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
        val disc = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color)
        }
        val button = FrameLayout(this).apply {
            background = disc
            isClickable = true
            isFocusable = true
            contentDescription = text
            setOnClickListener { onTap() }
            addView(
                ImageView(this@IncomingCallActivity).apply { setImageResource(icon) },
                FrameLayout.LayoutParams(dp(36), dp(36), Gravity.CENTER),
            )
        }
        column.tag = disc
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
