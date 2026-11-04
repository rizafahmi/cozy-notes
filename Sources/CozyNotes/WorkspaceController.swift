import AppKit
import CozyCore

@MainActor final class WorkspaceController: NSWindowController, NSWindowDelegate {
    enum Mode { case capture, find }

    let vault: Vault
    let editor = CaptureEditor(frame: .zero)
    private(set) var mode: Mode = .capture
    private let modeSwitch = NSSegmentedControl(labels: ["Capture", "Find"], trackingMode: .selectOne, target: nil, action: nil)
    private let captureView = NSView()
    private let findView = NSView()
    private let detailView = NSView()
    private let saveButton = PrimaryButton()
    private let captureContext = Theme.label("", size: 11)
    private let searchPanel: SearchPanel
    private let noteEditor = CaptureEditor(frame: .zero)
    private let noteHeading = Theme.label("", size: 21, color: Theme.ink)
    private let editButton = NSButton()
    private let noteSaveButton = PrimaryButton()
    private var findShowsNote = false
    private var findNeedsRefresh = true
    private var noteURL: URL?
    private var noteBaseline = ""
    private var noteDirty = false
    private var noteConflicted = false
    private var noteAvailable = true
    private var noteEditing = false
    private var autosave: Timer?
    private var watcher: VaultWatcher?
    var onChooseFolder: (() -> Void)?

    init(vault: Vault) {
        self.vault = vault
        self.searchPanel = SearchPanel(vault: vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Cozy Notes"
        window.representedURL = vault.root
        window.minSize = NSSize(width: 760, height: 540)
        window.backgroundColor = Theme.canvas
        window.titlebarAppearsTransparent = true
        window.appearance = nil
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        editor.onChange = { [weak self] in self?.updateCaptureButton() }
        noteEditor.onChange = { [weak self] in self?.noteChanged() }
        searchPanel.onOpenNote = { [weak self] url in self?.openNote(url) }
        watcher = VaultWatcher(root: vault.root) { [weak self] in self?.refresh() }
        presentMode(focus: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let emblem = PaperSurface(cornerRadius: 10, color: Theme.accentSoft, bordered: false)
        let notebook = Theme.symbol("book.closed.fill", size: 17, color: Theme.accent)
        Theme.fill(notebook, in: emblem, inset: 8)
        emblem.widthAnchor.constraint(equalToConstant: 34).isActive = true
        emblem.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let brand = Theme.label("Cozy Notes", size: 15, color: Theme.ink)
        brand.font = .systemFont(ofSize: 15, weight: .semibold)
        let identity = Theme.label("Your local notebook", size: 11)
        let name = Theme.stack([brand, identity], orientation: .vertical, spacing: 2)
        let signature = Theme.stack([emblem, name], spacing: 10)
        signature.toolTip = vault.root.path
        modeSwitch.target = self
        modeSwitch.action = #selector(changeMode(_:))
        modeSwitch.selectedSegment = 0
        modeSwitch.segmentStyle = .rounded
        modeSwitch.controlSize = .large
        modeSwitch.setWidth(112, forSegment: 0)
        modeSwitch.setWidth(112, forSegment: 1)
        modeSwitch.setImage(NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil), forSegment: 0)
        modeSwitch.setImage(NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil), forSegment: 1)
        modeSwitch.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        modeSwitch.setImageScaling(.scaleProportionallyDown, forSegment: 1)
        modeSwitch.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        modeSwitch.setAccessibilityLabel("Workspace mode")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = Theme.stack([signature, spacer, modeSwitch])
        header.edgeInsets = NSEdgeInsets(top: 10, left: 26, bottom: 12, right: 26)
        let body = NSView()
        Theme.fill(captureView, in: body)
        Theme.fill(findView, in: body)
        let layout = Theme.stack([header, body], orientation: .vertical, spacing: 0)
        Theme.fill(layout, in: content)
        header.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        buildCapture()
        buildFind()
    }

