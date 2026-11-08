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

@MainActor final class MarkdownTextView: NSTextView, NSLayoutManagerDelegate {
    private let editorUndoManager: UndoManager = {
        let um = CozyUndoManager()
        um.levelsOfUndo = 2
        return um
    }()
    override var undoManager: UndoManager? { editorUndoManager }
    var onFiles: (([URL]) -> Void)?
    var onClipboardImage: ((Data) -> Void)?
    var onFocusChange: (() -> Void)?
    var onFoldStatusChange: ((String) -> Void)?
    var onOpenWikiLink: ((WikiLink) -> Void)?
    var onOpenWikiLinkInNewWindow: ((WikiLink) -> Void)?
    var onOpenCurrentNoteInNewWindow: (() -> Void)?
    var onInsertWikiLinkShortcut: (() -> Void)?
    var onWikiAutocompleteCommand: ((Selector) -> Bool)?
    var onQuickSwitcher: (() -> Void)?
    var onShowInNoteFind: (() -> Void)?
    var onFindNextInNote: (() -> Void)?
    var onFindPreviousInNote: (() -> Void)?
    var onToggleOutline: (() -> Void)?
    var placeholder = "Begin a note, paste a clipping, or drop a file…" { didSet { needsDisplay = true } }
    struct FencedBlock {
        let fullRange: NSRange
        let headerRange: NSRange
        let bodyRange: NSRange
    }
    struct HeadingGutter: Equatable {
        let range: NSRange
        let label: String
        let level: Int
        let title: String

        init(range: NSRange, label: String, level: Int, title: String = "") {
            self.range = range
            self.label = label
            self.level = level
            self.title = title
        }
    }
    struct BulletItem: Equatable {
        enum Kind: Equatable {
            case unordered
            case ordered
            case task(completed: Bool)
        }
        let lineRange: NSRange
        let markerRange: NSRange
        let level: Int
        let kind: Kind
    }
    enum OutlineFoldMode: Equatable {
        case showAll
        case overview
        case headingsOnly
    }
    struct FoldedSection: Equatable {
        let headingLocation: Int
        let headingRange: NSRange
        let headingLevel: Int
        let foldedCharRange: NSRange
        let hiddenLineCount: Int
    }
    private struct FoldHitTarget {
        let rect: NSRect
        let headingLocation: Int
    }

    var blockquoteRanges: [NSRange] = []
    var fencedBlocks: [FencedBlock] = []
    var inlineCodeRanges: [NSRange] = []
    var wikiLinkItems: [WikiLink] = []
    var inNoteFindRanges: [NSRange] = []
    var activeInNoteFindIndex: Int = -1
    var headingGutterItems: [HeadingGutter] = []
    var bulletItems: [BulletItem] = []
    var externalChangeRanges: [NSRange] = []
    private(set) var foldedSections: [FoldedSection] = []
    private(set) var outlineFoldMode: OutlineFoldMode = .showAll
    private var foldHitTargets: [FoldHitTarget] = []
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
    var isEditingText = false
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
    private(set) var scrollSpringTargetY: CGFloat?
    private var scrollSpringVelocityY: CGFloat = 0
    private var scrollSpringWorkItem: DispatchWorkItem?
    private var lastEditWasLarge = false
    private var minimumOverscrollHeight: CGFloat = 0
    private var windowFocusObservers: [NSObjectProtocol] = []
    var suppressCaretUpdates = false
    override func setFrameSize(_ newSize: NSSize) {
        if minimumOverscrollHeight > 0 {
            let maxOverscroll = newSize.height + (enclosingScrollView?.contentView.bounds.height ?? 0) * 0.4
            if minimumOverscrollHeight > maxOverscroll {
                minimumOverscrollHeight = maxOverscroll
            }
        }
        let clampedHeight = max(newSize.height, minimumOverscrollHeight)
        super.setFrameSize(NSSize(width: newSize.width, height: clampedHeight))
    }

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
        guard !fencedBlocks.isEmpty || !inlineCodeRanges.isEmpty || !wikiLinkItems.isEmpty || !inNoteFindRanges.isEmpty || !blockquoteRanges.isEmpty || !headingGutterItems.isEmpty || !bulletItems.isEmpty || !externalChangeRanges.isEmpty else { return }
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

