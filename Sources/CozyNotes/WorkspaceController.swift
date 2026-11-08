import AppKit
import CozyCore

@MainActor final class WorkspaceController: NSWindowController, NSWindowDelegate {
    let vault: Vault
    let editor = CaptureEditor(frame: .zero)
    private let searchPanel: SearchPanel
    let quickSwitcher = QuickSwitcherOverlay(frame: .zero)
    private let sidebarContainer = NSView()
    private let folioSurface = FolioPageSurface()
    private let collapsedControls = NSStackView()
    private let sealDot = PaperSurface(cornerRadius: 3.5, color: Theme.sage, bordered: false)
    private let contextLabel = Theme.label("", size: 10.5, color: Theme.muted)
    private let voiceButton = QuietButton(title: "AVENIR", symbol: "textformat", target: nil, action: nil)
    private let atmosphereButton = QuietButton(title: "OBSIDIAN", symbol: "sparkles", target: nil, action: nil)
    let openInNewWindowButton = QuietButton(symbol: "rectangle.on.rectangle", target: nil, action: nil)
    let revealButton = QuietButton(symbol: "doc.viewfinder", target: nil, action: nil)
    let deleteButton = QuietButton(symbol: "trash", target: nil, action: nil)
    private let conflictSaveButton = PrimaryButton()
    private let headerRule = HairlineView()
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var folioLeadingConstraint: NSLayoutConstraint?
    private var folioTopConstraint: NSLayoutConstraint?
    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var ruleLeadingConstraint: NSLayoutConstraint?
    private var ruleTrailingConstraint: NSLayoutConstraint?

