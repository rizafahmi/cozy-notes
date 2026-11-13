package app.cozynotes.capture

import android.content.Intent
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.animation.PathInterpolator
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.ViewModelProvider
import androidx.core.content.IntentCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class CaptureActivity : ComponentActivity() {
    private lateinit var worker: CaptureWorker
    private lateinit var text: SpringCaretEditText
    private lateinit var note: SpringCaretEditText
    private lateinit var folder: TextView
    private lateinit var wordCountLabel: TextView
    private lateinit var sealDot: View
    private lateinit var attachmentsLabel: TextView
    private lateinit var status: TextView
    private lateinit var save: Button
    private lateinit var choose: Button
    private lateinit var fresh: Button
    private var captureSaved = false
    private var actionInitialized = false
    private var actionShowsSaved = false
    private var animateSaveCompletion = false
    private val attachments = mutableListOf<Uri>()
    private val preferences by lazy { getSharedPreferences("capture", MODE_PRIVATE) }

    // Midnight Ink palette (matching macOS Midnight Ink & Porcelain dark mode)
    private val deskColor = Color.rgb(14, 18, 24)        // #0E1218
    private val folioColor = Color.rgb(20, 25, 35)       // #141923
    private val recessedColor = Color.rgb(27, 34, 48)    // #1B2230
    private val borderColor = Color.rgb(39, 48, 66)      // #273042
    private val ruleColor = Color.rgb(31, 39, 54)        // #1F2736
    private val headingInk = Color.rgb(240, 244, 250)    // #F0F4FA
    private val bodyInk = Color.rgb(218, 226, 238)       // #DAE2EE
    private val mutedInk = Color.rgb(142, 156, 178)      // #8E9CB2
    private val subtleInk = Color.rgb(95, 108, 130)      // #5F6C82
    private val accentColor = Color.rgb(110, 155, 246)   // #6E9BF6
    private val onAccentColor = Color.rgb(11, 15, 22)    // #0B0F16
    private val seafoamColor = Color.rgb(94, 194, 176)   // #5EC2B0

    private var root: Uri? = null
    private val folderPicker = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        handleFolderResult(result.resultCode, result.data)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        worker = ViewModelProvider(this)[CaptureWorker::class.java]
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (worker.busy) status.text = "Saving capture… Please wait before leaving."
                else {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        })
        root = preferences.getString("vault", null)?.let(Uri::parse)
        buildView()
        if (savedInstanceState != null) {
            text.setText(savedInstanceState.getString("text", ""))
            note.setText(savedInstanceState.getString("note", ""))
            savedInstanceState.getStringArrayList("attachments")?.mapTo(attachments, Uri::parse)
            if (savedInstanceState.getBoolean("saved", false) && worker.result == null) {
                captureSaved = true
                status.text = "Your previous capture was saved. Start a new capture below."
            } else if (savedInstanceState.getBoolean("saving", false) && !worker.busy && worker.result == null) {
                status.text = "Android interrupted the previous save. Check Inbox for the capture before retrying. Any .pending file is incomplete."
            }
        } else {
            receiveShare(intent)
        }
        render()
    }

    override fun onStart() {
        super.onStart()
        worker.listener = { render(animateCompletion = animateSaveCompletion) }
        render()
    }

    override fun onStop() {
        animateSaveCompletion = false
        actionInitialized = false
        showCaptureAction(captureSaved || worker.result != null, animated = false)
        worker.listener = null
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("text", text.text.toString())
        outState.putString("note", note.text.toString())
        outState.putStringArrayList("attachments", ArrayList(attachments.map(Uri::toString)))
        outState.putBoolean("saving", worker.busy)
        outState.putBoolean("saved", captureSaved || worker.result != null)
        super.onSaveInstanceState(outState)
    }

    private fun buildView() {
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(deskColor)
        }
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(22))
        }
        scroll.addView(outer)
        // Target 35 draws edge-to-edge; keep controls clear of system bars and the keyboard.
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }

        // 1. Top Desk Bar: Seal dot + "MIDNIGHT FOLIO" + Vault Selector Pill
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(4), dp(4), dp(12))
        }
        sealDot = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(seafoamColor)
            }
            topBar.addView(this, LinearLayout.LayoutParams(dp(8), dp(8)).apply { rightMargin = dp(8) })
        }
        val brandStamp = TextView(this).apply {
            this.text = "COZY NOTES  ·  MIDNIGHT"
            textSize = 11f
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.08f
            setTextColor(mutedInk)
            topBar.addView(this, LinearLayout.LayoutParams(0, -2, 1f))
        }
        choose = FeedbackButton(this, recessedColor, borderColor, dp(8)).apply {
            this.text = "Choose vault…"
            textSize = 12f
            isAllCaps = false
            setTextColor(headingInk)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            minHeight = dp(32)
            minimumHeight = dp(32)
            setOnClickListener { chooseFolder() }
            topBar.addView(this, LinearLayout.LayoutParams(-2, dp(34)))
        }
        outer.addView(topBar, LinearLayout.LayoutParams(-1, -2))

        folder = TextView(this).apply {
            textSize = 11f
            typeface = Typeface.MONOSPACE
            setTextColor(subtleInk)
            setPadding(dp(6), 0, dp(6), dp(10))
            outer.addView(this, LinearLayout.LayoutParams(-1, -2))
        }

        // 2. Inset Folio Page Card
        val folioCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = surfaceDrawable(folioColor, borderColor, dp(16))
            setPadding(dp(20), dp(16), dp(20), dp(18))
        }

        val folioHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(10))
        }
        val dateStamp = SimpleDateFormat("EEE, MMM d, yyyy", Locale.US).format(Date()).uppercase(Locale.US)
        TextView(this).apply {
            this.text = "FOLIO  ·  $dateStamp"
            textSize = 11f
            typeface = Typeface.MONOSPACE
            setTextColor(mutedInk)
            folioHeader.addView(this, LinearLayout.LayoutParams(0, -2, 1f))
        }
        wordCountLabel = TextView(this).apply {
            this.text = "BLANK FOLIO"
            textSize = 11f
            typeface = Typeface.MONOSPACE
            setTextColor(subtleInk)
            folioHeader.addView(this, LinearLayout.LayoutParams(-2, -2))
        }
        folioCard.addView(folioHeader, LinearLayout.LayoutParams(-1, -2))

        // Hairline rule under dateline
        View(this).apply {
            setBackgroundColor(ruleColor)
            folioCard.addView(this, LinearLayout.LayoutParams(-1, dp(1)).apply { bottomMargin = dp(14) })
        }

        val watcher = object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) { updateWordCount() }
        }

        text = SpringCaretEditText(this, accentColor).apply {
            id = 1001
            hint = "Begin a note, paste a link, or jot a thought…"
            minLines = 7
            textSize = 17.5f
            setLineSpacing(dp(6).toFloat(), 1f)
            gravity = Gravity.TOP or Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setTextColor(bodyInk)
            setHintTextColor(subtleInk)
            background = null
            setPadding(0, dp(2), 0, dp(14))
            addTextChangedListener(watcher)
            folioCard.addView(this, LinearLayout.LayoutParams(-1, -2))
        }

        // Hairline rule before context note
        View(this).apply {
            setBackgroundColor(ruleColor)
            folioCard.addView(this, LinearLayout.LayoutParams(-1, dp(1)).apply {
                topMargin = dp(4)
                bottomMargin = dp(10)
            })
        }

        TextView(this).apply {
            this.text = "MARGIN CONTEXT"
            textSize = 10f
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.08f
            setTextColor(subtleInk)
            setPadding(0, 0, 0, dp(6))
            folioCard.addView(this, LinearLayout.LayoutParams(-1, -2))
        }

        note = SpringCaretEditText(this, accentColor).apply {
            id = 1002
            hint = "Add context or a note for shared links & files…"
            minLines = 2
            textSize = 15f
            setLineSpacing(dp(4).toFloat(), 1f)
            gravity = Gravity.TOP or Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setTextColor(bodyInk)
            setHintTextColor(subtleInk)
            background = surfaceDrawable(recessedColor, borderColor, dp(10))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            addTextChangedListener(watcher)
            folioCard.addView(this, LinearLayout.LayoutParams(-1, -2))
        }

        attachmentsLabel = TextView(this).apply {
            textSize = 11.5f
            typeface = Typeface.MONOSPACE
            setTextColor(mutedInk)
            background = surfaceDrawable(recessedColor, borderColor, dp(8))
            setPadding(dp(12), dp(8), dp(12), dp(8))
            folioCard.addView(this, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) })
        }

        outer.addView(folioCard, LinearLayout.LayoutParams(-1, -2))

        // 3. Primary & Secondary Actions below the Folio
        val actionSlot = FrameLayout(this)
        outer.addView(actionSlot, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(16) })
        save = FeedbackButton(this, accentColor, accentColor, dp(12)).apply {
            this.text = "Keep in Inbox"
            textSize = 15f
            isAllCaps = false
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(onAccentColor)
            setOnClickListener { saveCapture(animated = (it as FeedbackButton).isTouchClick) }
            actionSlot.addView(this, FrameLayout.LayoutParams(-1, -1))
        }

        fresh = FeedbackButton(this, recessedColor, borderColor, dp(12)).apply {
            this.text = "New Folio Capture"
            textSize = 15f
            isAllCaps = false
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(headingInk)
            visibility = View.INVISIBLE
            setOnClickListener {
                this@CaptureActivity.text.setText("")
                note.setText("")
                attachments.clear()
                status.text = ""
                captureSaved = false
                animateSaveCompletion = false
                worker.reset()
                render()
                this@CaptureActivity.text.requestFocus()
            }
            actionSlot.addView(this, FrameLayout.LayoutParams(-1, -1))
        }

        status = TextView(this).apply {
            textSize = 12.5f
            setTextColor(seafoamColor)
            setPadding(dp(6), dp(12), dp(6), dp(6))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            outer.addView(this, LinearLayout.LayoutParams(-1, -2))
        }

        TextView(this).apply {
            this.text = "LOCAL MARKDOWN  ·  SYNCTHING READY  ·  NO NETWORK"
            textSize = 10f
            typeface = Typeface.MONOSPACE
            gravity = Gravity.CENTER_HORIZONTAL
            setTextColor(subtleInk)
            setPadding(0, dp(10), 0, dp(4))
            outer.addView(this, LinearLayout.LayoutParams(-1, -2))
        }

        setContentView(scroll)
    }

    private fun receiveShare(source: Intent) {
        if (source.action != Intent.ACTION_SEND && source.action != Intent.ACTION_SEND_MULTIPLE) return
        val sharedText = source.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
        val subject = source.getStringExtra(Intent.EXTRA_SUBJECT).orEmpty()
        val sharedTexts = mutableListOf<String>()
        if (sharedText.isNotBlank()) sharedTexts.add(sharedText)
        val incoming = mutableListOf<Uri>()
        if (source.action == Intent.ACTION_SEND_MULTIPLE) {
            IntentCompat.getParcelableArrayListExtra(source, Intent.EXTRA_STREAM, Uri::class.java)?.let(incoming::addAll)
        } else {
            IntentCompat.getParcelableExtra(source, Intent.EXTRA_STREAM, Uri::class.java)?.let(incoming::add)
        }
        // Some senders expose URI grants only in ClipData, not EXTRA_STREAM.
        source.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                val item = clip.getItemAt(index)
                item.uri?.let { uri ->
                    if (uri.scheme == "http" || uri.scheme == "https") sharedTexts.add(uri.toString())
                    else incoming.add(uri)
                }
                item.text?.toString()?.takeIf(String::isNotBlank)?.let(sharedTexts::add)
            }
        }
        text.setText(sharedTexts.distinct().joinToString("\n\n").ifBlank { subject })
        attachments.addAll(incoming.filter { it.scheme == "content" }.distinct())
        if (incoming.any { it.scheme != "content" }) status.text = "A shared attachment used an unsupported URI. Share it from a file provider instead."
    }

    private fun chooseFolder() {
        val picker = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            root?.let { putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
        }
        try {
            folderPicker.launch(picker)
        } catch (_: android.content.ActivityNotFoundException) {
            status.text = "This device has no system folder picker. Enable its Files/Documents app and try again."
        }
    }

    private fun handleFolderResult(resultCode: Int, data: Intent?) {
        if (resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        val grants = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (grants and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0) {
            status.text = "That folder was not writable. Please select a writable vault folder."
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri, grants)
            val previous = root
            preferences.edit().putString("vault", uri.toString()).apply()
            root = uri
            if (previous != null && previous != uri) {
                try { contentResolver.releasePersistableUriPermission(previous, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) } catch (_: SecurityException) { }
            }
            status.text = "Vault selected. This preference stays on this device."
            render()
        } catch (_: SecurityException) {
            status.text = "This provider cannot keep writable folder access. Choose a local folder that supports persisted access."
        }
    }

    private fun hasPermission(uri: Uri): Boolean = contentResolver.persistedUriPermissions.any {
        it.uri == uri && it.isReadPermission && it.isWritePermission
    }

    private fun saveCapture(animated: Boolean) {
        val selected = root
        if (selected == null || !hasPermission(selected)) {
            status.text = "Choose the vault folder again to grant writable access. Your input is kept."
            chooseFolder()
            return
        }
        val combined = listOf(text.text.toString(), note.text.toString()).filter(String::isNotBlank).joinToString("\n\n")
        if (combined.isBlank() && attachments.isEmpty()) {
            status.text = "Add text, a link, or share an attachment first."
            return
        }
        animateSaveCompletion = animated
        worker.start(CaptureRequest(selected, combined, attachments.toList()))
    }

    private fun updateWordCount() {
        val combined = "${text.text} ${note.text}".trim()
        if (combined.isEmpty()) {
            wordCountLabel.text = "BLANK FOLIO"
            return
        }
        val words = combined.split(Regex("\\s+")).count { it.isNotEmpty() }
        wordCountLabel.text = "$words ${if (words == 1) "WORD" else "WORDS"}"
    }

    private fun render(animateCompletion: Boolean = false) {
        val selected = root
        val validVault = selected != null && hasPermission(selected)
        folder.text = when {
            selected == null -> "NO VAULT SELECTED  ·  TAP 'CHOOSE VAULT…' ABOVE"
            !validVault -> "FOLDER ACCESS EXPIRED  ·  CHOOSE VAULT AGAIN"
            else -> {
                val rawId = Uri.decode(DocumentsContract.getTreeDocumentId(selected))
                "VAULT  ·  $rawId"
            }
        }
        choose.text = if (validVault) "Change vault…" else "Choose vault…"
        sealDot.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(if (validVault) seafoamColor else accentColor)
        }
        if (attachments.isEmpty()) {
            attachmentsLabel.text = "ATTACHMENTS  ·  NONE (SHARE FILES TO COZY NOTES)"
            attachmentsLabel.setTextColor(subtleInk)
        } else {
            attachmentsLabel.text = "${attachments.size} ATTACHMENT${if (attachments.size == 1) "" else "S"}  ·  ORIGINALS PRESERVED"
            attachmentsLabel.setTextColor(seafoamColor)
        }
        updateWordCount()
        val done = captureSaved || worker.result != null
        captureSaved = done
        save.isEnabled = !worker.busy && !done
        if (!done) save.alpha = if (save.isEnabled) 1f else 0.55f
        choose.isEnabled = !worker.busy
        text.isEnabled = !worker.busy && !done
        note.isEnabled = !worker.busy && !done
        if (worker.busy) {
            status.setTextColor(accentColor)
            status.text = "Saving capture… Keep this app open until the save finishes."
        }
        worker.failure?.let {
            status.setTextColor(accentColor)
            status.text = "$it\nYour input has been kept. Check folder access, then retry."
        }
        worker.result?.let {
            status.setTextColor(seafoamColor)
            status.text = "Saved to ${it.path}"
        }
        showCaptureAction(done, animated = animateCompletion && done)
        status.visibility = if (status.text.isNullOrBlank()) View.GONE else View.VISIBLE
    }

    private fun showCaptureAction(done: Boolean, animated: Boolean) {
        if (actionInitialized && actionShowsSaved == done) return
        val canAnimate = animated && actionInitialized && save.isLaidOut && hasWindowFocus() && ValueAnimator.areAnimatorsEnabled()
        actionInitialized = true
        actionShowsSaved = done
        save.animate().cancel()
        fresh.animate().cancel()
        val incoming = if (done) fresh else save
        val outgoing = if (done) save else fresh
        outgoing.isEnabled = false
        outgoing.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        incoming.isEnabled = !worker.busy
        incoming.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        incoming.visibility = View.VISIBLE
        incoming.bringToFront()
        if (!canAnimate) {
            incoming.alpha = if (incoming.isEnabled) 1f else 0.55f
            outgoing.visibility = View.INVISIBLE
            outgoing.alpha = 1f
            return
        }
        val duration = CaptureMotion.duration(this, 120L)
        incoming.alpha = 0f
        outgoing.visibility = View.VISIBLE
        incoming.animate().alpha(1f).setDuration(duration).setInterpolator(CaptureMotion.easing).start()
        outgoing.animate().alpha(0f).setDuration(duration).setInterpolator(CaptureMotion.easing).withEndAction {
            if (actionShowsSaved == done) outgoing.visibility = View.INVISIBLE
        }.start()
    }

    private fun surfaceDrawable(fill: Int, stroke: Int, radius: Int) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = radius.toFloat()
        setStroke(dp(1), stroke)
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}