        if !externalChangeRanges.isEmpty {
            for changeRange in externalChangeRanges {
                if changeRange.location > visEnd { break }
                guard NSMaxRange(changeRange) >= visStart, NSMaxRange(changeRange) <= totalLength else { continue }
                if isCharacterFolded(changeRange.location) { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: changeRange, actualCharacterRange: nil)
                let raw = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let bandRect = NSRect(
                    x: origin.x - 8,
                    y: origin.y + raw.minY - 1,
                    width: columnWidth + 16,
                    height: max(16, raw.height - 2)
                )
                let bandPath = NSBezierPath(roundedRect: bandRect, xRadius: 5, yRadius: 5)
                Theme.sage.withAlphaComponent(0.11).setFill()
                bandPath.fill()
                let barRect = NSRect(
                    x: max(4, origin.x - 10),
                    y: origin.y + raw.minY + 1,
                    width: 3,
                    height: max(12, raw.height - 6)
                )
                let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
                Theme.sage.withAlphaComponent(0.85).setFill()
                barPath.fill()
            }
        }
        for block in fencedBlocks {
            if block.fullRange.location > visEnd { break }
            if isCharacterFolded(block.fullRange.location) { continue }
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
                if isCharacterFolded(inner.location) { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: inner, actualCharacterRange: nil)
                var gIdx = glyphRange.location
                let gEnd = NSMaxRange(glyphRange)
                while gIdx < gEnd {
                    var lineGlyphRange = NSRange(location: 0, length: 0)
                    _ = layoutManager.lineFragmentRect(forGlyphAt: gIdx, effectiveRange: &lineGlyphRange)
                    let subRange = NSIntersectionRange(glyphRange, lineGlyphRange)
                    if subRange.length > 0 {
                        let raw = layoutManager.boundingRect(forGlyphRange: subRange, in: textContainer)
                        if raw.width > 0 {
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
                    gIdx = max(gIdx + 1, NSMaxRange(lineGlyphRange))
                }
            }
        }

        if !wikiLinkItems.isEmpty {
            for item in wikiLinkItems {
                if item.fullRange.location > visEnd { break }
                guard NSMaxRange(item.fullRange) >= visStart, NSMaxRange(item.fullRange) <= totalLength else { continue }
                if isCharacterFolded(item.fullRange.location) { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: item.fullRange, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { raw, _ in
                    let pill = NSRect(
                        x: origin.x + raw.minX - 2,
                        y: origin.y + raw.minY + 1,
                        width: raw.width + 4,
                        height: max(14, raw.height - 4)
                    )
                    let path = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
                    Theme.accentSoft.withAlphaComponent(0.65).setFill()
                    path.fill()
                    Theme.accent.withAlphaComponent(0.28).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }

        if !inNoteFindRanges.isEmpty {
            var lo = 0
            var hi = inNoteFindRanges.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if NSMaxRange(inNoteFindRanges[mid]) < visStart {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            for idx in lo..<inNoteFindRanges.count {
                let matchRange = inNoteFindRanges[idx]
                if matchRange.location > visEnd { break }
                guard NSMaxRange(matchRange) <= totalLength else { continue }
                if isCharacterFolded(matchRange.location) { continue }
                let isActiveMatch = (idx == activeInNoteFindIndex)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: matchRange, actualCharacterRange: nil)
                let raw = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let highlightRect = NSRect(
                    x: origin.x + raw.minX - 2,
                    y: origin.y + raw.minY + 1,
                    width: max(4, raw.width + 4),
                    height: max(14, raw.height - 4)
                )
                let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
                if isActiveMatch {
                    Theme.accent.withAlphaComponent(0.28).setFill()
                    path.fill()
                    Theme.accent.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                } else {
                    Theme.accentSoft.withAlphaComponent(0.85).setFill()
                    path.fill()
                    Theme.accent.withAlphaComponent(0.35).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }

        for range in blockquoteRanges {
            if range.location > visEnd { break }
            guard NSMaxRange(range) >= visStart, NSMaxRange(range) <= totalLength else { continue }
            if isCharacterFolded(range.location) { continue }
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

        foldHitTargets.removeAll(keepingCapacity: true)
        if !headingGutterItems.isEmpty {
            let unfoldedBadgeAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.monoFont(9.5, weight: .semibold),
                .foregroundColor: Theme.subtle.withAlphaComponent(0.85)
            ]
            let foldedBadgeAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.monoFont(9.5, weight: .bold),
                .foregroundColor: Theme.accent
            ]
            let pillTextAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.monoFont(9.5, weight: .semibold),
                .foregroundColor: Theme.muted
            ]
            var hLo = 0
            var hHi = headingGutterItems.count
            while hLo < hHi {
                let mid = (hLo + hHi) >> 1
                if NSMaxRange(headingGutterItems[mid].range) < visStart {
                    hLo = mid + 1
                } else {
                    hHi = mid
                }
            }
            for hIdx in hLo..<headingGutterItems.count {
                let item = headingGutterItems[hIdx]
                if item.range.location > visEnd { break }
                guard NSMaxRange(item.range) <= totalLength else { continue }
                if isCharacterFolded(item.range.location) { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
                let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let activeFold = foldedSection(forHeadingAt: item.range.location)
                let isFolded = activeFold != nil
                if origin.x >= 56 {
                    let badgeLabel = "\(isFolded ? "▸" : "▾") \(item.label)" as NSString
                    let attrs = isFolded ? foldedBadgeAttrs : unfoldedBadgeAttrs
                    let badgeSize = badgeLabel.size(withAttributes: attrs)
                    let x = origin.x - 18 - badgeSize.width
                    let y = origin.y + box.minY + max(0, (box.height - badgeSize.height) / 2) - 2
                    let badgeRect = NSRect(x: x - 4, y: y - 2, width: badgeSize.width + 8, height: badgeSize.height + 4)
                    if isFolded {
                        let bgPath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
                        Theme.accentSoft.setFill()
                        bgPath.fill()
                    }
                    badgeLabel.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                    foldHitTargets.append(FoldHitTarget(rect: badgeRect, headingLocation: item.range.location))
                }
                if let activeFold {
                    let lastGlyph = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
                    let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                    let pillLabel = "⋯ \(activeFold.hiddenLineCount) \(activeFold.hiddenLineCount == 1 ? "line" : "lines")" as NSString
                    let pillSize = pillLabel.size(withAttributes: pillTextAttrs)
                    let pillX = min(origin.x + columnWidth - pillSize.width - 14, origin.x + usedRect.maxX + 10)
                    let pillY = origin.y + box.minY + max(0, (box.height - pillSize.height) / 2) - 2
                    let pillRect = NSRect(x: pillX, y: pillY - 1.5, width: pillSize.width + 12, height: pillSize.height + 3)
                    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 5, yRadius: 5)
                    Theme.elevated.setFill()
                    pillPath.fill()
                    Theme.border.setStroke()
                    pillPath.lineWidth = 1
                    pillPath.stroke()
                    pillLabel.draw(at: NSPoint(x: pillRect.minX + 6, y: pillY), withAttributes: pillTextAttrs)
                    foldHitTargets.append(FoldHitTarget(rect: pillRect, headingLocation: item.range.location))
                }
                if item.level == 1 && !isFolded {
                    Theme.marginLine.setFill()
                    NSRect(x: origin.x + 4, y: origin.y + box.maxY + 4, width: max(0, columnWidth - 8), height: 1).fill()
                }
            }
        }

        if !bulletItems.isEmpty {
            for item in bulletItems {
                if item.lineRange.location > visEnd { break }
                guard NSMaxRange(item.lineRange) >= visStart,
                      NSMaxRange(item.lineRange) <= totalLength,
                      NSMaxRange(item.markerRange) <= totalLength else { continue }
                if isCharacterFolded(item.lineRange.location) { continue }
                if item.level > 0 {
                    let lineGlyphs = layoutManager.glyphRange(forCharacterRange: item.lineRange, actualCharacterRange: nil)
                    let lineBox = layoutManager.boundingRect(forGlyphRange: lineGlyphs, in: textContainer)
                    Theme.border.withAlphaComponent(0.48).setFill()
                    for lvl in 1...min(item.level, 6) {
                        let guideX = round(origin.x + CGFloat(lvl - 1) * 22.0 + 3.5)
                        let guideRect = NSRect(
                            x: guideX,
                            y: origin.y + lineBox.minY + 1,
                            width: 1.0,
                            height: max(8, lineBox.height - 4)
                        )
                        guideRect.fill()
                    }
                }
                if item.kind == .unordered {
                    let markerGlyphs = layoutManager.glyphRange(forCharacterRange: item.markerRange, actualCharacterRange: nil)
                    let markerBox = layoutManager.boundingRect(forGlyphRange: markerGlyphs, in: textContainer)
                    let cx = origin.x + markerBox.midX
                    let cy = origin.y + markerBox.minY + round(markerBox.height * 0.44)
                    let color = CaptureEditor.bulletColor(forLevel: item.level)
                    color.setFill()
                    color.setStroke()
                    switch item.level % 4 {
                    case 0:
                        let r: CGFloat = 3.0
                        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
                    case 1:
                        let r: CGFloat = 2.8
                        let ring = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                        ring.lineWidth = 1.5
                        ring.stroke()
                    case 2:
                        let r: CGFloat = 3.2
                        let diamond = NSBezierPath()
                        diamond.move(to: NSPoint(x: cx, y: cy - r))
                        diamond.line(to: NSPoint(x: cx + r, y: cy))
                        diamond.line(to: NSPoint(x: cx, y: cy + r))
                        diamond.line(to: NSPoint(x: cx - r, y: cy))
                        diamond.close()
                        diamond.fill()
                    default:
                        let bar = NSBezierPath(
                            roundedRect: NSRect(x: cx - 3.25, y: cy - 1.0, width: 6.5, height: 2.0),
                            xRadius: 1.0,
                            yRadius: 1.0
                        )
                        bar.fill()
                    }
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

    override var shouldDrawInsertionPoint: Bool {
        false
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        // Suppress AppKit's insertion-point layout queries and timer; caretLayer manages the caret.
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
        if !foldedSections.isEmpty {
            unfoldSectionsIntersecting(affectedCharRange)
        }
        let oldLen = ns.length
        let repNS = (replacementString ?? "") as NSString
        let repLen = repNS.length
        let delta = repLen - affectedCharRange.length
        let isLargeEdit = affectedCharRange.length > 4096 || repLen > 4096
        lastEditWasLarge = isLargeEdit
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
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "x":
                guard isEditable else { return false }
                cut(self)
                return true
            case "c":
                copy(self)
                return true
            case "v":
                guard isEditable else { return false }
                paste(self)
                return true
            case "a":
                selectAll(self)
                return true
            case "z":
                guard isEditable, let um = undoManager, um.canUndo else { return false }
                um.undo()
                return true
            case "b":
                guard isEditable else { return false }
                toggleBold(self)
                return true
            case "i":
                guard isEditable else { return false }
                toggleItalic(self)
                return true
            case "u":
                guard isEditable else { return false }
                toggleUnderline(self)
                return true
            case "e", "`":
                guard isEditable else { return false }
                toggleInlineCode(self)
                return true
            case "k":
                guard isEditable else { return false }
                insertMarkdownLink(self)
                return true
            case "]":
                guard isEditable else { return false }
                indentListLevel(self)
                return true
            case "[":
                guard isEditable else { return false }
                outdentListLevel(self)
                return true
            case "p":
                onQuickSwitcher?()
                return true
            case "f":
                onShowInNoteFind?()
                return true
            case "g":
                onFindNextInNote?()
                return true
            case "o":
                if let link = wikiLinkAtCursor() {
                    onOpenWikiLink?(link)
                    return true
                }
                onQuickSwitcher?()
                return true
            case "\r", "\n":
                if let link = wikiLinkAtCursor() {
                    onOpenWikiLink?(link)
                    return true
                }
            default:
                break
            }
        } else if flags == [.command, .shift] {
            switch key {
            case "z":
                guard isEditable, let um = undoManager, um.canRedo else { return false }
                um.redo()
                return true
            case "x", "s":
                guard isEditable else { return false }
                toggleStrikethrough(self)
                return true
            case "c":
                guard isEditable else { return false }
                toggleCodeBlock(self)
                return true
            case ".", ">":
                guard isEditable else { return false }
                toggleBlockquote(self)
                return true
            case "8", "*":
                guard isEditable else { return false }
                toggleBulletList(self)
                return true
            case "7", "&":
                guard isEditable else { return false }
                toggleNumberedList(self)
                return true
            case "l":
                guard isEditable else { return false }
                toggleChecklist(self)
                return true
            case "f":
                onQuickSwitcher?()
                return true
            case "g":
                onFindPreviousInNote?()
                return true
            case "\r", "\n":
                if let link = wikiLinkAtCursor() {
                    onOpenWikiLinkInNewWindow?(link)
                    return true
                }
            default:
                break
            }
        } else if flags == [.command, .option] {
            switch key {
            case "c":
                guard isEditable else { return false }
                toggleCodeBlock(self)
                return true
            case "1":
                guard isEditable else { return false }
                toggleHeading1(self)
                return true
            case "2":
                guard isEditable else { return false }
                toggleHeading2(self)
                return true
            case "3":
                guard isEditable else { return false }
                toggleHeading3(self)
                return true
            case "q":
                guard isEditable else { return false }
                toggleBlockquote(self)
                return true
            case "l":
                guard isEditable else { return false }
                toggleBulletList(self)
                return true
            case "t":
                guard isEditable else { return false }
                toggleChecklist(self)
                return true
            case "[":
                toggleHeadingFoldAtCursor(self)
                return true
            case "\\":
                onToggleOutline?()
                return true
            case "]":
                unfoldHeadingAtCursor(self)
                return true
            case "k":
                guard isEditable else { return false }
                insertWikiLink(self)
                return true
            case "\r", "\n":
                openWikiLinkAtCursor(self)
                return true
            case "o":
                if let link = wikiLinkAtCursor() {
                    onOpenWikiLinkInNewWindow?(link)
                } else {
                    onOpenCurrentNoteInNewWindow?()
                }
                return true
            default:
                break
            }
        } else if flags == [.command, .control] {
            switch key {
            case "c":
                guard isEditable else { return false }
                toggleCodeBlock(self)
                return true
            case "1":
                guard isEditable else { return false }
                toggleHeading1(self)
                return true
            case "2":
                guard isEditable else { return false }
                toggleHeading2(self)
                return true
            case "3":
                guard isEditable else { return false }
                toggleHeading3(self)
                return true
            case "q":
                guard isEditable else { return false }
                toggleBlockquote(self)
                return true
            case "l":
                guard isEditable else { return false }
                toggleBulletList(self)
                return true
            case "t":
                guard isEditable else { return false }
                toggleChecklist(self)
                return true
            case "[":
                cycleOutlineFolding(self)
                return true
            case "]":
                unfoldAllHeadings(self)
                return true
            default:
                break
            }
        } else if flags == .option {
            if (key == "\r" || key == "\n"), let link = wikiLinkAtCursor() {
                onOpenWikiLink?(link)
                return true
            }
        } else if flags == [.command, .option, .shift] {
            if (key == "\r" || key == "\n" || key == "o"), let link = wikiLinkAtCursor() {
                onOpenWikiLinkInNewWindow?(link)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func copy(_ sender: Any?) {
        autoreleasepool {
            let sel = selectedRange()
            guard sel.length > 0, let ns = textStorage?.mutableString, NSMaxRange(sel) <= ns.length else { return }
            let pb = NSPasteboard.general
            let sig = CaptureEditor.sampleSignature(of: ns, range: sel)
            if sel.length > 4096 && pb.changeCount == lastClipboardChangeCount && sel.length == lastClipboardLength && sig == lastClipboardSig {
                return
            }
            let str: String
            if sel.length > 4096 && sel.location == 0 && sel.length == ns.length && sel.length == cachedFullTextLength && sig == cachedFullTextSig {
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
            cancelScrollSpring()
            super.scrollRangeToVisible(range)
        }
    }

    override func selectAll(_ sender: Any?) {
        autoreleasepool {
            super.selectAll(sender)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = foldHitTargets.first(where: { $0.rect.insetBy(dx: -4, dy: -3).contains(pt) }) {
            toggleFold(forHeadingAt: hit.headingLocation)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let link = wikiLink(atPoint: pt) {
            if flags.contains(.option) {
                onOpenWikiLinkInNewWindow?(link)
            } else {
                onOpenWikiLink?(link)
            }
            return
        }
        super.mouseDown(with: event)
    }

    func wikiLink(atPoint pt: NSPoint) -> WikiLink? {
        guard !wikiLinkItems.isEmpty,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              let storage = textStorage else { return nil }
        let totalLength = storage.length
        let origin = textContainerOrigin
        let containerPt = NSPoint(x: pt.x - origin.x, y: pt.y - origin.y)
        for item in wikiLinkItems {
            if isCharacterFolded(item.fullRange.location) { continue }
            guard NSMaxRange(item.fullRange) <= totalLength else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: item.fullRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            var matched = false
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, stop in
                if rect.insetBy(dx: -3, dy: -2).contains(containerPt) {
                    matched = true
                    stop.pointee = true
                }
            }
            if matched {
                return item
            }
        }
        return nil
    }

    override func cancelOperation(_ sender: Any?) {
        if let handler = onWikiAutocompleteCommand, handler(#selector(NSResponder.cancelOperation(_:))) {
            return
        }
        super.cancelOperation(sender)
    }

    override func insertTab(_ sender: Any?) {
        if let handler = onWikiAutocompleteCommand, handler(#selector(NSResponder.insertTab(_:))) {
            return
        }
        if let ns = textStorage?.mutableString {
            let sel = selectedRange()
            if NSMaxRange(sel) <= ns.length {
                if sel.length == 0, headingIndex(atOrEnclosing: sel.location, requireSameLine: true) != nil {
                    toggleHeadingFoldAtCursor(sender)
                    return
                }
                let lineRange = ns.lineRange(for: sel)
                let lineStr = ns.substring(with: lineRange)
                if isEditable, Self.lineStartsWithListMarker(lineStr) {
                    indentListLevel(sender)
                    return
                }
            }
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if let ns = textStorage?.mutableString {
            let sel = selectedRange()
            if NSMaxRange(sel) <= ns.length,
               sel.length == 0,
               headingIndex(atOrEnclosing: sel.location, requireSameLine: true) != nil {
                cycleOutlineFolding(sender)
                return
            }
        }
        if isEditable {
            outdentListLevel(sender)
            return
        }
        super.insertBacktab(sender)
    }

    nonisolated func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        MainActor.assumeIsolated {
            guard !foldedSections.isEmpty, glyphRange.length > 0, let ns = textStorage?.mutableString else { return 0 }
            let totalLen = ns.length
            let firstChar = charIndexes[0]
            let lastChar = charIndexes[glyphRange.length - 1]
            let minChar = min(firstChar, lastChar)
            let maxChar = max(firstChar, lastChar)

            var lo = 0
            var hi = foldedSections.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if NSMaxRange(foldedSections[mid].foldedCharRange) <= minChar {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            guard lo < foldedSections.count,
                  foldedSections[lo].foldedCharRange.location <= maxChar else {
                return 0
            }

            let firstFold = foldedSections[lo].foldedCharRange
            if minChar >= firstFold.location && maxChar < NSMaxRange(firstFold) {
                var mutableProps = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
                for i in 0..<glyphRange.length {
                    let c = charIndexes[i]
                    if c < totalLen && ns.character(at: c) > 0x20 {
                        mutableProps[i] = .controlCharacter
                        break
                    }
                }
                layoutManager.setGlyphs(
                    glyphs,
                    properties: &mutableProps,
                    characterIndexes: charIndexes,
                    font: aFont,
                    forGlyphRange: glyphRange
                )
                return glyphRange.length
            }
            var mutableProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
            var didModify = false
            var cursor = lo
            let count = foldedSections.count
            for i in 0..<glyphRange.length {
                let c = charIndexes[i]
                while cursor < count && NSMaxRange(foldedSections[cursor].foldedCharRange) <= c {
                    cursor += 1
                }
                if cursor < count {
                    let r = foldedSections[cursor].foldedCharRange
                    if c >= r.location && c < NSMaxRange(r) {
                        if c == r.location && c < totalLen && ns.character(at: c) > 0x20 {
                            mutableProps[i] = .controlCharacter
                        } else {
                            mutableProps[i] = .null
                        }
                        didModify = true
                    } else if c < r.location && cursor > lo && isCharacterFolded(c) {
                        mutableProps[i] = .null
                        didModify = true
                    }
                }
            }
            guard didModify else { return 0 }
            layoutManager.setGlyphs(
                glyphs,
                properties: &mutableProps,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
            return glyphRange.length
        }
    }

    func isCharacterFolded(_ charIndex: Int) -> Bool {
        guard !foldedSections.isEmpty else { return false }
        var lo = 0
        var hi = foldedSections.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let r = foldedSections[mid].foldedCharRange
            if charIndex < r.location {
                hi = mid - 1
            } else if charIndex >= NSMaxRange(r) {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    func foldedSection(forHeadingAt headingLocation: Int) -> FoldedSection? {
        guard !foldedSections.isEmpty else { return nil }
        var lo = 0
        var hi = foldedSections.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let loc = foldedSections[mid].headingLocation
            if headingLocation < loc {
                hi = mid - 1
            } else if headingLocation > loc {
                lo = mid + 1
            } else {
                return foldedSections[mid]
            }
        }
        return nil
    }

    private func headingIndex(atOrEnclosing location: Int, requireSameLine: Bool) -> Int? {
        guard !headingGutterItems.isEmpty, let ns = textStorage?.mutableString else { return nil }
        let clamped = min(location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        if let sameLineIdx = headingGutterItems.firstIndex(where: { NSIntersectionRange($0.range, lineRange).length > 0 || $0.range.location == lineRange.location }) {
            return sameLineIdx
        }
        guard !requireSameLine else { return nil }
        return headingGutterItems.lastIndex(where: { $0.range.location <= clamped })
    }

    private func computeFoldedSection(forHeadingIndex idx: Int, bodyOnly: Bool) -> FoldedSection? {
        guard headingGutterItems.indices.contains(idx),
              let ns = textStorage?.mutableString else { return nil }
        let totalLen = ns.length
        let item = headingGutterItems[idx]
        let headingLineRange = ns.lineRange(for: item.range)
        let foldEnd: Int
        if bodyOnly {
            foldEnd = (idx + 1 < headingGutterItems.count) ? headingGutterItems[idx + 1].range.location : totalLen
        } else {
            var nextSameOrHigher: Int?
            for j in (idx + 1)..<headingGutterItems.count {
                if headingGutterItems[j].level <= item.level {
                    nextSameOrHigher = headingGutterItems[j].range.location
                    break
                }
            }
            foldEnd = nextSameOrHigher ?? totalLen
        }
        let foldStart = foldEnd == totalLen ? NSMaxRange(item.range) : NSMaxRange(headingLineRange)
        guard foldEnd > foldStart else { return nil }
        let foldedRange = NSRange(location: foldStart, length: foldEnd - foldStart)
        let sliceStart = min(NSMaxRange(headingLineRange), foldEnd)
        let sliceRange = NSRange(location: sliceStart, length: max(0, foldEnd - sliceStart))
        let lineCount = Self.countFoldedLines(in: ns, range: sliceRange)
        guard lineCount > 0 else { return nil }
        return FoldedSection(
            headingLocation: item.range.location,
            headingRange: item.range,
            headingLevel: item.level,
            foldedCharRange: foldedRange,
            hiddenLineCount: lineCount
        )
    }

    private static func countFoldedLines(in ns: NSString, range: NSRange) -> Int {
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return 0 }
        var effectiveLen = range.length
        if ns.character(at: range.location + effectiveLen - 1) == 0x0A {
            effectiveLen -= 1
        }
        guard effectiveLen > 0 else { return 0 }
        let cfStr = ns as CFString
        let chunkCap = 16384
        let allocSize = min(chunkCap, effectiveLen)
        let buf = UnsafeMutablePointer<UniChar>.allocate(capacity: allocSize)
        defer { buf.deallocate() }
        var lines = 1
        var offset = range.location
        let end = range.location + effectiveLen
        while offset < end {
            let count = min(allocSize, end - offset)
            CFStringGetCharacters(cfStr, CFRange(location: offset, length: count), buf)
            var i = 0
            while i < count {
                if buf[i] == 0x0A {
                    lines &+= 1
                }
                i &+= 1
            }
            offset &+= count
        }
        return lines
    }

    private static func symmetricDifferenceRanges(
        from oldFolds: [FoldedSection],
        to newFolds: [FoldedSection]
    ) -> [NSRange] {
        if oldFolds.isEmpty { return newFolds.map(\.foldedCharRange) }
        if newFolds.isEmpty { return oldFolds.map(\.foldedCharRange) }
        var coords: [Int] = []
        coords.reserveCapacity((oldFolds.count + newFolds.count) * 2)
        for s in oldFolds where s.foldedCharRange.length > 0 {
            coords.append(s.foldedCharRange.location)
            coords.append(NSMaxRange(s.foldedCharRange))
        }
        for s in newFolds where s.foldedCharRange.length > 0 {
            coords.append(s.foldedCharRange.location)
            coords.append(NSMaxRange(s.foldedCharRange))
        }
        guard coords.count >= 2 else { return [] }
        coords.sort()

        var oldIdx = 0
        var newIdx = 0
        var diff: [NSRange] = []
        for i in 0..<(coords.count - 1) {
            let start = coords[i]
            let end = coords[i + 1]
            guard end > start else { continue }
            while oldIdx < oldFolds.count && NSMaxRange(oldFolds[oldIdx].foldedCharRange) <= start {
                oldIdx += 1
            }
            while newIdx < newFolds.count && NSMaxRange(newFolds[newIdx].foldedCharRange) <= start {
                newIdx += 1
            }
            let inOld = oldIdx < oldFolds.count
                && start >= oldFolds[oldIdx].foldedCharRange.location
                && end <= NSMaxRange(oldFolds[oldIdx].foldedCharRange)
            let inNew = newIdx < newFolds.count
                && start >= newFolds[newIdx].foldedCharRange.location
                && end <= NSMaxRange(newFolds[newIdx].foldedCharRange)
            if inOld != inNew {
                if let last = diff.last, NSMaxRange(last) == start {
                    diff[diff.count - 1] = NSRange(location: last.location, length: end - last.location)
                } else {
                    diff.append(NSRange(location: start, length: end - start))
                }
            }
        }
        return diff
    }

    func shiftFoldedSections(from startLocation: Int, by delta: Int) {
        guard delta != 0, !foldedSections.isEmpty else { return }
        for i in foldedSections.indices where foldedSections[i].headingLocation >= startLocation {
            let s = foldedSections[i]
            foldedSections[i] = FoldedSection(
                headingLocation: s.headingLocation + delta,
                headingRange: NSRange(location: s.headingRange.location + delta, length: s.headingRange.length),
                headingLevel: s.headingLevel,
                foldedCharRange: NSRange(location: s.foldedCharRange.location + delta, length: s.foldedCharRange.length),
                hiddenLineCount: s.hiddenLineCount
            )
        }
    }

    func shiftExternalChangeRanges(for editRange: NSRange, delta: Int) {
        guard !externalChangeRanges.isEmpty else { return }
        let editEnd = NSMaxRange(editRange)
        var updated: [NSRange] = []
        updated.reserveCapacity(externalChangeRanges.count)
        for r in externalChangeRanges {
            if NSMaxRange(r) <= editRange.location {
                updated.append(r)
            } else if r.location >= editEnd {
                let nextLoc = max(0, r.location + delta)
                updated.append(NSRange(location: nextLoc, length: r.length))
            }
        }
        externalChangeRanges = updated
    }

    func toggleFold(forHeadingAt headingLocation: Int) {
        guard let idx = headingGutterItems.firstIndex(where: { $0.range.location == headingLocation }) else { return }
        let item = headingGutterItems[idx]
        if let existingIdx = foldedSections.firstIndex(where: { $0.headingLocation == headingLocation }) {
            let removed = foldedSections.remove(at: existingIdx)
            outlineFoldMode = .showAll
            invalidateFoldLayout(forChangedRanges: [removed.foldedCharRange])
            onFoldStatusChange?("Unfolded \(item.label)")
        } else if let section = computeFoldedSection(forHeadingIndex: idx, bodyOnly: false) {
            let oldFolds = foldedSections
            foldedSections.removeAll { NSLocationInRange($0.headingLocation, section.foldedCharRange) }
            foldedSections.append(section)
            foldedSections.sort { $0.headingLocation < $1.headingLocation }
            outlineFoldMode = .showAll
            let sel = selectedRange()
            if NSLocationInRange(sel.location, section.foldedCharRange) || NSIntersectionRange(sel, section.foldedCharRange).length > 0 {
                setSelectedRange(NSRange(location: NSMaxRange(item.range), length: 0))
            }
            let diff = Self.symmetricDifferenceRanges(from: oldFolds, to: foldedSections)
            invalidateFoldLayout(forChangedRanges: diff)
            onFoldStatusChange?("Folded \(item.label) (\(section.hiddenLineCount) \(section.hiddenLineCount == 1 ? "line" : "lines"))")
        }
    }

    @objc func toggleHeadingFoldAtCursor(_ sender: Any?) {
        guard let idx = headingIndex(atOrEnclosing: selectedRange().location, requireSameLine: false) else { return }
        toggleFold(forHeadingAt: headingGutterItems[idx].range.location)
    }

    @objc func unfoldHeadingAtCursor(_ sender: Any?) {
        let loc = selectedRange().location
        if let idx = headingIndex(atOrEnclosing: loc, requireSameLine: false) {
            let hLoc = headingGutterItems[idx].range.location
            if let foldIdx = foldedSections.firstIndex(where: { $0.headingLocation == hLoc }) {
                let removed = foldedSections.remove(at: foldIdx)
                outlineFoldMode = .showAll
                invalidateFoldLayout(forChangedRanges: [removed.foldedCharRange])
                onFoldStatusChange?("Unfolded \(headingGutterItems[idx].label)")
                return
            }
        }
        if let enclosingIdx = foldedSections.firstIndex(where: { NSLocationInRange(loc, $0.foldedCharRange) }) {
            let removed = foldedSections.remove(at: enclosingIdx)
            outlineFoldMode = .showAll
            invalidateFoldLayout(forChangedRanges: [removed.foldedCharRange])
            onFoldStatusChange?("Unfolded section")
        }
    }

    /// Cycles Org-mode global outline visibility: Overview (top-level headings) -> Headings Only (all headings) -> Show All.
    @objc func cycleOutlineFolding(_ sender: Any?) {
        guard !headingGutterItems.isEmpty else { return }
        switch outlineFoldMode {
        case .showAll:
            let minLevel = headingGutterItems.map(\.level).min() ?? 1
            var nextFolds: [FoldedSection] = []
            for idx in headingGutterItems.indices where headingGutterItems[idx].level == minLevel {
                if let section = computeFoldedSection(forHeadingIndex: idx, bodyOnly: false) {
                    nextFolds.append(section)
                }
            }
            let oldFolds = foldedSections
            foldedSections = nextFolds
            outlineFoldMode = nextFolds.isEmpty ? .showAll : .overview
            clampSelectionOutsideFolds()
            invalidateFoldLayout(forChangedRanges: Self.symmetricDifferenceRanges(from: oldFolds, to: nextFolds))
            onFoldStatusChange?(outlineFoldMode == .overview ? "Outline: Overview" : "Outline: Show All")

        case .overview:
            var nextFolds: [FoldedSection] = []
            for idx in headingGutterItems.indices {
                if let section = computeFoldedSection(forHeadingIndex: idx, bodyOnly: true) {
                    nextFolds.append(section)
                }
            }
            let oldFolds = foldedSections
            foldedSections = nextFolds
            outlineFoldMode = .headingsOnly
            clampSelectionOutsideFolds()
            invalidateFoldLayout(forChangedRanges: Self.symmetricDifferenceRanges(from: oldFolds, to: nextFolds))
            onFoldStatusChange?("Outline: Headings Only")

        case .headingsOnly:
            unfoldAllHeadings(sender)
        }
    }

    @objc func unfoldAllHeadings(_ sender: Any?) {
        guard !foldedSections.isEmpty || outlineFoldMode != .showAll else { return }
        let oldFolds = foldedSections
        foldedSections.removeAll()
        outlineFoldMode = .showAll
        invalidateFoldLayout(forChangedRanges: oldFolds.map(\.foldedCharRange))
        onFoldStatusChange?("Outline: Show All")
    }

    func clearAllFolds() {
        guard !foldedSections.isEmpty || outlineFoldMode != .showAll else { return }
        let oldFolds = foldedSections
        foldedSections.removeAll()
        outlineFoldMode = .showAll
        invalidateFoldLayout(forChangedRanges: oldFolds.map(\.foldedCharRange))
    }

    func unfoldSectionsIntersecting(_ editRange: NSRange) {
        var removedRanges: [NSRange] = []
        let beforeCount = foldedSections.count
        foldedSections.removeAll { section in
            let expanded = NSRange(
                location: section.headingRange.location,
                length: NSMaxRange(section.foldedCharRange) - section.headingRange.location
            )
            let hits = NSIntersectionRange(expanded, editRange).length > 0
                || NSLocationInRange(editRange.location, expanded)
                || editRange.location == NSMaxRange(expanded)
            if hits {
                removedRanges.append(section.foldedCharRange)
            }
            return hits
        }
        if foldedSections.count != beforeCount {
            outlineFoldMode = .showAll
            invalidateFoldLayout(forChangedRanges: removedRanges)
        }
    }

    private func clampSelectionOutsideFolds() {
        let sel = selectedRange()
        if let enclosing = foldedSections.first(where: { NSLocationInRange(sel.location, $0.foldedCharRange) }) {
            setSelectedRange(NSRange(location: NSMaxRange(enclosing.headingRange), length: 0))
        }
    }

    private func invalidateFoldLayout(forChangedRanges ranges: [NSRange]) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let totalLen = storage.length
        guard totalLen > 0, !ranges.isEmpty else { return }
        var minStart = totalLen
        var maxEnd = 0
        for r in ranges {
            let loc = min(max(0, r.location), totalLen)
            let end = min(totalLen, NSMaxRange(r))
            guard end > loc else { continue }
            if loc < minStart { minStart = loc }
            if end > maxEnd { maxEnd = end }
        }
        guard maxEnd > minStart else { return }
        let span = NSRange(location: minStart, length: maxEnd - minStart)
        lm.invalidateGlyphs(forCharacterRange: span, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: span, actualCharacterRange: nil)
        if totalLen <= 65_536 {
            lm.ensureLayout(for: tc)
        } else if let scrollView = enclosingScrollView {
            let clipView = scrollView.contentView
            if !foldedSections.isEmpty {
                let selLoc = min(selectedRange().location, totalLen)
                let selGlyphs = lm.glyphRange(forCharacterRange: NSRange(location: selLoc, length: 0), actualCharacterRange: nil)
                let selRect = lm.boundingRect(forGlyphRange: selGlyphs, in: tc)
                let selY = selRect.minY + textContainerOrigin.y
                if selY < clipView.bounds.minY || selY > clipView.bounds.maxY {
                    let targetY = max(0, selY - clipView.bounds.height * 0.25)
                    clipView.scroll(to: NSPoint(x: 0, y: targetY))
                    scrollView.reflectScrolledClipView(clipView)
                }
            }
            lm.ensureLayout(forBoundingRect: clipView.bounds, in: tc)
        } else {
            lm.ensureLayout(for: tc)
        }
        minimumOverscrollHeight = 0
        updateCaret(animated: false)
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
    }

    private static let listLineCheckRegex = try! NSRegularExpression(pattern: "(?m)^[ \\t]*(?:[-*+]|\\d+\\.)(?:\\s+\\[[ xX]\\])? ")

    private static func lineStartsWithListMarker(_ text: String) -> Bool {
        let ns = text as NSString
        return listLineCheckRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    @objc func indentListLevel(_ sender: Any?) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        guard NSMaxRange(sel) <= ns.length else { return }
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        let content = hasTrailingNewline ? String(block.dropLast()) : block
        let lines = content.components(separatedBy: "\n")
        let transformed = lines.map { "  " + $0 }
        let joined = transformed.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let nextSel: NSRange
        if sel.length == 0 {
            nextSel = NSRange(location: max(lineRange.location, sel.location + 2), length: 0)
        } else {
            nextSel = NSRange(location: lineRange.location, length: max(0, (joined as NSString).length - (hasTrailingNewline ? 1 : 0)))
        }
        applyUndoableReplacement(in: lineRange, with: joined, selectedRangeAfter: nextSel)
    }

    @objc func outdentListLevel(_ sender: Any?) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        guard NSMaxRange(sel) <= ns.length else { return }
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        let content = hasTrailingNewline ? String(block.dropLast()) : block
        let lines = content.components(separatedBy: "\n")
        var removedOnFirstLine = 0
        var transformed: [String] = []
        for (idx, line) in lines.enumerated() {
            if line.hasPrefix("  ") {
                if idx == 0 { removedOnFirstLine = 2 }
                transformed.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("\t") || line.hasPrefix(" ") {
                if idx == 0 { removedOnFirstLine = 1 }
                transformed.append(String(line.dropFirst(1)))
            } else {
                transformed.append(line)
            }
        }
        let joined = transformed.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        guard joined != block else { return }
        let nextSel: NSRange
        if sel.length == 0 {
            nextSel = NSRange(location: max(lineRange.location, sel.location - removedOnFirstLine), length: 0)
        } else {
            nextSel = NSRange(location: lineRange.location, length: max(0, (joined as NSString).length - (hasTrailingNewline ? 1 : 0)))
        }
        applyUndoableReplacement(in: lineRange, with: joined, selectedRangeAfter: nextSel)
    }

    @objc func toggleBold(_ sender: Any?) {
        toggleInlineWrapper(open: "**", close: "**")
    }

    @objc func toggleItalic(_ sender: Any?) {
        toggleInlineWrapper(open: "*", close: "*")
    }

    @objc func toggleUnderline(_ sender: Any?) {
        toggleInlineWrapper(open: "__", close: "__", alternateOpen: "<u>", alternateClose: "</u>")
    }

    @objc func toggleStrikethrough(_ sender: Any?) {
        toggleInlineWrapper(open: "~~", close: "~~")
    }

    @objc func toggleInlineCode(_ sender: Any?) {
        toggleInlineWrapper(open: "`", close: "`")
    }

    @objc func toggleCodeBlock(_ sender: Any?) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        let totalLen = ns.length
        guard NSMaxRange(sel) <= totalLen else { return }

        // 1. If selection itself is a fenced code block (```...\nbody\n```), unwrap it
        if sel.length >= 7 {
            let selected = ns.substring(with: sel)
            if selected.hasPrefix("```") && selected.hasSuffix("```") {
                var inner = String(selected.dropFirst(3).dropLast(3))
                if let firstNL = inner.firstIndex(of: "\n") {
                    inner = String(inner[inner.index(after: firstNL)...])
                }
                if inner.hasSuffix("\n") {
                    inner.removeLast()
                }
                let innerLen = (inner as NSString).length
                applyUndoableReplacement(
                    in: sel,
                    with: inner,
                    selectedRangeAfter: NSRange(location: sel.location, length: innerLen)
                )
                return
            }
        }

        // 2. If cursor/selection is inside an existing FencedBlock, unwrap that block
        if let enclosing = fencedBlocks.first(where: { sel.location >= $0.fullRange.location && NSMaxRange(sel) <= NSMaxRange($0.fullRange) }),
           NSMaxRange(enclosing.fullRange) <= totalLen,
           NSMaxRange(enclosing.bodyRange) <= totalLen {
            var body = ns.substring(with: enclosing.bodyRange)
            if body.hasSuffix("\n") {
                body.removeLast()
            }
            let bodyLen = (body as NSString).length
            applyUndoableReplacement(
                in: enclosing.fullRange,
                with: body,
                selectedRangeAfter: NSRange(location: enclosing.fullRange.location, length: bodyLen)
            )
            return
        }

        // 3. Wrap selection (or empty caret) in a fenced code block
        let atLineStart = sel.location == 0 || ns.character(at: sel.location - 1) == 10
        let leading = atLineStart ? "" : "\n"
        let leadingLen = (leading as NSString).length
        if sel.length == 0 {
            let atLineEnd = sel.location == totalLen || ns.character(at: sel.location) == 10
            let trailing = atLineEnd ? "" : "\n"
            let replacement = "\(leading)```\n\n```\(trailing)"
            let caretLoc = sel.location + leadingLen + 4
            applyUndoableReplacement(
                in: sel,
                with: replacement,
                selectedRangeAfter: NSRange(location: caretLoc, length: 0)
            )
        } else {
            let rawSelected = ns.substring(with: sel)
            let hadTrailingNewline = rawSelected.hasSuffix("\n")
            let body = hadTrailingNewline ? String(rawSelected.dropLast()) : rawSelected
            let bodyLen = (body as NSString).length
            let atLineEnd = NSMaxRange(sel) == totalLen || ns.character(at: NSMaxRange(sel)) == 10
            let trailing = hadTrailingNewline ? "\n" : (atLineEnd ? "" : "\n")
            let replacement = "\(leading)```\n\(body)\n```\(trailing)"
            let bodyStart = sel.location + leadingLen + 4
            applyUndoableReplacement(
                in: sel,
                with: replacement,
                selectedRangeAfter: NSRange(location: bodyStart, length: bodyLen)
            )
        }
    }

    @objc func insertMarkdownLink(_ sender: Any?) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        guard NSMaxRange(sel) <= ns.length else { return }

        if sel.length > 0 {
            let selected = ns.substring(with: sel)
            if selected.hasPrefix("["), let mid = selected.range(of: "]("), selected.hasSuffix(")") {
                let label = String(selected[selected.index(after: selected.startIndex)..<mid.lowerBound])
                let labelLen = (label as NSString).length
                applyUndoableReplacement(
                    in: sel,
                    with: label,
                    selectedRangeAfter: NSRange(location: sel.location, length: labelLen)
                )
                return
            }
            if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
                let replacement = "[](\(selected))"
                applyUndoableReplacement(
                    in: sel,
                    with: replacement,
                    selectedRangeAfter: NSRange(location: sel.location + 1, length: 0)
                )
                return
            }
            let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let urlStr = (clip.hasPrefix("http://") || clip.hasPrefix("https://")) ? clip : "https://"
            let urlLen = (urlStr as NSString).length
            let replacement = "[\(selected)](\(urlStr))"
            let urlStart = sel.location + 1 + sel.length + 2
            applyUndoableReplacement(
                in: sel,
                with: replacement,
                selectedRangeAfter: NSRange(location: urlStart, length: urlLen)
            )
        } else {
            let replacement = "[](https://)"
            applyUndoableReplacement(
                in: sel,
                with: replacement,
                selectedRangeAfter: NSRange(location: sel.location + 1, length: 0)
            )
        }
    }

    @objc func insertWikiLink(_ sender: Any?) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        guard NSMaxRange(sel) <= ns.length else { return }
        if sel.length > 0 {
            toggleInlineWrapper(open: "[[", close: "]]")
        } else {
            onInsertWikiLinkShortcut?()
        }
    }

    func wikiLinkAtCursor() -> WikiLink? {
        guard let ns = textStorage?.mutableString else { return nil }
        let sel = selectedRange()
        if let item = wikiLinkItems.first(where: { sel.location >= $0.fullRange.location && sel.location <= NSMaxRange($0.fullRange) }) {
            return item
        }
        return Vault.wikiLink(inNSString: ns, at: sel.location, includeTrailingEdge: true)
    }

    @objc func openWikiLinkAtCursor(_ sender: Any?) {
        if let link = wikiLinkAtCursor() {
            onOpenWikiLink?(link)
        }
    }

    @objc func openWikiLinkInNewWindowAtCursor(_ sender: Any?) {
        if let link = wikiLinkAtCursor() {
            onOpenWikiLinkInNewWindow?(link)
        }
    }

    @objc func toggleHeading1(_ sender: Any?) { toggleHeading(level: 1) }
    @objc func toggleHeading2(_ sender: Any?) { toggleHeading(level: 2) }
    @objc func toggleHeading3(_ sender: Any?) { toggleHeading(level: 3) }

    @objc func toggleBlockquote(_ sender: Any?) {
        toggleLinePrefix("> ")
    }

    @objc func toggleBulletList(_ sender: Any?) {
        toggleLinePrefix("- ")
    }

    @objc func toggleChecklist(_ sender: Any?) {
        toggleLinePrefix("- [ ] ", alternatePrefixes: ["- [x] ", "- [X] "])
    }

    @objc func toggleNumberedList(_ sender: Any?) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        guard NSMaxRange(sel) <= ns.length else { return }
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        let content = hasTrailingNewline ? String(block.dropLast()) : block
        let lines = content.components(separatedBy: "\n")
        let numberedRegex = try! NSRegularExpression(pattern: "^\\d+\\. ")
        let allNumbered = lines.filter { !$0.isEmpty }.allSatisfy { line in
            numberedRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        } && !lines.allSatisfy(\.isEmpty)

        var transformed: [String] = []
        var number = 1
        for line in lines {
            if allNumbered {
                let lineNS = line as NSString
                if let m = numberedRegex.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) {
                    transformed.append(lineNS.substring(from: NSMaxRange(m.range)))
                } else {
                    transformed.append(line)
                }
            } else {
                transformed.append("\(number). \(line)")
                number += 1
            }
        }
        let joined = transformed.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let joinedLen = (joined as NSString).length
        let nextSel = sel.length == 0
            ? NSRange(location: lineRange.location + joinedLen - (hasTrailingNewline ? 1 : 0), length: 0)
            : NSRange(location: lineRange.location, length: joinedLen - (hasTrailingNewline ? 1 : 0))
        applyUndoableReplacement(in: lineRange, with: joined, selectedRangeAfter: nextSel)
    }

    private func toggleHeading(level: Int) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        guard NSMaxRange(sel) <= ns.length else { return }
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        let content = hasTrailingNewline ? String(block.dropLast()) : block
        let lines = content.components(separatedBy: "\n")
        let targetPrefix = String(repeating: "#", count: level) + " "
        let headingPrefixRegex = try! NSRegularExpression(pattern: "^#{1,6} ")
        let allHaveTarget = lines.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix(targetPrefix) } && !lines.allSatisfy(\.isEmpty)

        let transformed = lines.map { line -> String in
            if allHaveTarget {
                return line.hasPrefix(targetPrefix) ? String(line.dropFirst(targetPrefix.count)) : line
            }
            let lineNS = line as NSString
            if let match = headingPrefixRegex.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) {
                return targetPrefix + lineNS.substring(from: NSMaxRange(match.range))
            }
            return targetPrefix + line
        }
        let joined = transformed.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let joinedLen = (joined as NSString).length
        let nextSel = sel.length == 0
            ? NSRange(location: lineRange.location + joinedLen - (hasTrailingNewline ? 1 : 0), length: 0)
            : NSRange(location: lineRange.location, length: joinedLen - (hasTrailingNewline ? 1 : 0))
        applyUndoableReplacement(in: lineRange, with: joined, selectedRangeAfter: nextSel)
    }

    private func toggleLinePrefix(_ prefix: String, alternatePrefixes: [String] = []) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        guard NSMaxRange(sel) <= ns.length else { return }
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        let content = hasTrailingNewline ? String(block.dropLast()) : block
        let lines = content.components(separatedBy: "\n")
        let allPrefixes = [prefix] + alternatePrefixes
        let allHavePrefix = lines.filter { !$0.isEmpty }.allSatisfy { line in
            allPrefixes.contains(where: { line.hasPrefix($0) })
        } && !lines.allSatisfy(\.isEmpty)

        let transformed = lines.map { line -> String in
            if allHavePrefix {
                if let matched = allPrefixes.first(where: { line.hasPrefix($0) }) {
                    return String(line.dropFirst(matched.count))
                }
                return line
            }
            return prefix + line
        }
        let joined = transformed.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let joinedLen = (joined as NSString).length
        let nextSel = sel.length == 0
            ? NSRange(location: lineRange.location + joinedLen - (hasTrailingNewline ? 1 : 0), length: 0)
            : NSRange(location: lineRange.location, length: joinedLen - (hasTrailingNewline ? 1 : 0))
        applyUndoableReplacement(in: lineRange, with: joined, selectedRangeAfter: nextSel)
    }

    private func toggleInlineWrapper(
        open: String,
        close: String,
        alternateOpen: String? = nil,
        alternateClose: String? = nil
    ) {
        guard isEditable, let ns = textStorage?.mutableString else { return }
        let sel = selectedRange()
        let totalLen = ns.length
        guard NSMaxRange(sel) <= totalLen else { return }

        // Check alternate wrapper first (e.g. <u>...</u> for underline)
        if let altOpen = alternateOpen, let altClose = alternateClose {
            let altOpenLen = (altOpen as NSString).length
            let altCloseLen = (altClose as NSString).length
            if sel.location >= altOpenLen, NSMaxRange(sel) + altCloseLen <= totalLen {
                let before = ns.substring(with: NSRange(location: sel.location - altOpenLen, length: altOpenLen))
                let after = ns.substring(with: NSRange(location: NSMaxRange(sel), length: altCloseLen))
                if before.caseInsensitiveCompare(altOpen) == .orderedSame && after.caseInsensitiveCompare(altClose) == .orderedSame {
                    let inner = ns.substring(with: sel)
                    let fullRange = NSRange(location: sel.location - altOpenLen, length: sel.length + altOpenLen + altCloseLen)
                    applyUndoableReplacement(
                        in: fullRange,
                        with: inner,
                        selectedRangeAfter: NSRange(location: sel.location - altOpenLen, length: sel.length)
                    )
                    return
                }
            }
            if sel.length >= altOpenLen + altCloseLen {
                let selected = ns.substring(with: sel)
                if selected.lowercased().hasPrefix(altOpen.lowercased()) && selected.lowercased().hasSuffix(altClose.lowercased()) {
                    let innerRange = NSRange(location: sel.location + altOpenLen, length: sel.length - altOpenLen - altCloseLen)
                    let inner = ns.substring(with: innerRange)
                    applyUndoableReplacement(
                        in: sel,
                        with: inner,
                        selectedRangeAfter: NSRange(location: sel.location, length: innerRange.length)
                    )
                    return
                }
            }
        }

        let openLen = (open as NSString).length
        let closeLen = (close as NSString).length

        // Helper for single '*' vs '**' bold disambiguation
        func canUnwrapSurroundingSingleStar() -> Bool {
            guard open == "*" && close == "*" else { return true }
            var beforeStars = 0
            var idx = sel.location
            while idx > 0 && beforeStars < 3 && ns.character(at: idx - 1) == 0x2A {
                beforeStars += 1
                idx -= 1
            }
            var afterStars = 0
            idx = NSMaxRange(sel)
            while idx < totalLen && afterStars < 3 && ns.character(at: idx) == 0x2A {
                afterStars += 1
                idx += 1
            }
            return !(beforeStars == 2 && afterStars == 2)
        }

        func canUnwrapSelectedSingleStar(_ selected: String) -> Bool {
            guard open == "*" && close == "*" else { return true }
            let leadStars = selected.prefix(while: { $0 == "*" }).count
            let trailStars = selected.reversed().prefix(while: { $0 == "*" }).count
            return !(leadStars == 2 && trailStars == 2)
        }

        // 1. Check if characters immediately outside the selection match open/close
        if sel.location >= openLen, NSMaxRange(sel) + closeLen <= totalLen {
            let before = ns.substring(with: NSRange(location: sel.location - openLen, length: openLen))
            let after = ns.substring(with: NSRange(location: NSMaxRange(sel), length: closeLen))
            if before == open && after == close && canUnwrapSurroundingSingleStar() {
                let inner = ns.substring(with: sel)
                let outerRange = NSRange(location: sel.location - openLen, length: sel.length + openLen + closeLen)
                applyUndoableReplacement(
                    in: outerRange,
                    with: inner,
                    selectedRangeAfter: NSRange(location: sel.location - openLen, length: sel.length)
                )
                return
            }
        }

        // 2. Check if the selected range itself includes the open/close markers
        if sel.length >= openLen + closeLen {
            let selected = ns.substring(with: sel)
            if selected.hasPrefix(open) && selected.hasSuffix(close) && canUnwrapSelectedSingleStar(selected) {
                let innerRange = NSRange(location: sel.location + openLen, length: sel.length - openLen - closeLen)
                let inner = ns.substring(with: innerRange)
                applyUndoableReplacement(
                    in: sel,
                    with: inner,
                    selectedRangeAfter: NSRange(location: sel.location, length: innerRange.length)
                )
                return
            }
        }

        // 3. Wrap the selection (or insert empty pair with caret inside)
        let selected = sel.length > 0 ? ns.substring(with: sel) : ""
        let replacement = open + selected + close
        applyUndoableReplacement(
            in: sel,
            with: replacement,
            selectedRangeAfter: NSRange(location: sel.location + openLen, length: sel.length)
        )
    }

    func applyUndoableReplacement(in range: NSRange, with replacement: String, selectedRangeAfter: NSRange? = nil) {
        autoreleasepool {
            guard let storage = textStorage else { return }
            breakUndoCoalescing()
            let previousSelection = selectedRange()
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
            } else if safeRange.length > 4096 && safeRange.location == 0 && safeRange.length == ns.length && safeRange.length == cachedFullTextLength && CaptureEditor.sampleSignature(of: ns, range: safeRange) == cachedFullTextSig {
                previousString = cachedFullText
            } else {
                previousString = ns.substring(with: safeRange)
            }

            let repLen = (replacement as NSString).length
            let inverseRange = NSRange(location: safeRange.location, length: repLen)
            let restoreSelection = selectedRangeAfter != nil ? previousSelection : nil
            editorUndoManager.registerUndo(withTarget: self) { target in
                target.applyUndoableReplacement(in: inverseRange, with: previousString, selectedRangeAfter: restoreSelection)
            }

            let clipView = enclosingScrollView?.contentView
            let savedOriginY = clipView?.bounds.origin.y

            editorUndoManager.disableUndoRegistration()
            storage.beginEditing()
            storage.replaceCharacters(in: safeRange, with: replacement)
            storage.endEditing()
            editorUndoManager.enableUndoRegistration()

            if let clipView, let savedOriginY, abs(clipView.bounds.origin.y - savedOriginY) > 0.01 {
                clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: savedOriginY))
            }

            let nextSelection = selectedRangeAfter ?? NSRange(location: safeRange.location + repLen, length: 0)
            setSelectedRange(nextSelection)
            didChangeText()
        }
    }

    override func didChangeText() {
        let wasLarge = lastEditWasLarge
        lastEditWasLarge = false
        isEditingText = false
        super.didChangeText()
        if wasLarge, (textStorage?.length ?? 0) > 65_536 {
            cancelCaretBlink()
            caretLayer.isHidden = true
            hasCaretOrigin = false
        } else {
            updateCaret(animated: true)
            if !wasLarge && !suppressCaretUpdates {
                ensureCaretVisible(animated: true, useTypewriterStep: true)
            }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !suppressCaretUpdates && !isEditingText else { return }
        updateCaret(animated: !stillSelectingFlag)
    }

    override func doCommand(by selector: Selector) {
        if let handler = onWikiAutocompleteCommand, handler(selector) {
            return
        }
        super.doCommand(by: selector)
        guard !suppressCaretUpdates && !isEditingText,
              window?.firstResponder === self else { return }
        if !foldedSections.isEmpty, selectedRange().length == 0 {
            let loc = selectedRange().location
            if let fold = foldedSections.first(where: { NSLocationInRange(loc, $0.foldedCharRange) }) {
                let movingBackward = selector == #selector(NSResponder.moveUp(_:))
                    || selector == #selector(NSResponder.moveBackward(_:))
                    || selector == #selector(NSResponder.moveLeft(_:))
                    || selector == #selector(NSResponder.moveWordBackward(_:))
                    || selector == #selector(NSResponder.moveWordLeft(_:))
                let targetLoc = movingBackward
                    ? NSMaxRange(fold.headingRange)
                    : min(textStorage?.length ?? 0, NSMaxRange(fold.foldedCharRange))
                setSelectedRange(NSRange(location: targetLoc, length: 0))
            }
        }
        if selectedRange().length == 0 {
            ensureCaretVisible(animated: true, useTypewriterStep: true)
        }
    }

    func resetCaretPosition() {
        hasCaretOrigin = false
        minimumOverscrollHeight = 0
        foldedSections.removeAll()
        externalChangeRanges.removeAll()
        outlineFoldMode = .showAll
        foldHitTargets.removeAll()
        caretLayer.removeAllAnimations()
        cancelScrollSpring()
    }

    func cancelScrollSpring() {
        scrollSpringWorkItem?.cancel()
        scrollSpringWorkItem = nil
        scrollSpringTargetY = nil
        scrollSpringVelocityY = 0
    }

    func completeScrollSpringImmediately() {
        guard let targetY = scrollSpringTargetY,
              let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        cancelScrollSpring()
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Ensures the active insertion caret stays inside the visible viewport comfort zone.
    /// When the caret moves below the fold, scrolls up with a ~30% viewport typewriter breathing margin below the cursor.
    func ensureCaretVisible(animated: Bool, useTypewriterStep: Bool = true) {
        guard !suppressCaretUpdates,
              let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let visHeight = clipView.bounds.height
        guard visHeight > 60 else { return }

        let caret: NSRect
        if !caretLayer.isHidden && hasCaretOrigin && caretLayer.bounds.height > 0 {
            caret = NSRect(
                x: caretLayer.position.x - caretLayer.bounds.width * 0.5,
                y: caretLayer.position.y - caretLayer.bounds.height * 0.5,
                width: caretLayer.bounds.width,
                height: caretLayer.bounds.height
            )
        } else {
            caret = currentCaretRect()
        }
        guard caret.height > 0 else { return }

        let currentY = scrollSpringTargetY ?? clipView.bounds.origin.y
        let topMargin = max(20.0, min(44.0, round(visHeight * 0.08)))
        let bottomMargin = max(28.0, min(56.0, round(visHeight * 0.12)))
        let topBound = currentY + topMargin
        let bottomBound = currentY + visHeight - bottomMargin

        if caret.minY >= topBound && caret.maxY <= bottomBound {
            return
        }

        let desiredY: CGFloat
        if caret.maxY > bottomBound {
            if !useTypewriterStep && caret.maxY <= currentY + visHeight {
                return
            }
            let breathingRoom = useTypewriterStep ? round(visHeight * 0.30) : bottomMargin
            desiredY = max(0, round(caret.maxY - (visHeight - breathingRoom)))
            let requiredDocHeight = desiredY + visHeight
            if requiredDocHeight > minimumOverscrollHeight {
                minimumOverscrollHeight = requiredDocHeight
            }
            if frame.height < requiredDocHeight {
                setFrameSize(NSSize(width: frame.width, height: requiredDocHeight))
            }
        } else {
            if !useTypewriterStep && caret.minY >= currentY {
                return
            }
            let topRoom = useTypewriterStep ? round(visHeight * 0.20) : topMargin
            desiredY = max(0, round(caret.minY - topRoom))
        }

        smoothScrollClipView(to: desiredY, animated: animated)
    }

    private func smoothScrollClipView(to targetY: CGFloat, animated: Bool) {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let visHeight = clipView.bounds.height
        let currentY = clipView.bounds.origin.y
        guard abs(targetY - currentY) > 0.5 else {
            cancelScrollSpring()
            return
        }

        let canAnimate = animated
            && (window?.isVisible ?? false)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && abs(targetY - currentY) <= visHeight * 1.5

        guard canAnimate else {
            cancelScrollSpring()
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
            return
        }

        scrollSpringTargetY = targetY
        stepScrollSpring()
    }

    private func stepScrollSpring() {
        scrollSpringWorkItem?.cancel()
        scrollSpringWorkItem = nil
        guard let targetY = scrollSpringTargetY,
              let scrollView = enclosingScrollView else {
            cancelScrollSpring()
            return
        }
        let clipView = scrollView.contentView
        let currentY = clipView.bounds.origin.y
        let displacement = currentY - targetY

        // Analytical critically-damped spring (response = 0.14s, dampingRatio = 1.0) at dt = 1/120s
        let dt: CGFloat = 1.0 / 120.0
        let response: CGFloat = 0.14
        let omega: CGFloat = (2.0 * .pi) / response
        let expTerm = exp(-omega * dt)
        let v0 = scrollSpringVelocityY
        let c1 = displacement
        let c2 = v0 + omega * c1
        let nextDisp = (c1 + c2 * dt) * expTerm
        let nextVel = (c2 - omega * (c1 + c2 * dt)) * expTerm
        let nextY = targetY + nextDisp

        if abs(nextDisp) < 0.5 && abs(nextVel) < 8.0 {
            cancelScrollSpring()
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
            return
        }

        scrollSpringVelocityY = nextVel
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: round(nextY * 2) / 2))
        scrollView.reflectScrolledClipView(clipView)

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.stepScrollSpring()
            }
        }
        scrollSpringWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dt, execute: work)
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
            let lineRange = ns.lineRange(for: NSRange(location: ensureLoc, length: 0))
            if len <= 100_000 && lineRange.location > 0 {
                let startLoc = lineRange.location - 1
                let fullEnsure = ns.lineRange(for: NSRange(location: startLoc, length: NSMaxRange(lineRange) - startLoc))
                lm.ensureLayout(forCharacterRange: fullEnsure)
            } else {
                lm.ensureLayout(forCharacterRange: lineRange)
            }
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

