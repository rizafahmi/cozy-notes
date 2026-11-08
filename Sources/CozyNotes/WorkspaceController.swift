import AppKit
import CozyCore

@MainActor final class WorkspaceController: NSWindowController, NSWindowDelegate {
    let vault: Vault
    let editor = CaptureEditor(frame: .zero)
    private let searchPanel: SearchPanel
    private let sidebarContainer = NSView()
    private let folioSurface = FolioPageSurface()
    private let collapsedControls = NSStackView()
    private let sealDot = PaperSurface(cornerRadius: 3.5, color: Theme.sage, bordered: false)
    private let contextLabel = Theme.label("", size: 10.5, color: Theme.muted)
    private let voiceButton = QuietButton(title: "AVENIR", symbol: "textformat", target: nil, action: nil)
    private let atmosphereButton = QuietButton(title: "OBSIDIAN", symbol: "sparkles", target: nil, action: nil)
    private let revealButton = QuietButton(symbol: "doc.viewfinder", target: nil, action: nil)
    private let conflictSaveButton = PrimaryButton()
    private let headerRule = HairlineView()
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var folioLeadingConstraint: NSLayoutConstraint?
    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var ruleLeadingConstraint: NSLayoutConstraint?
    private var ruleTrailingConstraint: NSLayoutConstraint?

    private(set) var isSidebarCollapsed = false
    private(set) var noteURL: URL?
    private var noteBaseline = ""
    private var noteDirty = false
    private var noteConflicted = false
    private var noteAvailable = true
    private var autosave: Timer?
    private var watcher: VaultWatcher?
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
        revealButton.target = self
        revealButton.action = #selector(revealCurrentNote)
        revealButton.toolTip = "Reveal this note in Finder"
        revealButton.setAccessibilityLabel("Reveal note in Finder")

