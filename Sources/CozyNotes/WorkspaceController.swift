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
    private let saveButton = NSButton()
    private let searchPanel: SearchPanel
    private let noteEditor = CaptureEditor(frame: .zero)
    private let noteHeading = Theme.label("", size: 21, color: Theme.ink)
    private let editButton = NSButton()
    private let noteSaveButton = NSButton()
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
        window.appearance = NSAppearance(named: .aqua)
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
        let brand = Theme.label("cozy notes", size: 19, color: Theme.accent)
        brand.font = .systemFont(ofSize: 19, weight: .semibold)
        brand.toolTip = vault.root.path
        modeSwitch.target = self
        modeSwitch.action = #selector(changeMode(_:))
        modeSwitch.selectedSegment = 0
        modeSwitch.setWidth(92, forSegment: 0)
        modeSwitch.setWidth(92, forSegment: 1)
        modeSwitch.setAccessibilityLabel("Workspace mode")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = Theme.stack([brand, spacer, modeSwitch])
        header.edgeInsets = NSEdgeInsets(top: 18, left: 26, bottom: 14, right: 26)
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
        let title = Theme.label("Keep a little something.", size: 28, color: Theme.ink)
        title.font = .systemFont(ofSize: 28, weight: .medium)
        let subtitle = Theme.label("A thought, a link, a screenshot. No organizing needed.", size: 13)
        let intro = Theme.stack([title, subtitle], orientation: .vertical, spacing: 9)
        intro.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 8, right: 30)
        saveButton.title = "Keep capture"
        saveButton.target = self
        saveButton.action = #selector(saveCapture)
        saveButton.bezelStyle = .rounded
        saveButton.contentTintColor = Theme.accent
        saveButton.font = .systemFont(ofSize: 14, weight: .semibold)
        saveButton.toolTip = "Save this capture (⌘Return)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = Theme.stack([spacer, saveButton])
        actions.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 20, right: 24)
        let column = Theme.stack([intro, editor, actions], orientation: .vertical, spacing: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        captureView.addSubview(column)
        for child in [intro, editor, actions] { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let fillWidth = column.widthAnchor.constraint(equalTo: captureView.widthAnchor, constant: -36)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: captureView.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: captureView.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(lessThanOrEqualTo: captureView.trailingAnchor, constant: -18),
            column.topAnchor.constraint(equalTo: captureView.topAnchor),
            column.bottomAnchor.constraint(equalTo: captureView.bottomAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let folder = Theme.button("Open folder", target: self, action: #selector(revealFolder))
        let choose = Theme.button("Change folder…", target: self, action: #selector(chooseFolder))
        let recovery = Theme.button("Recovery…", target: self, action: #selector(showRecovery))
        let footer = Theme.stack([folderName, spacer, folder, choose, recovery], spacing: 9)
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 16, right: 24)
        let layout = Theme.stack([destination, footer], orientation: .vertical, spacing: 0)
        Theme.fill(layout, in: findView)
        destination.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        destination.setContentHuggingPriority(.defaultLow, for: .vertical)

        let back = Theme.button("← Results", target: self, action: #selector(backToResults))
        back.toolTip = "Return to the same query and results"
        noteHeading.lineBreakMode = .byTruncatingTail
        noteHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editButton.title = "Edit note"
        editButton.target = self
        editButton.action = #selector(toggleNoteEditing)
        editButton.bezelStyle = .rounded
        noteSaveButton.target = self
        noteSaveButton.action = #selector(saveNote)
        noteSaveButton.bezelStyle = .rounded
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = Theme.stack([back, noteHeading, titleSpacer, editButton, noteSaveButton], spacing: 10)
        toolbar.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 8, right: 24)
        noteEditor.allowsAttachments = false
        noteEditor.textView.isEditable = false
        noteEditor.textView.placeholder = "This note is empty."
        let detail = Theme.stack([toolbar, noteEditor], orientation: .vertical, spacing: 0)
        Theme.fill(detail, in: detailView)
        toolbar.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        noteEditor.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        updateNoteControls()
    }

    private func presentMode(focus: Bool) {
        modeSwitch.selectedSegment = mode == .capture ? 0 : 1
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