    private(set) var isSidebarCollapsed = false
    private(set) var noteURL: URL? {
        didSet {
            if noteURL != oldValue { cachedNoteStamp = nil }
        }
    }
    private var noteBaseline = "" {
        didSet {
            noteBaselineUTF16Length = (noteBaseline as NSString).length
        }
    }
    private var noteBaselineUTF16Length = 0
    private var cachedNoteStamp: String?
    private var noteDirty = false
    private var noteConflicted = false
    private var noteAvailable = true
    private var autosave: Timer?
    private var watcher: VaultWatcher?
    private(set) var noteWindows: [NoteWindowController] = []
    var activeNoteWindowController: NoteWindowController? {
        noteWindows.first { $0.window === NSApp.keyWindow }
    }
    var onChooseFolder: (() -> Void)?

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, MMM d, yyyy · HH:mm")
        return f
    }()
    init(vault: Vault) {
        self.vault = vault
        self.searchPanel = SearchPanel(vault: vault)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cozy Notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.representedURL = vault.root
        window.minSize = NSSize(width: 720, height: 500)
        window.backgroundColor = Theme.canvas
        if let savedAppearance = UserDefaults.standard.string(forKey: "cozyAppearance") {
            window.appearance = NSAppearance(named: savedAppearance == "dark" ? .darkAqua : .aqua)
        } else {
            window.appearance = nil
        }
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireCallbacks()
        watcher = VaultWatcher(root: vault.root) { [weak self] in self?.refresh() }
        searchPanel.refresh()
        updateEditorChrome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        let desk = PaperSurface(cornerRadius: 0, color: Theme.canvas, bordered: false)
        window?.contentView = desk
        let content = desk
        Theme.fill(searchPanel, in: sidebarContainer)

        let expandSidebar = QuietButton(symbol: "sidebar.left", target: self, action: #selector(toggleSidebar))
        expandSidebar.toolTip = "Show index sidebar (⌘\\)"
        expandSidebar.setAccessibilityLabel("Show sidebar")

        let quickNew = QuietButton(symbol: "square.and.pencil", target: self, action: #selector(newCapture))
        quickNew.tint = Theme.accent
        quickNew.toolTip = "New folio note (⌘N)"
        quickNew.setAccessibilityLabel("New note")

        collapsedControls.orientation = .horizontal
        collapsedControls.alignment = .centerY
        collapsedControls.spacing = 4
        collapsedControls.addArrangedSubview(expandSidebar)
        collapsedControls.addArrangedSubview(quickNew)
        collapsedControls.isHidden = true

        sealDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        sealDot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        contextLabel.font = Theme.monoFont(10.5, weight: .medium)
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        voiceButton.target = self
        voiceButton.action = #selector(cycleVoice)
        voiceButton.font = Theme.monoFont(10, weight: .semibold)
        voiceButton.toolTip = "Cycle writing typeface (Avenir / Charter / Iowan / Mono)"

        atmosphereButton.target = self
        atmosphereButton.action = #selector(cycleAtmosphere)
        atmosphereButton.font = Theme.monoFont(10, weight: .semibold)
        atmosphereButton.toolTip = "Switch journal atmosphere (Obsidian / Midnight)"
        openInNewWindowButton.target = self
        openInNewWindowButton.action = #selector(openCurrentNoteInNewWindow)
        openInNewWindowButton.toolTip = "Open note in new window (⌥⌘O)"
        openInNewWindowButton.setAccessibilityLabel("Open note in new window")
        revealButton.target = self
        revealButton.action = #selector(revealCurrentNote)
        revealButton.toolTip = "Reveal this note in Finder"
        revealButton.setAccessibilityLabel("Reveal note in Finder")
        deleteButton.target = self
        deleteButton.action = #selector(deleteCurrentNote)
        deleteButton.toolTip = "Delete this note (⌘⌫)"
        deleteButton.setAccessibilityLabel("Delete note")

        conflictSaveButton.title = "Keep as new note"
        conflictSaveButton.target = self
        conflictSaveButton.action = #selector(resolveConflictAsNewNote)
        conflictSaveButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let editorHeader = Theme.stack([collapsedControls, sealDot, contextLabel, spacer, conflictSaveButton, voiceButton, atmosphereButton, openInNewWindowButton, revealButton, deleteButton], spacing: 6)

        for view in [editorHeader, headerRule, editor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            folioSurface.addSubview(view)
        }
        let headerLead = editorHeader.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let headerTrail = editorHeader.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let ruleLead = headerRule.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let ruleTrail = headerRule.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        headerLeadingConstraint = headerLead
        headerTrailingConstraint = headerTrail
        ruleLeadingConstraint = ruleLead
        ruleTrailingConstraint = ruleTrail

        NSLayoutConstraint.activate([
            headerLead,
            headerTrail,
            editorHeader.topAnchor.constraint(equalTo: folioSurface.topAnchor, constant: 14),
            editorHeader.heightAnchor.constraint(equalToConstant: 30),
            ruleLead,
            ruleTrail,
            headerRule.topAnchor.constraint(equalTo: editorHeader.bottomAnchor, constant: 8),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            editor.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 2),
            editor.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -4),
            editor.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: folioSurface.bottomAnchor, constant: -2)
        ])

        quickSwitcher.isHidden = true
        for view in [sidebarContainer, folioSurface, quickSwitcher] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let widthConstraint = sidebarContainer.widthAnchor.constraint(equalToConstant: 284)
        let folioLead = folioSurface.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: 8)
        let folioTop = folioSurface.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
        sidebarWidthConstraint = widthConstraint
        folioLeadingConstraint = folioLead
        folioTopConstraint = folioTop

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            widthConstraint,
            folioLead,
            folioTop,
            folioSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            folioSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            quickSwitcher.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            quickSwitcher.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            quickSwitcher.topAnchor.constraint(equalTo: content.topAnchor),
            quickSwitcher.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func wireCallbacks() {
        editor.onChange = { [weak self] in self?.editorDidChange() }
        editor.onAttachFiles = { [weak self] urls in self?.attachFilesToCurrentNote(urls) }
        editor.onRemoveLinkedAttachment = { [weak self] item in self?.removeLinkedAttachment(item) }
        editor.onHorizontalInsetChange = { [weak self] inset in self?.syncFolioMargins(inset) }
        editor.noteRecordsProvider = { [weak self] in (try? self?.vault.notes()) ?? [] }
        editor.currentNoteURLProvider = { [weak self] in self?.noteURL }
        editor.onOpenWikiLink = { [weak self] link in self?.openWikiLink(link) }
        editor.onOpenWikiLinkInNewWindow = { [weak self] link in _ = self?.openWikiLinkInNewWindow(link) }
        editor.onOpenCurrentNoteInNewWindow = { [weak self] in self?.openCurrentNoteInNewWindow() }
        editor.onQuickSwitcher = { [weak self] in self?.toggleQuickSwitcher() }
        quickSwitcher.onOpenNote = { [weak self] url in self?.openNote(url) }
        quickSwitcher.onOpenNoteInNewWindow = { [weak self] url in _ = self?.openNoteInNewWindow(url) }
        quickSwitcher.onOpenExternal = { [weak self] url in
            if !NSWorkspace.shared.open(url) {
                self?.editor.status.stringValue = "No viewer could open \(url.lastPathComponent)."
            }
            self?.editor.focus()
        }
        quickSwitcher.onDismiss = { [weak self] in self?.editor.focus() }
        quickSwitcher.onShowSidebarSearch = { [weak self] in self?.showInNoteFind() }
        searchPanel.onOpenNote = { [weak self] url in self?.openNote(url) }
        searchPanel.onOpenNoteInNewWindow = { [weak self] url in _ = self?.openNoteInNewWindow(url) }
        searchPanel.onNewNote = { [weak self] in self?.newCapture() }
        searchPanel.onDeleteNote = { [weak self] url in self?.confirmAndDeleteNote(url) }
        searchPanel.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        searchPanel.onToggleAppearance = { [weak self] in self?.toggleAppearance() }
        searchPanel.onSwitchAtmosphere = { [weak self] preset in self?.switchAtmosphere(preset) }
        searchPanel.onRevealFolder = { [weak self] in self?.revealFolder() }
        searchPanel.onChooseFolder = { [weak self] in self?.chooseFolder() }
        searchPanel.onShowRecovery = { [weak self] in self?.showRecovery() }
        searchPanel.onShowGlobalSearch = { [weak self] in self?.showQuickSwitcher() }
    }

    private func syncFolioMargins(_ inset: CGFloat) {
        folioSurface.marginX = max(24, inset - 22)
        let lead = inset
        if headerLeadingConstraint?.constant != lead {
            headerLeadingConstraint?.constant = lead
            headerTrailingConstraint?.constant = -inset
            ruleLeadingConstraint?.constant = inset
            ruleTrailingConstraint?.constant = -inset
        }
    }

    @objc func toggleAppearance() {
        guard let window else { return }
        let isCurrentlyDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let nextDark = !isCurrentlyDark
        window.appearance = NSAppearance(named: nextDark ? .darkAqua : .aqua)
        UserDefaults.standard.set(nextDark ? "dark" : "light", forKey: "cozyAppearance")
        for win in noteWindows {
            win.window?.appearance = window.appearance
        }
        refreshThemeSurfaces()
    }

    @objc func cycleVoice() {
        let cases = Theme.Voice.allCases
        let idx = cases.firstIndex(of: Theme.voice) ?? 0
        switchVoice(cases[(idx + 1) % cases.count])
    }

    func switchVoice(_ next: Theme.Voice) {
        Theme.voice = next
        editor.refreshTypography()
        updateEditorChrome()
        for win in noteWindows { win.refreshTypography() }
    }

    @objc func increaseFontSize() {
        Theme.fontScale += 1
        editor.refreshTypography()
        for win in noteWindows { win.refreshTypography() }
    }

    @objc func decreaseFontSize() {
        Theme.fontScale -= 1
        editor.refreshTypography()
        for win in noteWindows { win.refreshTypography() }
    }

    @objc func resetFontSize() {
        Theme.fontScale = 0
        editor.refreshTypography()
        for win in noteWindows { win.refreshTypography() }
    }

    @objc func cycleAtmosphere() {
        let next: Theme.Atmosphere = Theme.atmosphere == .study ? .botanical : .study
        switchAtmosphere(next)
    }

    func switchAtmosphere(_ preset: Theme.Atmosphere) {
        Theme.atmosphere = preset
        refreshThemeSurfaces()
    }

    private func refreshThemeSurfaces() {
        window?.backgroundColor = Theme.canvas
        editor.refreshTypography()
        updateEditorChrome()
        window?.contentView?.needsDisplay = true
        quickSwitcher.needsDisplay = true
        folioSurface.needsDisplay = true
        searchPanel.needsDisplay = true
        searchPanel.refresh()
        for win in noteWindows { win.refreshThemeSurfaces() }
    }

    @objc func toggleSidebar() {
        setSidebarCollapsed(!isSidebarCollapsed)
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        isSidebarCollapsed = collapsed
        sidebarContainer.isHidden = collapsed
        sidebarWidthConstraint?.constant = collapsed ? 0 : 284
        folioLeadingConstraint?.constant = collapsed ? 18 : 8
        folioTopConstraint?.constant = collapsed ? 32 : 16
        collapsedControls.isHidden = !collapsed
        window?.contentView?.layoutSubtreeIfNeeded()
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        if collapsed {
            editor.focus()
        }
    }
    @objc func showCapture() {
        editor.focus()
    }

    var isQuickSwitcherVisible: Bool {
        !quickSwitcher.isHidden
    }

    @objc func toggleQuickSwitcher() {
        if isQuickSwitcherVisible {
            dismissQuickSwitcher()
        } else {
            showQuickSwitcher()
        }
    }

    @objc func showQuickSwitcher() {
        _ = persistCurrent()
        editor.hideWikiAutocomplete()
        let (snap, dates) = searchPanel.freshSnapshotAndModifiedDates()
        quickSwitcher.present(snapshot: snap, modifiedDates: dates)
    }

    func dismissQuickSwitcher() {
        guard !quickSwitcher.isHidden else { return }
        quickSwitcher.dismiss()
    }

    @objc func showFind() {
        dismissQuickSwitcher()
        if isSidebarCollapsed { setSidebarCollapsed(false) }
        searchPanel.focusSidebar()
    }

    @objc func showInNoteFind() {
        dismissQuickSwitcher()
        editor.showInNoteFind()
    }

    @objc func findNextInNote() {
        editor.findNextInNote()
    }

    @objc func findPreviousInNote() {
        editor.findPreviousInNote()
    }

    func showAndFocus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focus()
    }

    func refresh() {
        refreshNoteIfClean()
        searchPanel.refresh()
        editor.invalidateNoteRecordsCache()
        for win in noteWindows {
            win.refreshNoteIfClean()
            win.editor.invalidateNoteRecordsCache()
        }
    }

    private func editorDidChange() {
        autosave?.invalidate()
        if let noteURL {
            let ns = editor.nsText
            if ns.length != noteBaselineUTF16Length {
                noteDirty = true
            } else {
                noteDirty = (ns as String) != noteBaseline
            }
            if editor.hasPotentialLinks || !editor.linkedAttachments.isEmpty {
                editor.linkedAttachments = vault.linkedAttachments(inNSString: ns, relativeTo: noteURL)
            }
        } else {
            noteDirty = editor.hasContent
        }
        updateEditorChrome()
        guard noteDirty, !noteConflicted else { return }
        if editor.status.stringValue != "Editing…" {
            editor.status.stringValue = "Editing…"
        }
        autosave = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.persistCurrent() }
        }
    }

    private func attachFilesToCurrentNote(_ urls: [URL]) {
        autosave?.invalidate()
        guard !noteConflicted else {
            editor.status.stringValue = "Keep conflicted edits as a new note before attaching files."
            return
        }
        do {
            if let existingURL = noteURL {
                let updated = try vault.attach(urls, to: existingURL, text: editor.text, expectedContent: noteBaseline)
                noteBaseline = updated
                noteDirty = false
                noteAvailable = true
                cachedNoteStamp = nil
                editor.text = updated
                editor.linkedAttachments = vault.linkedAttachments(in: updated, relativeTo: existingURL)
                editor.status.stringValue = "Saved"
                syncSavedNoteToCompanions(existingURL, content: updated)
            } else {
                let record = try vault.capture(text: editor.text, attachments: urls)
                let saved = try vault.read(record.url)
                noteURL = record.url
                noteBaseline = saved
                noteDirty = false
                noteConflicted = false
                noteAvailable = true
                editor.clearPendingAttachments()
                editor.text = saved
                editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: record.url)
                editor.status.stringValue = "Saved"
                searchPanel.selectNote(record.url)
            }
            updateEditorChrome()
            searchPanel.refresh()
            editor.focus()
        } catch {
            if let existingURL = noteURL, case VaultError.conflict = error {
                noteConflicted = true
                editor.status.stringValue = "Changed externally · Keep your edits as a new note."
                updateEditorChrome()
                _ = existingURL
            }
            showError(error, in: window)
        }
    }

    private func removeLinkedAttachment(_ item: LinkedAttachment) {
        guard !noteConflicted else { return }
        let current = editor.text as NSString
        guard NSMaxRange(item.markdownRange) <= current.length else { return }
        var removeRange = item.markdownRange
        if removeRange.location > 0, current.character(at: removeRange.location - 1) == 10 {
            removeRange = NSRange(location: removeRange.location - 1, length: removeRange.length + 1)
        }
        editor.text = current.replacingCharacters(in: removeRange, with: "")
        if let noteURL {
            editor.linkedAttachments = vault.linkedAttachments(in: editor.text, relativeTo: noteURL)
        }
        noteDirty = editor.text != noteBaseline
        _ = persistCurrent()
    }

    @discardableResult func persistCurrent() -> Bool {
        autosave?.invalidate()
        guard !noteConflicted else { return false }
        if let existingURL = noteURL {
            guard noteDirty else { return true }
            do {
                try vault.save(editor.text, to: existingURL, expectedContent: noteBaseline)
                noteBaseline = editor.text
                noteDirty = false
                cachedNoteStamp = nil
                editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: existingURL)
                editor.status.stringValue = "Saved"
                syncSavedNoteToCompanions(existingURL, content: noteBaseline)
                updateEditorChrome()
                searchPanel.refresh()
                return true
            } catch {
                noteConflicted = true
                editor.status.stringValue = "Changed externally · Click 'Keep as new note' to preserve your edits."
                updateEditorChrome()
                showError(error, in: window)
                return false
            }
        } else {
            guard editor.hasContent else { return true }
            let pending = editor.attachments
            do {
                let record = try vault.capture(text: editor.text, attachments: pending)
                let saved = try vault.read(record.url)
                noteURL = record.url
                noteBaseline = saved
                noteDirty = false
                noteConflicted = false
                noteAvailable = true
                editor.clearPendingAttachments()
                if !pending.isEmpty {
                    editor.text = saved
                }
                editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: record.url)
                editor.status.stringValue = "Saved"
                updateEditorChrome()
                searchPanel.selectNote(record.url)
                searchPanel.refresh()
                return true
            } catch {
                showError(error, in: window)
                return false
            }
        }
    }

    @objc func saveCurrent() {
        if noteConflicted {
            resolveConflictAsNewNote()
        } else {
            _ = persistCurrent()
            editor.focus()
        }
    }

    @objc private func resolveConflictAsNewNote() {
        do {
            let note = try vault.capture(text: editor.text, attachments: editor.attachments)
            let saved = try vault.read(note.url)
            noteURL = note.url
            noteBaseline = saved
            noteDirty = false
            noteConflicted = false
            noteAvailable = true
            editor.clearPendingAttachments()
            editor.text = saved
            editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: note.url)
            editor.status.stringValue = "Kept as a new note"
            updateEditorChrome()
            searchPanel.selectNote(note.url)
            searchPanel.refresh()
            editor.focus()
        } catch { showError(error, in: window) }
    }

    @objc func newCapture() {
        guard persistCurrent() else { return }
        noteURL = nil
        noteBaseline = ""
        noteDirty = false
        noteConflicted = false
        noteAvailable = true
        editor.reset()
        searchPanel.selectNote(nil)
        updateEditorChrome()
        editor.focus()
    }

    @objc func focusSearch() {
        showInNoteFind()
    }

    @objc func makeSearchable() {
        if isSidebarCollapsed { setSidebarCollapsed(false) }
        searchPanel.makeSearchable()
    }

    func openWikiLink(_ link: WikiLink) {
        openWikiLink(target: link.target)
    }

    func openWikiLink(target: String) {
        guard persistCurrent() else {
            searchPanel.selectNote(noteURL)
            return
        }
        do {
            let (record, created) = try vault.openOrCreateNote(matching: target)
            editor.invalidateNoteRecordsCache()
            openNote(record.url)
            if created {
                let end = editor.nsText.length
                editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                editor.status.stringValue = "Created “\(record.title)”"
                searchPanel.refresh()
            }
        } catch {
            showError(error, in: window)
        }
    }

    @discardableResult
    func openWikiLinkInNewWindow(_ link: WikiLink) -> NoteWindowController? {
        openWikiLinkInNewWindow(target: link.target)
    }

    @discardableResult
    func openWikiLinkInNewWindow(target: String) -> NoteWindowController? {
        guard persistCurrent() else {
            searchPanel.selectNote(noteURL)
            return nil
        }
        do {
            let (record, created) = try vault.openOrCreateNote(matching: target)
            editor.invalidateNoteRecordsCache()
            for win in noteWindows { win.editor.invalidateNoteRecordsCache() }
            let controller = openNoteInNewWindow(record.url)
            if created, let controller {
                let end = controller.editor.nsText.length
                controller.editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                controller.editor.status.stringValue = "Created “\(record.title)”"
                searchPanel.refresh()
            }
            return controller
        } catch {
            showError(error, in: window)
            return nil
        }
    }

    var canOpenInNewWindow: Bool {
        noteURL != nil || searchPanel.selectedNoteURL != nil || editor.hasContent
    }

    @objc func openCurrentNoteInNewWindow() {
        if noteURL == nil && editor.hasContent {
            guard persistCurrent() else { return }
        }
        guard let targetURL = noteURL ?? searchPanel.selectedNoteURL else { return }
        _ = openNoteInNewWindow(targetURL)
    }

    @discardableResult
    func openNoteInNewWindow(_ url: URL) -> NoteWindowController? {
        if noteURL == url {
            guard persistCurrent() else { return nil }
        }
        if let existing = noteWindows.first(where: { $0.noteURL == url }) {
            _ = existing.persistCurrent()
            existing.showAndFocus()
            return existing
        }
        let controller = NoteWindowController(vault: vault, appearance: window?.appearance)
        if let anchor = (noteWindows.last?.window ?? window), let win = controller.window {
            let anchorFrame = anchor.frame
            let nextOrigin = NSPoint(x: anchorFrame.minX + 36, y: anchorFrame.maxY - win.frame.height - 28)
            win.setFrameOrigin(nextOrigin)
        }
        controller.onDidSaveNote = { [weak self, weak controller] savedURL, content in
            self?.handleCompanionNoteSaved(savedURL, content: content, from: controller)
        }
        controller.onOpenInMainWorkspace = { [weak self] targetURL in
            self?.openNote(targetURL)
            self?.showAndFocus()
        }
        controller.onOpenWikiLinkInNewWindow = { [weak self] link in
            _ = self?.openWikiLinkInNewWindow(link)
        }
        controller.onQuickSwitcher = { [weak self] in
            self?.showAndFocus()
            self?.showQuickSwitcher()
        }
        controller.onRequestDeleteNote = { [weak self] targetURL, hostWindow in
            self?.confirmAndDeleteNote(targetURL, in: hostWindow)
        }
        controller.onWillClose = { [weak self] closed in
            self?.noteWindows.removeAll { $0 === closed }
        }
        noteWindows.append(controller)
        controller.openNote(url)
        controller.showAndFocus()
        return controller
    }

    private func syncSavedNoteToCompanions(_ url: URL, content: String) {
        for win in noteWindows where win.noteURL == url {
            win.applyExternalSave(url: url, content: content)
        }
    }

    private func handleCompanionNoteSaved(_ url: URL, content: String, from sender: NoteWindowController?) {
        if noteURL == url && !noteDirty && !noteConflicted && content != noteBaseline {
            noteBaseline = content
            cachedNoteStamp = nil
            editor.text = content
            editor.linkedAttachments = vault.linkedAttachments(in: content, relativeTo: url)
            updateEditorChrome()
        }
        for win in noteWindows where win !== sender && win.noteURL == url {
            win.applyExternalSave(url: url, content: content)
        }
        editor.invalidateNoteRecordsCache()
        for win in noteWindows { win.editor.invalidateNoteRecordsCache() }
        searchPanel.refresh()
    }

    @discardableResult
    func persistAllWindows() -> Bool {
        guard persistCurrent() else { return false }
        for win in noteWindows {
            guard win.persistCurrent() else { return false }
        }
        return true
    }

    func openNote(_ url: URL) {
        if noteURL == url && !noteConflicted {
            editor.focus()
            return
        }
        guard persistCurrent() else {
            searchPanel.selectNote(noteURL)
            return
        }
        do {
            let text = try vault.read(url)
            noteURL = url
            noteBaseline = text
            noteDirty = false
            noteConflicted = false
            noteAvailable = true
            cachedNoteStamp = nil
            editor.clearPendingAttachments()
            editor.text = text
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: url)
            editor.status.stringValue = ""
            searchPanel.selectNote(url)
            updateEditorChrome()
            editor.focus()
        } catch { showError(error, in: window) }
    }

    private func refreshNoteIfClean() {
        guard let noteURL, !noteDirty, !noteConflicted else { return }
        do {
            let text = try vault.read(noteURL)
            if text != noteBaseline {
                noteBaseline = text
                editor.text = text
                editor.linkedAttachments = vault.linkedAttachments(in: text, relativeTo: noteURL)
            }
            if !noteAvailable { editor.status.stringValue = "" }
            noteAvailable = true
        } catch {
            noteAvailable = false
            editor.status.stringValue = "Original unavailable · Last view preserved"
        }
        updateEditorChrome()
    }

    private func updateEditorChrome() {
        if conflictSaveButton.isHidden == noteConflicted { conflictSaveButton.isHidden = !noteConflicted }
        let hideNoteActions = noteURL == nil
        if openInNewWindowButton.isHidden != hideNoteActions { openInNewWindowButton.isHidden = hideNoteActions }
        if revealButton.isHidden != hideNoteActions { revealButton.isHidden = hideNoteActions }
        if deleteButton.isHidden != hideNoteActions { deleteButton.isHidden = hideNoteActions }
        let voiceBadge = Theme.voice.shortBadge
        if voiceButton.title != voiceBadge { voiceButton.title = voiceBadge }
        let atmoBadge = Theme.atmosphere.shortBadge
        if atmosphereButton.title != atmoBadge { atmosphereButton.title = atmoBadge }
        if let noteURL {
            let stamp: String
            if let cached = cachedNoteStamp {
                stamp = cached
            } else {
                let modified = (try? noteURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let formatted = Self.headerDateFormatter.string(from: modified).uppercased()
                cachedNoteStamp = formatted
                stamp = formatted
                contextLabel.toolTip = String(noteURL.path.dropFirst(vault.root.path.count + 1))
            }
            let nextContext = noteDirty ? "\(stamp)  ·  UNSAVED" : stamp
            if contextLabel.stringValue != nextContext { contextLabel.stringValue = nextContext }
        } else {
            let stamp = Self.headerDateFormatter.string(from: Date()).uppercased()
            let nextContext = "NEW FOLIO  ·  \(stamp)"
            if contextLabel.stringValue != nextContext { contextLabel.stringValue = nextContext }
            contextLabel.toolTip = vault.root.path
        }
    }

    @objc private func revealCurrentNote() {
        guard let noteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([noteURL])
    }

    var canDeleteNote: Bool {
        noteURL != nil || searchPanel.selectedNoteURL != nil
    }

    @objc func deleteCurrentNote() {
        guard let targetURL = noteURL ?? searchPanel.selectedNoteURL else { return }
        confirmAndDeleteNote(targetURL)
    }

    func confirmAndDeleteNote(_ url: URL, in hostWindow: NSWindow? = nil) {
        let alertHost = hostWindow ?? window
        guard !searchPanel.isExtracting else {
            showError(NSError(domain: "CozyNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wait for extraction to finish or cancel it before deleting notes."
            ]), in: alertHost)
            return
        }
        let title = (try? vault.notes().first(where: { $0.url == url })?.title)
            ?? url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "This note and its attachments will be moved to the Trash. A recovery checkpoint is saved first so you can also restore it from Recovery."
        let trashBtn = alert.addButton(withTitle: "Move to Trash")
        trashBtn.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let alertHost else {
            _ = performDeleteNote(url)
            return
        }
        alert.beginSheetModal(for: alertHost) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            _ = self.performDeleteNote(url)
        }
    }

    @discardableResult
    func performDeleteNote(_ url: URL, moveToTrash: Bool = true) -> Bool {
        guard !searchPanel.isExtracting else { return false }
        let deletingActiveNote = (noteURL == url)
        if deletingActiveNote {
            autosave?.invalidate()
        }
        do {
            _ = try vault.delete(url, moveToTrash: moveToTrash)
            if deletingActiveNote {
                noteURL = nil
                noteBaseline = ""
                noteDirty = false
                noteConflicted = false
                noteAvailable = true
                editor.reset()
                editor.status.stringValue = "Moved to Trash"
                searchPanel.selectNote(nil)
                updateEditorChrome()
                editor.focus()
            }
            let matchingCompanions = noteWindows.filter { $0.noteURL == url }
            for win in matchingCompanions {
                win.closeAfterDeletion()
                noteWindows.removeAll { $0 === win }
            }
            for win in noteWindows {
                win.editor.invalidateNoteRecordsCache()
            }
            editor.invalidateNoteRecordsCache()
            searchPanel.refresh()
            return true
        } catch {
            showError(error, in: window)
            return false
        }
    }
    @objc private func revealFolder() { NSWorkspace.shared.open(vault.root) }
    @objc private func chooseFolder() { onChooseFolder?() }

    @objc func showRecovery() {
        guard persistAllWindows() else { return }
        guard !searchPanel.isExtracting else {
            showError(NSError(domain: "CozyNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wait for extraction to finish or cancel it before recovering files."
            ]), in: window)
            return
        }
        do {
            let snapshots = try vault.snapshots()
            let alert = NSAlert()
            alert.messageText = "Recover an earlier version"
            alert.informativeText = "Restore saved files from a checkpoint. New files and any uncommitted draft are kept. A fresh checkpoint is made before recovery."
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for snapshot in snapshots { picker.addItem(withTitle: "\(formatter.string(from: snapshot.createdAt)) — \(snapshot.label)") }
            alert.accessoryView = picker
            alert.addButton(withTitle: snapshots.isEmpty ? "No checkpoints yet" : "Restore checkpoint")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Create checkpoint")
            alert.buttons.first?.isEnabled = !snapshots.isEmpty
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn || response == .alertThirdButtonReturn else { return }
                do {
                    guard !self.searchPanel.isExtracting else {
                        throw NSError(domain: "CozyNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wait for extraction to finish before recovering files."])
                    }
                    if response == .alertThirdButtonReturn {
                        _ = try self.vault.snapshot(label: "Manual checkpoint")
                        return
                    }
                    guard snapshots.indices.contains(picker.indexOfSelectedItem) else { return }
                    try self.vault.restore(snapshotID: snapshots[picker.indexOfSelectedItem].id)
                    if let activeURL = self.noteURL, let reloaded = try? self.vault.read(activeURL) {
                        self.noteBaseline = reloaded
                        self.noteDirty = false
                        self.noteConflicted = false
                        self.noteAvailable = true
                        self.editor.text = reloaded
                        self.editor.linkedAttachments = self.vault.linkedAttachments(in: reloaded, relativeTo: activeURL)
                    }
                    self.updateEditorChrome()
                    for win in self.noteWindows {
                        win.reloadAfterVaultRestore()
                    }
                    self.searchPanel.refresh()
                    self.editor.focus()
                } catch { showError(error, in: self.window) }
            }
        } catch { showError(error, in: window) }
    }

    func shutdown() {
        autosave?.invalidate()
        for win in noteWindows {
            win.shutdown()
            win.window?.orderOut(nil)
        }
        noteWindows.removeAll()
        searchPanel.shutdown()
    }
    func windowDidResignKey(_ notification: Notification) {
        _ = persistCurrent()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard persistCurrent() else { return false }
        sender.orderOut(nil)
        return false
    }
}

