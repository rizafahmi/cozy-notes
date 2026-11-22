import AppKit
import UniformTypeIdentifiers
import ImageIO
import QuartzCore
import CozyCore
import CozySearch

@MainActor private final class CozyUndoManager: UndoManager {
    var onWillUndoOrRedo: (() -> Void)?
    var onDidUndoOrRedo: (() -> Void)?

    override func undo() {
        onWillUndoOrRedo?()
        autoreleasepool { super.undo() }
        onDidUndoOrRedo?()
    }
    override func undoNestedGroup() {
        onWillUndoOrRedo?()
        autoreleasepool { super.undoNestedGroup() }
        onDidUndoOrRedo?()
    }
    override func redo() {
        onWillUndoOrRedo?()
        autoreleasepool { super.redo() }
        onDidUndoOrRedo?()
    }
}

@MainActor private final class FoldTypesetter: NSATSTypesetter {
    weak var textView: MarkdownTextView?

    nonisolated override func layoutParagraph(at lineFragmentOrigin: UnsafeMutablePointer<NSPoint>) -> Int {
        MainActor.assumeIsolated {
            guard let textView, !textView.foldedSections.isEmpty,
                  let container = currentTextContainer, let layoutManager else {
                return super.layoutParagraph(at: lineFragmentOrigin)
            }
            let paragraph = NSUnionRange(paragraphCharacterRange, paragraphSeparatorCharacterRange)
            guard paragraph.length > 0 else { return super.layoutParagraph(at: lineFragmentOrigin) }
            let folds = textView.foldedSections
            var lo = 0
            var hi = folds.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if NSMaxRange(folds[mid].foldedCharRange) <= paragraph.location {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            guard lo < folds.count else { return super.layoutParagraph(at: lineFragmentOrigin) }
            let fold = folds[lo].foldedCharRange
            guard paragraph.location >= fold.location, NSMaxRange(paragraph) <= NSMaxRange(fold) else {
                return super.layoutParagraph(at: lineFragmentOrigin)
            }
            // Lay out the whole hidden remainder once, not one empty fragment per font or paragraph.
            let hidden = NSRange(location: paragraph.location, length: NSMaxRange(fold) - paragraph.location)
            layoutManager.ensureGlyphs(forCharacterRange: hidden)
            let glyphs = layoutManager.glyphRange(forCharacterRange: hidden, actualCharacterRange: nil)
            setParagraphGlyphRange(glyphs, separatorGlyphRange: NSRange(location: NSMaxRange(glyphs), length: 0))
            beginParagraph()
            beginLine(withGlyphAt: glyphs.location)
            let rect = NSRect(origin: lineFragmentOrigin.pointee, size: NSSize(width: container.containerSize.width, height: 0))
            layoutManager.setTextContainer(container, forGlyphRange: glyphs)
            setLineFragmentRect(rect, forGlyphRange: glyphs, usedRect: NSRect(origin: rect.origin, size: .zero), baselineOffset: 0)
            setLocation(.zero, withAdvancements: nil, forStartOfGlyphRange: glyphs)
            endLine(withGlyphRange: glyphs)
            endParagraph()
            setNotShownAttribute(true, forGlyphRange: glyphs)
            return NSMaxRange(glyphs)
        }
    }
}

@MainActor private final class InlineImageCache {
    static let shared = InlineImageCache()

    struct Metrics: Equatable {
        let naturalPointSize: NSSize
    }

    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private let metricsCache = NSCache<NSString, Box<Metrics>>()
    private let thumbnailCache = NSCache<NSString, NSImage>()

    private init() {
        metricsCache.countLimit = 256
        thumbnailCache.countLimit = 96
    }

    private func fileStamp(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        let mod = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)|\(size.int64Value)|\(Int64(mod * 1000))"
    }

    func imageMetrics(for url: URL) -> Metrics? {
        guard let stamp = fileStamp(for: url) else { return nil }
        let cacheKey = stamp as NSString
        if let cached = metricsCache.object(forKey: cacheKey) {
            return cached.value
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let rawW = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let rawH = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           rawW > 0, rawH > 0 {
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapsAxes = (5...8).contains(orientation)
            let pixelW = CGFloat(swapsAxes ? rawH : rawW)
            let pixelH = CGFloat(swapsAxes ? rawW : rawH)
            let dpiX = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72.0
            let dpiScale: CGFloat = dpiX >= 140.0 ? CGFloat(dpiX / 72.0) : 1.0
            let pointSize = NSSize(
                width: max(1, round(pixelW / dpiScale)),
                height: max(1, round(pixelH / dpiScale))
            )
            let result = Metrics(naturalPointSize: pointSize)
            metricsCache.setObject(Box(result), forKey: cacheKey)
            return result
        }
        if let fallback = NSImage(contentsOf: url), fallback.size.width > 0, fallback.size.height > 0 {
            let result = Metrics(naturalPointSize: fallback.size)
            metricsCache.setObject(Box(result), forKey: cacheKey)
            return result
        }
        return nil
    }

    func thumbnail(for url: URL, targetPointSize: NSSize, backingScale: CGFloat) -> NSImage? {
        guard let stamp = fileStamp(for: url) else { return nil }
        let rawMaxPx = Int(ceil(max(targetPointSize.width, targetPointSize.height) * max(1.0, backingScale)))
        let bucketPx = max(64, ((rawMaxPx + 63) / 64) * 64)
        let cacheKey = "\(stamp)|\(bucketPx)" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: min(2560, bucketPx)
           ] as CFDictionary) {
            let img = NSImage(cgImage: cgImage, size: targetPointSize)
            thumbnailCache.setObject(img, forKey: cacheKey)
            return img
        }
        if let fallback = NSImage(contentsOf: url), fallback.size.width > 0, fallback.size.height > 0 {
            thumbnailCache.setObject(fallback, forKey: cacheKey)
            return fallback
        }
        return nil
    }
}

