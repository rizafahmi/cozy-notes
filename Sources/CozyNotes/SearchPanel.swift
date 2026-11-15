import AppKit
import CozyCore
import CozySearch

/// One queue owns the engine; only immutable search snapshots reach AppKit.
@MainActor
final class SearchPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    var onOpenNote: ((URL) -> Void)?
    var onOpenNoteInNewWindow: ((URL) -> Void)?
    var onTogglePinNote: ((URL) -> Void)?
    var onMergeNotes: (([URL]) -> Void)?
    var onNewNote: (() -> Void)?
    var onDeleteNote: ((URL) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onToggleAppearance: (() -> Void)?
    var onSwitchAtmosphere: ((Theme.Atmosphere) -> Void)?
    var onRevealFolder: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onOpenFolderInNewWindow: (() -> Void)?
    var onShowRecovery: (() -> Void)?
    var onShowGlobalSearch: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var isProcessing: Bool { busy }
    var isExtracting: Bool { extracting }
    var selectedNoteURL: URL? {
        if table.selectedRowIndexes.count > 1 {
            return selectedNoteURLs.first
        }
        let row = table.selectedRow
        guard hits.indices.contains(row), hits[row].source.kind == .note else { return nil }
        return hits[row].source.url
    }
    var selectedNoteURLs: [URL] {
        syncOrderedSelectionFromTable()
        return orderedSelectedNoteURLs
    }
    var isSidebarFocused: Bool { window?.firstResponder === table }
    var visibleHits: [SearchHit] { hits }
    private(set) var activeTagFilter: String?
    var availableTags: [TagCount] { snapshot?.tagCounts ?? [] }

    private let vault: Vault
    private let engine: CaptureSearch
    private let queue = DispatchQueue(label: "CozyNotes.capture-search", qos: .userInitiated)
    private let lifetime = SearchCancellation()
    private let table = SearchResultsTable()
    private let tagFilterBar = TagFilterBar()
    private let status = Theme.label("LOADING…", size: 10.5, color: Theme.subtle)
    private let empty = Theme.label("Loading…", size: 12.5, color: Theme.muted)
    private let progress = NSProgressIndicator()
    private let processingRow = NSStackView()
    private let processingNotice = PaperSurface(cornerRadius: 8, color: Theme.accentSoft, bordered: false)
    private let processingLabel = Theme.label("", size: 11, color: Theme.ink)
    private var makeButton: QuietButton!
    private var cancelButton: QuietButton!
    private var openButton: QuietButton!
    private var moreButton: QuietButton!
    private var snapshot: SearchSnapshot?
    private var hits: [SearchHit] = []
    private var stamps: [URL: SearchFileStamp] = [:]
    private var activeNoteURL: URL?
    private var orderedSelectedNoteURLs: [URL] = []
    private var suppressSelectionAction = false
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
        tagFilterBar.onSelectTag = { [weak self] tag in
            self?.setTagFilter(tag)
        }
        tagFilterBar.isHidden = true

        let folderLabel = vault.root.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionStamp = Theme.label((folderLabel.isEmpty ? "INDEX" : folderLabel).uppercased(), size: 10, color: Theme.subtle)
        sectionStamp.font = Theme.monoFont(10, weight: .semibold)
        sectionStamp.lineBreakMode = .byTruncatingMiddle
        sectionStamp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sectionStamp.toolTip = vault.root.path
        let globalSearchBtn = QuietButton(symbol: "magnifyingglass", target: self, action: #selector(globalSearchTapped))
        globalSearchBtn.toolTip = "Global Note Search (⌘P / ⇧⌘F)"
        globalSearchBtn.setAccessibilityLabel("Global Note Search")

        let appearanceBtn = QuietButton(symbol: "circle.lefthalf.filled", target: self, action: #selector(toggleAppearanceTapped))
        appearanceBtn.toolTip = "Switch Light / Dark appearance"
        appearanceBtn.setAccessibilityLabel("Switch appearance")

        let toggleSidebar = QuietButton(symbol: "sidebar.left", target: self, action: #selector(toggleSidebarTapped))
        toggleSidebar.toolTip = "Hide or show index (⌘\\)"
        toggleSidebar.setAccessibilityLabel("Toggle sidebar")

        let newNote = QuietButton(symbol: "square.and.pencil", target: self, action: #selector(newNoteTapped))
        newNote.tint = Theme.accent
        newNote.toolTip = "New folio note (⌘N)"
        newNote.setAccessibilityLabel("New note")

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerBar = Theme.stack([sectionStamp, headerSpacer, globalSearchBtn, appearanceBtn, toggleSidebar, newNote], spacing: 2)
        makeButton = QuietButton(title: "Index", target: self, action: #selector(makeSearchable))
        makeButton.tint = Theme.accent
        makeButton.font = .systemFont(ofSize: 11, weight: .semibold)
        makeButton.toolTip = "Extract selectable PDF text and recognize screenshot text locally. Originals are preserved."

        cancelButton = QuietButton(title: "Stop", target: self, action: #selector(cancelExtraction))
        cancelButton.font = .systemFont(ofSize: 11, weight: .medium)
        cancelButton.isHidden = true

        openButton = QuietButton(title: "Open ↗", target: self, action: #selector(openSelected))
        openButton.font = .systemFont(ofSize: 11, weight: .medium)
        openButton.toolTip = "Open selected item"
        openButton.isHidden = true

        moreButton = QuietButton(symbol: "ellipsis.circle", target: self, action: #selector(showMoreMenu(_:)))
        moreButton.toolTip = "Collection options, folder, and recovery"
        moreButton.setAccessibilityLabel("Collection options")

        processingLabel.lineBreakMode = .byTruncatingTail
        processingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let processingSpacer = NSView()
        processingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        processingRow.orientation = .horizontal
        processingRow.alignment = .centerY
        processingRow.distribution = .fill
        processingRow.spacing = 6
        for view in [processingLabel, processingSpacer, makeButton!, cancelButton!] { processingRow.addArrangedSubview(view) }
        Theme.fill(processingRow, in: processingNotice, inset: 8)
        processingNotice.isHidden = true

        let top = Theme.stack([tagFilterBar, processingNotice], orientation: .vertical, spacing: 6)
        tagFilterBar.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        processingNotice.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 14).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 14).isActive = true

        status.font = Theme.monoFont(10, weight: .medium)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Theme.stack([progress, status, footerSpacer, openButton, moreButton], spacing: 6)
        let footerDivider = HairlineView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 74
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelected() }
        table.onOptionReturn = { [weak self] in self?.openSelectedInNewWindow() }
        table.onTogglePin = { [weak self] in self?.togglePinSelectedNote() }
        table.onMerge = { [weak self] in self?.mergeSelectedNotes() }
        table.onDelete = { [weak self] in self?.deleteSelectedNote() }
        table.onMenuForRow = { [weak self] row in self?.contextMenuForRow(row) }
        let scroll = NSScrollView()
        scroll.verticalScroller = CozyScroller()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false

        empty.alignment = .center
        empty.maximumNumberOfLines = 4
        let results = NSView()
        Theme.fill(scroll, in: results)
        empty.translatesAutoresizingMaskIntoConstraints = false
        results.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: results.leadingAnchor, constant: 18),
            empty.trailingAnchor.constraint(equalTo: results.trailingAnchor, constant: -18),
            empty.centerYAnchor.constraint(equalTo: results.centerYAnchor)
        ])

        for view in [headerBar, top, results, footerDivider, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 78),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            headerBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerBar.heightAnchor.constraint(equalToConstant: 30),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            top.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            results.leadingAnchor.constraint(equalTo: leadingAnchor),
            results.trailingAnchor.constraint(equalTo: trailingAnchor),
            results.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4),
            results.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(vault:)") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()
    }

    func focusSidebar() {
        guard !closed else { return }
        if table.selectedRow < 0, !hits.isEmpty {
            suppressSelectionAction = true
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            suppressSelectionAction = false
            syncOrderedSelectionFromTable()
        }
        window?.makeFirstResponder(table)
    }

    func freshSnapshotAndModifiedDates() -> (snapshot: SearchSnapshot?, dates: [URL: Date]) {
        if let fresh = try? engine.scan() {
            var dates: [URL: Date] = [:]
            for source in fresh.sources {
                if let existing = stamps[source.url]?.modified {
                    dates[source.url] = existing
                } else if let mod = (try? source.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    dates[source.url] = mod
                }
            }
            return (fresh, dates)
        }
        var dates: [URL: Date] = [:]
        for (url, stamp) in stamps {
            dates[url] = stamp.modified
        }
        return (snapshot, dates)
    }

    func selectNote(_ url: URL?) {
        activeNoteURL = url
        suppressSelectionAction = true
        defer { suppressSelectionAction = false }
        guard let url, let row = hits.firstIndex(where: { $0.source.url == url }) else {
            orderedSelectedNoteURLs = []
            table.deselectAll(nil)
            updateOpenButtonVisibility()
            updateFooterSummary()
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        orderedSelectedNoteURLs = hits[row].source.kind == .note ? [url] : []
        updateOpenButtonVisibility()
        updateFooterSummary()
    }

    func selectNotes(_ urls: [URL]) {
        suppressSelectionAction = true
        defer { suppressSelectionAction = false }
        var rowIndexes = IndexSet()
        var ordered: [URL] = []
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if let row = hits.firstIndex(where: { $0.source.kind == .note && $0.source.url == canonical }) {
                rowIndexes.insert(row)
                if !ordered.contains(canonical) {
                    ordered.append(canonical)
                }
            }
        }
        orderedSelectedNoteURLs = ordered
        if rowIndexes.isEmpty {
            table.deselectAll(nil)
        } else {
            table.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        }
        updateOpenButtonVisibility()
        updateFooterSummary()
    }

    private func syncOrderedSelectionFromTable() {
        var currentNotes: [URL] = []
        for row in table.selectedRowIndexes where hits.indices.contains(row) && hits[row].source.kind == .note {
            let url = hits[row].source.url
            if !currentNotes.contains(url) {
                currentNotes.append(url)
            }
        }
        orderedSelectedNoteURLs.removeAll { !currentNotes.contains($0) }
        for url in currentNotes where !orderedSelectedNoteURLs.contains(url) {
            orderedSelectedNoteURLs.append(url)
        }
    }

    func applyPinnedPaths(_ pinnedPaths: Set<String>) {
        guard !closed else { return }
        if let current = snapshot {
            snapshot = current.updatingPinnedPaths(pinnedPaths)
            render()
        } else {
            refresh()
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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
        onOpenNoteInNewWindow = nil
        onTogglePinNote = nil
        onMergeNotes = nil
        onNewNote = nil
        onDeleteNote = nil
        onToggleSidebar = nil
        onRevealFolder = nil
        onChooseFolder = nil
        onShowRecovery = nil
        onShowGlobalSearch = nil
        onStatus = nil
        makeButton.isEnabled = false
        cancelButton.isEnabled = false
        openButton.isEnabled = false
        moreButton.isEnabled = false
    }

    @objc private func globalSearchTapped() { onShowGlobalSearch?() }
    @objc private func toggleAppearanceTapped() { onToggleAppearance?() }
    @objc private func toggleSidebarTapped() { onToggleSidebar?() }
    @objc private func newNoteTapped() { onNewNote?() }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let newItem = NSMenuItem(title: "New Note", action: #selector(newNoteTapped), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)

        let selectedNotes = selectedNoteURLs
        if selectedNotes.count >= 2 {
            let mergeItem = NSMenuItem(
                title: "Merge \(selectedNotes.count) Notes…",
                action: #selector(mergeSelectedNotes),
                keyEquivalent: ""
            )
            mergeItem.target = self
            mergeItem.isEnabled = !busy
            menu.addItem(mergeItem)
        }

        let indexItem = NSMenuItem(title: "Make Searchable", action: #selector(makeSearchable), keyEquivalent: "")
        indexItem.target = self
        indexItem.isEnabled = !busy
        menu.addItem(indexItem)

        menu.addItem(.separator())
        for preset in Theme.Atmosphere.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectAtmosphere(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = Theme.atmosphere == preset ? .on : .off
            menu.addItem(item)
        }
        let flipAppearance = NSMenuItem(title: "Toggle Light / Dark Mode", action: #selector(toggleAppearanceTapped), keyEquivalent: "")
        flipAppearance.target = self
        menu.addItem(flipAppearance)

        menu.addItem(.separator())

        let openFolder = NSMenuItem(title: "Open Folder in Finder", action: #selector(revealFolderTapped), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)


        let openFolderNewWindow = NSMenuItem(title: "Open Folder in New Window…", action: #selector(openFolderInNewWindowTapped), keyEquivalent: "")
        openFolderNewWindow.target = self
        menu.addItem(openFolderNewWindow)
        let changeFolder = NSMenuItem(title: "Change Notes Folder…", action: #selector(chooseFolderTapped), keyEquivalent: "")
        changeFolder.target = self
        menu.addItem(changeFolder)

        let recovery = NSMenuItem(title: "Recovery & Checkpoints…", action: #selector(recoveryTapped), keyEquivalent: "")
        recovery.target = self
        menu.addItem(recovery)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func selectAtmosphere(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = Theme.Atmosphere(rawValue: raw) else { return }
        onSwitchAtmosphere?(preset)
    }

    @objc private func revealFolderTapped() { onRevealFolder?() }
    @objc private func chooseFolderTapped() { onChooseFolder?() }
    @objc private func openFolderInNewWindowTapped() { onOpenFolderInNewWindow?() }
    @objc private func recoveryTapped() { onShowRecovery?() }

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
        progress.startAnimation(nil)
        setStatus(extract ? "Indexing on this Mac…" : "Reading notes…")
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
        if cancelled { setStatus("Stopped · Completed extractions saved") }
        else if let error { setStatus("Read error: \(error.localizedDescription)") }
        if refreshRequested || cancelled { refresh() }
    }

    @objc func makeSearchable() { start(extract: true) }

    @objc private func cancelExtraction() {
        guard extracting else { return }
        operation?.cancel()
        cancelButton.isEnabled = false
        setStatus("Stopping…")
    }

    func setTagFilter(_ rawTag: String?) {
        guard !closed else { return }
        let cleaned = rawTag
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" })) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let current = activeTagFilter, let next = cleaned, current.caseInsensitiveCompare(next) == .orderedSame {
            activeTagFilter = nil
        } else {
            activeTagFilter = cleaned
        }
        render()
    }

    private func render() {
        guard !closed else { return }
        syncOrderedSelectionFromTable()
        let previousMultiNotes = table.selectedRowIndexes.count > 1 ? orderedSelectedNoteURLs : []
        let selectedHit = table.selectedRow >= 0 && table.selectedRow < hits.count ? hits[table.selectedRow] : nil
        let targetURL = selectedHit?.source.url ?? activeNoteURL
        let targetPage = selectedHit?.page
        let previousOffset = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
        let allTagCounts = snapshot?.tagCounts ?? []
        tagFilterBar.update(tags: allTagCounts, activeTag: activeTagFilter)
        hits = snapshot?.search("", tagFilter: activeTagFilter) ?? []
        hits.sort {
            if $0.source.isPinned != $1.source.isPinned {
                return $0.source.isPinned && !$1.source.isPinned
            }
            let left = stamps[$0.source.url]?.modified ?? .distantPast
            let right = stamps[$1.source.url]?.modified ?? .distantPast
            return left == right ? $0.source.relativePath < $1.source.relativePath : left > right
        }
        suppressSelectionAction = true
        table.reloadData()
        if previousMultiNotes.count > 1 {
            var restoredIndexes = IndexSet()
            var restoredOrdered: [URL] = []
            for url in previousMultiNotes {
                if let row = hits.firstIndex(where: { $0.source.kind == .note && $0.source.url == url }) {
                    restoredIndexes.insert(row)
                    restoredOrdered.append(url)
                }
            }
            orderedSelectedNoteURLs = restoredOrdered
            if !restoredIndexes.isEmpty {
                table.selectRowIndexes(restoredIndexes, byExtendingSelection: false)
            }
        } else if let targetURL,
                  let row = hits.firstIndex(where: { $0.source.url == targetURL && (targetPage == nil || $0.page == targetPage) }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            orderedSelectedNoteURLs = hits[row].source.kind == .note ? [hits[row].source.url] : []
        } else {
            orderedSelectedNoteURLs = []
        }
        suppressSelectionAction = false
        if let scroll = table.enclosingScrollView {
            let height = hits.isEmpty ? 0 : table.rect(ofRow: hits.count - 1).maxY
            let y = min(previousOffset.y, max(0, height - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateProcessingNotice()
        empty.isHidden = !hits.isEmpty
        let pending = snapshot?.pendingCount ?? 0
        if snapshot == nil {
            empty.stringValue = busy ? "Loading notes…" : "Folder could not be loaded."
        } else if let activeTagFilter, hits.isEmpty {
            empty.stringValue = "No notes tagged #\(activeTagFilter)."
        } else if snapshot?.sources.isEmpty == true {
            empty.stringValue = "No notes yet.\nStart writing on the right."
        } else {
            empty.stringValue = "No notes yet.\(pending > 0 ? "\n\(pending) files still need indexing." : "")"
        }
        updateFooterSummary()
        updateOpenButtonVisibility()
    }

    private func updateFooterSummary() {
        guard !busy, let snapshot else { return }
        let selectedCount = orderedSelectedNoteURLs.count
        let count = hits.count
        let noun = count == 1 ? "ENTRY" : "ENTRIES"
        let pinnedCount = hits.reduce(0) { $0 + ($1.source.isPinned ? 1 : 0) }
        var summary = "\(count) \(noun)"
        if let activeTagFilter { summary += " · #\(activeTagFilter.uppercased())" }
        if selectedCount >= 2 { summary += " · \(selectedCount) SELECTED" }
        if pinnedCount > 0 { summary += " · \(pinnedCount) PINNED" }
        if snapshot.pendingCount > 0 { summary += " · \(snapshot.pendingCount) PENDING" }
        if snapshot.issueCount > 0 { summary += " · \(snapshot.issueCount) ISSUE" }
        setStatus(summary)
    }

    private func updateOpenButtonVisibility() {
        if table.selectedRowIndexes.count > 1 {
            openButton.isEnabled = !busy && !hits.isEmpty
            openButton.isHidden = true
            return
        }
        let row = table.selectedRow
        let selected = row >= 0 && row < hits.count ? hits[row] : nil
        openButton.isEnabled = !busy && !hits.isEmpty
        openButton.isHidden = selected == nil || selected?.source.kind == .note
    }

    private func updateProcessingNotice() {
        let pending = snapshot?.pendingCount ?? 0
        let issues = snapshot?.issueCount ?? 0
        let retryable = snapshot?.sources.contains {
            ($0.kind == .image || $0.kind == .pdf) && $0.state == .unreadable
        } ?? false
        processingNotice.isHidden = !extracting && pending == 0 && issues == 0
        makeButton.isHidden = extracting || (pending == 0 && !retryable)
        makeButton.title = pending > 0 ? "Make searchable" : "Retry"
        if extracting { processingLabel.stringValue = "Extracting text locally…" }
        else if pending > 0 { processingLabel.stringValue = "\(pending) \(pending == 1 ? "file needs" : "files need") OCR/text" }
        else { processingLabel.stringValue = "\(issues) \(issues == 1 ? "file needs" : "files need") attention" }
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
        onStatus?(text)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = SearchHitRow()
        rowView.isLastPinnedBeforeUnpinned = hits.indices.contains(row)
            && hits[row].source.isPinned
            && row + 1 < hits.count
            && !hits[row + 1].source.isPinned
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("SearchHit")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SearchHitCell) ?? SearchHitCell(frame: .zero)
        cell.identifier = id
        let hit = hits[row]
        let noteURL = hit.source.url
        cell.onTogglePin = hit.source.kind == .note ? { [weak self] in
            guard let self, !self.closed, !self.busy else { return }
            self.onTogglePinNote?(noteURL)
        } : nil
        cell.show(hit, modifiedAt: stamps[hit.source.url]?.modified)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        syncOrderedSelectionFromTable()
        updateOpenButtonVisibility()
        updateFooterSummary()
        guard !suppressSelectionAction, !closed, !busy else { return }
        guard table.selectedRowIndexes.count == 1 else { return }
        let row = table.selectedRow
        guard hits.indices.contains(row) else { return }
        let hit = hits[row]
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let eventType = NSApp.currentEvent?.type
        let isContextClick = eventType == .rightMouseDown || (eventType == .leftMouseDown && flags.contains(.control))
        guard !isContextClick else { return }
        let inNewWindow = (eventType == .leftMouseDown || eventType == .leftMouseUp) && flags.contains(.option)
        if hit.source.kind == .note {
            activateHit(hit, allowExternalViewer: false, inNewWindow: inNewWindow)
        }
    }

    @objc private func rowClicked() {
        guard !closed, !busy else { return }
        syncOrderedSelectionFromTable()
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        guard table.selectedRowIndexes.count <= 1,
              !flags.contains(.command),
              !flags.contains(.shift) else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard hits.indices.contains(row) else { return }
        let hit = hits[row]
        if hit.source.kind == .note {
            activateHit(hit, allowExternalViewer: false, inNewWindow: flags.contains(.option))
        }
    }

    @objc func openSelected() {
        guard !closed, !busy, !hits.isEmpty else { return }
        if selectedNoteURLs.count >= 2 {
            mergeSelectedNotes()
            return
        }
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard hits.indices.contains(row) else { return }
        activateHit(hits[row], allowExternalViewer: true)
    }

    @objc func openSelectedInNewWindow() {
        guard !closed, !busy, !hits.isEmpty else { return }
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard hits.indices.contains(row), hits[row].source.kind == .note else { return }
        activateHit(hits[row], allowExternalViewer: false, inNewWindow: true)
    }

    @objc func togglePinSelectedNote() {
        guard !closed, !busy, let url = selectedNoteURL else { return }
        onTogglePinNote?(url)
    }

    @objc func mergeSelectedNotes() {
        guard !closed, !busy else { return }
        let urls = selectedNoteURLs
        guard urls.count >= 2 else { return }
        onMergeNotes?(urls)
    }

    @objc func deleteSelectedNote() {
        guard !closed, !busy, table.selectedRowIndexes.count == 1, let url = selectedNoteURL else { return }
        onDeleteNote?(url)
    }

    func contextMenuForRow(_ row: Int) -> NSMenu? {
        guard !closed, !busy, hits.indices.contains(row) else { return nil }
        if table.selectedRowIndexes.count > 1 && table.selectedRowIndexes.contains(row) {
            let selectedNotes = selectedNoteURLs
            let allSelectedURLs = table.selectedRowIndexes.compactMap { idx -> URL? in
                guard hits.indices.contains(idx) else { return nil }
                return hits[idx].source.url
            }
            if selectedNotes.count >= 2 {
                let menu = NSMenu()
                let mergeItem = NSMenuItem(
                    title: "Merge \(selectedNotes.count) Notes…",
                    action: #selector(mergeRowsFromMenu(_:)),
                    keyEquivalent: ""
                )
                mergeItem.target = self
                mergeItem.representedObject = selectedNotes
                menu.addItem(mergeItem)

                menu.addItem(.separator())

                let revealItem = NSMenuItem(
                    title: "Reveal in Finder",
                    action: #selector(revealMultipleRowsFromMenu(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = allSelectedURLs
                menu.addItem(revealItem)
                return menu
            }
        }

        let hit = hits[row]
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: hit.source.kind == .note ? "Open Note" : "Open",
            action: #selector(openRowFromMenu(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.representedObject = row
        menu.addItem(openItem)
        if hit.source.kind == .note {
            let openNewWindowItem = NSMenuItem(
                title: "Open in New Window",
                action: #selector(openRowInNewWindowFromMenu(_:)),
                keyEquivalent: ""
            )
            openNewWindowItem.target = self
            openNewWindowItem.representedObject = row
            menu.addItem(openNewWindowItem)

            let pinItem = NSMenuItem(
                title: hit.source.isPinned ? "Unpin Note" : "Pin Note",
                action: #selector(togglePinRowFromMenu(_:)),
                keyEquivalent: ""
            )
            pinItem.target = self
            pinItem.representedObject = hit.source.url
            menu.addItem(pinItem)
        }

        let revealItem = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(revealRowFromMenu(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.representedObject = hit.source.url
        menu.addItem(revealItem)

        if hit.source.kind == .note {
            menu.addItem(.separator())
            let deleteItem = NSMenuItem(
                title: "Delete Note…",
                action: #selector(deleteRowFromMenu(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = hit.source.url
            menu.addItem(deleteItem)
        }
        return menu
    }

    @objc private func mergeRowsFromMenu(_ sender: NSMenuItem) {
        guard !closed, !busy, let urls = sender.representedObject as? [URL], urls.count >= 2 else { return }
        onMergeNotes?(urls)
    }

    @objc private func revealMultipleRowsFromMenu(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func openRowFromMenu(_ sender: NSMenuItem) {
        guard !closed, !busy, let row = sender.representedObject as? Int, hits.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        syncOrderedSelectionFromTable()
        activateHit(hits[row], allowExternalViewer: true)
    }

    @objc fileprivate func openRowInNewWindowFromMenu(_ sender: NSMenuItem) {
        guard !closed, !busy, let row = sender.representedObject as? Int, hits.indices.contains(row) else { return }
        activateHit(hits[row], allowExternalViewer: false, inNewWindow: true)
    }

    @objc private func revealRowFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func togglePinRowFromMenu(_ sender: NSMenuItem) {
        guard !closed, !busy, let url = sender.representedObject as? URL else { return }
        onTogglePinNote?(url)
    }

    @objc private func deleteRowFromMenu(_ sender: NSMenuItem) {
        guard !closed, !busy, let url = sender.representedObject as? URL else { return }
        onDeleteNote?(url)
    }

    private func activateHit(_ hit: SearchHit, allowExternalViewer: Bool, inNewWindow: Bool = false) {
        guard let expected = stamps[hit.source.url] else {
            setStatus("Missing or unreadable: \(hit.source.relativePath)")
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
                    self.updateOpenButtonVisibility()
                    if hit.source.kind == .note {
                        if inNewWindow {
                            self.selectNote(self.activeNoteURL)
                            self.onOpenNoteInNewWindow?(hit.source.url)
                        } else {
                            self.activeNoteURL = hit.source.url
                            self.onOpenNote?(hit.source.url)
                        }
                    } else if allowExternalViewer {
                        if !NSWorkspace.shared.open(hit.source.url) {
                            self.setStatus("No viewer could open \(hit.source.relativePath).")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.generation == id else { return }
                    self.updateOpenButtonVisibility()
                    self.setStatus("Could not open: \(error.localizedDescription)")
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
    var isLastPinnedBeforeUnpinned = false {
        didSet {
            if isLastPinnedBeforeUnpinned != oldValue { needsDisplay = true }
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isLastPinnedBeforeUnpinned {
            Theme.accent.withAlphaComponent(0.32).setFill()
            NSRect(x: 14, y: bounds.maxY - 1, width: max(0, bounds.width - 24), height: 1).fill()
        } else {
            Theme.border.withAlphaComponent(0.55).setFill()
            NSRect(x: 18, y: bounds.maxY - 1, width: max(0, bounds.width - 30), height: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        Theme.selectionFill.setFill()
        path.fill()
        Theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Theme.topHighlight.withAlphaComponent(0.6).setFill()
        NSRect(x: rect.minX + 8, y: rect.maxY - 1.5, width: max(0, rect.width - 16), height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Artisanal rubrication dot instead of Bear's vertical bar
        Theme.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 9, y: rect.minY + 14.5, width: 5, height: 5)).fill()
    }
}

@MainActor
private final class SearchResultsTable: NSTableView {
    var onReturn: (() -> Void)?
    var onOptionReturn: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onMerge: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMenuForRow: ((Int) -> NSMenu?)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags == [.command, .shift], window?.firstResponder === self {
                if key == "p" {
                    onTogglePin?()
                    return true
                }
                if key == "m", selectedRowIndexes.count >= 2 {
                    onMerge?()
                    return true
                }
            }
            if flags == .command, window?.firstResponder === self,
               event.keyCode == 51 || event.keyCode == 117,
               selectedRowIndexes.count == 1 {
                onDelete?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.option) {
                onOptionReturn?()
            } else {
                onReturn?()
            }
        } else if (event.keyCode == 51 || event.keyCode == 117) && (flags.isEmpty || flags == .command) {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return onMenuForRow?(row)
    }
}

@MainActor
private final class RowPinButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
private final class SearchHitCell: NSTableCellView {
    var onTogglePin: (() -> Void)?
    private let title = Theme.label("", size: 14, color: Theme.ink)
    private let badge = Theme.label("", size: 10, color: Theme.muted)
    private let snippet = Theme.label("", size: 12, color: Theme.muted)
    private let icon = NSImageView()
    private let pinButton = RowPinButton()
    private let titleRow = NSStackView()
    private var hoverTracking: NSTrackingArea?
    private var isRowHovered = false
    private var isNoteItem = false
    private var isItemPinned = false

    private static let pinnedSymbolImage: NSImage? = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    private static let unpinnedSymbolImage: NSImage? = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = Theme.displayFont(14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badge.font = Theme.monoFont(10, weight: .medium)
        badge.alignment = .right
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        icon.contentTintColor = Theme.sage
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 13).isActive = true

        pinButton.isBordered = false
        pinButton.bezelStyle = .inline
        pinButton.imagePosition = .imageOnly
        pinButton.imageScaling = .scaleProportionallyDown
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.isHidden = true
        pinButton.setContentHuggingPriority(.required, for: .horizontal)
        pinButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pinButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        pinButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        for view in [icon, title, spacer, pinButton, badge] { titleRow.addArrangedSubview(view) }

        snippet.lineBreakMode = .byTruncatingTail
        snippet.maximumNumberOfLines = 2
        snippet.cell?.wraps = true

        for view in [titleRow, snippet] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27),
            titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            snippet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            snippet.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 4),
            snippet.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isRowHovered = false
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isRowHovered = true
        syncPinButtonAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isRowHovered = false
        syncPinButtonAppearance()
    }

    @objc private func pinTapped() {
        onTogglePin?()
    }

    private func syncPinButtonAppearance() {
        guard isNoteItem, onTogglePin != nil else {
            pinButton.isHidden = !isItemPinned
            if isItemPinned {
                pinButton.image = Self.pinnedSymbolImage
                pinButton.contentTintColor = Theme.accent
                pinButton.alphaValue = 1
            }
            return
        }
        pinButton.isHidden = false
        if isItemPinned {
            pinButton.image = Self.pinnedSymbolImage
            pinButton.contentTintColor = Theme.accent
            pinButton.alphaValue = 1
            pinButton.toolTip = "Unpin note (⇧⌘P)"
            pinButton.setAccessibilityLabel("Unpin note")
        } else {
            pinButton.image = Self.unpinnedSymbolImage
            pinButton.contentTintColor = Theme.muted
            pinButton.alphaValue = isRowHovered ? 0.9 : 0
            pinButton.toolTip = "Pin note to top (⇧⌘P)"
            pinButton.setAccessibilityLabel("Pin note")
        }
    }

    func show(_ hit: SearchHit, modifiedAt: Date?) {
        let source = hit.source
        let kind: String
        let symbol: String?
        switch source.kind {
        case .note: kind = "Note"; symbol = nil
        case .text: kind = "Text"; symbol = "doc.text"
        case .pdf: kind = "PDF"; symbol = "doc.richtext"
        case .image: kind = "Image"; symbol = "photo"
        case .unsupported: kind = "File"; symbol = "doc"
        }
        if let symbol {
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        } else {
            icon.isHidden = true
        }
        title.stringValue = source.title
        isNoteItem = (source.kind == .note)
        isItemPinned = source.isPinned
        syncPinButtonAppearance()

        if let page = hit.page {
            badge.stringValue = "P.\(page)"
            badge.textColor = Theme.accent
        } else if source.state == .pending {
            badge.stringValue = "PENDING"
            badge.textColor = Theme.accent
        } else if source.state == .unreadable || source.state == .partial {
            badge.stringValue = "ISSUE"
            badge.textColor = Theme.accent
        } else if let modifiedAt {
            let cal = Calendar.current
            if cal.isDateInToday(modifiedAt) {
                badge.stringValue = Self.timeFormatter.string(from: modifiedAt).uppercased()
            } else if cal.isDateInYesterday(modifiedAt) {
                badge.stringValue = "YESTERDAY"
            } else {
                badge.stringValue = Self.shortDateFormatter.string(from: modifiedAt).uppercased()
            }
            badge.textColor = source.kind == .note ? Theme.subtle : Theme.sage
        } else {
            badge.stringValue = kind.uppercased()
            badge.textColor = Theme.subtle
        }

        let customPathPrefix: String? = (source.kind == .note && !source.relativePath.hasPrefix("Inbox/"))
            ? source.relativePath
            : nil
        if hit.highlights.isEmpty {
            var preview = hit.snippet
            if source.kind == .note {
                preview = Self.stripLeadingTitle(from: preview, title: source.title)
            }
            if preview.isEmpty {
                preview = source.kind == .note ? "No additional text" : source.detail
            }
            if let customPathPrefix {
                let combined = NSMutableAttributedString(
                    string: "\(customPathPrefix) · ",
                    attributes: [.font: Theme.monoFont(10.5, weight: .medium), .foregroundColor: Theme.subtle]
                )
                combined.append(NSAttributedString(
                    string: preview,
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.muted]
                ))
                snippet.attributedStringValue = combined
            } else {
                snippet.attributedStringValue = NSAttributedString(
                    string: preview,
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.muted]
                )
            }
        } else {
            let text = NSMutableAttributedString(
                string: hit.snippet,
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.ink]
            )
            let utf16 = hit.snippet as NSString
            for range in hit.highlights where range.location != NSNotFound && range.location >= 0 && range.length > 0 && NSMaxRange(range) <= utf16.length {
                let safeRange = utf16.rangeOfComposedCharacterSequences(for: range)
                text.addAttributes([
                    .backgroundColor: Theme.accentSoft,
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: Theme.ink
                ], range: safeRange)
            }
            snippet.attributedStringValue = text
        }

        let pinPrefix = source.isPinned ? "Pinned · " : ""
        let pageInfo = hit.page.map { " · Page \($0)" } ?? ""
        let metaInfo = "\(pinPrefix)\(kind)\(pageInfo) · \(source.state.rawValue.capitalized)\(source.detail.isEmpty ? "" : " — \(source.detail)")"
        toolTip = "\(title.stringValue)\n\(source.relativePath)\n\(metaInfo)\n\(hit.snippet)"
        setAccessibilityLabel(toolTip)
    }

    private static func stripLeadingTitle(from snippet: String, title: String) -> String {
        var cleaned = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("#") {
            cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if cleaned.hasPrefix(title) {
            cleaned = String(cleaned.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cleaned = cleaned.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\*\\*([^\\*]+)\\*\\*", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class QuickSwitcherOverlay: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let searchField = NSSearchField()
    var onOpenNote: ((URL) -> Void)?
    var onOpenNoteInNewWindow: ((URL) -> Void)?
    var onTogglePinNote: ((URL) -> Set<String>?)?
    var onOpenExternal: ((URL) -> Void)?
    var onDismiss: (() -> Void)?
    var onShowSidebarSearch: (() -> Void)?

    private let card = PaperSurface(cornerRadius: 14, color: Theme.paper, bordered: true)
    private let icon = Theme.symbol("magnifyingglass", size: 15, color: Theme.accent)
    private let table = NSTableView()
    private let statusLabel = Theme.label("", size: 10, color: Theme.subtle)
    private let emptyLabel = Theme.label("", size: 13, color: Theme.muted)
    private(set) var hits: [SearchHit] = []
    private var snapshot: SearchSnapshot?
    private var modifiedDates: [URL: Date] = [:]

    var selectedIndex: Int { table.selectedRow }
    var query: String {
        get { searchField.stringValue }
        set {
            searchField.stringValue = newValue
            updateResults()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = 2000
        setAccessibilityLabel("Global note search")

        card.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 22
        card.shadow = shadow

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 15, weight: .medium)
        searchField.textColor = Theme.ink
        searchField.placeholderString = "Jump to any note, PDF, or screenshot…"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Global note search query")
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
        }

        let escBadge = Theme.label("ESC", size: 9.5, color: Theme.subtle)
        escBadge.font = Theme.monoFont(9.5, weight: .semibold)
        escBadge.setContentHuggingPriority(.required, for: .horizontal)

        icon.setContentHuggingPriority(.required, for: .horizontal)
        let topBar = NSView()
        for v in [icon, searchField, escBadge] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: escBadge.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            escBadge.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -18),
            escBadge.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 48)
        ])

        let topDivider = HairlineView()
        let bottomDivider = HairlineView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quickSwitcherSource"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 72
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowClicked)

        let scroll = NSScrollView()
        scroll.verticalScroller = CozyScroller()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false

        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        let resultsContainer = NSView()
        Theme.fill(scroll, in: resultsContainer)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: resultsContainer.centerYAnchor)
        ])

        let hintLabel = Theme.label("↑↓ navigate  ·  ↵ open  ·  ⌥↵ new window  ·  ⇧⌘P pin  ·  esc dismiss", size: 10, color: Theme.subtle)
        hintLabel.font = Theme.monoFont(10, weight: .medium)
        statusLabel.font = Theme.monoFont(10, weight: .semibold)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerBar = Theme.stack([hintLabel, footerSpacer, statusLabel], spacing: 8)

        for v in [topBar, topDivider, resultsContainer, bottomDivider, footerBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: card.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
            resultsContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            resultsContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            resultsContainer.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 4),
            resultsContainer.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -4),
            bottomDivider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),
            footerBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            footerBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            footerBar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 30)
        ])

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        let widthConstraint = card.widthAnchor.constraint(equalToConstant: 580)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 64),
            widthConstraint,
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            card.heightAnchor.constraint(equalToConstant: 416)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        searchField.textColor = Theme.ink
        icon.contentTintColor = Theme.accent
        needsDisplay = true
        card.needsDisplay = true
        table.reloadData()
    }

    func present(snapshot: SearchSnapshot?, modifiedDates: [URL: Date], initialQuery: String = "") {
        self.snapshot = snapshot
        self.modifiedDates = modifiedDates
        searchField.stringValue = initialQuery
        updateResults()
        isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
        onDismiss?()
    }

    func controlTextDidChange(_ obj: Notification) {
        updateResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            guard !hits.isEmpty else { return true }
            let next = table.selectedRow >= 0 ? min(hits.count - 1, table.selectedRow + 1) : 0
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !hits.isEmpty else { return true }
            let prev = table.selectedRow > 0 ? table.selectedRow - 1 : 0
            table.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            table.scrollRowToVisible(prev)
            return true
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            // Field editors treat the single-line query as the whole document; AppKit's
            // moveToEndOfDocument is a no-op there, so route ⌘↓ to the line end.
            textView.moveToEndOfLine(nil)
            return true
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            textView.moveToBeginningOfLine(nil)
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let inNewWindow = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option) == true
            confirmSelection(inNewWindow: inNewWindow)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
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
            if key == "p" || key == "o" {
                dismiss()
                return true
            }
            if key == "f" {
                isHidden = true
                onShowSidebarSearch?()
                return true
            }
        } else if flags == [.command, .shift], key == "f" {
            dismiss()
            return true
        } else if flags == [.command, .shift], key == "p" {
            return togglePinSelectedNote()
        } else if flags == .option, (event.keyCode == 36 || event.keyCode == 76 || key == "\r" || key == "\n") {
            return confirmSelection(inNewWindow: true)
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(pt) {
            dismiss()
            return
        }
        super.mouseDown(with: event)
    }

    @discardableResult
    func confirmSelection(at explicitRow: Int? = nil, inNewWindow: Bool = false) -> Bool {
        guard !hits.isEmpty else { return false }
        let row = explicitRow ?? (table.selectedRow >= 0 ? table.selectedRow : 0)
        guard hits.indices.contains(row) else { return false }
        let hit = hits[row]
        isHidden = true
        if hit.source.kind == .note {
            if inNewWindow, let onOpenNoteInNewWindow {
                onOpenNoteInNewWindow(hit.source.url)
            } else {
                onOpenNote?(hit.source.url)
            }
        } else {
            onOpenExternal?(hit.source.url)
        }
        return true
    }

    @objc private func rowClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard hits.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let inNewWindow = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option) == true
        confirmSelection(at: row, inNewWindow: inNewWindow)
    }

    @discardableResult
    func togglePinSelectedNote() -> Bool {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard hits.indices.contains(row), hits[row].source.kind == .note else { return false }
        return togglePin(for: hits[row].source.url)
    }

    @discardableResult
    private func togglePin(for targetURL: URL) -> Bool {
        guard let updatedPins = onTogglePinNote?(targetURL) else { return false }
        snapshot = snapshot?.updatingPinnedPaths(updatedPins)
        updateResults(preservingSelectedURL: targetURL)
        return true
    }

    private func updateResults(preservingSelectedURL: URL? = nil) {
        let q = searchField.stringValue
        let browsing = q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var nextHits = snapshot?.search(q) ?? []
        if browsing {
            nextHits.sort {
                if $0.source.isPinned != $1.source.isPinned {
                    return $0.source.isPinned && !$1.source.isPinned
                }
                let left = modifiedDates[$0.source.url] ?? .distantPast
                let right = modifiedDates[$1.source.url] ?? .distantPast
                return left == right ? $0.source.relativePath < $1.source.relativePath : left > right
            }
        }
        hits = nextHits
        table.reloadData()
        if !hits.isEmpty {
            let targetRow = preservingSelectedURL.flatMap { url in
                hits.firstIndex(where: { $0.source.url == url })
            } ?? 0
            table.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            table.scrollRowToVisible(targetRow)
        } else {
            table.deselectAll(nil)
        }
        emptyLabel.isHidden = !hits.isEmpty
        if snapshot == nil {
            emptyLabel.stringValue = "Loading notes…"
        } else if snapshot?.sources.isEmpty == true {
            emptyLabel.stringValue = "No notes in this workspace yet."
        } else {
            emptyLabel.stringValue = "No matching notes or files."
        }
        let count = hits.count
        let noun = browsing ? (count == 1 ? "ITEM" : "ITEMS") : (count == 1 ? "MATCH" : "MATCHES")
        statusLabel.stringValue = "\(count) \(noun)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        hits.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = SearchHitRow()
        rowView.isLastPinnedBeforeUnpinned = hits.indices.contains(row)
            && hits[row].source.isPinned
            && row + 1 < hits.count
            && !hits[row + 1].source.isPinned
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("QuickSwitcherHit")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SearchHitCell) ?? SearchHitCell(frame: .zero)
        cell.identifier = id
        let hit = hits[row]
        let noteURL = hit.source.url
        cell.onTogglePin = hit.source.kind == .note ? { [weak self] in
            _ = self?.togglePin(for: noteURL)
        } : nil
        cell.show(hit, modifiedAt: modifiedDates[hit.source.url])
        return cell
    }
}