@MainActor final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let vault: Vault
    let editor = CaptureEditor(frame: .zero)
    private let folioSurface = FolioPageSurface()
    private let sealDot = PaperSurface(cornerRadius: 3.5, color: Theme.sage, bordered: false)
    private let contextLabel = Theme.label("", size: 10.5, color: Theme.muted)
    let focusInWorkspaceButton = QuietButton(symbol: "sidebar.left", target: nil, action: nil)
    let revealButton = QuietButton(symbol: "doc.viewfinder", target: nil, action: nil)
    let deleteButton = QuietButton(symbol: "trash", target: nil, action: nil)
    private let conflictSaveButton = PrimaryButton()
    private let headerRule = HairlineView()
    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var ruleLeadingConstraint: NSLayoutConstraint?
    private var ruleTrailingConstraint: NSLayoutConstraint?

    private(set) var noteURL: URL? {
        didSet {
            if noteURL != oldValue { cachedNoteStamp = nil }
        }
    }
    private var noteBaseline = "" {
        didSet {
            noteBaselineUTF16Length = (noteBaseline as NSString).length
        }
    }
    private var noteBaselineUTF16Length = 0
    private var cachedNoteStamp: String?
    private(set) var noteDirty = false
    private(set) var noteConflicted = false
    private var noteAvailable = true
    private var autosave: Timer?
    private var isClosingAfterDeletion = false

    var onDidSaveNote: ((URL, String) -> Void)?
    var onOpenInMainWorkspace: ((URL) -> Void)?
    var onOpenWikiLinkInNewWindow: ((WikiLink) -> Void)?
    var onQuickSwitcher: (() -> Void)?
    var onRequestDeleteNote: ((URL, NSWindow?) -> Void)?
    var onWillClose: ((NoteWindowController) -> Void)?

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, MMM d, yyyy · HH:mm")
        return f
    }()

    init(vault: Vault, appearance: NSAppearance? = nil) {
        self.vault = vault
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cozy Notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 520, height: 420)
        window.backgroundColor = Theme.canvas
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireCallbacks()
        updateEditorChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        let desk = PaperSurface(cornerRadius: 0, color: Theme.canvas, bordered: false)
        window?.contentView = desk

        sealDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        sealDot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        contextLabel.font = Theme.monoFont(10.5, weight: .medium)
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        focusInWorkspaceButton.target = self
        focusInWorkspaceButton.action = #selector(openInMainWorkspaceTapped)
        focusInWorkspaceButton.toolTip = "Focus this note in main workspace"
        focusInWorkspaceButton.setAccessibilityLabel("Focus note in main workspace")

        revealButton.target = self
        revealButton.action = #selector(revealCurrentNote)
        revealButton.toolTip = "Reveal this note in Finder"
        revealButton.setAccessibilityLabel("Reveal note in Finder")

        deleteButton.target = self
        deleteButton.action = #selector(deleteCurrentNote)
        deleteButton.toolTip = "Delete this note (⌘⌫)"
        deleteButton.setAccessibilityLabel("Delete note")

        conflictSaveButton.title = "Keep as new note"
        conflictSaveButton.target = self
        conflictSaveButton.action = #selector(resolveConflictAsNewNote)
        conflictSaveButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let editorHeader = Theme.stack([sealDot, contextLabel, spacer, conflictSaveButton, focusInWorkspaceButton, revealButton, deleteButton], spacing: 6)

        for view in [editorHeader, headerRule, editor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            folioSurface.addSubview(view)
        }
        let headerLead = editorHeader.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let headerTrail = editorHeader.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let ruleLead = headerRule.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let ruleTrail = headerRule.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        headerLeadingConstraint = headerLead
        headerTrailingConstraint = headerTrail
        ruleLeadingConstraint = ruleLead
        ruleTrailingConstraint = ruleTrail

        folioSurface.translatesAutoresizingMaskIntoConstraints = false
        desk.addSubview(folioSurface)

        NSLayoutConstraint.activate([
            headerLead,
            headerTrail,
            editorHeader.topAnchor.constraint(equalTo: folioSurface.topAnchor, constant: 14),
            editorHeader.heightAnchor.constraint(equalToConstant: 30),
            ruleLead,
            ruleTrail,
            headerRule.topAnchor.constraint(equalTo: editorHeader.bottomAnchor, constant: 8),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            editor.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 2),
            editor.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -4),
            editor.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: folioSurface.bottomAnchor, constant: -2),
            folioSurface.leadingAnchor.constraint(equalTo: desk.leadingAnchor, constant: 18),
            folioSurface.trailingAnchor.constraint(equalTo: desk.trailingAnchor, constant: -18),
            folioSurface.topAnchor.constraint(equalTo: desk.topAnchor, constant: 32),
            folioSurface.bottomAnchor.constraint(equalTo: desk.bottomAnchor, constant: -18)
        ])
    }

    private func wireCallbacks() {
        editor.onChange = { [weak self] in self?.editorDidChange() }
        editor.onAttachFiles = { [weak self] urls in self?.attachFilesToCurrentNote(urls) }
        editor.onRemoveLinkedAttachment = { [weak self] item in self?.removeLinkedAttachment(item) }
        editor.onHorizontalInsetChange = { [weak self] inset in self?.syncFolioMargins(inset) }
        editor.noteRecordsProvider = { [weak self] in (try? self?.vault.notes()) ?? [] }
        editor.currentNoteURLProvider = { [weak self] in self?.noteURL }
        editor.onOpenWikiLink = { [weak self] link in self?.openWikiLink(link) }
        editor.onOpenWikiLinkInNewWindow = { [weak self] link in self?.onOpenWikiLinkInNewWindow?(link) }
        editor.onQuickSwitcher = { [weak self] in self?.onQuickSwitcher?() }
    }

    private func syncFolioMargins(_ inset: CGFloat) {
        folioSurface.marginX = max(24, inset - 22)
        let lead = inset
        if headerLeadingConstraint?.constant != lead {
            headerLeadingConstraint?.constant = lead
            headerTrailingConstraint?.constant = -inset
            ruleLeadingConstraint?.constant = inset
            ruleTrailingConstraint?.constant = -inset
        }
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focus()
    }

    func openNote(_ url: URL) {
        if noteURL == url && !noteConflicted {
            editor.focus()
            return
        }
        guard persistCurrent() else { return }
        do {
            let text = try vault.read(url)
            noteURL = url
            noteBaseline = text
            noteDirty = false
            noteConflicted = false
            noteAvailable = true
            cachedNoteStamp = nil
            editor.clearPendingAttachments()
            editor.text = text
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: url)
            editor.status.stringValue = ""
            updateEditorChrome()
            editor.focus()
        } catch {
            showError(error, in: window)
        }
    }

    func openWikiLink(_ link: WikiLink) {
        openWikiLink(target: link.target)
    }

    func openWikiLink(target: String) {
        guard persistCurrent() else { return }
        do {
            let (record, created) = try vault.openOrCreateNote(matching: target)
            editor.invalidateNoteRecordsCache()
            openNote(record.url)
            if created {
                let end = editor.nsText.length
                editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                editor.status.stringValue = "Created “\(record.title)”"
                onDidSaveNote?(record.url, editor.text)
            }
        } catch {
            showError(error, in: window)
        }
    }

    private func editorDidChange() {
        autosave?.invalidate()
        if let noteURL {
            let ns = editor.nsText
            if ns.length != noteBaselineUTF16Length {
                noteDirty = true
            } else {
                noteDirty = (ns as String) != noteBaseline
            }
            if editor.hasPotentialLinks || !editor.linkedAttachments.isEmpty {
                editor.linkedAttachments = vault.linkedAttachments(inNSString: ns, relativeTo: noteURL)
            }
        } else {
            noteDirty = editor.hasContent
        }
        updateEditorChrome()
        guard noteDirty, !noteConflicted else { return }
        if editor.status.stringValue != "Editing…" {
            editor.status.stringValue = "Editing…"
        }
        autosave = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.persistCurrent() }
        }
    }

    @discardableResult
    func persistCurrent() -> Bool {
        autosave?.invalidate()
        guard !noteConflicted else { return false }
        guard let existingURL = noteURL else { return true }
        guard noteDirty else { return true }
        do {
            try vault.save(editor.text, to: existingURL, expectedContent: noteBaseline)
            noteBaseline = editor.text
            noteDirty = false
            cachedNoteStamp = nil
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: existingURL)
            editor.status.stringValue = "Saved"
            updateEditorChrome()
            onDidSaveNote?(existingURL, noteBaseline)
            return true
        } catch {
            noteConflicted = true
            editor.status.stringValue = "Changed externally · Click 'Keep as new note' to preserve your edits."
            updateEditorChrome()
            showError(error, in: window)
            return false
        }
    }

    @objc func saveCurrent() {
        if noteConflicted {
            resolveConflictAsNewNote()
        } else {
            _ = persistCurrent()
            editor.focus()
        }
    }

    @objc private func resolveConflictAsNewNote() {
        do {
            let note = try vault.capture(text: editor.text, attachments: editor.attachments)
            let saved = try vault.read(note.url)
            noteURL = note.url
            noteBaseline = saved
            noteDirty = false
            noteConflicted = false
            noteAvailable = true
            editor.clearPendingAttachments()
            editor.text = saved
            editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: note.url)
            editor.status.stringValue = "Kept as a new note"
            updateEditorChrome()
            onDidSaveNote?(note.url, saved)
            editor.focus()
        } catch {
            showError(error, in: window)
        }
    }

    private func attachFilesToCurrentNote(_ urls: [URL]) {
        autosave?.invalidate()
        guard !noteConflicted, let existingURL = noteURL else {
            editor.status.stringValue = "Keep conflicted edits as a new note before attaching files."
            return
        }
        do {
            let updated = try vault.attach(urls, to: existingURL, text: editor.text, expectedContent: noteBaseline)
            noteBaseline = updated
            noteDirty = false
            noteAvailable = true
            cachedNoteStamp = nil
            editor.text = updated
            editor.linkedAttachments = vault.linkedAttachments(in: updated, relativeTo: existingURL)
            editor.status.stringValue = "Saved"
            updateEditorChrome()
            onDidSaveNote?(existingURL, updated)
            editor.focus()
        } catch {
            if case VaultError.conflict = error {
                noteConflicted = true
                editor.status.stringValue = "Changed externally · Keep your edits as a new note."
                updateEditorChrome()
            }
            showError(error, in: window)
        }
    }

    private func removeLinkedAttachment(_ item: LinkedAttachment) {
        guard !noteConflicted else { return }
        let current = editor.text as NSString
        guard NSMaxRange(item.markdownRange) <= current.length else { return }
        var removeRange = item.markdownRange
        if removeRange.location > 0, current.character(at: removeRange.location - 1) == 10 {
            removeRange = NSRange(location: removeRange.location - 1, length: removeRange.length + 1)
        }
        editor.text = current.replacingCharacters(in: removeRange, with: "")
        if let noteURL {
            editor.linkedAttachments = vault.linkedAttachments(in: editor.text, relativeTo: noteURL)
        }
        noteDirty = editor.text != noteBaseline
        _ = persistCurrent()
    }

    func applyExternalSave(url: URL, content: String) {
        guard noteURL == url, !noteDirty, !noteConflicted, content != noteBaseline else { return }
        noteBaseline = content
        cachedNoteStamp = nil
        noteAvailable = true
        editor.text = content
        editor.linkedAttachments = vault.linkedAttachments(in: content, relativeTo: url)
        updateEditorChrome()
    }

    func refreshNoteIfClean() {
        guard let noteURL, !noteDirty, !noteConflicted else { return }
        do {
            let text = try vault.read(noteURL)
            if text != noteBaseline {
                noteBaseline = text
                cachedNoteStamp = nil
                editor.text = text
                editor.linkedAttachments = vault.linkedAttachments(in: text, relativeTo: noteURL)
            }
            if !noteAvailable { editor.status.stringValue = "" }
            noteAvailable = true
        } catch {
            noteAvailable = false
            editor.status.stringValue = "Original unavailable · Last view preserved"
        }
        updateEditorChrome()
    }

    func reloadAfterVaultRestore() {
        guard let activeURL = noteURL, let reloaded = try? vault.read(activeURL) else { return }
        noteBaseline = reloaded
        noteDirty = false
        noteConflicted = false
        noteAvailable = true
        cachedNoteStamp = nil
        editor.text = reloaded
        editor.linkedAttachments = vault.linkedAttachments(in: reloaded, relativeTo: activeURL)
        updateEditorChrome()
    }

    func refreshTypography() {
        editor.refreshTypography()
        updateEditorChrome()
    }

    func refreshThemeSurfaces() {
        window?.backgroundColor = Theme.canvas
        editor.refreshTypography()
        updateEditorChrome()
        window?.contentView?.needsDisplay = true
        folioSurface.needsDisplay = true
    }

    private func updateEditorChrome() {
        if conflictSaveButton.isHidden == noteConflicted { conflictSaveButton.isHidden = !noteConflicted }
        let hideNoteActions = noteURL == nil
        if focusInWorkspaceButton.isHidden != hideNoteActions { focusInWorkspaceButton.isHidden = hideNoteActions }
        if revealButton.isHidden != hideNoteActions { revealButton.isHidden = hideNoteActions }
        if deleteButton.isHidden != hideNoteActions { deleteButton.isHidden = hideNoteActions }
        if let noteURL {
            let stamp: String
            if let cached = cachedNoteStamp {
                stamp = cached
            } else {
                let modified = (try? noteURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let formatted = Self.headerDateFormatter.string(from: modified).uppercased()
                cachedNoteStamp = formatted
                stamp = formatted
                contextLabel.toolTip = String(noteURL.path.dropFirst(vault.root.path.count + 1))
            }
            let nextContext = noteDirty ? "\(stamp)  ·  UNSAVED" : stamp
            if contextLabel.stringValue != nextContext { contextLabel.stringValue = nextContext }
            window?.representedURL = noteURL
            let title = (try? vault.notes().first(where: { $0.url == noteURL })?.title)
                ?? noteURL.deletingPathExtension().lastPathComponent
            window?.title = title
        } else {
            contextLabel.stringValue = "COMPARISON FOLIO"
            window?.representedURL = vault.root
            window?.title = "Cozy Notes"
        }
    }

    @objc private func openInMainWorkspaceTapped() {
        guard let noteURL, persistCurrent() else { return }
        onOpenInMainWorkspace?(noteURL)
    }

    @objc private func revealCurrentNote() {
        guard let noteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([noteURL])
    }

    @objc func deleteCurrentNote() {
        guard let noteURL else { return }
        onRequestDeleteNote?(noteURL, window)
    }

    @objc func showInNoteFind() {
        editor.showInNoteFind()
    }

    @objc func findNextInNote() {
        editor.findNextInNote()
    }

    @objc func findPreviousInNote() {
        editor.findPreviousInNote()
    }

    func closeAfterDeletion() {
        isClosingAfterDeletion = true
        autosave?.invalidate()
        window?.close()
    }

    func shutdown() {
        isClosingAfterDeletion = true
        autosave?.invalidate()
    }

    func windowDidResignKey(_ notification: Notification) {
        _ = persistCurrent()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingAfterDeletion { return true }
        return persistCurrent()
    }

    func windowWillClose(_ notification: Notification) {
        autosave?.invalidate()
        onWillClose?(self)
    }
}