internal object CaptureMotion {
    val easing = PathInterpolator(0.42f, 0f, 0.58f, 1f)

    fun reducesMotion(context: Context): Boolean =
        Settings.Global.getFloat(context.contentResolver, Settings.Global.TRANSITION_ANIMATION_SCALE, 1f) == 0f ||
            Settings.Global.getFloat(context.contentResolver, Settings.Global.WINDOW_ANIMATION_SCALE, 1f) == 0f

    fun allowsCaretAnimation(context: Context): Boolean = ValueAnimator.areAnimatorsEnabled() &&
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) != 0f && !reducesMotion(context)

    fun duration(context: Context, normal: Long): Long =
        if (!ValueAnimator.areAnimatorsEnabled()) 0L else if (reducesMotion(context)) 80L else normal
}

/** Scale the drawing, not the View: touch bounds and native button activation stay unchanged. */
private class FeedbackButton(context: Context, fill: Int, stroke: Int, private val radius: Int) : Button(context) {
    private val pressedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK }
    private val pressedBounds = RectF()
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var touchActive = false
    private var touchInside = false
    private var touchPointer = -1
    private var pendingTouchClick = false
    private var touchFeedback = false
    var isTouchClick = false
        private set
    private var visualScale = 1f
    private var pressOpacity = 0f
    private var pressAnimator: ValueAnimator? = null

    init {
        background = GradientDrawable().apply {
            setColor(fill)
            cornerRadius = radius.toFloat()
            setStroke((resources.displayMetrics.density).toInt().coerceAtLeast(1), stroke)
        }
        stateListAnimator = null
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (isEnabled && event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN)) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    touchActive = true
                    touchFeedback = true
                    touchInside = true
                    touchPointer = event.getPointerId(0)
                    pendingTouchClick = false
                    updatePress(true)
                }
                MotionEvent.ACTION_MOVE -> {
                    val index = event.findPointerIndex(touchPointer)
                    val inside = index >= 0 && event.getX(index) >= -touchSlop && event.getX(index) < width + touchSlop &&
                        event.getY(index) >= -touchSlop && event.getY(index) < height + touchSlop
                    if (touchActive && touchInside != inside) {
                        touchInside = inside
                        updatePress(inside)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    pendingTouchClick = touchActive && touchInside
                    touchActive = false
                    updatePress(false)
                }
                MotionEvent.ACTION_CANCEL -> {
                    pendingTouchClick = false
                    touchActive = false
                    updatePress(false)
                }
                MotionEvent.ACTION_POINTER_UP -> if (event.getPointerId(event.actionIndex) == touchPointer) {
                    pendingTouchClick = false
                    touchActive = false
                    updatePress(false)
                }
            }
        }
        val handled = super.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP) post { pendingTouchClick = false }
        return handled
    }

    override fun performClick(): Boolean {
        isTouchClick = pendingTouchClick
        pendingTouchClick = false
        return try { super.performClick() } finally { isTouchClick = false }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        resetFeedback()
        return super.onKeyDown(keyCode, event)
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        resetFeedback()
        return super.performAccessibilityAction(action, arguments)
    }

    private fun updatePress(pressed: Boolean) {
        pressAnimator?.cancel()
        pressAnimator = null
        val reduced = CaptureMotion.reducesMotion(context)
        val duration = CaptureMotion.duration(context, 100L)
        val targetOpacity = if (pressed) 1f else 0f
        val targetScale = if (pressed && !reduced && duration > 0L) 0.98f else 1f
        if (!reduced || duration == 0L) pressOpacity = targetOpacity
        if (reduced || duration == 0L) visualScale = 1f
        val start = if (reduced) pressOpacity else visualScale
        val target = if (reduced) targetOpacity else targetScale
        if (duration == 0L || start == target) {
            visualScale = targetScale
            pressOpacity = targetOpacity
            invalidate()
            return
        }
        pressAnimator = ValueAnimator.ofFloat(start, target).apply {
            this.duration = duration
            interpolator = CaptureMotion.easing
            addUpdateListener {
                if (reduced) pressOpacity = it.animatedValue as Float else visualScale = it.animatedValue as Float
                invalidate()
            }
            start()
        }
        invalidate()
    }

    override fun draw(canvas: Canvas) {
        if (visualScale == 1f) {
            super.draw(canvas)
        } else {
            val checkpoint = canvas.save()
            canvas.scale(visualScale, visualScale, width * 0.5f, height * 0.5f)
            super.draw(canvas)
            canvas.restoreToCount(checkpoint)
        }
    }

    override fun onDraw(canvas: Canvas) {
        val opacity = if (isEnabled && isPressed && !touchFeedback) 1f else if (isEnabled) pressOpacity else 0f
        if (opacity > 0f) {
            pressedPaint.alpha = (46f * opacity).toInt()
            pressedBounds.set(0f, 0f, width.toFloat(), height.toFloat())
            canvas.drawRoundRect(pressedBounds, radius.toFloat(), radius.toFloat(), pressedPaint)
        }
        super.onDraw(canvas)
    }

    private fun resetFeedback() {
        pressAnimator?.cancel()
        pressAnimator = null
        touchActive = false
        pendingTouchClick = false
        touchFeedback = false
        visualScale = 1f
        pressOpacity = 0f
        invalidate()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) resetFeedback()
    }

    override fun onDetachedFromWindow() {
        resetFeedback()
        super.onDetachedFromWindow()
    }
}
