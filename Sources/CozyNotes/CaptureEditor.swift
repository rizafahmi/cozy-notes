import AppKit
import UniformTypeIdentifiers
import ImageIO
import QuartzCore
import CozyCore

@MainActor private final class CozyUndoManager: UndoManager {
    override func undo() {
        autoreleasepool { super.undo() }
    }
    override func undoNestedGroup() {
        autoreleasepool { super.undoNestedGroup() }
    }
    override func redo() {
        autoreleasepool { super.redo() }
    }
}

@MainActor final class MarkdownTextView: NSTextView {
    private let editorUndoManager: UndoManager = {
        let um = CozyUndoManager()
        um.levelsOfUndo = 2
        return um
    }()
    override var undoManager: UndoManager? { editorUndoManager }
    var onFiles: (([URL]) -> Void)?
    var onClipboardImage: ((Data) -> Void)?
    var onFocusChange: (() -> Void)?
    var placeholder = "Begin a note, paste a clipping, or drop a file…" { didSet { needsDisplay = true } }
    struct FencedBlock {
        let fullRange: NSRange
        let headerRange: NSRange
        let bodyRange: NSRange
    }
    struct HeadingGutter {
        let range: NSRange
        let label: String
        let level: Int
    }

    var blockquoteRanges: [NSRange] = []
    var fencedBlocks: [FencedBlock] = []
    var inlineCodeRanges: [NSRange] = []
    var headingGutterItems: [HeadingGutter] = []