        conflictSaveButton.title = "Keep as new note"
        conflictSaveButton.target = self
        conflictSaveButton.action = #selector(resolveConflictAsNewNote)
        conflictSaveButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let editorHeader = Theme.stack([collapsedControls, sealDot, contextLabel, spacer, conflictSaveButton, voiceButton, atmosphereButton, revealButton], spacing: 6)

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
            editorHeader.topAnchor.constraint(equalTo: folioSurface.topAnchor, constant: 12),
            editorHeader.heightAnchor.constraint(equalToConstant: 28),
            ruleLead,
            ruleTrail,
            headerRule.topAnchor.constraint(equalTo: editorHeader.bottomAnchor, constant: 4),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            editor.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 2),
            editor.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -4),
            editor.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: folioSurface.bottomAnchor, constant: -2)
        ])

        for view in [sidebarContainer, folioSurface] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let widthConstraint = sidebarContainer.widthAnchor.constraint(equalToConstant: 284)
        let folioLead = folioSurface.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: 2)
        sidebarWidthConstraint = widthConstraint
        folioLeadingConstraint = folioLead

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            widthConstraint,
            folioLead,
            folioSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            folioSurface.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            folioSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
    }

    private func wireCallbacks() {
        editor.onChange = { [weak self] in self?.editorDidChange() }
        editor.onAttachFiles = { [weak self] urls in self?.attachFilesToCurrentNote(urls) }
        editor.onRemoveLinkedAttachment = { [weak self] item in self?.removeLinkedAttachment(item) }
        editor.onHorizontalInsetChange = { [weak self] inset in self?.syncFolioMargins(inset) }
        searchPanel.onOpenNote = { [weak self] url in self?.openNote(url) }
        searchPanel.onNewNote = { [weak self] in self?.newCapture() }
        searchPanel.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        searchPanel.onToggleAppearance = { [weak self] in self?.toggleAppearance() }
        searchPanel.onSwitchAtmosphere = { [weak self] preset in self?.switchAtmosphere(preset) }
        searchPanel.onRevealFolder = { [weak self] in self?.revealFolder() }
        searchPanel.onChooseFolder = { [weak self] in self?.chooseFolder() }
        searchPanel.onShowRecovery = { [weak self] in self?.showRecovery() }
    }

    private func syncFolioMargins(_ inset: CGFloat) {
        folioSurface.marginX = max(24, inset - 22)
        let lead = isSidebarCollapsed ? max(78, inset) : inset
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
    }

    @objc func increaseFontSize() {
        Theme.fontScale += 1
        editor.refreshTypography()
    }

    @objc func decreaseFontSize() {
        Theme.fontScale -= 1
        editor.refreshTypography()
    }

    @objc func resetFontSize() {
        Theme.fontScale = 0
        editor.refreshTypography()
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
        folioSurface.needsDisplay = true
        searchPanel.needsDisplay = true
        searchPanel.refresh()
    }

    @objc func toggleSidebar() {
        setSidebarCollapsed(!isSidebarCollapsed)
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        isSidebarCollapsed = collapsed
        sidebarContainer.isHidden = collapsed
        sidebarWidthConstraint?.constant = collapsed ? 0 : 284
        folioLeadingConstraint?.constant = collapsed ? 10 : 2
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

    @objc func showFind() {
        if isSidebarCollapsed { setSidebarCollapsed(false) }
        searchPanel.focusSearch()
    }

    func showAndFocus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focus()
    }

    func refresh() {
        refreshNoteIfClean()
        searchPanel.refresh()
    }

    private func editorDidChange() {
        autosave?.invalidate()
        if let noteURL {
            noteDirty = editor.text != noteBaseline
            editor.linkedAttachments = vault.linkedAttachments(in: editor.text, relativeTo: noteURL)
        } else {
            noteDirty = editor.hasContent
        }
        updateEditorChrome()
        guard noteDirty, !noteConflicted else { return }
        editor.status.stringValue = "Editing…"
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
                editor.text = updated
                editor.linkedAttachments = vault.linkedAttachments(in: updated, relativeTo: existingURL)
                editor.status.stringValue = "Saved"
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
                editor.linkedAttachments = vault.linkedAttachments(in: editor.text, relativeTo: existingURL)
                editor.status.stringValue = "Saved"
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
        showFind()
    }

    @objc func makeSearchable() {
        if isSidebarCollapsed { setSidebarCollapsed(false) }
        searchPanel.makeSearchable()
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
            editor.clearPendingAttachments()
            editor.text = text
            editor.linkedAttachments = vault.linkedAttachments(in: text, relativeTo: url)
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
        conflictSaveButton.isHidden = !noteConflicted
        revealButton.isHidden = noteURL == nil
        voiceButton.title = Theme.voice.shortBadge
        atmosphereButton.title = Theme.atmosphere.shortBadge
        if let noteURL {
            let modified = (try? noteURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let stamp = Self.headerDateFormatter.string(from: modified).uppercased()
            contextLabel.stringValue = noteDirty ? "\(stamp)  ·  UNSAVED" : stamp
            contextLabel.toolTip = String(noteURL.path.dropFirst(vault.root.path.count + 1))
        } else {
            let stamp = Self.headerDateFormatter.string(from: Date()).uppercased()
            contextLabel.stringValue = "NEW FOLIO  ·  \(stamp)"
            contextLabel.toolTip = vault.root.path
        }
    }

    @objc private func revealCurrentNote() {
        guard let noteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([noteURL])
    }
    @objc private func revealFolder() { NSWorkspace.shared.open(vault.root) }
    @objc private func chooseFolder() { onChooseFolder?() }

    @objc func showRecovery() {
        if noteURL != nil {
            guard persistCurrent() else { return }
        }
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
                    self.searchPanel.refresh()
                    self.editor.focus()
                } catch { showError(error, in: self.window) }
            }
        } catch { showError(error, in: window) }
    }

    func shutdown() { autosave?.invalidate(); searchPanel.shutdown() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard persistCurrent() else { return false }
        sender.orderOut(nil)
        return false
    }
}