@MainActor final class MarkdownTextView: NSTextView {
    static let defaultUndoLevels = 128
    private let editorUndoManager: CozyUndoManager = {
        let um = CozyUndoManager()
        um.levelsOfUndo = MarkdownTextView.defaultUndoLevels
        return um
    }()
    override var undoManager: UndoManager? { editorUndoManager }
    let vim = VimEngine()
    var onFiles: (([URL], NSRange?, Bool) -> Void)?
    var onClipboardImage: ((Data, NSRange?, Bool) -> Void)?
    var onFocusChange: (() -> Void)?
    var onFoldStatusChange: ((String) -> Void)?
    var onOpenWikiLink: ((WikiLink) -> Void)?
    var onOpenWikiLinkInNewWindow: ((WikiLink) -> Void)?
    var onClickTag: ((String) -> Void)?
    var onOpenMarkdownLink: ((MarkdownLink) -> Void)?
    var onClickMarkdownLink: ((MarkdownLink, NSPoint) -> Void)?
    var onCopyMarkdownLink: ((MarkdownLink) -> Void)?
    var onOpenInlineImage: ((InlineImageItem) -> Void)?
    var onRevealInlineImage: ((InlineImageItem) -> Void)?
    var onCopyInlineImage: ((InlineImageItem) -> Void)?
    var onDismissLinkActionBar: (() -> Void)?
    var onCancelLinkActionBar: (() -> Bool)?
    var onScrollBoundsChange: (() -> Void)?
    var onOpenCurrentNoteInNewWindow: (() -> Void)?
    var onTogglePinCurrentNote: (() -> Void)?
    var onInsertWikiLinkShortcut: (() -> Void)?
    var onWikiAutocompleteCommand: ((Selector) -> Bool)?
    var onQuickSwitcher: (() -> Void)?
    var onShowInNoteFind: (() -> Void)?
    var onFindNextInNote: (() -> Void)?
    var onFindPreviousInNote: (() -> Void)?
    var onToggleOutline: (() -> Void)?
    var onToggleSemanticConnections: (() -> Void)?
    var placeholder = "Begin a note, paste a clipping, or drop a file…" { didSet { needsDisplay = true } }
    struct MarkdownLink: Equatable {
        let fullRange: NSRange
        let labelRange: NSRange
        let rawDestination: String
        let resolvedURL: URL
    }
    struct InlineImageItem: Equatable {
        let fullRange: NSRange
        let lineRange: NSRange
        let fullLineRange: NSRange
        let altText: String
        let caption: String?
        let rawDestination: String
        let resolvedURL: URL
        let naturalPointSize: NSSize?
        let displaySize: NSSize
        let itemSlotHeight: CGFloat
        let offsetFromParagraphBottom: CGFloat
        let isStandaloneLine: Bool
        let isReadableImage: Bool
    }
    struct FencedBlock {
        let fullRange: NSRange
        let headerRange: NSRange
        let bodyRange: NSRange
    }
    struct TableRowItem: Equatable {
        let lineRange: NSRange
        let fullLineRange: NSRange
        let isHeader: Bool
        let isDelimiter: Bool
    }
    struct TableBlock: Equatable {
        let fullRange: NSRange
        let headerRange: NSRange
        let delimiterRange: NSRange
        let rows: [TableRowItem]
        let columnDividerOffsets: [CGFloat]
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
    var horizontalRuleRanges: [NSRange] = []
    var fencedBlocks: [FencedBlock] = []
    var tableBlocks: [TableBlock] = []
    var inlineCodeRanges: [NSRange] = []
    var wikiLinkItems: [WikiLink] = []
    var tagItems: [NoteTag] = []
    var markdownLinkItems: [MarkdownLink] = []
    var inlineImageItems: [InlineImageItem] = []
    var inNoteFindRanges: [NSRange] = []
    var activeInNoteFindIndex: Int = -1
    var headingGutterItems: [HeadingGutter] = []
    var bulletItems: [BulletItem] = []
    var externalChangeRanges: [NSRange] = []
    private(set) var foldedSections: [FoldedSection] = []
    private(set) var outlineFoldMode: OutlineFoldMode = .showAll
    private var foldHitTargets: [FoldHitTarget] = []
    private var linkHoverTracking: NSTrackingArea?
    var customMouseSelectionTracker: ((MarkdownTextView, NSEvent) -> Void)?
    private var isShowingLinkPointerCursor = false
    private var contextMenuMarkdownLink: MarkdownLink?
    private var contextMenuInlineImage: InlineImageItem?
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
        let preSelectionLineLocation: Int
    }
    var pendingEdit: EditRecord?
    var isEditingText = false
    var cachedFullText: String = ""
    var cachedFullTextLength: Int = 0
    var cachedFullTextSig: Int = 0
    var pasteboard: NSPasteboard = .general
    private var lastClipboardChangeCount: Int = -1
    private var lastClipboardString: String = ""
    private var lastClipboardLength: Int = -1
    private var lastClipboardSig: Int = 0
    /// Bike-style visual easing for typing; logical insertion, selection, and scrolling stay immediate.
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
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "cornerRadius": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private var hasCaretOrigin = false
    private var caretAnimationSequence: UInt64 = 0
    private var isHandlingTypingInput = false
    private var activeKeyDownModifiers: NSEvent.ModifierFlags?
    private var wasComposingMarkedTextOnKeyDown = false
    private var isCaretTypingTransaction = false
    private var animatesNextCaretUpdate = false
    private let caretAccessibilityCenter = NSWorkspace.shared.notificationCenter
    private var caretAccessibilityObserver: NSObjectProtocol?
    private static let caretSpringFrequency: CGFloat = 2 * .pi / 0.125
    private static let caretSpringStiffness = caretSpringFrequency * caretSpringFrequency
    private static let caretSpringDamping = 2 * caretSpringFrequency
    private var caretBlinkWorkItem: DispatchWorkItem?
    private var caretBlinkOn = true
    private var lastEditWasLarge = false
    private var minimumOverscrollHeight: CGFloat = 0
    private var viewportPreservationDepth = 0
    private var preservedViewportMinHeight: CGFloat = 0
    private var isApplyingMarkedText = false
    private var textChangeGeneration: UInt64 = 0
    private var windowFocusObservers: [NSObjectProtocol] = []
    var suppressCaretUpdates = false
    var isPreservingViewport: Bool { viewportPreservationDepth > 0 }
    private var shouldSuppressImplicitTextScroll: Bool {
        viewportPreservationDepth > 0 || isEditingText || suppressCaretUpdates || isApplyingMarkedText
    }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { removeCaretTravelAnimations() }
        if minimumOverscrollHeight > 0 && viewportPreservationDepth == 0 && !isApplyingMarkedText {
            let maxOverscroll = newSize.height + (enclosingScrollView?.contentView.bounds.height ?? 0) * 0.4
            if minimumOverscrollHeight > maxOverscroll {
                minimumOverscrollHeight = maxOverscroll
            }
        }
        let clampedHeight = max(newSize.height, minimumOverscrollHeight, preservedViewportMinHeight)
        super.setFrameSize(NSSize(width: newSize.width, height: clampedHeight))
    }

    /// Runs an attribute-formatting or in-place storage pass without allowing TextKit 1's
    /// non-contiguous layout height estimate to collapse the document view or scroll the clip view.
    func preservingViewport<T>(_ body: () -> T) -> T {
        guard let scrollView = enclosingScrollView,
              let lm = layoutManager,
              let tc = textContainer,
              let storage = textStorage else {
            return body()
        }
        if viewportPreservationDepth > 0 {
            viewportPreservationDepth += 1
            defer { viewportPreservationDepth -= 1 }
            return body()
        }

        let clipView = scrollView.contentView
        let savedOrigin = clipView.bounds.origin
        let visHeight = clipView.bounds.height
        var preVisibleChars: NSRange?
        var anchorChar: Int?
        var anchorViewportOffsetY: CGFloat?

        if savedOrigin.y > 0, storage.length > 0 {
            let preVisRect = clipView.documentVisibleRect.offsetBy(
                dx: -textContainerOrigin.x,
                dy: -textContainerOrigin.y
            )
            let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: preVisRect, in: tc)
            if glyphs.length > 0 {
                preVisibleChars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let firstGlyph = glyphs.location
                anchorChar = lm.characterIndexForGlyph(at: firstGlyph)
                let frag = lm.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
                if frag.height > 0 {
                    anchorViewportOffsetY = (frag.minY + textContainerOrigin.y) - savedOrigin.y
                }
            }
        }

        viewportPreservationDepth = 1
        preservedViewportMinHeight = (savedOrigin.y > 0 && storage.length > 0)
            ? max(frame.height, savedOrigin.y + visHeight)
            : 0
        defer {
            preservedViewportMinHeight = 0
            viewportPreservationDepth = 0
        }

        let result = body()

        let postLen = storage.length
        if postLen == 0 {
            preservedViewportMinHeight = 0
            if savedOrigin.y > 0 {
                clipView.setBoundsOrigin(NSPoint(x: savedOrigin.x, y: 0))
                scrollView.reflectScrolledClipView(clipView)
            }
            return result
        }

        if savedOrigin.y > 0 {
            let ns = storage.mutableString
            var desiredY = savedOrigin.y
            if postLen <= 100_000 {
                let selEnd = min(postLen, NSMaxRange(selectedRange()))
                let targetEnd = min(postLen, max(preVisibleChars.map(NSMaxRange) ?? 0, selEnd) + 512)
                if targetEnd > 0 {
                    let lineSpan = ns.lineRange(for: NSRange(location: 0, length: targetEnd))
                    lm.ensureLayout(forCharacterRange: lineSpan)
                }
            } else if let preVisibleChars {
                let start = min(max(0, preVisibleChars.location - 1024), postLen)
                let end = min(postLen, max(start, NSMaxRange(preVisibleChars) + 2048))
                if end > start {
                    let lineSpan = ns.lineRange(for: NSRange(location: start, length: end - start))
                    lm.ensureLayout(forCharacterRange: lineSpan)
                }
                if let anchorChar, anchorChar < postLen, let anchorViewportOffsetY, lm.numberOfGlyphs > 0 {
                    let postGlyph = min(lm.glyphIndexForCharacter(at: anchorChar), lm.numberOfGlyphs - 1)
                    let postFrag = lm.lineFragmentRect(forGlyphAt: postGlyph, effectiveRange: nil)
                    if postFrag.height > 0 {
                        desiredY = max(0, (postFrag.minY + textContainerOrigin.y) - anchorViewportOffsetY)
                    }
                }
            }
            preservedViewportMinHeight = 0
            let postVisRect = NSRect(
                x: savedOrigin.x - textContainerOrigin.x,
                y: desiredY - textContainerOrigin.y,
                width: clipView.bounds.width,
                height: visHeight
            )
            lm.ensureLayout(forBoundingRect: postVisRect, in: tc)
            _ = lm.usedRect(for: tc)
            let maxOriginY = max(0, max(frame.height, minimumOverscrollHeight) - visHeight)
            let clampedY = min(desiredY, maxOriginY)
            if abs(clipView.bounds.origin.y - clampedY) > 0.01 || abs(clipView.bounds.origin.x - savedOrigin.x) > 0.01 {
                clipView.setBoundsOrigin(NSPoint(x: savedOrigin.x, y: clampedY))
                scrollView.reflectScrolledClipView(clipView)
            }
        }
        return result
    }

    private(set) var lastInvalidatedRect: NSRect = .zero

    override var preparedContentRect: NSRect {
        get { visibleRect }
        set { super.preparedContentRect = visibleRect }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        if enclosingScrollView != nil {
            let vis = visibleRect
            if vis.width > 0 && vis.height > 0 {
                guard !invalidRect.isNull && invalidRect.width > 0 && invalidRect.height > 0 else { return }
                lastInvalidatedRect = vis
                super.setNeedsDisplay(vis, avoidAdditionalLayout: true)
                return
            }
        }
        lastInvalidatedRect = invalidRect
        super.setNeedsDisplay(invalidRect, avoidAdditionalLayout: flag)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = layoutManager, let textContainer = textContainer, let storage = textStorage else { return }
        let totalLength = storage.length
        guard totalLength > 0 else { return }
        let origin = textContainerOrigin
        let baseRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let queryRect = baseRect.insetBy(dx: 0, dy: -96)
        if queryRect.width > 0 && queryRect.height > 0 {
            if totalLength > 65_536 {
                var probeGlyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: baseRect, in: textContainer)
                if probeGlyphs.length == 0 {
                    let visBase = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
                    probeGlyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: visBase, in: textContainer)
                }
                let ns = storage.mutableString
                if probeGlyphs.length > 0 {
                    let probeChars = layoutManager.characterRange(forGlyphRange: probeGlyphs, actualGlyphRange: nil)
                    let padStart = max(0, probeChars.location - 1200)
                    let padEnd = min(totalLength, NSMaxRange(probeChars) + 2400)
                    let padRange = ns.lineRange(for: NSRange(location: padStart, length: padEnd - padStart))
                    layoutManager.ensureLayout(forCharacterRange: padRange)
                } else if queryRect.minY <= 1200 {
                    let headRange = ns.lineRange(for: NSRange(location: 0, length: min(totalLength, 4800)))
                    layoutManager.ensureLayout(forCharacterRange: headRange)
                } else {
                    let ratio = min(1.0, max(0.0, queryRect.minY / max(1.0, bounds.height)))
                    let estChar = min(totalLength - 1, Int(Double(totalLength) * ratio))
                    let padStart = max(0, estChar - 2400)
                    let padEnd = ratio > 0.92 ? totalLength : min(totalLength, estChar + 4200)
                    let padRange = ns.lineRange(for: NSRange(location: padStart, length: padEnd - padStart))
                    layoutManager.ensureLayout(forCharacterRange: padRange)
                }
            } else {
                layoutManager.ensureLayout(forBoundingRect: queryRect, in: textContainer)
            }
        }
        guard !fencedBlocks.isEmpty || !tableBlocks.isEmpty || !inlineCodeRanges.isEmpty || !wikiLinkItems.isEmpty || !tagItems.isEmpty || !inlineImageItems.isEmpty || !inNoteFindRanges.isEmpty || !blockquoteRanges.isEmpty || !horizontalRuleRanges.isEmpty || !headingGutterItems.isEmpty || !bulletItems.isEmpty || !externalChangeRanges.isEmpty else { return }
        let columnWidth = max(0, bounds.width - 2 * origin.x)

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
        for table in tableBlocks {
            if table.fullRange.location > visEnd { break }
            if isCharacterFolded(table.fullRange.location) { continue }
            guard NSMaxRange(table.fullRange) >= visStart,
                  NSMaxRange(table.fullRange) <= totalLength,
                  NSMaxRange(table.headerRange) <= totalLength else { continue }
            let fullGlyphs = layoutManager.glyphRange(forCharacterRange: table.fullRange, actualCharacterRange: nil)
            let fullRect = layoutManager.boundingRect(forGlyphRange: fullGlyphs, in: textContainer)
            let headerGlyphs = layoutManager.glyphRange(forCharacterRange: table.headerRange, actualCharacterRange: nil)
            let headerRect = layoutManager.boundingRect(forGlyphRange: headerGlyphs, in: textContainer)
            let topY = round(origin.y + fullRect.minY - 6)
            let bottomY = round(origin.y + fullRect.maxY + 4)
            let headerBottomY = round(origin.y + headerRect.maxY + 2)
            let box = NSRect(x: origin.x, y: topY, width: columnWidth, height: max(32, bottomY - topY))

            let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            Theme.codeBackground.setFill()
            path.fill()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            Theme.codeHeaderFill.setFill()
            NSRect(x: box.minX, y: box.minY, width: box.width, height: max(22, headerBottomY - box.minY)).fill()

            var dataIdx = 0
            for row in table.rows where !row.isHeader && !row.isDelimiter {
                guard NSMaxRange(row.lineRange) <= totalLength else { continue }
                let rowGlyphs = layoutManager.glyphRange(forCharacterRange: row.lineRange, actualCharacterRange: nil)
                let rowRect = layoutManager.boundingRect(forGlyphRange: rowGlyphs, in: textContainer)
                let rowTop = dataIdx == 0 ? headerBottomY : round(origin.y + rowRect.minY - 5)
                let rowBottom = round(origin.y + rowRect.maxY + 2)
                if dataIdx % 2 == 1 {
                    Theme.elevated.withAlphaComponent(0.32).setFill()
                    NSRect(x: box.minX, y: rowTop, width: box.width, height: max(0, rowBottom - rowTop)).fill()
                }
                if dataIdx > 0 {
                    Theme.codeBorder.withAlphaComponent(0.6).setFill()
                    NSRect(x: box.minX, y: rowTop, width: box.width, height: 1).fill()
                }
                dataIdx += 1
            }

            Theme.codeBorder.setFill()
            NSRect(x: box.minX, y: headerBottomY, width: box.width, height: 1).fill()

            Theme.codeBorder.withAlphaComponent(0.75).setFill()
            for divOffset in table.columnDividerOffsets {
                let divX = round(origin.x + divOffset)
                if divX > box.minX + 8 && divX < box.maxX - 8 {
                    NSRect(x: divX, y: box.minY, width: 1, height: box.height).fill()
                }
            }
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

        if !tagItems.isEmpty {
            var lo = 0
            var hi = tagItems.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if NSMaxRange(tagItems[mid].fullRange) < visStart {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            for idx in lo..<tagItems.count {
                let item = tagItems[idx]
                if item.fullRange.location > visEnd { break }
                guard NSMaxRange(item.fullRange) <= totalLength else { continue }
                if isCharacterFolded(item.fullRange.location) { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: item.fullRange, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { raw, _ in
                    let pill = NSRect(
                        x: origin.x + raw.minX - 3,
                        y: origin.y + raw.minY + 1,
                        width: raw.width + 6,
                        height: max(14, raw.height - 4)
                    )
                    let path = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
                    Theme.sage.withAlphaComponent(0.14).setFill()
                    path.fill()
                    Theme.sage.withAlphaComponent(0.34).setStroke()
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

        if !horizontalRuleRanges.isEmpty {
            let ruleColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? Theme.muted
                : Theme.codeBorder
            let selected = selectedRange()
            var hrLo = 0
            var hrHi = horizontalRuleRanges.count
            while hrLo < hrHi {
                let mid = (hrLo + hrHi) >> 1
                if NSMaxRange(horizontalRuleRanges[mid]) < visStart {
                    hrLo = mid + 1
                } else {
                    hrHi = mid
                }
            }
            for hrIdx in hrLo..<horizontalRuleRanges.count {
                let range = horizontalRuleRanges[hrIdx]
                if range.location > visEnd { break }
                guard range.length > 0, NSMaxRange(range) <= totalLength else { continue }
                if isCharacterFolded(range.location) { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphRange.length > 0 else { continue }

                let fg = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                let showsSyntax = (fg != nil && fg != NSColor.clear) || NSIntersectionRange(selected, range).length > 0

                let targetGlyph = showsSyntax ? max(glyphRange.location, NSMaxRange(glyphRange) - 1) : glyphRange.location
                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: targetGlyph, effectiveRange: nil, withoutAdditionalLayout: true)
                let glyphLoc = layoutManager.location(forGlyphAt: targetGlyph)
                let hrFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                    ?? Theme.monoFont(Theme.baseProseSize - 2.0, weight: .semibold)
                let centerY = origin.y + lineFrag.minY + glyphLoc.y - hrFont.xHeight * 0.52

                let startX: CGFloat
                if showsSyntax {
                    let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: targetGlyph, effectiveRange: nil, withoutAdditionalLayout: true)
                    startX = origin.x + usedRect.maxX + 10
                } else {
                    startX = origin.x
                }
                let endX = origin.x + columnWidth
                let ruleWidth = endX - startX
                guard ruleWidth >= 8 else { continue }

                let ruleRect = NSRect(
                    x: startX,
                    y: round(centerY) - 0.75,
                    width: ruleWidth,
                    height: 1.5
                )
                let rulePath = NSBezierPath(roundedRect: ruleRect, xRadius: 0.75, yRadius: 0.75)
                ruleColor.setFill()
                rulePath.fill()
            }
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

        if !inlineImageItems.isEmpty {
            let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let sel = selectedRange()
            let isFocused = window?.firstResponder === self
            let captionParagraph = NSMutableParagraphStyle()
            captionParagraph.lineBreakMode = .byTruncatingTail
            let captionAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.bodyFont(12.0),
                .foregroundColor: Theme.muted,
                .paragraphStyle: captionParagraph
            ]
            let missingAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.monoFont(11.5, weight: .medium),
                .foregroundColor: Theme.muted,
                .paragraphStyle: captionParagraph
            ]
            for item in inlineImageItems {
                if item.fullLineRange.location > visEnd { break }
                guard NSMaxRange(item.fullLineRange) >= visStart,
                      NSMaxRange(item.fullLineRange) <= totalLength,
                      let cardRect = inlineImageCardRect(for: item),
                      cardRect.insetBy(dx: -4, dy: -28).intersects(rect) else { continue }

                let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 8, yRadius: 8)
                Theme.elevated.setFill()
                cardPath.fill()

                if item.isReadableImage,
                   let thumb = InlineImageCache.shared.thumbnail(
                       for: item.resolvedURL,
                       targetPointSize: cardRect.size,
                       backingScale: backingScale
                   ) {
                    let drawRect: NSRect
                    if let natural = item.naturalPointSize, natural.width > 0, natural.height > 0 {
                        let fit = min(1.0, min(cardRect.width / natural.width, cardRect.height / natural.height))
                        let w = min(cardRect.width, max(1, round(natural.width * fit)))
                        let h = min(cardRect.height, max(1, round(natural.height * fit)))
                        drawRect = NSRect(
                            x: round(cardRect.midX - w / 2),
                            y: round(cardRect.midY - h / 2),
                            width: w,
                            height: h
                        )
                    } else {
                        drawRect = cardRect
                    }
                    NSGraphicsContext.saveGraphicsState()
                    cardPath.addClip()
                    thumb.draw(
                        in: drawRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high]
                    )
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    let label = "Missing image · \(item.resolvedURL.lastPathComponent)" as NSString
                    let labelSize = label.size(withAttributes: missingAttrs)
                    let labelRect = NSRect(
                        x: cardRect.minX + 14,
                        y: round(cardRect.midY - labelSize.height / 2),
                        width: max(0, cardRect.width - 28),
                        height: ceil(labelSize.height)
                    )
                    label.draw(in: labelRect, withAttributes: missingAttrs)
                }

                let cursorOnItemLine = isFocused && (
                    (sel.length == 0 && sel.location >= item.lineRange.location && sel.location <= NSMaxRange(item.lineRange))
                    || NSIntersectionRange(sel, item.lineRange).length > 0
                )
                (cursorOnItemLine ? Theme.accent.withAlphaComponent(0.55) : Theme.border).setStroke()
                cardPath.lineWidth = 1.0
                cardPath.stroke()

                if let caption = item.caption, !caption.isEmpty {
                    let capNS = caption as NSString
                    let capRect = NSRect(
                        x: cardRect.minX + 2,
                        y: cardRect.maxY + 5,
                        width: max(120, columnWidth - 4),
                        height: 18
                    )
                    capNS.draw(in: capRect, withAttributes: captionAttrs)
                }
            }
        }
    }

    func inlineImageCardRect(for item: InlineImageItem) -> NSRect? {
        guard !isCharacterFolded(item.lineRange.location),
              let layoutManager = layoutManager,
              let storage = textStorage,
              NSMaxRange(item.fullLineRange) <= storage.length else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: item.fullLineRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        layoutManager.ensureLayout(forGlyphRange: glyphRange)
        let lastGlyph = NSMaxRange(glyphRange) - 1
        guard lastGlyph < layoutManager.numberOfGlyphs else { return nil }
        let lastFrag = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        guard lastFrag.height >= item.itemSlotHeight - 2 else { return nil }
        let origin = textContainerOrigin
        let slotTopY = round(origin.y + lastFrag.maxY - item.offsetFromParagraphBottom)
        return NSRect(
            x: round(origin.x),
            y: slotTopY + 8,
            width: item.displaySize.width,
            height: item.displaySize.height
        )
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
        // Avoid AppKit's insertion-point layout queries; caretLayer renders the glyph-aligned caret.
    }

    @objc(_drawInsertionPointInRect:color:)
    func _drawInsertionPoint(in rect: NSRect, color: NSColor) {}
    deinit {
        for token in windowFocusObservers { NotificationCenter.default.removeObserver(token) }
        if let token = caretAccessibilityObserver { caretAccessibilityCenter.removeObserver(token) }
        caretBlinkWorkItem?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in windowFocusObservers { NotificationCenter.default.removeObserver(token) }
        windowFocusObservers.removeAll()
        if let token = caretAccessibilityObserver { caretAccessibilityCenter.removeObserver(token) }
        caretAccessibilityObserver = nil
        cancelCaretBlink()
        removeCaretTravelAnimations()
        hasCaretOrigin = false
        wantsLayer = true
        ensureCaretSublayer()
        let nc = NotificationCenter.default
        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            windowFocusObservers.append(
                nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.onScrollBoundsChange?()
                        self.updateCaret()
                        self.setNeedsDisplay(self.visibleRect, avoidAdditionalLayout: true)
                    }
                }
            )
        }
        if let window {
            caretAccessibilityObserver = caretAccessibilityCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCaret() }
            }
            windowFocusObservers.append(
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateCaret() }
                }
            )
            windowFocusObservers.append(
                nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.onDismissLinkActionBar?()
                        self?.updateCaret()
                    }
                }
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkHoverTracking {
            removeTrackingArea(linkHoverTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        linkHoverTracking = area
    }

    func clearLinkPointerCursorState() {
        isShowingLinkPointerCursor = false
    }

    func isOccludedBySiblingOverlay(at windowPoint: NSPoint) -> Bool {
        guard let rootView = window?.contentView else { return false }
        let pointInRootSuperview = rootView.superview.map { $0.convert(windowPoint, from: nil) }
            ?? rootView.convert(windowPoint, from: nil)
        guard let hitView = rootView.hitTest(pointInRootSuperview) else { return false }
        return hitView !== self && !hitView.isDescendant(of: self)
    }

    func resolvedEditorCursor(at windowPoint: NSPoint, modifierFlags: NSEvent.ModifierFlags) -> NSCursor {
        let pt = convert(windowPoint, from: nil)
        guard bounds.contains(pt) else { return .arrow }
        if !wikiLinkItems.isEmpty || !tagItems.isEmpty || !markdownLinkItems.isEmpty || !inlineImageItems.isEmpty || !bulletItems.isEmpty {
            let overTaskCheckbox = isEditable && taskCheckbox(atPoint: pt) != nil
            let overImageCard = inlineImage(atPoint: pt) != nil
            let cmdHeld = modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            let overLink = (cmdHeld || !isEditable) && (markdownLink(atPoint: pt) != nil || wikiLink(atPoint: pt) != nil || noteTag(atPoint: pt) != nil)
            if overTaskCheckbox || overImageCard || overLink {
                return .pointingHand
            }
        }
        return .iBeam
    }

    func applyEditorCursor(at windowPoint: NSPoint, modifierFlags: NSEvent.ModifierFlags) {
        guard !isOccludedBySiblingOverlay(at: windowPoint) else {
            isShowingLinkPointerCursor = false
            return
        }
        let cursor = resolvedEditorCursor(at: windowPoint, modifierFlags: modifierFlags)
        isShowingLinkPointerCursor = (cursor === NSCursor.pointingHand)
        cursor.set()
    }

    private func refreshLinkHoverCursor(at windowPoint: NSPoint?, modifierFlags: NSEvent.ModifierFlags) {
        if wikiLinkItems.isEmpty && tagItems.isEmpty && markdownLinkItems.isEmpty && inlineImageItems.isEmpty && bulletItems.isEmpty {
            if isShowingLinkPointerCursor {
                isShowingLinkPointerCursor = false
                if let windowPoint, !isOccludedBySiblingOverlay(at: windowPoint) {
                    NSCursor.iBeam.set()
                }
            }
            return
        }
        guard let windowPoint else {
            if isShowingLinkPointerCursor {
                isShowingLinkPointerCursor = false
                NSCursor.iBeam.set()
            }
            return
        }
        if isOccludedBySiblingOverlay(at: windowPoint) {
            isShowingLinkPointerCursor = false
            return
        }
        let pt = convert(windowPoint, from: nil)
        guard bounds.contains(pt) else {
            if isShowingLinkPointerCursor {
                isShowingLinkPointerCursor = false
                NSCursor.iBeam.set()
            }
            return
        }
        let overTaskCheckbox = isEditable && taskCheckbox(atPoint: pt) != nil
        let overImageCard = inlineImage(atPoint: pt) != nil
        let cmdHeld = modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        let overLink = (cmdHeld || !isEditable) && (markdownLink(atPoint: pt) != nil || wikiLink(atPoint: pt) != nil || noteTag(atPoint: pt) != nil)
        if overTaskCheckbox || overImageCard || overLink {
            if !isShowingLinkPointerCursor {
                isShowingLinkPointerCursor = true
            }
            NSCursor.pointingHand.set()
        } else if isShowingLinkPointerCursor {
            isShowingLinkPointerCursor = false
            NSCursor.iBeam.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if isOccludedBySiblingOverlay(at: event.locationInWindow) {
            isShowingLinkPointerCursor = false
            return
        }
        if wikiLinkItems.isEmpty && tagItems.isEmpty && markdownLinkItems.isEmpty && inlineImageItems.isEmpty && bulletItems.isEmpty {
            super.mouseMoved(with: event)
            return
        }
        refreshLinkHoverCursor(at: event.locationInWindow, modifierFlags: event.modifierFlags)
        if isShowingLinkPointerCursor { return }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOccludedBySiblingOverlay(at: event.locationInWindow) {
            isShowingLinkPointerCursor = false
            return
        }
        refreshLinkHoverCursor(at: event.locationInWindow, modifierFlags: event.modifierFlags)
        if isShowingLinkPointerCursor { return }
        super.cursorUpdate(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isShowingLinkPointerCursor = false
        super.mouseExited(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        refreshLinkHoverCursor(at: window?.mouseLocationOutsideOfEventStream, modifierFlags: event.modifierFlags)
        super.flagsChanged(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshCaretAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChange?()
            updateCaret()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            vim.handleFocusLost()
            hasCaretOrigin = false
            removeCaretTravelAnimations()
            cancelCaretBlink()
            caretLayer.isHidden = true
            onFocusChange?()
        }
        return ok
    }

    func expandedLineWindow(for range: NSRange, in ns: NSString) -> NSRange {
        let totalLen = ns.length
        guard totalLen > 0 else { return NSRange(location: 0, length: 0) }
        let clampedStart = min(max(0, range.location), totalLen)
        let clampedEnd = min(totalLen, max(clampedStart, NSMaxRange(range)))
        let firstLine = ns.lineRange(for: NSRange(location: clampedStart > 0 ? clampedStart - 1 : 0, length: 0))
        let prevLineStart = firstLine.location > 0
            ? ns.lineRange(for: NSRange(location: firstLine.location - 1, length: 0)).location
            : 0
        let endProbe = min(clampedEnd, totalLen - 1)
        let lastLine = ns.lineRange(for: NSRange(location: endProbe, length: 0))
        let nextLineEnd = NSMaxRange(lastLine) < totalLen
            ? NSMaxRange(ns.lineRange(for: NSRange(location: NSMaxRange(lastLine), length: 0)))
            : totalLen
        return NSRange(location: prevLineStart, length: max(0, nextLineEnd - prevLineStart))
    }

    func rangeTouchesFenceOrTable(_ window: NSRange) -> Bool {
        guard window.location != NSNotFound else { return false }
        let wEnd = NSMaxRange(window)
        return fencedBlocks.contains(where: { window.location <= NSMaxRange($0.fullRange) && $0.fullRange.location <= wEnd })
            || tableBlocks.contains(where: { window.location <= NSMaxRange($0.fullRange) && $0.fullRange.location <= wEnd })
    }

    private func preparePendingEdit(in affectedCharRange: NSRange, replacementString: String?) {
        guard let ns = textStorage?.mutableString else { return }
        isEditingText = true
        if !foldedSections.isEmpty {
            unfoldSectionsIntersecting(affectedCharRange)
        }
        let oldLen = ns.length
        let safeLoc = min(max(0, affectedCharRange.location), oldLen)
        let safeRange = NSRange(location: safeLoc, length: min(max(0, affectedCharRange.length), oldLen - safeLoc))
        let preSelLoc = min(selectedRange().location, oldLen)
        let preSelLineLoc = oldLen > 0 ? ns.lineRange(for: NSRange(location: preSelLoc, length: 0)).location : 0
        let repNS = (replacementString ?? "") as NSString
        let repLen = repNS.length
        let delta = repLen - safeRange.length
        animatesNextCaretUpdate = isCaretTypingTransaction
            && safeRange.length <= 16 && repLen <= 64
            && !editorUndoManager.isUndoing && !editorUndoManager.isRedoing
        let isLargeEdit = safeRange.length > 4096 || repLen > 4096
        lastEditWasLarge = isLargeEdit
        var requiresFullFormat = isLargeEdit
        if !requiresFullFormat && oldLen > 0 {
            let checkRange = expandedLineWindow(for: safeRange, in: ns)
            if rangeTouchesFenceOrTable(checkRange)
                || ns.range(of: "```", options: .literal, range: checkRange).location != NSNotFound
                || ns.range(of: "|", options: .literal, range: checkRange).location != NSNotFound {
                requiresFullFormat = true
            }
        }
        if !requiresFullFormat && repLen >= 1 {
            if (repLen >= 3 && repNS.range(of: "```", options: .literal, range: NSRange(location: 0, length: repLen)).location != NSNotFound)
                || repNS.range(of: "|", options: .literal, range: NSRange(location: 0, length: repLen)).location != NSNotFound {
                requiresFullFormat = true
            }
        }
        let mayHaveLink = repLen > 0 && (repNS.range(of: "](", options: .literal).location != NSNotFound || repNS.range(of: ")", options: .literal).location != NSNotFound)
        if isLargeEdit {
            pendingEdit = EditRecord(
                affectedRange: safeRange,
                replacementLength: repLen,
                delta: delta,
                oldTotalLength: oldLen,
                windowStart: 0,
                oldWindowEnd: oldLen,
                oldWindowWords: 0,
                needsFullWordCount: true,
                requiresFullFormat: true,
                mayHaveLink: false,
                preSelectionLineLocation: preSelLineLoc
            )
        } else {
            let wStart = max(0, safeRange.location - 1)
            let wEnd = min(oldLen, NSMaxRange(safeRange) + 1)
            let oldWords = CaptureEditor.countWords(in: ns, range: NSRange(location: wStart, length: max(0, wEnd - wStart)))
            pendingEdit = EditRecord(
                affectedRange: safeRange,
                replacementLength: repLen,
                delta: delta,
                oldTotalLength: oldLen,
                windowStart: wStart,
                oldWindowEnd: wEnd,
                oldWindowWords: oldWords,
                needsFullWordCount: false,
                requiresFullFormat: requiresFullFormat,
                mayHaveLink: mayHaveLink,
                preSelectionLineLocation: preSelLineLoc
            )
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        guard ok else { return ok }
        preparePendingEdit(in: affectedCharRange, replacementString: replacementString)
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if vim.isEnabled, isEditable, vim.handleKeyEvent(event) {
            return
        }
        let previous = isHandlingTypingInput
        let previousModifiers = activeKeyDownModifiers
        let previousComposing = wasComposingMarkedTextOnKeyDown
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let scalar = event.characters?.unicodeScalars.first?.value
        activeKeyDownModifiers = modifiers.intersection([.shift, .control, .option, .command])
        wasComposingMarkedTextOnKeyDown = hasMarkedText()
        isHandlingTypingInput = !modifiers.contains(.command) && !modifiers.contains(.control)
            && scalar != nil && scalar != 9 && scalar != 27
            && !(0xF700...0xF8FF).contains(scalar ?? 0)
        defer {
            isHandlingTypingInput = previous
            activeKeyDownModifiers = previousModifiers
            wasComposingMarkedTextOnKeyDown = previousComposing
        }
        super.keyDown(with: event)
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
        let hadMarked = hasMarkedText()
        let currentMarked = hadMarked ? markedRange() : NSRange(location: NSNotFound, length: 0)
        let targetRange: NSRange
        if replacementRange.location != NSNotFound {
            targetRange = replacementRange
        } else if hadMarked, currentMarked.location != NSNotFound {
            targetRange = currentMarked
        } else {
            targetRange = selectedRange()
        }
        if hadMarked {
            unmarkText()
        }
        let previous = isCaretTypingTransaction
        isCaretTypingTransaction = previous || (isHandlingTypingInput && selectedRange().length == 0
            && targetRange == selectedRange())
        defer { isCaretTypingTransaction = previous }
        applyUndoableReplacement(in: targetRange, with: str)
    }

    override func deleteBackward(_ sender: Any?) {
        let previous = isCaretTypingTransaction
        isCaretTypingTransaction = isHandlingTypingInput && selectedRange().length == 0
        defer { isCaretTypingTransaction = previous }
        if vim.isEnabled, vim.mode == .insert, !hasMarkedText(), let ns = textStorage?.mutableString {
            let sel = selectedRange()
            if sel.length > 0 {
                applyUndoableReplacement(in: sel, with: "", selectedRangeAfter: NSRange(location: sel.location, length: 0))
                return
            } else if sel.location > 0 {
                let delRange = ns.rangeOfComposedCharacterSequence(at: sel.location - 1)
                applyUndoableReplacement(in: delRange, with: "", selectedRangeAfter: NSRange(location: delRange.location, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let previous = isCaretTypingTransaction
        isCaretTypingTransaction = isHandlingTypingInput && selectedRange().length == 0
        defer { isCaretTypingTransaction = previous }
        if vim.isEnabled, vim.mode == .insert, !hasMarkedText(), let ns = textStorage?.mutableString {
            let sel = selectedRange()
            if sel.length > 0 {
                applyUndoableReplacement(in: sel, with: "", selectedRangeAfter: NSRange(location: sel.location, length: 0))
                return
            } else if sel.location < ns.length {
                let delRange = ns.rangeOfComposedCharacterSequence(at: sel.location)
                applyUndoableReplacement(in: delRange, with: "", selectedRangeAfter: NSRange(location: sel.location, length: 0))
                return
            }
        }
        super.deleteForward(sender)
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
                vim.clampSelectionIfNeeded()
                return true
            case "c":
                copy(self)
                return true
            case "v":
                guard isEditable else { return false }
                paste(self)
                vim.clampSelectionIfNeeded()
                return true
            case "a":
                selectAll(self)
                return true
            case "z":
                guard isEditable else { return false }
                vim.flushInsertUndoIfNeeded()
                guard let um = undoManager, um.canUndo else { return false }
                um.undo()
                vim.clampSelectionIfNeeded()
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
                if let mdLink = markdownLinkAtCursor() {
                    onOpenMarkdownLink?(mdLink)
                    return true
                }
                if let tag = noteTagAtCursor() {
                    onClickTag?(tag.name)
                    return true
                }
            default:
                break
            }
        } else if flags == [.command, .shift] {
            switch key {
            case "z":
                guard isEditable else { return false }
                vim.flushInsertUndoIfNeeded()
                guard let um = undoManager, um.canRedo else { return false }
                um.redo()
                vim.clampSelectionIfNeeded()
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
            case "p":
                if let onTogglePinCurrentNote {
                    onTogglePinCurrentNote()
                    return true
                }
            case "\r", "\n":
                if let link = wikiLinkAtCursor() {
                    onOpenWikiLinkInNewWindow?(link)
                    return true
                }
                if let mdLink = markdownLinkAtCursor() {
                    onOpenMarkdownLink?(mdLink)
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
            case "\\":
                onToggleSemanticConnections?()
                return true
            default:
                break
            }
        } else if flags == .option {
            if key == "\r" || key == "\n" {
                if let link = wikiLinkAtCursor() {
                    onOpenWikiLink?(link)
                    return true
                }
                if let mdLink = markdownLinkAtCursor() {
                    onOpenMarkdownLink?(mdLink)
                    return true
                }
                if let tag = noteTagAtCursor() {
                    onClickTag?(tag.name)
                    return true
                }
            }
        } else if flags == [.command, .option, .shift] {
            if key == "\r" || key == "\n" || key == "o" {
                if let link = wikiLinkAtCursor() {
                    onOpenWikiLinkInNewWindow?(link)
                    return true
                }
                if (key == "\r" || key == "\n"), let mdLink = markdownLinkAtCursor() {
                    onOpenMarkdownLink?(mdLink)
                    return true
                }
            }
        } else if vim.isEnabled, isEditable, !hasMarkedText(),
                  flags.contains(.control), !flags.contains(.command), !flags.contains(.option) {
            if vim.handleKeyEvent(event) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func copy(_ sender: Any?) {
        autoreleasepool {
            let sel = selectedRange()
            guard sel.length > 0, let ns = textStorage?.mutableString, NSMaxRange(sel) <= ns.length else { return }
            let pb = self.pasteboard
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
        guard !shouldSuppressImplicitTextScroll else { return }
        autoreleasepool {
            super.scrollRangeToVisible(range)
        }
    }

    override func scroll(_ point: NSPoint) {
        guard !shouldSuppressImplicitTextScroll else { return }
        super.scroll(point)
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard !shouldSuppressImplicitTextScroll else { return false }
        return super.scrollToVisible(rect)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str: String
        if let s = string as? String {
            str = s
        } else if let attr = string as? NSAttributedString {
            str = attr.string
        } else {
            str = String(describing: string)
        }
        let targetRange: NSRange
        if replacementRange.location != NSNotFound {
            targetRange = replacementRange
        } else if hasMarkedText(), markedRange().location != NSNotFound {
            targetRange = markedRange()
        } else {
            targetRange = self.selectedRange()
        }
        let preGen = textChangeGeneration
        let prevApplying = isApplyingMarkedText
        let prevMinHeight = preservedViewportMinHeight
        isApplyingMarkedText = true
        if let clipView = enclosingScrollView?.contentView, clipView.bounds.origin.y > 0 {
            let floorH = max(frame.height, clipView.bounds.origin.y + clipView.bounds.height)
            if floorH > preservedViewportMinHeight {
                preservedViewportMinHeight = floorH
            }
        }
        preparePendingEdit(in: targetRange, replacementString: str)
        defer {
            isApplyingMarkedText = prevApplying
            if viewportPreservationDepth == 0 {
                preservedViewportMinHeight = prevMinHeight
            }
            if textChangeGeneration == preGen {
                pendingEdit = nil
                isEditingText = false
                lastEditWasLarge = false
                animatesNextCaretUpdate = false
            }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func selectAll(_ sender: Any?) {
        autoreleasepool {
            super.selectAll(sender)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = foldHitTargets.first(where: { $0.rect.insetBy(dx: -4, dy: -3).contains(pt) }) {
            onDismissLinkActionBar?()
            toggleFold(forHeadingAt: hit.headingLocation)
            vim.clampSelectionIfNeeded()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isEditable, !flags.contains(.control), let taskItem = taskCheckbox(atPoint: pt) {
            onDismissLinkActionBar?()
            if toggleTaskCompletion(in: taskItem.markerRange, preserveViewport: true) {
                vim.clampSelectionIfNeeded()
                return
            }
        }
        if !flags.contains(.control), let img = inlineImage(atPoint: pt) {
            onDismissLinkActionBar?()
            if flags.contains(.command) || event.clickCount >= 2 || !isEditable {
                onOpenInlineImage?(img)
                return
            }
            window?.makeFirstResponder(self)
            let totalLen = textStorage?.length ?? 0
            setSelectedRange(NSRange(location: min(NSMaxRange(img.fullRange), totalLen), length: 0))
            vim.handleMouseSelectionCompleted()
            return
        }
        if flags.contains(.command) {
            if let link = wikiLink(atPoint: pt) {
                onDismissLinkActionBar?()
                if flags.contains(.option) {
                    onOpenWikiLinkInNewWindow?(link)
                } else {
                    onOpenWikiLink?(link)
                }
                return
            }
            if let mdLink = markdownLink(atPoint: pt) {
                onOpenMarkdownLink?(mdLink)
                return
            }
            if let tag = noteTag(atPoint: pt) {
                onDismissLinkActionBar?()
                onClickTag?(tag.name)
                return
            }
        }
        let clickedMarkdownLink = (!flags.contains(.control) && event.clickCount == 1)
            ? markdownLink(atPoint: pt)
            : nil
        if clickedMarkdownLink == nil {
            onDismissLinkActionBar?()
        }
        if let tracker = customMouseSelectionTracker {
            tracker(self, event)
        } else {
            super.mouseDown(with: event)
        }
        vim.handleMouseSelectionCompleted()
        if let mdLink = clickedMarkdownLink, selectedRange().length == 0 {
            onClickMarkdownLink?(mdLink, pt)
        } else if clickedMarkdownLink != nil {
            onDismissLinkActionBar?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event)
        let pt = convert(event.locationInWindow, from: nil)
        if let img = inlineImage(atPoint: pt) {
            onDismissLinkActionBar?()
            contextMenuMarkdownLink = nil
            contextMenuInlineImage = img
            let menu = baseMenu ?? NSMenu()
            var insertIdx = 0
            let openItem = NSMenuItem(title: "Open Image", action: #selector(openContextMenuInlineImage(_:)), keyEquivalent: "")
            openItem.target = self
            menu.insertItem(openItem, at: insertIdx)
            insertIdx += 1
            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealContextMenuInlineImage(_:)), keyEquivalent: "")
            revealItem.target = self
            menu.insertItem(revealItem, at: insertIdx)
            insertIdx += 1
            if img.isReadableImage {
                let copyImgItem = NSMenuItem(title: "Copy Image", action: #selector(copyContextMenuInlineImage(_:)), keyEquivalent: "")
                copyImgItem.target = self
                menu.insertItem(copyImgItem, at: insertIdx)
                insertIdx += 1
            }
            if isEditable {
                let removeItem = NSMenuItem(title: "Remove Image", action: #selector(removeContextMenuInlineImage(_:)), keyEquivalent: "")
                removeItem.target = self
                menu.insertItem(removeItem, at: insertIdx)
                insertIdx += 1
            }
            menu.insertItem(.separator(), at: insertIdx)
            return menu
        }
        contextMenuInlineImage = nil
        guard let mdLink = markdownLink(atPoint: pt) else {
            contextMenuMarkdownLink = nil
            return baseMenu
        }
        onDismissLinkActionBar?()
        contextMenuMarkdownLink = mdLink
        let menu = baseMenu ?? NSMenu()
        let openItem = NSMenuItem(title: "Open Link", action: #selector(openContextMenuLink(_:)), keyEquivalent: "")
        openItem.target = self
        let copyItem = NSMenuItem(title: "Copy Link", action: #selector(copyContextMenuLink(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(copyItem, at: 0)
        menu.insertItem(openItem, at: 0)
        return menu
    }

    @objc private func openContextMenuInlineImage(_ sender: Any?) {
        guard let img = contextMenuInlineImage else { return }
        contextMenuInlineImage = nil
        onOpenInlineImage?(img)
    }

    @objc private func revealContextMenuInlineImage(_ sender: Any?) {
        guard let img = contextMenuInlineImage else { return }
        contextMenuInlineImage = nil
        onRevealInlineImage?(img)
    }

    @objc private func copyContextMenuInlineImage(_ sender: Any?) {
        guard let img = contextMenuInlineImage else { return }
        contextMenuInlineImage = nil
        onCopyInlineImage?(img)
    }

    @objc private func removeContextMenuInlineImage(_ sender: Any?) {
        guard isEditable, let img = contextMenuInlineImage, let storage = textStorage else { return }
        contextMenuInlineImage = nil
        let targetRange = img.isStandaloneLine ? img.fullLineRange : img.fullRange
        guard NSMaxRange(targetRange) <= storage.length else { return }
        applyUndoableReplacement(
            in: targetRange,
            with: "",
            selectedRangeAfter: NSRange(location: targetRange.location, length: 0)
        )
    }

    @objc private func openContextMenuLink(_ sender: Any?) {
        guard let link = contextMenuMarkdownLink else { return }
        contextMenuMarkdownLink = nil
        onOpenMarkdownLink?(link)
    }

    @objc private func copyContextMenuLink(_ sender: Any?) {
        guard let link = contextMenuMarkdownLink else { return }
        contextMenuMarkdownLink = nil
        onCopyMarkdownLink?(link)
    }

    func inlineImage(atPoint pt: NSPoint) -> InlineImageItem? {
        guard !inlineImageItems.isEmpty else { return nil }
        for item in inlineImageItems {
            guard let cardRect = inlineImageCardRect(for: item) else { continue }
            if cardRect.contains(pt) {
                return item
            }
        }
        return nil
    }

    func taskCheckbox(atPoint pt: NSPoint) -> BulletItem? {
        guard !bulletItems.isEmpty,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              let storage = textStorage else { return nil }
        let totalLength = storage.length
        let origin = textContainerOrigin
        let containerPt = NSPoint(x: pt.x - origin.x, y: pt.y - origin.y)
        for item in bulletItems {
            guard case .task = item.kind else { continue }
            if isCharacterFolded(item.lineRange.location) { continue }
            guard item.markerRange.length > 0, NSMaxRange(item.markerRange) <= totalLength else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: item.markerRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            var matched = false
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, stop in
                if rect.insetBy(dx: -4, dy: -3).contains(containerPt) {
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

    func noteTag(atPoint pt: NSPoint) -> NoteTag? {
        guard !tagItems.isEmpty,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              let storage = textStorage else { return nil }
        let totalLength = storage.length
        let origin = textContainerOrigin
        let containerPt = NSPoint(x: pt.x - origin.x, y: pt.y - origin.y)
        for item in tagItems {
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

    func markdownLink(atPoint pt: NSPoint) -> MarkdownLink? {
        guard !markdownLinkItems.isEmpty,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              let storage = textStorage else { return nil }
        let totalLength = storage.length
        let origin = textContainerOrigin
        let containerPt = NSPoint(x: pt.x - origin.x, y: pt.y - origin.y)
        for item in markdownLinkItems {
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

    func enclosingRect(for link: MarkdownLink, preferredPoint: NSPoint? = nil) -> NSRect? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer,
              let storage = textStorage,
              NSMaxRange(link.fullRange) <= storage.length,
              !isCharacterFolded(link.fullRange.location) else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: link.fullRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let origin = textContainerOrigin
        let preferredContainerPt = preferredPoint.map { NSPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        var firstRect: NSRect?
        var matchedRect: NSRect?
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, stop in
            if firstRect == nil {
                firstRect = rect
            }
            if let pt = preferredContainerPt, rect.insetBy(dx: -4, dy: -3).contains(pt) {
                matchedRect = rect
                stop.pointee = true
            }
        }
        guard let chosen = matchedRect ?? firstRect else { return nil }
        return chosen.offsetBy(dx: origin.x, dy: origin.y)
    }

    override func cancelOperation(_ sender: Any?) {
        if let handler = onWikiAutocompleteCommand, handler(#selector(NSResponder.cancelOperation(_:))) {
            return
        }
        if let cancelLink = onCancelLinkActionBar, cancelLink() {
            return
        }
        nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
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

    override func insertNewline(_ sender: Any?) {
        if let handler = onWikiAutocompleteCommand, handler(#selector(NSResponder.insertNewline(_:))) {
            return
        }
        if handleListContinuationOnNewline() {
            return
        }
        super.insertNewline(sender)
    }

    private func handleListContinuationOnNewline() -> Bool {
        guard isEditable,
              !hasMarkedText(),
              !wasComposingMarkedTextOnKeyDown,
              (activeKeyDownModifiers ?? []).isEmpty,
              let ns = textStorage?.mutableString else {
            return false
        }
        let sel = selectedRange()
        guard sel.length == 0, sel.location >= 0, sel.location <= ns.length else {
            return false
        }

        var lineStart = 0
        var lineEnd = 0
        var contentEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentEnd, for: NSRange(location: sel.location, length: 0))
        guard contentEnd > lineStart, sel.location == contentEnd else {
            return false
        }

        if CaptureEditor.isHorizontalRuleLine(ns, lineStart: lineStart, contentEnd: contentEnd) {
            return false
        }

        var p = lineStart
        while p < contentEnd {
            let ch = ns.character(at: p)
            if ch == 0x20 || ch == 0x09 {
                p += 1
            } else {
                break
            }
        }
        guard p < contentEnd else { return false }

        let indentRange = NSRange(location: lineStart, length: p - lineStart)
        let markerStart = p
        let markerEnd: Int
        let nextMarker: String
        let mc = ns.character(at: markerStart)
        if mc == 0x2D {
            markerEnd = markerStart + 1
            nextMarker = "-"
        } else if mc == 0x2A {
            markerEnd = markerStart + 1
            nextMarker = "*"
        } else if mc == 0x2B {
            markerEnd = markerStart + 1
            nextMarker = "+"
        } else if mc >= 0x30 && mc <= 0x39 {
            var dEnd = markerStart
            while dEnd < contentEnd {
                let d = ns.character(at: dEnd)
                if d >= 0x30 && d <= 0x39 {
                    dEnd += 1
                } else {
                    break
                }
            }
            guard dEnd > markerStart, dEnd < contentEnd, ns.character(at: dEnd) == 0x2E else {
                return false
            }
            markerEnd = dEnd + 1
            let digits = ns.substring(with: NSRange(location: markerStart, length: dEnd - markerStart))
            nextMarker = Self.incrementDecimalDigits(digits) + "."
        } else {
            return false
        }

        guard markerEnd < contentEnd, ns.character(at: markerEnd) == 0x20 else {
            return false
        }

        // Exclude task / checklist items (`- [ ]`, `- [x]`, `- [X]`, `1. [ ]`, etc.).
        var wsAfterMarker = markerEnd
        while wsAfterMarker < contentEnd {
            let ch = ns.character(at: wsAfterMarker)
            if ch == 0x20 || ch == 0x09 {
                wsAfterMarker += 1
            } else {
                break
            }
        }
        if wsAfterMarker > markerEnd, wsAfterMarker + 3 <= contentEnd,
           ns.character(at: wsAfterMarker) == 0x5B,
           ns.character(at: wsAfterMarker + 2) == 0x5D {
            let boxChar = ns.character(at: wsAfterMarker + 1)
            let afterBox = wsAfterMarker + 3
            if (boxChar == 0x20 || boxChar == 0x78 || boxChar == 0x58),
               (afterBox == contentEnd || ns.character(at: afterBox) == 0x20 || ns.character(at: afterBox) == 0x09) {
                return false
            }
        }

        if isLineInsideFencedCode(ns, lineStart: lineStart)
            || tableBlocks.contains(where: { lineStart >= $0.fullRange.location && lineStart < NSMaxRange($0.fullRange) }) {
            return false
        }

        var hasBodyContent = false
        var bIdx = markerEnd + 1
        while bIdx < contentEnd {
            let ch = ns.character(at: bIdx)
            if ch != 0x20 && ch != 0x09 {
                hasBodyContent = true
                break
            }
            bIdx += 1
        }

        if !hasBodyContent {
            let removeRange = NSRange(location: markerStart, length: contentEnd - markerStart)
            applyUndoableReplacement(
                in: removeRange,
                with: "",
                selectedRangeAfter: NSRange(location: markerStart, length: 0)
            )
            return true
        }

        let newline: String
        if lineEnd - contentEnd >= 2,
           ns.character(at: contentEnd) == 13,
           ns.character(at: contentEnd + 1) == 10 {
            newline = "\r\n"
        } else if lineEnd == contentEnd,
                  lineStart >= 2,
                  ns.character(at: lineStart - 2) == 13,
                  ns.character(at: lineStart - 1) == 10 {
            newline = "\r\n"
        } else {
            newline = "\n"
        }

        let indent = indentRange.length > 0 ? ns.substring(with: indentRange) : ""
        let insertion = newline + indent + nextMarker + " "
        let nextCaret = NSRange(location: sel.location + (insertion as NSString).length, length: 0)
        applyUndoableReplacement(
            in: NSRange(location: sel.location, length: 0),
            with: insertion,
            selectedRangeAfter: nextCaret
        )
        return true
    }

    private func isLineInsideFencedCode(_ ns: NSString, lineStart: Int) -> Bool {
        if fencedBlocks.contains(where: { lineStart >= $0.fullRange.location && lineStart < NSMaxRange($0.fullRange) }) {
            return true
        }
        guard lineStart > 0 else { return false }
        let prefixRange = NSRange(location: 0, length: lineStart)
        if ns.range(of: "```", options: .literal, range: prefixRange).location == NSNotFound,
           ns.range(of: "~~~", options: .literal, range: prefixRange).location == NSNotFound {
            return false
        }
        var openChar: unichar = 0
        var openLen = 0
        var pos = 0
        while pos < lineStart {
            var lStart = 0
            var lEnd = 0
            var cEnd = 0
            ns.getLineStart(&lStart, end: &lEnd, contentsEnd: &cEnd, for: NSRange(location: pos, length: 0))
            pos = max(pos + 1, lEnd)
            var leadSpaces = 0
            var fp = lStart
            while fp < cEnd, ns.character(at: fp) == 0x20 {
                leadSpaces += 1
                if leadSpaces > 3 { break }
                fp += 1
            }
            guard leadSpaces <= 3, fp < cEnd else { continue }
            let fc = ns.character(at: fp)
            guard fc == 0x60 || fc == 0x7E else { continue }
            var runEnd = fp
            while runEnd < cEnd, ns.character(at: runEnd) == fc {
                runEnd += 1
            }
            let runLen = runEnd - fp
            guard runLen >= 3 else { continue }
            if openChar == 0 {
                if fc == 0x60 {
                    var hasBacktickInInfo = false
                    var k = runEnd
                    while k < cEnd {
                        if ns.character(at: k) == 0x60 {
                            hasBacktickInInfo = true
                            break
                        }
                        k += 1
                    }
                    if hasBacktickInInfo { continue }
                }
                openChar = fc
                openLen = runLen
            } else if openChar == fc, runLen >= openLen {
                var onlyTrailingWS = true
                var k = runEnd
                while k < cEnd {
                    let ch = ns.character(at: k)
                    if ch != 0x20 && ch != 0x09 {
                        onlyTrailingWS = false
                        break
                    }
                    k += 1
                }
                if onlyTrailingWS {
                    openChar = 0
                    openLen = 0
                }
            }
        }
        return openChar != 0
    }

    private static func incrementDecimalDigits(_ digits: String) -> String {
        if let value = UInt64(digits), value < UInt64.max {
            return String(value + 1)
        }
        var bytes = Array(digits.utf8).drop(while: { $0 == 0x30 })
        if bytes.isEmpty {
            return "1"
        }
        var idx = bytes.endIndex
        var carry = true
        while idx > bytes.startIndex, carry {
            bytes.formIndex(before: &idx)
            if bytes[idx] < 0x39 {
                bytes[idx] += 1
                carry = false
            } else {
                bytes[idx] = 0x30
            }
        }
        var result = String(decoding: bytes, as: UTF8.self)
        if carry {
            result = "1" + result
        }
        return result
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
        let foldStart = NSMaxRange(headingLineRange)
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

    func foldedRangeEnclosing(_ charIndex: Int) -> NSRange? {
        guard !foldedSections.isEmpty else { return nil }
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
                return r
            }
        }
        return nil
    }

    @objc func foldHeadingAtCursor(_ sender: Any?) {
        guard let idx = headingIndex(atOrEnclosing: selectedRange().location, requireSameLine: false) else { return }
        let headingLocation = headingGutterItems[idx].range.location
        guard foldedSections.firstIndex(where: { $0.headingLocation == headingLocation }) == nil else { return }
        toggleFold(forHeadingAt: headingLocation)
    }

    @objc func foldAllHeadings(_ sender: Any?) {
        guard !headingGutterItems.isEmpty else { return }
        var nextFolds: [FoldedSection] = []
        for idx in headingGutterItems.indices {
            if let section = computeFoldedSection(forHeadingIndex: idx, bodyOnly: true) {
                nextFolds.append(section)
            }
        }
        let oldFolds = foldedSections
        foldedSections = nextFolds
        outlineFoldMode = nextFolds.isEmpty ? .showAll : .headingsOnly
        clampSelectionOutsideFolds()
        invalidateFoldLayout(forChangedRanges: Self.symmetricDifferenceRanges(from: oldFolds, to: nextFolds))
        onFoldStatusChange?(outlineFoldMode == .headingsOnly ? "Outline: Headings Only" : "Outline: Show All")
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

    func refreshFoldLayoutAfterGeometryChange(visibleCharacterRange: NSRange?) {
        guard !foldedSections.isEmpty, let lm = layoutManager, let tc = textContainer,
              let ns = textStorage?.mutableString else { return }
        let visible: NSRange
        if let visibleCharacterRange {
            visible = visibleCharacterRange
        } else {
            let rect = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
            lm.ensureLayout(forBoundingRect: rect, in: tc)
            let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: tc)
            guard glyphs.length > 0 else { return }
            visible = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        var start = ns.length
        var end = 0
        for fold in foldedSections {
            if fold.headingLocation > NSMaxRange(visible) { break }
            let foldEnd = NSMaxRange(fold.foldedCharRange)
            guard foldEnd >= visible.location else { continue }
            lm.invalidateLayout(forCharacterRange: fold.foldedCharRange, actualCharacterRange: nil)
            start = min(start, fold.headingLocation)
            let followingLineEnd = foldEnd < ns.length
                ? NSMaxRange(ns.lineRange(for: NSRange(location: foldEnd, length: 0)))
                : ns.length
            end = max(end, followingLineEnd)
        }
        guard end > start else { return }
        lm.ensureLayout(forCharacterRange: NSRange(location: start, length: end - start))
    }

    /// Full-document attribute resets can leave cached visible line fragments for folded bodies.
    /// Re-invalidate every fold so the typesetter restores hidden layout without moving the viewport.
    func refreshFoldLayoutAfterFullFormat() {
        guard !foldedSections.isEmpty else { return }
        invalidateFoldLayout(forChangedRanges: foldedSections.map(\.foldedCharRange), scrollCaretIntoView: false)
    }

    private func invalidateFoldLayout(forChangedRanges ranges: [NSRange], scrollCaretIntoView: Bool = true) {
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
        lm.invalidateLayout(forCharacterRange: span, actualCharacterRange: nil)
        if totalLen <= 65_536 {
            lm.ensureLayout(for: tc)
        } else if let scrollView = enclosingScrollView {
            let clipView = scrollView.contentView
            if scrollCaretIntoView, !foldedSections.isEmpty {
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
            let visInContainer = clipView.documentVisibleRect.offsetBy(
                dx: -textContainerOrigin.x,
                dy: -textContainerOrigin.y
            )
            lm.ensureLayout(forBoundingRect: visInContainer, in: tc)
        } else {
            lm.ensureLayout(for: tc)
        }
        if scrollCaretIntoView {
            minimumOverscrollHeight = 0
        }
        updateCaret()
        setNeedsDisplay(bounds, avoidAdditionalLayout: true)
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
            let clip = self.pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    func noteTagAtCursor() -> NoteTag? {
        let sel = selectedRange()
        if let item = tagItems.first(where: {
            !isCharacterFolded($0.fullRange.location)
                && sel.location >= $0.fullRange.location
                && sel.location <= NSMaxRange($0.fullRange)
        }) {
            return item
        }
        return nil
    }

    func markdownLinkAtCursor() -> MarkdownLink? {
        let sel = selectedRange()
        return markdownLinkItems.first { item in
            !isCharacterFolded(item.fullRange.location)
                && sel.location >= item.fullRange.location
                && sel.location <= NSMaxRange(item.fullRange)
        }
    }

    @objc func openWikiLinkAtCursor(_ sender: Any?) {
        if let link = wikiLinkAtCursor() {
            onOpenWikiLink?(link)
        } else if let mdLink = markdownLinkAtCursor() {
            onOpenMarkdownLink?(mdLink)
        } else if let tag = noteTagAtCursor() {
            onClickTag?(tag.name)
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

    private static let taskCheckboxToggleRegex = try! NSRegularExpression(
        pattern: "(?m)^([ \\t]*(?:[-*+]|\\d+\\.)\\s+\\[)([ xX])(\\])"
    )

    @discardableResult
    func toggleTaskCompletion(in range: NSRange, preserveViewport: Bool = false) -> Bool {
        guard isEditable, let ns = textStorage?.mutableString, ns.length > 0 else { return false }
        let safeLoc = min(max(0, range.location), ns.length)
        let safeRange = NSRange(location: safeLoc, length: min(range.length, ns.length - safeLoc))
        let lineSpan = ns.lineRange(for: safeRange)
        guard lineSpan.length > 0 else { return false }
        let block = ns.substring(with: lineSpan)
        let blockNS = block as NSString
        let matches = Self.taskCheckboxToggleRegex.matches(
            in: block,
            range: NSRange(location: 0, length: blockNS.length)
        )
        guard !matches.isEmpty else { return false }
        let allChecked = matches.allSatisfy { m in
            let state = blockNS.substring(with: m.range(at: 2))
            return state == "x" || state == "X"
        }
        let nextState = allChecked ? " " : "x"
        let mutable = NSMutableString(string: block)
        for m in matches.reversed() {
            mutable.replaceCharacters(in: m.range(at: 2), with: nextState)
        }
        let updated = mutable as String
        guard updated != block else { return false }
        let preservedLoc = min(selectedRange().location, ns.length)
        applyUndoableReplacement(
            in: lineSpan,
            with: updated,
            selectedRangeAfter: NSRange(location: preservedLoc, length: 0),
            preserveViewport: preserveViewport
        )
        return true
    }

    func configureUndoHooks() {
        editorUndoManager.onWillUndoOrRedo = { [weak self] in
            self?.vim.flushInsertUndoIfNeeded()
        }
        editorUndoManager.onDidUndoOrRedo = { [weak self] in
            self?.vim.clampSelectionIfNeeded()
        }
    }

    func resetUndoHistory() {
        editorUndoManager.removeAllActions()
        editorUndoManager.levelsOfUndo = Self.defaultUndoLevels
    }

    func registerCoalescedUndo(inverseRange: NSRange, previousString: String, restoreSelection: NSRange) {
        breakUndoCoalescing()
        editorUndoManager.registerUndo(withTarget: self) { target in
            target.applyUndoableReplacement(in: inverseRange, with: previousString, selectedRangeAfter: restoreSelection)
        }
    }

    func applyUndoableReplacement(
        in range: NSRange,
        with replacement: String,
        selectedRangeAfter: NSRange? = nil,
        preserveViewport: Bool = false,
        redoSelectionOverride: NSRange? = nil
    ) {
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
            let nextSelection = selectedRangeAfter ?? NSRange(location: safeRange.location + repLen, length: 0)
            if safeRange.length > 256_000 || repLen > 256_000 {
                editorUndoManager.levelsOfUndo = 2
            }
            let absorbedByVimInsert = !editorUndoManager.isUndoing
                && !editorUndoManager.isRedoing
                && vim.recordMutationInInsertSession(
                    safeRange: safeRange,
                    previousString: previousString,
                    replacementLength: repLen,
                    selectionBefore: previousSelection
                )
            if !absorbedByVimInsert {
                let inverseRange = NSRange(location: safeRange.location, length: repLen)
                let restoreSelection = redoSelectionOverride ?? (selectedRangeAfter != nil ? previousSelection : nil)
                let nextRedoOverride = selectedRangeAfter != nil ? nextSelection : nil
                editorUndoManager.registerUndo(withTarget: self) { target in
                    target.applyUndoableReplacement(
                        in: inverseRange,
                        with: previousString,
                        selectedRangeAfter: restoreSelection,
                        preserveViewport: preserveViewport,
                        redoSelectionOverride: nextRedoOverride
                    )
                }
            }

            let performReplacement = {
                let clipView = self.enclosingScrollView?.contentView
                let savedOriginY = clipView?.bounds.origin.y
                let savedVisHeight = clipView?.bounds.height ?? 0
                let savedMinHeight = (savedOriginY ?? 0) > 0
                    ? max(self.frame.height, (savedOriginY ?? 0) + savedVisHeight)
                    : 0

                let wasEmpty = storage.length == 0
                self.editorUndoManager.disableUndoRegistration()
                self.viewportPreservationDepth += 1
                if savedMinHeight > self.preservedViewportMinHeight {
                    self.preservedViewportMinHeight = savedMinHeight
                }
                storage.beginEditing()
                storage.replaceCharacters(in: safeRange, with: replacement)
                if wasEmpty && repLen > 0 && !self.typingAttributes.isEmpty {
                    storage.setAttributes(self.typingAttributes, range: NSRange(location: 0, length: repLen))
                }
                storage.endEditing()
                self.viewportPreservationDepth -= 1
                if self.viewportPreservationDepth == 0 {
                    self.preservedViewportMinHeight = 0
                }
                self.editorUndoManager.enableUndoRegistration()

                if let clipView, let savedOriginY, abs(clipView.bounds.origin.y - savedOriginY) > 0.01 {
                    clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: savedOriginY))
                }

                self.setSelectedRange(nextSelection)
                let prevSuppress = self.suppressCaretUpdates
                if preserveViewport {
                    self.suppressCaretUpdates = true
                }
                self.didChangeText()
                if preserveViewport {
                    self.suppressCaretUpdates = prevSuppress
                }
            }

            if preserveViewport {
                preservingViewport(performReplacement)
                updateCaret(animateForTyping: false)
            } else {
                performReplacement()
            }
        }
    }

    private func currentSelectedLineRange() -> NSRange {
        guard let ns = textStorage?.mutableString, ns.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let loc = min(selectedRange().location, ns.length)
        return ns.lineRange(for: NSRange(location: loc, length: 0))
    }

    override func didChangeText() {
        textChangeGeneration &+= 1
        let wasLarge = lastEditWasLarge
        let editLocation = pendingEdit?.affectedRange.location
        let preSelLineLocation = pendingEdit?.preSelectionLineLocation
        let animateCaret = animatesNextCaretUpdate
        animatesNextCaretUpdate = false
        lastEditWasLarge = false
        isEditingText = false
        super.didChangeText()
        if wasLarge, (textStorage?.length ?? 0) > 65_536 {
            cancelCaretBlink()
            removeCaretTravelAnimations()
            caretLayer.isHidden = true
            hasCaretOrigin = false
        } else {
            if isApplyingMarkedText && viewportPreservationDepth == 0 {
                preservedViewportMinHeight = 0
            }
            updateCaret(animateForTyping: animateCaret)
            if !wasLarge && !suppressCaretUpdates {
                // Same-line edits must not recenter a caret already visible near a viewport edge.
                let useTypewriterStep: Bool
                if let ns = textStorage?.mutableString {
                    let caretLine = ns.lineRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
                    if let editLocation {
                        let editLine = ns.lineRange(for: NSRange(location: min(editLocation, ns.length), length: 0))
                        useTypewriterStep = editLine.location != caretLine.location
                            || (preSelLineLocation != nil && preSelLineLocation != caretLine.location)
                    } else if let preSelLineLocation {
                        useTypewriterStep = preSelLineLocation != caretLine.location
                    } else {
                        useTypewriterStep = false
                    }
                } else {
                    useTypewriterStep = false
                }
                ensureCaretVisible(useTypewriterStep: useTypewriterStep)
            }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !suppressCaretUpdates && !isEditingText else { return }
        updateCaret()
    }

    override func doCommand(by selector: Selector) {
        if let handler = onWikiAutocompleteCommand, handler(selector) {
            return
        }
        let preGen = textChangeGeneration
        let preLine = currentSelectedLineRange()
        let previous = isCaretTypingTransaction
        isCaretTypingTransaction = isHandlingTypingInput && selectedRange().length == 0
            && (selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.deleteBackward(_:))
                || selector == #selector(NSResponder.deleteForward(_:)))
        defer { isCaretTypingTransaction = previous }
        super.doCommand(by: selector)
        guard !suppressCaretUpdates && !isEditingText,
              window?.firstResponder === self else { return }
        var didAdjustForFold = false
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
                didAdjustForFold = true
            }
        }
        if selectedRange().length == 0, (textChangeGeneration == preGen || didAdjustForFold) {
            let postLine = currentSelectedLineRange()
            ensureCaretVisible(useTypewriterStep: didAdjustForFold || preLine != postLine)
        }
    }

    func resetCaretPosition() {
        hasCaretOrigin = false
        animatesNextCaretUpdate = false
        minimumOverscrollHeight = 0
        foldedSections.removeAll()
        externalChangeRanges.removeAll()
        outlineFoldMode = .showAll
        foldHitTargets.removeAll()
        caretLayer.removeAllAnimations()
    }

    /// Ensures the active insertion caret stays inside the visible viewport comfort zone.
    /// When the caret moves below the fold, scrolls up with a ~30% viewport typewriter breathing margin below the cursor.
    func ensureCaretVisible(useTypewriterStep: Bool = true) {
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

        let currentY = clipView.bounds.origin.y
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

        guard abs(desiredY - currentY) > 0.01 else { return }
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: desiredY))
        scrollView.reflectScrolledClipView(clipView)
        updateCaret()
    }

    func scrollCursorLine(alignment: VimScrollAlignment) {
        guard !suppressCaretUpdates, let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let visHeight = clipView.bounds.height
        guard visHeight > 40 else { return }
        let caret = currentCaretRect()
        guard caret.height > 0 else { return }
        let desiredY: CGFloat
        switch alignment {
        case .center:
            desiredY = max(0, round(caret.midY - visHeight * 0.5))
        case .top:
            desiredY = max(0, round(caret.minY - max(18, visHeight * 0.06)))
        case .bottom:
            desiredY = max(0, round(caret.maxY - visHeight + max(24, visHeight * 0.08)))
        }
        let requiredDocHeight = desiredY + visHeight
        if requiredDocHeight > minimumOverscrollHeight {
            minimumOverscrollHeight = requiredDocHeight
        }
        if frame.height < requiredDocHeight {
            setFrameSize(NSSize(width: frame.width, height: requiredDocHeight))
        }
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: desiredY))
        scrollView.reflectScrolledClipView(clipView)
        updateCaret()
    }

    func scrollByHalfPages(_ halfPages: Int) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        let ns = storage.mutableString
        guard ns.length > 0 else { return 0 }
        guard let scrollView = enclosingScrollView, scrollView.contentView.bounds.height > 60 else {
            // Fallback when not in an active scroll viewport: step ~12 lines per half-page
            var pos = min(selectedRange().location, ns.length)
            let steps = abs(halfPages) * 12
            if halfPages > 0 {
                for _ in 0..<steps {
                    let lr = ns.lineRange(for: NSRange(location: min(pos, ns.length - 1), length: 0))
                    guard NSMaxRange(lr) < ns.length else { pos = lr.location; break }
                    pos = NSMaxRange(lr)
                }
            } else {
                for _ in 0..<steps {
                    let lr = ns.lineRange(for: NSRange(location: min(pos, ns.length - 1), length: 0))
                    guard lr.location > 0 else { pos = 0; break }
                    pos = ns.lineRange(for: NSRange(location: lr.location - 1, length: 0)).location
                }
            }
            return pos
        }
        let clipView = scrollView.contentView
        let visHeight = clipView.bounds.height
        let oldY = clipView.bounds.origin.y
        let caretBefore = currentCaretRect()
        let relY = min(max(24.0, caretBefore.midY - oldY), visHeight - 24.0)
        let deltaY = max(60.0, round(visHeight * 0.5)) * CGFloat(halfPages)
        if ns.length <= 100_000 {
            lm.ensureLayout(for: tc)
        }
        let maxScrollY = max(0, bounds.height - visHeight)
        let nextY = min(max(0, oldY + deltaY), maxScrollY)
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
        let visInContainer = clipView.documentVisibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        lm.ensureLayout(forBoundingRect: visInContainer, in: tc)
        let probePt = NSPoint(x: 4.0, y: max(0, nextY + relY - textContainerOrigin.y))
        let glyphIdx = lm.glyphIndex(for: probePt, in: tc, fractionOfDistanceThroughGlyph: nil)
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        updateCaret()
        return min(charIdx, ns.length)
    }

    func viewportLineTarget(_ target: VimViewportTarget) -> Int? {
        guard let scrollView = enclosingScrollView,
              let lm = layoutManager,
              let tc = textContainer,
              let storage = textStorage,
              storage.length > 0 else { return nil }
        let vis = scrollView.contentView.documentVisibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        guard vis.height > 20 else { return nil }
        lm.ensureLayout(forBoundingRect: vis, in: tc)
        let visGlyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: vis, in: tc)
        guard visGlyphs.length > 0 else { return nil }
        var visibleStarts: [Int] = []
        lm.enumerateLineFragments(forGlyphRange: visGlyphs) { rect, _, _, glyphRange, _ in
            guard rect.height > 0.5, rect.maxY > vis.minY + 2, rect.minY < vis.maxY - 2 else { return }
            let ch = lm.characterIndexForGlyph(at: glyphRange.location)
            if visibleStarts.last != ch {
                visibleStarts.append(ch)
            }
        }
        guard !visibleStarts.isEmpty else { return nil }
        switch target {
        case .top:
            return visibleStarts[0]
        case .middle:
            return visibleStarts[visibleStarts.count / 2]
        case .bottom:
            return visibleStarts[visibleStarts.count - 1]
        }
    }

    func visualLineVerticalTarget(from location: Int, deltaLines: Int, preferredX: inout CGFloat?) -> Int? {
        guard deltaLines != 0,
              let lm = layoutManager,
              let tc = textContainer,
              let storage = textStorage,
              storage.length > 0 else { return nil }
        let ns = storage.mutableString
        let totalLen = ns.length
        let clampedLoc = min(max(0, location), totalLen - 1)
        let winStart = max(0, clampedLoc - 2000)
        let winEnd = min(totalLen, clampedLoc + 2000)
        lm.ensureLayout(forCharacterRange: ns.lineRange(for: NSRange(location: winStart, length: winEnd - winStart)))
        let totalGlyphs = lm.numberOfGlyphs
        guard totalGlyphs > 0 else { return nil }
        let startGlyph = min(lm.glyphIndexForCharacter(at: clampedLoc), totalGlyphs - 1)
        var fragRange = NSRange(location: 0, length: 0)
        let startFrag = lm.lineFragmentRect(forGlyphAt: startGlyph, effectiveRange: &fragRange)
        let targetX: CGFloat
        if let px = preferredX {
            targetX = px
        } else {
            let locPt = lm.location(forGlyphAt: startGlyph)
            let computed = startFrag.minX + locPt.x
            preferredX = computed
            targetX = computed
        }

        var currentFrag = startFrag
        var remaining = abs(deltaLines)
        while remaining > 0 {
            if deltaLines > 0 {
                var probe = NSMaxRange(fragRange)
                var found = false
                while probe < lm.numberOfGlyphs {
                    var nextRange = NSRange(location: 0, length: 0)
                    let rect = lm.lineFragmentRect(forGlyphAt: probe, effectiveRange: &nextRange)
                    if rect.height > 0.5 {
                        fragRange = nextRange
                        currentFrag = rect
                        found = true
                        break
                    }
                    probe = max(probe + 1, NSMaxRange(nextRange))
                }
                if !found { break }
            } else {
                guard fragRange.location > 0 else { break }
                var probe = fragRange.location - 1
                var found = false
                while probe >= 0 {
                    var prevRange = NSRange(location: 0, length: 0)
                    let rect = lm.lineFragmentRect(forGlyphAt: probe, effectiveRange: &prevRange)
                    if rect.height > 0.5 {
                        fragRange = prevRange
                        currentFrag = rect
                        found = true
                        break
                    }
                    if prevRange.location == 0 { break }
                    probe = prevRange.location - 1
                }
                if !found { break }
            }
            remaining -= 1
        }

        let charSpan = lm.characterRange(forGlyphRange: fragRange, actualGlyphRange: nil)
        var contentEnd = min(NSMaxRange(charSpan), totalLen)
        while contentEnd > charSpan.location {
            let u = ns.character(at: contentEnd - 1)
            if u == 10 || u == 13 { contentEnd -= 1 } else { break }
        }
        guard contentEnd > charSpan.location else { return charSpan.location }
        let hitChar = lm.characterIndex(
            for: NSPoint(x: targetX, y: currentFrag.midY),
            in: tc,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        let maxChar = ns.rangeOfComposedCharacterSequence(at: contentEnd - 1).location
        return min(max(charSpan.location, hitChar), maxChar)
    }

    func visualLineBoundary(from location: Int, kind: VimVisualBoundaryKind) -> Int? {
        guard let lm = layoutManager,
              let storage = textStorage,
              storage.length > 0 else { return nil }
        let ns = storage.mutableString
        let totalLen = ns.length
        let clamped = min(max(0, location), totalLen - 1)
        lm.ensureLayout(forCharacterRange: ns.lineRange(for: NSRange(location: clamped, length: 0)))
        guard lm.numberOfGlyphs > 0 else { return nil }
        let glyphIdx = min(lm.glyphIndexForCharacter(at: clamped), lm.numberOfGlyphs - 1)
        var fragGlyphs = NSRange(location: 0, length: 0)
        _ = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &fragGlyphs)
        let charSpan = lm.characterRange(forGlyphRange: fragGlyphs, actualGlyphRange: nil)
        var contentEnd = min(NSMaxRange(charSpan), totalLen)
        while contentEnd > charSpan.location {
            let u = ns.character(at: contentEnd - 1)
            if u == 10 || u == 13 { contentEnd -= 1 } else { break }
        }
        switch kind {
        case .start:
            return charSpan.location
        case .firstNonBlank:
            var p = charSpan.location
            while p < contentEnd {
                let u = ns.character(at: p)
                if u == 0x20 || u == 0x09 { p += 1 } else { break }
            }
            return p < contentEnd ? p : charSpan.location
        case .end:
            guard contentEnd > charSpan.location else { return charSpan.location }
            return ns.rangeOfComposedCharacterSequence(at: contentEnd - 1).location
        }
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
            switch vim.cursorShape {
            case .beam:
                caretLayer.backgroundColor = insertionPointColor.cgColor
                caretLayer.borderWidth = 0
                caretLayer.borderColor = nil
                caretLayer.cornerRadius = 1.0
            case .block:
                let accent = Theme.accent
                let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                caretLayer.backgroundColor = accent.withAlphaComponent(highContrast ? 0.42 : 0.30).cgColor
                caretLayer.borderWidth = 1.0
                caretLayer.borderColor = accent.withAlphaComponent(highContrast ? 0.95 : 0.82).cgColor
                caretLayer.cornerRadius = 2.0
            case .underline:
                caretLayer.backgroundColor = Theme.accent.cgColor
                caretLayer.borderWidth = 0
                caretLayer.borderColor = nil
                caretLayer.cornerRadius = 1.0
            }
        }
    }

    /// Computes the exact glyph-aligned caret rect in view coordinates, excluding trailing lineSpacing/paragraphSpacing.
    func currentCaretRect() -> NSRect {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return .zero }
        let origin = textContainerOrigin
        let ns = storage.mutableString
        let len = ns.length
        let rawLoc = vim.activeBlockCursorLocation ?? selectedRange().location
        let charIdx = min(max(0, rawLoc), len)
        let shape = vim.cursorShape
        if len > 0 {
            let ensureLoc = min(charIdx, len - 1)
            let lineRange = ns.lineRange(for: NSRange(location: ensureLoc, length: 0))
            if len <= 100_000 {
                // Small notes can use exact preceding geometry; large notes retain bounded lazy layout.
                lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(lineRange)))
            } else {
                lm.ensureLayout(forCharacterRange: lineRange)
            }
        }

        let fallbackFont = (typingAttributes[.font] as? NSFont) ?? font ?? Theme.bodyFont()
        let fallbackPara = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        let sampleFont: NSFont
        let samplePara: NSParagraphStyle?
        var activeLineContentEnd = 0

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
            activeLineContentEnd = lineContentEnd
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
        let paraSpacing = samplePara?.paragraphSpacing ?? 0

        let glyphIdx = lm.glyphIndexForCharacter(at: charIdx)
        let raw = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 0), in: tc)
        var rawHeight = raw.height > 0 ? raw.height : fontLineHeight
        if paraSpacing > 16, rawHeight - paraSpacing >= fontLineHeight - 2 {
            rawHeight -= paraSpacing
        }
        let trimmedHeight = (lineSpacing > 0 && rawHeight - lineSpacing >= fontLineHeight - 1)
            ? (rawHeight - lineSpacing)
            : rawHeight
        let height = max(14, round(trimmedHeight))
        var x = round((origin.x + raw.minX) * 2) / 2
        let y = round((origin.y + raw.minY) * 2) / 2

        if shape == .beam {
            return NSRect(x: x, y: y, width: 2.0, height: height)
        }

        var cellWidth = max(8.5, round(sampleFont.pointSize * 0.56))
        if len > 0, charIdx < activeLineContentEnd, !isCharacterFolded(charIdx) {
            let seqRange = ns.rangeOfComposedCharacterSequence(at: charIdx)
            let charGlyphs = lm.glyphRange(forCharacterRange: seqRange, actualCharacterRange: nil)
            if charGlyphs.length > 0 {
                let charBox = lm.boundingRect(forGlyphRange: charGlyphs, in: tc)
                if charBox.width > 1.0 {
                    x = round((origin.x + charBox.minX) * 2) / 2
                    cellWidth = max(6.0, ceil(charBox.width))
                }
            }
        }

        if shape == .underline {
            let underlineHeight: CGFloat = 2.5
            return NSRect(x: x, y: y + height - underlineHeight, width: cellWidth, height: underlineHeight)
        }
        return NSRect(x: x, y: y, width: cellWidth, height: height)
    }

    func updateCaret(animateForTyping: Bool = false) {
        guard !suppressCaretUpdates else { return }
        ensureCaretSublayer()
        let isActive = window?.firstResponder === self && (window?.isKeyWindow ?? false) && isEditable
        let sel = selectedRange()
        let shape = vim.cursorShape
        let showCaret = isActive && (sel.length == 0 || vim.activeBlockCursorLocation != nil)
        guard showCaret else {
            cancelCaretBlink()
            removeCaretTravelAnimations()
            caretLayer.isHidden = true
            if sel.length > 0 { hasCaretOrigin = false }
            return
        }

        let targetRect = currentCaretRect()
        guard targetRect.height > 0 else { return }
        let targetPos = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let targetBounds = CGRect(x: 0, y: 0, width: targetRect.width, height: targetRect.height)
        let oldPosition = caretLayer.position
        let oldBounds = caretLayer.bounds
        let dx = oldPosition.x - targetPos.x
        let dy = oldPosition.y - targetPos.y
        let canAnimate = shape == .beam && animateForTyping && hasCaretOrigin && !caretLayer.isHidden
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !hasMarkedText()
            && abs(dx) <= max(96, targetRect.height * 4) && abs(dy) <= targetRect.height * 1.5
        if !canAnimate { removeCaretTravelAnimations() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caretLayer.isHidden = false
        caretLayer.opacity = 1.0
        caretLayer.position = targetPos
        caretLayer.bounds = targetBounds
        CATransaction.commit()

        if canAnimate {
            caretAnimationSequence &+= 1
            // Existing additive springs retain their presentation offset and velocity on rapid typing.
            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                let travel = makeCaretSpring(keyPath: "position")
                travel.fromValue = NSValue(point: NSPoint(x: dx, y: dy))
                travel.toValue = NSValue(point: .zero)
                caretLayer.add(travel, forKey: "caret.position.\(caretAnimationSequence)")
            }
            let widthDelta = oldBounds.width - targetBounds.width
            let heightDelta = oldBounds.height - targetBounds.height
            if abs(widthDelta) > 0.01 || abs(heightDelta) > 0.01 {
                let resize = makeCaretSpring(keyPath: "bounds")
                resize.fromValue = NSValue(rect: NSRect(x: 0, y: 0, width: widthDelta, height: heightDelta))
                resize.toValue = NSValue(rect: .zero)
                caretLayer.add(resize, forKey: "caret.bounds.\(caretAnimationSequence)")
            }
        }

        hasCaretOrigin = true
        if shape == .beam {
            scheduleCaretBlink()
        } else {
            cancelCaretBlink()
            caretLayer.opacity = 1.0
        }
    }

    private func makeCaretSpring(keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.isAdditive = true
        spring.mass = 1
        spring.stiffness = Self.caretSpringStiffness
        spring.damping = Self.caretSpringDamping
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        return spring
    }

    private func removeCaretTravelAnimations() {
        guard let keys = caretLayer.animationKeys() else { return }
        for key in keys where key.hasPrefix("caret.position.") || key.hasPrefix("caret.bounds.") {
            caretLayer.removeAnimation(forKey: key)
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
        guard vim.cursorShape == .beam, !caretLayer.isHidden, window?.firstResponder === self, window?.isKeyWindow == true else { return }
        caretBlinkOn.toggle()
        let targetOpacity: Float = caretBlinkOn ? 1.0 : 0.08
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = caretLayer.presentation()?.opacity ?? caretLayer.opacity
        fade.toValue = targetOpacity
        fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.16
        fade.timingFunction = Theme.feedbackTimingFunction
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
            let pb = self.pasteboard
            let targetRange = selectedRange()
            if pb.types?.contains(.fileURL) == true,
               let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                onFiles?(urls, targetRange, CaptureEditor.isPointerAction)
            } else if pb.availableType(from: [.string]) == nil,
                      let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                onClipboardImage?(png, targetRange, CaptureEditor.isPointerAction)
            } else {
                let str: String?
                if pb.changeCount == lastClipboardChangeCount && lastClipboardLength >= 0 {
                    str = lastClipboardString
                } else {
                    str = pb.string(forType: .string)
                }
                if let str {
                    applyUndoableReplacement(in: targetRange, with: str)
                } else {
                    pasteAsPlainText(sender)
                }
            }
        }
    }

    func dropInsertionRange(atViewPoint viewPt: NSPoint) -> NSRange {
        let totalLen = textStorage?.length ?? 0
        guard totalLen > 0 else { return NSRange(location: 0, length: 0) }
        for item in inlineImageItems {
            if let cardRect = inlineImageCardRect(for: item), cardRect.contains(viewPt) {
                let loc = viewPt.y < cardRect.midY ? item.lineRange.location : NSMaxRange(item.fullLineRange)
                return NSRange(location: min(max(0, loc), totalLen), length: 0)
            }
        }
        var charIdx = min(max(0, characterIndexForInsertion(at: viewPt)), totalLen)
        if let fold = foldedSections.first(where: { NSLocationInRange(charIdx, $0.foldedCharRange) }) {
            charIdx = min(totalLen, NSMaxRange(fold.foldedCharRange))
        }
        return NSRange(location: charIdx, length: 0)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        if pb.availableType(from: [.string]) == nil,
           pb.availableType(from: [.png, .tiff]) != nil {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let viewPt = convert(sender.draggingLocation, from: nil)
        let targetRange = dropInsertionRange(atViewPoint: viewPt)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls, targetRange, true)
            return true
        }
        if pb.availableType(from: [.string]) == nil,
           let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            onClipboardImage?(png, targetRange, true)
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
        let tagName: String?

        init(title: String, subtitle: String, isCreateNew: Bool, noteURL: URL?, tagName: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.isCreateNew = isCreateNew
            self.noteURL = noteURL
            self.tagName = tagName
        }
    }

    var headerTitle: String = "LINK TO NOTE" {
        didSet {
            if headerTitle != oldValue {
                needsDisplay = true
            }
        }
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
        (headerTitle as NSString).draw(at: NSPoint(x: 12, y: 6), withAttributes: headerAttrs)
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
            let isTagItem = (item.tagName != nil)

            if isSelected {
                let selPath = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6)
                Theme.selectionFill.setFill()
                selPath.fill()
                let barRect = NSRect(x: rowRect.minX + 2, y: rowRect.minY + 6, width: 2.5, height: rowRect.height - 12)
                (isTagItem ? Theme.sage : Theme.accent).setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
            }

            let titleText: String
            if isTagItem {
                titleText = item.isCreateNew ? "Use #\(item.title)" : "#\(item.title)"
            } else {
                titleText = item.isCreateNew ? "Create “\(item.title)”" : item.title
            }
            let titleColor: NSColor
            if isTagItem {
                titleColor = item.isCreateNew ? Theme.sage : (isSelected ? Theme.headingInk : Theme.sage)
            } else {
                titleColor = item.isCreateNew ? Theme.accent : (isSelected ? Theme.headingInk : Theme.ink)
            }
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: isTagItem
                    ? Theme.monoFont(12.0, weight: isSelected ? .semibold : .medium)
                    : NSFont.systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .medium),
                .foregroundColor: titleColor,
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

@MainActor final class LinkActionBarView: NSView {
    static let barHeight: CGFloat = 34
    private static let maxURLLabelWidth: CGFloat = 216
    private static let minURLLabelWidth: CGFloat = 64

    let urlLabel = NSTextField(labelWithString: "")
    let openButton = QuietButton(title: "Open", symbol: "arrow.up.right.square")
    let copyButton = QuietButton(title: "Copy", symbol: "doc.on.doc")

    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCursorExit: ((NSEvent) -> Void)?
    var isInteractive = true

    private(set) var isShowingCopied = false
    private var fixedCopyButtonWidth: CGFloat = 78
    private var cursorTracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = 1001
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Link actions")

        urlLabel.font = Theme.monoFont(11, weight: .regular)
        urlLabel.textColor = Theme.muted
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.maximumNumberOfLines = 1
        urlLabel.isEditable = false
        urlLabel.isSelectable = false
        urlLabel.isBordered = false
        urlLabel.drawsBackground = false

        openButton.tint = Theme.accent
        openButton.hoverCursor = .pointingHand
        openButton.refusesFirstResponder = true
        openButton.target = self
        openButton.action = #selector(handleOpen)
        openButton.toolTip = "Open link in browser (⌘-Click)"
        openButton.setAccessibilityLabel("Open link")
        openButton.onHoverCursorExit = { [weak self] event in
            self?.handleChildButtonCursorExit(event)
        }

        copyButton.tint = Theme.headingInk
        copyButton.hoverCursor = .pointingHand
        copyButton.refusesFirstResponder = true
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        copyButton.toolTip = "Copy link URL to clipboard"
        copyButton.setAccessibilityLabel("Copy link")
        copyButton.onHoverCursorExit = { [weak self] event in
            self?.handleChildButtonCursorExit(event)
        }

        let copyNormalWidth = ceil(copyButton.intrinsicContentSize.width)
        copyButton.title = "Copied"
        copyButton.setSymbol("checkmark")
        let copyConfirmedWidth = ceil(copyButton.intrinsicContentSize.width)
        fixedCopyButtonWidth = max(copyNormalWidth, copyConfirmedWidth)
        copyButton.title = "Copy"
        copyButton.setSymbol("doc.on.doc")

        addSubview(urlLabel)
        addSubview(openButton)
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return nil }
        return super.hitTest(point)
    }

    // Absorb clicks on pill chrome so they neither drag the window nor pass through to the editor.
    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking {
            removeTrackingArea(cursorTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    func resolvedCursor(at localPoint: NSPoint) -> NSCursor {
        if openButton.isEnabled && !openButton.isHidden && openButton.frame.contains(localPoint) {
            return openButton.hoverCursor ?? .pointingHand
        }
        if copyButton.isEnabled && !copyButton.isHidden && copyButton.frame.contains(localPoint) {
            return copyButton.hoverCursor ?? .pointingHand
        }
        return .arrow
    }

    @discardableResult
    func applyCursor(forWindowPoint windowPoint: NSPoint) -> Bool {
        guard isInteractive && !isHidden else { return false }
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else { return false }
        resolvedCursor(at: localPoint).set()
        return true
    }

    private func handleChildButtonCursorExit(_ event: NSEvent) {
        if !applyCursor(forWindowPoint: event.locationInWindow) {
            onCursorExit?(event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        _ = applyCursor(forWindowPoint: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        _ = applyCursor(forWindowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        _ = applyCursor(forWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        if !applyCursor(forWindowPoint: event.locationInWindow) {
            onCursorExit?(event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isInteractive && !isHidden, bounds.width > 0, bounds.height > 0 else { return }
        let openRect = openButton.frame.intersection(bounds)
        let copyRect = copyButton.frame.intersection(bounds)
        let sortedButtons = [openRect, copyRect]
            .filter { !$0.isNull && !$0.isEmpty }
            .sorted { $0.minX < $1.minX }

        var currentX = bounds.minX
        for btnRect in sortedButtons {
            if btnRect.minX > currentX {
                addCursorRect(
                    NSRect(x: currentX, y: bounds.minY, width: btnRect.minX - currentX, height: bounds.height),
                    cursor: .arrow
                )
            }
            if btnRect.minY > bounds.minY {
                addCursorRect(
                    NSRect(x: btnRect.minX, y: bounds.minY, width: btnRect.width, height: btnRect.minY - bounds.minY),
                    cursor: .arrow
                )
            }
            if btnRect.maxY < bounds.maxY {
                addCursorRect(
                    NSRect(x: btnRect.minX, y: btnRect.maxY, width: btnRect.width, height: bounds.maxY - btnRect.maxY),
                    cursor: .arrow
                )
            }
            currentX = max(currentX, btnRect.maxX)
        }
        if currentX < bounds.maxX {
            addCursorRect(
                NSRect(x: currentX, y: bounds.minY, width: bounds.maxX - currentX, height: bounds.height),
                cursor: .arrow
            )
        }
    }

    @objc private func handleOpen() {
        onOpen?()
    }

    @objc private func handleCopy() {
        onCopy?()
    }

    func configure(url: URL, copied: Bool) {
        let display = url.absoluteString
        urlLabel.stringValue = display
        urlLabel.toolTip = display
        setCopiedState(copied)
        needsLayout = true
        needsDisplay = true
    }

    func setCopiedState(_ copied: Bool) {
        isShowingCopied = copied
        if copied {
            copyButton.title = "Copied"
            copyButton.setSymbol("checkmark")
            copyButton.tint = Theme.sage
            copyButton.setAccessibilityLabel("Copied link")
        } else {
            copyButton.title = "Copy"
            copyButton.setSymbol("doc.on.doc")
            copyButton.tint = Theme.headingInk
            copyButton.setAccessibilityLabel("Copy link")
        }
        copyButton.needsDisplay = true
    }

    func preferredSize() -> NSSize {
        let font = urlLabel.font ?? Theme.monoFont(11, weight: .regular)
        let rawLabelW = ceil((urlLabel.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4
        let labelW = min(Self.maxURLLabelWidth, max(Self.minURLLabelWidth, rawLabelW))
        let openW = ceil(openButton.intrinsicContentSize.width)
        let width = 11 + labelW + 8 + 1 + 4 + openW + 3 + 1 + 4 + fixedCopyButtonWidth + 5
        return NSSize(width: ceil(width), height: Self.barHeight)
    }

    override func layout() {
        super.layout()
        let buttonHeight: CGFloat = 26
        let buttonY = floor((bounds.height - buttonHeight) / 2)
        let copyX = bounds.width - 5 - fixedCopyButtonWidth
        let div2X = copyX - 4
        let openW = ceil(openButton.intrinsicContentSize.width)
        let openX = div2X - 1 - 3 - openW
        let div1X = openX - 4
        let labelX: CGFloat = 11
        let labelW = max(24, div1X - 1 - 8 - labelX)
        let font = urlLabel.font ?? Theme.monoFont(11, weight: .regular)
        let labelH = ceil(font.ascender - font.descender) + 2
        let labelY = floor((bounds.height - labelH) / 2)

        urlLabel.frame = NSRect(x: labelX, y: labelY, width: labelW, height: labelH)
        openButton.frame = NSRect(x: openX, y: buttonY, width: openW, height: buttonHeight)
        copyButton.frame = NSRect(x: copyX, y: buttonY, width: fixedCopyButtonWidth, height: buttonHeight)
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let cardRect = bounds.insetBy(dx: 1, dy: 1)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 9, yRadius: 9)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 9
        shadow.set()
        Theme.selectionFill.setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        cardPath.addClip()
        Theme.topHighlight.withAlphaComponent(0.55).setFill()
        NSRect(x: cardRect.minX + 8, y: cardRect.maxY - 1.5, width: max(0, cardRect.width - 16), height: 1).fill()

        let copyX = bounds.width - 5 - fixedCopyButtonWidth
        let div2X = copyX - 4
        let openW = ceil(openButton.intrinsicContentSize.width)
        let openX = div2X - 1 - 3 - openW
        let div1X = openX - 4
        let dividerColor = (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Theme.muted : Theme.border).withAlphaComponent(0.85)
        dividerColor.setFill()
        NSRect(x: div1X, y: 8, width: 1, height: max(0, bounds.height - 16)).fill()
        NSRect(x: div2X, y: 8, width: 1, height: max(0, bounds.height - 16)).fill()
        NSGraphicsContext.restoreGraphicsState()

        (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Theme.muted : Theme.codeBorder).setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        urlLabel.textColor = Theme.muted
        openButton.tint = Theme.accent
        copyButton.tint = isShowingCopied ? Theme.sage : Theme.headingInk
        needsDisplay = true
    }
}

@MainActor final class InNoteFindBar: NSView, NSSearchFieldDelegate {
    let searchBar = CozySearchBar()
    let countLabel = Theme.label("", size: 10, color: Theme.subtle)
    var onQueryChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
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
            } else if let onCommit {
                onCommit()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            // Field editors treat the single-line query as the whole document; AppKit's
            // moveToEndOfDocument is a no-op there, so route ⌘↓ to the line end.
            textView.moveToEndOfLine(nil)
            return true
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            textView.moveToBeginningOfLine(nil)
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

    nonisolated static let railWidth: CGFloat = 228
    nonisolated static let rowHeight: CGFloat = 30

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
        closeButton.toolTip = "Hide Outline (⌥⌘\\)"
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

    func scrollActiveRowIntoView() {
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
    let vimPendingLabel = Theme.label("", size: 10.5, color: Theme.accent)
    let vimModePill = VimModePill(frame: .zero)
    let wordCount = Theme.label("", size: 10.5, color: Theme.subtle)
    var allowsVimMode = false {
        didSet {
            if allowsVimMode != oldValue {
                syncVimModePreference()
            }
        }
    }
    var isVimActive: Bool { allowsVimMode && Theme.vimModeEnabled }
    private(set) var vimSearchDirection: VimSearchDirection = .forward
    private var vimSearchWholeWord = false
    private var isVimSearchingPrompt = false
    private var vimSearchOriginLocation: Int = 0
    var onChange: (() -> Void)?
    var onAttachFiles: (([URL], NSRange?) -> Void)?
    var onRemoveLinkedAttachment: ((LinkedAttachment) -> Void)?
    var onHorizontalInsetChange: ((CGFloat) -> Void)?
    var onOpenWikiLink: ((WikiLink) -> Void)?
    var onOpenWikiLinkInNewWindow: ((WikiLink) -> Void)?
    var onClickTag: ((String) -> Void)?
    var urlOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var pasteboard: NSPasteboard = .general {
        didSet { textView.pasteboard = pasteboard }
    }
    var onOpenCurrentNoteInNewWindow: (() -> Void)?
    var onTogglePinCurrentNote: (() -> Void)?
    var onQuickSwitcher: (() -> Void)?
    var onOutlineVisibilityChange: ((Bool) -> Void)?
    var onSemanticVisibilityChange: ((Bool) -> Void)?
    var noteRecordsProvider: (() -> [NoteRecord])?
    var currentNoteURLProvider: (() -> URL?)?
    var vaultRootURLProvider: (() -> URL?)?
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
    let semanticView = SemanticConnectionsView(frame: .zero)
    private let footerRule = HairlineView()
    private let footer = NSStackView()
    private var attachmentLeading: NSLayoutConstraint?
    private var attachmentTrailing: NSLayoutConstraint?
    private var attachmentHeight: NSLayoutConstraint?
    private var attachmentBottom: NSLayoutConstraint?
    private var semanticHeight: NSLayoutConstraint?
    private var semanticBottom: NSLayoutConstraint?
    private(set) var isSemanticConnectionsVisible = false
    private var footerLeading: NSLayoutConstraint?
    private var footerTrailing: NSLayoutConstraint?
    private var previews: [URL: NSImage] = [:]
    private var temporaryFiles: [URL] = []
    private var isFormatting = false
    private var lastCursorLine = NSRange(location: NSNotFound, length: 0)
    private let wikiCompletionView = WikiLinkCompletionView(frame: .zero)
    let linkActionBar = LinkActionBarView(frame: .zero)
    private(set) var isLinkActionBarVisible = false
    private(set) var activeLinkActionItem: MarkdownTextView.MarkdownLink?
    private var activeLinkPreferredPoint: NSPoint?
    private var linkActionGeneration: UInt64 = 0
    let inNoteFindBar = InNoteFindBar(frame: .zero)
    nonisolated static let outlineTotalWidth: CGFloat = DocumentOutlineView.railWidth + 1
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
            vimSearchWholeWord = false
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
    private let angleAutolink = try! NSRegularExpression(pattern: "<((?:[a-zA-Z][a-zA-Z0-9+.-]*://|mailto:)[^<>\\s]+)>", options: [.caseInsensitive])
    private let bareURL = try! NSRegularExpression(pattern: "(?:https?://|mailto:)[^\\s<>\"\\x60]+", options: [.caseInsensitive])
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
        textView.configureUndoHooks()
        textView.vim.host = self
        let typesetter = FoldTypesetter()
        typesetter.textView = textView
        textView.layoutManager?.typesetter = typesetter
        textView.registerForDraggedTypes(textView.acceptableDragTypes + [.fileURL, .png, .tiff])
        textView.onFiles = { [weak self] urls, insertionRange, animated in
            self?.addAttachments(urls, at: insertionRange, animated: animated)
        }
        textView.onClipboardImage = { [weak self] data, insertionRange, animated in
            self?.addClipboardImage(data, at: insertionRange, animated: animated)
        }
        textView.onFocusChange = { [weak self] in self?.handleFocusChange() }
        textView.onFoldStatusChange = { [weak self] msg in
            self?.hideLinkActionBar(animated: false)
            self?.status.stringValue = msg
            self?.refreshOutline()
        }
        textView.onOpenWikiLink = { [weak self] link in self?.onOpenWikiLink?(link) }
        textView.onOpenWikiLinkInNewWindow = { [weak self] link in self?.onOpenWikiLinkInNewWindow?(link) }
        textView.onClickTag = { [weak self] tag in self?.onClickTag?(tag) }
        textView.onOpenMarkdownLink = { [weak self] link in self?.openMarkdownLink(link) }
        textView.onClickMarkdownLink = { [weak self] link, pt in self?.showLinkActionBar(for: link, preferredPoint: pt) }
        textView.onCopyMarkdownLink = { [weak self] link in self?.copyMarkdownLink(link, fromActionBar: false) }
        textView.onOpenInlineImage = { [weak self] img in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: img.resolvedURL.path) {
                _ = self.urlOpener(img.resolvedURL)
            } else {
                self.status.stringValue = "Image file not found: \(img.resolvedURL.lastPathComponent)"
            }
        }
        textView.onRevealInlineImage = { [weak self] img in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: img.resolvedURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([img.resolvedURL])
            } else {
                self.status.stringValue = "Image file not found: \(img.resolvedURL.lastPathComponent)"
            }
        }
        textView.onCopyInlineImage = { [weak self] img in
            guard let self, let nsImg = NSImage(contentsOf: img.resolvedURL) else { return }
            let pb = self.pasteboard
            pb.clearContents()
            pb.writeObjects([nsImg])
            self.status.stringValue = "Copied image to clipboard"
        }
        textView.onDismissLinkActionBar = { [weak self] in self?.hideLinkActionBar(animated: true) }
        textView.onCancelLinkActionBar = { [weak self] in
            guard let self, self.isLinkActionBarVisible else { return false }
            self.hideLinkActionBar(animated: true)
            return true
        }
        textView.onScrollBoundsChange = { [weak self] in
            guard let self, self.isLinkActionBarVisible else { return }
            self.positionLinkActionBar()
        }
        textView.onOpenCurrentNoteInNewWindow = { [weak self] in self?.onOpenCurrentNoteInNewWindow?() }
        textView.onTogglePinCurrentNote = { [weak self] in self?.onTogglePinCurrentNote?() }
        textView.onInsertWikiLinkShortcut = { [weak self] in self?.handleInsertWikiLinkShortcut() }
        textView.onQuickSwitcher = { [weak self] in self?.onQuickSwitcher?() }
        textView.onShowInNoteFind = { [weak self] in self?.showInNoteFind() }
        textView.onFindNextInNote = { [weak self] in self?.findNextInNote() }
        textView.onFindPreviousInNote = { [weak self] in self?.findPreviousInNote() }
        textView.onToggleOutline = { [weak self] in self?.toggleOutline() }
        textView.onToggleSemanticConnections = { [weak self] in self?.toggleSemanticConnections() }
        inNoteFindBar.isHidden = true
        inNoteFindBar.onQueryChange = { [weak self] _ in
            self?.vimSearchWholeWord = false
            self?.updateInNoteFindMatches(scrollToMatch: true)
        }
        inNoteFindBar.onCommit = { [weak self] in
            guard let self else { return }
            if self.isVimActive && self.isVimSearchingPrompt {
                self.commitVimSearchFromFindBar()
            } else {
                self.findNextInNote()
            }
        }
        inNoteFindBar.onNext = { [weak self] in self?.findNextInNote() }
        inNoteFindBar.onPrevious = { [weak self] in self?.findPreviousInNote() }
        inNoteFindBar.onClose = { [weak self] in self?.hideInNoteFind() }
        outlineView.isHidden = true
        outlineDivider.isHidden = true
        outlineView.onSelectItem = { [weak self] idx in self?.jumpToHeading(at: idx) }
        outlineView.onToggleFoldItem = { [weak self] idx in self?.toggleFoldForOutlineItem(at: idx) }
        outlineView.onCycleFoldMode = { [weak self] in
            self?.textView.cycleOutlineFolding(nil)
            self?.textView.vim.clampSelectionIfNeeded()
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
        linkActionBar.isHidden = true
        linkActionBar.onOpen = { [weak self] in
            guard let self, let link = self.activeLinkActionItem else { return }
            self.openMarkdownLink(link)
        }
        linkActionBar.onCopy = { [weak self] in
            guard let self, let link = self.activeLinkActionItem else { return }
            self.copyMarkdownLink(link, fromActionBar: true)
        }
        linkActionBar.onCursorExit = { [weak self] event in
            self?.syncCursor(atWindowPoint: event.locationInWindow, modifierFlags: event.modifierFlags)
        }
        semanticView.isHidden = true
        semanticView.wantsLayer = true
        semanticView.onPreferredHeightChange = { [weak self] in
            self?.syncSemanticStripHeight()
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
        vimPendingLabel.font = Theme.monoFont(10.5, weight: .semibold)
        vimPendingLabel.textColor = Theme.accent
        vimPendingLabel.setContentHuggingPriority(.required, for: .horizontal)
        vimPendingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        vimPendingLabel.isHidden = true
        vimModePill.isHidden = true
        wordCount.font = Theme.monoFont(10.5, weight: .medium)
        wordCount.setContentHuggingPriority(.required, for: .horizontal)

        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 10
        chips.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        chips.translatesAutoresizingMaskIntoConstraints = false
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
        for item in [add, status, spacer, vimPendingLabel, vimModePill, wordCount] { footer.addArrangedSubview(item) }

        for view in [scroll, outlineDivider, outlineView, attachmentScroll, semanticView, footerRule, footer, inNoteFindBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(wikiCompletionView)
        addSubview(linkActionBar)
        let attachLead = attachmentScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36)
        let attachTrail = attachmentScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36)
        let footLead = footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36)
        let footTrail = footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36)
        let attachHeight = attachmentScroll.heightAnchor.constraint(equalToConstant: 0)
        let attachBottom = attachmentScroll.bottomAnchor.constraint(equalTo: semanticView.topAnchor, constant: 0)
        let semHeight = semanticView.heightAnchor.constraint(equalToConstant: 0)
        let semBottom = semanticView.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: 0)
        let scrollTrailEditor = scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        let scrollTrailOutline = scroll.trailingAnchor.constraint(equalTo: outlineDivider.leadingAnchor)
        attachmentLeading = attachLead
        attachmentTrailing = attachTrail
        attachmentHeight = attachHeight
        attachmentBottom = attachBottom
        semanticHeight = semHeight
        semanticBottom = semBottom
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
            outlineDivider.bottomAnchor.constraint(equalTo: semanticView.topAnchor),
            outlineDivider.widthAnchor.constraint(equalToConstant: 1),
            outlineDivider.trailingAnchor.constraint(equalTo: outlineView.leadingAnchor),
            outlineView.topAnchor.constraint(equalTo: topAnchor),
            outlineView.bottomAnchor.constraint(equalTo: semanticView.topAnchor),
            outlineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            outlineView.widthAnchor.constraint(equalToConstant: DocumentOutlineView.railWidth),
            attachLead,
            attachTrail,
            attachHeight,
            attachBottom,
            semanticView.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            semanticView.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            semHeight,
            semBottom,
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
        // Snapshot the viewport before changing geometry; estimated post-resize layout can contain gaps.
        let visibleCharacters: NSRange?
        if !textView.foldedSections.isEmpty, let lm = textView.layoutManager, let tc = textView.textContainer {
            let rect = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
            let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: tc)
            visibleCharacters = glyphs.length > 0 ? lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil) : nil
        } else {
            visibleCharacters = nil
        }
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
            if !textView.tableBlocks.isEmpty || !textView.inlineImageItems.isEmpty {
                formatMarkdown()
            }
            if let anchorChar, let lm = textView.layoutManager, let storage = textView.textStorage, storage.length > 0 {
                let ns = storage.mutableString as NSString
                let start = max(0, anchorChar - 2400)
                let end = min(ns.length, anchorChar + 4200)
                let windowRange = ns.lineRange(for: NSRange(location: start, length: end - start))
                lm.ensureLayout(forCharacterRange: windowRange)
                let glyphIdx = lm.glyphIndexForCharacter(at: min(anchorChar, ns.length - 1))
                let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 0), in: container)
                let rawTargetY = max(0, rect.minY + textView.textContainerOrigin.y)
                let docHeight = textView.bounds.height
                let targetY = docHeight > clipView.bounds.height
                    ? min(rawTargetY, max(0, docHeight - clipView.bounds.height))
                    : rawTargetY
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
            textView.refreshFoldLayoutAfterGeometryChange(visibleCharacterRange: visibleCharacters)
            textView.updateCaret()
            textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
            if isWikiAutocompleteVisible {
                positionWikiCompletionView()
            }
            if isLinkActionBarVisible {
                positionLinkActionBar()
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
                hideLinkActionBar(animated: false)
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
                textView.resetUndoHistory()
                textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
                if isVimActive {
                    textView.vim.resetForLoadedDocument(isEmpty: newLen == 0)
                }
                updateVimChrome()
                let ns = nsText
                lastCursorLine = ns.length > 0 ? ns.lineRange(for: NSRange(location: min(textView.selectedRange().location, ns.length), length: 0)) : NSRange(location: 0, length: 0)
                textView.suppressCaretUpdates = false
                textView.refreshCaretAppearance()
                textView.updateCaret()
                textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
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
    func preserveReadingPosition(during updates: () -> Void) {
        let clipView = scroll.contentView
        let origin = clipView.bounds.origin
        let anchorInWindow = textView.convert(origin, to: nil)
        updates()
        (window?.contentView ?? self).layoutSubtreeIfNeeded()
        let anchorAfter = textView.convert(anchorInWindow, from: nil)
        let target = NSPoint(
            x: max(0, clipView.bounds.origin.x + origin.x - anchorAfter.x),
            y: max(0, clipView.bounds.origin.y + origin.y - anchorAfter.y)
        )
        clipView.setBoundsOrigin(target)
        scroll.reflectScrolledClipView(clipView)
    }

    func clearPendingAttachments() {
        if !attachments.isEmpty { attachments = [] }
        if !temporaryFiles.isEmpty {
            for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
            temporaryFiles.removeAll()
        }
    }
    func reset() {
        hideWikiAutocomplete()
        hideLinkActionBar(animated: false)
        hideInNoteFind()
        text = ""
        linkedAttachments = []
        clearPendingAttachments()
        status.stringValue = ""
    }
    func textDidChange(_ notification: Notification) {
        autoreleasepool {
            if isLinkActionBarVisible {
                hideLinkActionBar(animated: false)
            }
            let edit = textView.pendingEdit
            textView.pendingEdit = nil
            let didTouchAttributes: Bool
            if let edit {
                lastScanResult = nil
                textView.shiftExternalChangeRanges(for: edit.affectedRange, delta: edit.delta)
            }
            var shouldFullFormat = edit?.requiresFullFormat ?? true
            if !shouldFullFormat, let edit, let storage = textView.textStorage {
                let ns = storage.mutableString as NSString
                let startLoc = min(edit.affectedRange.location, ns.length)
                let insertedRange = NSRange(
                    location: startLoc,
                    length: min(edit.replacementLength, max(0, ns.length - startLoc))
                )
                let postWindow = textView.expandedLineWindow(for: insertedRange, in: ns)
                if postWindow.length > 0,
                   ns.range(of: "```", options: .literal, range: postWindow).location != NSNotFound
                    || ns.range(of: "|", options: .literal, range: postWindow).location != NSNotFound {
                    shouldFullFormat = true
                }
            }
            if let edit, !shouldFullFormat {
                didTouchAttributes = formatIncrementalEdit(edit)
            } else {
                if let edit, edit.delta != 0 {
                    textView.shiftFoldedSections(from: NSMaxRange(edit.affectedRange), by: edit.delta)
                }
                formatMarkdown()
                didTouchAttributes = true
            }
            if didTouchAttributes, textView.hasMarkedText(), let storage = textView.textStorage {
                let mRange = textView.markedRange()
                if mRange.location != NSNotFound, mRange.length > 0, NSMaxRange(mRange) <= storage.length {
                    let attrs = textView.markedTextAttributes ?? [.underlineStyle: NSUnderlineStyle.single.rawValue]
                    textView.preservingViewport {
                        textView.undoManager?.disableUndoRegistration()
                        storage.addAttributes(attrs, range: mRange)
                        textView.undoManager?.enableUndoRegistration()
                    }
                }
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
            if didTouchAttributes || edit != nil {
                textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
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
        if isLinkActionBarVisible, let activeLink = activeLinkActionItem {
            if sel.length > 0 || sel.location < activeLink.fullRange.location || sel.location > NSMaxRange(activeLink.fullRange) {
                hideLinkActionBar(animated: true)
            }
        }
        let activeOpenLoc = Vault.activeWikiLinkQuery(inNSString: ns, cursorLocation: sel.location)?.replacementRange.location
            ?? Vault.activeTagQuery(inNSString: ns, cursorLocation: sel.location)?.replacementRange.location
        if isWikiAutocompleteVisible {
            if sel.length > 0 || activeOpenLoc != activeWikiOpenLocation {
                hideWikiAutocomplete()
            }
        } else if let dismissed = dismissedWikiOpenLocation {
            if activeOpenLoc != dismissed {
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
    func addAttachments(_ urls: [URL], at insertionRange: NSRange? = nil, animated: Bool = false) {
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
        performAttachmentChange(animated: animated) {
            if let onAttachFiles {
                onAttachFiles(valid, insertionRange)
            } else {
                for url in valid where !attachments.contains(url) {
                    attachments.append(url)
                }
                onChange?()
            }
        }
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
        let animated = Self.isPointerAction
        let targetRange = textView.selectedRange()
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.addAttachments(panel.urls, at: targetRange, animated: animated) }
        }
    }
    private func addClipboardImage(_ data: Data, at insertionRange: NSRange? = nil, animated: Bool) {
        guard allowsAttachments else {
            status.stringValue = "Start a new note to paste a screenshot."
            return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            temporaryFiles.append(url)
            addAttachments([url], at: insertionRange, animated: animated)
        } catch { showError(error, in: window) }
    }
    func refreshInlineImages() {
        formatMarkdown()
        textView.updateCaret()
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
    }

    private struct ChipItem {
        let url: URL
        let linked: LinkedAttachment?
        let pendingIndex: Int?
    }
    private var renderedChipItems: [ChipItem] = []
    private struct ChipCard {
        let view: PaperSurface
        let openButton: QuietButton
        let removeButton: QuietButton
    }
    private var renderedChipCards: [ChipCard] = []
    private var attachmentExitOverlays: [FeedbackOverlay] = []
    private var removingChipView: NSView?
    private var batchingAttachmentChanges = false
    private var needsAttachmentUpdate = false
    private var animatesAttachmentChanges = false

    static var isPointerAction: Bool {
        guard let type = NSApp.currentEvent?.type else { return false }
        return type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp
    }

    private func performAttachmentChange(animated: Bool, _ updates: () -> Void) {
        let wasBatching = batchingAttachmentChanges
        let previousAnimation = animatesAttachmentChanges
        batchingAttachmentChanges = true
        animatesAttachmentChanges = animated && window?.isVisible == true
        preserveReadingPosition {
            updates()
            batchingAttachmentChanges = wasBatching
            if !wasBatching, needsAttachmentUpdate {
                needsAttachmentUpdate = false
                updateAttachments()
            }
        }
        animatesAttachmentChanges = previousAnimation
    }

    private func clearAttachmentFeedback() {
        for overlay in attachmentExitOverlays { overlay.removeFromSuperview() }
        attachmentExitOverlays.removeAll()
        for card in renderedChipCards { card.view.layer?.removeAnimation(forKey: "feedback.opacity") }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clearAttachmentFeedback()
            hideLinkActionBar(animated: false)
        }
    }

    private func updateAttachments() {
        if batchingAttachmentChanges {
            needsAttachmentUpdate = true
            return
        }
        var items: [ChipItem] = linkedAttachments
            .filter { !$0.isImage }
            .map { ChipItem(url: $0.url, linked: $0, pendingIndex: nil) }
        for (idx, url) in attachments.enumerated() {
            items.append(ChipItem(url: url, linked: nil, pendingIndex: idx))
        }
        if items.count == renderedChipItems.count,
           zip(items, renderedChipItems).allSatisfy({ $0.0.url == $0.1.url }), removingChipView == nil {
            renderedChipItems = items
            return
        }
        let activeURLs = Set(items.map(\.url))
        previews = previews.filter { activeURLs.contains($0.key) }
        if !animatesAttachmentChanges { clearAttachmentFeedback() }

        var available: [URL: [ChipCard]] = [:]
        for (item, card) in zip(renderedChipItems, renderedChipCards) where card.view !== removingChipView {
            available[item.url, default: []].append(card)
        }
        var used: [URL: Int] = [:]
        var nextCards: [ChipCard] = []
        var newCards: [ChipCard] = []
        nextCards.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let occurrence = used[item.url, default: 0]
            let card: ChipCard
            if let candidates = available[item.url], occurrence < candidates.count {
                card = candidates[occurrence]
            } else {
                card = makeChipCard(for: item.url)
                newCards.append(card)
            }
            used[item.url] = occurrence + 1
            card.openButton.tag = index
            card.removeButton.tag = index
            nextCards.append(card)
        }
        let retained = Set(nextCards.map { ObjectIdentifier($0.view) })
        for card in renderedChipCards where !retained.contains(ObjectIdentifier(card.view)) {
            let frame = convert(card.view.bounds, from: card.view)
            chips.removeArrangedSubview(card.view)
            card.view.removeFromSuperview()
            if animatesAttachmentChanges {
                let overlay = FeedbackOverlay(frame: frame)
                overlay.setAccessibilityElement(false)
                overlay.setAccessibilityChildren([])
                card.view.translatesAutoresizingMaskIntoConstraints = true
                card.view.frame = overlay.bounds
                overlay.addSubview(card.view)
                addSubview(overlay)
                attachmentExitOverlays.append(overlay)
                if let layer = card.view.layer {
                    Theme.fade(layer, to: 0, duration: 0.12) { [weak self, weak overlay] in
                        overlay?.removeFromSuperview()
                        self?.attachmentExitOverlays.removeAll { $0 === overlay }
                    }
                }
            }
        }
        for (index, card) in nextCards.enumerated() {
            if chips.arrangedSubviews.indices.contains(index), chips.arrangedSubviews[index] === card.view { continue }
            if card.view.superview === chips { chips.removeArrangedSubview(card.view) }
            chips.insertArrangedSubview(card.view, at: index)
        }
        renderedChipItems = items
        renderedChipCards = nextCards
        preserveReadingPosition {
            let size = chips.fittingSize
            chips.setFrameSize(NSSize(width: max(4, size.width), height: max(4, size.height)))
            let empty = items.isEmpty
            attachmentScroll.isHidden = empty
            attachmentHeight?.constant = empty ? 0 : 62
            attachmentBottom?.constant = empty ? 0 : -6
        }
        if animatesAttachmentChanges {
            for card in newCards {
                if let layer = card.view.layer { Theme.fade(layer, to: 1, duration: 0.16, from: 0) }
            }
        }
    }

    private func makeChipCard(for url: URL) -> ChipCard {
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

        let open = QuietButton(symbol: "arrow.up.right", target: self, action: #selector(openChipAttachment(_:)))
        open.toolTip = "Open \(url.lastPathComponent)"
        open.setAccessibilityLabel("Open \(url.lastPathComponent)")
        let remove = QuietButton(symbol: "xmark", target: self, action: #selector(removeAttachment(_:)))
        remove.setAccessibilityLabel("Remove \(url.lastPathComponent)")
        remove.toolTip = "Remove \(url.lastPathComponent) from this note"
        let row = Theme.stack([preview, description, open, remove], spacing: 6)
        let card = PaperSurface(cornerRadius: 10, color: Theme.elevated, bordered: true)
        card.wantsLayer = true
        Theme.fill(row, in: card, inset: 7)
        card.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return ChipCard(view: card, openButton: open, removeButton: remove)
    }

    @objc private func openChipAttachment(_ sender: NSButton) {
        guard renderedChipItems.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.open(renderedChipItems[sender.tag].url)
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        guard renderedChipItems.indices.contains(sender.tag) else { return }
        let item = renderedChipItems[sender.tag]
        removingChipView = renderedChipCards[sender.tag].view
        performAttachmentChange(animated: Self.isPointerAction) {
            if let pendingIndex = item.pendingIndex, attachments.indices.contains(pendingIndex) {
                attachments.remove(at: pendingIndex)
                onChange?()
            } else if let linked = item.linked {
                onRemoveLinkedAttachment?(linked)
            }
        }
        removingChipView = nil
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
        vimModePill.needsDisplay = true
        semanticView.refreshTypography()
        textView.refreshCaretAppearance()
        textView.updateCaret()
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
    }

    private func handleFocusChange() {
        if textView.window?.firstResponder !== textView {
            hideWikiAutocomplete()
            hideLinkActionBar(animated: false)
        }
        guard !isFormatting, let storage = textView.textStorage else { return }
        let ns = storage.mutableString as NSString
        let sel = textView.selectedRange()
        let clamped = NSRange(location: min(sel.location, ns.length), length: 0)
        let line = ns.lineRange(for: clamped)
        refreshCursorDependentLines(oldLine: lastCursorLine, newLine: line)
    }

    func openMarkdownLink(_ link: MarkdownTextView.MarkdownLink) {
        hideLinkActionBar(animated: false)
        _ = urlOpener(link.resolvedURL)
    }

    func copyMarkdownLink(_ link: MarkdownTextView.MarkdownLink, fromActionBar: Bool = false) {
        let urlString = link.resolvedURL.absoluteString
        let pb = pasteboard
        pb.clearContents()
        pb.setString(urlString, forType: .string)
        status.stringValue = "Copied link to clipboard"
        guard fromActionBar, isLinkActionBarVisible, activeLinkActionItem == link else { return }
        linkActionGeneration &+= 1
        let gen = linkActionGeneration
        linkActionBar.setCopiedState(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.linkActionGeneration == gen, self.isLinkActionBarVisible else { return }
            self.hideLinkActionBar(animated: true)
        }
    }

    func syncCursor(atWindowPoint windowPoint: NSPoint?, modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let windowPoint else { return }
        if isLinkActionBarVisible && !linkActionBar.isHidden,
           linkActionBar.applyCursor(forWindowPoint: windowPoint) {
            textView.clearLinkPointerCursorState()
            return
        }
        guard let rootView = window?.contentView else { return }
        let pointInRootSuperview = rootView.superview.map { $0.convert(windowPoint, from: nil) }
            ?? rootView.convert(windowPoint, from: nil)
        guard let hitView = rootView.hitTest(pointInRootSuperview) else { return }
        if hitView === textView || hitView.isDescendant(of: textView) {
            textView.applyEditorCursor(at: windowPoint, modifierFlags: modifierFlags)
        } else if let button = hitView as? QuietButton, button.isEnabled, let hoverCursor = button.hoverCursor {
            textView.clearLinkPointerCursorState()
            hoverCursor.set()
        } else {
            textView.clearLinkPointerCursorState()
            NSCursor.arrow.set()
        }
    }

    func showLinkActionBar(for link: MarkdownTextView.MarkdownLink, preferredPoint: NSPoint? = nil) {
        hideWikiAutocomplete()
        linkActionGeneration &+= 1
        activeLinkActionItem = link
        activeLinkPreferredPoint = preferredPoint
        isLinkActionBarVisible = true
        linkActionBar.isInteractive = true
        linkActionBar.layer?.removeAnimation(forKey: "feedback.opacity")
        linkActionBar.configure(url: link.resolvedURL, copied: false)
        positionLinkActionBar()
        guard isLinkActionBarVisible else { return }
        linkActionBar.isHidden = false
        linkActionBar.layoutSubtreeIfNeeded()
        window?.invalidateCursorRects(for: linkActionBar)
        if window?.isVisible == true {
            syncCursor(atWindowPoint: window?.mouseLocationOutsideOfEventStream)
        }
        if window?.isVisible == true, let layer = linkActionBar.layer {
            Theme.fade(layer, to: 1, duration: 0.12, from: 0)
        } else {
            linkActionBar.layer?.opacity = 1
        }
    }

    func hideLinkActionBar(animated: Bool) {
        linkActionGeneration &+= 1
        let gen = linkActionGeneration
        let wasVisible = isLinkActionBarVisible || !linkActionBar.isHidden
        isLinkActionBarVisible = false
        linkActionBar.isInteractive = false
        activeLinkActionItem = nil
        activeLinkPreferredPoint = nil
        guard wasVisible else { return }
        if animated, window?.isVisible == true, let layer = linkActionBar.layer {
            Theme.fade(layer, to: 0, duration: 0.10) { [weak self] in
                guard let self, self.linkActionGeneration == gen else { return }
                self.linkActionBar.isHidden = true
                layer.opacity = 1
            }
        } else {
            linkActionBar.layer?.removeAnimation(forKey: "feedback.opacity")
            linkActionBar.layer?.opacity = 1
            linkActionBar.isHidden = true
        }
        window?.invalidateCursorRects(for: linkActionBar)
        window?.invalidateCursorRects(for: textView)
        if window?.isVisible == true {
            syncCursor(atWindowPoint: window?.mouseLocationOutsideOfEventStream)
        }
    }

    private func positionLinkActionBar() {
        guard let link = activeLinkActionItem,
              let linkRectInText = textView.enclosingRect(for: link, preferredPoint: activeLinkPreferredPoint) else {
            hideLinkActionBar(animated: false)
            return
        }
        let rectInEditor = convert(linkRectInText, from: textView)
        let viewportInEditor = convert(scroll.contentView.bounds, from: scroll.contentView)
        guard viewportInEditor.width > 0, viewportInEditor.height > 0, rectInEditor.intersects(viewportInEditor) else {
            hideLinkActionBar(animated: false)
            return
        }
        let naturalSize = linkActionBar.preferredSize()
        let maxWidth = max(180, viewportInEditor.width - 20)
        let size = NSSize(width: min(naturalSize.width, maxWidth), height: naturalSize.height)
        let minX = max(10, viewportInEditor.minX + 10)
        let maxX = max(minX, viewportInEditor.maxX - size.width - 10)
        let x = min(max(minX, rectInEditor.minX), maxX)
        let belowY = rectInEditor.minY - size.height - 6
        let y: CGFloat
        if belowY >= viewportInEditor.minY + 6 || viewportInEditor.height < size.height + 36 {
            y = max(viewportInEditor.minY + 4, belowY)
        } else {
            y = min(max(viewportInEditor.minY + 4, viewportInEditor.maxY - size.height - 6), rectInEditor.maxY + 6)
        }
        linkActionBar.frame = NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
        linkActionBar.layoutSubtreeIfNeeded()
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
        onOutlineVisibilityChange?(visible)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if visible {
            outlineView.scrollActiveRowIntoView()
        }
    }

    @objc func toggleSemanticConnections() {
        setSemanticConnectionsVisible(!isSemanticConnectionsVisible)
    }

    func setSemanticConnectionsVisible(_ visible: Bool) {
        guard isSemanticConnectionsVisible != visible else { return }
        isSemanticConnectionsVisible = visible
        preserveReadingPosition {
            semanticView.isHidden = !visible
            semanticHeight?.constant = visible ? semanticView.preferredHeight : 0
            semanticBottom?.constant = visible ? -8 : 0
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        if visible, window?.isVisible == true, let layer = semanticView.layer {
            Theme.fade(layer, to: 1, duration: 0.15, from: 0)
        } else {
            semanticView.layer?.removeAnimation(forKey: "feedback.opacity")
        }
        onSemanticVisibilityChange?(visible)
    }

    private func syncSemanticStripHeight() {
        guard isSemanticConnectionsVisible else { return }
        let desired = semanticView.preferredHeight
        guard semanticHeight?.constant != desired else { return }
        preserveReadingPosition {
            semanticHeight?.constant = desired
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    @discardableResult
    func insertSuggestedTag(_ rawTag: String) -> Bool {
        guard textView.isEditable else { return false }
        let clean = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard SemanticIndex.isValidCozyTagName(clean) else { return false }

        let ns = nsText
        let existingTags = Vault.tags(inNSString: ns)
        if existingTags.contains(where: { $0.name.lowercased() == clean }) {
            return false
        }

        let prevSel = textView.selectedRange()
        if let lastTag = existingTags.last {
            let insertLoc = NSMaxRange(lastTag.fullRange)
            let insertion = " #\(clean)"
            let insLen = (insertion as NSString).length
            let nextSel: NSRange
            if prevSel.location >= insertLoc {
                nextSel = NSRange(location: prevSel.location + insLen, length: prevSel.length)
            } else {
                nextSel = prevSel
            }
            textView.applyUndoableReplacement(
                in: NSRange(location: insertLoc, length: 0),
                with: insertion,
                selectedRangeAfter: nextSel,
                preserveViewport: true
            )
            return true
        }

        if ns.length == 0 {
            let insertion = "#\(clean) "
            textView.applyUndoableReplacement(
                in: NSRange(location: 0, length: 0),
                with: insertion,
                preserveViewport: true
            )
            return true
        }

        let insertion: String
        if ns.length >= 2 && ns.character(at: ns.length - 1) == 0x0A && ns.character(at: ns.length - 2) == 0x0A {
            insertion = "#\(clean)"
        } else if ns.character(at: ns.length - 1) == 0x0A {
            insertion = "\n#\(clean)"
        } else {
            insertion = "\n\n#\(clean)"
        }
        textView.applyUndoableReplacement(
            in: NSRange(location: ns.length, length: 0),
            with: insertion,
            selectedRangeAfter: prevSel,
            preserveViewport: true
        )
        return true
    }

    @discardableResult
    func insertWikiLinkToRelatedNote(_ wikiTarget: String) -> Bool {
        guard textView.isEditable else { return false }
        let cleaned = wikiTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        let ns = nsText
        let existingLinks = Vault.wikiLinks(inNSString: ns)
        if existingLinks.contains(where: { $0.target.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return false
        }

        let token = "[[\(cleaned)]]"
        if ns.length == 0 {
            textView.applyUndoableReplacement(
                in: NSRange(location: 0, length: 0),
                with: token,
                preserveViewport: true
            )
            return true
        }

        let sel = textView.selectedRange()
        if sel.length == 0 && sel.location > 0 && sel.location < ns.length {
            let prevCh = ns.character(at: sel.location - 1)
            let needsLeadingSpace = (prevCh != 0x20 && prevCh != 0x09 && prevCh != 0x0A && prevCh != 0x0D)
            let insertion = (needsLeadingSpace ? " " : "") + token
            textView.applyUndoableReplacement(
                in: sel,
                with: insertion,
                preserveViewport: true
            )
            return true
        }

        let insertion: String
        if ns.length >= 2 && ns.character(at: ns.length - 1) == 0x0A && ns.character(at: ns.length - 2) == 0x0A {
            insertion = token
        } else if ns.character(at: ns.length - 1) == 0x0A {
            insertion = "\n\(token)"
        } else {
            insertion = "\n\n\(token)"
        }
        textView.applyUndoableReplacement(
            in: NSRange(location: ns.length, length: 0),
            with: insertion,
            selectedRangeAfter: sel,
            preserveViewport: true
        )
        return true
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
        textView.vim.clampSelectionIfNeeded()
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(forCharacterRange: heading.range)
            let glyphRange = lm.glyphRange(forCharacterRange: heading.range, actualCharacterRange: nil)
            let box = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let clipView = scroll.contentView
            let visHeight = clipView.bounds.height
            let targetY = max(0, round(box.minY + textView.textContainerOrigin.y - max(24, visHeight * 0.16)))
            clipView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(clipView)
        }
        textView.updateCaret()
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
        refreshOutline()
        focus()
    }

    func toggleFoldForOutlineItem(at index: Int) {
        guard textView.headingGutterItems.indices.contains(index) else { return }
        let heading = textView.headingGutterItems[index]
        textView.toggleFold(forHeadingAt: heading.range.location)
        textView.vim.clampSelectionIfNeeded()
        refreshOutline()
    }

    func clearExternalChangeHighlights() {
        guard !textView.externalChangeRanges.isEmpty else { return }
        textView.externalChangeRanges.removeAll()
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
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
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
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
    private func computeFindRanges(for query: String, wholeWord: Bool, in ns: NSString) -> [NSRange] {
        guard !query.isEmpty, ns.length > 0 else { return [] }
        let totalLen = ns.length
        let maxMatches = 2000
        if wholeWord {
            let escaped = NSRegularExpression.escapedPattern(for: query)
            let startsWord = query.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? false
            let endsWord = query.unicodeScalars.last.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? false
            let pattern = (startsWord ? "\\b" : "") + escaped + (endsWord ? "\\b" : "")
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                var ranges: [NSRange] = []
                regex.enumerateMatches(in: ns as String, options: [], range: NSRange(location: 0, length: totalLen)) { match, _, stop in
                    if let r = match?.range, r.length > 0 {
                        ranges.append(r)
                        if ranges.count >= maxMatches {
                            stop.pointee = true
                        }
                    }
                }
                return ranges
            }
        }
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < totalLen && ranges.count < maxMatches {
            let hit = ns.range(
                of: query,
                options: [.caseInsensitive],
                range: NSRange(location: searchStart, length: totalLen - searchStart)
            )
            guard hit.location != NSNotFound && hit.length > 0 else { break }
            ranges.append(hit)
            searchStart = NSMaxRange(hit)
        }
        return ranges
    }

    @objc func showInNoteFind() {
        vimSearchWholeWord = false
        isVimSearchingPrompt = false
        vimSearchDirection = .forward
        inNoteFindBar.searchBar.field.placeholderString = "Find in note…"
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

    @discardableResult
    func revealSearchQuery(_ rawQuery: String) -> Bool {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ns = nsText
        guard ns.length > 0 else { return false }
        var candidates: [String] = [trimmed]
        let tokens = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for token in tokens where token.caseInsensitiveCompare(trimmed) != .orderedSame {
            candidates.append(token)
        }
        var matchedTerm: String?
        for candidate in candidates {
            let cleanCandidate = candidate.hasPrefix("#") && candidate.count > 1
                ? String(candidate.dropFirst())
                : candidate
            if ns.range(of: candidate, options: [.caseInsensitive]).location != NSNotFound {
                matchedTerm = candidate
                break
            }
            if cleanCandidate != candidate,
               ns.range(of: cleanCandidate, options: [.caseInsensitive]).location != NSNotFound {
                matchedTerm = cleanCandidate
                break
            }
        }
        guard let term = matchedTerm else { return false }
        vimSearchWholeWord = false
        isVimSearchingPrompt = false
        vimSearchDirection = .forward
        inNoteFindBar.searchBar.field.placeholderString = "Find in note…"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        inNoteFindBar.query = term
        inNoteFindBar.isHidden = false
        updateInNoteFindMatches(scrollToMatch: true)
        window?.makeFirstResponder(textView)
        return !textView.inNoteFindRanges.isEmpty
    }

    @discardableResult
    func revealLinkedAttachment(_ attachmentURL: URL) -> Bool {
        let standardizedTarget = attachmentURL.standardizedFileURL
        guard let item = linkedAttachments.first(where: { $0.url.standardizedFileURL == standardizedTarget }) else {
            return false
        }
        let targetRange = item.markdownRange
        guard NSMaxRange(targetRange) <= nsText.length else { return false }
        if textView.isCharacterFolded(targetRange.location) {
            textView.unfoldSectionsIntersecting(targetRange)
        }
        textView.setSelectedRange(targetRange)
        textView.scrollRangeToVisible(targetRange)
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
        window?.makeFirstResponder(textView)
        return true
    }

    @objc func hideInNoteFind() {
        let wasVimPrompt = isVimSearchingPrompt
        isVimSearchingPrompt = false
        inNoteFindBar.searchBar.field.placeholderString = "Find in note…"
        guard !inNoteFindBar.isHidden || !textView.inNoteFindRanges.isEmpty else { return }
        inNoteFindBar.isHidden = true
        textView.inNoteFindRanges = []
        textView.activeInNoteFindIndex = -1
        inNoteFindBar.countLabel.stringValue = ""
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
        window?.makeFirstResponder(textView)
        if isVimActive {
            if wasVimPrompt {
                textView.vim.enterNormalModeFromExternalControl(at: vimSearchOriginLocation)
            } else {
                textView.vim.clampSelectionIfNeeded()
            }
            textView.updateCaret()
        }
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
            textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
            return
        }
        let ranges = computeFindRanges(for: q, wholeWord: vimSearchWholeWord, in: ns)
        textView.inNoteFindRanges = ranges
        guard !ranges.isEmpty else {
            textView.activeInNoteFindIndex = -1
            inNoteFindBar.countLabel.stringValue = "0 MATCHES"
            textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
            return
        }
        let refLoc = isVimSearchingPrompt ? vimSearchOriginLocation : textView.selectedRange().location
        let dir = isVimSearchingPrompt ? vimSearchDirection : .forward
        if dir == .forward {
            if let idx = ranges.firstIndex(where: { isVimSearchingPrompt ? ($0.location > refLoc) : ($0.location >= refLoc) }) {
                textView.activeInNoteFindIndex = idx
            } else {
                textView.activeInNoteFindIndex = 0
            }
        } else {
            if let idx = ranges.lastIndex(where: { $0.location < refLoc }) {
                textView.activeInNoteFindIndex = idx
            } else {
                textView.activeInNoteFindIndex = ranges.count - 1
            }
        }
        inNoteFindBar.countLabel.stringValue = "\(textView.activeInNoteFindIndex + 1) OF \(ranges.count)"
        if scrollToMatch {
            if isVimSearchingPrompt {
                let idx = textView.activeInNoteFindIndex
                if ranges.indices.contains(idx) {
                    let matchRange = ranges[idx]
                    if textView.isCharacterFolded(matchRange.location) {
                        textView.unfoldSectionsIntersecting(matchRange)
                    }
                    textView.scrollRangeToVisible(matchRange)
                }
                textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
            } else {
                revealActiveInNoteFindMatch()
            }
        } else {
            textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
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
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
    }

    func commitVimSearchFromFindBar() {
        isVimSearchingPrompt = false
        inNoteFindBar.searchBar.field.placeholderString = "Find in note…"
        let idx = textView.activeInNoteFindIndex
        if textView.inNoteFindRanges.indices.contains(idx) {
            let matchRange = textView.inNoteFindRanges[idx]
            if textView.isCharacterFolded(matchRange.location) {
                textView.unfoldSectionsIntersecting(matchRange)
            }
            textView.scrollRangeToVisible(matchRange)
            focus()
            textView.vim.enterNormalModeFromExternalControl(at: matchRange.location)
            status.stringValue = ""
        } else {
            let q = inNoteFindBar.query
            focus()
            textView.vim.enterNormalModeFromExternalControl(at: vimSearchOriginLocation)
            if !q.isEmpty {
                status.stringValue = "Pattern not found: \(q)"
            }
        }
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
    }

    func syncVimModePreference() {
        let active = isVimActive
        if !active, isVimSearchingPrompt {
            isVimSearchingPrompt = false
            inNoteFindBar.searchBar.field.placeholderString = "Find in note…"
        }
        textView.vim.setEnabled(active, startInInsertIfEmpty: nsText.length == 0)
        updateVimChrome()
        textView.refreshCaretAppearance()
        textView.updateCaret()
    }

    func enterVimInsertMode() {
        guard isVimActive else { return }
        textView.vim.enterInsertModeProgrammatically()
        updateVimChrome()
        textView.refreshCaretAppearance()
        textView.updateCaret()
    }

    func updateVimChrome() {
        if isVimActive {
            let mode = textView.vim.mode
            vimModePill.badgeText = mode.badgeTitle
            vimModePill.style = mode.pillStyle
            if vimModePill.isHidden { vimModePill.isHidden = false }
            let pending = textView.vim.pendingKeysDisplay
            if pending.isEmpty {
                if !vimPendingLabel.isHidden { vimPendingLabel.isHidden = true }
                if !vimPendingLabel.stringValue.isEmpty { vimPendingLabel.stringValue = "" }
            } else {
                if vimPendingLabel.stringValue != pending {
                    vimPendingLabel.stringValue = pending
                }
                if vimPendingLabel.isHidden { vimPendingLabel.isHidden = false }
            }
        } else {
            if !vimModePill.isHidden { vimModePill.isHidden = true }
            if !vimPendingLabel.isHidden { vimPendingLabel.isHidden = true }
            if !vimPendingLabel.stringValue.isEmpty { vimPendingLabel.stringValue = "" }
        }
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
        let replacement = item.tagName.map { "#\($0)" } ?? "[[\(item.title)]]"
        let nextCursor = NSRange(location: replaceRange.location + (replacement as NSString).length, length: 0)
        if item.tagName != nil {
            dismissedWikiOpenLocation = replaceRange.location
        }
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
        let activeWiki = Vault.activeWikiLinkQuery(inNSString: ns, cursorLocation: cursor)
        let activeTag = activeWiki == nil ? Vault.activeTagQuery(inNSString: ns, cursorLocation: cursor) : nil
        guard let replacementRange = activeWiki?.replacementRange ?? activeTag?.replacementRange else {
            dismissedWikiOpenLocation = nil
            hideWikiAutocomplete()
            return
        }
        let openLoc = replacementRange.location
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

        let items: [WikiLinkCompletionView.Item]
        if let activeWiki {
            wikiCompletionView.headerTitle = "LINK TO NOTE"
            items = Self.buildWikiCompletionItems(
                for: activeWiki.query,
                notes: notes,
                currentNoteURL: currentNoteURLProvider?()
            )
        } else if let activeTag {
            wikiCompletionView.headerTitle = "INSERT TAG"
            items = Self.buildTagCompletionItems(
                for: activeTag.query,
                notes: notes
            )
        } else {
            items = []
        }
        guard !items.isEmpty else {
            hideWikiAutocomplete()
            return
        }
        let isNewPopup = (activeWikiOpenLocation != openLoc) || wikiCompletionView.isHidden
        activeWikiOpenLocation = openLoc
        activeWikiReplacementRange = replacementRange
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

    static func buildTagCompletionItems(
        for rawQuery: String,
        notes: [NoteRecord]
    ) -> [WikiLinkCompletionView.Item] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags {
                counts[tag, default: 0] += 1
            }
        }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var results: [WikiLinkCompletionView.Item] = []
        if trimmed.isEmpty {
            let sorted = counts.sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.key < b.key
            }
            for entry in sorted.prefix(8) {
                results.append(WikiLinkCompletionView.Item(
                    title: entry.key,
                    subtitle: "\(entry.value) \(entry.value == 1 ? "note" : "notes")",
                    isCreateNew: false,
                    noteURL: nil,
                    tagName: entry.key
                ))
            }
            return results
        }

        var scored: [(score: Int, count: Int, name: String)] = []
        for (name, count) in counts {
            let score: Int
            if name == trimmed {
                score = 100
            } else if name.hasPrefix(trimmed) {
                score = 80
            } else if name.contains(trimmed) {
                score = 60
            } else {
                continue
            }
            scored.append((score, count, name))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.count != b.count { return a.count > b.count }
            return a.name < b.name
        }
        for entry in scored.prefix(6) {
            results.append(WikiLinkCompletionView.Item(
                title: entry.name,
                subtitle: "\(entry.count) \(entry.count == 1 ? "note" : "notes")",
                isCreateNew: false,
                noteURL: nil,
                tagName: entry.name
            ))
        }
        if counts[trimmed] == nil {
            results.append(WikiLinkCompletionView.Item(
                title: trimmed,
                subtitle: "New tag",
                isCreateNew: true,
                noteURL: nil,
                tagName: trimmed
            ))
        }
        return results
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
                if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
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
        let hasAutoLink: Bool
        let hasWikiLink: Bool
        let hasHash: Bool
        let hasPipe: Bool
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
                hasAutoLink: false,
                hasWikiLink: false,
                hasHash: false,
                hasPipe: false
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
        var hasAutoLink = false
        var hasWikiLink = false
        var hasHash = false
        var hasPipe = false
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
                            if u == 0x23 {
                                hasHash = true
                            } else if u == 0x7C {
                                hasPipe = true
                            } else if u == 0x28 && prevChar == 0x5D {
                                hasLinkOpen = true
                            } else if u == 0x5B && prevChar == 0x5B {
                                hasWikiLink = true
                            } else if u == 0x2F && prevChar == 0x2F {
                                hasAutoLink = true
                            } else if !hasAutoLink && u == 0x3A && offset + i >= 6 {
                                let absIdx = offset + i
                                if (ns.character(at: absIdx - 6) | 0x20) == 0x6D
                                    && (ns.character(at: absIdx - 1) | 0x20) == 0x6F {
                                    hasAutoLink = true
                                }
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
            hasAutoLink: hasAutoLink,
            hasWikiLink: hasWikiLink,
            hasHash: hasHash,
            hasPipe: hasPipe
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
                hasAutoLink: false,
                hasWikiLink: false,
                hasHash: false,
                hasPipe: false
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

    static func isHorizontalRuleLine(_ ns: NSString, lineStart: Int, contentEnd: Int) -> Bool {
        guard contentEnd - lineStart >= 3 else { return false }
        var p = lineStart
        var leadSpaces = 0
        while p < contentEnd && ns.character(at: p) == 0x20 {
            leadSpaces += 1
            if leadSpaces > 3 { return false }
            p += 1
        }
        guard p < contentEnd else { return false }
        let marker = ns.character(at: p)
        guard marker == 0x2D || marker == 0x2A || marker == 0x5F else { return false }
        var count = 0
        while p < contentEnd {
            let ch = ns.character(at: p)
            if ch == marker {
                count += 1
            } else if ch != 0x20 && ch != 0x09 {
                return false
            }
            p += 1
        }
        return count >= 3
    }

    private func lineHasCursorSensitiveSyntax(_ ns: NSString, lineRange: NSRange) -> Bool {
        guard lineRange.location != NSNotFound, lineRange.length > 0, NSMaxRange(lineRange) <= ns.length else { return false }
        let first = ns.character(at: lineRange.location)
        if first == 0x23 || first == 0x60 || first == 0x7C { return true }
        if first == 0x2D || first == 0x2A || first == 0x5F || first == 0x20 {
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location {
                let ch = ns.character(at: contentEnd - 1)
                if ch == 10 || ch == 13 { contentEnd -= 1 } else { break }
            }
            if Self.isHorizontalRuleLine(ns, lineStart: lineRange.location, contentEnd: contentEnd) {
                return true
            }
        }
        if ns.range(of: "![", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "`", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "|", options: .literal, range: lineRange).location != NSNotFound { return true }
        return false
    }

    private func refreshCursorDependentLines(oldLine: NSRange, newLine: NSRange) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.mutableString as NSString
        let oldNeeds = lineHasCursorSensitiveSyntax(ns, lineRange: oldLine)
        let newNeeds = lineHasCursorSensitiveSyntax(ns, lineRange: newLine)
        guard oldNeeds || newNeeds else { return }
        let touchesBlock = (oldNeeds && textView.rangeTouchesFenceOrTable(oldLine))
            || (newNeeds && textView.rangeTouchesFenceOrTable(newLine))
        if touchesBlock {
            formatMarkdown()
            textView.updateCaret()
            textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
            return
        }
        isFormatting = true
        defer { isFormatting = false }
        textView.preservingViewport {
            let cursor = textView.selectedRange()
            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            if oldNeeds, NSMaxRange(oldLine) <= ns.length {
                var q: [NSRange] = []
                var hr: [NSRange] = []
                var h: [MarkdownTextView.HeadingGutter] = []
                var c: [NSRange] = []
                var w: [WikiLink] = []
                var t: [NoteTag] = []
                var m: [MarkdownTextView.MarkdownLink] = []
                var img: [MarkdownTextView.InlineImageItem] = []
                var b: [MarkdownTextView.BulletItem] = []
                formatLineRange(oldLine, in: storage, ns: ns, cursor: cursor, quotes: &q, horizontalRules: &hr, headings: &h, codes: &c, wikiLinks: &w, tags: &t, markdownLinks: &m, inlineImages: &img, bullets: &b)
            }
            if newNeeds, newLine != oldLine, NSMaxRange(newLine) <= ns.length {
                var q: [NSRange] = []
                var hr: [NSRange] = []
                var h: [MarkdownTextView.HeadingGutter] = []
                var c: [NSRange] = []
                var w: [WikiLink] = []
                var t: [NoteTag] = []
                var m: [MarkdownTextView.MarkdownLink] = []
                var img: [MarkdownTextView.InlineImageItem] = []
                var b: [MarkdownTextView.BulletItem] = []
                formatLineRange(newLine, in: storage, ns: ns, cursor: cursor, quotes: &q, horizontalRules: &hr, headings: &h, codes: &c, wikiLinks: &w, tags: &t, markdownLinks: &m, inlineImages: &img, bullets: &b)
            }
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()
            applyEditorChromeAttributes()
        }
        textView.updateCaret()
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
    }

    private static func isBlockSyntaxLead(_ ch: unichar) -> Bool {
        ch == 0x23 || ch == 0x3E || ch == 0x2D || ch == 0x2A || ch == 0x2B || ch == 0x5F || ch == 0x20 || ch == 0x09 || (ch >= 0x30 && ch <= 0x39)
    }

    private func lineHasMarkdownSyntax(_ ns: NSString, lineRange: NSRange) -> Bool {
        guard lineRange.length > 0, NSMaxRange(lineRange) <= ns.length else { return false }
        let rangeEnd = NSMaxRange(lineRange)
        if Self.isBlockSyntaxLead(ns.character(at: lineRange.location)) {
            return true
        }
        let firstLineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: lineRange.location, length: 0)))
        if firstLineEnd < rangeEnd {
            var pos = firstLineEnd
            while pos < rangeEnd {
                if Self.isBlockSyntaxLead(ns.character(at: pos)) {
                    return true
                }
                let nextEnd = NSMaxRange(ns.lineRange(for: NSRange(location: pos, length: 0)))
                pos = max(pos + 1, nextEnd)
            }
        }
        if ns.range(of: "*", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "`", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "#", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "](", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "__", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "<", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "~~", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "[[", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "://", options: .literal, range: lineRange).location != NSNotFound { return true }
        if ns.range(of: "mailto:", options: .caseInsensitive, range: lineRange).location != NSNotFound { return true }
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
        let editEnd = min(newLen, editLoc + edit.replacementLength)
        let spanEnd = editEnd < newLen ? editEnd + 1 : editEnd
        let newLineRange = ns.lineRange(for: NSRange(location: editLoc, length: spanEnd - editLoc))
        let oldLineEnd = max(newLineRange.location, NSMaxRange(newLineRange) - edit.delta)
        let oldLineRange = NSRange(location: newLineRange.location, length: oldLineEnd - newLineRange.location)
        let delta = edit.delta

        let hadItemsInOldLine = textView.headingGutterItems.contains { NSIntersectionRange($0.range, oldLineRange).length > 0 || $0.range.location == oldLineRange.location }
            || textView.blockquoteRanges.contains { NSIntersectionRange($0, oldLineRange).length > 0 || $0.location == oldLineRange.location }
            || textView.horizontalRuleRanges.contains { NSIntersectionRange($0, oldLineRange).length > 0 || $0.location == oldLineRange.location }
            || textView.inlineCodeRanges.contains { NSIntersectionRange($0, oldLineRange).length > 0 || $0.location == oldLineRange.location }
            || textView.wikiLinkItems.contains { NSIntersectionRange($0.fullRange, oldLineRange).length > 0 || $0.fullRange.location == oldLineRange.location }
            || textView.tagItems.contains { NSIntersectionRange($0.fullRange, oldLineRange).length > 0 || $0.fullRange.location == oldLineRange.location }
            || textView.markdownLinkItems.contains { NSIntersectionRange($0.fullRange, oldLineRange).length > 0 || $0.fullRange.location == oldLineRange.location }
            || textView.inlineImageItems.contains { NSIntersectionRange($0.fullLineRange, oldLineRange).length > 0 || $0.fullLineRange.location == oldLineRange.location }
            || textView.bulletItems.contains { NSIntersectionRange($0.lineRange, oldLineRange).length > 0 || $0.lineRange.location == oldLineRange.location }

        let newHasSyntax = lineHasMarkdownSyntax(ns, lineRange: newLineRange)
        let missingBaseAttrs = newLineRange.length > 0
            && storage.attribute(.foregroundColor, at: newLineRange.location, effectiveRange: nil) == nil

        if edit.affectedRange.length == 0 && !hadItemsInOldLine && !newHasSyntax && !missingBaseAttrs {
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
                for i in textView.horizontalRuleRanges.indices where textView.horizontalRuleRanges[i].location >= shiftStart {
                    let r = textView.horizontalRuleRanges[i]
                    textView.horizontalRuleRanges[i] = NSRange(location: r.location + delta, length: r.length)
                }
                for i in textView.inlineCodeRanges.indices where textView.inlineCodeRanges[i].location >= shiftStart {
                    let r = textView.inlineCodeRanges[i]
                    textView.inlineCodeRanges[i] = NSRange(location: r.location + delta, length: r.length)
                }
                for i in textView.wikiLinkItems.indices where textView.wikiLinkItems[i].fullRange.location >= shiftStart {
                    textView.wikiLinkItems[i] = Self.shiftWikiLink(textView.wikiLinkItems[i], by: delta)
                }
                for i in textView.tagItems.indices where textView.tagItems[i].fullRange.location >= shiftStart {
                    textView.tagItems[i] = Self.shiftNoteTag(textView.tagItems[i], by: delta)
                }
                for i in textView.markdownLinkItems.indices where textView.markdownLinkItems[i].fullRange.location >= shiftStart {
                    textView.markdownLinkItems[i] = Self.shiftMarkdownLink(textView.markdownLinkItems[i], by: delta)
                }
                for i in textView.inlineImageItems.indices where textView.inlineImageItems[i].fullLineRange.location >= shiftStart {
                    textView.inlineImageItems[i] = Self.shiftInlineImage(textView.inlineImageItems[i], by: delta)
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
                for i in textView.fencedBlocks.indices where textView.fencedBlocks[i].fullRange.location >= shiftStart {
                    textView.fencedBlocks[i] = Self.shiftFencedBlock(textView.fencedBlocks[i], by: delta)
                }
                for i in textView.tableBlocks.indices where textView.tableBlocks[i].fullRange.location >= shiftStart {
                    textView.tableBlocks[i] = Self.shiftTableBlock(textView.tableBlocks[i], by: delta)
                }
                textView.shiftFoldedSections(from: shiftStart, by: delta)
            }
            lastCursorLine = ns.lineRange(for: NSRange(location: min(textView.selectedRange().location, newLen), length: 0))
            return false
        }

        var newQuotes: [NSRange] = []
        var newHorizontalRules: [NSRange] = []
        var newHeadings: [MarkdownTextView.HeadingGutter] = []
        var newCodes: [NSRange] = []
        var newWikiLinks: [WikiLink] = []
        var newTags: [NoteTag] = []
        var newMarkdownLinks: [MarkdownTextView.MarkdownLink] = []
        var newInlineImages: [MarkdownTextView.InlineImageItem] = []
        var newBullets: [MarkdownTextView.BulletItem] = []
        let cursor = textView.selectedRange()

        textView.preservingViewport {
            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            formatLineRange(newLineRange, in: storage, ns: ns, cursor: cursor, quotes: &newQuotes, horizontalRules: &newHorizontalRules, headings: &newHeadings, codes: &newCodes, wikiLinks: &newWikiLinks, tags: &newTags, markdownLinks: &newMarkdownLinks, inlineImages: &newInlineImages, bullets: &newBullets)
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()
        }

        let oldEnd = NSMaxRange(oldLineRange)
        var updatedHeadings: [MarkdownTextView.HeadingGutter] = []
        updatedHeadings.reserveCapacity(textView.headingGutterItems.count + newHeadings.count)
        var insertedHeadings = false
        for item in textView.headingGutterItems {
            if NSMaxRange(item.range) <= oldLineRange.location && item.range.location < oldLineRange.location {
                updatedHeadings.append(item)
            } else if item.range.location >= oldEnd {
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
            } else if r.location >= oldEnd {
                if !insertedQuotes {
                    updatedQuotes.append(contentsOf: newQuotes)
                    insertedQuotes = true
                }
                updatedQuotes.append(NSRange(location: r.location + delta, length: r.length))
            }
        }
        if !insertedQuotes { updatedQuotes.append(contentsOf: newQuotes) }
        textView.blockquoteRanges = updatedQuotes

        var updatedHorizontalRules: [NSRange] = []
        var insertedHorizontalRules = false
        for r in textView.horizontalRuleRanges {
            if NSMaxRange(r) <= oldLineRange.location && r.location < oldLineRange.location {
                updatedHorizontalRules.append(r)
            } else if r.location >= oldEnd {
                if !insertedHorizontalRules {
                    updatedHorizontalRules.append(contentsOf: newHorizontalRules)
                    insertedHorizontalRules = true
                }
                updatedHorizontalRules.append(NSRange(location: r.location + delta, length: r.length))
            }
        }
        if !insertedHorizontalRules { updatedHorizontalRules.append(contentsOf: newHorizontalRules) }
        textView.horizontalRuleRanges = updatedHorizontalRules

        var updatedCodes: [NSRange] = []
        var insertedCodes = false
        for r in textView.inlineCodeRanges {
            if NSMaxRange(r) <= oldLineRange.location && r.location < oldLineRange.location {
                updatedCodes.append(r)
            } else if r.location >= oldEnd {
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
            } else if item.fullRange.location >= oldEnd {
                if !insertedWikiLinks {
                    updatedWikiLinks.append(contentsOf: newWikiLinks)
                    insertedWikiLinks = true
                }
                updatedWikiLinks.append(Self.shiftWikiLink(item, by: delta))
            }
        }
        if !insertedWikiLinks { updatedWikiLinks.append(contentsOf: newWikiLinks) }
        textView.wikiLinkItems = updatedWikiLinks

        var updatedTags: [NoteTag] = []
        var insertedTags = false
        for item in textView.tagItems {
            if NSMaxRange(item.fullRange) <= oldLineRange.location && item.fullRange.location < oldLineRange.location {
                updatedTags.append(item)
            } else if item.fullRange.location >= oldEnd {
                if !insertedTags {
                    updatedTags.append(contentsOf: newTags)
                    insertedTags = true
                }
                updatedTags.append(Self.shiftNoteTag(item, by: delta))
            }
        }
        if !insertedTags { updatedTags.append(contentsOf: newTags) }
        textView.tagItems = updatedTags

        var updatedMarkdownLinks: [MarkdownTextView.MarkdownLink] = []
        var insertedMarkdownLinks = false
        for item in textView.markdownLinkItems {
            if NSMaxRange(item.fullRange) <= oldLineRange.location && item.fullRange.location < oldLineRange.location {
                updatedMarkdownLinks.append(item)
            } else if item.fullRange.location >= oldEnd {
                if !insertedMarkdownLinks {
                    updatedMarkdownLinks.append(contentsOf: newMarkdownLinks)
                    insertedMarkdownLinks = true
                }
                updatedMarkdownLinks.append(Self.shiftMarkdownLink(item, by: delta))
            }
        }
        if !insertedMarkdownLinks { updatedMarkdownLinks.append(contentsOf: newMarkdownLinks) }
        textView.markdownLinkItems = updatedMarkdownLinks

        var updatedInlineImages: [MarkdownTextView.InlineImageItem] = []
        var insertedInlineImages = false
        for item in textView.inlineImageItems {
            if NSMaxRange(item.fullLineRange) <= oldLineRange.location && item.fullLineRange.location < oldLineRange.location {
                updatedInlineImages.append(item)
            } else if item.fullLineRange.location >= oldEnd {
                if !insertedInlineImages {
                    updatedInlineImages.append(contentsOf: newInlineImages)
                    insertedInlineImages = true
                }
                updatedInlineImages.append(Self.shiftInlineImage(item, by: delta))
            }
        }
        if !insertedInlineImages { updatedInlineImages.append(contentsOf: newInlineImages) }
        textView.inlineImageItems = updatedInlineImages

        var updatedBullets: [MarkdownTextView.BulletItem] = []
        var insertedBullets = false
        for item in textView.bulletItems {
            if NSMaxRange(item.lineRange) <= oldLineRange.location && item.lineRange.location < oldLineRange.location {
                updatedBullets.append(item)
            } else if item.lineRange.location >= oldEnd {
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
            for i in textView.fencedBlocks.indices where textView.fencedBlocks[i].fullRange.location >= oldEnd {
                textView.fencedBlocks[i] = Self.shiftFencedBlock(textView.fencedBlocks[i], by: delta)
            }
            for i in textView.tableBlocks.indices where textView.tableBlocks[i].fullRange.location >= oldEnd {
                textView.tableBlocks[i] = Self.shiftTableBlock(textView.tableBlocks[i], by: delta)
            }
            textView.shiftFoldedSections(from: oldEnd, by: delta)
        }
        applyEditorChromeAttributes()

        lastCursorLine = ns.lineRange(for: NSRange(location: min(cursor.location, newLen), length: 0))
        return true
    }

    private static func shiftRange(_ range: NSRange, by delta: Int) -> NSRange {
        guard range.location != NSNotFound else { return range }
        return NSRange(location: max(0, range.location + delta), length: range.length)
    }

    private static func shiftFencedBlock(_ block: MarkdownTextView.FencedBlock, by delta: Int) -> MarkdownTextView.FencedBlock {
        MarkdownTextView.FencedBlock(
            fullRange: shiftRange(block.fullRange, by: delta),
            headerRange: shiftRange(block.headerRange, by: delta),
            bodyRange: shiftRange(block.bodyRange, by: delta)
        )
    }

    private static func shiftTableBlock(_ table: MarkdownTextView.TableBlock, by delta: Int) -> MarkdownTextView.TableBlock {
        MarkdownTextView.TableBlock(
            fullRange: shiftRange(table.fullRange, by: delta),
            headerRange: shiftRange(table.headerRange, by: delta),
            delimiterRange: shiftRange(table.delimiterRange, by: delta),
            rows: table.rows.map { row in
                MarkdownTextView.TableRowItem(
                    lineRange: shiftRange(row.lineRange, by: delta),
                    fullLineRange: shiftRange(row.fullLineRange, by: delta),
                    isHeader: row.isHeader,
                    isDelimiter: row.isDelimiter
                )
            },
            columnDividerOffsets: table.columnDividerOffsets
        )
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
        textView.preservingViewport {
            let cursor = textView.selectedRange()
            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            applyFullMarkdownAttributes(to: storage, cursor: cursor, scanHint: nil)
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()
            applyEditorChromeAttributes()
            textView.refreshFoldLayoutAfterFullFormat()
        }
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
            textView.horizontalRuleRanges = []
            textView.headingGutterItems = []
            textView.inlineCodeRanges = []
            textView.wikiLinkItems = []
            textView.tagItems = []
            textView.markdownLinkItems = []
            textView.inlineImageItems = []
            textView.fencedBlocks = []
            textView.tableBlocks = []
            textView.bulletItems = []
            hasPotentialLinks = false
            return
        }

        let scan = scanHint ?? performOrReuseScan(on: ns, length: totalLen, sig: Self.sampleSignature(of: ns))

        storage.setAttributes(baseAttrs, range: range)

        var quotes: [NSRange] = []
        var horizontalRules: [NSRange] = []
        var headings: [MarkdownTextView.HeadingGutter] = []
        var inlinePills: [NSRange] = []
        var wikiLinks: [WikiLink] = []
        var tags: [NoteTag] = []
        var markdownLinks: [MarkdownTextView.MarkdownLink] = []
        var inlineImages: [MarkdownTextView.InlineImageItem] = []
        var bullets: [MarkdownTextView.BulletItem] = []
        var parsedFences: [MarkdownTextView.FencedBlock] = []

        formatLineRange(range, in: storage, ns: ns, cursor: cursor, scan: scan, quotes: &quotes, horizontalRules: &horizontalRules, headings: &headings, codes: &inlinePills, wikiLinks: &wikiLinks, tags: &tags, markdownLinks: &markdownLinks, inlineImages: &inlineImages, bullets: &bullets)
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
            horizontalRules.removeAll { r in
                parsedFences.contains { NSIntersectionRange($0.fullRange, r).length > 0 }
            }
            inlinePills.removeAll { r in
                parsedFences.contains { NSIntersectionRange($0.fullRange, r).length > 0 }
            }
            wikiLinks.removeAll { link in
                parsedFences.contains { NSIntersectionRange($0.fullRange, link.fullRange).length > 0 }
            }
            tags.removeAll { tag in
                parsedFences.contains { NSIntersectionRange($0.fullRange, tag.fullRange).length > 0 }
            }
            markdownLinks.removeAll { link in
                parsedFences.contains { NSIntersectionRange($0.fullRange, link.fullRange).length > 0 }
            }
            inlineImages.removeAll { img in
                parsedFences.contains { NSIntersectionRange($0.fullRange, img.fullRange).length > 0 }
            }
        }
        var parsedTables: [MarkdownTextView.TableBlock] = []
        if scan.hasPipe {
            parsedTables = parseAndFormatTables(
                in: storage,
                ns: ns,
                cursor: cursor,
                fencedBlocks: parsedFences,
                inlineCodeRanges: inlinePills
            )
            if !parsedTables.isEmpty {
                bullets.removeAll { item in
                    parsedTables.contains { NSIntersectionRange($0.fullRange, item.lineRange).length > 0 }
                }
                quotes.removeAll { r in
                    parsedTables.contains { NSIntersectionRange($0.fullRange, r).length > 0 }
                }
                horizontalRules.removeAll { r in
                    parsedTables.contains { NSIntersectionRange($0.fullRange, r).length > 0 }
                }
                headings.removeAll { item in
                    parsedTables.contains { NSIntersectionRange($0.fullRange, item.range).length > 0 }
                }
                inlineImages.removeAll { img in
                    parsedTables.contains { NSIntersectionRange($0.fullRange, img.fullRange).length > 0 }
                }
            }
        }

        textView.blockquoteRanges = quotes
        textView.horizontalRuleRanges = horizontalRules
        textView.headingGutterItems = headings
        textView.inlineCodeRanges = inlinePills
        textView.wikiLinkItems = wikiLinks
        textView.tagItems = tags
        textView.markdownLinkItems = markdownLinks
        textView.inlineImageItems = inlineImages
        textView.fencedBlocks = parsedFences
        textView.tableBlocks = parsedTables
        textView.bulletItems = bullets
    }

    private struct ParsedTableCell {
        let openPipeLocation: Int?
        let leadingSyntaxRange: NSRange
        let contentRange: NSRange
        let trailingSyntaxRange: NSRange
    }

    private struct ParsedTableRow {
        let lineRange: NSRange
        let fullLineRange: NSRange
        let isHeader: Bool
        let isDelimiter: Bool
        let cells: [ParsedTableCell]
        let closingSyntaxRange: NSRange
    }

    private func parseAndFormatTables(
        in storage: NSTextStorage,
        ns: NSString,
        cursor: NSRange,
        fencedBlocks: [MarkdownTextView.FencedBlock],
        inlineCodeRanges: [NSRange]
    ) -> [MarkdownTextView.TableBlock] {
        let totalLen = ns.length
        guard totalLen > 0 else { return [] }
        let isFocused = textView.window?.firstResponder === textView
        let proseSize = Theme.baseProseSize
        let hiddenAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 0.1),
            .foregroundColor: NSColor.clear,
            .kern: 0.0
        ]

        var lineInfos: [(lineRange: NSRange, fullLineRange: NSRange)] = []
        var pos = 0
        while pos < totalLen {
            let fullLine = ns.lineRange(for: NSRange(location: pos, length: 0))
            let nextPos = max(pos + 1, NSMaxRange(fullLine))
            var contentEnd = min(NSMaxRange(fullLine), totalLen)
            while contentEnd > fullLine.location {
                let ch = ns.character(at: contentEnd - 1)
                if ch == 10 || ch == 13 { contentEnd -= 1 } else { break }
            }
            lineInfos.append((
                lineRange: NSRange(location: fullLine.location, length: max(0, contentEnd - fullLine.location)),
                fullLineRange: fullLine
            ))
            pos = nextPos
        }

        func lineInFence(_ r: NSRange) -> Bool {
            fencedBlocks.contains { NSIntersectionRange($0.fullRange, r).length > 0 }
        }

        var result: [MarkdownTextView.TableBlock] = []
        var idx = 0
        while idx + 1 < lineInfos.count {
            let headerInfo = lineInfos[idx]
            let delimInfo = lineInfos[idx + 1]
            if headerInfo.lineRange.length == 0 || delimInfo.lineRange.length == 0
                || lineInFence(headerInfo.lineRange) || lineInFence(delimInfo.lineRange)
                || !Self.isTableDelimiterRow(in: ns, lineRange: delimInfo.lineRange) {
                idx += 1
                continue
            }
            guard let headerParsed = Self.parseTableRow(
                in: ns,
                lineRange: headerInfo.lineRange,
                fullLineRange: headerInfo.fullLineRange,
                isHeader: true,
                isDelimiter: false
            ), !headerParsed.cells.isEmpty else {
                idx += 1
                continue
            }
            let delimParsed = ParsedTableRow(
                lineRange: delimInfo.lineRange,
                fullLineRange: delimInfo.fullLineRange,
                isHeader: false,
                isDelimiter: true,
                cells: [],
                closingSyntaxRange: NSRange(location: NSMaxRange(delimInfo.lineRange), length: 0)
            )
            var parsedRows: [ParsedTableRow] = [headerParsed, delimParsed]
            var scanIdx = idx + 2
            while scanIdx < lineInfos.count {
                let rowInfo = lineInfos[scanIdx]
                if rowInfo.lineRange.length == 0 || lineInFence(rowInfo.lineRange) { break }
                if Self.isTableDelimiterRow(in: ns, lineRange: rowInfo.lineRange) { break }
                guard let bodyRow = Self.parseTableRow(
                    in: ns,
                    lineRange: rowInfo.lineRange,
                    fullLineRange: rowInfo.fullLineRange,
                    isHeader: false,
                    isDelimiter: false
                ), !bodyRow.cells.isEmpty else {
                    break
                }
                parsedRows.append(bodyRow)
                scanIdx += 1
            }
            idx = scanIdx

            let colCount = max(1, headerParsed.cells.count)
            let headerFont = Theme.bodyFont(proseSize - 0.5, weight: .semibold)
            let cellBodyFont = Theme.bodyFont(proseSize - 0.5)
            let cellBoldFont = Theme.bodyFont(proseSize - 0.5, weight: .semibold)
            let cellItalicFont = Theme.italicBodyFont(proseSize - 0.5)

            // Format delimiter row (collapse to 1pt border height unless cursor is directly on it)
            let cursorOnDelimiter = isFocused && cursor.location >= delimInfo.lineRange.location && cursor.location <= NSMaxRange(delimInfo.lineRange)
            if cursorOnDelimiter {
                let editDelimPara = NSMutableParagraphStyle()
                editDelimPara.firstLineHeadIndent = 14
                editDelimPara.headIndent = 14
                editDelimPara.lineSpacing = 2.0
                editDelimPara.paragraphSpacingBefore = 2.0
                editDelimPara.paragraphSpacing = 4.0
                storage.addAttributes([
                    .font: Theme.monoFont(proseSize - 3.0),
                    .foregroundColor: Theme.subtle,
                    .paragraphStyle: editDelimPara,
                    .kern: 0.0
                ], range: delimInfo.fullLineRange)
            } else {
                let collapsedDelimPara = NSMutableParagraphStyle()
                collapsedDelimPara.lineSpacing = 0.0
                collapsedDelimPara.paragraphSpacing = 0.0
                collapsedDelimPara.paragraphSpacingBefore = 0.0
                collapsedDelimPara.minimumLineHeight = 1.0
                collapsedDelimPara.maximumLineHeight = 1.0
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: collapsedDelimPara,
                    .kern: 0.0
                ], range: delimInfo.fullLineRange)
            }

            // Format cells and measure each cell's natural rendered width
            var measuredWidths: [[CGFloat]] = Array(repeating: Array(repeating: 0, count: colCount), count: parsedRows.count)
            for (rIdx, row) in parsedRows.enumerated() where !row.isDelimiter {
                let cursorOnRow = isFocused && cursor.location >= row.lineRange.location && cursor.location <= NSMaxRange(row.lineRange)
                let lineStr = ns.substring(with: row.lineRange)
                let localRange = NSRange(location: 0, length: row.lineRange.length)

                for cell in row.cells {
                    if cell.leadingSyntaxRange.length > 0 {
                        storage.addAttributes(hiddenAttrs, range: cell.leadingSyntaxRange)
                    }
                    if cell.trailingSyntaxRange.length > 0 {
                        storage.addAttributes(hiddenAttrs, range: cell.trailingSyntaxRange)
                    }
                    if cell.contentRange.length > 0 {
                        storage.addAttributes([
                            .font: row.isHeader ? headerFont : cellBodyFont,
                            .foregroundColor: row.isHeader ? Theme.headingInk : Theme.ink
                        ], range: cell.contentRange)
                        for codeRange in inlineCodeRanges {
                            let inter = NSIntersectionRange(codeRange, cell.contentRange)
                            if inter.length > 0 {
                                storage.addAttributes([
                                    .font: Theme.monoFont(proseSize - 2.5, weight: .medium),
                                    .foregroundColor: Theme.inlineCodeInk,
                                    .kern: 0.1
                                ], range: inter)
                                let tickAttrs: [NSAttributedString.Key: Any] = [
                                    .foregroundColor: cursorOnRow ? Theme.subtle : NSColor.clear,
                                    .font: Theme.monoFont(11)
                                ]
                                if codeRange.location > row.lineRange.location {
                                    let openTick = NSRange(location: codeRange.location - 1, length: 1)
                                    storage.addAttributes(tickAttrs, range: openTick)
                                }
                                if NSMaxRange(codeRange) < NSMaxRange(row.lineRange) {
                                    let closeTick = NSRange(location: NSMaxRange(codeRange), length: 1)
                                    storage.addAttributes(tickAttrs, range: closeTick)
                                }
                            }
                        }
                    }
                }
                if row.closingSyntaxRange.length > 0 {
                    storage.addAttributes(hiddenAttrs, range: row.closingSyntaxRange)
                }

                // Re-apply bold/italic/strikethrough inside the row and hide markers when cursor is not on the row
                for match in bold.matches(in: lineStr, range: localRange) {
                    let full = NSRange(location: row.lineRange.location + match.range.location, length: match.range.length)
                    storage.addAttributes([.font: cellBoldFont, .foregroundColor: Theme.headingInk], range: full)
                    let openM = NSRange(location: full.location, length: 2)
                    let closeM = NSRange(location: NSMaxRange(full) - 2, length: 2)
                    if cursorOnRow {
                        storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(11.5)], range: openM)
                        storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(11.5)], range: closeM)
                    } else {
                        storage.addAttributes(hiddenAttrs, range: openM)
                        storage.addAttributes(hiddenAttrs, range: closeM)
                    }
                }
                for match in italic.matches(in: lineStr, range: localRange) {
                    let full = NSRange(location: row.lineRange.location + match.range.location, length: match.range.length)
                    let inner = NSRange(location: row.lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                    storage.addAttributes([.font: cellItalicFont], range: inner)
                    let openM = NSRange(location: full.location, length: 1)
                    let closeM = NSRange(location: NSMaxRange(full) - 1, length: 1)
                    if cursorOnRow {
                        storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(11.5)], range: openM)
                        storage.addAttributes([.foregroundColor: Theme.subtle, .font: Theme.monoFont(11.5)], range: closeM)
                    } else {
                        storage.addAttributes(hiddenAttrs, range: openM)
                        storage.addAttributes(hiddenAttrs, range: closeM)
                    }
                }

                for (cIdx, cell) in row.cells.prefix(colCount).enumerated() where cell.contentRange.length > 0 {
                    let w = ceil(storage.attributedSubstring(from: cell.contentRange).size().width)
                    measuredWidths[rIdx][cIdx] = w
                }
            }

            let linePad = textView.textContainer?.lineFragmentPadding ?? 5.0
            let containerWidth = max(240.0, textView.textContainer?.containerSize.width ?? 640.0)
            let leftPad: CGFloat = 14.0
            let rightPad: CGFloat = 14.0
            let gapBeforeDivider: CGFloat = 12.0
            let gapAfterDivider: CGFloat = 12.0
            let interColGap = gapBeforeDivider + gapAfterDivider
            let usableWidth = max(120.0, containerWidth - 2.0 * linePad - leftPad - rightPad - CGFloat(max(0, colCount - 1)) * interColGap)

            var naturalMax = Array(repeating: CGFloat(32.0), count: colCount)
            for rIdx in parsedRows.indices where !parsedRows[rIdx].isDelimiter {
                for cIdx in 0..<colCount {
                    if measuredWidths[rIdx][cIdx] > naturalMax[cIdx] {
                        naturalMax[cIdx] = measuredWidths[rIdx][cIdx]
                    }
                }
            }

            let leadingSum = colCount > 1 ? naturalMax[0..<(colCount - 1)].reduce(0, +) : 0
            let canAlignColumns = colCount == 1 || (leadingSum <= usableWidth - 72.0)

            var dividerOffsets: [CGFloat] = []
            if canAlignColumns {
                var colWidths = naturalMax
                if colCount > 1 {
                    colWidths[colCount - 1] = max(72.0, usableWidth - leadingSum)
                } else {
                    colWidths[0] = usableWidth
                }
                var columnStartIndents: [CGFloat] = Array(repeating: leftPad, count: colCount)
                for cIdx in 1..<colCount {
                    columnStartIndents[cIdx] = columnStartIndents[cIdx - 1] + colWidths[cIdx - 1] + interColGap
                    dividerOffsets.append(round(linePad + columnStartIndents[cIdx] - gapAfterDivider))
                }
                let lastColIndent = columnStartIndents.last ?? leftPad
                for (rIdx, row) in parsedRows.enumerated() where !row.isDelimiter {
                    let isLastRow = (rIdx == parsedRows.count - 1)
                    let rowPara = NSMutableParagraphStyle()
                    rowPara.firstLineHeadIndent = leftPad
                    rowPara.headIndent = lastColIndent
                    rowPara.tailIndent = -rightPad
                    rowPara.lineSpacing = 4.0
                    rowPara.paragraphSpacingBefore = row.isHeader ? 8.0 : 5.0
                    rowPara.paragraphSpacing = row.isHeader ? 7.0 : (isLastRow ? 14.0 : 6.0)
                    storage.addAttribute(.paragraphStyle, value: rowPara, range: row.fullLineRange)

                    let limit = min(colCount - 1, row.cells.count - 1)
                    if limit >= 0 {
                        for cIdx in 0..<limit {
                            let nextCell = row.cells[cIdx + 1]
                            if let pipeLoc = nextCell.openPipeLocation, pipeLoc < totalLen {
                                let w = measuredWidths[rIdx][cIdx]
                                let advance = max(8.0, (colWidths[cIdx] - w) + interColGap)
                                storage.addAttribute(.kern, value: advance, range: NSRange(location: pipeLoc, length: 1))
                            }
                        }
                    }
                }
            } else {
                // Fallback for wide multi-column tables in narrow windows: show subtle pipe separators and wrap cleanly without overflowing column dividers
                let pipeSeparatorAttrs: [NSAttributedString.Key: Any] = [
                    .font: Theme.monoFont(proseSize - 2.5, weight: .semibold),
                    .foregroundColor: Theme.subtle,
                    .kern: 6.0
                ]
                for (rIdx, row) in parsedRows.enumerated() where !row.isDelimiter {
                    let isLastRow = (rIdx == parsedRows.count - 1)
                    let rowPara = NSMutableParagraphStyle()
                    rowPara.firstLineHeadIndent = leftPad
                    rowPara.headIndent = leftPad + 12.0
                    rowPara.tailIndent = -rightPad
                    rowPara.lineSpacing = 4.0
                    rowPara.paragraphSpacingBefore = row.isHeader ? 8.0 : 5.0
                    rowPara.paragraphSpacing = row.isHeader ? 7.0 : (isLastRow ? 14.0 : 6.0)
                    storage.addAttribute(.paragraphStyle, value: rowPara, range: row.fullLineRange)
                    for cIdx in 1..<row.cells.count {
                        if let pipeLoc = row.cells[cIdx].openPipeLocation, pipeLoc < totalLen {
                            storage.addAttributes(pipeSeparatorAttrs, range: NSRange(location: pipeLoc, length: 1))
                            if pipeLoc > row.lineRange.location {
                                storage.addAttribute(.kern, value: CGFloat(6.0), range: NSRange(location: pipeLoc - 1, length: 1))
                            }
                        }
                    }
                }
            }

            let lastRow = parsedRows.last!
            let tableFullRange = NSRange(
                location: headerInfo.lineRange.location,
                length: NSMaxRange(lastRow.lineRange) - headerInfo.lineRange.location
            )
            let rowItems = parsedRows.map {
                MarkdownTextView.TableRowItem(
                    lineRange: $0.lineRange,
                    fullLineRange: $0.fullLineRange,
                    isHeader: $0.isHeader,
                    isDelimiter: $0.isDelimiter
                )
            }
            result.append(MarkdownTextView.TableBlock(
                fullRange: tableFullRange,
                headerRange: headerInfo.lineRange,
                delimiterRange: delimInfo.lineRange,
                rows: rowItems,
                columnDividerOffsets: dividerOffsets
            ))
        }
        return result
    }

    private static func isTableDelimiterRow(in ns: NSString, lineRange: NSRange) -> Bool {
        guard lineRange.length >= 3, NSMaxRange(lineRange) <= ns.length else { return false }
        var pipeCount = 0
        var dashCount = 0
        var hasOther = false
        for idx in lineRange.location..<NSMaxRange(lineRange) {
            let ch = ns.character(at: idx)
            if ch == 0x7C { pipeCount += 1 }
            else if ch == 0x2D { dashCount += 1 }
            else if ch == 0x3A || ch == 0x20 || ch == 0x09 { continue }
            else { hasOther = true; break }
        }
        return !hasOther && pipeCount >= 1 && dashCount >= 3
    }

    private static func parseTableRow(
        in ns: NSString,
        lineRange: NSRange,
        fullLineRange: NSRange,
        isHeader: Bool,
        isDelimiter: Bool
    ) -> ParsedTableRow? {
        guard lineRange.length > 0, NSMaxRange(lineRange) <= ns.length else { return nil }
        var start = lineRange.location
        var end = NSMaxRange(lineRange)
        while start < end && (ns.character(at: start) == 0x20 || ns.character(at: start) == 0x09) {
            start += 1
        }
        while end > start && (ns.character(at: end - 1) == 0x20 || ns.character(at: end - 1) == 0x09) {
            end -= 1
        }
        guard end > start else { return nil }

        var pipeLocs: [Int] = []
        var inBackticks = false
        var escaped = false
        for idx in start..<end {
            let ch = ns.character(at: idx)
            if escaped {
                escaped = false
                continue
            }
            if ch == 0x5C {
                escaped = true
                continue
            }
            if ch == 0x60 {
                inBackticks.toggle()
                continue
            }
            if !inBackticks && ch == 0x7C {
                pipeLocs.append(idx)
            }
        }
        guard !pipeLocs.isEmpty else { return nil }
        let startsWithPipe = (pipeLocs.first == start)
        let endsWithPipe = (pipeLocs.last == end - 1)
        guard startsWithPipe || endsWithPipe || pipeLocs.count >= 2 else { return nil }

        var boundaries: [Int] = []
        if !startsWithPipe { boundaries.append(start - 1) }
        boundaries.append(contentsOf: pipeLocs)
        if !endsWithPipe { boundaries.append(end) }
        guard boundaries.count >= 2 else { return nil }

        var cells: [ParsedTableCell] = []
        cells.reserveCapacity(boundaries.count - 1)
        for bIdx in 0..<(boundaries.count - 1) {
            let leftBoundary = boundaries[bIdx]
            let rightBoundary = boundaries[bIdx + 1]
            let hasOpenPipe = leftBoundary >= start && leftBoundary < end && ns.character(at: leftBoundary) == 0x7C
            let openPipeLoc: Int? = hasOpenPipe ? leftBoundary : nil
            let rawStart = hasOpenPipe ? (leftBoundary + 1) : start
            let rawEnd = rightBoundary
            var cStart = rawStart
            var cEnd = rawEnd
            while cStart < cEnd && (ns.character(at: cStart) == 0x20 || ns.character(at: cStart) == 0x09) {
                cStart += 1
            }
            while cEnd > cStart && (ns.character(at: cEnd - 1) == 0x20 || ns.character(at: cEnd - 1) == 0x09) {
                cEnd -= 1
            }
            let leadLoc = (bIdx == 0) ? lineRange.location : (openPipeLoc ?? rawStart)
            let leadingSyntax = NSRange(location: leadLoc, length: max(0, cStart - leadLoc))
            let content = NSRange(location: cStart, length: max(0, cEnd - cStart))
            let trailingSyntax = NSRange(location: cEnd, length: max(0, rawEnd - cEnd))
            cells.append(ParsedTableCell(
                openPipeLocation: openPipeLoc,
                leadingSyntaxRange: leadingSyntax,
                contentRange: content,
                trailingSyntaxRange: trailingSyntax
            ))
        }

        let closingStart = endsWithPipe ? pipeLocs.last! : end
        let closingSyntax = NSRange(location: closingStart, length: max(0, NSMaxRange(lineRange) - closingStart))
        return ParsedTableRow(
            lineRange: lineRange,
            fullLineRange: fullLineRange,
            isHeader: isHeader,
            isDelimiter: isDelimiter,
            cells: cells,
            closingSyntaxRange: closingSyntax
        )
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

    private static func shiftNoteTag(_ item: NoteTag, by delta: Int) -> NoteTag {
        NoteTag(
            name: item.name,
            fullRange: NSRange(location: item.fullRange.location + delta, length: item.fullRange.length),
            nameRange: NSRange(location: item.nameRange.location + delta, length: item.nameRange.length)
        )
    }

    private static func shiftMarkdownLink(_ item: MarkdownTextView.MarkdownLink, by delta: Int) -> MarkdownTextView.MarkdownLink {
        MarkdownTextView.MarkdownLink(
            fullRange: NSRange(location: item.fullRange.location + delta, length: item.fullRange.length),
            labelRange: NSRange(location: item.labelRange.location + delta, length: item.labelRange.length),
            rawDestination: item.rawDestination,
            resolvedURL: item.resolvedURL
        )
    }

    private static func shiftInlineImage(_ item: MarkdownTextView.InlineImageItem, by delta: Int) -> MarkdownTextView.InlineImageItem {
        MarkdownTextView.InlineImageItem(
            fullRange: shiftRange(item.fullRange, by: delta),
            lineRange: shiftRange(item.lineRange, by: delta),
            fullLineRange: shiftRange(item.fullLineRange, by: delta),
            altText: item.altText,
            caption: item.caption,
            rawDestination: item.rawDestination,
            resolvedURL: item.resolvedURL,
            naturalPointSize: item.naturalPointSize,
            displaySize: item.displaySize,
            itemSlotHeight: item.itemSlotHeight,
            offsetFromParagraphBottom: item.offsetFromParagraphBottom,
            isStandaloneLine: item.isStandaloneLine,
            isReadableImage: item.isReadableImage
        )
    }

    private func resolveLocalImageDestination(_ rawDestination: String) -> URL? {
        let trimmed = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("#"),
              !trimmed.contains("://") else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("mailto:") || lower.hasPrefix("data:") || lower.hasPrefix("javascript:") {
            return nil
        }
        let pathPart = trimmed.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? trimmed
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        guard !decoded.isEmpty, !decoded.contains("\0"), Vault.isImageFilename(decoded) else {
            return nil
        }
        let fm = FileManager.default
        let vaultRoot = vaultRootURLProvider?()?.standardizedFileURL.resolvingSymlinksInPath()

        func validated(_ rawCandidate: URL) -> URL? {
            let std = rawCandidate.standardizedFileURL
            if let attrs = try? fm.attributesOfItem(atPath: std.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                return nil
            }
            let resolved = std.resolvingSymlinksInPath()
            if let vaultRoot {
                let prefix = vaultRoot.path == "/" ? "/" : vaultRoot.path + "/"
                guard resolved.path == vaultRoot.path || resolved.path.hasPrefix(prefix) else {
                    return nil
                }
            }
            return resolved
        }

        if let noteURL = currentNoteURLProvider?() {
            let noteDir = noteURL.deletingLastPathComponent()
            guard let primary = validated(noteDir.appendingPathComponent(decoded)) else {
                return nil
            }
            if fm.fileExists(atPath: primary.path) {
                return primary
            }
            if let vaultRoot,
               let fallback = validated(vaultRoot.appendingPathComponent(decoded)),
               fm.fileExists(atPath: fallback.path) {
                return fallback
            }
            return primary
        }
        if let vaultRoot {
            return validated(vaultRoot.appendingPathComponent(decoded))
        }
        return nil
    }

    private static func inlineImageCaption(altText: String, resolvedURL: URL) -> String? {
        let trimmed = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let filename = resolvedURL.lastPathComponent
        if trimmed.caseInsensitiveCompare(filename) == .orderedSame {
            return nil
        }
        let stem = resolvedURL.deletingPathExtension().lastPathComponent
        if trimmed.caseInsensitiveCompare(stem) == .orderedSame,
           trimmed.hasPrefix("Screenshot-") || !trimmed.contains(" ") {
            return nil
        }
        return trimmed
    }

    private struct ParsedInlineLink {
        let fullRange: NSRange
        let bracketRange: NSRange
        let labelInnerRange: NSRange
        let parenRange: NSRange
        let rawDestination: String
        let isImage: Bool
    }

    private static func parseInlineMarkdownLinks(in ns: NSString, lineRange: NSRange) -> [ParsedInlineLink] {
        let start = lineRange.location
        var end = NSMaxRange(lineRange)
        while end > start {
            let ch = ns.character(at: end - 1)
            if ch == 10 || ch == 13 { end -= 1 } else { break }
        }
        guard end - start >= 4 else { return [] }
        var results: [ParsedInlineLink] = []
        var idx = start
        while idx < end {
            let ch = ns.character(at: idx)
            if ch == 0x5C { // '\'
                idx += 2
                continue
            }
            guard ch == 0x5B else { // '['
                idx += 1
                continue
            }
            let isImage = (idx > start && ns.character(at: idx - 1) == 0x21)
            let fullStart = isImage ? (idx - 1) : idx
            var p = idx + 1
            var bracketDepth = 1
            var closeBracket: Int?
            while p < end {
                let c = ns.character(at: p)
                if c == 0x5C {
                    p += 2
                    continue
                }
                if c == 0x5B {
                    bracketDepth += 1
                } else if c == 0x5D {
                    bracketDepth -= 1
                    if bracketDepth == 0 {
                        closeBracket = p
                        break
                    }
                }
                p += 1
            }
            guard let closeB = closeBracket, closeB + 1 < end, ns.character(at: closeB + 1) == 0x28 else {
                idx += 1
                continue
            }
            let openParen = closeB + 1
            var d = openParen + 1
            while d < end && (ns.character(at: d) == 0x20 || ns.character(at: d) == 0x09) {
                d += 1
            }
            guard d < end else {
                idx += 1
                continue
            }
            var rawDest: String?
            var closeParen: Int?
            if ns.character(at: d) == 0x3C { // '<...>'
                var a = d + 1
                var angleClose: Int?
                while a < end {
                    let c = ns.character(at: a)
                    if c == 0x5C {
                        a += 2
                        continue
                    }
                    if c == 0x3C {
                        break
                    }
                    if c == 0x3E {
                        angleClose = a
                        break
                    }
                    a += 1
                }
                if let ac = angleClose {
                    let destStr = ns.substring(with: NSRange(location: d + 1, length: ac - (d + 1)))
                    var t = ac + 1
                    while t < end && (ns.character(at: t) == 0x20 || ns.character(at: t) == 0x09) {
                        t += 1
                    }
                    if t < end && (ns.character(at: t) == 0x22 || ns.character(at: t) == 0x27) {
                        let quote = ns.character(at: t)
                        t += 1
                        while t < end {
                            let qc = ns.character(at: t)
                            if qc == 0x5C { t += 2; continue }
                            if qc == quote { t += 1; break }
                            t += 1
                        }
                        while t < end && (ns.character(at: t) == 0x20 || ns.character(at: t) == 0x09) {
                            t += 1
                        }
                    }
                    if t < end && ns.character(at: t) == 0x29 {
                        rawDest = destStr
                        closeParen = t
                    }
                }
            } else {
                let destStart = d
                var parenDepth = 0
                while d < end {
                    let c = ns.character(at: d)
                    if c == 0x5C {
                        d += 2
                        continue
                    }
                    if (c == 0x20 || c == 0x09) && parenDepth == 0 {
                        break
                    }
                    if c == 0x28 {
                        parenDepth += 1
                    } else if c == 0x29 {
                        if parenDepth == 0 {
                            break
                        }
                        parenDepth -= 1
                    }
                    d += 1
                }
                let destEnd = d
                var t = d
                while t < end && (ns.character(at: t) == 0x20 || ns.character(at: t) == 0x09) {
                    t += 1
                }
                if t > destEnd, t < end, (ns.character(at: t) == 0x22 || ns.character(at: t) == 0x27) {
                    let quote = ns.character(at: t)
                    t += 1
                    var closedQuote = false
                    while t < end {
                        let qc = ns.character(at: t)
                        if qc == 0x5C { t += 2; continue }
                        if qc == quote { closedQuote = true; t += 1; break }
                        t += 1
                    }
                    while t < end && (ns.character(at: t) == 0x20 || ns.character(at: t) == 0x09) {
                        t += 1
                    }
                    if closedQuote, t < end, ns.character(at: t) == 0x29 {
                        rawDest = ns.substring(with: NSRange(location: destStart, length: destEnd - destStart))
                        closeParen = t
                    }
                } else if t < end && ns.character(at: t) == 0x29 {
                    rawDest = ns.substring(with: NSRange(location: destStart, length: destEnd - destStart))
                    closeParen = t
                }
            }
            guard let cp = closeParen, let dest = rawDest else {
                idx += 1
                continue
            }
            results.append(ParsedInlineLink(
                fullRange: NSRange(location: fullStart, length: cp - fullStart + 1),
                bracketRange: NSRange(location: fullStart, length: closeB - fullStart + 1),
                labelInnerRange: NSRange(location: idx + 1, length: closeB - (idx + 1)),
                parenRange: NSRange(location: openParen, length: cp - openParen + 1),
                rawDestination: dest,
                isImage: isImage
            ))
            idx = cp + 1
        }
        return results
    }

    private static let nonWebBareExtensions: Set<String> = [
        "md", "markdown", "txt", "rtf", "pdf",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "ico",
        "mp3", "mp4", "mov", "wav", "m4a", "zip", "tar", "gz",
        "json", "yaml", "yml", "toml", "xml", "csv", "tsv",
        "swift", "py", "rb", "rs", "go", "c", "cpp", "h", "hpp",
        "java", "kt", "cs", "php", "sql", "css", "scss", "tsx", "jsx", "lock", "sh"
    ]

    static func resolveExternalLinkDestination(_ rawDestination: String, allowSchemelessDomain: Bool) -> URL? {
        let trimmed = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") || trimmed == "." || trimmed == ".." {
            return nil
        }
        if trimmed.contains("\\") || trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("attachments/") {
            return nil
        }

        if let colonIdx = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<colonIdx])
            let afterColon = trimmed[trimmed.index(after: colonIdx)...]
            let isValidScheme = !prefix.isEmpty
                && prefix.first!.isASCII && prefix.first!.isLetter
                && prefix.unicodeScalars.allSatisfy {
                    ($0.value >= 0x41 && $0.value <= 0x5A)
                        || ($0.value >= 0x61 && $0.value <= 0x7A)
                        || ($0.value >= 0x30 && $0.value <= 0x39)
                        || $0.value == 0x2B || $0.value == 0x2D || $0.value == 0x2E
                }
            if isValidScheme {
                let schemeLower = prefix.lowercased()
                if schemeLower == "javascript" || schemeLower == "vbscript" || schemeLower == "data" || schemeLower == "file" {
                    return nil
                }
                if schemeLower == "mailto" {
                    let recipient = afterColon.trimmingCharacters(in: .whitespaces)
                    guard !recipient.isEmpty, !recipient.contains(" "), recipient.contains("@") else { return nil }
                    return URL(string: "mailto:\(recipient)")
                }
                if schemeLower == "http" || schemeLower == "https" {
                    guard afterColon.hasPrefix("//") else { return nil }
                    if let url = makeValidatedWebURL(trimmed) {
                        return url
                    }
                    return nil
                }
                if afterColon.hasPrefix("//") {
                    return URL(string: trimmed)
                }
                if allowSchemelessDomain, schemeLower == "localhost",
                   let firstAfter = afterColon.first, firstAfter.isNumber {
                    return makeValidatedWebURL("http://" + trimmed)
                }
                return nil
            }
        }

        guard allowSchemelessDomain, !trimmed.contains(" ") else { return nil }
        let pathBreak = trimmed.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? trimmed.endIndex
        let authority = String(trimmed[..<pathBreak])
        let hasPathOrQuery = pathBreak < trimmed.endIndex
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        let hostPart: String
        if let portColon = authority.firstIndex(of: ":") {
            let portStr = authority[authority.index(after: portColon)...]
            guard !portStr.isEmpty, portStr.allSatisfy(\.isNumber) else { return nil }
            hostPart = String(authority[..<portColon])
        } else {
            hostPart = authority
        }
        guard hostPart.contains("."),
              !hostPart.hasPrefix("."),
              !hostPart.hasSuffix("."),
              !hostPart.contains(".."),
              hostPart.unicodeScalars.allSatisfy({
                  ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || ($0.value >= 0x30 && $0.value <= 0x39)
                      || $0.value == 0x2D || $0.value == 0x2E
              }),
              let lastDot = hostPart.lastIndex(of: ".") else {
            return nil
        }
        let tld = String(hostPart[hostPart.index(after: lastDot)...]).lowercased()
        guard tld.count >= 2, tld.count <= 24,
              tld.unicodeScalars.allSatisfy({ $0.value >= 0x61 && $0.value <= 0x7A }) else {
            return nil
        }
        if !hasPathOrQuery && !hostPart.lowercased().hasPrefix("www.") && nonWebBareExtensions.contains(tld) {
            return nil
        }
        return makeValidatedWebURL("https://" + trimmed)
    }

    private static func makeValidatedWebURL(_ candidate: String) -> URL? {
        if let direct = URL(string: candidate), let host = direct.host, !host.isEmpty {
            return direct
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%[]")
        if let encoded = candidate.addingPercentEncoding(withAllowedCharacters: allowed),
           let fallback = URL(string: encoded),
           let host = fallback.host, !host.isEmpty {
            return fallback
        }
        return nil
    }

    private static func trimBareURLCandidate(_ rawRange: NSRange, in ns: NSString) -> NSRange? {
        guard rawRange.length > 0, NSMaxRange(rawRange) <= ns.length else { return nil }
        if rawRange.location > 0 {
            let prev = ns.character(at: rawRange.location - 1)
            let isWordPrev = (prev >= 0x41 && prev <= 0x5A)
                || (prev >= 0x61 && prev <= 0x7A)
                || (prev >= 0x30 && prev <= 0x39)
                || prev == 0x5F || prev == 0x2F || prev == 0x3A || prev == 0x3C
            if isWordPrev {
                return nil
            }
        }
        var end = NSMaxRange(rawRange)
        let start = rawRange.location
        while end > start {
            let last = ns.character(at: end - 1)
            if last == 0x2E || last == 0x2C || last == 0x3B || last == 0x3A
                || last == 0x21 || last == 0x3F || last == 0x27 || last == 0x22 {
                end -= 1
                continue
            }
            if last == 0x29 { // ')'
                var opens = 0
                var closes = 0
                for idx in start..<end {
                    let c = ns.character(at: idx)
                    if c == 0x28 { opens += 1 }
                    else if c == 0x29 { closes += 1 }
                }
                if closes > opens {
                    end -= 1
                    continue
                }
            } else if last == 0x5D { // ']'
                var opens = 0
                var closes = 0
                for idx in start..<end {
                    let c = ns.character(at: idx)
                    if c == 0x5B { opens += 1 }
                    else if c == 0x5D { closes += 1 }
                }
                if closes > opens {
                    end -= 1
                    continue
                }
            }
            break
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
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
        horizontalRules: inout [NSRange],
        headings: inout [MarkdownTextView.HeadingGutter],
        codes: inout [NSRange],
        wikiLinks: inout [WikiLink],
        tags: inout [NoteTag],
        markdownLinks: inout [MarkdownTextView.MarkdownLink],
        inlineImages: inout [MarkdownTextView.InlineImageItem],
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

        if targetRange.length < totalLen || scan == nil {
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
        let checkAutoLink = scan?.hasAutoLink ?? true
        let checkBacktick = scan?.hasBacktick ?? true
        let checkDoubleUnderscore = scan?.hasDoubleUnderscore ?? true
        let checkHTMLUnderline = scan?.hasHTMLUnderline ?? true
        let checkDoubleTilde = scan?.hasDoubleTilde ?? true

        let checkWikiLink = scan?.hasWikiLink ?? true
        let checkHash = scan?.hasHash ?? true
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

        let hasInlineLinkMarker = checkLink && ns.range(of: "](", options: .literal, range: targetRange).location != NSNotFound
        if hasInlineLinkMarker {
            hasPotentialLinks = true
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

        // 2. Line-anchored constructs (headings, blockquotes, horizontal rules, lists) by stepping line-by-line
        var linePos = targetRange.location
        let targetEnd = NSMaxRange(targetRange)
        let isFocused = textView.window?.firstResponder === textView
        var lazyQuoteParagraph: NSMutableParagraphStyle?
        var lazyHRParagraph: NSMutableParagraphStyle?
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
            } else if (c0 == 0x2D || c0 == 0x2A || c0 == 0x5F || c0 == 0x20)
                && Self.isHorizontalRuleLine(ns, lineStart: lineRange.location, contentEnd: contentEnd) {
                let matchRange = NSRange(location: lineRange.location, length: contentLen)
                horizontalRules.append(matchRange)
                let hrParagraph: NSMutableParagraphStyle
                if let existing = lazyHRParagraph {
                    hrParagraph = existing
                } else {
                    let created = NSMutableParagraphStyle()
                    created.lineSpacing = 6.0
                    created.paragraphSpacingBefore = 6.0
                    created.paragraphSpacing = 14.0
                    lazyHRParagraph = created
                    hrParagraph = created
                }
                let cursorOnRule = ((cursor.length == 0 && cursor.location >= matchRange.location && cursor.location <= NSMaxRange(matchRange))
                    || NSIntersectionRange(cursor, matchRange).length > 0) && isFocused
                storage.setAttributes([
                    .font: Theme.monoFont(proseSize - 2.0, weight: .semibold),
                    .foregroundColor: (cursorOnRule || compactLayout) ? Theme.subtle : NSColor.clear,
                    .paragraphStyle: hrParagraph,
                    .kern: 0.0
                ], range: matchRange)
            } else if c0 == 0x2D || c0 == 0x2A || c0 == 0x2B || c0 == 0x20 || c0 == 0x09 || (c0 >= 0x30 && c0 <= 0x39) {
                var p = lineRange.location
                while p < contentEnd {
                    let ch = ns.character(at: p)
                    if ch == 0x20 || ch == 0x09 { p += 1 } else { break }
                }
                guard p < contentEnd else {
                    // TextKit 1 / CoreText collapses glyph locations on whitespace-only lines when .kern is non-zero,
                    // causing the caret to snap back to column 0 after multiple spaces.
                    if tracking != 0 {
                        storage.addAttribute(.kern, value: CGFloat(0.0), range: NSRange(location: lineRange.location, length: contentLen))
                    }
                    continue
                }
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
                    let bulletMarkerRange: NSRange
                    if isTask {
                        kind = .task(completed: completed)
                        bulletMarkerRange = NSRange(
                            location: symbolRange.location,
                            length: max(symbolRange.length, NSMaxRange(markerRange) - symbolRange.location)
                        )
                    } else if isUnordered {
                        kind = .unordered
                        bulletMarkerRange = symbolRange
                    } else {
                        kind = .ordered
                        bulletMarkerRange = symbolRange
                    }
                    bullets.append(MarkdownTextView.BulletItem(
                        lineRange: fullMatchRange,
                        markerRange: bulletMarkerRange,
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

        var inlineLinkSpans: [NSRange] = []
        if hasInlineLinkMarker {
            struct PendingLineImage {
                let parsed: ParsedInlineLink
                let altText: String
                let caption: String?
                let resolvedURL: URL
                let naturalPointSize: NSSize?
                let displaySize: NSSize
                let itemSlotHeight: CGFloat
                let isReadable: Bool
            }
            let linkURLAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.subtle,
                .font: Theme.monoFont(12),
                .underlineStyle: 0,
                .strikethroughStyle: 0
            ]
            let bracketSyntaxAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.subtle,
                .font: Theme.monoFont(12, weight: .medium),
                .underlineStyle: 0,
                .strikethroughStyle: 0
            ]
            let containerWidth = textView.textContainer?.containerSize.width ?? 640
            let maxCardWidth = max(160, min(containerWidth, 680))
            let maxCardHeight: CGFloat = 420
            var searchStart = targetRange.location
            while searchStart < targetEnd {
                let hit = ns.range(of: "](", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let fullLineRange = ns.lineRange(for: hit)
                let lineRange = NSIntersectionRange(fullLineRange, targetRange)
                var pendingImages: [PendingLineImage] = []
                for parsed in Self.parseInlineMarkdownLinks(in: ns, lineRange: lineRange) {
                    if codes.contains(where: { NSIntersectionRange($0, parsed.fullRange).length > 0 })
                        || wikiLinks.contains(where: { NSIntersectionRange($0.fullRange, parsed.fullRange).length > 0 }) {
                        continue
                    }
                    inlineLinkSpans.append(parsed.fullRange)
                    let headingMatch = headings.first { NSIntersectionRange($0.range, parsed.fullRange).length > 0 }
                    let linkFont = headingMatch.map { Theme.headingFont(level: $0.level) } ?? Theme.bodyFont(proseSize, weight: .medium)
                    if parsed.isImage, let resolvedLocal = resolveLocalImageDestination(parsed.rawDestination) {
                        storage.addAttributes(bracketSyntaxAttrs, range: parsed.bracketRange)
                        if parsed.labelInnerRange.length > 0 {
                            storage.addAttributes([
                                .foregroundColor: Theme.accent,
                                .font: linkFont,
                                .underlineStyle: 0,
                                .strikethroughStyle: 0
                            ], range: parsed.labelInnerRange)
                        }
                        storage.addAttributes(linkURLAttrs, range: parsed.parenRange)
                        let altText = parsed.labelInnerRange.length > 0
                            ? ns.substring(with: parsed.labelInnerRange)
                            : ""
                        let caption = Self.inlineImageCaption(altText: altText, resolvedURL: resolvedLocal)
                        let metrics = InlineImageCache.shared.imageMetrics(for: resolvedLocal)
                        let naturalSize = metrics?.naturalPointSize
                        let displaySize: NSSize
                        let isReadable: Bool
                        if let nat = naturalSize, nat.width > 0, nat.height > 0 {
                            let fit = min(1.0, min(maxCardWidth / nat.width, maxCardHeight / nat.height))
                            displaySize = NSSize(
                                width: max(48, round(nat.width * fit)),
                                height: max(36, round(nat.height * fit))
                            )
                            isReadable = true
                        } else {
                            displaySize = NSSize(width: min(maxCardWidth, 320), height: 56)
                            isReadable = false
                        }
                        let slotHeight = 8 + displaySize.height + (caption == nil ? 0 : 20) + 14
                        pendingImages.append(PendingLineImage(
                            parsed: parsed,
                            altText: altText,
                            caption: caption,
                            resolvedURL: resolvedLocal,
                            naturalPointSize: naturalSize,
                            displaySize: displaySize,
                            itemSlotHeight: slotHeight,
                            isReadable: isReadable
                        ))
                        continue
                    }
                    if let resolved = Self.resolveExternalLinkDestination(parsed.rawDestination, allowSchemelessDomain: !parsed.isImage) {
                        storage.addAttributes(bracketSyntaxAttrs, range: parsed.bracketRange)
                        let clickableAttrs: [NSAttributedString.Key: Any] = [
                            .foregroundColor: Theme.accent,
                            .font: linkFont,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: Theme.accent.withAlphaComponent(0.45)
                        ]
                        let labelTarget = parsed.labelInnerRange.length > 0 ? parsed.labelInnerRange : parsed.bracketRange
                        storage.addAttributes(clickableAttrs, range: labelTarget)
                        storage.addAttributes(linkURLAttrs, range: parsed.parenRange)
                        markdownLinks.append(MarkdownTextView.MarkdownLink(
                            fullRange: parsed.fullRange,
                            labelRange: labelTarget,
                            rawDestination: parsed.rawDestination,
                            resolvedURL: resolved
                        ))
                    } else {
                        storage.addAttributes([.foregroundColor: Theme.accent, .font: linkFont], range: parsed.bracketRange)
                        storage.addAttributes(linkURLAttrs, range: parsed.parenRange)
                    }
                }
                if !pendingImages.isEmpty, NSMaxRange(fullLineRange) <= totalLen {
                    var contentEnd = NSMaxRange(fullLineRange)
                    while contentEnd > fullLineRange.location {
                        let ch = ns.character(at: contentEnd - 1)
                        if ch == 10 || ch == 13 { contentEnd -= 1 } else { break }
                    }
                    let lineContentRange = NSRange(location: fullLineRange.location, length: contentEnd - fullLineRange.location)
                    var trimStart = lineContentRange.location
                    var trimEnd = contentEnd
                    while trimStart < trimEnd && (ns.character(at: trimStart) == 0x20 || ns.character(at: trimStart) == 0x09) {
                        trimStart += 1
                    }
                    while trimEnd > trimStart && (ns.character(at: trimEnd - 1) == 0x20 || ns.character(at: trimEnd - 1) == 0x09) {
                        trimEnd -= 1
                    }
                    let trimmedRange = NSRange(location: trimStart, length: trimEnd - trimStart)
                    let isStandalone = pendingImages.count == 1
                        && pendingImages[0].parsed.fullRange == trimmedRange
                        && !headings.contains(where: { NSIntersectionRange($0.range, fullLineRange).length > 0 })
                        && !quotes.contains(where: { NSIntersectionRange($0, fullLineRange).length > 0 })
                        && !bullets.contains(where: { NSIntersectionRange($0.lineRange, fullLineRange).length > 0 })
                    let cursorOnLine = isFocused && (
                        (cursor.length == 0 && cursor.location >= lineContentRange.location && cursor.location <= NSMaxRange(lineContentRange))
                        || NSIntersectionRange(cursor, lineContentRange).length > 0
                    )
                    let showRawSyntax = !isStandalone || cursorOnLine || compactLayout
                    let totalSlotHeight = pendingImages.reduce(CGFloat(0)) { $0 + $1.itemSlotHeight }
                    if showRawSyntax {
                        let basePara = (lineContentRange.length > 0
                            ? (storage.attribute(.paragraphStyle, at: lineContentRange.location, effectiveRange: nil) as? NSParagraphStyle)
                            : nil)
                        let imgPara = (basePara?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                        if basePara == nil {
                            imgPara.lineSpacing = 8.0
                        }
                        imgPara.paragraphSpacing = totalSlotHeight
                        storage.addAttribute(.paragraphStyle, value: imgPara, range: fullLineRange)
                    } else {
                        let imgPara = NSMutableParagraphStyle()
                        imgPara.lineSpacing = 0.0
                        imgPara.paragraphSpacing = totalSlotHeight
                        storage.setAttributes([
                            .font: NSFont.systemFont(ofSize: 1.0),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: imgPara,
                            .kern: 0.0
                        ], range: fullLineRange)
                    }
                    var consumedSlot: CGFloat = 0
                    for pending in pendingImages {
                        let offsetFromBottom = totalSlotHeight - consumedSlot
                        consumedSlot += pending.itemSlotHeight
                        inlineImages.append(MarkdownTextView.InlineImageItem(
                            fullRange: pending.parsed.fullRange,
                            lineRange: lineContentRange,
                            fullLineRange: fullLineRange,
                            altText: pending.altText,
                            caption: pending.caption,
                            rawDestination: pending.parsed.rawDestination,
                            resolvedURL: pending.resolvedURL,
                            naturalPointSize: pending.naturalPointSize,
                            displaySize: pending.displaySize,
                            itemSlotHeight: pending.itemSlotHeight,
                            offsetFromParagraphBottom: offsetFromBottom,
                            isStandaloneLine: isStandalone,
                            isReadableImage: pending.isReadable
                        ))
                    }
                }
                searchStart = NSMaxRange(lineRange)
            }
        }

        if (checkHTMLUnderline || checkAutoLink) && ns.range(of: "<", options: .literal, range: targetRange).location != NSNotFound {
            let angleBracketAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.subtle, .font: Theme.monoFont(12)]
            var searchStart = targetRange.location
            while searchStart < targetEnd {
                let hit = ns.range(of: "<", options: .literal, range: NSRange(location: searchStart, length: targetEnd - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = NSIntersectionRange(ns.lineRange(for: hit), targetRange)
                let lineStr = ns.substring(with: lineRange)
                for match in angleAutolink.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                    let full = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    if codes.contains(where: { NSIntersectionRange($0, full).length > 0 })
                        || wikiLinks.contains(where: { NSIntersectionRange($0.fullRange, full).length > 0 })
                        || inlineLinkSpans.contains(where: { NSIntersectionRange($0, full).length > 0 }) {
                        continue
                    }
                    let innerSub = match.range(at: 1)
                    let innerRange = NSRange(location: lineRange.location + innerSub.location, length: innerSub.length)
                    let rawDest = ns.substring(with: innerRange)
                    guard let resolved = Self.resolveExternalLinkDestination(rawDest, allowSchemelessDomain: false) else { continue }
                    let headingMatch = headings.first { NSIntersectionRange($0.range, full).length > 0 }
                    let linkFont = headingMatch.map { Theme.headingFont(level: $0.level) } ?? Theme.bodyFont(proseSize, weight: .medium)
                    storage.addAttributes([
                        .foregroundColor: Theme.accent,
                        .font: linkFont,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: Theme.accent.withAlphaComponent(0.45)
                    ], range: innerRange)
                    storage.addAttributes(angleBracketAttrs, range: NSRange(location: full.location, length: 1))
                    storage.addAttributes(angleBracketAttrs, range: NSRange(location: NSMaxRange(full) - 1, length: 1))
                    markdownLinks.append(MarkdownTextView.MarkdownLink(
                        fullRange: full,
                        labelRange: innerRange,
                        rawDestination: rawDest,
                        resolvedURL: resolved
                    ))
                }
                searchStart = NSMaxRange(lineRange)
            }
        }

        if checkAutoLink {
            let hasSchemeSep = ns.range(of: "://", options: .literal, range: targetRange).location != NSNotFound
            let hasMailto = ns.range(of: "mailto:", options: .caseInsensitive, range: targetRange).location != NSNotFound
            if hasSchemeSep || hasMailto {
                var searchStart = targetRange.location
                while searchStart < targetEnd {
                    let rem = NSRange(location: searchStart, length: targetEnd - searchStart)
                    let hit1 = hasSchemeSep ? ns.range(of: "://", options: .literal, range: rem) : NSRange(location: NSNotFound, length: 0)
                    let hit2 = hasMailto ? ns.range(of: "mailto:", options: .caseInsensitive, range: rem) : NSRange(location: NSNotFound, length: 0)
                    let nextLoc: Int
                    if hit1.location != NSNotFound && hit2.location != NSNotFound {
                        nextLoc = min(hit1.location, hit2.location)
                    } else if hit1.location != NSNotFound {
                        nextLoc = hit1.location
                    } else if hit2.location != NSNotFound {
                        nextLoc = hit2.location
                    } else {
                        break
                    }
                    let lineRange = NSIntersectionRange(ns.lineRange(for: NSRange(location: nextLoc, length: 0)), targetRange)
                    let lineStr = ns.substring(with: lineRange)
                    for match in bareURL.matches(in: lineStr, range: NSRange(location: 0, length: lineRange.length)) {
                        let rawFull = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                        guard let trimmedFull = Self.trimBareURLCandidate(rawFull, in: ns) else { continue }
                        if codes.contains(where: { NSIntersectionRange($0, trimmedFull).length > 0 })
                            || wikiLinks.contains(where: { NSIntersectionRange($0.fullRange, trimmedFull).length > 0 })
                            || inlineLinkSpans.contains(where: { NSIntersectionRange($0, trimmedFull).length > 0 })
                            || markdownLinks.contains(where: { NSIntersectionRange($0.fullRange, trimmedFull).length > 0 }) {
                            continue
                        }
                        let rawDest = ns.substring(with: trimmedFull)
                        guard let resolved = Self.resolveExternalLinkDestination(rawDest, allowSchemelessDomain: false) else { continue }
                        let headingMatch = headings.first { NSIntersectionRange($0.range, trimmedFull).length > 0 }
                        let linkFont = headingMatch.map { Theme.headingFont(level: $0.level) } ?? Theme.bodyFont(proseSize, weight: .medium)
                        storage.addAttributes([
                            .foregroundColor: Theme.accent,
                            .font: linkFont,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: Theme.accent.withAlphaComponent(0.45)
                        ], range: trimmedFull)
                        markdownLinks.append(MarkdownTextView.MarkdownLink(
                            fullRange: trimmedFull,
                            labelRange: trimmedFull,
                            rawDestination: rawDest,
                            resolvedURL: resolved
                        ))
                    }
                    searchStart = max(nextLoc + 1, NSMaxRange(lineRange))
                }
            }
        }

        if markdownLinks.count > 1 {
            markdownLinks.sort { $0.fullRange.location < $1.fullRange.location }
        }

        if checkHash && ns.range(of: "#", options: .literal, range: targetRange).location != NSNotFound {
            let tagFont = Theme.monoFont(proseSize - 1.5, weight: .medium)
            let hashAttrs: [NSAttributedString.Key: Any] = [
                .font: tagFont,
                .foregroundColor: Theme.sage.withAlphaComponent(0.72),
                .kern: 0.1
            ]
            let tagAttrs: [NSAttributedString.Key: Any] = [
                .font: tagFont,
                .foregroundColor: Theme.sage,
                .kern: 0.1
            ]
            let parsedTags = Vault.tags(inNSString: ns, range: targetRange)
            for item in parsedTags {
                if codes.contains(where: { NSIntersectionRange($0, item.fullRange).length > 0 })
                    || wikiLinks.contains(where: { NSIntersectionRange($0.fullRange, item.fullRange).length > 0 })
                    || inlineLinkSpans.contains(where: { NSIntersectionRange($0, item.fullRange).length > 0 })
                    || markdownLinks.contains(where: { NSIntersectionRange($0.fullRange, item.fullRange).length > 0 }) {
                    continue
                }
                tags.append(item)
                storage.addAttributes(hashAttrs, range: NSRange(location: item.fullRange.location, length: 1))
                storage.addAttributes(tagAttrs, range: item.nameRange)
            }
        }
    }
}

extension CaptureEditor: VimHost {
    var vimNSString: NSString { nsText }

    var vimSelectedRange: NSRange {
        get { textView.selectedRange() }
        set { textView.setSelectedRange(newValue) }
    }

    var vimUndoManager: UndoManager? { textView.undoManager }

    var vimHasMarkedText: Bool { textView.hasMarkedText() }

    var vimIsWikiAutocompleteVisible: Bool { isWikiAutocompleteVisible }

    func vimDismissWikiAutocomplete() {
        dismissedWikiOpenLocation = activeWikiOpenLocation
        hideWikiAutocomplete()
    }

    func vimReplace(in range: NSRange, with replacement: String, selectedRangeAfter: NSRange?) {
        textView.applyUndoableReplacement(in: range, with: replacement, selectedRangeAfter: selectedRangeAfter)
    }

    func vimRegisterCoalescedUndo(inverseRange: NSRange, previousString: String, restoreSelection: NSRange) {
        textView.registerCoalescedUndo(inverseRange: inverseRange, previousString: previousString, restoreSelection: restoreSelection)
    }

    func vimIsCharacterFolded(_ location: Int) -> Bool {
        textView.isCharacterFolded(location)
    }

    func vimFoldedRangeEnclosing(_ location: Int) -> NSRange? {
        textView.foldedRangeEnclosing(location)
    }

    func vimHeadingLocations() -> [Int] {
        textView.headingGutterItems.map(\.range.location)
    }

    func vimToggleFoldAtCursor() {
        textView.toggleHeadingFoldAtCursor(nil)
        textView.vim.clampSelectionIfNeeded()
        if isOutlineVisible { refreshOutline() }
    }

    func vimOpenFoldAtCursor() {
        textView.unfoldHeadingAtCursor(nil)
        textView.vim.clampSelectionIfNeeded()
        if isOutlineVisible { refreshOutline() }
    }

    func vimCloseFoldAtCursor() {
        textView.foldHeadingAtCursor(nil)
        textView.vim.clampSelectionIfNeeded()
        if isOutlineVisible { refreshOutline() }
    }

    func vimUnfoldAllHeadings() {
        textView.unfoldAllHeadings(nil)
        textView.vim.clampSelectionIfNeeded()
        if isOutlineVisible { refreshOutline() }
    }

    func vimFoldAllHeadings() {
        textView.foldAllHeadings(nil)
        textView.vim.clampSelectionIfNeeded()
        if isOutlineVisible { refreshOutline() }
    }

    func vimCycleOutlineFolding() {
        textView.cycleOutlineFolding(nil)
        textView.vim.clampSelectionIfNeeded()
        if isOutlineVisible { refreshOutline() }
    }

    func vimOpenWikiLinkAtCursor(inNewWindow: Bool) -> Bool {
        if let link = textView.wikiLinkAtCursor() {
            if inNewWindow {
                onOpenWikiLinkInNewWindow?(link)
            } else {
                onOpenWikiLink?(link)
            }
            return true
        }
        if let mdLink = textView.markdownLinkAtCursor() {
            openMarkdownLink(mdLink)
            return true
        }
        return false
    }

    func vimToggleTaskAt(range: NSRange) -> Bool {
        textView.toggleTaskCompletion(in: range)
    }

    func vimEnsureCaretVisible(typewriter: Bool) {
        textView.ensureCaretVisible(useTypewriterStep: typewriter)
    }

    func vimScrollCursorLine(alignment: VimScrollAlignment) {
        textView.scrollCursorLine(alignment: alignment)
    }

    func vimScrollByHalfPages(_ halfPages: Int) -> Int? {
        textView.scrollByHalfPages(halfPages)
    }

    func vimViewportLineTarget(_ target: VimViewportTarget) -> Int? {
        textView.viewportLineTarget(target)
    }

    func vimVisualLineVerticalTarget(from location: Int, deltaLines: Int, preferredX: inout CGFloat?) -> Int? {
        textView.visualLineVerticalTarget(from: location, deltaLines: deltaLines, preferredX: &preferredX)
    }

    func vimVisualLineBoundary(from location: Int, kind: VimVisualBoundaryKind) -> Int? {
        textView.visualLineBoundary(from: location, kind: kind)
    }

    func vimBeginSearch(direction: VimSearchDirection) {
        vimSearchOriginLocation = textView.vim.activeBlockCursorLocation ?? textView.selectedRange().location
        vimSearchDirection = direction
        vimSearchWholeWord = false
        isVimSearchingPrompt = true
        inNoteFindBar.searchBar.field.placeholderString = direction == .forward ? "Search forward (/)…" : "Search backward (?)…"
        inNoteFindBar.query = ""
        inNoteFindBar.isHidden = false
        updateInNoteFindMatches(scrollToMatch: false)
        inNoteFindBar.focusField()
    }

    func vimFindMatchLocation(from location: Int, reverse: Bool, count: Int, inclusiveCurrent: Bool) -> NSRange? {
        let q = inNoteFindBar.query
        guard !q.isEmpty else {
            status.stringValue = "No previous search pattern"
            return nil
        }
        let ranges = computeFindRanges(for: q, wholeWord: vimSearchWholeWord, in: nsText)
        textView.inNoteFindRanges = ranges
        guard !ranges.isEmpty else {
            textView.activeInNoteFindIndex = -1
            inNoteFindBar.countLabel.stringValue = "0 MATCHES"
            status.stringValue = "Pattern not found: \(q)"
            textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
            return nil
        }
        let forward = (vimSearchDirection == .forward) ? !reverse : reverse
        let steps = max(1, count)
        var idx: Int
        if forward {
            idx = ranges.firstIndex(where: { inclusiveCurrent ? ($0.location >= location) : ($0.location > location) }) ?? 0
            idx = (idx + steps - 1) % ranges.count
        } else {
            idx = ranges.lastIndex(where: { inclusiveCurrent ? ($0.location <= location) : ($0.location < location) }) ?? (ranges.count - 1)
            let offset = (steps - 1) % ranges.count
            idx = (idx - offset + ranges.count) % ranges.count
        }
        textView.activeInNoteFindIndex = idx
        let matchRange = ranges[idx]
        if textView.isCharacterFolded(matchRange.location) {
            textView.unfoldSectionsIntersecting(matchRange)
        }
        inNoteFindBar.countLabel.stringValue = "\(idx + 1) OF \(ranges.count)"
        status.stringValue = ""
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: true)
        return matchRange
    }

    func vimSearchWord(_ word: String, forward: Bool, count: Int) -> NSRange? {
        vimSearchDirection = forward ? .forward : .backward
        isVimSearchingPrompt = false
        inNoteFindBar.searchBar.field.placeholderString = "Find in note…"
        inNoteFindBar.query = word
        vimSearchWholeWord = true
        let cursor = textView.vim.activeBlockCursorLocation ?? textView.selectedRange().location
        return vimFindMatchLocation(from: cursor, reverse: false, count: count, inclusiveCurrent: false)
    }

    func vimDismissSearchHighlightsIfNeeded() -> Bool {
        var dismissed = false
        if isLinkActionBarVisible {
            hideLinkActionBar(animated: true)
            dismissed = true
        }
        if !inNoteFindBar.isHidden || !textView.inNoteFindRanges.isEmpty {
            hideInNoteFind()
            dismissed = true
        }
        return dismissed
    }

    func vimSetStatus(_ message: String) {
        status.stringValue = message
    }

    func vimDidUpdateState() {
        updateVimChrome()
        textView.refreshCaretAppearance()
        textView.updateCaret()
    }
}