@MainActor final class WikiLinkCompletionView: NSView {
    struct Item: Equatable {
        let title: String
        let subtitle: String
        let isCreateNew: Bool
        let noteURL: URL?
    }

    var items: [Item] = [] {
        didSet {
            if selectedIndex >= items.count {
                selectedIndex = max(0, items.count - 1)
            }
            ensureSelectionVisible()
            needsDisplay = true
        }
    }
    var selectedIndex: Int = 0 {
        didSet {
            ensureSelectionVisible()
            needsDisplay = true
        }
    }
    var onSelectIndex: ((Int) -> Void)?
    private var scrollOffsetRow: Int = 0
    private var tracking: NSTrackingArea?
    static let maxVisibleRows = 6
    static let headerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 40
    static let bottomPad: CGFloat = 6
    static let defaultWidth: CGFloat = 328

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = 1000
        setAccessibilityLabel("Note link suggestions")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func preferredSize() -> NSSize {
        let count = min(max(1, items.count), Self.maxVisibleRows)
        return NSSize(
            width: Self.defaultWidth,
            height: Self.headerHeight + CGFloat(count) * Self.rowHeight + Self.bottomPad
        )
    }

    private func ensureSelectionVisible() {
        guard !items.isEmpty else {
            scrollOffsetRow = 0
            return
        }
        let clamped = min(max(0, selectedIndex), items.count - 1)
        if clamped < scrollOffsetRow {
            scrollOffsetRow = clamped
        } else if clamped >= scrollOffsetRow + Self.maxVisibleRows {
            scrollOffsetRow = clamped - Self.maxVisibleRows + 1
        }
        let maxOffset = max(0, items.count - Self.maxVisibleRows)
        scrollOffsetRow = min(scrollOffsetRow, maxOffset)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func rowIndex(at pt: NSPoint) -> Int? {
        guard pt.y >= Self.headerHeight, pt.x >= 0, pt.x <= bounds.width else { return nil }
        let visibleRow = Int(floor((pt.y - Self.headerHeight) / Self.rowHeight))
        let idx = scrollOffsetRow + visibleRow
        guard visibleRow >= 0, visibleRow < Self.maxVisibleRows, items.indices.contains(idx) else { return nil }
        return idx
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let idx = rowIndex(at: pt), idx != selectedIndex {
            selectedIndex = idx
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let idx = rowIndex(at: pt) {
            selectedIndex = idx
            onSelectIndex?(idx)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let cardRect = bounds.insetBy(dx: 1, dy: 1)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowOffset = NSSize(width: 0, height: 3)
        shadow.shadowBlurRadius = 10
        shadow.set()
        Theme.elevated.setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        cardPath.addClip()

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.monoFont(9.5, weight: .semibold),
            .foregroundColor: Theme.subtle
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.monoFont(9.0, weight: .regular),
            .foregroundColor: Theme.subtle
        ]
        ("LINK TO NOTE" as NSString).draw(at: NSPoint(x: 12, y: 6), withAttributes: headerAttrs)
        let hint = "↑↓ · ↵ · esc" as NSString
        let hintSize = hint.size(withAttributes: hintAttrs)
        hint.draw(at: NSPoint(x: bounds.width - hintSize.width - 12, y: 6), withAttributes: hintAttrs)

        Theme.border.withAlphaComponent(0.75).setFill()
        NSRect(x: 8, y: Self.headerHeight - 1, width: max(0, bounds.width - 16), height: 1).fill()

        let pStyle = NSMutableParagraphStyle()
        pStyle.lineBreakMode = .byTruncatingTail

        let visibleEnd = min(items.count, scrollOffsetRow + Self.maxVisibleRows)
        for idx in scrollOffsetRow..<visibleEnd {
            let item = items[idx]
            let visIdx = idx - scrollOffsetRow
            let rowY = Self.headerHeight + CGFloat(visIdx) * Self.rowHeight
            let rowRect = NSRect(x: 5, y: rowY + 2, width: bounds.width - 10, height: Self.rowHeight - 4)
            let isSelected = (idx == selectedIndex)

            if isSelected {
                let selPath = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6)
                Theme.selectionFill.setFill()
                selPath.fill()
                let barRect = NSRect(x: rowRect.minX + 2, y: rowRect.minY + 6, width: 2.5, height: rowRect.height - 12)
                Theme.accent.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
            }

            let titleText = item.isCreateNew ? "Create “\(item.title)”" : item.title
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .medium),
                .foregroundColor: item.isCreateNew ? Theme.accent : (isSelected ? Theme.headingInk : Theme.ink),
                .paragraphStyle: pStyle
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: Theme.muted,
                .paragraphStyle: pStyle
            ]
            let textX: CGFloat = 14
            let textW = max(10, rowRect.width - 20)
            (titleText as NSString).draw(in: NSRect(x: textX, y: rowY + 4, width: textW, height: 17), withAttributes: titleAttrs)
            (item.subtitle as NSString).draw(in: NSRect(x: textX, y: rowY + 21, width: textW, height: 15), withAttributes: subAttrs)
        }

