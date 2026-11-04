import AppKit
import CozyCore
import CozySearch

/// One queue owns the engine; only immutable search snapshots reach AppKit.
@MainActor
final class SearchPanel: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenNote: ((URL) -> Void)?
    var onStatus: ((String) -> Void)?
    var isProcessing: Bool { busy }
    var isExtracting: Bool { extracting }

    private let vault: Vault
    private let engine: CaptureSearch
    private let queue = DispatchQueue(label: "CozyNotes.capture-search", qos: .userInitiated)
    private let lifetime = SearchCancellation()
    private let field = NSSearchField()
    private let table = SearchResultsTable()
    private let status = Theme.label("Loading local sources…", size: 11)
    private let empty = Theme.label("Loading local sources…")
    private let progress = NSProgressIndicator()
    private let processingRow = NSStackView()
    private let processingNotice = PaperSurface(cornerRadius: 12, color: Theme.accentSoft, bordered: false)
    private let processingLabel = Theme.label("", size: 12)
    private let recentLabel = Theme.label("RECENT CAPTURES", size: 11)
    private var renderedQuery: String?
    private var makeButton: NSButton!
    private var cancelButton: NSButton!
    private var openButton: NSButton!
    private var snapshot: SearchSnapshot?
    private var hits: [SearchHit] = []
    private var stamps: [URL: SearchFileStamp] = [:]
    private var scheduledRefresh: DispatchWorkItem?
    private var operation: SearchCancellation?
    private var busy = false
    private var extracting = false
    private var refreshRequested = false
    private var closed = false
    private var generation = 0

    init(vault: Vault) {
        self.vault = vault
        engine = CaptureSearch(vault: vault)
        super.init(frame: .zero)
        field.placeholderString = "Words, filenames, a half-remembered thought…"
        field.delegate = self
        field.target = self
        field.action = #selector(openSelected)
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.controlSize = .large
        field.font = .systemFont(ofSize: 14)
        field.setAccessibilityLabel("Search captures")
        makeButton = Theme.button("Make searchable", target: self, action: #selector(makeSearchable))
        makeButton.toolTip = "Extract selectable PDF text and recognize screenshot text locally. Originals are preserved."
        cancelButton = Theme.button("Cancel", target: self, action: #selector(cancelExtraction))
        cancelButton.isHidden = true
        openButton = Theme.button("Open original", target: self, action: #selector(openSelected))
        openButton.isEnabled = false
        let toolbar = Theme.stack([field, openButton], spacing: 10)
        let heading = Theme.label("Find a little something.", size: 29, color: Theme.ink)
        heading.font = Theme.displayFont(29)
        let hint = Theme.label("Search your notes and files, in their original words.", size: 12)
        hint.lineBreakMode = .byTruncatingTail
        processingLabel.lineBreakMode = .byTruncatingTail
        processingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let processingSpacer = NSView()
        processingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        processingRow.orientation = .horizontal
        processingRow.alignment = .centerY
        processingRow.distribution = .fill
        processingRow.spacing = 8
        for view in [processingLabel, processingSpacer, makeButton!, cancelButton!] { processingRow.addArrangedSubview(view) }
        Theme.fill(processingRow, in: processingNotice, inset: 10)
        processingNotice.isHidden = true
        recentLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        let top = Theme.stack([heading, hint, toolbar, processingNotice, recentLabel], orientation: .vertical, spacing: 10)
        toolbar.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        processingNotice.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        field.heightAnchor.constraint(equalToConstant: 36).isActive = true
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = Theme.stack([progress, status], spacing: 8)
        progress.widthAnchor.constraint(equalToConstant: 85).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 120
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.backgroundColor = Theme.canvas
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelected() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        let results = NSView()
        Theme.fill(scroll, in: results)
        empty.translatesAutoresizingMaskIntoConstraints = false
        results.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: results.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: results.trailingAnchor, constant: -16),
            empty.centerYAnchor.constraint(equalTo: results.centerYAnchor)
        ])
        for view in [top, results, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            results.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            results.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            results.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            results.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(vault:)") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()
    }

    func focusSearch() {
        guard !closed else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func refresh() {
        guard !closed else { return }
        refreshRequested = true
        guard !busy else { return }
        scheduledRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.closed else { return }
            self.scheduledRefresh = nil
            self.start(extract: false)
        }
        scheduledRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        lifetime.cancel()
        operation?.cancel()
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        generation += 1
        onOpenNote = nil
        onStatus = nil
        field.isEnabled = false
        makeButton.isEnabled = false
        cancelButton.isEnabled = false
        openButton.isEnabled = false
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    private func start(extract: Bool) {
        guard !closed, !busy else { return }
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        refreshRequested = false
        busy = true
        extracting = extract
        generation += 1
        let id = generation
        let token = SearchCancellation()
        operation = token
        makeButton.isEnabled = false
        cancelButton.isHidden = !extract
        cancelButton.isEnabled = true
        openButton.isEnabled = false
        progress.isHidden = false
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        setStatus(extract ? "Making sources searchable on this Mac…" : "Reading local sources…")
        updateProcessingNotice()
        let engine = self.engine
        let vault = self.vault
        let lifetime = self.lifetime
        queue.async { [weak self] in
            guard !lifetime.isCancelled else { return }
            do {
                let result: SearchSnapshot
                if extract {
                    result = try engine.makeSearchable(progress: { done, total, name in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.closed, self.generation == id, !token.isCancelled else { return }
                            self.progress.isIndeterminate = total <= 0
                            self.progress.maxValue = Double(max(total, 1))
                            self.progress.doubleValue = Double(done)
                            self.setStatus("\(done)/\(total) · \(name)")
                        }
                    }, cancelled: { lifetime.isCancelled || token.isCancelled })
                } else {
                    result = try engine.scan()
                }
                var stamps: [URL: SearchFileStamp] = [:]
                for source in result.sources {
                    if lifetime.isCancelled { return }
                    stamps[source.url] = try? SearchFileStamp.read(source.url, vault: vault)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.generation == id else { return }
                    self.snapshot = result
                    self.stamps = stamps
                    self.finish(error: nil, cancelled: token.isCancelled)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.generation == id else { return }
                    self.finish(error: error, cancelled: token.isCancelled)
                }
            }
        }
    }

    private func finish(error: Error?, cancelled: Bool) {
        busy = false
        extracting = false
        operation = nil
        makeButton.isEnabled = true
        cancelButton.isHidden = true
        progress.stopAnimation(nil)
        progress.isHidden = true
        render()
        if cancelled { setStatus("Stopped. Completed extractions are preserved; remaining sources can be processed later.") }
        else if let error { setStatus("Could not read sources: \(error.localizedDescription)") }
        // FSEvents caused by companion writes collapse into one trailing scan.
        if refreshRequested || cancelled { refresh() }
    }

    @objc func makeSearchable() { start(extract: true) }

    @objc private func cancelExtraction() {
        guard extracting else { return }
        operation?.cancel()
        cancelButton.isEnabled = false
        setStatus("Stopping after the current source…")
    }

    private func render() {
        guard !closed else { return }
        let query = field.stringValue
        let browsing = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selected = table.selectedRow >= 0 && table.selectedRow < hits.count ? hits[table.selectedRow] : nil
        let previousOffset = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
        hits = snapshot?.search(query) ?? []
        if browsing {
            hits.sort {
                let left = stamps[$0.source.url]?.modified ?? .distantPast
                let right = stamps[$1.source.url]?.modified ?? .distantPast
                return left == right ? $0.source.relativePath < $1.source.relativePath : left > right
            }
        }
        table.reloadData()
        if let selected, let row = hits.firstIndex(where: { $0.source.url == selected.source.url && $0.page == selected.page }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if let scroll = table.enclosingScrollView {
            let height = hits.isEmpty ? 0 : table.rect(ofRow: hits.count - 1).maxY
            let y = renderedQuery == query ? min(previousOffset.y, max(0, height - scroll.contentView.bounds.height)) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        renderedQuery = query
        recentLabel.isHidden = !browsing
        updateProcessingNotice()
        empty.isHidden = !hits.isEmpty
        let pending = snapshot?.pendingCount ?? 0
        if snapshot == nil {
            empty.stringValue = busy ? "Reading local sources…" : "Sources could not be loaded. Check folder access or choose another folder."
        } else if snapshot?.sources.isEmpty == true {
            empty.stringValue = "No sources yet. Capture a note or add files to this folder."
        } else {
            empty.stringValue = "No matches.\(pending > 0 ? " \(pending) sources still need Make searchable; their filenames can already be searched." : " Try other original-language words or a filename.")"
        }
        if !busy, let snapshot {
            let noun = browsing ? (hits.count == 1 ? "source" : "sources") : (hits.count == 1 ? "result" : "results")
            setStatus("\(hits.count) \(noun) · \(snapshot.readyCount) ready · \(snapshot.pendingCount) pending · \(snapshot.issueCount) need attention · Local only")
        }
        openButton.isEnabled = !busy && !hits.isEmpty
    }

    private func updateProcessingNotice() {
        let pending = snapshot?.pendingCount ?? 0
        let issues = snapshot?.issueCount ?? 0
        let retryable = snapshot?.sources.contains {
            ($0.kind == .image || $0.kind == .pdf) && $0.state == .unreadable
        } ?? false
        processingNotice.isHidden = !extracting && pending == 0 && issues == 0
        makeButton.isHidden = extracting || (pending == 0 && !retryable)
        makeButton.title = pending > 0 ? "Make searchable" : "Retry extraction"
        if extracting { processingLabel.stringValue = "Processing on this Mac. Originals stay unchanged." }
        else if pending > 0 { processingLabel.stringValue = "\(pending) \(pending == 1 ? "file needs" : "files need") text extraction." }
        else { processingLabel.stringValue = "\(issues) \(issues == 1 ? "file needs" : "files need") attention. Clear search to review statuses." }
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
        onStatus?(text)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SearchHitRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("SearchHit")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SearchHitCell) ?? SearchHitCell(frame: .zero)
        cell.identifier = id
        cell.show(hits[row])
        return cell
    }

    @objc private func openSelected() {
        guard !closed, !busy, !hits.isEmpty else { return }
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard hits.indices.contains(row) else { return }
        let hit = hits[row]
        guard let expected = stamps[hit.source.url] else {
            setStatus("Source is missing or unreadable: \(hit.source.relativePath). Use Make searchable to refresh.")
            return
        }
        let vault = self.vault
        let lifetime = self.lifetime
        let id = generation
        openButton.isEnabled = false
        queue.async { [weak self] in
            guard !lifetime.isCancelled else { return }
            do {
                let current = try SearchFileStamp.read(hit.source.url, vault: vault)
                guard current == expected else { throw VaultError.conflict(hit.source.relativePath) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.generation == id else { return }
                    self.openButton.isEnabled = true
                    if hit.source.kind == .note {
                        guard let onOpenNote = self.onOpenNote else {
                            self.setStatus("The note editor is not available.")
                            return
                        }
                        onOpenNote(hit.source.url)
                    } else if !NSWorkspace.shared.open(hit.source.url) {
                        self.setStatus("No viewer could open \(hit.source.relativePath).")
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.generation == id else { return }
                    self.openButton.isEnabled = true
                    self.setStatus("Could not open original: \(error.localizedDescription). Use Make searchable to refresh.")
                }
            }
        }
    }
}

/// Lock-protected because extraction polls this from its background queue.
private final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

private struct SearchFileStamp: Equatable {
    let size: Int
    let modified: Date
    let identifier: String

    static func read(_ url: URL, vault: Vault) throws -> SearchFileStamp {
        try vault.validateSource(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else {
            throw VaultError.invalidAttachment(url.path)
        }
        return SearchFileStamp(size: size, modified: modified, identifier: String(describing: values.fileResourceIdentifier))
    }
}

@MainActor
private final class SearchHitRow: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        drawCard(selected: false)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        drawCard(selected: true)
    }

    private func drawCard(selected: Bool) {
        let rect = bounds.insetBy(dx: 1, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        (selected ? Theme.accentSoft : Theme.paper).setFill()
        path.fill()
        (selected ? Theme.accent : Theme.border).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        if selected {
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 5, y: rect.minY + 17, width: 3, height: max(0, rect.height - 34)), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

@MainActor
private final class SearchResultsTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class SearchHitCell: NSTableCellView {
    private let title = Theme.label("", size: 14, color: Theme.ink)
    private let snippet = Theme.label("", size: 12, color: Theme.ink)
    private let path = Theme.label("", size: 10)
    private let metadata = Theme.label("", size: 10)
    private let icon = NSImageView()
    private let tile = PaperSurface(cornerRadius: 10, color: Theme.accentSoft, bordered: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        snippet.lineBreakMode = .byTruncatingTail
        snippet.maximumNumberOfLines = 2
        path.lineBreakMode = .byTruncatingMiddle
        metadata.lineBreakMode = .byTruncatingTail
        metadata.font = .systemFont(ofSize: 10, weight: .medium)
        icon.contentTintColor = Theme.accent
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        Theme.fill(icon, in: tile, inset: 10)
        for view in [tile, title, snippet, path, metadata] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            tile.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            tile.widthAnchor.constraint(equalToConstant: 40),
            tile.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            snippet.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            snippet.heightAnchor.constraint(equalToConstant: 32),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            path.topAnchor.constraint(equalTo: snippet.bottomAnchor, constant: 5),
            metadata.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 3),
            metadata.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func show(_ hit: SearchHit) {
        let source = hit.source
        let kind: String
        let symbol: String
        switch source.kind {
        case .note: kind = "Note"; symbol = "note.text"
        case .text: kind = "Text"; symbol = "doc.text"
        case .pdf: kind = "PDF"; symbol = "doc.richtext"
        case .image: kind = "Image"; symbol = "photo"
        case .unsupported: kind = "File"; symbol = "doc"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        title.stringValue = source.title
        let text = NSMutableAttributedString(string: hit.snippet, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.ink])
        let utf16 = hit.snippet as NSString
        for range in hit.highlights where range.location != NSNotFound && range.location >= 0 && range.length > 0 && NSMaxRange(range) <= utf16.length {
            let safeRange = utf16.rangeOfComposedCharacterSequences(for: range)
            text.addAttributes([.backgroundColor: Theme.accentSoft, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)], range: safeRange)
        }
        snippet.attributedStringValue = text
        path.stringValue = source.relativePath
        let page = hit.page.map { " · Page \($0)" } ?? ""
        metadata.stringValue = "\(kind)\(page) · \(source.state.rawValue.capitalized)\(source.detail.isEmpty ? "" : " — \(source.detail)")"
        path.toolTip = source.relativePath
        metadata.toolTip = metadata.stringValue
        toolTip = "\(title.stringValue)\n\(path.stringValue)\n\(metadata.stringValue)\n\(hit.snippet)"
        setAccessibilityLabel(toolTip)
    }
}
