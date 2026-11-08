package app.cozynotes.capture

import android.content.Intent
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Choreographer
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
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
    private lateinit var text: EditText
    private lateinit var note: EditText
    private lateinit var folder: TextView
    private lateinit var wordCountLabel: TextView
    private lateinit var sealDot: View
    private lateinit var attachmentsLabel: TextView
    private lateinit var status: TextView
    private lateinit var save: Button
    private lateinit var choose: Button
    private lateinit var fresh: Button
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
                status.text = "Your previous capture was saved. Start a new capture below."
                save.visibility = View.GONE
                fresh.visibility = View.VISIBLE
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
        worker.listener = { render() }
        render()
    }

    override fun onStop() {
        worker.listener = null
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("text", text.text.toString())
        outState.putString("note", note.text.toString())
        outState.putStringArrayList("attachments", ArrayList(attachments.map(Uri::toString)))
        outState.putBoolean("saving", worker.busy)
        outState.putBoolean("saved", worker.result != null || save.visibility == View.GONE)
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
        choose = Button(this).apply {
            this.text = "Choose vault…"
            textSize = 12f
            isAllCaps = false
            setTextColor(headingInk)
            background = surfaceDrawable(recessedColor, borderColor, dp(8))
            setPadding(dp(12), dp(6), dp(12), dp(6))
            minHeight = dp(32)
            minimumHeight = dp(32)
            stateListAnimator = null
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

        text = SmoothCaretEditText(this, accentColor).apply {
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

        note = SmoothCaretEditText(this, accentColor).apply {
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
        save = Button(this).apply {
            this.text = "Keep in Inbox"
            textSize = 15f
            isAllCaps = false
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(onAccentColor)
            background = surfaceDrawable(accentColor, accentColor, dp(12))
            stateListAnimator = null
            setOnClickListener { saveCapture() }
            outer.addView(this, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(16) })
        }

        fresh = Button(this).apply {
            this.text = "New Folio Capture"
            textSize = 15f
            isAllCaps = false
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(headingInk)
            background = surfaceDrawable(recessedColor, borderColor, dp(12))
            stateListAnimator = null
            visibility = View.GONE
            setOnClickListener {
                this@CaptureActivity.text.setText("")
                note.setText("")
                attachments.clear()
                status.text = ""
                save.visibility = View.VISIBLE
                worker.reset()
                render()
                this@CaptureActivity.text.requestFocus()
            }
            outer.addView(this, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(16) })
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

    private fun saveCapture() {
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

    private fun render() {
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
        val done = worker.result != null || save.visibility == View.GONE
        save.isEnabled = !worker.busy && !done
        save.alpha = if (save.isEnabled) 1f else 0.55f
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
            save.visibility = View.GONE
        }
        fresh.visibility = if (done) View.VISIBLE else View.GONE
        status.visibility = if (status.text.isNullOrBlank()) View.GONE else View.VISIBLE
    }

    private fun surfaceDrawable(fill: Int, stroke: Int, radius: Int) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = radius.toFloat()
        setStroke(dp(1), stroke)
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}

/**
 * EditText with Bike-style critically-damped spring caret animation (response = 0.125s, dampingRatio = 1.0)
 * and velocity preservation across rapid keystrokes.
 */
private class SmoothCaretEditText(
    context: Context,
    private val caretColor: Int
) : EditText(context), Choreographer.FrameCallback {
    private val density = resources.displayMetrics.density
    private val caretWidthPx = 2f * density
    private val caretRadiusPx = 1f * density
    private val maxDeltaXPx = 180f * density
    private val maxDeltaYPx = 120f * density
    private val caretPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = caretColor
    }
    private val caretRect = RectF()

    // Critically-damped spring frequency: omega0 = 2 * pi / response (response = 0.125s)
    private val omega0 = (2.0 * Math.PI / 0.125).toFloat()

    private var hasCaretOrigin = false
    private var currentX = 0f
    private var currentY = 0f
    private var currentHeight = 0f
    private var targetX = 0f
    private var targetY = 0f
    private var targetHeight = 0f
    private var velocityX = 0f
    private var velocityY = 0f
    private var velocityH = 0f

    private var frameScheduled = false
    private var lastFrameNanos = 0L
    private var lastInteractionMs = 0L

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            textCursorDrawable = ColorDrawable(Color.TRANSPARENT)
        }
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        updateCaretTarget(animated = true)
    }

    override fun onTextChanged(text: CharSequence?, start: Int, lengthBefore: Int, lengthAfter: Int) {
        super.onTextChanged(text, start, lengthBefore, lengthAfter)
        updateCaretTarget(animated = true)
    }

    override fun onFocusChanged(focused: Boolean, direction: Int, previouslyFocusedRect: android.graphics.Rect?) {
        super.onFocusChanged(focused, direction, previouslyFocusedRect)
        if (focused) {
            hasCaretOrigin = false
            updateCaretTarget(animated = false)
        } else {
            hasCaretOrigin = false
            stopFrameLoop()
            invalidate()
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        updateCaretTarget(animated = false)
    }

    override fun onDetachedFromWindow() {
        stopFrameLoop()
        super.onDetachedFromWindow()
    }

    private fun shouldShowCaret(): Boolean {
        return isFocused && isEnabled && selectionStart >= 0 && selectionStart == selectionEnd
    }

    private fun computeTargetGeometry(): Boolean {
        val textLayout = layout ?: return false
        val len = text?.length ?: 0
        val offset = selectionStart.coerceIn(0, len)
        val line = textLayout.getLineForOffset(offset)
        val primaryX = textLayout.getPrimaryHorizontal(offset)
        val baseline = textLayout.getLineBaseline(line).toFloat()
        val fm = paint.fontMetrics
        val padV = 1f * density
        val top = baseline + fm.ascent - padV
        val bottom = baseline + fm.descent + padV

        targetX = totalPaddingLeft + primaryX - caretWidthPx * 0.5f
        targetY = totalPaddingTop + top
        targetHeight = (bottom - top).coerceAtLeast(14f * density)
        return true
    }

    private fun updateCaretTarget(animated: Boolean) {
        if (!shouldShowCaret()) {
            hasCaretOrigin = false
            stopFrameLoop()
            invalidate()
            return
        }
        if (!computeTargetGeometry()) {
            post { if (isAttachedToWindow) updateCaretTarget(animated = false) }
            return
        }
        lastInteractionMs = android.os.SystemClock.uptimeMillis()
        val animationsEnabled = ValueAnimator.areAnimatorsEnabled()
        if (!animated || !hasCaretOrigin || !animationsEnabled) {
            currentX = targetX
            currentY = targetY
            currentHeight = targetHeight
            velocityX = 0f
            velocityY = 0f
            velocityH = 0f
            hasCaretOrigin = true
        } else {
            // Clamp extreme jumps so long-distance cursor moves glide over the final approach
            if (currentX - targetX > maxDeltaXPx) currentX = targetX + maxDeltaXPx
            else if (currentX - targetX < -maxDeltaXPx) currentX = targetX - maxDeltaXPx
            if (currentY - targetY > maxDeltaYPx) currentY = targetY + maxDeltaYPx
            else if (currentY - targetY < -maxDeltaYPx) currentY = targetY - maxDeltaYPx
        }
        ensureFrameLoop()
        invalidate()
    }

    private val blinkWakeRunnable = Runnable { ensureFrameLoop() }

    private fun ensureFrameLoop() {
        removeCallbacks(blinkWakeRunnable)
        if (!frameScheduled && isAttachedToWindow && shouldShowCaret()) {
            frameScheduled = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    private fun stopFrameLoop() {
        removeCallbacks(blinkWakeRunnable)
        if (frameScheduled) {
            frameScheduled = false
            Choreographer.getInstance().removeFrameCallback(this)
        }
        lastFrameNanos = 0L
    }

    override fun doFrame(frameTimeNanos: Long) {
        frameScheduled = false
        if (!isAttachedToWindow || !shouldShowCaret()) return

        // Keep target synced if layout shifted during edit/scroll
        computeTargetGeometry()

        val dt = if (lastFrameNanos == 0L) (1f / 60f)
        else ((frameTimeNanos - lastFrameNanos) * 1e-9f).coerceIn(1e-4f, 0.05f)
        lastFrameNanos = frameTimeNanos

        if (!ValueAnimator.areAnimatorsEnabled()) {
            currentX = targetX
            currentY = targetY
            currentHeight = targetHeight
            velocityX = 0f
            velocityY = 0f
            velocityH = 0f
        } else {
            val exp = kotlin.math.exp((-omega0 * dt).toDouble()).toFloat()
            val dx = currentX - targetX
            val dy = currentY - targetY
            val dh = currentHeight - targetHeight

            if (kotlin.math.abs(dx) > 0.1f || kotlin.math.abs(velocityX) > 0.5f) {
                val nextX = targetX + exp * (dx * (1f + omega0 * dt) + velocityX * dt)
                velocityX = exp * (velocityX * (1f - omega0 * dt) - omega0 * omega0 * dx * dt)
                currentX = nextX
            } else {
                currentX = targetX
                velocityX = 0f
            }

            if (kotlin.math.abs(dy) > 0.1f || kotlin.math.abs(velocityY) > 0.5f) {
                val nextY = targetY + exp * (dy * (1f + omega0 * dt) + velocityY * dt)
                velocityY = exp * (velocityY * (1f - omega0 * dt) - omega0 * omega0 * dy * dt)
                currentY = nextY
            } else {
                currentY = targetY
                velocityY = 0f
            }

            if (kotlin.math.abs(dh) > 0.1f || kotlin.math.abs(velocityH) > 0.5f) {
                val nextH = targetHeight + exp * (dh * (1f + omega0 * dt) + velocityH * dt)
                velocityH = exp * (velocityH * (1f - omega0 * dt) - omega0 * omega0 * dh * dt)
                currentHeight = nextH
            } else {
                currentHeight = targetHeight
                velocityH = 0f
            }
        }
        val springMoving = kotlin.math.abs(currentX - targetX) > 0.1f ||
            kotlin.math.abs(currentY - targetY) > 0.1f ||
            kotlin.math.abs(currentHeight - targetHeight) > 0.1f ||
            kotlin.math.abs(velocityX) > 0.5f ||
            kotlin.math.abs(velocityY) > 0.5f ||
            kotlin.math.abs(velocityH) > 0.5f

        invalidate()
        val elapsed = (android.os.SystemClock.uptimeMillis() - lastInteractionMs).coerceAtLeast(0L)
        if (springMoving) {
            ensureFrameLoop()
        } else {
            lastFrameNanos = 0L
            if (elapsed < 530L) {
                postDelayed(blinkWakeRunnable, (530L - elapsed) + 340L)
            } else {
                val cycle = (elapsed - 530L) % 1000L
                when {
                    cycle < 340L -> postDelayed(blinkWakeRunnable, 340L - cycle)
                    cycle < 500L -> ensureFrameLoop()
                    cycle < 840L -> postDelayed(blinkWakeRunnable, 840L - cycle)
                    else -> ensureFrameLoop()
                }
            }
        }
    }

    private fun currentCaretAlpha(): Int {
        val elapsed = (android.os.SystemClock.uptimeMillis() - lastInteractionMs).coerceAtLeast(0L)
        // Stay solid while typing/moving and for 530ms afterward, then smooth-blink every 500ms
        if (elapsed < 530L) return 255
        val cycle = (elapsed - 530L) % 1000L
        val alphaFraction = when {
            cycle < 340L -> 1f
            cycle < 500L -> {
                val t = (cycle - 340L) / 160f
                0.5f * (1f + kotlin.math.cos(Math.PI * t)).toFloat()
            }
            cycle < 840L -> 0.08f
            else -> {
                val t = (cycle - 840L) / 160f
                0.08f + 0.92f * (0.5f * (1f - kotlin.math.cos(Math.PI * t)).toFloat())
            }
        }
        return (alphaFraction * 255f).toInt().coerceIn(20, 255)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!shouldShowCaret()) return
        if (!hasCaretOrigin) {
            if (!computeTargetGeometry()) return
            currentX = targetX
            currentY = targetY
            currentHeight = targetHeight
            hasCaretOrigin = true
        }
        caretPaint.color = caretColor
        caretPaint.alpha = currentCaretAlpha()
        caretRect.set(currentX, currentY, currentX + caretWidthPx, currentY + currentHeight)
        canvas.drawRoundRect(caretRect, caretRadiusPx, caretRadiusPx, caretPaint)
    }
}
