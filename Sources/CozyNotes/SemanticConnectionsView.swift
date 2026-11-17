import AppKit
import CozyCore
import CozySearch

@MainActor final class SemanticCategoryBadge: NSView {
    var text: String = "TAGS & LINKS" {
        didSet {
            if text != oldValue {
                invalidateIntrinsicContentSize()
                setAccessibilityValue(text)
                needsDisplay = true
            }
        }
    }

    var isHighlightedCategory: Bool = false {
        didSet {
            if isHighlightedCategory != oldValue {
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Suggested category")
        setAccessibilityValue(text)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let font = Theme.monoFont(9.5, weight: .semibold)
        let width = (text as NSString).size(withAttributes: [.font: font, .kern: 0.4]).width
        return NSSize(width: ceil(width) + 14, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let fill = isHighlightedCategory ? Theme.sage.withAlphaComponent(0.14) : Theme.elevated
        let border = isHighlightedCategory ? Theme.sage.withAlphaComponent(0.45) : Theme.border
        let ink = isHighlightedCategory ? Theme.sage : Theme.muted
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.monoFont(9.5, weight: .semibold),
            .foregroundColor: ink,
            .kern: 0.4
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pt = NSPoint(
            x: round((bounds.width - size.width) * 0.5),
            y: round((bounds.height - size.height) * 0.5)
        )
        (text as NSString).draw(at: pt, withAttributes: attrs)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor final class SemanticTagPillButton: NSButton {
    let tagName: String
    let isExistingVaultTag: Bool
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(tagName: String, isExistingVaultTag: Bool, target: AnyObject?, action: Selector?) {
        self.tagName = tagName
        self.isExistingVaultTag = isExistingVaultTag
        super.init(frame: .zero)
        self.title = "+ #\(tagName)"
        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .exterior
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel("Insert tag #\(tagName)")
        toolTip = isExistingVaultTag
            ? "Insert #\(tagName) (existing vault tag · ⌘Z to undo)"
            : "Insert #\(tagName) (suggested tag · ⌘Z to undo)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let font = Theme.monoFont(10.5, weight: .medium)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 16, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let pressed = cell?.isHighlighted == true

        let fill: NSColor
        let border: NSColor
        let ink: NSColor
        if pressed {
            fill = Theme.accentSoft
            border = Theme.accent.withAlphaComponent(0.65)
            ink = Theme.accent
        } else if hovered {
            fill = isExistingVaultTag ? Theme.accentSoft : Theme.selectionFill
            border = Theme.accent.withAlphaComponent(0.50)
            ink = isExistingVaultTag ? Theme.accent : Theme.headingInk
        } else if isExistingVaultTag {
            fill = Theme.accentSoft.withAlphaComponent(0.65)
            border = Theme.accent.withAlphaComponent(0.35)
            ink = Theme.accent
        } else {
            fill = Theme.paper
            border = Theme.border
            ink = Theme.ink
        }

        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.monoFont(10.5, weight: .medium),
            .foregroundColor: ink
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        let pt = NSPoint(
            x: round((bounds.width - size.width) * 0.5),
            y: round((bounds.height - size.height) * 0.5)
        )
        (title as NSString).draw(at: pt, withAttributes: attrs)
    }
}

@MainActor final class SemanticRelatedNoteChip: NSView {
    let hit: RelatedNoteHit
    let openButton: QuietButton
    let linkButton: QuietButton
    private let card = PaperSurface(cornerRadius: 7, color: Theme.paper, bordered: true)

    init(
        hit: RelatedNoteHit,
        onOpen: @escaping (Bool) -> Void,
        onInsertLink: @escaping () -> Void
    ) {
        self.hit = hit
        let pct = Int((hit.similarity * 100).rounded())
        let displayTitle = hit.note.title.count > 34
            ? String(hit.note.title.prefix(33)) + "…"
            : hit.note.title
        self.openButton = QuietButton(title: "\(displayTitle)  \(pct)%", symbol: "doc.text")
        self.linkButton = QuietButton(title: hit.isAlreadyLinked ? "Linked" : "[[]]")
        super.init(frame: .zero)

        openButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        openButton.tint = Theme.ink
        openButton.hoverCursor = .pointingHand
        openButton.toolTip = "Open “\(hit.note.title)” (⌥-click to open in new window)"
        openButton.setAccessibilityLabel("Open related note \(hit.note.title)")
        openButton.target = self
        openButton.action = #selector(openTapped)

        linkButton.font = Theme.monoFont(9.5, weight: .semibold)
        linkButton.tint = hit.isAlreadyLinked ? Theme.sage : Theme.accent
        linkButton.isEnabled = !hit.isAlreadyLinked
        linkButton.hoverCursor = hit.isAlreadyLinked ? nil : .pointingHand
        linkButton.toolTip = hit.isAlreadyLinked
            ? "Already linked in this note"
            : "Insert [[\(hit.wikiTarget)]] link (⌘Z to undo)"
        linkButton.setAccessibilityLabel(hit.isAlreadyLinked ? "Already linked" : "Insert wiki link to \(hit.wikiTarget)")
        linkButton.target = self
        linkButton.action = #selector(linkTapped)

        self.openHandler = onOpen
        self.linkHandler = onInsertLink

        let divider = HairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 14).isActive = true

        Theme.fill(card, in: self)
        let row = Theme.stack([openButton, divider, linkButton], spacing: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    private var openHandler: ((Bool) -> Void)?
    private var linkHandler: (() -> Void)?

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func openTapped() {
        let inNewWindow = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        openHandler?(inNewWindow)
    }

    @objc private func linkTapped() {
        linkHandler?()
    }
}

@MainActor private final class SemanticProgressBar: NSView {
    var fraction: Double = 0 {
        didSet {
            let clamped = min(1.0, max(0.0, fraction))
            if abs(clamped - oldValue) > 0.001 {
                fraction = clamped
                needsDisplay = true
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        Theme.codeBackground.setFill()
        track.fill()

        let fillWidth = max(fraction > 0 ? 6 : 0, CGFloat(fraction) * bounds.width)
        guard fillWidth > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: min(bounds.width, fillWidth), height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
        Theme.accent.setFill()
        fillPath.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Collapsible folio strip inside `CaptureEditor` for opt-in local semantic `#tag` suggestions,
/// 7-category classification, cross-lingual `EN ↔ ID` related notes, and local model management.
@MainActor final class SemanticConnectionsView: NSView {
    private let card = PaperSurface(cornerRadius: 10, color: Theme.elevated, bordered: true)

    // Setup / Download / Error state controls
    private let setupContainer = NSView()
    private let setupIcon = Theme.symbol("point.3.connected.trianglepath.dotted", size: 13, color: Theme.accent)
    let setupTitleLabel = Theme.label("Local Semantic Connections (EN ↔ ID)", size: 12, color: Theme.headingInk)
    let setupDetailLabel = Theme.label(
        "Suggest #tags, categories, and cross-lingual related notes 100% offline. Zero cloud calls.",
        size: 11,
        color: Theme.muted
    )
    let downloadButton = PrimaryButton()
    let importButton = QuietButton(title: "Import Folder…", symbol: "folder")
    let cancelDownloadButton = QuietButton(title: "Cancel", symbol: "xmark")
    private let setupCloseButton = QuietButton(symbol: "xmark")
    private let progressBar = SemanticProgressBar()
    let progressBytesLabel = Theme.label("", size: 10.5, color: Theme.muted)

    // Ready state controls
    private let readyContainer = NSView()
    let categoryBadge = SemanticCategoryBadge()
    let emptyHintLabel = Theme.label("Write a sentence to suggest a category, #tags, and related notes.", size: 11, color: Theme.muted)
    private let tagsScroll = NSScrollView()
    private let tagsStack = NSStackView()
    let modelMenuButton = QuietButton(symbol: "ellipsis.circle")
    let closeButton = QuietButton(symbol: "xmark")

    private let relatedRow = NSView()
    private let relatedLabel = Theme.label("RELATED", size: 9.5, color: Theme.muted)
    private let relatedScroll = NSScrollView()
    private let relatedStack = NSStackView()

    private(set) var modelState: SemanticModelState = .notInstalled
    private(set) var suggestions: NoteSemanticSuggestions = .empty
    private(set) var isIndexing: Bool = false

    private(set) var tagButtons: [SemanticTagPillButton] = []
    private(set) var relatedChips: [SemanticRelatedNoteChip] = []

    var onDownloadModel: (() -> Void)?
    var onCancelDownload: (() -> Void)?
    var onImportModelFolder: (() -> Void)?
    var onRemoveModel: (() -> Void)?
    var onRevealModelFolder: (() -> Void)?
    var onRefreshSuggestions: (() -> Void)?
    var onSelectSuggestedTag: ((String) -> Void)?
    var onOpenRelatedNote: ((NoteRecord, Bool) -> Void)?
    var onInsertRelatedWikiLink: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onPreferredHeightChange: (() -> Void)?

    var preferredHeight: CGFloat {
        switch modelState {
        case .notInstalled, .downloading, .failed:
            return 74
        case .ready:
            return suggestions.relatedNotes.isEmpty ? 40 : 74
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Semantic Connections")

        Theme.fill(card, in: self)
        buildSetupUI()
        buildReadyUI()
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildSetupUI() {
        setupTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        setupTitleLabel.lineBreakMode = .byTruncatingTail
        setupDetailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        setupDetailLabel.lineBreakMode = .byTruncatingTail
        setupDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBytesLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        progressBytesLabel.setContentHuggingPriority(.required, for: .horizontal)

        downloadButton.title = "Download Local Model (~224 MB)"
        downloadButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        downloadButton.target = self
        downloadButton.action = #selector(downloadTapped)
        downloadButton.setAccessibilityLabel("Download Local Model")

        importButton.font = .systemFont(ofSize: 11, weight: .medium)
        importButton.target = self
        importButton.action = #selector(importTapped)
        importButton.toolTip = "Import an existing folder with tokenizer.json and model.safetensors"
        importButton.setAccessibilityLabel("Import Model Folder")

        cancelDownloadButton.font = .systemFont(ofSize: 11, weight: .medium)
        cancelDownloadButton.target = self
        cancelDownloadButton.action = #selector(cancelDownloadTapped)
        cancelDownloadButton.setAccessibilityLabel("Cancel Model Download")

        setupCloseButton.target = self
        setupCloseButton.action = #selector(closeTapped)
        setupCloseButton.toolTip = "Hide Semantic Connections (⌃⌘\\)"
        setupCloseButton.setAccessibilityLabel("Close Semantic Connections")

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = Theme.stack([setupIcon, setupTitleLabel, topSpacer, progressBytesLabel, cancelDownloadButton, setupCloseButton], spacing: 6)

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = Theme.stack([setupDetailLabel, bottomSpacer, importButton, downloadButton], spacing: 8)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        for v in [headerRow, actionRow, progressBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            setupContainer.addSubview(v)
        }
        Theme.fill(setupContainer, in: self)

        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 12),
            headerRow.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -8),
            headerRow.topAnchor.constraint(equalTo: setupContainer.topAnchor, constant: 8),
            headerRow.heightAnchor.constraint(equalToConstant: 24),

            actionRow.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 12),
            actionRow.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -10),
            actionRow.bottomAnchor.constraint(equalTo: setupContainer.bottomAnchor, constant: -8),
            actionRow.heightAnchor.constraint(equalToConstant: 28),

            progressBar.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 12),
            progressBar.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -12),
            progressBar.bottomAnchor.constraint(equalTo: setupContainer.bottomAnchor, constant: -14),
            progressBar.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    private func buildReadyUI() {
        tagsStack.orientation = .horizontal
        tagsStack.alignment = .centerY
        tagsStack.spacing = 6
        tagsStack.translatesAutoresizingMaskIntoConstraints = false

        tagsScroll.documentView = tagsStack
        tagsScroll.drawsBackground = false
        tagsScroll.hasHorizontalScroller = false
        tagsScroll.hasVerticalScroller = false
        tagsScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagsScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

        emptyHintLabel.lineBreakMode = .byTruncatingTail
        emptyHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modelMenuButton.target = self
        modelMenuButton.action = #selector(showModelMenu(_:))
        modelMenuButton.toolTip = "Semantic Connections & model options"
        modelMenuButton.setAccessibilityLabel("Semantic Model Options")

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Hide Semantic Connections (⌃⌘\\)"
        closeButton.setAccessibilityLabel("Close Semantic Connections")

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topRow = Theme.stack([categoryBadge, emptyHintLabel, tagsScroll, topSpacer, modelMenuButton, closeButton], spacing: 6)

        relatedLabel.font = Theme.monoFont(9.5, weight: .semibold)
        relatedLabel.setContentHuggingPriority(.required, for: .horizontal)
        relatedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        relatedStack.orientation = .horizontal
        relatedStack.alignment = .centerY
        relatedStack.spacing = 6
        relatedStack.translatesAutoresizingMaskIntoConstraints = false

        relatedScroll.documentView = relatedStack
        relatedScroll.drawsBackground = false
        relatedScroll.hasHorizontalScroller = false
        relatedScroll.hasVerticalScroller = false
        relatedScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        relatedScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for v in [relatedLabel, relatedScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            relatedRow.addSubview(v)
        }
        NSLayoutConstraint.activate([
            relatedLabel.leadingAnchor.constraint(equalTo: relatedRow.leadingAnchor),
            relatedLabel.centerYAnchor.constraint(equalTo: relatedRow.centerYAnchor),
            relatedScroll.leadingAnchor.constraint(equalTo: relatedLabel.trailingAnchor, constant: 8),
            relatedScroll.trailingAnchor.constraint(equalTo: relatedRow.trailingAnchor),
            relatedScroll.topAnchor.constraint(equalTo: relatedRow.topAnchor),
            relatedScroll.bottomAnchor.constraint(equalTo: relatedRow.bottomAnchor)
        ])

        for v in [topRow, relatedRow] {
            v.translatesAutoresizingMaskIntoConstraints = false
            readyContainer.addSubview(v)
        }
        Theme.fill(readyContainer, in: self)

        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: readyContainer.leadingAnchor, constant: 10),
            topRow.trailingAnchor.constraint(equalTo: readyContainer.trailingAnchor, constant: -6),
            topRow.topAnchor.constraint(equalTo: readyContainer.topAnchor, constant: 6),
            topRow.heightAnchor.constraint(equalToConstant: 28),
            tagsScroll.heightAnchor.constraint(equalToConstant: 24),

            relatedRow.leadingAnchor.constraint(equalTo: readyContainer.leadingAnchor, constant: 10),
            relatedRow.trailingAnchor.constraint(equalTo: readyContainer.trailingAnchor, constant: -10),
            relatedRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 4),
            relatedRow.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    func update(
        modelState nextState: SemanticModelState,
        suggestions nextSuggestions: NoteSemanticSuggestions? = nil,
        isIndexing nextIndexing: Bool? = nil
    ) {
        let prevHeight = preferredHeight
        self.modelState = nextState
        if let nextSuggestions {
            self.suggestions = nextSuggestions
        }
        if let nextIndexing {
            self.isIndexing = nextIndexing
        }
        applyState()
        if preferredHeight != prevHeight {
            onPreferredHeightChange?()
        }
    }

    private func applyState() {
        switch modelState {
        case .notInstalled:
            setupContainer.isHidden = false
            readyContainer.isHidden = true
            setupTitleLabel.stringValue = "Local Semantic Connections (EN ↔ ID)"
            setupDetailLabel.stringValue = "Suggest #tags, categories, and cross-lingual related notes 100% offline. Zero cloud calls."
            setupDetailLabel.textColor = Theme.muted
            downloadButton.title = "Download Local Model (~224 MB)"
            downloadButton.isHidden = false
            importButton.isHidden = false
            setupCloseButton.isHidden = false
            cancelDownloadButton.isHidden = true
            progressBytesLabel.isHidden = true
            progressBar.isHidden = true

        case .downloading(let progress):
            setupContainer.isHidden = false
            readyContainer.isHidden = true
            setupTitleLabel.stringValue = progress.phase.rawValue
            let dlMB = Double(progress.downloadedBytes) / (1024 * 1024)
            let totMB = Double(max(1, progress.totalBytes)) / (1024 * 1024)
            progressBytesLabel.stringValue = String(format: "%.1f / %.1f MB", dlMB, totMB)
            progressBytesLabel.isHidden = false
            cancelDownloadButton.isHidden = false
            setupCloseButton.isHidden = true
            downloadButton.isHidden = true
            importButton.isHidden = true
            setupDetailLabel.isHidden = true
            progressBar.isHidden = false
            progressBar.fraction = progress.fractionCompleted
            return

        case .failed(let message):
            setupContainer.isHidden = false
            readyContainer.isHidden = true
            setupTitleLabel.stringValue = "Local Semantic Model Unavailable"
            setupDetailLabel.stringValue = message
            setupDetailLabel.textColor = Theme.accent
            setupDetailLabel.isHidden = false
            downloadButton.title = "Retry Download"
            downloadButton.isHidden = false
            importButton.isHidden = false
            setupCloseButton.isHidden = false
            cancelDownloadButton.isHidden = true
            progressBytesLabel.isHidden = true
            progressBar.isHidden = true

        case .ready:
            setupContainer.isHidden = true
            setupDetailLabel.isHidden = false
            readyContainer.isHidden = false
            rebuildReadyContent()
        }
        setupDetailLabel.isHidden = false
    }

    private func rebuildReadyContent() {
        if let cat = suggestions.category {
            categoryBadge.text = cat.category.displayName.uppercased()
            categoryBadge.isHighlightedCategory = true
        } else if isIndexing {
            categoryBadge.text = "INDEXING…"
            categoryBadge.isHighlightedCategory = false
        } else {
            categoryBadge.text = "TAGS & LINKS"
            categoryBadge.isHighlightedCategory = false
        }

        // Rebuild tag pills
        for view in tagsStack.arrangedSubviews {
            tagsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tagButtons.removeAll(keepingCapacity: true)

        for suggested in suggestions.tags {
            let btn = SemanticTagPillButton(
                tagName: suggested.name,
                isExistingVaultTag: suggested.isExistingVaultTag,
                target: self,
                action: #selector(tagPillClicked(_:))
            )
            tagsStack.addArrangedSubview(btn)
            tagButtons.append(btn)
        }
        let tagFit = tagsStack.fittingSize
        tagsStack.setFrameSize(NSSize(width: max(1, tagFit.width), height: 24))

        let hasTags = !tagButtons.isEmpty
        tagsScroll.isHidden = !hasTags
        if hasTags {
            emptyHintLabel.isHidden = true
        } else {
            emptyHintLabel.isHidden = false
            if isIndexing {
                emptyHintLabel.stringValue = "Indexing vault notes locally…"
            } else if suggestions.category != nil {
                emptyHintLabel.stringValue = "All matching #tags are already in this note."
            } else {
                emptyHintLabel.stringValue = "Write a sentence to suggest a category, #tags, and related notes."
            }
        }

        // Rebuild related note chips
        for view in relatedStack.arrangedSubviews {
            relatedStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        relatedChips.removeAll(keepingCapacity: true)

        for hit in suggestions.relatedNotes {
            let chip = SemanticRelatedNoteChip(
                hit: hit,
                onOpen: { [weak self] inNewWindow in
                    self?.onOpenRelatedNote?(hit.note, inNewWindow)
                },
                onInsertLink: { [weak self] in
                    self?.onInsertRelatedWikiLink?(hit.wikiTarget)
                }
            )
            relatedStack.addArrangedSubview(chip)
            relatedChips.append(chip)
        }
        let relFit = relatedStack.fittingSize
        relatedStack.setFrameSize(NSSize(width: max(1, relFit.width), height: 28))
        relatedRow.isHidden = relatedChips.isEmpty
    }

    func refreshTypography() {
        needsDisplay = true
        card.needsDisplay = true
        categoryBadge.needsDisplay = true
        for btn in tagButtons { btn.needsDisplay = true }
    }

    @objc private func downloadTapped() { onDownloadModel?() }
    @objc private func cancelDownloadTapped() { onCancelDownload?() }
    @objc private func importTapped() { onImportModelFolder?() }
    @objc private func closeTapped() { onClose?() }

    @objc private func tagPillClicked(_ sender: SemanticTagPillButton) {
        onSelectSuggestedTag?(sender.tagName)
    }

    @objc private func showModelMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh Suggestions", action: #selector(menuRefreshSuggestions), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let importItem = NSMenuItem(title: "Import Local Model Folder…", action: #selector(importTapped), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let revealItem = NSMenuItem(title: "Reveal Model Folder in Finder", action: #selector(menuRevealFolder), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        if case .ready(let bytes) = modelState {
            menu.addItem(.separator())
            let mb = Double(bytes) / (1024 * 1024)
            let removeTitle = mb >= 1
                ? String(format: "Remove Downloaded Model (%.0f MB)…", mb)
                : "Remove Downloaded Model…"
            let removeItem = NSMenuItem(title: removeTitle, action: #selector(menuRemoveModel), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
        }

        let pt = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: pt, in: sender)
    }

    @objc private func menuRefreshSuggestions() { onRefreshSuggestions?() }
    @objc private func menuRevealFolder() { onRevealModelFolder?() }
    @objc private func menuRemoveModel() { onRemoveModel?() }
}

// MARK: - Workspace Semantic Coordinator

private final class AtomicGenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestByEditorID: [ObjectIdentifier: UInt64] = [:]
    private var shutdownFlag = false

    func bump(for id: ObjectIdentifier) -> UInt64 {
        lock.withLock {
            let next = (latestByEditorID[id] ?? 0) &+ 1
            latestByEditorID[id] = next
            return next
        }
    }

    func isCurrent(_ generation: UInt64, for id: ObjectIdentifier) -> Bool {
        lock.withLock {
            !shutdownFlag && latestByEditorID[id] == generation
        }
    }

    var isShutdown: Bool {
        lock.withLock { shutdownFlag }
    }

    func markShutdown() {
        lock.withLock {
            shutdownFlag = true
            latestByEditorID.removeAll()
        }
    }
}

/// Coordinates opt-in local model lifecycle and background `SemanticIndex` suggestions
/// for a `WorkspaceController` and its companion `NoteWindowController`s.
@MainActor final class WorkspaceSemanticCoordinator {
    let vault: Vault
    let modelStore: SemanticModelStore
    let cacheDirectory: URL?

    private let workQueue = DispatchQueue(label: "cozy.semantic.coordinator", qos: .utility)
    private let generations = AtomicGenerationBox()
    private var semanticIndex: SemanticIndex?
    private var hasSyncedVaultOnce = false
    private var isIndexingVault = false
    private var downloadTask: Task<Void, Never>?
    private var debounceTimers: [ObjectIdentifier: Timer] = [:]
    private var registeredEditors: [WeakEditorRef] = []

    var onStateDidChange: (() -> Void)?

    private struct WeakEditorRef {
        weak var editor: CaptureEditor?
    }

    private(set) var modelState: SemanticModelState

    init(
        vault: Vault,
        modelStore: SemanticModelStore = SemanticModelStore(),
        cacheDirectory: URL? = nil
    ) {
        self.vault = vault
        self.modelStore = modelStore
        self.cacheDirectory = cacheDirectory
        self.modelState = modelStore.currentState()
    }

    func registerEditor(
        _ editor: CaptureEditor,
        onOpenRelatedNote: @escaping (NoteRecord, Bool) -> Void
    ) {
        pruneEditors()
        if !registeredEditors.contains(where: { $0.editor === editor }) {
            registeredEditors.append(WeakEditorRef(editor: editor))
        }

        let view = editor.semanticView
        view.update(modelState: modelState, isIndexing: isIndexingVault)

        view.onDownloadModel = { [weak self] in
            self?.startDownload()
        }
        view.onCancelDownload = { [weak self] in
            self?.cancelDownload()
        }
        view.onImportModelFolder = { [weak self, weak editor] in
            self?.promptImportModelFolder(in: editor?.window)
        }
        view.onRemoveModel = { [weak self] in
            self?.removeModel()
        }
        view.onRevealModelFolder = { [weak self] in
            guard let self else { return }
            let dir = self.modelStore.modelDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
        view.onRefreshSuggestions = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.scheduleSuggestionUpdate(for: editor, immediate: true, forceVaultSync: true)
        }
        view.onSelectSuggestedTag = { [weak self, weak editor] tagName in
            guard let self, let editor else { return }
            if editor.insertSuggestedTag(tagName) {
                editor.status.stringValue = "Added #\(tagName)"
                self.scheduleSuggestionUpdate(for: editor, immediate: true)
            }
        }
        view.onOpenRelatedNote = { record, inNewWindow in
            onOpenRelatedNote(record, inNewWindow)
        }
        view.onInsertRelatedWikiLink = { [weak self, weak editor] wikiTarget in
            guard let self, let editor else { return }
            if editor.insertWikiLinkToRelatedNote(wikiTarget) {
                editor.status.stringValue = "Linked [[\(wikiTarget)]]"
                self.scheduleSuggestionUpdate(for: editor, immediate: true)
            }
        }
        view.onClose = { [weak editor] in
            editor?.setSemanticConnectionsVisible(false)
        }
    }

    func editorVisibilityDidChange(_ editor: CaptureEditor) {
        guard editor.isSemanticConnectionsVisible else {
            let id = ObjectIdentifier(editor)
            debounceTimers[id]?.invalidate()
            debounceTimers.removeValue(forKey: id)
            _ = generations.bump(for: id)
            return
        }
        refreshModelStateFromDisk()
        editor.semanticView.update(modelState: modelState, isIndexing: isIndexingVault)
        if modelState.isReady {
            scheduleSuggestionUpdate(for: editor, immediate: true)
        }
    }

    func scheduleSuggestionUpdate(
        for editor: CaptureEditor,
        immediate: Bool = false,
        forceVaultSync: Bool = false
    ) {
        guard editor.isSemanticConnectionsVisible else { return }
        if !modelState.isReady {
            refreshModelStateFromDisk()
            guard modelState.isReady else { return }
        }

        let editorID = ObjectIdentifier(editor)
        debounceTimers[editorID]?.invalidate()
        debounceTimers.removeValue(forKey: editorID)

        if immediate {
            dispatchSuggestionWork(for: editor, forceVaultSync: forceVaultSync)
        } else {
            debounceTimers[editorID] = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self, weak editor] _ in
                MainActor.assumeIsolated {
                    guard let self, let editor else { return }
                    self.debounceTimers.removeValue(forKey: editorID)
                    self.dispatchSuggestionWork(for: editor, forceVaultSync: forceVaultSync)
                }
            }
        }
    }

    func noteDidSave(url: URL, content: String) {
        guard semanticIndex != nil else { return }
        let idx = semanticIndex
        let vaultRef = vault
        workQueue.async {
            guard let idx, let notes = try? vaultRef.notes(),
                  let record = notes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
                return
            }
            try? idx.upsertNote(record, content: content)
        }
        refreshVisibleEditors(immediate: true)
    }

    func noteDidDelete(url: URL) {
        guard let idx = semanticIndex else { return }
        workQueue.async {
            idx.removeNote(at: url)
        }
        refreshVisibleEditors(immediate: true)
    }

    func vaultDidRefresh() {
        guard semanticIndex != nil, hasAnyVisibleSemanticEditor else { return }
        refreshVisibleEditors(immediate: true, forceVaultSync: true)
    }

    // MARK: - Model Lifecycle Actions

    func startDownload(
        spec: SemanticRemoteSpec = .officialMiniLM,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        guard downloadTask == nil else { return }
        let initial = SemanticDownloadProgress(
            phase: .downloadingTokenizer,
            downloadedBytes: 0,
            totalBytes: max(1, spec.tokenizerExpectedBytes + spec.safetensorsExpectedBytes)
        )
        setModelState(.downloading(initial))

        let store = modelStore
        downloadTask = Task { [weak self] in
            do {
                let installedBytes = try await store.downloadModel(
                    spec: spec,
                    sessionConfiguration: sessionConfiguration
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadTask != nil else { return }
                        self.setModelState(.downloading(progress))
                    }
                }
                guard !Task.isCancelled else { return }
                self?.downloadTask = nil
                self?.semanticIndex = nil
                self?.hasSyncedVaultOnce = false
                self?.setModelState(.ready(installedBytes: installedBytes))
                self?.refreshVisibleEditors(immediate: true, forceVaultSync: true)
            } catch is CancellationError {
                self?.downloadTask = nil
                self?.setModelState(.notInstalled)
            } catch SemanticModelError.cancelled {
                self?.downloadTask = nil
                self?.setModelState(.notInstalled)
            } catch {
                self?.downloadTask = nil
                self?.setModelState(.failed(error.localizedDescription))
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        modelStore.cancelDownload()
        setModelState(modelStore.currentState())
    }

    func promptImportModelFolder(in hostWindow: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = "Import Local Semantic Model Folder"
        panel.message = "Choose a folder containing tokenizer.json and model.fp16.safetensors, model.safetensors, or MiniLM-L12-v2.mlpackage."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Model"

        let handleChoice: (URL?) -> Void = { [weak self] chosenURL in
            guard let self, let chosenURL else { return }
            do {
                try self.importModel(from: chosenURL)
            } catch {
                self.setModelState(.failed(error.localizedDescription))
            }
        }

        if let hostWindow, hostWindow.isVisible {
            panel.beginSheetModal(for: hostWindow) { response in
                if response == .OK { handleChoice(panel.url) }
            }
        } else if panel.runModal() == .OK {
            handleChoice(panel.url)
        }
    }

    func importModel(from folderURL: URL) throws {
        let installedBytes = try modelStore.importLocalModel(from: folderURL)
        semanticIndex = nil
        hasSyncedVaultOnce = false
        setModelState(.ready(installedBytes: installedBytes))
        refreshVisibleEditors(immediate: true, forceVaultSync: true)
    }

    func removeModel() {
        cancelDownload()
        try? modelStore.removeInstalledModel()
        semanticIndex = nil
        hasSyncedVaultOnce = false
        for editor in activeEditors {
            editor.semanticView.update(modelState: .notInstalled, suggestions: .empty, isIndexing: false)
        }
        setModelState(.notInstalled)
    }

    /// Waits for all queued background indexing / suggestion tasks to complete (used by deterministic tests).
    func waitForIdle() async {
        if let downloadTask {
            await downloadTask.value
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workQueue.async {
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    func shutdown() {
        generations.markShutdown()
        for timer in debounceTimers.values { timer.invalidate() }
        debounceTimers.removeAll()
        downloadTask?.cancel()
        downloadTask = nil
        modelStore.cancelDownload()
        semanticIndex = nil
    }

    // MARK: - Internal Helpers

    private var activeEditors: [CaptureEditor] {
        pruneEditors()
        return registeredEditors.compactMap(\.editor)
    }

    private var hasAnyVisibleSemanticEditor: Bool {
        activeEditors.contains(where: \.isSemanticConnectionsVisible)
    }

    private func pruneEditors() {
        registeredEditors.removeAll { $0.editor == nil }
    }

    private func refreshModelStateFromDisk() {
        if downloadTask != nil { return }
        let diskState = modelStore.currentState()
        if diskState != modelState {
            setModelState(diskState)
        }
    }

    private func setModelState(_ next: SemanticModelState) {
        modelState = next
        for editor in activeEditors {
            editor.semanticView.update(modelState: next, isIndexing: isIndexingVault)
        }
        onStateDidChange?()
    }

    private func refreshVisibleEditors(immediate: Bool, forceVaultSync: Bool = false) {
        for editor in activeEditors where editor.isSemanticConnectionsVisible {
            scheduleSuggestionUpdate(for: editor, immediate: immediate, forceVaultSync: forceVaultSync)
        }
    }

    private func ensureIndexLoadedOnQueue(
        store: SemanticModelStore,
        vaultRoot: URL,
        cacheDir: URL?,
        existing: SemanticIndex?
    ) throws -> SemanticIndex {
        if let existing { return existing }
        let embedder = try store.loadEmbedder()
        return try SemanticIndex(vaultRoot: vaultRoot, embedder: embedder, cacheDirectory: cacheDir)
    }

    private func dispatchSuggestionWork(for editor: CaptureEditor, forceVaultSync: Bool) {
        let editorID = ObjectIdentifier(editor)
        let generation = generations.bump(for: editorID)
        let snapshotText = editor.text
        let snapshotNoteURL = editor.currentNoteURLProvider?()
        let store = modelStore
        let vaultRef = vault
        let cacheDir = cacheDirectory
        let existingIndex = semanticIndex
        let needsSync = forceVaultSync || !hasSyncedVaultOnce
        let genBox = generations

        if needsSync {
            isIndexingVault = true
            editor.semanticView.update(modelState: modelState, isIndexing: true)
        }

        workQueue.async { [weak self, weak editor] in
            guard genBox.isCurrent(generation, for: editorID) else { return }
            do {
                let idx: SemanticIndex
                if let existingIndex {
                    idx = existingIndex
                } else {
                    let embedder = try store.loadEmbedder()
                    idx = try SemanticIndex(vaultRoot: vaultRef.root, embedder: embedder, cacheDirectory: cacheDir)
                }

                var didSync = false
                if needsSync {
                    let notes = (try? vaultRef.notes()) ?? []
                    didSync = try idx.syncNotes(notes, vault: vaultRef) {
                        !genBox.isCurrent(generation, for: editorID)
                    }
                }

                guard genBox.isCurrent(generation, for: editorID) else { return }
                let suggestions = try idx.suggest(
                    for: snapshotText,
                    currentNoteURL: snapshotNoteURL,
                    vault: vaultRef
                )

                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.semanticIndex == nil {
                        self.semanticIndex = idx
                    }
                    if didSync {
                        self.hasSyncedVaultOnce = true
                    }
                    self.isIndexingVault = false
                    guard let editor, genBox.isCurrent(generation, for: editorID) else { return }
                    editor.semanticView.update(
                        modelState: self.modelState,
                        suggestions: suggestions,
                        isIndexing: false
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isIndexingVault = false
                    self.setModelState(.failed(error.localizedDescription))
                }
            }
        }
    }
}