    private func buildCapture() {
        captureContext.font = .systemFont(ofSize: 11, weight: .medium)
        let title = Theme.label("Leave it here.", size: 35, color: Theme.ink)
        title.font = Theme.displayFont(35)
        let subtitle = Theme.label("Write a thought, paste a link, or drop in a file. Keep it without sorting it.", size: 13)
        let intro = Theme.stack([captureContext, title, subtitle], orientation: .vertical, spacing: 5)
        saveButton.title = "Keep capture"
        saveButton.target = self
        saveButton.action = #selector(saveCapture)
        saveButton.toolTip = "Save this capture (⌘Return)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let shortcut = Theme.label("⌘ Return", size: 11)
        shortcut.setAccessibilityLabel("Command Return to keep capture")
        let actions = Theme.stack([spacer, shortcut, saveButton], spacing: 12)
        actions.edgeInsets = NSEdgeInsets(top: 4, left: 22, bottom: 14, right: 22)
        let sheet = PaperSurface()
        let sheetContents = Theme.stack([editor, actions], orientation: .vertical, spacing: 0)
        Theme.fill(sheetContents, in: sheet)
        editor.widthAnchor.constraint(equalTo: sheetContents.widthAnchor).isActive = true
        actions.widthAnchor.constraint(equalTo: sheetContents.widthAnchor).isActive = true
        editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let column = Theme.stack([intro, sheet], orientation: .vertical, spacing: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        captureView.addSubview(column)
        intro.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        sheet.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        sheet.setContentHuggingPriority(.defaultLow, for: .vertical)
        let fillWidth = column.widthAnchor.constraint(equalTo: captureView.widthAnchor, constant: -64)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: captureView.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: captureView.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: captureView.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: captureView.topAnchor, constant: 18),
            column.bottomAnchor.constraint(equalTo: captureView.bottomAnchor, constant: -22),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 850),
            fillWidth
        ])
        editor.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateCaptureButton()
    }

    private func buildFind() {
        let destination = NSView()
        Theme.fill(searchPanel, in: destination)
        Theme.fill(detailView, in: destination)
        let folderName = Theme.label(vault.root.lastPathComponent, size: 11)
        folderName.toolTip = vault.root.path
        folderName.lineBreakMode = .byTruncatingMiddle
        folderName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folderIcon = Theme.symbol("folder", size: 12, color: Theme.muted)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let folder = Theme.button("Open folder", target: self, action: #selector(revealFolder))
        let choose = Theme.button("Change folder…", target: self, action: #selector(chooseFolder))
        let recovery = Theme.button("Recovery…", target: self, action: #selector(showRecovery))
        for button in [folder, choose, recovery] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = Theme.muted
        }
        let footer = Theme.stack([folderIcon, folderName, spacer, folder, choose, recovery], spacing: 9)
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 28, bottom: 14, right: 28)
        let layout = Theme.stack([destination, footer], orientation: .vertical, spacing: 0)
        Theme.fill(layout, in: findView)
        destination.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        destination.setContentHuggingPriority(.defaultLow, for: .vertical)

        let back = Theme.button("← Results", target: self, action: #selector(backToResults))
        back.toolTip = "Return to the same query and results"
        back.controlSize = .small
        back.contentTintColor = Theme.muted
        noteHeading.font = .systemFont(ofSize: 12, weight: .medium)
        noteHeading.textColor = Theme.muted
        noteHeading.maximumNumberOfLines = 1
        noteHeading.lineBreakMode = .byTruncatingTail
        noteHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editButton.title = "Edit note"
        editButton.target = self
        editButton.action = #selector(toggleNoteEditing)
        editButton.bezelStyle = .rounded
        noteSaveButton.target = self
        noteSaveButton.action = #selector(saveNote)
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = Theme.stack([back, noteHeading, titleSpacer, editButton, noteSaveButton], spacing: 10)
        toolbar.edgeInsets = NSEdgeInsets(top: 14, left: 24, bottom: 8, right: 24)
        noteEditor.allowsAttachments = false
        noteEditor.textView.isEditable = false
        noteEditor.textView.placeholder = "This note is empty."
        let paper = PaperSurface()
        let detail = Theme.stack([toolbar, noteEditor], orientation: .vertical, spacing: 0)
        Theme.fill(detail, in: paper)
        toolbar.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        noteEditor.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        noteEditor.setContentHuggingPriority(.defaultLow, for: .vertical)
        paper.translatesAutoresizingMaskIntoConstraints = false
        detailView.addSubview(paper)
        let paperWidth = paper.widthAnchor.constraint(equalTo: detailView.widthAnchor, constant: -64)
        paperWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            paper.centerXAnchor.constraint(equalTo: detailView.centerXAnchor),
            paper.topAnchor.constraint(equalTo: detailView.topAnchor, constant: 18),
            paper.bottomAnchor.constraint(equalTo: detailView.bottomAnchor, constant: -6),
            paper.leadingAnchor.constraint(greaterThanOrEqualTo: detailView.leadingAnchor, constant: 24),
            paper.trailingAnchor.constraint(lessThanOrEqualTo: detailView.trailingAnchor, constant: -24),
            paper.widthAnchor.constraint(lessThanOrEqualToConstant: 850),
            paperWidth
        ])
        updateNoteControls()
    }

    private func presentMode(focus: Bool) {
        modeSwitch.selectedSegment = mode == .capture ? 0 : 1
        if mode == .capture {
            let date = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
            captureContext.stringValue = "\(date)  ·  Local capture"
        }
        captureView.isHidden = mode != .capture
        findView.isHidden = mode != .find
        searchPanel.isHidden = findShowsNote
        detailView.isHidden = !findShowsNote
        if mode == .find {
            if findShowsNote { refreshNoteIfClean() }
            else if findNeedsRefresh { findNeedsRefresh = false; searchPanel.refresh() }
        }
        guard focus else { return }
        if mode == .capture { editor.focus() }
        else if findShowsNote { noteEditor.focus() }
        else { searchPanel.focusSearch() }
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { showCapture() }
        else { showFind() }
        modeSwitch.selectedSegment = mode == .capture ? 0 : 1
    }
    @objc func showCapture() {
        guard persistNoteIfNeeded() else { return }
        mode = .capture
        presentMode(focus: true)
    }
    @objc func showFind() {
        mode = .find
        presentMode(focus: true)
    }
    func showAndFocus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        presentMode(focus: true)
    }
    func refresh() {
        findNeedsRefresh = true
        if mode == .find {
            if findShowsNote { refreshNoteIfClean() }
            else { findNeedsRefresh = false; searchPanel.refresh() }
        }
    }
    private func updateCaptureButton() { saveButton.isEnabled = editor.hasContent }

    @discardableResult private func persistCapture() -> Bool {
        guard editor.hasContent else { return true }
        do {
            let note = try vault.capture(text: editor.text, attachments: editor.attachments)
            editor.reset()
            editor.status.stringValue = "Kept · \(note.url.lastPathComponent)"
            updateCaptureButton()
            refresh()
            return true
        } catch {
            mode = .capture
            presentMode(focus: true)
            showError(error, in: window)
            return false
        }
    }
    @discardableResult func persistCurrent() -> Bool {
        guard persistNoteIfNeeded() else { return false }
        return persistCapture()
    }
    @objc func saveCapture() { if persistCapture() { editor.focus() } }
    @objc func saveCurrent() {
        if mode == .capture { saveCapture() }
        else if findShowsNote, noteEditing { saveNote() }
    }
    @objc func newCapture() {
        guard persistCurrent() else { return }
        mode = .capture
        presentMode(focus: true)
    }
    @objc func focusSearch() { backToResults() }
    @objc func makeSearchable() {
        guard returnToResults() else { return }
        searchPanel.makeSearchable()
    }
    @objc private func backToResults() { _ = returnToResults() }
    @discardableResult private func returnToResults() -> Bool {
        guard persistNoteIfNeeded() else { return false }
        noteEditing = false
        noteEditor.textView.isEditable = false
        findShowsNote = false
        mode = .find
        updateNoteControls()
        presentMode(focus: true)
        return true
    }

    private func openNote(_ url: URL) {
        guard persistNoteIfNeeded() else { return }
        do {
            let text = try vault.read(url)
            noteURL = url
            noteBaseline = text
            noteDirty = false
            noteConflicted = false
            noteAvailable = true
            noteEditing = false
            noteEditor.text = text
            noteEditor.textView.isEditable = false
            noteEditor.status.stringValue = relativePath(url)
            noteHeading.stringValue = title(text, fallback: url.deletingPathExtension().lastPathComponent)
            findShowsNote = true
            mode = .find
            updateNoteControls()
            presentMode(focus: true)
        } catch { showError(error, in: window) }
    }
    private func title(_ text: String, fallback: String) -> String {
        var result = fallback
        text.enumerateLines { line, stop in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            result = Vault.title(from: String(line.prefix(160)))
            stop = true
        }
        return result
    }
    private func relativePath(_ url: URL) -> String { String(url.path.dropFirst(vault.root.path.count + 1)) }
    private func refreshNoteIfClean() {
        guard let noteURL, !noteDirty, !noteConflicted else { return }
        do {
            let text = try vault.read(noteURL)
            if text != noteBaseline {
                noteBaseline = text
                noteEditor.text = text
                noteHeading.stringValue = title(text, fallback: noteURL.deletingPathExtension().lastPathComponent)
            }
            if !noteAvailable { noteEditor.status.stringValue = relativePath(noteURL) }
            noteAvailable = true
        } catch {
            noteAvailable = false
            noteEditor.status.stringValue = "Original unavailable. Its last view is preserved. \(error.localizedDescription)"
        }
        updateNoteControls()
    }
    @objc private func toggleNoteEditing() {
        if noteEditing {
            guard persistNoteIfNeeded() else { return }
            noteEditing = false
        } else {
            guard noteAvailable else { return }
            noteEditing = true
        }
        noteEditor.textView.isEditable = noteEditing
        updateNoteControls()
        noteEditor.focus()
    }
    private func noteChanged() {
        guard noteEditing else { return }
        noteDirty = noteEditor.text != noteBaseline
        updateNoteControls()
        autosave?.invalidate()
        guard noteDirty, !noteConflicted else { return }
        noteEditor.status.stringValue = "Unsaved changes"
        autosave = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.persistNoteIfNeeded() }
        }
    }
    private func updateNoteControls() {
        editButton.title = noteEditing ? "Done editing" : "Edit note"
        editButton.isEnabled = noteAvailable && !noteConflicted
        noteSaveButton.title = noteConflicted ? "Keep as new note" : "Save changes"
        noteSaveButton.isHidden = !noteEditing && !noteConflicted
        noteSaveButton.isEnabled = noteDirty
    }
    @discardableResult private func persistNoteIfNeeded() -> Bool {
        autosave?.invalidate()
        guard noteDirty, let noteURL else { return true }
        guard !noteConflicted else { return false }
        do {
            try vault.save(noteEditor.text, to: noteURL, expectedContent: noteBaseline)
            noteBaseline = noteEditor.text
            noteDirty = false
            noteEditor.status.stringValue = "Saved · \(relativePath(noteURL))"
            noteHeading.stringValue = title(noteBaseline, fallback: noteURL.deletingPathExtension().lastPathComponent)
            updateNoteControls()
            refresh()
            return true
        } catch {
            noteConflicted = true
            noteEditor.status.stringValue = "Couldn’t save safely. Keep your edits as a new note; the original will not be overwritten."
            updateNoteControls()
            showError(error, in: window)
            return false
        }
    }
    @objc private func saveNote() {
        if !noteConflicted { _ = persistNoteIfNeeded(); return }
        do {
            let note = try vault.capture(text: noteEditor.text)
            noteURL = note.url
            noteBaseline = try vault.read(note.url)
            noteEditor.text = noteBaseline
            noteDirty = false
            noteConflicted = false
            noteAvailable = true
            noteEditing = false
            noteEditor.textView.isEditable = false
            noteHeading.stringValue = note.title
            noteEditor.status.stringValue = "Kept as a new note · \(relativePath(note.url))"
            updateNoteControls()
            refresh()
        } catch { showError(error, in: window) }
    }

    @objc private func revealFolder() { NSWorkspace.shared.open(vault.root) }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc func showRecovery() {
        guard persistNoteIfNeeded() else { return }
        mode = .find
        presentMode(focus: false)
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
            alert.informativeText = "Restore saved files from a checkpoint. New files and the current capture draft are kept. A fresh checkpoint is made before recovery."
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
                    self.noteURL = nil
                    self.noteEditor.reset()
                    self.findShowsNote = false
                    self.noteEditing = false
                    self.noteEditor.textView.isEditable = false
                    self.findNeedsRefresh = true
                    self.presentMode(focus: true)
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
