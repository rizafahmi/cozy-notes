import AppKit
import CozyCore

@MainActor
final class MergeNotesSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragPasteboardType = NSPasteboard.PasteboardType("app.cozynotes.merge-note-row")

    let vault: Vault
    private(set) var orderedURLs: [URL]
    private(set) var currentPreview: MergePreview?

    var onConfirmMerge: (([URL]) -> Void)?
    var onCancel: (() -> Void)?

    let moveUpButton = QuietButton(symbol: "chevron.up", target: nil, action: nil)
    let moveDownButton = QuietButton(symbol: "chevron.down", target: nil, action: nil)
    let makeTargetButton = QuietButton(title: "Make Target", symbol: nil, target: nil, action: nil)
    let cancelButton = QuietButton(title: "Cancel", symbol: nil, target: nil, action: nil)
    let confirmButton = PrimaryButton()

    private let table = MergeOrderTableView()
    private let previewTextView = NSTextView()
    private let targetPathLabel = Theme.label("", size: 10.5, color: Theme.accent)
    private let impactLabel = Theme.label("", size: 11.5, color: Theme.muted)
    private let errorLabel = Theme.label("", size: 11.5, color: Theme.accent)
    private weak var hostWindow: NSWindow?

    var previewText: String { previewTextView.string }
    var impactSummary: String { impactLabel.stringValue }
    var selectedRow: Int { table.selectedRow }

    init(vault: Vault, noteURLs: [URL], appearance: NSAppearance? = nil) {
        self.vault = vault
        var deduplicated: [URL] = []
        for url in noteURLs {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if !deduplicated.contains(canonical) {
                deduplicated.append(canonical)
            }
        }
        self.orderedURLs = deduplicated

        let sheetWindow = MergeSheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = "Merge Notes"
        sheetWindow.minSize = NSSize(width: 680, height: 440)
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.backgroundColor = Theme.canvas
        sheetWindow.appearance = appearance

        super.init(window: sheetWindow)
        sheetWindow.onEscape = { [weak self] in self?.cancel() }
        sheetWindow.onCommandReturn = { [weak self] in self?.confirmMerge() }

        buildUI()
        if !orderedURLs.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        reloadPreviewAndControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(in parentWindow: NSWindow?) {
        guard let sheetWindow = window else { return }
        hostWindow = parentWindow
        sheetWindow.appearance = parentWindow?.appearance
        if let parentWindow {
            parentWindow.beginSheet(sheetWindow)
            sheetWindow.makeFirstResponder(table)
        } else {
            showWindow(nil)
            sheetWindow.makeFirstResponder(table)
        }
    }

    func dismissSheet() {
        guard let sheetWindow = window else { return }
        if let parent = sheetWindow.sheetParent ?? hostWindow {
            parent.endSheet(sheetWindow)
        }
        sheetWindow.orderOut(nil)
    }

    func selectRow(_ row: Int) {
        guard orderedURLs.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateReorderButtons()
    }

    @discardableResult
    func moveNote(from sourceIndex: Int, to destinationIndex: Int) -> Bool {
        guard orderedURLs.indices.contains(sourceIndex),
              orderedURLs.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else {
            return false
        }
        let moved = orderedURLs.remove(at: sourceIndex)
        orderedURLs.insert(moved, at: destinationIndex)
        reloadPreviewAndControls(selectingRow: destinationIndex)
        table.scrollRowToVisible(destinationIndex)
        return true
    }

    @objc func moveSelectedUp() {
        let row = table.selectedRow
        guard row > 0 else { return }
        _ = moveNote(from: row, to: row - 1)
    }

    @objc func moveSelectedDown() {
        let row = table.selectedRow
        guard row >= 0, row + 1 < orderedURLs.count else { return }
        _ = moveNote(from: row, to: row + 1)
    }

    @objc func promoteSelectedToTarget() {
        let row = table.selectedRow
        guard row > 0 else { return }
        _ = moveNote(from: row, to: 0)
    }

    @objc func confirmMerge() {
        guard confirmButton.isEnabled, orderedURLs.count >= 2 else { return }
        let urls = orderedURLs
        dismissSheet()
        onConfirmMerge?(urls)
    }

    @objc func cancel() {
        dismissSheet()
        onCancel?()
    }

    private func buildUI() {
        guard let sheetWindow = window else { return }
        let root = PaperSurface(cornerRadius: 0, color: Theme.canvas, bordered: false)
        sheetWindow.contentView = root

        let icon = Theme.symbol("arrow.triangle.merge", size: 17, color: Theme.accent)
        let titleLabel = Theme.label("Merge Notes", size: 16, color: Theme.headingInk)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let subtitleLabel = Theme.label(
            "Drag rows or use ↑ ↓ to set merge order. The first note is kept as the target; the others move to Trash.",
            size: 12,
            color: Theme.muted
        )
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let titleStack = Theme.stack([titleLabel, subtitleLabel], orientation: .vertical, spacing: 2)
        let headerRow = Theme.stack([icon, titleStack], spacing: 10)
        let topRule = HairlineView()

        let orderStamp = Theme.label("MERGE ORDER", size: 10, color: Theme.subtle)
        orderStamp.font = Theme.monoFont(10, weight: .semibold)

        moveUpButton.target = self
        moveUpButton.action = #selector(moveSelectedUp)
        moveUpButton.toolTip = "Move selected note up (⌥↑)"
        moveUpButton.setAccessibilityLabel("Move selected note up")

        moveDownButton.target = self
        moveDownButton.action = #selector(moveSelectedDown)
        moveDownButton.toolTip = "Move selected note down (⌥↓)"
        moveDownButton.setAccessibilityLabel("Move selected note down")

        makeTargetButton.target = self
        makeTargetButton.action = #selector(promoteSelectedToTarget)
        makeTargetButton.font = .systemFont(ofSize: 11, weight: .medium)
        makeTargetButton.toolTip = "Move selected note to the top so other notes merge into it"
        makeTargetButton.setAccessibilityLabel("Make selected note target")

        let orderSpacer = NSView()
        orderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let leftHeader = Theme.stack([orderStamp, orderSpacer, makeTargetButton, moveUpButton, moveDownButton], spacing: 4)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mergeOrder"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        table.registerForDraggedTypes([Self.dragPasteboardType])
        table.draggingDestinationFeedbackStyle = .gap
        table.onMoveUp = { [weak self] in self?.moveSelectedUp() }
        table.onMoveDown = { [weak self] in self?.moveSelectedDown() }

        let listScroll = NSScrollView()
        listScroll.verticalScroller = CozyScroller()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.drawsBackground = false

        let listCard = PaperSurface(cornerRadius: 10, color: Theme.paper, bordered: true)
        Theme.fill(listScroll, in: listCard, inset: 4)

        let leftPane = NSView()
        for view in [leftHeader, listCard] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leftPane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            leftHeader.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            leftHeader.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            leftHeader.topAnchor.constraint(equalTo: leftPane.topAnchor),
            leftHeader.heightAnchor.constraint(equalToConstant: 26),
            listCard.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            listCard.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            listCard.topAnchor.constraint(equalTo: leftHeader.bottomAnchor, constant: 6),
            listCard.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor)
        ])

        let previewStamp = Theme.label("MERGED PREVIEW", size: 10, color: Theme.subtle)
        previewStamp.font = Theme.monoFont(10, weight: .semibold)
        targetPathLabel.font = Theme.monoFont(10, weight: .semibold)
        targetPathLabel.lineBreakMode = .byTruncatingMiddle
        targetPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let previewSpacer = NSView()
        previewSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rightHeader = Theme.stack([previewStamp, previewSpacer, targetPathLabel], spacing: 8)

        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.isRichText = false
        previewTextView.drawsBackground = false
        previewTextView.textContainerInset = NSSize(width: 16, height: 14)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.autoresizingMask = [.width]
        previewTextView.textContainer?.widthTracksTextView = true
        previewTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        previewTextView.setAccessibilityLabel("Merged note preview")

        let previewScroll = NSScrollView()
        previewScroll.verticalScroller = CozyScroller()
        previewScroll.documentView = previewTextView
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.scrollerStyle = .overlay
        previewScroll.drawsBackground = false

        let previewCard = PaperSurface(cornerRadius: 10, color: Theme.paper, bordered: true)
        Theme.fill(previewScroll, in: previewCard, inset: 2)

        let rightPane = NSView()
        for view in [rightHeader, previewCard] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rightPane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            rightHeader.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            rightHeader.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            rightHeader.topAnchor.constraint(equalTo: rightPane.topAnchor),
            rightHeader.heightAnchor.constraint(equalToConstant: 26),
            previewCard.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            previewCard.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            previewCard.topAnchor.constraint(equalTo: rightHeader.bottomAnchor, constant: 6),
            previewCard.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor)
        ])

        let bottomRule = HairlineView()

        impactLabel.lineBreakMode = .byTruncatingTail
        impactLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.isHidden = true

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel merge")

        confirmButton.target = self
        confirmButton.action = #selector(confirmMerge)
        confirmButton.keyEquivalent = "\r"
        confirmButton.setAccessibilityLabel("Confirm merge notes")

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerRow = Theme.stack([impactLabel, errorLabel, footerSpacer, cancelButton, confirmButton], spacing: 10)

        for view in [headerRow, topRule, leftPane, rightPane, bottomRule, footerRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            headerRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            topRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topRule.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 14),
            topRule.heightAnchor.constraint(equalToConstant: 1),

            leftPane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            leftPane.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 14),
            leftPane.bottomAnchor.constraint(equalTo: bottomRule.topAnchor, constant: -14),
            leftPane.widthAnchor.constraint(equalToConstant: 292),

            rightPane.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: 16),
            rightPane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            rightPane.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 14),
            rightPane.bottomAnchor.constraint(equalTo: bottomRule.topAnchor, constant: -14),

            bottomRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -12),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),

            footerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footerRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            footerRow.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func reloadPreviewAndControls(selectingRow: Int? = nil) {
        let desiredRow = selectingRow ?? (table.selectedRow >= 0 ? table.selectedRow : 0)
        confirmButton.title = "Merge \(orderedURLs.count) Notes"
        confirmButton.invalidateIntrinsicContentSize()

        do {
            let preview = try vault.previewMerge(orderedURLs)
            currentPreview = preview
            errorLabel.isHidden = true
            impactLabel.isHidden = false
            confirmButton.isEnabled = true

            let relTarget = relativeVaultPath(for: preview.targetNote.url)
            targetPathLabel.stringValue = "INTO \(relTarget.uppercased())"
            targetPathLabel.toolTip = relTarget

            applyPreviewTypography(preview.mergedContent)

            let absorbedCount = max(0, preview.orderedNotes.count - 1)
            var clauses: [String] = [
                "\(absorbedCount) \(absorbedCount == 1 ? "note moves" : "notes move") to Trash"
            ]
            if preview.affectedBacklinkNoteCount > 0 {
                let n = preview.affectedBacklinkNoteCount
                clauses.append("updates [[WikiLinks]] in \(n) \(n == 1 ? "note" : "notes")")
            }
            if preview.willBePinned {
                clauses.append("keeps pinned")
            }
            clauses.append("checkpoint saved first")
            impactLabel.stringValue = clauses.joined(separator: " · ")
            impactLabel.toolTip = impactLabel.stringValue
            table.reloadData()
        } catch {
            currentPreview = nil
            confirmButton.isEnabled = false
            impactLabel.isHidden = true
            errorLabel.isHidden = false
            errorLabel.stringValue = error.localizedDescription
            previewTextView.string = ""
            targetPathLabel.stringValue = ""
            table.reloadData()
        }

        if !orderedURLs.isEmpty {
            let clamped = min(max(0, desiredRow), orderedURLs.count - 1)
            table.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        }
        updateReorderButtons()
    }

    private func applyPreviewTypography(_ content: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.bodyFont(14),
            .foregroundColor: Theme.ink,
            .paragraphStyle: paragraph
        ]
        previewTextView.textStorage?.setAttributedString(NSAttributedString(string: content, attributes: attrs))
    }

    private func updateReorderButtons() {
        let row = table.selectedRow
        moveUpButton.isEnabled = row > 0
        moveDownButton.isEnabled = row >= 0 && row + 1 < orderedURLs.count
        makeTargetButton.isEnabled = row > 0
    }

    private func relativeVaultPath(for url: URL) -> String {
        let rootPrefix = vault.root.path.hasSuffix("/") ? vault.root.path : vault.root.path + "/"
        if url.path.hasPrefix(rootPrefix) {
            return String(url.path.dropFirst(rootPrefix.count))
        }
        return url.lastPathComponent
    }

    // MARK: - NSTableViewDataSource & NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        orderedURLs.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        MergeOrderRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard orderedURLs.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("MergeOrderCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? MergeOrderCellView) ?? MergeOrderCellView(frame: .zero)
        cell.identifier = id
        let url = orderedURLs[row]
        let record = currentPreview?.orderedNotes.first(where: { $0.url == url })
        let title = record?.title ?? url.deletingPathExtension().lastPathComponent
        let relPath = relativeVaultPath(for: url)
        let isPinned = record?.isPinned ?? vault.isPinned(url)
        cell.configure(
            index: row,
            title: title,
            relativePath: relPath,
            isTarget: row == 0,
            isPinned: isPinned
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateReorderButtons()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard orderedURLs.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as AnyObject? === tableView else { return [] }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: Self.dragPasteboardType),
              let sourceIndex = Int(raw),
              orderedURLs.indices.contains(sourceIndex) else {
            return false
        }
        let targetIndex = sourceIndex < row ? max(0, row - 1) : min(orderedURLs.count - 1, row)
        guard sourceIndex != targetIndex else { return false }
        return moveNote(from: sourceIndex, to: targetIndex)
    }
}