    struct EditRecord {
        let affectedRange: NSRange
        let replacementLength: Int
        let delta: Int
        let oldTotalLength: Int
        let windowStart: Int
        let oldWindowEnd: Int
        let oldWindowWords: Int
        let needsFullWordCount: Bool
        let requiresFullFormat: Bool
        let mayHaveLink: Bool
    }
    var pendingEdit: EditRecord?
    private var isEditingText = false
    var cachedFullText: String = ""
    var cachedFullTextLength: Int = 0
    var cachedFullTextSig: Int = 0
    private var lastClipboardChangeCount: Int = -1
    private var lastClipboardString: String = ""
    private var lastClipboardLength: Int = -1
    private var lastClipboardSig: Int = 0
    /// Bike-style smooth typewriter caret layer driven by additive critically-damped springs.
    private let caretLayer: CALayer = {
        let layer = CALayer()
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.cornerRadius = 1.0
        layer.zPosition = 999
        layer.isHidden = true
        layer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "backgroundColor": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private var hasCaretOrigin = false
    private var caretAnimationSeq: UInt64 = 0
    private var caretBlinkWorkItem: DispatchWorkItem?
    private var caretBlinkOn = true
    private var windowFocusObservers: [NSObjectProtocol] = []
    var suppressCaretUpdates = false

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        if enclosingScrollView != nil {
            let vis = visibleRect
            if vis.width > 0 && vis.height > 0 {
                let clipped = invalidRect.intersection(vis)
                guard !clipped.isNull && clipped.width > 0 && clipped.height > 0 else { return }
                super.setNeedsDisplay(clipped, avoidAdditionalLayout: true)
                return
            }
        }
        super.setNeedsDisplay(invalidRect, avoidAdditionalLayout: flag)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !fencedBlocks.isEmpty || !inlineCodeRanges.isEmpty || !blockquoteRanges.isEmpty || !headingGutterItems.isEmpty else { return }
        guard let layoutManager = layoutManager, let textContainer = textContainer, let storage = textStorage else { return }
        let totalLength = storage.length
        guard totalLength > 0 else { return }
        let origin = textContainerOrigin
        let columnWidth = max(0, bounds.width - 2 * origin.x)

        let queryRect = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -96)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: queryRect, in: textContainer)
        guard visibleGlyphs.length > 0 else { return }
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let visStart = visibleChars.location
        let visEnd = NSMaxRange(visibleChars)

        for block in fencedBlocks {
            if block.fullRange.location > visEnd { break }
            guard NSMaxRange(block.fullRange) >= visStart,
                  NSMaxRange(block.fullRange) <= totalLength,
                  NSMaxRange(block.bodyRange) <= totalLength else { continue }
            let bodyGlyphs = layoutManager.glyphRange(forCharacterRange: block.bodyRange, actualCharacterRange: nil)
            let bodyRect = layoutManager.boundingRect(forGlyphRange: bodyGlyphs, in: textContainer)
            let verticalPad: CGFloat = 14
            let headerHeight: CGFloat = 28
            let dividerY = round(origin.y + bodyRect.minY - verticalPad)
            let topY = dividerY - headerHeight
            let bottomY = round(origin.y + bodyRect.maxY - 4.5 + verticalPad)
            let box = NSRect(x: origin.x, y: topY, width: columnWidth, height: max(headerHeight + 28, bottomY - topY))

            let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
            Theme.codeBackground.setFill()
            path.fill()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            Theme.codeHeaderFill.setFill()
            NSRect(x: box.minX, y: box.minY, width: box.width, height: headerHeight).fill()
            Theme.codeBorder.setFill()
            NSRect(x: box.minX, y: dividerY, width: box.width, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()

            Theme.codeBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if !inlineCodeRanges.isEmpty {
            let codeFont = Theme.monoFont(Theme.baseProseSize - 2.0, weight: .medium)
            let pillHeight = ceil(codeFont.ascender - codeFont.descender) + 5
            for inner in inlineCodeRanges {
                if inner.location > visEnd { break }
                guard NSMaxRange(inner) >= visStart, NSMaxRange(inner) <= totalLength else { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: inner, actualCharacterRange: nil)
                let raw = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let pill = NSRect(
                    x: origin.x + raw.minX - 5,
                    y: origin.y + raw.minY,
                    width: raw.width + 10,
                    height: pillHeight
                )
                let path = NSBezierPath(roundedRect: pill, xRadius: 5.5, yRadius: 5.5)
                Theme.inlineCodeFill.setFill()
                path.fill()
                Theme.inlineCodeBorder.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        for range in blockquoteRanges {
            if range.location > visEnd { break }
            guard NSMaxRange(range) >= visStart, NSMaxRange(range) <= totalLength else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            box.origin.x = origin.x
            box.origin.y += origin.y - 4
            box.size.width = columnWidth
            box.size.height += 2
            let wash = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            Theme.quoteWash.setFill()
            wash.fill()
            let bar = NSBezierPath(
                roundedRect: NSRect(x: box.minX, y: box.minY + 3, width: 3, height: max(4, box.height - 6)),
                xRadius: 1.5, yRadius: 1.5
            )
            Theme.accent.setFill()
            bar.fill()
        }

        if !headingGutterItems.isEmpty {
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.monoFont(9.5, weight: .semibold),
                .foregroundColor: Theme.subtle.withAlphaComponent(0.8)
            ]
            for item in headingGutterItems {
                if item.range.location > visEnd { break }
                guard NSMaxRange(item.range) >= visStart, NSMaxRange(item.range) <= totalLength else { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
                let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                if origin.x >= 56 {
                    let badgeSize = (item.label as NSString).size(withAttributes: badgeAttrs)
                    let x = origin.x - 24 - badgeSize.width
                    let y = origin.y + box.minY + max(0, (box.height - badgeSize.height) / 2) - 2
                    (item.label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: badgeAttrs)
                }
                if item.level == 1 {
                    Theme.marginLine.setFill()
                    NSRect(x: origin.x + 4, y: origin.y + box.maxY + 4, width: max(0, columnWidth - 8), height: 1).fill()
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard (textStorage?.length ?? 0) == 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7.5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.italicDisplayFont(Theme.baseProseSize + 0.5),
            .foregroundColor: Theme.subtle,
            .paragraphStyle: paragraph
        ]
        (placeholder as NSString).draw(
            in: NSRect(x: textContainerInset.width + 5, y: textContainerInset.height,
                       width: max(0, bounds.width - 2 * textContainerInset.width - 10), height: 70),
            withAttributes: attributes
        )
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Suppress AppKit's teleporting insertion bar and NSTextInsertionIndicator; caretLayer renders the spring-animated caret.
    }

    @objc(_drawInsertionPointInRect:color:)
    func _drawInsertionPoint(in rect: NSRect, color: NSColor) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in windowFocusObservers { NotificationCenter.default.removeObserver(token) }
        windowFocusObservers.removeAll()
        wantsLayer = true
        ensureCaretSublayer()
        if let window {
            let nc = NotificationCenter.default
            windowFocusObservers.append(
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateCaret(animated: false) }
                }
            )
            windowFocusObservers.append(
                nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateCaret(animated: false) }
                }
            )
        }
        updateCaret(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshCaretAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?()
            updateCaret(animated: false)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            hasCaretOrigin = false
            cancelCaretBlink()
            caretLayer.isHidden = true
            onFocusChange?()
        }
        return ok
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        guard ok, let ns = textStorage?.mutableString else { return ok }
        isEditingText = true
        let oldLen = ns.length
        let repNS = (replacementString ?? "") as NSString
        let repLen = repNS.length
        let delta = repLen - affectedCharRange.length
        let isLargeEdit = affectedCharRange.length > 4096 || repLen > 4096
        var requiresFullFormat = isLargeEdit || !fencedBlocks.isEmpty
        if !requiresFullFormat {
            if affectedCharRange.length > 0 {
                let checkRange = ns.lineRange(for: affectedCharRange)
                if ns.range(of: "```", options: .literal, range: checkRange).location != NSNotFound {
                    requiresFullFormat = true
                }
            }
            if !requiresFullFormat && repLen >= 3 {
                if repNS.range(of: "```", options: .literal, range: NSRange(location: 0, length: repLen)).location != NSNotFound {
                    requiresFullFormat = true
                }
            }
        }
        let mayHaveLink = repLen > 0 && (repNS.range(of: "](", options: .literal).location != NSNotFound || repNS.range(of: ")", options: .literal).location != NSNotFound)
        if isLargeEdit {
            pendingEdit = EditRecord(
                affectedRange: affectedCharRange,
                replacementLength: repLen,
                delta: delta,
                oldTotalLength: oldLen,
                windowStart: 0,
                oldWindowEnd: oldLen,
                oldWindowWords: 0,
                needsFullWordCount: true,
                requiresFullFormat: true,
                mayHaveLink: false
            )
        } else {
            let wStart = max(0, affectedCharRange.location - 1)
            let wEnd = min(oldLen, NSMaxRange(affectedCharRange) + 1)
            let oldWords = CaptureEditor.countWords(in: ns, range: NSRange(location: wStart, length: max(0, wEnd - wStart)))
            pendingEdit = EditRecord(
                affectedRange: affectedCharRange,
                replacementLength: repLen,
                delta: delta,
                oldTotalLength: oldLen,
                windowStart: wStart,
                oldWindowEnd: wEnd,
                oldWindowWords: oldWords,
                needsFullWordCount: false,
                requiresFullFormat: requiresFullFormat,
                mayHaveLink: mayHaveLink
            )
        }
        return ok
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let clipView = enclosingScrollView?.contentView
        let savedOriginY = clipView?.bounds.origin.y
        let str: String
        if let s = string as? String {
            str = s
        } else if let attr = string as? NSAttributedString {
            str = attr.string
        } else {
            str = String(describing: string)
        }
        let targetRange = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        applyUndoableReplacement(in: targetRange, with: str)
        if let clipView, let savedOriginY, abs(clipView.bounds.origin.y - savedOriginY) > 0.01 {
            let caret = currentCaretRect()
            let visTop = savedOriginY
            let visBottom = savedOriginY + clipView.bounds.height
            if caret.minY >= visTop + 8 && caret.maxY <= visBottom - 8 {
                clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: savedOriginY))
            }
        }
    }

    override func copy(_ sender: Any?) {
        autoreleasepool {
            let sel = selectedRange()
            guard sel.length > 0, let ns = textStorage?.mutableString, NSMaxRange(sel) <= ns.length else { return }
            let pb = NSPasteboard.general
            let sig = CaptureEditor.sampleSignature(of: ns, range: sel)
            if pb.changeCount == lastClipboardChangeCount && sel.length == lastClipboardLength && sig == lastClipboardSig {
                return
            }
            let str: String
            if sel.location == 0 && sel.length == ns.length && sel.length == cachedFullTextLength && sig == cachedFullTextSig {
                str = cachedFullText
            } else {
                str = ns.substring(with: sel)
            }
            pb.clearContents()
            pb.setString(str, forType: .string)
            lastClipboardChangeCount = pb.changeCount
            lastClipboardString = str
            lastClipboardLength = sel.length
            lastClipboardSig = sig
        }
    }

    override func cut(_ sender: Any?) {
        autoreleasepool {
            let sel = selectedRange()
            guard sel.length > 0 else { return }
            copy(sender)
            applyUndoableReplacement(in: sel, with: "")
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        autoreleasepool {
            super.scrollRangeToVisible(range)
        }
    }

    override func selectAll(_ sender: Any?) {
        autoreleasepool {
            super.selectAll(sender)
        }
    }

    private func applyUndoableReplacement(in range: NSRange, with replacement: String) {
        autoreleasepool {
            guard let storage = textStorage else { return }
            breakUndoCoalescing()
            let ns = storage.mutableString
            let safeLoc = min(range.location, ns.length)
            let safeRange = NSRange(location: safeLoc, length: min(range.length, ns.length - safeLoc))

            let prevAllowsUndo = allowsUndo
            allowsUndo = false
            editorUndoManager.disableUndoRegistration()
            let allowed = shouldChangeText(in: safeRange, replacementString: replacement)
            editorUndoManager.enableUndoRegistration()
            allowsUndo = prevAllowsUndo
            guard allowed else { return }

            let previousString: String
            if safeRange.length == 0 {
                previousString = ""
            } else if safeRange.location == 0 && safeRange.length == ns.length && safeRange.length == cachedFullTextLength && CaptureEditor.sampleSignature(of: ns, range: safeRange) == cachedFullTextSig {
                previousString = cachedFullText
            } else {
                previousString = ns.substring(with: safeRange)
            }

            let repLen = (replacement as NSString).length
            let inverseRange = NSRange(location: safeRange.location, length: repLen)
            editorUndoManager.registerUndo(withTarget: self) { target in
                target.applyUndoableReplacement(in: inverseRange, with: previousString)
            }

            editorUndoManager.disableUndoRegistration()
            storage.beginEditing()
            storage.replaceCharacters(in: safeRange, with: replacement)
            storage.endEditing()
            editorUndoManager.enableUndoRegistration()

            setSelectedRange(NSRange(location: safeRange.location + repLen, length: 0))
            didChangeText()
        }
    }

    override func didChangeText() {
        isEditingText = false
        super.didChangeText()
        updateCaret(animated: true)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !suppressCaretUpdates && !isEditingText else { return }
        updateCaret(animated: !stillSelectingFlag)
    }

    func resetCaretPosition() {
        hasCaretOrigin = false
        caretLayer.removeAllAnimations()
    }

    private func ensureCaretSublayer() {
        wantsLayer = true
        guard let hostLayer = layer else { return }
        if caretLayer.superlayer !== hostLayer {
            hostLayer.addSublayer(caretLayer)
        }
        caretLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        refreshCaretAppearance()
    }

    func refreshCaretAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            caretLayer.backgroundColor = insertionPointColor.cgColor
        }
    }

    /// Computes the exact glyph-aligned caret rect in view coordinates, excluding trailing lineSpacing/paragraphSpacing.
    func currentCaretRect() -> NSRect {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return .zero }
        let origin = textContainerOrigin
        let ns = storage.mutableString
        let len = ns.length
        let charIdx = min(selectedRange().location, len)
        let caretWidth: CGFloat = 2.0
        if len > 0 {
            let ensureLoc = min(charIdx, len - 1)
            let ensureRange = ns.lineRange(for: NSRange(location: ensureLoc, length: 0))
            lm.ensureLayout(forCharacterRange: ensureRange)
        }

        let fallbackFont = (typingAttributes[.font] as? NSFont) ?? font ?? Theme.bodyFont()
        let fallbackPara = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        let sampleFont: NSFont
        let samplePara: NSParagraphStyle?

        if len == 0 || (charIdx == len && ns.character(at: len - 1) == 10) {
            sampleFont = fallbackFont
            samplePara = fallbackPara
        } else {
            let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
            var lineContentEnd = NSMaxRange(lineRange)
            while lineContentEnd > lineRange.location {
                let ch = ns.character(at: lineContentEnd - 1)
                if ch == 10 || ch == 13 { lineContentEnd -= 1 } else { break }
            }
            let probe = min(max(lineRange.location, charIdx < lineContentEnd ? charIdx : max(lineRange.location, lineContentEnd - 1)), len - 1)
            var resolvedFont = (textStorage?.attribute(.font, at: probe, effectiveRange: nil) as? NSFont) ?? fallbackFont
            if resolvedFont.pointSize < 2, lineContentEnd > lineRange.location,
               let endFont = textStorage?.attribute(.font, at: lineContentEnd - 1, effectiveRange: nil) as? NSFont,
               endFont.pointSize >= 2 {
                resolvedFont = endFont
            }
            sampleFont = resolvedFont
            samplePara = (textStorage?.attribute(.paragraphStyle, at: probe, effectiveRange: nil) as? NSParagraphStyle) ?? fallbackPara
        }

        let fontLineHeight = ceil(sampleFont.ascender - sampleFont.descender + max(0, sampleFont.leading))
        let lineSpacing = samplePara?.lineSpacing ?? 0

        let glyphIdx = lm.glyphIndexForCharacter(at: charIdx)
        let raw = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 0), in: tc)
        let rawHeight = raw.height > 0 ? raw.height : fontLineHeight
        let trimmedHeight = (lineSpacing > 0 && rawHeight - lineSpacing >= fontLineHeight - 1)
            ? (rawHeight - lineSpacing)
            : rawHeight
        let height = max(14, round(trimmedHeight))
        let x = round((origin.x + raw.minX) * 2) / 2
        let y = round((origin.y + raw.minY) * 2) / 2
        return NSRect(x: x, y: y, width: caretWidth, height: height)
    }

    func updateCaret(animated: Bool) {
        guard !suppressCaretUpdates else { return }
        ensureCaretSublayer()
        let isActive = window?.firstResponder === self && (window?.isKeyWindow ?? false) && isEditable
        let sel = selectedRange()
        guard isActive, sel.length == 0 else {
            cancelCaretBlink()
            caretLayer.isHidden = true
            if sel.length > 0 { hasCaretOrigin = false }
            return
        }

        let targetRect = currentCaretRect()
        guard targetRect.height > 0 else { return }
        let targetPos = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let targetBounds = CGRect(x: 0, y: 0, width: targetRect.width, height: targetRect.height)

        let oldPos = caretLayer.position
        let oldBounds = caretLayer.bounds
        let shouldAnimate = animated
            && hasCaretOrigin
            && !caretLayer.isHidden
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caretLayer.isHidden = false
        caretLayer.opacity = 1.0
        caretLayer.position = targetPos
        caretLayer.bounds = targetBounds
        CATransaction.commit()

        hasCaretOrigin = true
        scheduleCaretBlink()

        guard shouldAnimate else { return }
        let rawDX = oldPos.x - targetPos.x
        let rawDY = oldPos.y - targetPos.y
        let dh = oldBounds.height - targetBounds.height
        guard hypot(rawDX, rawDY) > 0.25 || abs(dh) > 0.5 else { return }

        caretAnimationSeq &+= 1
        // Critically-damped spring matching BikeLib.CaretLineLayer (response = 0.125s, dampingRatio = 1.0)
        let response: CGFloat = 0.125
        let dampingRatio: CGFloat = 1.0
        let omega0 = (2.0 * .pi) / response
        let stiffness = omega0 * omega0
        let damping = 4.0 * .pi * dampingRatio / response

        if hypot(rawDX, rawDY) > 0.25 {
            let dx = max(-180, min(180, rawDX))
            let dy = max(-120, min(120, rawDY))
            let posAnim = CASpringAnimation(keyPath: "position")
            posAnim.isAdditive = true
            posAnim.mass = 1.0
            posAnim.stiffness = stiffness
            posAnim.damping = damping
            posAnim.initialVelocity = 0.0
            posAnim.fromValue = NSValue(point: NSPoint(x: dx, y: dy))
            posAnim.toValue = NSValue(point: .zero)
            posAnim.duration = posAnim.settlingDuration
            posAnim.isRemovedOnCompletion = true
            caretLayer.add(posAnim, forKey: "caret.pos.\(caretAnimationSeq)")
        }

        if abs(dh) > 0.5 {
            let clampedDH = max(-40, min(40, dh))
            let boundsAnim = CASpringAnimation(keyPath: "bounds")
            boundsAnim.isAdditive = true
            boundsAnim.mass = 1.0
            boundsAnim.stiffness = stiffness
            boundsAnim.damping = damping
            boundsAnim.initialVelocity = 0.0
            boundsAnim.fromValue = NSValue(rect: NSRect(x: 0, y: 0, width: 0, height: clampedDH))
            boundsAnim.toValue = NSValue(rect: .zero)
            boundsAnim.duration = boundsAnim.settlingDuration
            boundsAnim.isRemovedOnCompletion = true
            caretLayer.add(boundsAnim, forKey: "caret.bounds.\(caretAnimationSeq)")
        }
    }

    private func cancelCaretBlink() {
        caretBlinkWorkItem?.cancel()
        caretBlinkWorkItem = nil
        caretBlinkOn = true
        caretLayer.removeAnimation(forKey: "caret.blink")
    }

    private func scheduleCaretBlink() {
        cancelCaretBlink()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.tickCaretBlink()
            }
        }
        caretBlinkWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.53, execute: work)
    }

    private func tickCaretBlink() {
        guard !caretLayer.isHidden, window?.firstResponder === self, window?.isKeyWindow == true else { return }
        caretBlinkOn.toggle()
        let targetOpacity: Float = caretBlinkOn ? 1.0 : 0.08
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = caretLayer.presentation()?.opacity ?? caretLayer.opacity
        fade.toValue = targetOpacity
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        caretLayer.opacity = targetOpacity
        caretLayer.add(fade, forKey: "caret.blink")

        let next = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.tickCaretBlink()
            }
        }
        caretBlinkWorkItem = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50, execute: next)
    }
    override func paste(_ sender: Any?) {
        autoreleasepool {
            let pb = NSPasteboard.general
            if pb.types?.contains(.fileURL) == true,
               let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                onFiles?(urls)
            } else if pb.availableType(from: [.string]) == nil,
                      let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                onClipboardImage?(png)
            } else {
                let str: String?
                if pb.changeCount == lastClipboardChangeCount && lastClipboardLength >= 0 {
                    str = lastClipboardString
                } else {
                    str = pb.string(forType: .string)
                }
                if let str {
                    applyUndoableReplacement(in: selectedRange(), with: str)
                } else {
                    pasteAsPlainText(sender)
                }
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

@MainActor final class CaptureEditor: NSView, NSTextViewDelegate {
    let textView = MarkdownTextView()
    let status = Theme.label("", size: 11, color: Theme.muted)
    let wordCount = Theme.label("", size: 10.5, color: Theme.subtle)
    var onChange: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onRemoveLinkedAttachment: ((LinkedAttachment) -> Void)?
    var onHorizontalInsetChange: ((CGFloat) -> Void)?
    var compactLayout = false { didSet { needsLayout = true } }
    var attachments: [URL] = [] {
        didSet {
            if attachments != oldValue { updateAttachments() }
        }
    }
    var linkedAttachments: [LinkedAttachment] = [] {
        didSet {
            if linkedAttachments != oldValue { updateAttachments() }
        }
    }
    private(set) var hasPotentialLinks = false
    var allowsAttachments = true {
        didSet { attachmentButton?.isHidden = !allowsAttachments }
    }

    private let scroll = NSScrollView()
    private var attachmentButton: QuietButton?
    private let chips = NSStackView()
    private let attachmentScroll = NSScrollView()
    private let footerRule = HairlineView()
    private let footer = NSStackView()
    private var attachmentLeading: NSLayoutConstraint?
    private var attachmentTrailing: NSLayoutConstraint?
    private var footerLeading: NSLayoutConstraint?
    private var footerTrailing: NSLayoutConstraint?
    private var previews: [URL: NSImage] = [:]
    private var temporaryFiles: [URL] = []
    private var isFormatting = false
    private var lastCursorLine = NSRange(location: NSNotFound, length: 0)
    private var cachedWordCount = 0
    private var lastFullCountLength = -1
    private var lastFullCountSampleHash = 0
    private var lastFullCountWords = 0
    private let heading = try! NSRegularExpression(pattern: "(?m)^(#{1,6}) (.+)$")
    private let blockquote = try! NSRegularExpression(pattern: "(?m)^(>+) (.*)$")
    private let listMarker = try! NSRegularExpression(pattern: "(?m)^([ \\t]*(?:[-*+]|\\d+\\.)(?:\\s+\\[[ xX]\\])?) (.*)$")
    private let bold = try! NSRegularExpression(pattern: "\\*\\*([^\\*\\n]+)\\*\\*")
    private let italic = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^\\*\\n]+)\\*(?!\\*)")
    private let link = try! NSRegularExpression(pattern: "(!?\\[[^\\]\\n]*\\])(\\([^\\)\\n]+\\))")
    private let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private let fencedCode = try! NSRegularExpression(pattern: "(?ms)^```[^\\n]*\\n.*?^```$")
    private let codeKeyword = try! NSRegularExpression(pattern: "\\b(let|var|func|struct|class|enum|return|if|else|for|in|import|guard|true|false|nil|async|await|try|private|public|static)\\b")
    private let codeString = try! NSRegularExpression(pattern: "\"[^\"\\n]*\"")

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.setAccessibilityLabel("Note text")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 36, height: 26)
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.accent
        textView.delegate = self
        textView.registerForDraggedTypes([.fileURL])
        textView.onFiles = { [weak self] in self?.addAttachments($0) }
        textView.onClipboardImage = { [weak self] in self?.addClipboardImage($0) }
        textView.onFocusChange = { [weak self] in self?.handleFocusChange() }
        scroll.verticalScroller = CozyScroller()
        scroll.documentView = textView
        scroll.scrollerStyle = .overlay
        let add = QuietButton(title: "Attach", symbol: "paperclip", target: self, action: #selector(chooseAttachments))
        add.toolTip = "Attach files or screenshots. You can also paste an image or drop files directly into the note."
        add.setContentHuggingPriority(.required, for: .horizontal)
        attachmentButton = add

        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingMiddle
        wordCount.font = Theme.monoFont(10.5, weight: .medium)
        wordCount.setContentHuggingPriority(.required, for: .horizontal)

        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 10
        chips.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        attachmentScroll.documentView = chips
        attachmentScroll.drawsBackground = false
        attachmentScroll.hasHorizontalScroller = true
        attachmentScroll.autohidesScrollers = true
        attachmentScroll.scrollerStyle = .overlay
        attachmentScroll.isHidden = true
        attachmentScroll.setAccessibilityLabel("Note attachments")

        footerRule.wantsLayer = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        for item in [add, status, spacer, wordCount] { footer.addArrangedSubview(item) }

        for view in [scroll, attachmentScroll, footerRule, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let attachLead = attachmentScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36)
        let attachTrail = attachmentScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36)
        let footLead = footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36)
        let footTrail = footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36)
        attachmentLeading = attachLead
        attachmentTrailing = attachTrail
        footerLeading = footLead
        footerTrailing = footTrail

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: attachmentScroll.topAnchor, constant: -4),
            attachLead,
            attachTrail,
            attachmentScroll.heightAnchor.constraint(equalToConstant: 62),
            attachmentScroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: -6),
            footerRule.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footLead,
            footTrail,
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 26)
        ])
        formatMarkdown()
        updateWordCount()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        let available = max(bounds.width, 320)
        let minPad: CGFloat = compactLayout ? 22 : 40
        let maxMeasure: CGFloat = 640
        let horizontal = compactLayout ? minPad : max(minPad, floor((available - maxMeasure) / 2))
        let vertical: CGFloat = compactLayout ? 18 : 26
        let chipInset = horizontal + 5
        if attachmentLeading?.constant != chipInset {
            attachmentLeading?.constant = chipInset
            attachmentTrailing?.constant = -chipInset
            footerLeading?.constant = horizontal
            footerTrailing?.constant = -horizontal
        }
        super.layout()
        scroll.layoutSubtreeIfNeeded()
        let contentWidth = scroll.contentSize.width
        let columnWidth = compactLayout
            ? max(1, contentWidth - 2 * minPad)
            : max(1, min(maxMeasure, contentWidth - 2 * minPad))
        let insetX = compactLayout ? minPad : max(minPad, floor((contentWidth - columnWidth) / 2))

        var geometryChanged = false
        if abs(textView.textContainerInset.width - insetX) > 0.5 || abs(textView.textContainerInset.height - vertical) > 0.5 {
            textView.textContainerInset = NSSize(width: insetX, height: vertical)
            textView.invalidateTextContainerOrigin()
            geometryChanged = true
        }
        if let container = textView.textContainer, contentWidth > 0, abs(container.containerSize.width - columnWidth) > 0.5 {
            let clipView = scroll.contentView
            let originY = clipView.bounds.origin.y
            var anchorChar: Int?
            if originY > 100, let lm = textView.layoutManager, let storage = textView.textStorage, storage.length > 0 {
                let visRect = clipView.documentVisibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
                let visGlyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visRect, in: container)
                if visGlyphs.length > 0 {
                    anchorChar = lm.characterIndexForGlyph(at: visGlyphs.location)
                } else {
                    let ratio = min(1.0, max(0.0, originY / max(1.0, textView.bounds.height)))
                    anchorChar = min(storage.length - 1, Int(Double(storage.length) * ratio))
                }
            }
            container.containerSize = NSSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
            if let anchorChar, let lm = textView.layoutManager, let storage = textView.textStorage, storage.length > 0 {
                let ns = storage.mutableString as NSString
                let start = max(0, anchorChar - 600)
                let end = min(ns.length, anchorChar + 2400)
                let windowRange = ns.lineRange(for: NSRange(location: start, length: end - start))
                lm.ensureLayout(forCharacterRange: windowRange)
                let glyphIdx = lm.glyphIndexForCharacter(at: min(anchorChar, ns.length - 1))
                let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 0), in: container)
                let targetY = max(0, rect.minY + textView.textContainerOrigin.y)
                clipView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
                scroll.reflectScrolledClipView(clipView)
            }
            geometryChanged = true
        }
        if contentWidth > 0 && abs(textView.frame.width - contentWidth) > 0.5 {
            textView.setFrameSize(NSSize(width: contentWidth, height: textView.frame.height))
            geometryChanged = true
        }
        onHorizontalInsetChange?(insetX)
        if geometryChanged {
            textView.updateCaret(animated: false)
            textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
        }
    }

    var nsText: NSString {
        textView.textStorage?.mutableString ?? ("" as NSString)
    }

    var text: String {
        get { textView.string }
        set {
            autoreleasepool {
                let previousSelection = textView.selectedRange()
                textView.suppressCaretUpdates = true
                textView.resetCaretPosition()
                textView.pendingEdit = nil
                let nsNew = newValue as NSString
                let newLen = nsNew.length
                let sig = Self.sampleSignature(of: nsNew)
                textView.cachedFullText = newValue
                textView.cachedFullTextLength = newLen
                textView.cachedFullTextSig = sig
                let clampedLocation = min(previousSelection.location, newLen)
                let scan = performOrReuseScan(on: nsNew, length: newLen, sig: sig)
                cachedWordCount = scan.words
                renderWordCountLabel()
                isFormatting = true
                if let storage = textView.textStorage {
                    textView.undoManager?.disableUndoRegistration()
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newValue)
                    applyFullMarkdownAttributes(to: storage, cursor: NSRange(location: clampedLocation, length: 0), scanHint: scan)
                    storage.endEditing()
                    textView.undoManager?.enableUndoRegistration()
                } else {
                    textView.string = newValue
                }
                isFormatting = false
                textView.undoManager?.removeAllActions()
                textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
                let ns = nsText
                lastCursorLine = ns.length > 0 ? ns.lineRange(for: NSRange(location: min(clampedLocation, ns.length), length: 0)) : NSRange(location: 0, length: 0)
                textView.suppressCaretUpdates = false
                textView.updateCaret(animated: false)
                textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
            }
        }
    }
    var hasContent: Bool {
        if !attachments.isEmpty { return true }
        let ns = nsText
        guard ns.length > 0 else { return false }
        return Self.countWords(in: ns, range: NSRange(location: 0, length: min(ns.length, 256))) > 0
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func focus() { window?.makeFirstResponder(textView) }
    func clearPendingAttachments() {
        if !attachments.isEmpty { attachments = [] }
        if !temporaryFiles.isEmpty {
            for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
            temporaryFiles.removeAll()
        }
    }
    func reset() {
        text = ""
        linkedAttachments = []
        clearPendingAttachments()
        status.stringValue = ""
    }
    func textDidChange(_ notification: Notification) {
        autoreleasepool {
            let edit = textView.pendingEdit
            textView.pendingEdit = nil
            let didTouchAttributes: Bool
            if let edit, !edit.requiresFullFormat {
                didTouchAttributes = formatIncrementalEdit(edit)
            } else {
                formatMarkdown()
                didTouchAttributes = true
            }
            if let edit, !edit.needsFullWordCount, let storage = textView.textStorage {
                let ns = storage.mutableString as NSString
                let newWEnd = min(ns.length, max(edit.windowStart, edit.oldWindowEnd + edit.delta))
                let newWords = Self.countWords(in: ns, range: NSRange(location: edit.windowStart, length: max(0, newWEnd - edit.windowStart)))
                cachedWordCount = max(0, cachedWordCount + newWords - edit.oldWindowWords)
                renderWordCountLabel()
            } else {
                recalculateFullWordCount()
            }
            if let edit, edit.mayHaveLink {
                hasPotentialLinks = true
            }
            if didTouchAttributes {
                textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
            }
            onChange?()
        }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isFormatting, let storage = textView.textStorage else { return }
        let ns = storage.mutableString as NSString
        let sel = textView.selectedRange()
        let clamped = NSRange(location: min(sel.location, ns.length), length: 0)
        let line = ns.lineRange(for: clamped)
        guard line != lastCursorLine else { return }
        let prevLine = lastCursorLine
        lastCursorLine = line
        refreshCursorDependentLines(oldLine: prevLine, newLine: line)
    }
    func addAttachments(_ urls: [URL]) {
        guard allowsAttachments else {
            status.stringValue = "Start a new note to add attachments."
            return
        }
        var valid: [URL] = []
        for url in urls where url.isFileURL {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue {
                valid.append(url)
            }
        }
        guard !valid.isEmpty else { return }
        if let onAttachFiles {
            onAttachFiles(valid)
            return
        }
        for url in valid where !attachments.contains(url) {
            attachments.append(url)
        }
        onChange?()
    }
    @objc private func chooseAttachments() {
        guard allowsAttachments else {
            status.stringValue = "Start a new note to add attachments."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.addAttachments(panel.urls) }
        }
    }
    private func addClipboardImage(_ data: Data) {
        guard allowsAttachments else {
            status.stringValue = "Start a new note to paste a screenshot."
            return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            temporaryFiles.append(url)
            addAttachments([url])
        } catch { showError(error, in: window) }
    }

    private struct ChipItem {
        let url: URL
        let linked: LinkedAttachment?
        let pendingIndex: Int?
    }
    private var renderedChipItems: [ChipItem] = []

    private func updateAttachments() {
        for view in chips.arrangedSubviews { chips.removeArrangedSubview(view); view.removeFromSuperview() }
        var items: [ChipItem] = linkedAttachments.map { ChipItem(url: $0.url, linked: $0, pendingIndex: nil) }
        for (idx, url) in attachments.enumerated() {
            items.append(ChipItem(url: url, linked: nil, pendingIndex: idx))
        }
        renderedChipItems = items
        let activeURLs = Set(items.map(\.url))
        previews = previews.filter { activeURLs.contains($0.key) }

        for (index, item) in items.enumerated() {
            let url = item.url
            let preview = NSImageView()
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.image = thumbnail(for: url) ?? NSWorkspace.shared.icon(forFile: url.path)
            preview.setAccessibilityElement(false)
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 6
            preview.layer?.masksToBounds = true
            preview.widthAnchor.constraint(equalToConstant: 38).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 38).isActive = true

            let name = Theme.label(url.lastPathComponent, size: 12, color: Theme.ink)
            name.font = .systemFont(ofSize: 12, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 145).isActive = true

            let kindText = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
            let kind = Theme.label("\(kindText) · Click to open", size: 10, color: Theme.muted)
            let description = Theme.stack([name, kind], orientation: .vertical, spacing: 2)

            let openBtn = QuietButton(symbol: "arrow.up.right", target: self, action: #selector(openChipAttachment(_:)))
            openBtn.tag = index
            openBtn.toolTip = "Open \(url.lastPathComponent)"
            openBtn.setAccessibilityLabel("Open \(url.lastPathComponent)")
            let remove = QuietButton(symbol: "xmark", target: self, action: #selector(removeAttachment(_:)))
            remove.setAccessibilityLabel("Remove \(url.lastPathComponent)")
            remove.toolTip = "Remove \(url.lastPathComponent) from this note"
            remove.tag = index

            let row = Theme.stack([preview, description, openBtn, remove], spacing: 6)
            let card = PaperSurface(cornerRadius: 10, color: Theme.elevated, bordered: true)
            Theme.fill(row, in: card, inset: 7)
            card.heightAnchor.constraint(equalToConstant: 52).isActive = true
            chips.addArrangedSubview(card)
        }
        chips.setFrameSize(chips.fittingSize)
        attachmentScroll.isHidden = items.isEmpty
    }

    @objc private func openChipAttachment(_ sender: NSButton) {
        guard renderedChipItems.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.open(renderedChipItems[sender.tag].url)
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        guard renderedChipItems.indices.contains(sender.tag) else { return }
        let item = renderedChipItems[sender.tag]
        if let pendingIndex = item.pendingIndex, attachments.indices.contains(pendingIndex) {
            attachments.remove(at: pendingIndex)
            onChange?()
        } else if let linked = item.linked {
            onRemoveLinkedAttachment?(linked)
        }
    }

    private func thumbnail(for url: URL) -> NSImage? {
        if let cached = previews[url] { return cached }
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 120
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        previews[url] = thumbnail
        return thumbnail
    }

    func refreshTypography() {
        formatMarkdown()
        textView.updateCaret(animated: false)
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
    }

    private func handleFocusChange() {
        guard !isFormatting, let storage = textView.textStorage else { return }
        let ns = storage.mutableString as NSString
        let sel = textView.selectedRange()
        let clamped = NSRange(location: min(sel.location, ns.length), length: 0)
        let line = ns.lineRange(for: clamped)
        refreshCursorDependentLines(oldLine: lastCursorLine, newLine: line)
    }

    struct DocumentScanResult {
        let words: Int
        let hasStar: Bool
        let hasDoubleStar: Bool
        let hasBacktick: Bool
        let hasTripleBacktick: Bool
        let hasLinkOpen: Bool
    }
    private var lastScanResult: DocumentScanResult?

    static func sampleSignature(of ns: NSString, range: NSRange? = nil) -> Int {
        let r = range ?? NSRange(location: 0, length: ns.length)
        let len = r.length
        guard len > 0, NSMaxRange(r) <= ns.length else { return 0 }
        let base = r.location
        var h = len &* 31
        let p0 = ns.character(at: base)
        let pMid = ns.character(at: base + len / 2)
        let pEnd = ns.character(at: base + len - 1)
        h = (h &* 31) &+ Int(p0)
        h = (h &* 31) &+ Int(pMid)
        h = (h &* 31) &+ Int(pEnd)
        if len > 100 {
            h = (h &* 31) &+ Int(ns.character(at: base + len / 4))
            h = (h &* 31) &+ Int(ns.character(at: base + (len * 3) / 4))
        }
        return h
    }

    static func scanDocument(in ns: NSString, range: NSRange) -> DocumentScanResult {
        guard range.length > 0 else {
            return DocumentScanResult(words: 0, hasStar: false, hasDoubleStar: false, hasBacktick: false, hasTripleBacktick: false, hasLinkOpen: false)
        }
        let cfStr = ns as CFString
        var words = 0
        var inWord = false
        var hasStar = false
        var hasDoubleStar = false
        var hasBacktick = false
        var hasTripleBacktick = false
        var hasLinkOpen = false
        var prevChar: UniChar = 0
        var runBackticks = 0

        let chunkCap = 16384
        let allocSize = min(chunkCap, range.length)
        let buf = UnsafeMutablePointer<UniChar>.allocate(capacity: allocSize)
        defer { buf.deallocate() }

        var offset = range.location
        let end = NSMaxRange(range)
        while offset < end {
            let count = min(allocSize, end - offset)
            CFStringGetCharacters(cfStr, CFRange(location: offset, length: count), buf)
            var i = 0
            while i < count {
                let u = buf[i]
                if u > 0x60 && u < 0x0085 {
                    if !inWord {
                        inWord = true
                        words &+= 1
                    }
                    prevChar = 0
                    runBackticks = 0
                } else if u <= 0x20 {
                    if u == 0x20 || (u >= 0x09 && u <= 0x0D) {
                        inWord = false
                    } else if !inWord {
                        inWord = true
                        words &+= 1
                    }
                    prevChar = 0
                    runBackticks = 0
                } else {
                    let isWS = u >= 0x0085 && ((u == 0x0085) || (u == 0x00A0) || (u >= 0x2000 && u <= 0x200A) || (u == 0x2028) || (u == 0x2029) || (u == 0x202F) || (u == 0x205F) || (u == 0x3000))
                    if isWS {
                        inWord = false
                        prevChar = 0
                        runBackticks = 0
                    } else {
                        if !inWord {
                            inWord = true
                            words &+= 1
                        }
                        if u == 0x2A {
                            hasStar = true
                            if prevChar == 0x2A { hasDoubleStar = true }
                            runBackticks = 0
                        } else if u == 0x60 {
                            hasBacktick = true
                            runBackticks &+= 1
                            if runBackticks >= 3 { hasTripleBacktick = true }
                        } else {
                            if u == 0x28 && prevChar == 0x5D {
                                hasLinkOpen = true
                            }
                            runBackticks = 0
                        }
                        prevChar = u
                    }
                }
                i &+= 1
            }
            offset &+= count
        }
        return DocumentScanResult(
            words: words,
            hasStar: hasStar,
            hasDoubleStar: hasDoubleStar,
            hasBacktick: hasBacktick,
            hasTripleBacktick: hasTripleBacktick,
            hasLinkOpen: hasLinkOpen
        )
    }

    static func countWords(in ns: NSString, range: NSRange) -> Int {
        scanDocument(in: ns, range: range).words
    }

    private func performOrReuseScan(on ns: NSString, length: Int, sig: Int) -> DocumentScanResult {
        if length == 0 {
            return DocumentScanResult(words: 0, hasStar: false, hasDoubleStar: false, hasBacktick: false, hasTripleBacktick: false, hasLinkOpen: false)
        }
        if length == lastFullCountLength, sig == lastFullCountSampleHash, let cached = lastScanResult {
            return cached
        }
        let scan = Self.scanDocument(in: ns, range: NSRange(location: 0, length: length))
        lastFullCountLength = length
        lastFullCountSampleHash = sig
        lastFullCountWords = scan.words
        lastScanResult = scan
        return scan
    }

    private func recalculateFullWordCount() {
        let ns = nsText
        let len = ns.length
        if len == 0 {
            cachedWordCount = 0
            renderWordCountLabel()
            return
        }
        let sig = Self.sampleSignature(of: ns)
        let scan = performOrReuseScan(on: ns, length: len, sig: sig)
        cachedWordCount = scan.words
        renderWordCountLabel()
    }

    private func updateWordCount() {
        recalculateFullWordCount()
    }

    private func renderWordCountLabel() {
        let words = cachedWordCount
        guard words > 0 else {
            if wordCount.stringValue != "BLANK FOLIO" {
                wordCount.stringValue = "BLANK FOLIO"
            }
            return
        }
        let mins = max(1, (words + 199) / 200)
        let next = "\(words) \(words == 1 ? "WORD" : "WORDS")  ·  \(mins) MIN READ"
        if wordCount.stringValue != next {
            wordCount.stringValue = next
        }
    }

    private func lineHasCursorSensitiveSyntax(_ ns: NSString, lineRange: NSRange) -> Bool {
        guard lineRange.location != NSNotFound, lineRange.length > 0, NSMaxRange(lineRange) <= ns.length else { return false }
        let first = ns.character(at: lineRange.location)
        if first == 0x23 || first == 0x60 { return true }
        if ns.range(of: "`", options: .literal, range: lineRange).location != NSNotFound { return true }
        return false
    }

    private func refreshCursorDependentLines(oldLine: NSRange, newLine: NSRange) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.mutableString as NSString
        let oldNeeds = lineHasCursorSensitiveSyntax(ns, lineRange: oldLine)
        let newNeeds = lineHasCursorSensitiveSyntax(ns, lineRange: newLine)
        guard oldNeeds || newNeeds else { return }
        if !textView.fencedBlocks.isEmpty {
            formatMarkdown()
            textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
            return
        }
        isFormatting = true
        defer { isFormatting = false }
        let cursor = textView.selectedRange()
        storage.beginEditing()
        if oldNeeds, NSMaxRange(oldLine) <= ns.length {
            var q: [NSRange] = []
            var h: [MarkdownTextView.HeadingGutter] = []
            var c: [NSRange] = []
            formatLineRange(oldLine, in: storage, ns: ns, cursor: cursor, quotes: &q, headings: &h, codes: &c)
        }
        if newNeeds, newLine != oldLine, NSMaxRange(newLine) <= ns.length {
            var q: [NSRange] = []
            var h: [MarkdownTextView.HeadingGutter] = []
            var c: [NSRange] = []
            formatLineRange(newLine, in: storage, ns: ns, cursor: cursor, quotes: &q, headings: &h, codes: &c)
        }
        storage.endEditing()
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
    }

    private func lineHasMarkdownSyntax(_ ns: NSString, lineRange: NSRange) -> Bool {
        guard lineRange.length > 0, NSMaxRange(lineRange) <= ns.length else { return false }
        let c0 = ns.character(at: lineRange.location)
        if c0 == 0x23 || c0 == 0x3E || c0 == 0x2D || c0 == 0x2A || c0 == 0x2B || c0 == 0x20 || c0 == 0x09 || (c0 >= 0x30 && c0 <= 0x39) {
            return true
        }
        if ns.range(of: "*", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "`", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "](", options: .literal, range: lineRange).location != NSNotFound { return true }
        return false
    }

    @discardableResult
    private func formatIncrementalEdit(_ edit: MarkdownTextView.EditRecord) -> Bool {
        guard !isFormatting, let storage = textView.textStorage else { return false }
        isFormatting = true
        defer { isFormatting = false }
        let ns = storage.mutableString as NSString
        let newLen = ns.length
        let editLoc = min(edit.affectedRange.location, newLen)
        let newEditedRange = NSRange(location: editLoc, length: min(edit.replacementLength, newLen - editLoc))
        let newLineRange = ns.lineRange(for: newEditedRange)
        let oldLineEnd = max(newLineRange.location, NSMaxRange(newLineRange) - edit.delta)
        let oldLineRange = NSRange(location: newLineRange.location, length: oldLineEnd - newLineRange.location)
        let delta = edit.delta

        let hadItemsInOldLine = textView.headingGutterItems.contains { NSIntersectionRange($0.range, oldLineRange).length > 0 || $0.range.location == oldLineRange.location }
            || textView.blockquoteRanges.contains { NSIntersectionRange($0, oldLineRange).length > 0 || $0.location == oldLineRange.location }
            || textView.inlineCodeRanges.contains { NSIntersectionRange($0, oldLineRange).length > 0 || $0.location == oldLineRange.location }

        let newHasSyntax = lineHasMarkdownSyntax(ns, lineRange: newLineRange)

        if !hadItemsInOldLine && !newHasSyntax {
            // Fast path for plain prose editing: shift subsequent decoration ranges without touching NSTextStorage attributes
            if delta != 0 {
                let shiftStart = oldLineEnd
                for i in textView.headingGutterItems.indices where textView.headingGutterItems[i].range.location >= shiftStart {
                    let r = textView.headingGutterItems[i].range
                    textView.headingGutterItems[i] = MarkdownTextView.HeadingGutter(
                        range: NSRange(location: r.location + delta, length: r.length),
                        label: textView.headingGutterItems[i].label,
                        level: textView.headingGutterItems[i].level
                    )
                }
                for i in textView.blockquoteRanges.indices where textView.blockquoteRanges[i].location >= shiftStart {
                    let r = textView.blockquoteRanges[i]
                    textView.blockquoteRanges[i] = NSRange(location: r.location + delta, length: r.length)
                }
                for i in textView.inlineCodeRanges.indices where textView.inlineCodeRanges[i].location >= shiftStart {
                    let r = textView.inlineCodeRanges[i]
                    textView.inlineCodeRanges[i] = NSRange(location: r.location + delta, length: r.length)
                }
            }
            lastCursorLine = ns.lineRange(for: NSRange(location: min(textView.selectedRange().location, newLen), length: 0))
            return false
        }

        var newQuotes: [NSRange] = []
        var newHeadings: [MarkdownTextView.HeadingGutter] = []
        var newCodes: [NSRange] = []
        let cursor = textView.selectedRange()

        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        formatLineRange(newLineRange, in: storage, ns: ns, cursor: cursor, quotes: &newQuotes, headings: &newHeadings, codes: &newCodes)
        storage.endEditing()
        textView.undoManager?.enableUndoRegistration()

        let oldEnd = NSMaxRange(oldLineRange)
        var updatedHeadings: [MarkdownTextView.HeadingGutter] = []
        updatedHeadings.reserveCapacity(textView.headingGutterItems.count + newHeadings.count)
        var insertedHeadings = false
        for item in textView.headingGutterItems {
            if NSMaxRange(item.range) <= oldLineRange.location && item.range.location < oldLineRange.location {
                updatedHeadings.append(item)
            } else if item.range.location >= oldEnd && oldEnd > oldLineRange.location {
                if !insertedHeadings {
                    updatedHeadings.append(contentsOf: newHeadings)
                    insertedHeadings = true
                }
                updatedHeadings.append(MarkdownTextView.HeadingGutter(
                    range: NSRange(location: item.range.location + delta, length: item.range.length),
                    label: item.label,
                    level: item.level
                ))
            }
        }
        if !insertedHeadings { updatedHeadings.append(contentsOf: newHeadings) }
        textView.headingGutterItems = updatedHeadings

        var updatedQuotes: [NSRange] = []
        var insertedQuotes = false
        for r in textView.blockquoteRanges {
            if NSMaxRange(r) <= oldLineRange.location && r.location < oldLineRange.location {
                updatedQuotes.append(r)
            } else if r.location >= oldEnd && oldEnd > oldLineRange.location {
                if !insertedQuotes {
                    updatedQuotes.append(contentsOf: newQuotes)
                    insertedQuotes = true
                }
                updatedQuotes.append(NSRange(location: r.location + delta, length: r.length))
            }
        }
        if !insertedQuotes { updatedQuotes.append(contentsOf: newQuotes) }
        textView.blockquoteRanges = updatedQuotes

        var updatedCodes: [NSRange] = []
        var insertedCodes = false
        for r in textView.inlineCodeRanges {
            if NSMaxRange(r) <= oldLineRange.location && r.location < oldLineRange.location {
                updatedCodes.append(r)
            } else if r.location >= oldEnd && oldEnd > oldLineRange.location {
                if !insertedCodes {
                    updatedCodes.append(contentsOf: newCodes)
                    insertedCodes = true
                }
                updatedCodes.append(NSRange(location: r.location + delta, length: r.length))
            }
        }
        if !insertedCodes { updatedCodes.append(contentsOf: newCodes) }
        textView.inlineCodeRanges = updatedCodes

        lastCursorLine = ns.lineRange(for: NSRange(location: min(cursor.location, newLen), length: 0))
        return true
    }

    private func formatMarkdown() {
        guard !isFormatting, let storage = textView.textStorage else { return }
        isFormatting = true
        defer { isFormatting = false }
        let cursor = textView.selectedRange()
        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        applyFullMarkdownAttributes(to: storage, cursor: cursor, scanHint: nil)
        storage.endEditing()
        textView.undoManager?.enableUndoRegistration()
    }

    private func applyFullMarkdownAttributes(to storage: NSTextStorage, cursor: NSRange, scanHint: DocumentScanResult?) {
        let ns = storage.mutableString as NSString
        let totalLen = ns.length
        let range = NSRange(location: 0, length: totalLen)
        let proseSize = Theme.baseProseSize
        let baseFont = Theme.bodyFont(proseSize)
        let tracking = Theme.proseTracking

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 8.0
        bodyParagraph.paragraphSpacing = 11.5

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: Theme.ink,
            .paragraphStyle: bodyParagraph,
            .kern: tracking
        ]

        textView.selectedTextAttributes = [
            .backgroundColor: Theme.selectionHighlight,
            .foregroundColor: Theme.headingInk
        ]
        textView.insertionPointColor = Theme.accent
        textView.refreshCaretAppearance()
        textView.typingAttributes = baseAttrs

        guard totalLen > 0 else {
            textView.blockquoteRanges = []
            textView.headingGutterItems = []
            textView.inlineCodeRanges = []
            textView.fencedBlocks = []
            hasPotentialLinks = false
            return
        }

        let scan = scanHint ?? performOrReuseScan(on: ns, length: totalLen, sig: Self.sampleSignature(of: ns))

        storage.setAttributes(baseAttrs, range: range)

        var quotes: [NSRange] = []
        var headings: [MarkdownTextView.HeadingGutter] = []
        var inlinePills: [NSRange] = []
        var parsedFences: [MarkdownTextView.FencedBlock] = []

        formatLineRange(range, in: storage, ns: ns, cursor: cursor, scan: scan, quotes: &quotes, headings: &headings, codes: &inlinePills)

        if scan.hasTripleBacktick && ns.range(of: "```", options: .literal, range: range).location != NSNotFound {
            let codeBodyParagraph = NSMutableParagraphStyle()
            codeBodyParagraph.lineSpacing = 4.5
            codeBodyParagraph.paragraphSpacing = 2.5
            codeBodyParagraph.firstLineHeadIndent = 16
            codeBodyParagraph.headIndent = 16

            let openFenceParagraph = NSMutableParagraphStyle()
            openFenceParagraph.lineSpacing = 2.0
            openFenceParagraph.paragraphSpacingBefore = 8.0
            openFenceParagraph.paragraphSpacing = 21.0
            openFenceParagraph.firstLineHeadIndent = 16
            openFenceParagraph.headIndent = 16

            let closeFenceParagraph = NSMutableParagraphStyle()
            closeFenceParagraph.lineSpacing = 1.0
            closeFenceParagraph.paragraphSpacingBefore = 8.0
            closeFenceParagraph.paragraphSpacing = 12.0
            closeFenceParagraph.firstLineHeadIndent = 16
            closeFenceParagraph.headIndent = 16

            let current = ns as String
            for match in fencedCode.matches(in: current, range: range) {
                storage.addAttributes([
                    .font: Theme.monoFont(proseSize - 2.5),
                    .foregroundColor: Theme.headingInk,
                    .paragraphStyle: codeBodyParagraph,
                    .kern: 0.0
                ], range: match.range)

                for kw in codeKeyword.matches(in: current, range: match.range) {
                    storage.addAttributes([
                        .font: Theme.monoFont(proseSize - 2.5, weight: .semibold),
                        .foregroundColor: Theme.accent
                    ], range: kw.range)
                }
                for str in codeString.matches(in: current, range: match.range) {
                    storage.addAttributes([
                        .foregroundColor: Theme.sage
                    ], range: str.range)
                }

                let blockString = ns.substring(with: match.range)
                if let firstNewline = blockString.firstIndex(of: "\n") {
                    let openFenceLen = blockString.distance(from: blockString.startIndex, to: firstNewline)
                    let headerRange = NSRange(location: match.range.location, length: openFenceLen)
                    let bodyStart = min(NSMaxRange(match.range), match.range.location + openFenceLen + 1)
                    let bodyEnd = max(bodyStart, NSMaxRange(match.range) - 4)
                    let bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
                    parsedFences.append(MarkdownTextView.FencedBlock(fullRange: match.range, headerRange: headerRange, bodyRange: bodyRange))
                    storage.addAttributes([
                        .font: Theme.monoFont(11, weight: .semibold),
                        .foregroundColor: Theme.muted,
                        .paragraphStyle: openFenceParagraph,
                        .kern: 0.6
                    ], range: headerRange)
                    let cursorOnFence = cursor.location >= headerRange.location && cursor.location <= NSMaxRange(headerRange)
                    if !cursorOnFence && openFenceLen > 3 {
                        storage.addAttributes([
                            .font: NSFont.systemFont(ofSize: 0.1),
                            .foregroundColor: NSColor.clear
                        ], range: NSRange(location: match.range.location, length: 3))
                    }
                }
                if match.range.length >= 3 {
                    let closeRange = NSRange(location: NSMaxRange(match.range) - 3, length: 3)
                    let cursorOnClose = cursor.location >= closeRange.location && cursor.location <= NSMaxRange(closeRange)
                    storage.addAttributes([
                        .font: cursorOnClose ? Theme.monoFont(11, weight: .medium) : Theme.monoFont(4),
                        .foregroundColor: cursorOnClose ? Theme.subtle : NSColor.clear,
                        .paragraphStyle: closeFenceParagraph
                    ], range: closeRange)
                }
            }
        }

        textView.blockquoteRanges = quotes
        textView.headingGutterItems = headings
        textView.inlineCodeRanges = inlinePills
        textView.fencedBlocks = parsedFences
    }

    private func formatLineRange(
        _ targetRange: NSRange,
        in storage: NSTextStorage,
        ns: NSString,
        cursor: NSRange,
        scan: DocumentScanResult? = nil,
        quotes: inout [NSRange],
        headings: inout [MarkdownTextView.HeadingGutter],
        codes: inout [NSRange]
    ) {
        let totalLen = ns.length
        guard targetRange.length > 0, NSMaxRange(targetRange) <= totalLen else { return }
        let proseSize = Theme.baseProseSize
        let baseFont = Theme.bodyFont(proseSize)
        let tracking = Theme.proseTracking

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 8.0
        bodyParagraph.paragraphSpacing = 11.5

        if targetRange.length < totalLen {
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: Theme.ink,
                .paragraphStyle: bodyParagraph,
                .kern: tracking
            ], range: targetRange)
        }

        let checkDoubleStar = scan?.hasDoubleStar ?? true
        let checkStar = scan?.hasStar ?? true
        let checkLink = scan?.hasLinkOpen ?? true
        let checkBacktick = scan?.hasBacktick ?? true

        // 1. Inline spans via fast literal search on NSString
        if checkDoubleStar && ns.range(of: "**", options: .literal, range: targetRange).location != NSNotFound {
            let boldFont = Theme.bodyFont(proseSize, weight: .semibold)
            let markerAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)]
            var searchStart = targetRange.location
            let targetEnd = NSMaxRange(targetRange)
            while searchStart < targetEnd {
                let hit = ns.range(of: "**", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in bold.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let full = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    storage.addAttributes([.font: boldFont, .foregroundColor: Theme.headingInk], range: full)
                    storage.addAttributes(markerAttrs, range: NSRange(location: full.location, length: 2))
                    storage.addAttributes(markerAttrs, range: NSRange(location: NSMaxRange(full) - 2, length: 2))
                }
                searchStart = NSMaxRange(lineRange)
            }
        }

        if checkStar && ns.range(of: "*", options: .literal, range: targetRange).location != NSNotFound {
            let italicFont = Theme.italicBodyFont(proseSize)
            let markerAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)]
            var searchStart = targetRange.location
            let targetEnd = NSMaxRange(targetRange)
            while searchStart < targetEnd {
                let hit = ns.range(of: "*", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in italic.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let full = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    let inner = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    storage.addAttributes([.font: italicFont], range: inner)
                    storage.addAttributes(markerAttrs, range: NSRange(location: full.location, length: 1))
                    storage.addAttributes(markerAttrs, range: NSRange(location: NSMaxRange(full) - 1, length: 1))
                }
                searchStart = NSMaxRange(lineRange)
            }
        }

        if checkLink && ns.range(of: "](", options: .literal, range: targetRange).location != NSNotFound {
            hasPotentialLinks = true
            let linkTextAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.accent, .font: Theme.bodyFont(proseSize, weight: .medium)]
            let linkURLAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)]
            var searchStart = targetRange.location
            let targetEnd = NSMaxRange(targetRange)
            while searchStart < targetEnd {
                let hit = ns.range(of: "](", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in link.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let g1 = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    let g2 = NSRange(location: lineRange.location + match.range(at: 2).location, length: match.range(at: 2).length)
                    storage.addAttributes(linkTextAttrs, range: g1)
                    storage.addAttributes(linkURLAttrs, range: g2)
                }
                searchStart = NSMaxRange(lineRange)
            }
        } else if targetRange.length == totalLen {
            hasPotentialLinks = false
        }

        if checkBacktick && ns.range(of: "`", options: .literal, range: targetRange).location != NSNotFound {
            let codeAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.monoFont(proseSize - 2.0, weight: .medium),
                .foregroundColor: Theme.inlineCodeInk,
                .kern: 0.15
            ]
            let fontNear = Theme.monoFont(11)
            let fontFar = Theme.monoFont(11.5)
            var searchStart = targetRange.location
            let targetEnd = NSMaxRange(targetRange)
            while searchStart < targetEnd {
                let hit = ns.range(of: "`", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in code.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let full = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    let inner = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    codes.append(inner)
                    storage.addAttributes(codeAttrs, range: inner)
                    let open = NSRange(location: full.location, length: 1)
                    let close = NSRange(location: NSMaxRange(full) - 1, length: 1)
                    let cursorNear = cursor.location >= full.location && cursor.location <= NSMaxRange(full)
                    let tickColor = cursorNear ? Theme.subtle : NSColor.clear
                    let tickFont = cursorNear ? fontNear : fontFar
                    storage.addAttributes([.foregroundColor: tickColor, .font: tickFont], range: open)
                    storage.addAttributes([.foregroundColor: tickColor, .font: tickFont], range: close)
                }
                searchStart = NSMaxRange(lineRange)
            }
        }

        // 2. Line-anchored constructs (headings, blockquotes, lists) by stepping line-by-line
        var linePos = targetRange.location
        let targetEnd = NSMaxRange(targetRange)
        let isFocused = textView.window?.firstResponder === textView
        var lazyQuoteParagraph: NSMutableParagraphStyle?
        let hiddenAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 0.1),
            .foregroundColor: NSColor.clear
        ]

        while linePos < targetEnd {
            let lineRange = ns.lineRange(for: NSRange(location: linePos, length: 0))
            let nextPos = max(linePos + 1, NSMaxRange(lineRange))
            defer { linePos = nextPos }

            var contentEnd = min(NSMaxRange(lineRange), totalLen)
            while contentEnd > lineRange.location {
                let ch = ns.character(at: contentEnd - 1)
                if ch == 10 || ch == 13 { contentEnd -= 1 } else { break }
            }
            let contentLen = contentEnd - lineRange.location
            guard contentLen > 0 else { continue }

            let c0 = ns.character(at: lineRange.location)
            if c0 == 0x23 { // '#'
                var h = 1
                while h <= 6 && lineRange.location + h < contentEnd && ns.character(at: lineRange.location + h) == 0x23 {
                    h += 1
                }
                if h <= 6 && lineRange.location + h + 1 <= contentEnd && lineRange.location + h < contentEnd && ns.character(at: lineRange.location + h) == 0x20 && lineRange.location + h + 1 <= contentEnd && (contentEnd - (lineRange.location + h + 1)) > 0 {
                    let matchRange = NSRange(location: lineRange.location, length: contentLen)
                    let hashes = NSRange(location: lineRange.location, length: h)
                    let titleRange = NSRange(location: lineRange.location + h + 1, length: contentEnd - (lineRange.location + h + 1))
                    let prefixRange = NSRange(location: hashes.location, length: min(totalLen - hashes.location, h + 1))
                    let level = h
                    headings.append(MarkdownTextView.HeadingGutter(range: matchRange, label: "H\(level)", level: level))
                    let headingFont = Theme.headingFont(level: level)
                    let headingParagraph = NSMutableParagraphStyle()
                    let headingKern: CGFloat
                    switch level {
                    case 1:
                        headingParagraph.lineSpacing = 3.0
                        headingParagraph.paragraphSpacingBefore = 4.0
                        headingParagraph.paragraphSpacing = 16.0
                        headingKern = -0.35
                    case 2:
                        headingParagraph.lineSpacing = 3.5
                        headingParagraph.paragraphSpacingBefore = 18.0
                        headingParagraph.paragraphSpacing = 8.0
                        headingKern = -0.20
                    default:
                        headingParagraph.lineSpacing = 4.0
                        headingParagraph.paragraphSpacingBefore = 14.0
                        headingParagraph.paragraphSpacing = 6.0
                        headingKern = -0.10
                    }
                    storage.addAttribute(.paragraphStyle, value: headingParagraph, range: matchRange)
                    storage.addAttributes([
                        .font: headingFont,
                        .foregroundColor: Theme.headingInk,
                        .kern: headingKern
                    ], range: titleRange)

                    let cursorOnHeading = cursor.location >= matchRange.location && cursor.location <= NSMaxRange(matchRange) && isFocused
                    if cursorOnHeading || compactLayout {
                        let hashPt = round(headingFont.pointSize * 0.56)
                        storage.addAttributes([
                            .font: Theme.monoFont(hashPt, weight: .semibold),
                            .foregroundColor: Theme.accent.withAlphaComponent(0.7),
                            .baselineOffset: round(headingFont.pointSize * 0.12)
                        ], range: hashes)
                    } else {
                        storage.addAttributes(hiddenAttrs, range: prefixRange)
                    }
                }
            } else if c0 == 0x3E { // '>'
                var q = 1
                while lineRange.location + q < contentEnd && ns.character(at: lineRange.location + q) == 0x3E {
                    q += 1
                }
                if lineRange.location + q < contentEnd && ns.character(at: lineRange.location + q) == 0x20 {
                    let matchRange = NSRange(location: lineRange.location, length: contentLen)
                    let g1 = NSRange(location: lineRange.location, length: q)
                    let g2 = NSRange(location: lineRange.location + q + 1, length: contentEnd - (lineRange.location + q + 1))
                    quotes.append(matchRange)
                    let qp: NSMutableParagraphStyle
                    if let existing = lazyQuoteParagraph {
                        qp = existing
                    } else {
                        let created = NSMutableParagraphStyle()
                        created.lineSpacing = 6.5
                        created.paragraphSpacing = 10.0
                        created.firstLineHeadIndent = 14
                        created.headIndent = 26
                        lazyQuoteParagraph = created
                        qp = created
                    }
                    storage.addAttribute(.paragraphStyle, value: qp, range: matchRange)
                    storage.addAttributes([
                        .font: Theme.monoFont(12.5, weight: .semibold),
                        .foregroundColor: Theme.accent
                    ], range: g1)
                    storage.addAttributes([
                        .font: Theme.italicDisplayFont(proseSize + 0.5),
                        .foregroundColor: Theme.muted,
                        .kern: 0.05
                    ], range: g2)
                }
            } else if c0 == 0x2D || c0 == 0x2A || c0 == 0x2B || c0 == 0x20 || c0 == 0x09 || (c0 >= 0x30 && c0 <= 0x39) {
                var p = lineRange.location
                while p < contentEnd {
                    let ch = ns.character(at: p)
                    if ch == 0x20 || ch == 0x09 { p += 1 } else { break }
                }
                guard p < contentEnd else { continue }
                let mc = ns.character(at: p)
                guard mc == 0x2D || mc == 0x2A || mc == 0x2B || (mc >= 0x30 && mc <= 0x39) else { continue }
                let contentRange = NSRange(location: lineRange.location, length: contentLen)
                let lineStr = ns.substring(with: contentRange)
                if let match = listMarker.firstMatch(in: lineStr, range: NSRange(location: 0, length: contentLen)) {
                    let fullMatchRange = NSRange(location: contentRange.location + match.range.location, length: match.range.length)
                    let markerRange = NSRange(location: contentRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    let bodyRange = NSRange(location: contentRange.location + match.range(at: 2).location, length: match.range(at: 2).length)
                    let markerText = (lineStr as NSString).substring(with: match.range(at: 1))
                    let isTask = markerText.hasSuffix("[ ]") || markerText.hasSuffix("[x]") || markerText.hasSuffix("[X]")
                    let itemParagraph = NSMutableParagraphStyle()
                    itemParagraph.lineSpacing = 5.5
                    itemParagraph.paragraphSpacing = 4.5
                    itemParagraph.headIndent = isTask ? 42 : 18
                    storage.addAttribute(.paragraphStyle, value: itemParagraph, range: fullMatchRange)
                    let completed = markerText.hasSuffix("[x]") || markerText.hasSuffix("[X]")
                    storage.addAttributes([
                        .font: Theme.monoFont(proseSize - 2.5, weight: .semibold),
                        .foregroundColor: completed ? Theme.sage : Theme.accent
                    ], range: markerRange)
                    if completed {
                        storage.addAttributes([
                            .foregroundColor: Theme.muted,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: Theme.subtle.withAlphaComponent(0.75)
                        ], range: bodyRange)
                    }
                }
            }
        }
    }
}