        NSGraphicsContext.restoreGraphicsState()

        Theme.border.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()
    }
}

@MainActor final class InNoteFindBar: NSView, NSSearchFieldDelegate {
    let searchBar = CozySearchBar()
    let countLabel = Theme.label("", size: 10, color: Theme.subtle)
    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    var query: String {
        get { searchBar.field.stringValue }
        set { searchBar.field.stringValue = newValue }
    }

    private let surface = PaperSurface(cornerRadius: 10, color: Theme.elevated, bordered: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = 950
        setAccessibilityLabel("Find in note")

        surface.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowBlurRadius = 10
        surface.shadow = shadow

        searchBar.field.placeholderString = "Find in note…"
        searchBar.field.delegate = self
        searchBar.field.sendsWholeSearchString = false
        searchBar.field.sendsSearchStringImmediately = true
        searchBar.field.setAccessibilityLabel("Find in note text")
        searchBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        searchBar.heightAnchor.constraint(equalToConstant: 28).isActive = true

        countLabel.font = Theme.monoFont(10, weight: .semibold)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let prevBtn = QuietButton(symbol: "chevron.up", target: self, action: #selector(prevTapped))
        prevBtn.toolTip = "Previous match (⇧⌘G)"
        prevBtn.setAccessibilityLabel("Previous match")

        let nextBtn = QuietButton(symbol: "chevron.down", target: self, action: #selector(nextTapped))
        nextBtn.toolTip = "Next match (⌘G)"
        nextBtn.setAccessibilityLabel("Next match")

        let closeBtn = QuietButton(symbol: "xmark", target: self, action: #selector(closeTapped))
        closeBtn.toolTip = "Close find bar (Esc)"
        closeBtn.setAccessibilityLabel("Close find bar")

        let row = Theme.stack([searchBar, countLabel, prevBtn, nextBtn, closeBtn], spacing: 4)
        Theme.fill(row, in: surface, inset: 6)
        Theme.fill(surface, in: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusField() {
        window?.makeFirstResponder(searchBar.field)
        searchBar.field.selectText(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(searchBar.field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            if key == "f" {
                focusField()
                return true
            }
            if key == "g" {
                onNext?()
                return true
            }
        } else if flags == [.command, .shift], key == "g" {
            onPrevious?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func prevTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func closeTapped() { onClose?() }
}

@MainActor final class DocumentOutlineView: NSView {
    struct Item: Equatable {
        let headingLocation: Int
        let range: NSRange
        let level: Int
        let label: String
        let title: String
        let isFolded: Bool
        let hiddenLineCount: Int
    }

    static let railWidth: CGFloat = 228
    static let rowHeight: CGFloat = 30

    var items: [Item] = [] {
        didSet {
            if items != oldValue {
                reloadCanvas()
            }
        }
    }
    var activeIndex: Int = -1 {
        didSet {
            if activeIndex != oldValue {
                canvas.activeIndex = activeIndex
                scrollActiveRowIntoView()
            }
        }
    }
    var foldMode: MarkdownTextView.OutlineFoldMode = .showAll {
        didSet {
            if foldMode != oldValue {
                updateFoldButtonTitle()
            }
        }
    }
    var onSelectItem: ((Int) -> Void)?
    var onToggleFoldItem: ((Int) -> Void)?
    var onCycleFoldMode: (() -> Void)?
    var onClose: (() -> Void)?

    private let headerTitle = Theme.label("OUTLINE", size: 10, color: Theme.subtle)
    private var foldButton: QuietButton!
    private var closeButton: QuietButton!
    private let headerDivider = HairlineView()
    private let scroll = NSScrollView()
    private let canvas = OutlineCanvasView(frame: .zero)
    private let emptyLabel = Theme.label("No headings yet\nUse # to structure sections", size: 11.5, color: Theme.muted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Document Outline")
        headerTitle.font = Theme.monoFont(10, weight: .semibold)

        foldButton = QuietButton(title: "Fold", target: self, action: #selector(cycleFoldTapped))
        foldButton.font = Theme.monoFont(9.5, weight: .semibold)
        foldButton.toolTip = "Cycle section folding (Overview / Headings / All)"

        closeButton = QuietButton(symbol: "xmark", target: self, action: #selector(closeTapped))
        closeButton.toolTip = "Hide Outline (⇧⌘O)"
        closeButton.setAccessibilityLabel("Hide Outline")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = Theme.stack([headerTitle, spacer, foldButton, closeButton], spacing: 4)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = CozyScroller()
        scroll.documentView = canvas

        canvas.onSelectRow = { [weak self] idx in self?.onSelectItem?(idx) }
        canvas.onToggleFoldRow = { [weak self] idx in self?.onToggleFoldItem?(idx) }

        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3

        for v in [headerRow, headerDivider, scroll, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerRow.heightAnchor.constraint(equalToConstant: 26),
            headerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerDivider.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        reloadCanvas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        updateCanvasFrame()
    }

    private func updateFoldButtonTitle() {
        switch foldMode {
        case .showAll: foldButton.title = "Fold"
        case .overview: foldButton.title = "Overview"
        case .headingsOnly: foldButton.title = "Headings"
        }
    }

    private func reloadCanvas() {
        emptyLabel.isHidden = !items.isEmpty
        foldButton.isEnabled = !items.isEmpty
        canvas.items = items
        canvas.activeIndex = activeIndex
        updateCanvasFrame()
    }

    private func updateCanvasFrame() {
        let w = max(160, scroll.contentSize.width)
        let h = max(scroll.contentSize.height, CGFloat(items.count) * Self.rowHeight + 12)
        if abs(canvas.frame.width - w) > 0.5 || abs(canvas.frame.height - h) > 0.5 {
            canvas.frame = NSRect(x: 0, y: 0, width: w, height: h)
        }
        canvas.needsDisplay = true
    }

    private func scrollActiveRowIntoView() {
        guard items.indices.contains(activeIndex) else { return }
        let rowRect = canvas.rectForRow(activeIndex).insetBy(dx: 0, dy: -8)
        canvas.scrollToVisible(rowRect)
    }

    @objc private func cycleFoldTapped() { onCycleFoldMode?() }
    @objc private func closeTapped() { onClose?() }

    @MainActor private final class OutlineCanvasView: NSView {
        var items: [Item] = [] { didSet { needsDisplay = true } }
        var activeIndex: Int = -1 { didSet { needsDisplay = true } }
        var hoveredIndex: Int = -1 { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }
        var onSelectRow: ((Int) -> Void)?
        var onToggleFoldRow: ((Int) -> Void)?
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        func rectForRow(_ index: Int) -> NSRect {
            NSRect(
                x: 6,
                y: 6 + CGFloat(index) * DocumentOutlineView.rowHeight,
                width: max(0, bounds.width - 12),
                height: DocumentOutlineView.rowHeight - 2
            )
        }

        private func rowIndex(at pt: NSPoint) -> Int? {
            let idx = Int(floor((pt.y - 6) / DocumentOutlineView.rowHeight))
            guard items.indices.contains(idx) else { return nil }
            return idx
        }

        override func mouseMoved(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            hoveredIndex = rowIndex(at: pt) ?? -1
        }

        override func mouseExited(with event: NSEvent) {
            hoveredIndex = -1
        }

        override func mouseDown(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            guard let idx = rowIndex(at: pt) else { return }
            let minLevel = items.map(\.level).min() ?? 1
            let indent = CGFloat(min(items[idx].level - minLevel, 5)) * 11
            let chevronMaxX = 12 + indent + 20
            if event.modifierFlags.contains(.option) || pt.x <= chevronMaxX {
                onToggleFoldRow?(idx)
            } else {
                onSelectRow?(idx)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard !items.isEmpty else { return }
            let minLevel = items.map(\.level).min() ?? 1
            for (idx, item) in items.enumerated() {
                let rowRect = rectForRow(idx)
                guard rowRect.intersects(dirtyRect) else { continue }
                let isActive = (idx == activeIndex)
                let isHover = (idx == hoveredIndex)
                if isActive {
                    let bg = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6)
                    Theme.accentSoft.withAlphaComponent(0.85).setFill()
                    bg.fill()
                    let bar = NSBezierPath(
                        roundedRect: NSRect(x: rowRect.minX + 2, y: rowRect.minY + 5, width: 2.5, height: max(8, rowRect.height - 10)),
                        xRadius: 1.25,
                        yRadius: 1.25
                    )
                    Theme.accent.setFill()
                    bar.fill()
                } else if isHover {
                    let bg = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6)
                    Theme.elevated.withAlphaComponent(0.75).setFill()
                    bg.fill()
                }

                let indent = CGFloat(min(item.level - minLevel, 5)) * 11
                var cursorX = rowRect.minX + 8 + indent
                let chevron = (item.isFolded ? "▸" : "▾") as NSString
                let chevronAttrs: [NSAttributedString.Key: Any] = [
                    .font: Theme.monoFont(9.5, weight: .bold),
                    .foregroundColor: item.isFolded ? Theme.accent : Theme.subtle
                ]
                let chevronSize = chevron.size(withAttributes: chevronAttrs)
                chevron.draw(
                    at: NSPoint(x: cursorX, y: rowRect.minY + (rowRect.height - chevronSize.height) / 2),
                    withAttributes: chevronAttrs
                )
                cursorX += 11

                let badge = item.label as NSString
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: Theme.monoFont(9, weight: .semibold),
                    .foregroundColor: isActive ? Theme.accent : Theme.subtle
                ]
                let badgeSize = badge.size(withAttributes: badgeAttrs)
                badge.draw(
                    at: NSPoint(x: cursorX, y: rowRect.minY + (rowRect.height - badgeSize.height) / 2),
                    withAttributes: badgeAttrs
                )
                cursorX += badgeSize.width + 6

                var rightLimit = rowRect.maxX - 8
                if item.isFolded && item.hiddenLineCount > 0 {
                    let pillStr = "⋯\(item.hiddenLineCount)" as NSString
                    let pillAttrs: [NSAttributedString.Key: Any] = [
                        .font: Theme.monoFont(9, weight: .semibold),
                        .foregroundColor: Theme.muted
                    ]
                    let pillSize = pillStr.size(withAttributes: pillAttrs)
                    let pillRect = NSRect(
                        x: rightLimit - pillSize.width - 8,
                        y: rowRect.minY + (rowRect.height - pillSize.height) / 2 - 1,
                        width: pillSize.width + 8,
                        height: pillSize.height + 2
                    )
                    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
                    Theme.elevated.setFill()
                    pillPath.fill()
                    pillStr.draw(at: NSPoint(x: pillRect.minX + 4, y: pillRect.minY + 1), withAttributes: pillAttrs)
                    rightLimit = pillRect.minX - 6
                }

                let titleWidth = max(20, rightLimit - cursorX)
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineBreakMode = .byTruncatingTail
                let titleFont = NSFont.systemFont(
                    ofSize: item.level == 1 ? 12.5 : 12.0,
                    weight: isActive || item.level == 1 ? .semibold : .regular
                )
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: titleFont,
                    .foregroundColor: isActive ? Theme.headingInk : Theme.ink,
                    .paragraphStyle: pStyle
                ]
                let displayTitle = (item.title.isEmpty ? "Untitled section" : item.title) as NSString
                let titleHeight = ceil(titleFont.ascender - titleFont.descender) + 2
                displayTitle.draw(
                    in: NSRect(
                        x: cursorX,
                        y: rowRect.minY + (rowRect.height - titleHeight) / 2,
                        width: titleWidth,
                        height: titleHeight
                    ),
                    withAttributes: titleAttrs
                )
            }
        }
    }
}

@MainActor final class CaptureEditor: NSView, NSTextViewDelegate {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    let textView = MarkdownTextView()
    let status = Theme.label("", size: 11, color: Theme.muted)
    let wordCount = Theme.label("", size: 10.5, color: Theme.subtle)
    var onChange: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onRemoveLinkedAttachment: ((LinkedAttachment) -> Void)?
    var onHorizontalInsetChange: ((CGFloat) -> Void)?
    var onOpenWikiLink: ((WikiLink) -> Void)?
    var onOpenWikiLinkInNewWindow: ((WikiLink) -> Void)?
    var onOpenCurrentNoteInNewWindow: (() -> Void)?
    var onQuickSwitcher: (() -> Void)?
    var onOutlineVisibilityChange: ((Bool) -> Void)?
    var noteRecordsProvider: (() -> [NoteRecord])?
    var currentNoteURLProvider: (() -> URL?)?
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
    private var attachmentHeight: NSLayoutConstraint?
    private var attachmentBottom: NSLayoutConstraint?
    private var footerLeading: NSLayoutConstraint?
    private var footerTrailing: NSLayoutConstraint?
    private var previews: [URL: NSImage] = [:]
    private var temporaryFiles: [URL] = []
    private var isFormatting = false
    private var lastCursorLine = NSRange(location: NSNotFound, length: 0)
    private let wikiCompletionView = WikiLinkCompletionView(frame: .zero)
    let inNoteFindBar = InNoteFindBar(frame: .zero)
    let outlineView = DocumentOutlineView(frame: .zero)
    private let outlineDivider = HairlineView()
    private var scrollTrailingToEditorConstraint: NSLayoutConstraint?
    private var scrollTrailingToOutlineConstraint: NSLayoutConstraint?
    private(set) var isOutlineVisible = false
    var outlineItems: [DocumentOutlineView.Item] { outlineView.items }
    var activeOutlineIndex: Int { outlineView.activeIndex }
    var isInNoteFindVisible: Bool { !inNoteFindBar.isHidden }
    var inNoteFindQuery: String {
        get { inNoteFindBar.query }
        set {
            inNoteFindBar.query = newValue
            updateInNoteFindMatches(scrollToMatch: true)
        }
    }
    var inNoteFindMatchCount: Int { textView.inNoteFindRanges.count }
    var activeInNoteFindMatchIndex: Int { textView.activeInNoteFindIndex }
    private var activeWikiReplacementRange: NSRange?
    private var activeWikiOpenLocation: Int?
    private var dismissedWikiOpenLocation: Int?
    private var cachedAutocompleteNotes: [NoteRecord]?
    var isWikiAutocompleteVisible: Bool {
        !wikiCompletionView.isHidden && !wikiCompletionView.items.isEmpty
    }
    var wikiCompletionItems: [WikiLinkCompletionView.Item] {
        wikiCompletionView.items
    }
    var selectedWikiCompletionIndex: Int {
        wikiCompletionView.selectedIndex
    }
    private var cachedWordCount = 0
    private var lastFullCountLength = -1
    private var lastFullCountSampleHash = 0
    private var lastFullCountWords = 0
    private let heading = try! NSRegularExpression(pattern: "(?m)^(#{1,6}) (.+)$")
    private let blockquote = try! NSRegularExpression(pattern: "(?m)^(>+) (.*)$")
    private let listMarker = try! NSRegularExpression(pattern: "(?m)^(([ \\t]*)([-*+]|\\d+\\.)(?:\\s+(\\[[ xX]\\]))?) (.*)$")
    private let bold = try! NSRegularExpression(pattern: "\\*\\*([^\\*\\n]+)\\*\\*")
    private let italic = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^\\*\\n]+)\\*(?!\\*)")
    private let underline = try! NSRegularExpression(pattern: "__([^_\\n]+)__")
    private let htmlUnderline = try! NSRegularExpression(pattern: "(?i)<u>([^<\\n]+)</u>")
    private let strikethrough = try! NSRegularExpression(pattern: "~~([^~\\n]+)~~")
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
        textView.layoutManager?.delegate = textView
        textView.registerForDraggedTypes([.fileURL])
        textView.onFiles = { [weak self] in self?.addAttachments($0) }
        textView.onClipboardImage = { [weak self] in self?.addClipboardImage($0) }
        textView.onFocusChange = { [weak self] in self?.handleFocusChange() }
        textView.onFoldStatusChange = { [weak self] msg in
            self?.status.stringValue = msg
            self?.refreshOutline()
        }
        textView.onOpenWikiLink = { [weak self] link in self?.onOpenWikiLink?(link) }
        textView.onOpenWikiLinkInNewWindow = { [weak self] link in self?.onOpenWikiLinkInNewWindow?(link) }
        textView.onOpenCurrentNoteInNewWindow = { [weak self] in self?.onOpenCurrentNoteInNewWindow?() }
        textView.onInsertWikiLinkShortcut = { [weak self] in self?.handleInsertWikiLinkShortcut() }
        textView.onQuickSwitcher = { [weak self] in self?.onQuickSwitcher?() }
        textView.onShowInNoteFind = { [weak self] in self?.showInNoteFind() }
        textView.onFindNextInNote = { [weak self] in self?.findNextInNote() }
        textView.onFindPreviousInNote = { [weak self] in self?.findPreviousInNote() }
        textView.onToggleOutline = { [weak self] in self?.toggleOutline() }
        inNoteFindBar.isHidden = true
        inNoteFindBar.onQueryChange = { [weak self] _ in self?.updateInNoteFindMatches(scrollToMatch: true) }
        inNoteFindBar.onNext = { [weak self] in self?.findNextInNote() }
        inNoteFindBar.onPrevious = { [weak self] in self?.findPreviousInNote() }
        inNoteFindBar.onClose = { [weak self] in self?.hideInNoteFind() }
        outlineView.isHidden = true
        outlineDivider.isHidden = true
        outlineView.onSelectItem = { [weak self] idx in self?.jumpToHeading(at: idx) }
        outlineView.onToggleFoldItem = { [weak self] idx in self?.toggleFoldForOutlineItem(at: idx) }
        outlineView.onCycleFoldMode = { [weak self] in
            self?.textView.cycleOutlineFolding(nil)
            self?.refreshOutline()
        }
        outlineView.onClose = { [weak self] in self?.setOutlineVisible(false) }
        textView.onWikiAutocompleteCommand = { [weak self] selector in
            self?.handleWikiAutocompleteCommand(selector) ?? false
        }
        wikiCompletionView.isHidden = true
        wikiCompletionView.onSelectIndex = { [weak self] idx in
            self?.commitWikiAutocomplete(at: idx)
        }
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

        for view in [scroll, outlineDivider, outlineView, attachmentScroll, footerRule, footer, inNoteFindBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(wikiCompletionView)
        let attachLead = attachmentScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36)
        let attachTrail = attachmentScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36)
        let footLead = footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36)
        let footTrail = footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36)
        let attachHeight = attachmentScroll.heightAnchor.constraint(equalToConstant: 0)
        let attachBottom = attachmentScroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: 0)
        let scrollTrailEditor = scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        let scrollTrailOutline = scroll.trailingAnchor.constraint(equalTo: outlineDivider.leadingAnchor)
        attachmentLeading = attachLead
        attachmentTrailing = attachTrail
        attachmentHeight = attachHeight
        attachmentBottom = attachBottom
        footerLeading = footLead
        footerTrailing = footTrail
        scrollTrailingToEditorConstraint = scrollTrailEditor
        scrollTrailingToOutlineConstraint = scrollTrailOutline

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollTrailEditor,
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: attachmentScroll.topAnchor, constant: -4),
            outlineDivider.topAnchor.constraint(equalTo: topAnchor),
            outlineDivider.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            outlineDivider.widthAnchor.constraint(equalToConstant: 1),
            outlineDivider.trailingAnchor.constraint(equalTo: outlineView.leadingAnchor),
            outlineView.topAnchor.constraint(equalTo: topAnchor),
            outlineView.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            outlineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            outlineView.widthAnchor.constraint(equalToConstant: DocumentOutlineView.railWidth),
            attachLead,
            attachTrail,
            attachHeight,
            attachBottom,
            footerRule.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footLead,
            footTrail,
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            inNoteFindBar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            inNoteFindBar.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -24),
            inNoteFindBar.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor),
            inNoteFindBar.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            inNoteFindBar.heightAnchor.constraint(equalToConstant: 40),
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
            if isWikiAutocompleteVisible {
                positionWikiCompletionView()
            }
        }
    }

    var nsText: NSString {
        textView.textStorage?.mutableString ?? ("" as NSString)
    }

    func cacheFullText(_ value: String) {
        let ns = value as NSString
        textView.cachedFullText = value
        textView.cachedFullTextLength = ns.length
        textView.cachedFullTextSig = Self.sampleSignature(of: ns)
    }

    var text: String {
        get {
            let ns = nsText
            let len = ns.length
            if len > 4096 && len == textView.cachedFullTextLength && Self.sampleSignature(of: ns) == textView.cachedFullTextSig {
                return textView.cachedFullText
            }
            return textView.string
        }
        set {
            autoreleasepool {
                let previousSelection = textView.selectedRange()
                textView.suppressCaretUpdates = true
                textView.resetCaretPosition()
                textView.pendingEdit = nil
                hideWikiAutocomplete()
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
                    if NSMaxRange(previousSelection) > newLen {
                        textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
                    }
                    textView.undoManager?.disableUndoRegistration()
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newValue)
                    applyFullMarkdownAttributes(to: storage, cursor: NSRange(location: clampedLocation, length: 0), scanHint: scan)
                    storage.endEditing()
                    textView.undoManager?.enableUndoRegistration()
                } else {
                    textView.string = newValue
                }
                applyEditorChromeAttributes()
                isFormatting = false
                textView.undoManager?.removeAllActions()
                textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
                let ns = nsText
                lastCursorLine = ns.length > 0 ? ns.lineRange(for: NSRange(location: min(clampedLocation, ns.length), length: 0)) : NSRange(location: 0, length: 0)
                textView.suppressCaretUpdates = false
                textView.updateCaret(animated: false)
                textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
                if isInNoteFindVisible {
                    updateInNoteFindMatches(scrollToMatch: false)
                }
                if isOutlineVisible {
                    refreshOutline()
                }
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
        hideWikiAutocomplete()
        hideInNoteFind()
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
            if let edit {
                textView.shiftExternalChangeRanges(for: edit.affectedRange, delta: edit.delta)
            }
            if let edit, !edit.requiresFullFormat {
                didTouchAttributes = formatIncrementalEdit(edit)
            } else {
                if let edit, edit.delta != 0 {
                    textView.shiftFoldedSections(from: NSMaxRange(edit.affectedRange), by: edit.delta)
                }
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
            updateWikiAutocompleteAfterEdit(force: false)
            if isInNoteFindVisible {
                updateInNoteFindMatches(scrollToMatch: false)
            }
            if isOutlineVisible {
                refreshOutline()
            }
            onChange?()
        }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isFormatting, !textView.isEditingText, let storage = textView.textStorage else { return }
        let ns = storage.mutableString as NSString
        let sel = textView.selectedRange()
        if isWikiAutocompleteVisible {
            if sel.length > 0 || Vault.activeWikiLinkQuery(inNSString: ns, cursorLocation: sel.location)?.replacementRange.location != activeWikiOpenLocation {
                hideWikiAutocomplete()
            }
        } else if let dismissed = dismissedWikiOpenLocation {
            if Vault.activeWikiLinkQuery(inNSString: ns, cursorLocation: sel.location)?.replacementRange.location != dismissed {
                dismissedWikiOpenLocation = nil
            }
        }
        let clamped = NSRange(location: min(sel.location, ns.length), length: 0)
        let line = ns.lineRange(for: clamped)
        if isOutlineVisible {
            updateActiveOutlineHeading()
        }
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
        let empty = items.isEmpty
        attachmentScroll.isHidden = empty
        attachmentHeight?.constant = empty ? 0 : 62
        attachmentBottom?.constant = empty ? 0 : -6
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
        if textView.window?.firstResponder !== textView {
            hideWikiAutocomplete()
        }
        guard !isFormatting, let storage = textView.textStorage else { return }
        let ns = storage.mutableString as NSString
        let sel = textView.selectedRange()
        let clamped = NSRange(location: min(sel.location, ns.length), length: 0)
        let line = ns.lineRange(for: clamped)
        refreshCursorDependentLines(oldLine: lastCursorLine, newLine: line)
    }

    func invalidateNoteRecordsCache() {
        cachedAutocompleteNotes = nil
    }


    @objc func toggleOutline() {
        setOutlineVisible(!isOutlineVisible)
    }

    func setOutlineVisible(_ visible: Bool) {
        guard isOutlineVisible != visible else { return }
        isOutlineVisible = visible
        outlineView.isHidden = !visible
        outlineDivider.isHidden = !visible
        scrollTrailingToEditorConstraint?.isActive = !visible
        scrollTrailingToOutlineConstraint?.isActive = visible
        if visible {
            refreshOutline()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onOutlineVisibilityChange?(visible)
    }

    func refreshOutline() {
        let ns = nsText
        let totalLen = ns.length
        var items: [DocumentOutlineView.Item] = []
        items.reserveCapacity(textView.headingGutterItems.count)
        for h in textView.headingGutterItems {
            let resolvedTitle: String
            if !h.title.isEmpty {
                resolvedTitle = h.title
            } else if NSMaxRange(h.range) <= totalLen {
                resolvedTitle = Vault.title(from: ns.substring(with: h.range))
            } else {
                resolvedTitle = ""
            }
            let fold = textView.foldedSection(forHeadingAt: h.range.location)
            items.append(DocumentOutlineView.Item(
                headingLocation: h.range.location,
                range: h.range,
                level: h.level,
                label: h.label,
                title: resolvedTitle,
                isFolded: fold != nil,
                hiddenLineCount: fold?.hiddenLineCount ?? 0
            ))
        }
        outlineView.items = items
        outlineView.foldMode = textView.outlineFoldMode
        updateActiveOutlineHeading()
    }

    func updateActiveOutlineHeading() {
        let headings = textView.headingGutterItems
        guard !headings.isEmpty else {
            outlineView.activeIndex = -1
            return
        }
        let cursorLoc = textView.selectedRange().location
        if let idx = headings.lastIndex(where: { $0.range.location <= cursorLoc }) {
            outlineView.activeIndex = idx
        } else {
            outlineView.activeIndex = 0
        }
    }

    func jumpToHeading(at index: Int) {
        guard textView.headingGutterItems.indices.contains(index) else { return }
        let heading = textView.headingGutterItems[index]
        if textView.isCharacterFolded(heading.range.location) {
            textView.unfoldSectionsIntersecting(heading.range)
        }
        let targetLoc = min(nsText.length, NSMaxRange(heading.range))
        textView.setSelectedRange(NSRange(location: targetLoc, length: 0))
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(forCharacterRange: heading.range)
            let glyphRange = lm.glyphRange(forCharacterRange: heading.range, actualCharacterRange: nil)
            let box = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let clipView = scroll.contentView
            let visHeight = clipView.bounds.height
            let targetY = max(0, round(box.minY + textView.textContainerOrigin.y - max(24, visHeight * 0.16)))
            textView.cancelScrollSpring()
            clipView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(clipView)
        }
        textView.updateCaret(animated: false)
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
        refreshOutline()
        focus()
    }

    func toggleFoldForOutlineItem(at index: Int) {
        guard textView.headingGutterItems.indices.contains(index) else { return }
        let heading = textView.headingGutterItems[index]
        textView.toggleFold(forHeadingAt: heading.range.location)
        refreshOutline()
    }

    func clearExternalChangeHighlights() {
        guard !textView.externalChangeRanges.isEmpty else { return }
        textView.externalChangeRanges.removeAll()
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
    }

    @discardableResult
    func applyExternalReload(_ newText: String, previousText: String, highlightChanges: Bool = true) -> Int {
        let clipView = scroll.contentView
        let savedOriginY = clipView.bounds.origin.y
        var anchorChar: Int?
        if savedOriginY > 40, let lm = textView.layoutManager, let tc = textView.textContainer, let storage = textView.textStorage, storage.length > 0 {
            let visRect = clipView.documentVisibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
            let visGlyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visRect, in: tc)
            if visGlyphs.length > 0 {
                anchorChar = lm.characterIndexForGlyph(at: visGlyphs.location)
            }
        }
        let changedRanges = highlightChanges ? Self.changedLineRanges(from: previousText, to: newText) : []
        self.text = newText
        textView.externalChangeRanges = changedRanges
        if let anchorChar, let lm = textView.layoutManager, let tc = textView.textContainer, let storage = textView.textStorage, storage.length > 0 {
            let ns = storage.mutableString as NSString
            let clampedAnchor = min(anchorChar, ns.length - 1)
            let start = max(0, clampedAnchor - 600)
            let end = min(ns.length, clampedAnchor + 2400)
            let windowRange = ns.lineRange(for: NSRange(location: start, length: end - start))
            lm.ensureLayout(forCharacterRange: windowRange)
            let glyphIdx = lm.glyphIndexForCharacter(at: clampedAnchor)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 0), in: tc)
            let targetY = max(0, rect.minY + textView.textContainerOrigin.y)
            clipView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(clipView)
        }
        if isOutlineVisible {
            refreshOutline()
        }
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
        return changedRanges.count
    }

    static func changedLineRanges(from oldText: String, to newText: String) -> [NSRange] {
        guard oldText != newText, !newText.isEmpty else { return [] }
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        var lineRanges: [NSRange] = []
        lineRanges.reserveCapacity(newLines.count)
        var utf16Cursor = 0
        for (idx, line) in newLines.enumerated() {
            let len = (line as NSString).length
            let newlineLen = idx + 1 < newLines.count ? 1 : 0
            lineRanges.append(NSRange(location: utf16Cursor, length: len + newlineLen))
            utf16Cursor += len + newlineLen
        }
        var prefix = 0
        let minCount = min(oldLines.count, newLines.count)
        while prefix < minCount && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var oldSuffix = oldLines.count
        var newSuffix = newLines.count
        while oldSuffix > prefix && newSuffix > prefix && oldLines[oldSuffix - 1] == newLines[newSuffix - 1] {
            oldSuffix -= 1
            newSuffix -= 1
        }
        var changedIndices = IndexSet()
        let middleOldCount = oldSuffix - prefix
        let middleNewCount = newSuffix - prefix
        if middleNewCount > 0 {
            if middleOldCount + middleNewCount <= 4_000 {
                let oldSlice = Array(oldLines[prefix..<oldSuffix])
                let newSlice = Array(newLines[prefix..<newSuffix])
                for change in newSlice.difference(from: oldSlice) {
                    if case let .insert(offset, _, _) = change {
                        changedIndices.insert(prefix + offset)
                    }
                }
            } else {
                changedIndices.insert(integersIn: prefix..<newSuffix)
            }
        }
        var merged: [NSRange] = []
        for idx in changedIndices {
            guard lineRanges.indices.contains(idx) else { continue }
            let r = lineRanges[idx]
            guard r.length > 0 else { continue }
            if let last = merged.last, NSMaxRange(last) == r.location {
                merged[merged.count - 1] = NSRange(location: last.location, length: last.length + r.length)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
    @objc func showInNoteFind() {
        let sel = textView.selectedRange()
        if sel.length > 0 && sel.length <= 80, NSMaxRange(sel) <= nsText.length {
            let sub = nsText.substring(with: sel)
            if !sub.contains("\n") && !sub.contains("\r") {
                inNoteFindBar.query = sub
            }
        }
        inNoteFindBar.isHidden = false
        updateInNoteFindMatches(scrollToMatch: true)
        inNoteFindBar.focusField()
    }

    @objc func hideInNoteFind() {
        guard !inNoteFindBar.isHidden else { return }
        inNoteFindBar.isHidden = true
        textView.inNoteFindRanges = []
        textView.activeInNoteFindIndex = -1
        inNoteFindBar.countLabel.stringValue = ""
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
        window?.makeFirstResponder(textView)
    }

    @objc func findNextInNote() {
        if inNoteFindBar.isHidden {
            showInNoteFind()
            return
        }
        let count = textView.inNoteFindRanges.count
        guard count > 0 else { return }
        textView.activeInNoteFindIndex = (textView.activeInNoteFindIndex + 1) % count
        revealActiveInNoteFindMatch()
    }

    @objc func findPreviousInNote() {
        if inNoteFindBar.isHidden {
            showInNoteFind()
            return
        }
        let count = textView.inNoteFindRanges.count
        guard count > 0 else { return }
        textView.activeInNoteFindIndex = (textView.activeInNoteFindIndex - 1 + count) % count
        revealActiveInNoteFindMatch()
    }

    private func updateInNoteFindMatches(scrollToMatch: Bool) {
        let q = inNoteFindBar.query
        let ns = nsText
        guard !q.isEmpty, ns.length > 0 else {
            textView.inNoteFindRanges = []
            textView.activeInNoteFindIndex = -1
            inNoteFindBar.countLabel.stringValue = ""
            textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
            return
        }
        var ranges: [NSRange] = []
        var searchStart = 0
        let totalLen = ns.length
        let maxMatches = 2000
        while searchStart < totalLen && ranges.count < maxMatches {
            let hit = ns.range(
                of: q,
                options: [.caseInsensitive],
                range: NSRange(location: searchStart, length: totalLen - searchStart)
            )
            guard hit.location != NSNotFound && hit.length > 0 else { break }
            ranges.append(hit)
            searchStart = NSMaxRange(hit)
        }
        textView.inNoteFindRanges = ranges
        guard !ranges.isEmpty else {
            textView.activeInNoteFindIndex = -1
            inNoteFindBar.countLabel.stringValue = "0 MATCHES"
            textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
            return
        }
        let cursorLoc = textView.selectedRange().location
        if let idx = ranges.firstIndex(where: { $0.location >= cursorLoc }) {
            textView.activeInNoteFindIndex = idx
        } else {
            textView.activeInNoteFindIndex = 0
        }
        inNoteFindBar.countLabel.stringValue = "\(textView.activeInNoteFindIndex + 1) OF \(ranges.count)"
        if scrollToMatch {
            revealActiveInNoteFindMatch()
        } else {
            textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
        }
    }

    private func revealActiveInNoteFindMatch() {
        let idx = textView.activeInNoteFindIndex
        guard textView.inNoteFindRanges.indices.contains(idx) else { return }
        let matchRange = textView.inNoteFindRanges[idx]
        if textView.isCharacterFolded(matchRange.location) {
            textView.unfoldSectionsIntersecting(matchRange)
        }
        inNoteFindBar.countLabel.stringValue = "\(idx + 1) OF \(textView.inNoteFindRanges.count)"
        textView.setSelectedRange(matchRange)
        textView.scrollRangeToVisible(matchRange)
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
    }

    func hideWikiAutocomplete() {
        wikiCompletionView.isHidden = true
        wikiCompletionView.items = []
        activeWikiReplacementRange = nil
        activeWikiOpenLocation = nil
        cachedAutocompleteNotes = nil
    }

    private func handleInsertWikiLinkShortcut() {
        let sel = textView.selectedRange()
        let ns = nsText
        if Vault.activeWikiLinkQuery(inNSString: ns, cursorLocation: sel.location) != nil {
            dismissedWikiOpenLocation = nil
            updateWikiAutocompleteAfterEdit(force: true)
        } else {
            dismissedWikiOpenLocation = nil
            textView.applyUndoableReplacement(
                in: sel,
                with: "[[",
                selectedRangeAfter: NSRange(location: sel.location + 2, length: 0)
            )
        }
    }

    private func handleWikiAutocompleteCommand(_ selector: Selector) -> Bool {
        guard isWikiAutocompleteVisible else { return false }
        let count = wikiCompletionView.items.count
        guard count > 0 else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            wikiCompletionView.selectedIndex = (wikiCompletionView.selectedIndex + 1) % count
            return true
        case #selector(NSResponder.moveUp(_:)):
            wikiCompletionView.selectedIndex = (wikiCompletionView.selectedIndex - 1 + count) % count
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertTab(_:)):
            commitWikiAutocomplete(at: wikiCompletionView.selectedIndex)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissedWikiOpenLocation = activeWikiOpenLocation
            hideWikiAutocomplete()
            return true
        default:
            return false
        }
    }

    @discardableResult
    func commitWikiAutocomplete(at index: Int? = nil) -> Bool {
        let targetIndex = index ?? wikiCompletionView.selectedIndex
        guard wikiCompletionView.items.indices.contains(targetIndex),
              let replaceRange = activeWikiReplacementRange else {
            return false
        }
        let item = wikiCompletionView.items[targetIndex]
        let replacement = "[[\(item.title)]]"
        let nextCursor = NSRange(location: replaceRange.location + (replacement as NSString).length, length: 0)
        hideWikiAutocomplete()
        textView.applyUndoableReplacement(in: replaceRange, with: replacement, selectedRangeAfter: nextCursor)
        window?.makeFirstResponder(textView)
        return true
    }

    private func updateWikiAutocompleteAfterEdit(force: Bool) {
        let sel = textView.selectedRange()
        guard sel.length == 0 else {
            hideWikiAutocomplete()
            return
        }
        let cursor = sel.location
        if textView.fencedBlocks.contains(where: { NSLocationInRange(cursor, $0.fullRange) })
            || textView.inlineCodeRanges.contains(where: { NSLocationInRange(cursor, $0) }) {
            hideWikiAutocomplete()
            return
        }
        let ns = nsText
        guard let active = Vault.activeWikiLinkQuery(inNSString: ns, cursorLocation: cursor) else {
            dismissedWikiOpenLocation = nil
            hideWikiAutocomplete()
            return
        }
        let openLoc = active.replacementRange.location
        if !force, dismissedWikiOpenLocation == openLoc {
            return
        }
        dismissedWikiOpenLocation = nil

        let notes: [NoteRecord]
        if activeWikiOpenLocation == openLoc, let cached = cachedAutocompleteNotes {
            notes = cached
        } else {
            let loaded = noteRecordsProvider?() ?? []
            cachedAutocompleteNotes = loaded
            notes = loaded
        }

        let items = Self.buildWikiCompletionItems(
            for: active.query,
            notes: notes,
            currentNoteURL: currentNoteURLProvider?()
        )
        guard !items.isEmpty else {
            hideWikiAutocomplete()
            return
        }
        let isNewPopup = (activeWikiOpenLocation != openLoc) || wikiCompletionView.isHidden
        activeWikiOpenLocation = openLoc
        activeWikiReplacementRange = active.replacementRange
        wikiCompletionView.items = items
        if isNewPopup {
            wikiCompletionView.selectedIndex = 0
        }
        positionWikiCompletionView()
        wikiCompletionView.isHidden = false
    }

    private func positionWikiCompletionView() {
        let size = wikiCompletionView.preferredSize()
        let caretInText = textView.currentCaretRect()
        let caretInEditor = convert(caretInText, from: textView)
        let minX: CGFloat = 16
        let maxX = max(minX, bounds.width - size.width - 16)
        let x = min(max(minX, caretInEditor.minX), maxX)
        let belowY = caretInEditor.minY - size.height - 6
        let y: CGFloat
        if belowY >= 34 || bounds.height < size.height + 40 {
            y = max(8, belowY)
        } else {
            y = min(max(8, bounds.height - size.height - 8), caretInEditor.maxY + 6)
        }
        wikiCompletionView.frame = NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
    }

    static func buildWikiCompletionItems(
        for rawQuery: String,
        notes: [NoteRecord],
        currentNoteURL: URL?
    ) -> [WikiLinkCompletionView.Item] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [WikiLinkCompletionView.Item] = []
        if trimmed.isEmpty {
            let ordered = notes.sorted { a, b in
                let aIsCurrent = (a.url == currentNoteURL)
                let bIsCurrent = (b.url == currentNoteURL)
                if aIsCurrent != bIsCurrent { return !aIsCurrent }
                return a.modifiedAt > b.modifiedAt
            }
            for note in ordered.prefix(8) {
                let sub = note.excerpt.isEmpty ? note.url.deletingPathExtension().lastPathComponent : note.excerpt
                results.append(WikiLinkCompletionView.Item(
                    title: note.title,
                    subtitle: sub,
                    isCreateNew: false,
                    noteURL: note.url
                ))
            }
            return results
        }

        let lowerQuery = trimmed.lowercased()
        var scored: [(score: Int, isCurrent: Bool, note: NoteRecord)] = []
        for note in notes {
            let titleLower = note.title.lowercased()
            let stemLower = note.url.deletingPathExtension().lastPathComponent.lowercased()
            let score: Int
            if titleLower == lowerQuery {
                score = 100
            } else if titleLower.hasPrefix(lowerQuery) {
                score = 80
            } else if titleLower.contains(lowerQuery) {
                score = 60
            } else if stemLower.contains(lowerQuery) {
                score = 40
            } else if note.excerpt.localizedCaseInsensitiveContains(trimmed) {
                score = 20
            } else {
                continue
            }
            scored.append((score, note.url == currentNoteURL, note))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.isCurrent != b.isCurrent { return !a.isCurrent }
            return a.note.modifiedAt > b.note.modifiedAt
        }
        for entry in scored.prefix(6) {
            let sub = entry.note.excerpt.isEmpty ? entry.note.url.deletingPathExtension().lastPathComponent : entry.note.excerpt
            results.append(WikiLinkCompletionView.Item(
                title: entry.note.title,
                subtitle: sub,
                isCreateNew: false,
                noteURL: entry.note.url
            ))
        }
        let hasExactMatch = notes.contains { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
        if !hasExactMatch {
            results.append(WikiLinkCompletionView.Item(
                title: trimmed,
                subtitle: "Create new note when opened",
                isCreateNew: true,
                noteURL: nil
            ))
        }
        return results
    }

    struct DocumentScanResult {
        let words: Int
        let hasStar: Bool
        let hasDoubleStar: Bool
        let hasDoubleUnderscore: Bool
        let hasHTMLUnderline: Bool
        let hasDoubleTilde: Bool
        let hasBacktick: Bool
        let hasTripleBacktick: Bool
        let hasLinkOpen: Bool
        let hasWikiLink: Bool
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
            return DocumentScanResult(
                words: 0,
                hasStar: false,
                hasDoubleStar: false,
                hasDoubleUnderscore: false,
                hasHTMLUnderline: false,
                hasDoubleTilde: false,
                hasBacktick: false,
                hasTripleBacktick: false,
                hasLinkOpen: false,
                hasWikiLink: false
            )
        }
        let cfStr = ns as CFString
        var words = 0
        var inWord = false
        var hasStar = false
        var hasDoubleStar = false
        var hasDoubleUnderscore = false
        var hasHTMLUnderline = false
        var hasDoubleTilde = false
        var hasBacktick = false
        var hasTripleBacktick = false
        var hasLinkOpen = false
        var hasWikiLink = false
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
                if u > 0x60 && u < 0x007B {
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
                        } else if u == 0x5F {
                            if prevChar == 0x5F { hasDoubleUnderscore = true }
                            runBackticks = 0
                        } else if u == 0x7E {
                            if prevChar == 0x7E { hasDoubleTilde = true }
                            runBackticks = 0
                        } else if u == 0x3C {
                            hasHTMLUnderline = true
                            runBackticks = 0
                        } else if u == 0x60 {
                            hasBacktick = true
                            runBackticks &+= 1
                            if runBackticks >= 3 { hasTripleBacktick = true }
                        } else {
                            if u == 0x28 && prevChar == 0x5D {
                                hasLinkOpen = true
                            } else if u == 0x5B && prevChar == 0x5B {
                                hasWikiLink = true
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
            hasDoubleUnderscore: hasDoubleUnderscore,
            hasHTMLUnderline: hasHTMLUnderline,
            hasDoubleTilde: hasDoubleTilde,
            hasBacktick: hasBacktick,
            hasTripleBacktick: hasTripleBacktick,
            hasLinkOpen: hasLinkOpen,
            hasWikiLink: hasWikiLink
        )
    }

    static func countWords(in ns: NSString, range: NSRange) -> Int {
        scanDocument(in: ns, range: range).words
    }

    private func performOrReuseScan(on ns: NSString, length: Int, sig: Int) -> DocumentScanResult {
        if length == 0 {
            return DocumentScanResult(
                words: 0,
                hasStar: false,
                hasDoubleStar: false,
                hasDoubleUnderscore: false,
                hasHTMLUnderline: false,
                hasDoubleTilde: false,
                hasBacktick: false,
                hasTripleBacktick: false,
                hasLinkOpen: false,
                hasWikiLink: false
            )
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
            var w: [WikiLink] = []
            var b: [MarkdownTextView.BulletItem] = []
            formatLineRange(oldLine, in: storage, ns: ns, cursor: cursor, quotes: &q, headings: &h, codes: &c, wikiLinks: &w, bullets: &b)
        }
        if newNeeds, newLine != oldLine, NSMaxRange(newLine) <= ns.length {
            var q: [NSRange] = []
            var h: [MarkdownTextView.HeadingGutter] = []
            var c: [NSRange] = []
            var w: [WikiLink] = []
            var b: [MarkdownTextView.BulletItem] = []
            formatLineRange(newLine, in: storage, ns: ns, cursor: cursor, quotes: &q, headings: &h, codes: &c, wikiLinks: &w, bullets: &b)
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
        if ns.range(of: "__", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "<u>", options: .caseInsensitive, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "~~", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "[[", options: .literal, range: lineRange).location != NSNotFound { return true }
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
            || textView.wikiLinkItems.contains { NSIntersectionRange($0.fullRange, oldLineRange).length > 0 || $0.fullRange.location == oldLineRange.location }
            || textView.bulletItems.contains { NSIntersectionRange($0.lineRange, oldLineRange).length > 0 || $0.lineRange.location == oldLineRange.location }

        let newHasSyntax = lineHasMarkdownSyntax(ns, lineRange: newLineRange)

        if edit.affectedRange.length == 0 && !hadItemsInOldLine && !newHasSyntax {
            // Fast path for plain prose editing: shift subsequent decoration ranges without touching NSTextStorage attributes
            if delta != 0 {
                let shiftStart = oldLineEnd
                for i in textView.headingGutterItems.indices where textView.headingGutterItems[i].range.location >= shiftStart {
                    let r = textView.headingGutterItems[i].range
                    textView.headingGutterItems[i] = MarkdownTextView.HeadingGutter(
                        range: NSRange(location: r.location + delta, length: r.length),
                        label: textView.headingGutterItems[i].label,
                        level: textView.headingGutterItems[i].level,
                        title: textView.headingGutterItems[i].title
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
                for i in textView.wikiLinkItems.indices where textView.wikiLinkItems[i].fullRange.location >= shiftStart {
                    textView.wikiLinkItems[i] = Self.shiftWikiLink(textView.wikiLinkItems[i], by: delta)
                }
                for i in textView.bulletItems.indices where textView.bulletItems[i].lineRange.location >= shiftStart {
                    let item = textView.bulletItems[i]
                    textView.bulletItems[i] = MarkdownTextView.BulletItem(
                        lineRange: NSRange(location: item.lineRange.location + delta, length: item.lineRange.length),
                        markerRange: NSRange(location: item.markerRange.location + delta, length: item.markerRange.length),
                        level: item.level,
                        kind: item.kind
                    )
                }
                textView.shiftFoldedSections(from: shiftStart, by: delta)
            }
            lastCursorLine = ns.lineRange(for: NSRange(location: min(textView.selectedRange().location, newLen), length: 0))
            return false
        }

        var newQuotes: [NSRange] = []
        var newHeadings: [MarkdownTextView.HeadingGutter] = []
        var newCodes: [NSRange] = []
        var newWikiLinks: [WikiLink] = []
        var newBullets: [MarkdownTextView.BulletItem] = []
        let cursor = textView.selectedRange()

        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        formatLineRange(newLineRange, in: storage, ns: ns, cursor: cursor, quotes: &newQuotes, headings: &newHeadings, codes: &newCodes, wikiLinks: &newWikiLinks, bullets: &newBullets)
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
                    level: item.level,
                    title: item.title
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

        var updatedWikiLinks: [WikiLink] = []
        var insertedWikiLinks = false
        for item in textView.wikiLinkItems {
            if NSMaxRange(item.fullRange) <= oldLineRange.location && item.fullRange.location < oldLineRange.location {
                updatedWikiLinks.append(item)
            } else if item.fullRange.location >= oldEnd && oldEnd > oldLineRange.location {
                if !insertedWikiLinks {
                    updatedWikiLinks.append(contentsOf: newWikiLinks)
                    insertedWikiLinks = true
                }
                updatedWikiLinks.append(Self.shiftWikiLink(item, by: delta))
            }
        }
        if !insertedWikiLinks { updatedWikiLinks.append(contentsOf: newWikiLinks) }
        textView.wikiLinkItems = updatedWikiLinks

        var updatedBullets: [MarkdownTextView.BulletItem] = []
        var insertedBullets = false
        for item in textView.bulletItems {
            if NSMaxRange(item.lineRange) <= oldLineRange.location && item.lineRange.location < oldLineRange.location {
                updatedBullets.append(item)
            } else if item.lineRange.location >= oldEnd && oldEnd > oldLineRange.location {
                if !insertedBullets {
                    updatedBullets.append(contentsOf: newBullets)
                    insertedBullets = true
                }
                updatedBullets.append(MarkdownTextView.BulletItem(
                    lineRange: NSRange(location: item.lineRange.location + delta, length: item.lineRange.length),
                    markerRange: NSRange(location: item.markerRange.location + delta, length: item.markerRange.length),
                    level: item.level,
                    kind: item.kind
                ))
            }
        }
        if !insertedBullets { updatedBullets.append(contentsOf: newBullets) }
        textView.bulletItems = updatedBullets
        if delta != 0 {
            textView.shiftFoldedSections(from: oldEnd, by: delta)
        }

        lastCursorLine = ns.lineRange(for: NSRange(location: min(cursor.location, newLen), length: 0))
        return true
    }

    private func applyEditorChromeAttributes() {
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
        applyEditorChromeAttributes()
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
        guard totalLen > 0 else {
            textView.blockquoteRanges = []
            textView.headingGutterItems = []
            textView.inlineCodeRanges = []
            textView.wikiLinkItems = []
            textView.fencedBlocks = []
            textView.bulletItems = []
            hasPotentialLinks = false
            return
        }

        let scan = scanHint ?? performOrReuseScan(on: ns, length: totalLen, sig: Self.sampleSignature(of: ns))

        storage.setAttributes(baseAttrs, range: range)

        var quotes: [NSRange] = []
        var headings: [MarkdownTextView.HeadingGutter] = []
        var inlinePills: [NSRange] = []
        var wikiLinks: [WikiLink] = []
        var bullets: [MarkdownTextView.BulletItem] = []
        var parsedFences: [MarkdownTextView.FencedBlock] = []

        formatLineRange(range, in: storage, ns: ns, cursor: cursor, scan: scan, quotes: &quotes, headings: &headings, codes: &inlinePills, wikiLinks: &wikiLinks, bullets: &bullets)
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

        if !parsedFences.isEmpty {
            headings.removeAll { item in
                parsedFences.contains { NSIntersectionRange($0.fullRange, item.range).length > 0 }
            }
            bullets.removeAll { item in
                parsedFences.contains { NSIntersectionRange($0.fullRange, item.lineRange).length > 0 }
            }
            quotes.removeAll { r in
                parsedFences.contains { NSIntersectionRange($0.fullRange, r).length > 0 }
            }
            inlinePills.removeAll { r in
                parsedFences.contains { NSIntersectionRange($0.fullRange, r).length > 0 }
            }
            wikiLinks.removeAll { link in
                parsedFences.contains { NSIntersectionRange($0.fullRange, link.fullRange).length > 0 }
            }
        }

        textView.blockquoteRanges = quotes
        textView.headingGutterItems = headings
        textView.inlineCodeRanges = inlinePills
        textView.wikiLinkItems = wikiLinks
        textView.fencedBlocks = parsedFences
        textView.bulletItems = bullets
    }

    private static func shiftWikiLink(_ item: WikiLink, by delta: Int) -> WikiLink {
        WikiLink(
            target: item.target,
            alias: item.alias,
            fullRange: NSRange(location: item.fullRange.location + delta, length: item.fullRange.length),
            innerRange: NSRange(location: item.innerRange.location + delta, length: item.innerRange.length),
            targetRange: NSRange(location: item.targetRange.location + delta, length: item.targetRange.length),
            aliasRange: item.aliasRange.map { NSRange(location: $0.location + delta, length: $0.length) }
        )
    }

    static func bulletColor(forLevel level: Int) -> NSColor {
        switch level % 4 {
        case 0: return Theme.accent
        case 1: return Theme.sage
        case 2: return Theme.bulletTertiary
        default: return Theme.muted
        }
    }

    private func formatLineRange(
        _ targetRange: NSRange,
        in storage: NSTextStorage,
        ns: NSString,
        cursor: NSRange,
        scan: DocumentScanResult? = nil,
        quotes: inout [NSRange],
        headings: inout [MarkdownTextView.HeadingGutter],
        codes: inout [NSRange],
        wikiLinks: inout [WikiLink],
        bullets: inout [MarkdownTextView.BulletItem]
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
        let checkDoubleUnderscore = scan?.hasDoubleUnderscore ?? true
        let checkHTMLUnderline = scan?.hasHTMLUnderline ?? true
        let checkDoubleTilde = scan?.hasDoubleTilde ?? true

        let checkWikiLink = scan?.hasWikiLink ?? true
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

        if checkDoubleUnderscore && ns.range(of: "__", options: .literal, range: targetRange).location != NSNotFound {
            let markerAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)]
            let underlineAttrs: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: Theme.accent.withAlphaComponent(0.85)
            ]
            var searchStart = targetRange.location
            let targetEnd = NSMaxRange(targetRange)
            while searchStart < targetEnd {
                let hit = ns.range(of: "__", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in underline.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let full = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    let inner = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    storage.addAttributes(underlineAttrs, range: inner)
                    storage.addAttributes(markerAttrs, range: NSRange(location: full.location, length: 2))
                    storage.addAttributes(markerAttrs, range: NSRange(location: NSMaxRange(full) - 2, length: 2))
                }
                searchStart = NSMaxRange(lineRange)
            }
        }

        if checkHTMLUnderline && ns.range(of: "<u>", options: .caseInsensitive, range: targetRange).location != NSNotFound {
            let markerAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.subtle, .font: Theme.monoFont(11.5)]
            let underlineAttrs: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: Theme.accent.withAlphaComponent(0.85)
            ]
            var searchStart = targetRange.location
            let targetEnd = NSMaxRange(targetRange)
            while searchStart < targetEnd {
                let hit = ns.range(of: "<u>", options: .caseInsensitive, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in htmlUnderline.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let full = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    let inner = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    storage.addAttributes(underlineAttrs, range: inner)
                    storage.addAttributes(markerAttrs, range: NSRange(location: full.location, length: 3))
                    storage.addAttributes(markerAttrs, range: NSRange(location: NSMaxRange(full) - 4, length: 4))
                }
                searchStart = NSMaxRange(lineRange)
            }
        }

        if checkDoubleTilde && ns.range(of: "~~", options: .literal, range: targetRange).location != NSNotFound {
            let markerAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)]
            let strikeAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.muted,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: Theme.subtle.withAlphaComponent(0.8)
            ]
            var searchStart = targetRange.location
            let targetEnd = NSMaxRange(targetRange)
            while searchStart < targetEnd {
                let hit = ns.range(of: "~~", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in strikethrough.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let full = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    let inner = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    storage.addAttributes(strikeAttrs, range: inner)
                    storage.addAttributes(markerAttrs, range: NSRange(location: full.location, length: 2))
                    storage.addAttributes(markerAttrs, range: NSRange(location: NSMaxRange(full) - 2, length: 2))
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
                    let headingTitle = ns.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                    headings.append(MarkdownTextView.HeadingGutter(range: matchRange, label: "H\(level)", level: level, title: headingTitle))
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
                    let wsSubrange = match.range(at: 2)
                    let symbolSubrange = match.range(at: 3)
                    let taskSubrange = match.range(at: 4)
                    let bodyRange = NSRange(location: contentRange.location + match.range(at: 5).location, length: match.range(at: 5).length)

                    var indentCols = 0
                    if wsSubrange.location != NSNotFound && wsSubrange.length > 0 {
                        let wsRange = NSRange(location: contentRange.location + wsSubrange.location, length: wsSubrange.length)
                        for idx in wsRange.location..<NSMaxRange(wsRange) {
                            let ch = ns.character(at: idx)
                            if ch == 0x09 { indentCols += 2 }
                            else if ch == 0x20 { indentCols += 1 }
                        }
                        storage.addAttributes(hiddenAttrs, range: wsRange)
                    }
                    let level = indentCols / 2
                    let clampedLevel = min(level, 6)
                    let levelIndent = CGFloat(clampedLevel) * 22.0

                    let symbolRange = NSRange(location: contentRange.location + symbolSubrange.location, length: symbolSubrange.length)
                    let symbolChar = ns.character(at: symbolRange.location)
                    let isUnordered = (symbolChar == 0x2D || symbolChar == 0x2A || symbolChar == 0x2B)
                    let isTask = taskSubrange.location != NSNotFound && taskSubrange.length > 0
                    let markerText = (lineStr as NSString).substring(with: match.range(at: 1))
                    let completed = isTask && (markerText.hasSuffix("[x]") || markerText.hasSuffix("[X]"))

                    let itemParagraph = NSMutableParagraphStyle()
                    itemParagraph.lineSpacing = 5.5
                    itemParagraph.paragraphSpacing = level == 0 ? 4.5 : 3.0
                    itemParagraph.firstLineHeadIndent = levelIndent
                    itemParagraph.headIndent = levelIndent + (isTask ? 42 : 18)
                    storage.addAttribute(.paragraphStyle, value: itemParagraph, range: fullMatchRange)

                    let levelColor = Self.bulletColor(forLevel: level)
                    if isTask {
                        storage.addAttributes([
                            .font: Theme.monoFont(proseSize - 2.5, weight: .semibold),
                            .foregroundColor: completed ? Theme.sage : levelColor
                        ], range: markerRange)
                        if completed {
                            storage.addAttributes([
                                .foregroundColor: Theme.muted,
                                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                .strikethroughColor: Theme.subtle.withAlphaComponent(0.75)
                            ], range: bodyRange)
                        }
                    } else if isUnordered {
                        storage.addAttributes([
                            .font: Theme.monoFont(proseSize - 2.5, weight: .semibold),
                            .foregroundColor: NSColor.clear
                        ], range: symbolRange)
                    } else {
                        storage.addAttributes([
                            .font: Theme.monoFont(proseSize - 2.5, weight: .semibold),
                            .foregroundColor: levelColor
                        ], range: symbolRange)
                    }

                    let kind: MarkdownTextView.BulletItem.Kind
                    if isTask {
                        kind = .task(completed: completed)
                    } else if isUnordered {
                        kind = .unordered
                    } else {
                        kind = .ordered
                    }
                    bullets.append(MarkdownTextView.BulletItem(
                        lineRange: fullMatchRange,
                        markerRange: symbolRange,
                        level: level,
                        kind: kind
                    ))
                }
            }
        }

        if checkWikiLink && ns.range(of: "[[", options: .literal, range: targetRange).location != NSNotFound {
            let bracketAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.subtle,
                .font: Theme.monoFont(12, weight: .medium)
            ]
            let pipeTargetAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.subtle,
                .font: Theme.monoFont(12)
            ]
            let parsed = Vault.wikiLinks(inNSString: ns, range: targetRange)
            for item in parsed {
                if codes.contains(where: { NSIntersectionRange($0, item.fullRange).length > 0 }) {
                    continue
                }
                wikiLinks.append(item)
                let headingMatch = headings.first { NSIntersectionRange($0.range, item.fullRange).length > 0 }
                let linkFont = headingMatch.map { Theme.headingFont(level: $0.level) } ?? Theme.bodyFont(proseSize, weight: .medium)
                let linkTextAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: Theme.accent,
                    .font: linkFont,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: Theme.accent.withAlphaComponent(0.45)
                ]
                if let aliasRange = item.aliasRange, aliasRange.length > 0 {
                    let prefixLen = max(0, aliasRange.location - item.targetRange.location)
                    if prefixLen > 0 {
                        storage.addAttributes(pipeTargetAttrs, range: NSRange(location: item.targetRange.location, length: prefixLen))
                    }
                    storage.addAttributes(linkTextAttrs, range: aliasRange)
                } else {
                    storage.addAttributes(linkTextAttrs, range: item.innerRange)
                }
                storage.addAttributes(bracketAttrs, range: NSRange(location: item.fullRange.location, length: 2))
                storage.addAttributes(bracketAttrs, range: NSRange(location: NSMaxRange(item.fullRange) - 2, length: 2))
            }
        }
    }
}