@MainActor
final class TagFilterBar: NSView {
    var onSelectTag: ((String?) -> Void)?
    private let row = NSStackView()
    private var tags: [TagCount] = []
    private var activeTag: String?
    private var lastPackedWidth: CGFloat = 0
    private(set) var visibleTagNames: [String] = []
    private(set) var overflowTagCount: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        let w = bounds.width
        if w > 40, abs(w - lastPackedWidth) > 8 {
            rebuildChips(forWidth: w)
        }
    }

    func update(tags: [TagCount], activeTag: String?) {
        self.tags = tags
        self.activeTag = activeTag
        let shouldHide = tags.isEmpty && activeTag == nil
        isHidden = shouldHide
        guard !shouldHide else {
            for sub in row.arrangedSubviews {
                row.removeArrangedSubview(sub)
                sub.removeFromSuperview()
            }
            visibleTagNames = []
            overflowTagCount = 0
            return
        }
        let targetWidth = bounds.width > 40 ? bounds.width : 260
        rebuildChips(forWidth: targetWidth)
    }

    private func rebuildChips(forWidth availableWidth: CGFloat) {
        lastPackedWidth = availableWidth
        for sub in row.arrangedSubviews {
            row.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        visibleTagNames = []
        overflowTagCount = 0

        let allBtn = TagChipButton(title: "All", count: nil, isSelected: activeTag == nil)
        allBtn.target = self
        allBtn.action = #selector(allTapped)
        allBtn.toolTip = "Show all notes"
        allBtn.setAccessibilityLabel("All notes")
        row.addArrangedSubview(allBtn)

        var orderedTags = tags
        if let activeTag {
            if let existingIdx = orderedTags.firstIndex(where: { $0.name.caseInsensitiveCompare(activeTag) == .orderedSame }) {
                if existingIdx > 0 {
                    let item = orderedTags.remove(at: existingIdx)
                    orderedTags.insert(item, at: 0)
                }
            } else {
                orderedTags.insert(TagCount(name: activeTag, count: 0), at: 0)
            }
        }

        var usedWidth = allBtn.intrinsicContentSize.width
        let spacing = row.spacing
        let overflowReserve: CGFloat = orderedTags.count > 1 ? 42 : 0

        for (index, item) in orderedTags.enumerated() {
            let isSelected = activeTag.map { $0.caseInsensitiveCompare(item.name) == .orderedSame } ?? false
            let chip = TagChipButton(title: "#\(item.name)", count: item.count > 0 ? item.count : nil, isSelected: isSelected)
            let chipWidth = chip.intrinsicContentSize.width
            let remainingHasMore = index + 1 < orderedTags.count
            let budget = availableWidth - (remainingHasMore ? overflowReserve : 0)
            if index == 0 || (usedWidth + spacing + chipWidth <= budget && visibleTagNames.count < 4) {
                chip.representedTagName = item.name
                chip.target = self
                chip.action = #selector(tagChipTapped(_:))
                chip.toolTip = "Filter by #\(item.name) (\(item.count))"
                chip.setAccessibilityLabel("Tag #\(item.name)")
                row.addArrangedSubview(chip)
                visibleTagNames.append(item.name)
                usedWidth += spacing + chipWidth
            } else {
                overflowTagCount = orderedTags.count - visibleTagNames.count
                break
            }
        }

        if overflowTagCount > 0 {
            let moreChip = TagChipButton(title: "+\(overflowTagCount) ▾", count: nil, isSelected: false)
            moreChip.target = self
            moreChip.action = #selector(showOverflowMenu(_:))
            moreChip.toolTip = "All tags (\(orderedTags.count))"
            moreChip.setAccessibilityLabel("More tags")
            row.addArrangedSubview(moreChip)
        }
    }

    @objc private func allTapped() {
        onSelectTag?(nil)
    }

    @objc private func tagChipTapped(_ sender: TagChipButton) {
        guard let tag = sender.representedTagName else { return }
        onSelectTag?(tag)
    }

    @objc private func showOverflowMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let allItem = NSMenuItem(title: "All Notes", action: #selector(menuAllSelected), keyEquivalent: "")
        allItem.target = self
        allItem.state = activeTag == nil ? .on : .off
        menu.addItem(allItem)
        if !tags.isEmpty {
            menu.addItem(.separator())
            for item in tags {
                let menuItem = NSMenuItem(
                    title: "#\(item.name)  (\(item.count))",
                    action: #selector(menuTagSelected(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = item.name
                if let activeTag, activeTag.caseInsensitiveCompare(item.name) == .orderedSame {
                    menuItem.state = .on
                }
                menu.addItem(menuItem)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func menuAllSelected() {
        onSelectTag?(nil)
    }

    @objc private func menuTagSelected(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        onSelectTag?(tag)
    }
}

@MainActor
private final class TagChipButton: NSButton {
    var representedTagName: String?
    private let chipTitle: String
    private let chipCount: Int?
    private let isSelectedChip: Bool
    private var hoverArea: NSTrackingArea?
    private var isHovered = false

    init(title: String, count: Int?, isSelected: Bool) {
        self.chipTitle = title
        self.chipCount = count
        self.isSelectedChip = isSelected
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        TitleConfig.apply(to: self, title: title, count: count, isSelected: isSelected)
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:count:isSelected:)") }

    @MainActor
    private enum TitleConfig {
        static func apply(to button: NSButton, title: String, count: Int?, isSelected: Bool) {
            let font = Theme.monoFont(10.5, weight: isSelected ? .semibold : .medium)
            let primaryColor = isSelected ? Theme.accent : Theme.ink.withAlphaComponent(0.84)
            let result = NSMutableAttributedString(
                string: title,
                attributes: [.font: font, .foregroundColor: primaryColor]
            )
            if let count {
                result.append(NSAttributedString(
                    string: " \(count)",
                    attributes: [
                        .font: Theme.monoFont(9.5, weight: .regular),
                        .foregroundColor: isSelected ? Theme.accent.withAlphaComponent(0.8) : Theme.subtle
                    ]
                ))
            }
            button.attributedTitle = result
        }
    }

    override var intrinsicContentSize: NSSize {
        let base = attributedTitle.size()
        return NSSize(width: min(132, ceil(base.width) + 14), height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        TitleConfig.apply(to: self, title: chipTitle, count: chipCount, isSelected: isSelectedChip)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if isSelectedChip {
            Theme.accentSoft.setFill()
            path.fill()
            Theme.accent.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            let fillAlpha: CGFloat = isHovered ? 0.92 : 0.55
            Theme.elevated.withAlphaComponent(fillAlpha).setFill()
            path.fill()
            Theme.border.withAlphaComponent(isHovered ? 0.95 : 0.65).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let textSize = attributedTitle.size()
        let drawRect = NSRect(
            x: rect.minX + 6.5,
            y: rect.midY - textSize.height / 2,
            width: max(0, rect.width - 13),
            height: textSize.height
        )
        attributedTitle.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
