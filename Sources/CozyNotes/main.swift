import AppKit
import CozyCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var workspace: WorkspaceController?
    private var quickCapture: QuickCaptureController?
    private var hotKey: GlobalHotKey?

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
    }
    private func openVault(_ root: URL, persistPreference: Bool = true) throws {
        let vault = try Vault(root: root)
        let nextWorkspace = WorkspaceController(vault: vault)
        let nextQuick = QuickCaptureController(vault: vault)
        nextWorkspace.onChooseFolder = { [weak self] in self?.chooseFolder() }
        nextQuick.onCapture = { [weak nextWorkspace] in nextWorkspace?.refresh() }
        workspace?.shutdown()
        workspace?.window?.orderOut(nil)
        quickCapture?.window?.orderOut(nil)
        workspace = nextWorkspace
        quickCapture = nextQuick
        if persistPreference {
            UserDefaults.standard.set(root.path, forKey: "vaultPath")
        }
    }
    @objc func chooseFolder() {
        guard workspace?.persistCurrent() != false, quickCapture?.persistDraft() != false else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose your local notes folder"
        picker.message = "Choose the same folder you sync with Syncthing. Notes are ordinary Markdown files; attachments stay beside them."
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = "Use this folder"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do { try openVault(url); workspace?.showAndFocus() }
        catch { showError(error, in: workspace?.window) }
    }
    @objc private func newCapture() { workspace?.newCapture(); workspace?.showAndFocus() }
    @objc private func quick() { quickCapture?.summon() }
    @objc private func save() {
        if NSApp.keyWindow === quickCapture?.window { quickCapture?.save() }
        else { workspace?.saveCurrent() }
    }
    @objc private func deleteNote() { workspace?.deleteCurrentNote() }
    @objc private func search() { workspace?.focusSearch(); workspace?.showAndFocus() }
    @objc private func makeSearchable() { workspace?.makeSearchable() }
    @objc private func recovery() { workspace?.showRecovery() }
    @objc private func showWorkspace() { workspace?.showAndFocus() }
    @objc private func toggleSidebar() { workspace?.toggleSidebar(); workspace?.showWindow(nil) }
    @objc private func toggleAppearance() { workspace?.toggleAppearance(); workspace?.showWindow(nil) }
    @objc private func cycleAtmosphere() { workspace?.cycleAtmosphere(); workspace?.showWindow(nil) }
    @objc private func cycleVoice() { workspace?.cycleVoice(); workspace?.showWindow(nil) }
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
        guard workspace?.persistCurrent() != false, quickCapture?.persistDraft() != false else { return .terminateCancel }
        workspace?.shutdown()
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
        add("Save Note", action: #selector(save), key: "s", to: file)
        add("Keep / Save", action: #selector(save), key: "\r", to: file)
        add("Delete Note…", action: #selector(deleteNote), key: "\u{08}", to: file)
        add("Choose Notes Folder…", action: #selector(chooseFolder), key: "o", modifiers: [.command, .shift], to: file)
        add("Open Notes Folder", action: #selector(openFolder), key: "", to: file)
        add("Recovery…", action: #selector(recovery), key: "", to: file)
        add("Make Searchable", action: #selector(makeSearchable), key: "", to: file)
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
        format.addItem(.separator())
        addResponder("Heading 1", action: #selector(MarkdownTextView.toggleHeading1(_:)), key: "1", modifiers: [.command, .option], to: format)
        addResponder("Heading 2", action: #selector(MarkdownTextView.toggleHeading2(_:)), key: "2", modifiers: [.command, .option], to: format)
        addResponder("Heading 3", action: #selector(MarkdownTextView.toggleHeading3(_:)), key: "3", modifiers: [.command, .option], to: format)
        format.addItem(.separator())
        addResponder("Blockquote", action: #selector(MarkdownTextView.toggleBlockquote(_:)), key: ".", modifiers: [.command, .shift], to: format)
        addResponder("Bullet List", action: #selector(MarkdownTextView.toggleBulletList(_:)), key: "8", modifiers: [.command, .shift], to: format)
        addResponder("Numbered List", action: #selector(MarkdownTextView.toggleNumberedList(_:)), key: "7", modifiers: [.command, .shift], to: format)
        addResponder("Checklist", action: #selector(MarkdownTextView.toggleChecklist(_:)), key: "l", modifiers: [.command, .shift], to: format)
        let viewItem = NSMenuItem()
        viewItem.title = "View"
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        bar.addItem(viewItem)
        add("Toggle Sidebar", action: #selector(toggleSidebar), key: "\\", to: view)
        add("Toggle Light / Dark Mode", action: #selector(toggleAppearance), key: "d", modifiers: [.command, .shift], to: view)
        add("Switch Atmosphere (Obsidian / Midnight)", action: #selector(cycleAtmosphere), key: "t", modifiers: [.command, .shift], to: view)
        add("Cycle Writing Font (Avenir / Charter / Iowan / Mono)", action: #selector(cycleVoice), key: "y", modifiers: [.command, .shift], to: view)
        view.addItem(.separator())
        add("Bigger Text", action: #selector(zoomIn), key: "=", to: view)
        add("Smaller Text", action: #selector(zoomOut), key: "-", to: view)
        add("Actual Size", action: #selector(zoomReset), key: "0", to: view)
        view.addItem(.separator())
        add("Focus Editor", action: #selector(captureMode), key: "1", to: view)
        add("Focus Sidebar", action: #selector(findMode), key: "2", to: view)
        add("Search Notes & Files", action: #selector(search), key: "f", to: view)
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
        if menuItem.action == #selector(deleteNote) {
            guard let workspace, NSApp.keyWindow === workspace.window || NSApp.keyWindow == nil else { return false }
            return workspace.canDeleteNote
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
