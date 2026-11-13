package app.cozynotes.capture

import android.animation.ValueAnimator
import android.content.Context
import android.content.ContextWrapper
import android.content.res.Resources
import android.database.ContentObserver
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Choreographer
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.CompletionInfo
import android.view.inputmethod.CorrectionInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.TextAttribute
import android.view.inputmethod.TextSnapshot
import android.widget.EditText
import kotlin.math.abs
import kotlin.math.exp

/** The native editor owns text, selection, blink, handles, IME geometry, and scrolling. */
internal class SpringCaretEditText private constructor(context: Context, caret: CaretPresentation) :
    EditText(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) context else CursorContext(context, caret)) {
    constructor(context: Context, color: Int) : this(context, CaretPresentation(context, color))

    // TextView invokes overridable methods in its constructor, before this field is initialized.
    private var presentation: CaretPresentation? = null
    private var connectionGeneration = 0

    init {
        presentation = caret
        caret.editor = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) textCursorDrawable = NativeCaretDrawable(caret)
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val connection = super.onCreateInputConnection(outAttrs) ?: return null
        val generation = ++connectionGeneration
        presentation?.snap()
        return when {
            Build.VERSION.SDK_INT >= 34 -> ReplacementInputConnection(connection, generation)
            Build.VERSION.SDK_INT >= 33 -> AttributeInputConnection(connection, generation)
            else -> TypingInputConnection(connection, generation)
        }
    }

    private open inner class TypingInputConnection(protected val connection: InputConnection, protected val generation: Int) :
        InputConnectionWrapper(connection, false) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean =
                imeText(text, newCursorPosition, generation) { super.commitText(text, newCursorPosition) }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean =
                imeText(text, newCursorPosition, generation) { super.setComposingText(text, newCursorPosition) }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
            imeBackspace(beforeLength, afterLength, false, generation) { super.deleteSurroundingText(beforeLength, afterLength) }

        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean =
            imeBackspace(beforeLength, afterLength, true, generation) { super.deleteSurroundingTextInCodePoints(beforeLength, afterLength) }

        override fun setSelection(start: Int, end: Int): Boolean {
            presentation?.snap()
            return super.setSelection(start, end)
        }

        override fun setComposingRegion(start: Int, end: Int): Boolean {
            presentation?.snap()
            return super.setComposingRegion(start, end)
        }

        override fun commitCompletion(text: CompletionInfo?): Boolean {
            presentation?.snap()
            return super.commitCompletion(text)
        }

        override fun commitCorrection(correctionInfo: CorrectionInfo?): Boolean {
            presentation?.snap()
            return super.commitCorrection(correctionInfo)
        }

        override fun performEditorAction(editorAction: Int): Boolean {
            presentation?.snap()
            return super.performEditorAction(editorAction)
        }

        override fun performContextMenuAction(id: Int): Boolean {
            presentation?.snap()
            return super.performContextMenuAction(id)
        }

        override fun closeConnection() {
            if (generation == connectionGeneration) {
                connectionGeneration++
                presentation?.snap()
            }
            super.closeConnection()
        }
    }

    @android.annotation.TargetApi(33)
    private open inner class AttributeInputConnection(connection: InputConnection, generation: Int) : TypingInputConnection(connection, generation) {
        override fun commitText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean =
            imeText(text, newCursorPosition, generation) { connection.commitText(text, newCursorPosition, textAttribute) }

        override fun setComposingText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean =
            imeText(text, newCursorPosition, generation) { connection.setComposingText(text, newCursorPosition, textAttribute) }

        override fun setComposingRegion(start: Int, end: Int, textAttribute: TextAttribute?): Boolean {
            presentation?.snap()
            return connection.setComposingRegion(start, end, textAttribute)
        }

        // API 33's InputConnectionWrapper omitted delegation of the native snapshot.
        override fun takeSnapshot(): TextSnapshot? = connection.takeSnapshot()
    }

    @android.annotation.TargetApi(34)
    private inner class ReplacementInputConnection(connection: InputConnection, generation: Int) : AttributeInputConnection(connection, generation) {
        override fun replaceText(start: Int, end: Int, text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean {
            presentation?.snap()
            return connection.replaceText(start, end, text, newCursorPosition, textAttribute)
        }
    }

    private inline fun imeText(value: CharSequence?, newCursorPosition: Int, generation: Int, operation: () -> Boolean): Boolean {
        val buffer = text
        val selection = selectionStart
        val composingStart = BaseInputConnection.getComposingSpanStart(buffer)
        val composingEnd = BaseInputConnection.getComposingSpanEnd(buffer)
        val composing = composingStart >= 0 && composingEnd >= composingStart && composingEnd <= buffer.length
        val start = if (composing) composingStart else selection
        val removed = if (composing) composingEnd - composingStart else 0
        val added = value?.length ?: 0
        val eligible = generation == connectionGeneration && newCursorPosition == 1 && selection >= 0 && selection == selectionEnd &&
            (!composing || selection == composingEnd) && value != null &&
            isIncrementalText(buffer, start, removed, value)
        return inputEdit(eligible, start, removed, added, start + added, operation)
    }

    private fun isIncrementalText(buffer: CharSequence, start: Int, removed: Int, value: CharSequence): Boolean {
        val added = value.length
        val difference = added - removed
        if (difference !in -2..2 || start < 0 || start + removed > buffer.length) return false
        val sharedLength = minOf(removed, added)
        for (index in 0 until sharedLength) if (buffer[start + index] != value[index]) return false
        // IMEs resend the whole composing word per keystroke; accept only a single code-point
        // append/backspace, or identical text when committing an existing composition.
        return when {
            difference > 0 -> Character.codePointCount(value, sharedLength, added) == 1
            difference < 0 -> Character.codePointCount(buffer, start + sharedLength, start + removed) == 1
            else -> removed > 0
        }
    }

    private inline fun imeBackspace(before: Int, after: Int, codePoints: Boolean, generation: Int, operation: () -> Boolean): Boolean {
        val selection = selectionStart
        val removed = previousCodePointLength(selection)
        val eligible = generation == connectionGeneration && selection == selectionEnd && removed > 0 && after == 0 &&
            before == (if (codePoints) 1 else removed) && BaseInputConnection.getComposingSpanStart(text) < 0
        return inputEdit(eligible, selection - removed, removed, 0, selection - removed, operation)
    }

    private fun previousCodePointLength(selection: Int): Int =
        if (selection > 0 && selection <= text.length) Character.charCount(Character.codePointBefore(text, selection)) else 0

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val selection = selectionStart
        val unmodified = !event.isCtrlPressed && !event.isAltPressed && !event.isMetaPressed &&
            selection >= 0 && selection == selectionEnd && BaseInputConnection.getComposingSpanStart(text) < 0
        val character = event.unicodeChar
        val ordinaryCharacter = character != 0 && character and KeyCharacterMap.COMBINING_ACCENT == 0
        val removed = if (keyCode == KeyEvent.KEYCODE_DEL) previousCodePointLength(selection) else 0
        val added = if (keyCode == KeyEvent.KEYCODE_ENTER) 1 else if (ordinaryCharacter) Character.charCount(character) else 0
        val eligible = unmodified && (removed > 0 || (keyCode != KeyEvent.KEYCODE_DEL && added > 0))
        return inputEdit(eligible, selection - removed, removed, added, selection - removed + added) { super.onKeyDown(keyCode, event) }
    }

    private inline fun inputEdit(eligible: Boolean, start: Int, removed: Int, added: Int, selection: Int, operation: () -> Boolean): Boolean {
        val caret = presentation
        caret?.beginInput(eligible, start, removed, added, selection)
        var handled = false
        try {
            handled = operation()
            return handled
        } finally {
            caret?.endInput(handled)
        }
    }

    override fun setText(text: CharSequence?, type: BufferType?) {
        presentation?.snap()
        super.setText(text, type)
    }

    override fun setSelection(start: Int, stop: Int) {
        presentation?.snap()
        super.setSelection(start, stop)
    }

    override fun setSelection(index: Int) {
        presentation?.snap()
        super.setSelection(index)
    }

    override fun selectAll() {
        presentation?.snap()
        super.selectAll()
    }

    override fun extendSelection(index: Int) {
        presentation?.snap()
        super.extendSelection(index)
    }

    override fun onTextChanged(text: CharSequence?, start: Int, lengthBefore: Int, lengthAfter: Int) {
        super.onTextChanged(text, start, lengthBefore, lengthAfter)
        presentation?.textChanged(start, lengthBefore, lengthAfter)
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        presentation?.selectionChanged()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        presentation?.snap()
        return super.onTouchEvent(event)
    }

    override fun onTextContextMenuItem(id: Int): Boolean {
        presentation?.snap()
        return super.onTextContextMenuItem(id)
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        presentation?.snap()
        return super.performAccessibilityAction(action, arguments)
    }

    override fun onFocusChanged(focused: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        presentation?.snap()
        super.onFocusChanged(focused, direction, previouslyFocusedRect)
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        presentation?.reconcileMotion()
        presentation?.snap()
        super.onWindowFocusChanged(hasWindowFocus)
    }

    override fun setEnabled(enabled: Boolean) {
        if (!enabled) presentation?.snap()
        super.setEnabled(enabled)
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        if (changed) presentation?.snap()
        super.onLayout(changed, left, top, right, bottom)
    }

    override fun onScrollChanged(left: Int, top: Int, oldLeft: Int, oldTop: Int) {
        presentation?.snap()
        super.onScrollChanged(left, top, oldLeft, oldTop)
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        if (visibility != View.VISIBLE) presentation?.snap()
        super.onWindowVisibilityChanged(visibility)
    }

    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        if (visibility != View.VISIBLE) presentation?.snap()
        super.onVisibilityChanged(changedView, visibility)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        presentation?.attach()
    }

    override fun onDetachedFromWindow() {
        presentation?.detach()
        connectionGeneration++
        super.onDetachedFromWindow()
    }
}

