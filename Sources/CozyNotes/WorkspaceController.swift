import AppKit
import CozyCore

@MainActor final class WorkspaceController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let vault: Vault
    let editor = CaptureEditor(frame: .zero)
    private let table = NSTableView()
    private let heading = Theme.label("A little room to think.", size: 22, color: Theme.ink)
    private let count = Theme.label("YOUR NOTES", size: 11)
    private let saveButton = NSButton()
    private let terminalButton = NSButton()
    private let terminalHost = NSView()
    private var agentPanel: AgentPanel?
    private var records: [NoteRecord] = []
    private var selectedURL: URL?
    private var baseline = ""
    private var dirty = false
    private var conflicted = false
    private var changingSelection = false
    private var autosave: Timer?
    private var watcher: VaultWatcher?
    var onChooseFolder: (() -> Void)?
    var onQuickCapture: (() -> Void)?

    init(vault: Vault) {
        self.vault = vault
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Cozy Notes"
        window.minSize = NSSize(width: 820, height: 580)
        window.backgroundColor = Theme.canvas
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        editor.onChange = { [weak self] in self?.editorChanged() }
        watcher = VaultWatcher(root: vault.root) { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = Theme.sidebar.cgColor
        let brand = Theme.label("cozy notes", size: 22, color: Theme.accent)
        brand.font = .systemFont(ofSize: 22, weight: .semibold)
        let new = Theme.button("New capture", target: self, action: #selector(newCapture))
        new.keyEquivalent = "n"
        new.keyEquivalentModifierMask = .command
        new.toolTip = "Start a new capture (⌘N)"
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notes")))
        table.headerView = nil
        table.rowHeight = 76
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self
        let list = NSScrollView()
        list.documentView = table
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        let folder = Theme.button("Open folder", target: self, action: #selector(revealFolder))
        let change = Theme.button("Change…", target: self, action: #selector(chooseFolder))
        let folderRow = Theme.stack([folder, change], spacing: 4)
        let folderName = Theme.label(vault.root.lastPathComponent, size: 11)
        folderName.toolTip = vault.root.path
        folderName.lineBreakMode = .byTruncatingMiddle
        let sidebarStack = Theme.stack([brand, new, count, list, folderName, folderRow], orientation: .vertical, spacing: 18)
        sidebarStack.edgeInsets = NSEdgeInsets(top: 25, left: 18, bottom: 18, right: 18)
        Theme.fill(sidebarStack, in: sidebar)
        list.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -36).isActive = true
        folderName.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor).isActive = true
        sidebar.widthAnchor.constraint(equalToConstant: 254).isActive = true

        saveButton.title = "Keep capture"
        saveButton.target = self
        saveButton.action = #selector(saveCapture)
        saveButton.bezelStyle = .rounded
        saveButton.contentTintColor = Theme.accent
        saveButton.toolTip = "Save this capture (⌘Return)"
        terminalButton.title = "Agent"
        terminalButton.target = self
        terminalButton.action = #selector(toggleTerminal)
        terminalButton.bezelStyle = .rounded
        terminalButton.toolTip = "Show or hide the agent terminal (⌘J)"
        let history = Theme.button("Recovery…", target: self, action: #selector(showRecovery))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.lineBreakMode = .byTruncatingTail
        let toolbar = Theme.stack([heading, spacer, history, terminalButton, saveButton], spacing: 10)
        toolbar.edgeInsets = NSEdgeInsets(top: 20, left: 30, bottom: 10, right: 24)
        let hint = Theme.label("Capture first. Make sense of it later.", size: 13)
        let hintRow = Theme.stack([hint])
        hintRow.edgeInsets = NSEdgeInsets(top: 0, left: 32, bottom: 0, right: 24)
        terminalHost.isHidden = true
        terminalHost.heightAnchor.constraint(equalToConstant: 290).isActive = true
        let main = Theme.stack([toolbar, hintRow, editor, terminalHost], orientation: .vertical, spacing: 6)
        main.alignment = .leading
        for view in [toolbar, hintRow, editor, terminalHost] {
            view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        let layout = Theme.stack([sidebar, main], spacing: 0)
        layout.alignment = .top
        Theme.fill(layout, in: content)
        sidebar.heightAnchor.constraint(equalTo: layout.heightAnchor).isActive = true
        main.heightAnchor.constraint(equalTo: layout.heightAnchor).isActive = true
        editor.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateSaveButton()
    }

    func showAndFocus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focus()
    }
    func refresh() {
        do {
            records = try vault.notes()
            changingSelection = true
            table.reloadData()
            if let selectedURL, let index = records.firstIndex(where: { $0.url == selectedURL }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            changingSelection = false
            count.stringValue = records.isEmpty ? "YOUR NOTES · NOTHING HERE YET" : "YOUR NOTES · \(records.count)"
            if let selectedURL, !dirty {
                do {
                    let current = try vault.read(selectedURL)
                    if current != baseline { baseline = current; editor.text = current }
                } catch {
                    editor.status.stringValue = "This note moved or was removed elsewhere. Your view is preserved."
                }
            }
        } catch { editor.status.stringValue = "Couldn’t refresh: \(error.localizedDescription)" }
    }
    private func editorChanged() {
        dirty = selectedURL == nil ? editor.hasContent : editor.text != baseline
        updateSaveButton()
        guard selectedURL != nil, !conflicted else { return }
        autosave?.invalidate()
        autosave = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.persistCurrent() }
        }
    }
    private func updateSaveButton() {
        saveButton.title = conflicted ? "Keep as new capture" : (selectedURL == nil ? "Keep capture" : "Save changes")
        saveButton.isEnabled = dirty || !editor.attachments.isEmpty
    }
    @discardableResult func persistCurrent() -> Bool {
        autosave?.invalidate()
        guard dirty || !editor.attachments.isEmpty else { return true }
        do {
            if let url = selectedURL {
                try vault.save(editor.text, to: url, expectedContent: baseline)
                baseline = editor.text
                dirty = false
                editor.status.stringValue = "Saved · \(url.lastPathComponent)"
            } else {
                guard editor.hasContent else { return true }
                let note = try vault.capture(text: editor.text, attachments: editor.attachments)
                editor.reset()
                dirty = false
                editor.status.stringValue = "Kept · \(note.url.lastPathComponent)"
            }
            conflicted = false
            updateSaveButton()
            refresh()
            return true
        } catch {
            if selectedURL != nil {
                conflicted = true
                editor.status.stringValue = "Couldn’t save safely. Your edits are here; keep them as a new capture."
            }
            updateSaveButton()
            showError(error, in: window)
            return false
        }
    }
    @objc func saveCapture() {
        if conflicted {
            do {
                _ = try vault.capture(text: editor.text, attachments: editor.attachments)
                dirty = false
                conflicted = false
                selectedURL = nil
                baseline = ""
                editor.reset()
                editor.allowsAttachments = true
                heading.stringValue = "A little room to think."
                updateSaveButton()
                refresh()
            } catch { showError(error, in: window) }
        } else { _ = persistCurrent() }
        editor.focus()
    }
    @objc func newCapture() {
        guard persistCurrent() else { return }
        selectedURL = nil
        baseline = ""
        dirty = false
        conflicted = false
        changingSelection = true
        table.deselectAll(nil)
        changingSelection = false
        editor.reset()
        editor.allowsAttachments = true
        heading.stringValue = "A little room to think."
        updateSaveButton()
        editor.focus()
    }
    @objc func toggleTerminal() {
        if terminalHost.isHidden {
            guard persistCurrent() else { return }
            if agentPanel == nil {
                let panel = AgentPanel(vault: vault)
                panel.onFilesChanged = { [weak self] in self?.refresh() }
                Theme.fill(panel, in: terminalHost)
                agentPanel = panel
            }
            terminalHost.isHidden = false
            terminalButton.title = "Hide agent"
            agentPanel?.focusTerminal()
        } else {
            terminalHost.isHidden = true
            terminalButton.title = "Agent"
            editor.focus()
        }
    }
    @objc private func revealFolder() { NSWorkspace.shared.open(vault.root) }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc func showRecovery() {
        guard persistCurrent() else { return }
        guard agentPanel?.isSessionRunning != true else {
            showError(NSError(domain: "CozyNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Exit or stop the terminal session before restoring a checkpoint."
            ]), in: window)
            return
        }
        do {
            let snapshots = try vault.snapshots()
            let alert = NSAlert()
            alert.messageText = "Recover an earlier version"
            alert.informativeText = "Restore notes and attachments from a checkpoint. New files created since then are kept. A fresh checkpoint is made before recovery. Stop the agent first so it cannot keep changing restored files."
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for snapshot in snapshots { picker.addItem(withTitle: "\(formatter.string(from: snapshot.createdAt)) — \(snapshot.label)") }
            alert.accessoryView = picker
            alert.addButton(withTitle: snapshots.isEmpty ? "No checkpoints yet" : "Restore checkpoint")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.isEnabled = !snapshots.isEmpty
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn, snapshots.indices.contains(picker.indexOfSelectedItem) else { return }
                do {
                    guard self.agentPanel?.isSessionRunning != true else {
                        throw NSError(domain: "CozyNotes", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "The terminal is running. Stop it before restoring."
                        ])
                    }
                    try self.vault.restore(snapshotID: snapshots[picker.indexOfSelectedItem].id)
                    self.selectedURL = nil
                    self.baseline = ""
                    self.editor.reset()
                    self.editor.allowsAttachments = true
                    self.heading.stringValue = "A little room to think."
                    self.refresh()
                } catch { showError(error, in: self.window) }
            }
        } catch { showError(error, in: window) }
    }
    func shutdown() { autosave?.invalidate(); agentPanel?.shutdown() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard persistCurrent() else { return false }
        sender.orderOut(nil)
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = records[row]
        let title = Theme.label(note.title, size: 13, color: Theme.ink)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let excerpt = Theme.label(note.excerpt, size: 12)
        excerpt.lineBreakMode = .byTruncatingTail
        let date = Theme.label(note.modifiedAt.formatted(date: .abbreviated, time: .shortened), size: 10)
        let stack = Theme.stack([title, excerpt, date], orientation: .vertical, spacing: 4)
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 196).isActive = true
        excerpt.widthAnchor.constraint(lessThanOrEqualToConstant: 196).isActive = true
        return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !changingSelection, records.indices.contains(table.selectedRow) else { return }
        let requested = records[table.selectedRow]
        guard requested.url != selectedURL else { return }
        guard persistCurrent() else {
            changingSelection = true
            if let selectedURL, let index = records.firstIndex(where: { $0.url == selectedURL }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            changingSelection = false
            return
        }
        do {
            let text = try vault.read(requested.url)
            selectedURL = requested.url
            baseline = text
            dirty = false
            conflicted = false
            editor.reset()
            editor.allowsAttachments = false
            editor.text = text
            editor.status.stringValue = requested.url.path.replacingOccurrences(of: vault.root.path + "/", with: "")
            heading.stringValue = requested.title
            updateSaveButton()
            editor.focus()
        } catch { showError(error, in: window) }
    }
}
