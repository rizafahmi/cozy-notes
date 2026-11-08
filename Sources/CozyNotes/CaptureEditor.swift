import AppKit
import UniformTypeIdentifiers
import ImageIO
import QuartzCore
import CozyCore

@MainActor final class MarkdownTextView: NSTextView {
    private let editorUndoManager = UndoManager()
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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return }
        let origin = textContainerOrigin
        let columnWidth = max(0, bounds.width - 2 * origin.x)
        let totalLength = (string as NSString).length

        for block in fencedBlocks where NSMaxRange(block.fullRange) <= totalLength && NSMaxRange(block.bodyRange) <= totalLength {
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

        let codeFont = Theme.monoFont(Theme.baseProseSize - 2.0, weight: .medium)
        let pillHeight = ceil(codeFont.ascender - codeFont.descender) + 5
        for inner in inlineCodeRanges where NSMaxRange(inner) <= totalLength {
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

        for range in blockquoteRanges where NSMaxRange(range) <= totalLength {
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

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.monoFont(9.5, weight: .semibold),
            .foregroundColor: Theme.subtle.withAlphaComponent(0.8)
        ]
        for item in headingGutterItems where NSMaxRange(item.range) <= totalLength {
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
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

    override func didChangeText() {
        super.didChangeText()
        updateCaret(animated: true)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !suppressCaretUpdates else { return }
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
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        lm.ensureLayout(for: tc)
        let origin = textContainerOrigin
        let ns = string as NSString
        let len = ns.length
        let charIdx = min(selectedRange().location, len)
        let caretWidth: CGFloat = 2.0

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
        refreshCaretAppearance()
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
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls)
        } else if NSPasteboard.general.string(forType: .string) == nil,
                  let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            onClipboardImage?(png)
        } else {
            pasteAsPlainText(sender)
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
    var attachments: [URL] = [] { didSet { updateAttachments() } }
    var linkedAttachments: [LinkedAttachment] = [] { didSet { updateAttachments() } }
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
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 36, height: 26)
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.accent
        textView.delegate = self
        textView.registerForDraggedTypes([.fileURL])
        textView.onFiles = { [weak self] in self?.addAttachments($0) }
        textView.onClipboardImage = { [weak self] in self?.addClipboardImage($0) }
        textView.onFocusChange = { [weak self] in self?.formatMarkdown() }
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
        if contentWidth > 0 && abs(textView.frame.width - contentWidth) > 0.5 {
            textView.setFrameSize(NSSize(width: contentWidth, height: textView.frame.height))
        }
        if abs(textView.textContainerInset.width - horizontal) > 0.5 || abs(textView.textContainerInset.height - vertical) > 0.5 {
            textView.textContainerInset = NSSize(width: horizontal, height: vertical)
        }
        textView.invalidateTextContainerOrigin()
        if let container = textView.textContainer {
            textView.layoutManager?.textContainerChangedGeometry(container)
            textView.layoutManager?.ensureLayout(for: container)
        }
        onHorizontalInsetChange?(horizontal)
        textView.updateCaret(animated: false)
        textView.needsDisplay = true
    }

    var text: String {
        get { textView.string }
        set {
            let previousSelection = textView.selectedRange()
            textView.suppressCaretUpdates = true
            textView.resetCaretPosition()
            textView.string = newValue
            textView.undoManager?.removeAllActions()
            formatMarkdown()
            let clampedLocation = min(previousSelection.location, (newValue as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
            textView.suppressCaretUpdates = false
            textView.updateCaret(animated: false)
            updateWordCount()
            textView.needsDisplay = true
        }
    }
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    func focus() { window?.makeFirstResponder(textView) }
    func clearPendingAttachments() {
        attachments = []
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles.removeAll()
    }
    func reset() {
        text = ""
        linkedAttachments = []
        clearPendingAttachments()
        status.stringValue = ""
    }
    func textDidChange(_ notification: Notification) {
        formatMarkdown()
        updateWordCount()
        textView.needsDisplay = true
        onChange?()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isFormatting else { return }
        let ns = text as NSString
        let sel = textView.selectedRange()
        let clamped = NSRange(location: min(sel.location, ns.length), length: 0)
        let line = ns.lineRange(for: clamped)
        guard line != lastCursorLine else { return }
        lastCursorLine = line
        formatMarkdown()
        textView.needsDisplay = true
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
        textView.needsDisplay = true
    }

    private func updateWordCount() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            wordCount.stringValue = "BLANK FOLIO"
            return
        }
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        let mins = max(1, Int(ceil(Double(words) / 200.0)))
        wordCount.stringValue = "\(words) \(words == 1 ? "WORD" : "WORDS")  ·  \(mins) MIN READ"
    }

    private func formatMarkdown() {
        guard !isFormatting, let storage = textView.textStorage else { return }
        isFormatting = true
        defer { isFormatting = false }
        let current = text
        let ns = current as NSString
        let range = NSRange(location: 0, length: storage.length)
        let cursor = textView.selectedRange()
        let proseSize = Theme.baseProseSize
        let baseFont = Theme.bodyFont(proseSize)
        let tracking = Theme.proseTracking

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 8.0
        bodyParagraph.paragraphSpacing = 11.5

        let quoteParagraph = NSMutableParagraphStyle()
        quoteParagraph.lineSpacing = 6.5
        quoteParagraph.paragraphSpacing = 10.0
        quoteParagraph.firstLineHeadIndent = 14
        quoteParagraph.headIndent = 26

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

        let quoteMatches = blockquote.matches(in: current, range: range)
        let fenceMatches = fencedCode.matches(in: current, range: range)
        let headingMatches = heading.matches(in: current, range: range)
        let listMatches = listMarker.matches(in: current, range: range)

        textView.blockquoteRanges = quoteMatches.map(\.range)
        textView.headingGutterItems = headingMatches.map { match in
            let level = min(6, match.range(at: 1).length)
            return MarkdownTextView.HeadingGutter(range: match.range, label: "H\(level)", level: level)
        }
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.selectionHighlight,
            .foregroundColor: Theme.headingInk
        ]
        textView.insertionPointColor = Theme.accent
        textView.refreshCaretAppearance()
        var inlinePills: [NSRange] = []
        var parsedFences: [MarkdownTextView.FencedBlock] = []

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: Theme.ink,
            .paragraphStyle: bodyParagraph,
            .kern: tracking
        ], range: range)

        for match in quoteMatches {
            storage.addAttribute(.paragraphStyle, value: quoteParagraph, range: match.range)
            storage.addAttributes([
                .font: Theme.monoFont(12.5, weight: .semibold),
                .foregroundColor: Theme.accent
            ], range: match.range(at: 1))
            storage.addAttributes([
                .font: Theme.italicDisplayFont(proseSize + 0.5),
                .foregroundColor: Theme.muted,
                .kern: 0.05
            ], range: match.range(at: 2))
        }
        for match in bold.matches(in: current, range: range) {
            storage.addAttributes([
                .font: Theme.bodyFont(proseSize, weight: .semibold),
                .foregroundColor: Theme.headingInk
            ], range: match.range)
            let open = NSRange(location: match.range.location, length: 2)
            let close = NSRange(location: NSMaxRange(match.range) - 2, length: 2)
            storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)], range: open)
            storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)], range: close)
        }
        for match in italic.matches(in: current, range: range) {
            storage.addAttributes([.font: Theme.italicBodyFont(proseSize)], range: match.range(at: 1))
            let open = NSRange(location: match.range.location, length: 1)
            let close = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
            storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)], range: open)
            storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)], range: close)
        }
        for match in link.matches(in: current, range: range) {
            storage.addAttributes([
                .foregroundColor: Theme.accent,
                .font: Theme.bodyFont(proseSize, weight: .medium)
            ], range: match.range(at: 1))
            storage.addAttributes([
                .foregroundColor: Theme.subtle,
                .font: Theme.monoFont(12)
            ], range: match.range(at: 2))
        }
        for match in code.matches(in: current, range: range) {
            let inner = match.range(at: 1)
            inlinePills.append(inner)
            storage.addAttributes([
                .font: Theme.monoFont(proseSize - 2.0, weight: .medium),
                .foregroundColor: Theme.inlineCodeInk,
                .kern: 0.15
            ], range: inner)
            let open = NSRange(location: match.range.location, length: 1)
            let close = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
            let cursorNear = cursor.location >= match.range.location && cursor.location <= NSMaxRange(match.range)
            let tickColor = cursorNear ? Theme.subtle : NSColor.clear
            let tickFont = cursorNear ? Theme.monoFont(11) : Theme.monoFont(11.5)
            storage.addAttributes([.foregroundColor: tickColor, .font: tickFont], range: open)
            storage.addAttributes([.foregroundColor: tickColor, .font: tickFont], range: close)
        }
        for match in listMatches {
            let markerRange = match.range(at: 1)
            let bodyRange = match.range(at: 2)
            let markerText = ns.substring(with: markerRange)
            let isTask = markerText.hasSuffix("[ ]") || markerText.hasSuffix("[x]") || markerText.hasSuffix("[X]")
            let itemParagraph = NSMutableParagraphStyle()
            itemParagraph.lineSpacing = 5.5
            itemParagraph.paragraphSpacing = 4.5
            itemParagraph.headIndent = isTask ? 42 : 18
            storage.addAttribute(.paragraphStyle, value: itemParagraph, range: match.range)
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
        for match in headingMatches {
            let hashes = match.range(at: 1)
            let titleRange = match.range(at: 2)
            let prefixRange = NSRange(location: hashes.location, length: min(ns.length - hashes.location, hashes.length + 1))
            let level = hashes.length
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
            storage.addAttribute(.paragraphStyle, value: headingParagraph, range: match.range)
            storage.addAttributes([
                .font: headingFont,
                .foregroundColor: Theme.headingInk,
                .kern: headingKern
            ], range: titleRange)

            let cursorOnHeading = cursor.location >= match.range.location && cursor.location <= NSMaxRange(match.range) && textView.window?.firstResponder === textView
            if cursorOnHeading || compactLayout {
                let hashPt = round(headingFont.pointSize * 0.56)
                storage.addAttributes([
                    .font: Theme.monoFont(hashPt, weight: .semibold),
                    .foregroundColor: Theme.accent.withAlphaComponent(0.7),
                    .baselineOffset: round(headingFont.pointSize * 0.12)
                ], range: hashes)
            } else {
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear
                ], range: prefixRange)
            }
        }
        for match in fenceMatches {
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
        textView.inlineCodeRanges = inlinePills
        textView.fencedBlocks = parsedFences
        storage.endEditing()
        if let tc = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: tc)
        }
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: Theme.ink,
            .paragraphStyle: bodyParagraph,
            .kern: tracking
        ]
    }
}