@MainActor
private final class MergeSheetWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && flags.isEmpty {
                onEscape?()
                return true
            }
            if (event.keyCode == 36 || event.keyCode == 76) && (flags == .command || flags.isEmpty) {
                onCommandReturn?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class MergeOrderTableView: NSTableView {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .option {
            if event.keyCode == 126 {
                onMoveUp?()
                return
            }
            if event.keyCode == 125 {
                onMoveDown?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class MergeOrderRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.border.withAlphaComponent(0.45).setFill()
        NSRect(x: 12, y: bounds.maxY - 1, width: max(0, bounds.width - 24), height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        Theme.selectionFill.setFill()
        path.fill()
        Theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class MergeRoleBadge: NSView {
    var text: String = "TARGET" {
        didSet {
            if text != oldValue {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }
    var isTarget: Bool = false {
        didSet {
            if isTarget != oldValue { needsDisplay = true }
        }
    }

    override var intrinsicContentSize: NSSize {
        let font = Theme.monoFont(9.5, weight: .semibold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 12, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let fill = isTarget ? Theme.accentSoft : Theme.elevated
        let stroke = isTarget ? Theme.accent.withAlphaComponent(0.45) : Theme.border
        let ink = isTarget ? Theme.accent : Theme.muted
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let font = Theme.monoFont(9.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
            .kern: 0.3
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pt = NSPoint(
            x: round((bounds.width - size.width) * 0.5),
            y: round((bounds.height - size.height) * 0.5)
        )
        (text as NSString).draw(at: pt, withAttributes: attrs)
    }
}

@MainActor
private final class MergeOrderCellView: NSTableCellView {
    private let gripIcon = Theme.symbol("line.3.horizontal", size: 11, color: Theme.subtle)
    private let indexLabel = Theme.label("1", size: 10.5, color: Theme.subtle)
    private let pinIcon = Theme.symbol("pin.fill", size: 10, color: Theme.accent)
    private let titleLabel = Theme.label("", size: 13, color: Theme.ink)
    private let pathLabel = Theme.label("", size: 10.5, color: Theme.muted)
    private let roleBadge = MergeRoleBadge(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        indexLabel.font = Theme.monoFont(10.5, weight: .semibold)
        indexLabel.alignment = .right
        indexLabel.widthAnchor.constraint(equalToConstant: 16).isActive = true
        gripIcon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        pinIcon.widthAnchor.constraint(equalToConstant: 11).isActive = true

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.font = Theme.monoFont(10, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        roleBadge.setContentHuggingPriority(.required, for: .horizontal)
        roleBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = Theme.stack([pinIcon, titleLabel], spacing: 4)
        let textCol = Theme.stack([titleRow, pathLabel], orientation: .vertical, spacing: 2)
        textCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = Theme.stack([gripIcon, indexLabel, textCol, spacer, roleBadge], spacing: 7)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(index: Int, title: String, relativePath: String, isTarget: Bool, isPinned: Bool) {
        indexLabel.stringValue = "\(index + 1)"
        indexLabel.textColor = isTarget ? Theme.accent : Theme.subtle
        pinIcon.isHidden = !isPinned
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: isTarget ? .semibold : .medium)
        titleLabel.textColor = isTarget ? Theme.headingInk : Theme.ink
        pathLabel.stringValue = relativePath
        pathLabel.toolTip = relativePath
        roleBadge.isTarget = isTarget
        roleBadge.text = isTarget ? "TARGET" : "APPEND"
    }
}
