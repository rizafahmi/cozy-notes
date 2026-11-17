import AppKit
import CozyCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var workspaces: [WorkspaceController] = []
    private weak var lastActiveWorkspace: WorkspaceController?
    private var quickCapture: QuickCaptureController?
    private var hotKey: GlobalHotKey?

    var workspace: WorkspaceController? {
        if let key = NSApp.keyWindow {
            if let direct = workspaces.first(where: { $0.window === key }) {
                return direct
            }
            if let owner = workspaces.first(where: { ws in ws.noteWindows.contains { $0.window === key } }) {
                return owner
            }
        }
        if let last = lastActiveWorkspace, workspaces.contains(where: { $0 === last }) {
            return last
        }
        return workspaces.first
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenus()
        let arguments = CommandLine.arguments
        if arguments.contains("--moby-dick-workout") {
            do {
                let cycles: Int = arguments.firstIndex(of: "--cycles").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 2
                let sample: String = arguments.firstIndex(of: "--sample").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "Whale"
                let report = try MobyDickWorkout.run(repeatCycles: cycles, typingSample: sample)
                print(report.formattedSummary())
                fflush(stdout)
                exit(0)
            } catch {
                fputs("Moby Dick Workout failed: \(error)\n", stderr)
                exit(1)
            }
        }
        let argumentVault: String? = arguments.firstIndex(of: "--vault").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let envVault = ProcessInfo.processInfo.environment["COZY_VAULT"]
        let path = argumentVault ?? envVault ?? UserDefaults.standard.string(forKey: "vaultPath")
        let root = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Cozy Notes", isDirectory: true)
        do { try openVault(root, persistPreference: argumentVault == nil && envVault == nil) }
        catch {
            showError(error, in: nil)
            chooseFolder()
            if workspace == nil { NSApp.terminate(nil); return }
        }
        do {
            hotKey = try GlobalHotKey { [weak self] in self?.quickCapture?.summon() }
        } catch { showError(error, in: workspace?.window) }
        workspace?.showAndFocus()
        if let openNoteIdx = arguments.firstIndex(of: "--open-note"),
           arguments.indices.contains(openNoteIdx + 1),
           let ws = workspace {
            let rel = arguments[openNoteIdx + 1]
            let target = ws.vault.root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: target.path) {
                ws.openNote(target)
            }
        }
        if let qsIdx = arguments.firstIndex(of: "--quick-switcher") {
            let nextIdx = qsIdx + 1
            let initialQuery: String? = (arguments.indices.contains(nextIdx) && !arguments[nextIdx].hasPrefix("--"))
                ? arguments[nextIdx]
                : nil
            workspace?.showQuickSwitcher(initialQuery: initialQuery)
        }
    }
    @discardableResult
    func openVault(_ root: URL, persistPreference: Bool = true, replacing targetWorkspace: WorkspaceController? = nil) throws -> WorkspaceController {
        let vault = try Vault(root: root)
        if let existing = workspaces.first(where: { $0.vault.root == vault.root }) {
            lastActiveWorkspace = existing
            existing.showAndFocus()
            return existing
        }
        let nextWorkspace = WorkspaceController(vault: vault)
        wireWorkspace(nextWorkspace)
        let replaced = targetWorkspace ?? workspaces.first
        if let replaced, let idx = workspaces.firstIndex(where: { $0 === replaced }) {
            if let oldFrame = replaced.window?.frame {
                nextWorkspace.window?.setFrame(oldFrame, display: false)
            }
            replaced.shutdown()
            replaced.window?.orderOut(nil)
            workspaces[idx] = nextWorkspace
        } else {
            workspaces.append(nextWorkspace)
        }
        lastActiveWorkspace = nextWorkspace
        if workspaces.first === nextWorkspace {
            let nextQuick = QuickCaptureController(vault: vault)
            nextQuick.onCapture = { [weak nextWorkspace] in nextWorkspace?.refresh() }
            nextQuick.onOpenWikiLink = { [weak nextWorkspace, weak nextQuick] link in
                guard nextQuick?.persistDraft() != false else { return }
                nextQuick?.hide()
                nextWorkspace?.showAndFocus()
                nextWorkspace?.openWikiLink(link)
            }
            quickCapture?.window?.orderOut(nil)
            quickCapture = nextQuick
        }
        if persistPreference {
            UserDefaults.standard.set(root.path, forKey: "vaultPath")
        }
        return nextWorkspace
    }

    @discardableResult
    func openWorkspaceInNewWindow(_ root: URL) throws -> WorkspaceController {
        let vault = try Vault(root: root)
        if let existing = workspaces.first(where: { $0.vault.root == vault.root }) {
            lastActiveWorkspace = existing
            existing.showAndFocus()
            return existing
        }
        let controller = WorkspaceController(vault: vault)
        if let anchor = (workspace?.window ?? workspaces.last?.window), let win = controller.window {
            let anchorFrame = anchor.frame
            let nextOrigin = NSPoint(x: anchorFrame.minX + 36, y: anchorFrame.maxY - win.frame.height - 28)
            win.setFrameOrigin(nextOrigin)
        }
        wireWorkspace(controller)
        workspaces.append(controller)
        lastActiveWorkspace = controller
        controller.showAndFocus()
        return controller
    }

    private func wireWorkspace(_ controller: WorkspaceController) {
        controller.onChooseFolder = { [weak self, weak controller] in
            self?.promptFolderReplacement(for: controller)
        }
        controller.onOpenFolderInNewWindow = { [weak self] in
            self?.openFolderInNewWindow()
        }
        controller.onDidBecomeActive = { [weak self] active in
            self?.lastActiveWorkspace = active
        }
        controller.onRequestCloseWorkspace = { [weak self] closing in
            guard let self, self.workspaces.count > 1 else { return false }
            closing.shutdown()
            self.workspaces.removeAll { $0 === closing }
            if self.lastActiveWorkspace === closing {
                self.lastActiveWorkspace = self.workspaces.first
            }
            return true
        }
        controller.onDidChangeTheme = { [weak self, weak controller] appearance in
            guard let self else { return }
            for ws in self.workspaces where ws !== controller {
                ws.applySharedTheme(appearance: appearance)
            }
        }
    }

    @objc func chooseFolder() {
        promptFolderReplacement(for: workspace)
    }

    private func promptFolderReplacement(for targetWorkspace: WorkspaceController?) {
        guard (targetWorkspace ?? workspace)?.persistAllWindows() != false, quickCapture?.persistDraft() != false else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose your local notes or project folder"
        picker.message = "Choose a notes vault or a project repository. Cozy Notes indexes Markdown files and attachments locally."
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = "Use this folder"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let opened = try openVault(url, replacing: targetWorkspace)
            opened.showAndFocus()
        } catch {
            showError(error, in: (targetWorkspace ?? workspace)?.window)
        }
    }

    @objc func openFolderInNewWindow() {
        let picker = NSOpenPanel()
        picker.title = "Open Folder or Project in New Window"
        picker.message = "Open another notes vault or project repository alongside your current workspace."
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = "Open in New Window"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            _ = try openWorkspaceInNewWindow(url)
        } catch {
            showError(error, in: workspace?.window)
        }
    }
    @objc private func newCapture() { workspace?.newCapture(); workspace?.showAndFocus() }
    @objc private func quick() { quickCapture?.summon() }
    @objc private func openInNewWindow() {
        if let noteWin = workspace?.activeNoteWindowController {
            if let link = noteWin.editor.textView.wikiLinkAtCursor() {
                _ = workspace?.openWikiLinkInNewWindow(link)
            } else {
                noteWin.showAndFocus()
            }
            return
        }
        if let link = workspace?.editor.textView.wikiLinkAtCursor() {
            _ = workspace?.openWikiLinkInNewWindow(link)
            return
        }
        workspace?.openCurrentNoteInNewWindow()
    }
    @objc private func togglePinNote() {
        if let noteWin = workspace?.activeNoteWindowController {
            noteWin.togglePinCurrentNote()
        } else {
            workspace?.togglePinCurrentNote()
        }
    }
    @objc private func save() {
        if NSApp.keyWindow === quickCapture?.window {
            if let link = quickCapture?.editor.textView.wikiLinkAtCursor() {
                quickCapture?.editor.onOpenWikiLink?(link)
                return
            }
            quickCapture?.save()
        } else if let noteWin = workspace?.activeNoteWindowController {
            if let link = noteWin.editor.textView.wikiLinkAtCursor() {
                noteWin.openWikiLink(link)
                return
            }
            noteWin.saveCurrent()
        } else {
            if let link = workspace?.editor.textView.wikiLinkAtCursor() {
                workspace?.openWikiLink(link)
                return
            }
            workspace?.saveCurrent()
        }
    }
    @objc func mergeNotes() {
        workspace?.mergeSelectedNotes()
    }
    @objc private func deleteNote() {
        if let noteWin = workspace?.activeNoteWindowController {
            noteWin.deleteCurrentNote()
        } else {
            workspace?.deleteCurrentNote()
        }
    }
    @objc private func search() {
        if let noteWin = workspace?.activeNoteWindowController {
            noteWin.showInNoteFind()
        } else {
            workspace?.showAndFocus()
            workspace?.showInNoteFind()
        }
    }
    @objc private func findNext() {
        if let noteWin = workspace?.activeNoteWindowController {
            noteWin.findNextInNote()
        } else {
            workspace?.showAndFocus()
            workspace?.findNextInNote()
        }
    }
    @objc private func findPrevious() {
        if let noteWin = workspace?.activeNoteWindowController {
            noteWin.findPreviousInNote()
        } else {
            workspace?.showAndFocus()
            workspace?.findPreviousInNote()
        }
    }
    @objc private func quickSwitcher() { workspace?.showAndFocus(); workspace?.toggleQuickSwitcher() }
    @objc private func makeSearchable() { workspace?.makeSearchable() }
    @objc private func recovery() { workspace?.showRecovery() }
    @objc private func showWorkspace() { workspace?.showAndFocus() }
    @objc private func toggleSidebar() { workspace?.toggleSidebar(); workspace?.showWindow(nil) }
    @objc private func toggleOutline() {
        if let noteWin = workspace?.activeNoteWindowController {
            noteWin.toggleOutline()
        } else {
            workspace?.toggleOutline()
            workspace?.showWindow(nil)
        }
    }
    @objc private func toggleSemanticConnections() {
        if let noteWin = workspace?.activeNoteWindowController {
            noteWin.toggleSemanticConnections()
        } else {
            workspace?.toggleSemanticConnections()
            workspace?.showWindow(nil)
        }
    }
    @objc private func semanticModelManager() {
        workspace?.showSemanticModelManager()
    }
    @objc private func toggleAppearance() { workspace?.toggleAppearance(); workspace?.showWindow(nil) }
    @objc private func cycleAtmosphere() { workspace?.cycleAtmosphere(); workspace?.showWindow(nil) }
    @objc private func cycleVoice() { workspace?.cycleVoice(); workspace?.showWindow(nil) }
    @objc func toggleVimMode() {
        Theme.vimModeEnabled.toggle()
        for ws in workspaces {
            ws.syncVimModePreference()
        }
    }
    @objc private func zoomIn() { workspace?.increaseFontSize() }
    @objc private func zoomOut() { workspace?.decreaseFontSize() }
    @objc private func zoomReset() { workspace?.resetFontSize() }
    @objc private func captureMode() { workspace?.showCapture(); workspace?.showAndFocus() }
    @objc private func findMode() { workspace?.showFind(); workspace?.showAndFocus() }
    @objc private func openFolder() {
        if let root = workspace?.vault.root { NSWorkspace.shared.open(root) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspace?.showAndFocus()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for ws in workspaces {
            guard ws.persistAllWindows() else { return .terminateCancel }
        }
        guard quickCapture?.persistDraft() != false else { return .terminateCancel }
        for ws in workspaces {
            ws.shutdown()
        }
        return .terminateNow
    }
    func buildMenus() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let app = NSMenu()
        appItem.submenu = app
        app.addItem(withTitle: "About Cozy Notes", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Cozy Notes", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Cozy Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem()
        fileItem.title = "File"
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        bar.addItem(fileItem)
        add("New Note", action: #selector(newCapture), key: "n", to: file)
        add("Quick Capture", action: #selector(quick), key: " ", modifiers: [.command, .shift], to: file)
        add("Open in New Window", action: #selector(openInNewWindow), key: "o", modifiers: [.command, .option], to: file)
        add("Pin Note", action: #selector(togglePinNote), key: "p", modifiers: [.command, .shift], to: file)
        add("Merge Notes…", action: #selector(mergeNotes), key: "m", modifiers: [.command, .shift], to: file)
        add("Save Note", action: #selector(save), key: "s", to: file)
        add("Keep / Save", action: #selector(save), key: "\r", to: file)
        add("Delete Note…", action: #selector(deleteNote), key: "\u{08}", to: file)
        add("Choose Notes Folder…", action: #selector(chooseFolder), key: "o", modifiers: [.command, .shift], to: file)
        add("Open Folder in New Window…", action: #selector(openFolderInNewWindow), key: "o", modifiers: [.command, .control], to: file)
        add("Open Notes Folder", action: #selector(openFolder), key: "", to: file)
        add("Recovery…", action: #selector(recovery), key: "", to: file)
        add("Make Searchable", action: #selector(makeSearchable), key: "", to: file)
        add("Semantic Connections Model…", action: #selector(semanticModelManager), key: "", to: file)
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        bar.addItem(editItem)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        add("Find in Note…", action: #selector(search), key: "f", to: edit)
        add("Find Next", action: #selector(findNext), key: "g", to: edit)
        add("Find Previous", action: #selector(findPrevious), key: "g", modifiers: [.command, .shift], to: edit)
        let formatItem = NSMenuItem()
        formatItem.title = "Format"
        let format = NSMenu(title: "Format")
        formatItem.submenu = format
        bar.addItem(formatItem)
        addResponder("Bold", action: #selector(MarkdownTextView.toggleBold(_:)), key: "b", to: format)
        addResponder("Italic", action: #selector(MarkdownTextView.toggleItalic(_:)), key: "i", to: format)
        addResponder("Underline", action: #selector(MarkdownTextView.toggleUnderline(_:)), key: "u", to: format)
        addResponder("Strikethrough", action: #selector(MarkdownTextView.toggleStrikethrough(_:)), key: "x", modifiers: [.command, .shift], to: format)
        addResponder("Inline Code", action: #selector(MarkdownTextView.toggleInlineCode(_:)), key: "e", to: format)
        addResponder("Code Block", action: #selector(MarkdownTextView.toggleCodeBlock(_:)), key: "c", modifiers: [.command, .shift], to: format)
        addResponder("Insert Link", action: #selector(MarkdownTextView.insertMarkdownLink(_:)), key: "k", to: format)
        addResponder("Insert Note Link", action: #selector(MarkdownTextView.insertWikiLink(_:)), key: "k", modifiers: [.command, .option], to: format)
        addResponder("Open Note Link", action: #selector(MarkdownTextView.openWikiLinkAtCursor(_:)), key: "\r", modifiers: [.command, .option], to: format)
        addResponder("Open Note Link in New Window", action: #selector(MarkdownTextView.openWikiLinkInNewWindowAtCursor(_:)), key: "\r", modifiers: [.command, .option, .shift], to: format)
        format.addItem(.separator())
        addResponder("Heading 1", action: #selector(MarkdownTextView.toggleHeading1(_:)), key: "1", modifiers: [.command, .option], to: format)
        addResponder("Heading 2", action: #selector(MarkdownTextView.toggleHeading2(_:)), key: "2", modifiers: [.command, .option], to: format)
        addResponder("Heading 3", action: #selector(MarkdownTextView.toggleHeading3(_:)), key: "3", modifiers: [.command, .option], to: format)
        format.addItem(.separator())
        addResponder("Blockquote", action: #selector(MarkdownTextView.toggleBlockquote(_:)), key: ".", modifiers: [.command, .shift], to: format)
        addResponder("Bullet List", action: #selector(MarkdownTextView.toggleBulletList(_:)), key: "8", modifiers: [.command, .shift], to: format)
        addResponder("Numbered List", action: #selector(MarkdownTextView.toggleNumberedList(_:)), key: "7", modifiers: [.command, .shift], to: format)
        addResponder("Checklist", action: #selector(MarkdownTextView.toggleChecklist(_:)), key: "l", modifiers: [.command, .shift], to: format)
        format.addItem(.separator())
        addResponder("Indent List Level", action: #selector(MarkdownTextView.indentListLevel(_:)), key: "]", to: format)
        addResponder("Outdent List Level", action: #selector(MarkdownTextView.outdentListLevel(_:)), key: "[", to: format)
        format.addItem(.separator())
        addResponder("Toggle Heading Fold", action: #selector(MarkdownTextView.toggleHeadingFoldAtCursor(_:)), key: "[", modifiers: [.command, .option], to: format)
        addResponder("Unfold Heading Section", action: #selector(MarkdownTextView.unfoldHeadingAtCursor(_:)), key: "]", modifiers: [.command, .option], to: format)
        addResponder("Cycle Outline Folding", action: #selector(MarkdownTextView.cycleOutlineFolding(_:)), key: "[", modifiers: [.command, .control], to: format)
        addResponder("Unfold All Headings", action: #selector(MarkdownTextView.unfoldAllHeadings(_:)), key: "]", modifiers: [.command, .control], to: format)
        let viewItem = NSMenuItem()
        viewItem.title = "View"
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        bar.addItem(viewItem)
        add("Toggle Sidebar", action: #selector(toggleSidebar), key: "\\", to: view)
        add("Toggle Document Outline", action: #selector(toggleOutline), key: "\\", modifiers: [.command, .option], to: view)
        add("Toggle Semantic Connections", action: #selector(toggleSemanticConnections), key: "\\", modifiers: [.command, .control], to: view)
        add("Toggle Light / Dark Mode", action: #selector(toggleAppearance), key: "d", modifiers: [.command, .shift], to: view)
        add("Switch Atmosphere (Obsidian / Midnight / Neo-Acid)", action: #selector(cycleAtmosphere), key: "t", modifiers: [.command, .shift], to: view)
        add("Cycle Writing Font (Avenir / Charter / Iowan / Mono / Unbounded)", action: #selector(cycleVoice), key: "y", modifiers: [.command, .shift], to: view)
        add("Vim Mode", action: #selector(toggleVimMode), key: "v", modifiers: [.command, .control], to: view)
        view.addItem(.separator())
        add("Bigger Text", action: #selector(zoomIn), key: "=", to: view)
        add("Smaller Text", action: #selector(zoomOut), key: "-", to: view)
        add("Actual Size", action: #selector(zoomReset), key: "0", to: view)
        view.addItem(.separator())
        add("Focus Editor", action: #selector(captureMode), key: "1", to: view)
        add("Focus Sidebar", action: #selector(findMode), key: "2", to: view)
        add("Quick Open / Global Search…", action: #selector(quickSwitcher), key: "p", to: view)
        add("Global Note Search…", action: #selector(quickSwitcher), key: "f", modifiers: [.command, .shift], to: view)
        add("Show Workspace", action: #selector(showWorkspace), key: "", to: view)
        NSApp.mainMenu = bar
    }
    private func add(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
    }
    private func addResponder(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if NSApp.keyWindow?.sheetParent != nil {
            return false
        }
        if menuItem.action == #selector(deleteNote) {
            if let noteWin = workspace?.activeNoteWindowController {
                return noteWin.noteURL != nil
            }
            guard let workspace, NSApp.keyWindow === workspace.window || NSApp.keyWindow == nil else { return false }
            return workspace.canDeleteNote
        }
        if menuItem.action == #selector(openInNewWindow) {
            if let noteWin = workspace?.activeNoteWindowController {
                return noteWin.noteURL != nil
            }
            guard let workspace, NSApp.keyWindow === workspace.window || NSApp.keyWindow == nil else { return false }
            return workspace.canOpenInNewWindow
        }
        if menuItem.action == #selector(togglePinNote) {
            if let noteWin = workspace?.activeNoteWindowController {
                menuItem.title = noteWin.isCurrentNotePinned ? "Unpin Note" : "Pin Note"
                return noteWin.noteURL != nil
            }
            guard let workspace, NSApp.keyWindow === workspace.window || NSApp.keyWindow == nil else {
                menuItem.title = "Pin Note"
                return false
            }
            menuItem.title = workspace.targetNoteIsPinned ? "Unpin Note" : "Pin Note"
            return workspace.canPinNote
        }
        if menuItem.action == #selector(mergeNotes) {
            guard let workspace,
                  workspace.activeNoteWindowController == nil,
                  NSApp.keyWindow === workspace.window || NSApp.keyWindow == nil else {
                menuItem.title = "Merge Notes…"
                return false
            }
            let count = workspace.selectedNotesForMerge.count
            menuItem.title = count >= 2 ? "Merge \(count) Notes…" : "Merge Notes…"
            return workspace.canMergeNotes
        }
        if menuItem.action == #selector(toggleSemanticConnections) {
            if let noteWin = workspace?.activeNoteWindowController {
                menuItem.state = noteWin.editor.isSemanticConnectionsVisible ? .on : .off
            } else {
                menuItem.state = (workspace?.editor.isSemanticConnectionsVisible == true) ? .on : .off
            }
            return true
        }
        if menuItem.action == #selector(toggleVimMode) {
            menuItem.state = Theme.vimModeEnabled ? .on : .off
            return true
        }
        return true
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