/** A finite, critically damped presentation spring; no selection or viewport writes. */
private class CaretPresentation(private val context: Context, color: Int) : Choreographer.FrameCallback {
    var editor: SpringCaretEditText? = null
    val width = (2f * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
    private val radius = context.resources.displayMetrics.density
    private var primary: NativeCaretDrawable? = null
    private var initialized = false
    private var x = 0.0
    private var y = 0.0
    private var targetX = 0.0
    private var targetY = 0.0
    private var velocityX = 0.0
    private var velocityY = 0.0
    private var targetHeight = 0
    private var running = false
    private var frameTime = 0L
    private var choreographer: Choreographer? = null
    private var motionAllowed = false
    private var inputDepth = 0
    private var eligibleInput = false
    private var changeCount = 0
    private var expectedStart = 0
    private var expectedRemoved = 0
    private var expectedAdded = 0
    private var expectedSelection = 0
    private var previousSelection = 0
    private var pendingTyping = false
    private var pendingSelection = 0
    private var observerTree: ViewTreeObserver? = null
    private val location = IntArray(2)
    private var locationX = 0
    private var locationY = 0
    private var viewWidth = 0
    private var viewHeight = 0
    private var layoutWidth = 0
    private var paddingLeft = 0
    private var paddingTop = 0
    private var textSize = 0f
    private var textScaleX = 0f
    private var lineSpacing = 0f
    private var typeface: android.graphics.Typeface? = null
    private val scrollListener = ViewTreeObserver.OnScrollChangedListener { reconcileGeometry() }
    private val layoutListener = ViewTreeObserver.OnGlobalLayoutListener { reconcileGeometry() }
    private val motionObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) { reconcileMotion() }
    }

    fun beginInput(eligible: Boolean, start: Int, removed: Int, added: Int, selection: Int) {
        if (inputDepth == 0) {
            reconcileMotion()
            eligibleInput = eligible && motionAllowed && canShow()
            changeCount = 0
            expectedStart = start
            expectedRemoved = removed
            expectedAdded = added
            expectedSelection = selection
            previousSelection = editor?.selectionStart ?: -1
            if (!eligibleInput) snap()
        } else if (!eligible) {
            snap()
        }
        inputDepth++
    }

    fun endInput(handled: Boolean) {
        if (!handled) eligibleInput = false
        inputDepth--
        if (inputDepth != 0) return
        val view = editor ?: return
        if (!eligibleInput || changeCount != 1 || view.selectionStart != expectedSelection || view.selectionEnd != expectedSelection) {
            snap()
        } else if (previousSelection != expectedSelection) {
            if (running) choreographer?.removeFrameCallback(this)
            pendingTyping = true
            pendingSelection = expectedSelection
        }
        eligibleInput = false
    }

    fun textChanged(start: Int, before: Int, after: Int) {
        if (inputDepth == 0) {
            snap()
        } else {
            changeCount++
            if (changeCount != 1 || start != expectedStart || before != expectedRemoved || after != expectedAdded) snap()
        }
    }

    fun selectionChanged() {
        if (inputDepth == 0) snap()
    }

    fun draw(drawable: NativeCaretDrawable, canvas: Canvas) {
        val bounds = drawable.bounds
        if (!canShow()) {
            snap()
            // Native drawing also serves the magnifier, which can hide the on-screen cursor.
            canvas.drawRoundRect(bounds.left.toFloat(), bounds.top.toFloat(), bounds.right.toFloat(), bounds.bottom.toFloat(), radius, radius, paint)
            return
        }
        if (primary == null) primary = drawable
        if (primary !== drawable) {
            canvas.drawRoundRect(bounds.left.toFloat(), bounds.top.toFloat(), bounds.right.toFloat(), bounds.bottom.toFloat(), radius, radius, paint)
            return
        }
        val view = editor ?: return
        val admitted = pendingTyping && motionAllowed && view.selectionStart == pendingSelection && view.selectionEnd == pendingSelection
        pendingTyping = false
        val nextX = bounds.left.toDouble()
        val nextY = bounds.top.toDouble()
        val height = bounds.height()
        if (!initialized || nextX != targetX || nextY != targetY || height != targetHeight) {
            val animate = initialized && admitted && height == targetHeight
            targetX = nextX
            targetY = nextY
            targetHeight = height
            initialized = true
            if (animate) {
                // Keep displayed position and safe velocity on retarget, limiting target crossings
                // after a rapid backspace reversal instead of adding bounce to the writing caret.
                velocityX = nonOvershootingVelocity(x - targetX, velocityX)
                velocityY = nonOvershootingVelocity(y - targetY, velocityY)
                running = x != targetX || y != targetY || velocityX != 0.0 || velocityY != 0.0
            } else {
                settle()
            }
        }
        if (admitted && running) {
            choreographer?.removeFrameCallback(this)
            frameTime = System.nanoTime()
            choreographer?.postFrameCallback(this)
        }
        canvas.drawRoundRect(x.toFloat(), y.toFloat(), x.toFloat() + bounds.width(), y.toFloat() + targetHeight, radius, radius, paint)
    }

    private fun nonOvershootingVelocity(displacement: Double, velocity: Double): Double = when {
        displacement == 0.0 -> 0.0
        displacement > 0.0 -> velocity.coerceIn(-FREQUENCY * displacement, 0.0)
        else -> velocity.coerceIn(0.0, -FREQUENCY * displacement)
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!running) return
        if (!motionAllowed || !ValueAnimator.areAnimatorsEnabled() || !canShow()) {
            snap()
            return
        }
        val elapsed = ((frameTimeNanos - frameTime).coerceAtLeast(0L) * 1e-9)
        frameTime = frameTimeNanos
        val decay = exp(-FREQUENCY * elapsed)
        val dx = x - targetX
        val dy = y - targetY
        val cx = velocityX + FREQUENCY * dx
        val cy = velocityY + FREQUENCY * dy
        x = targetX + (dx + cx * elapsed) * decay
        y = targetY + (dy + cy * elapsed) * decay
        velocityX = (velocityX - FREQUENCY * cx * elapsed) * decay
        velocityY = (velocityY - FREQUENCY * cy * elapsed) * decay
        if (abs(x - targetX) < 0.05 && abs(y - targetY) < 0.05 && abs(velocityX) < 1.0 && abs(velocityY) < 1.0) {
            settle()
        } else {
            choreographer?.postFrameCallback(this)
        }
        editor?.invalidate()
    }

    fun snap() {
        pendingTyping = false
        eligibleInput = false
        val bounds = primary?.bounds
        if (bounds != null) {
            targetX = bounds.left.toDouble()
            targetY = bounds.top.toDouble()
            targetHeight = bounds.height()
        }
        val needsDraw = running || x != targetX || y != targetY
        settle()
        if (needsDraw) editor?.invalidate()
    }

    private fun settle() {
        if (running) choreographer?.removeFrameCallback(this)
        running = false
        velocityX = 0.0
        velocityY = 0.0
        x = targetX
        y = targetY
    }

    private fun canShow(): Boolean {
        val view = editor ?: return false
        return view.isAttachedToWindow && view.isShown && view.isEnabled && view.isFocused && view.hasWindowFocus() &&
            view.isCursorVisible && view.selectionStart >= 0 && view.selectionStart == view.selectionEnd
    }

    fun reconcileMotion() {
        val allowed = CaptureMotion.allowsCaretAnimation(context)
        if (motionAllowed != allowed) {
            motionAllowed = allowed
            snap()
        }
    }

    private fun reconcileGeometry() {
        val view = editor ?: return
        view.getLocationInWindow(location)
        val nextLayoutWidth = view.layout?.width ?: 0
        val changed = viewWidth != view.width || viewHeight != view.height || locationX != location[0] || locationY != location[1] ||
            layoutWidth != nextLayoutWidth || paddingLeft != view.compoundPaddingLeft || paddingTop != view.totalPaddingTop ||
            textSize != view.textSize || textScaleX != view.textScaleX || lineSpacing != view.lineSpacingExtra || typeface !== view.typeface
        if (changed) snap()
        viewWidth = view.width
        viewHeight = view.height
        locationX = location[0]
        locationY = location[1]
        layoutWidth = nextLayoutWidth
        paddingLeft = view.compoundPaddingLeft
        paddingTop = view.totalPaddingTop
        textSize = view.textSize
        textScaleX = view.textScaleX
        lineSpacing = view.lineSpacingExtra
        typeface = view.typeface
    }

    fun attach() {
        val view = editor ?: return
        choreographer = Choreographer.getInstance()
        observerTree = view.viewTreeObserver.also {
            it.addOnScrollChangedListener(scrollListener)
            it.addOnGlobalLayoutListener(layoutListener)
        }
        for (setting in MOTION_SETTINGS) context.contentResolver.registerContentObserver(Settings.Global.getUriFor(setting), false, motionObserver)
        reconcileMotion()
        reconcileGeometry()
        snap()
    }

    fun detach() {
        snap()
        context.contentResolver.unregisterContentObserver(motionObserver)
        observerTree?.let {
            if (it.isAlive) {
                it.removeOnScrollChangedListener(scrollListener)
                it.removeOnGlobalLayoutListener(layoutListener)
            }
        }
        observerTree = null
        choreographer = null
    }

    companion object {
        // Bike-style writing convention: response 0.125 seconds, damping ratio 1.0.
        private const val FREQUENCY = 2.0 * Math.PI / 0.125
        private val MOTION_SETTINGS = arrayOf(Settings.Global.ANIMATOR_DURATION_SCALE, Settings.Global.TRANSITION_ANIMATION_SCALE, Settings.Global.WINDOW_ANIMATION_SCALE)
    }
}

