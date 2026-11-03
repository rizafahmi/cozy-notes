import AppKit
import CozyCore
import CozySearch

/// One queue owns the engine; only immutable search snapshots reach AppKit.
@MainActor
final class SearchPanel: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenNote: ((URL) -> Void)?
    var onStatus: ((String) -> Void)?
    var isProcessing: Bool { busy }

    private let vault: Vault
    private let engine: CaptureSearch
    private let queue = DispatchQueue(label: "CozyNotes.capture-search", qos: .userInitiated)
    private let lifetime = SearchCancellation()
    private let field = NSSearchField()
    private let table = SearchResultsTable()
    private let status = Theme.label("Loading local sources…", size: 11)
    private let empty = Theme.label("Loading local sources…")
    private let progress = NSProgressIndicator()
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
        wantsLayer = true
        layer?.backgroundColor = Theme.canvas.cgColor
        field.placeholderString = "Search notes, screenshots and PDFs"
        field.delegate = self
        field.target = self
        field.action = #selector(openSelected)
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        makeButton = Theme.button("Make searchable", target: self, action: #selector(makeSearchable))
        makeButton.toolTip = "Extract selectable PDF text and recognize screenshot text locally. Originals are preserved."
        cancelButton = Theme.button("Cancel", target: self, action: #selector(cancelExtraction))
        cancelButton.isHidden = true
        openButton = Theme.button("Open original", target: self, action: #selector(openSelected))
        openButton.isEnabled = false
        let toolbar = Theme.stack([field, makeButton, cancelButton, openButton], spacing: 8)
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
        table.rowHeight = 90
        table.intercellSpacing = NSSize(width: 0, height: 4)
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
        for view in [toolbar, results, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            results.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            results.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            results.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            results.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(vault:)") }

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
        let selected = table.selectedRow >= 0 && table.selectedRow < hits.count ? hits[table.selectedRow] : nil
        hits = snapshot?.search(field.stringValue) ?? []
        table.reloadData()
        if let selected, let row = hits.firstIndex(where: { $0.source.url == selected.source.url && $0.page == selected.page }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        empty.isHidden = !hits.isEmpty
        let pending = snapshot?.pendingCount ?? 0
        if snapshot == nil {
            empty.stringValue = busy ? "Reading local sources…" : "Sources could not be loaded. Try Make searchable or refresh the folder."
        } else if snapshot?.sources.isEmpty == true {
            empty.stringValue = "No sources yet. Capture a note or add files to this folder."
        } else {
            empty.stringValue = "No matches.\(pending > 0 ? " \(pending) sources still need Make searchable; their filenames can already be searched." : " Try other original-language words or a filename.")"
        }
        if !busy, let snapshot {
            let browsing = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let noun = browsing ? (hits.count == 1 ? "source" : "sources") : (hits.count == 1 ? "result" : "results")
            setStatus("\(hits.count) \(noun) · \(snapshot.readyCount) ready · \(snapshot.pendingCount) pending · \(snapshot.issueCount) need attention · Local only")
        }
        openButton.isEnabled = !busy && !hits.isEmpty
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
        onStatus?(text)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

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
private final class SearchResultsTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class SearchHitCell: NSTableCellView {
    private let title = Theme.label("", size: 13, color: Theme.ink)
    private let snippet = Theme.label("", size: 12, color: Theme.ink)
    private let detail = Theme.label("", size: 10)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        snippet.lineBreakMode = .byTruncatingTail
        snippet.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 2
        for label in [title, snippet, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            snippet.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: snippet.bottomAnchor, constant: 4),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func show(_ hit: SearchHit) {
        let source = hit.source
        let page = hit.page.map { " · Page \($0)" } ?? ""
        title.stringValue = "\(source.kind.rawValue.uppercased()) · \(source.title)\(page)"
        let text = NSMutableAttributedString(string: hit.snippet, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.ink])
        let utf16 = hit.snippet as NSString
        for range in hit.highlights where range.location != NSNotFound && range.location >= 0 && range.length > 0 && NSMaxRange(range) <= utf16.length {
            let safeRange = utf16.rangeOfComposedCharacterSequences(for: range)
            text.addAttributes([.backgroundColor: Theme.sidebar, .font: NSFont.systemFont(ofSize: 12, weight: .bold)], range: safeRange)
        }
        snippet.attributedStringValue = text
        detail.stringValue = "\(source.relativePath) · \(source.state.rawValue.capitalized)\(source.detail.isEmpty ? "" : " — \(source.detail)")"
        toolTip = "\(title.stringValue)\n\(detail.stringValue)\n\(hit.snippet)"
        setAccessibilityLabel(toolTip)
    }
}