/** Bounds remain the immediate native insertion rectangle, including native bidi split carets. */
private class NativeCaretDrawable(private val presentation: CaretPresentation) : Drawable() {
    override fun draw(canvas: Canvas) = presentation.draw(this, canvas)
    override fun getIntrinsicWidth(): Int = presentation.width
    override fun getIntrinsicHeight(): Int = presentation.width * 12
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
    override fun setAlpha(alpha: Int) { presentation.paint.alpha = alpha }
    override fun setColorFilter(colorFilter: ColorFilter?) { presentation.paint.colorFilter = colorFilter }
}

/** API 26–28 expose only a cursor resource. Intercept this editor's existing themed resource
 * rather than using hidden Editor fields or disabling native insertion-handle/blink behavior. */
private class CursorContext(base: Context, presentation: CaretPresentation) : ContextWrapper(base) {
    private val cursorResources = CursorResources(base.resources, presentation)
    override fun getResources(): Resources = cursorResources
}

@Suppress("DEPRECATION")
private class CursorResources(private val original: Resources, private val presentation: CaretPresentation) :
    Resources(original.assets, original.displayMetrics, original.configuration) {
    override fun getDrawable(id: Int, theme: Theme?): Drawable =
        if (id == R.drawable.transparent_cursor) NativeCaretDrawable(presentation) else original.getDrawable(id, theme)
}
