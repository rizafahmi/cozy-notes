import AppKit
import CozyCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var workspace: WorkspaceController?
    private var quickCapture: QuickCaptureController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenus()
        let arguments = CommandLine.arguments
        let argumentVault: String? = arguments.firstIndex(of: "--vault").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let path = argumentVault ?? ProcessInfo.processInfo.environment["COZY_VAULT"] ?? UserDefaults.standard.string(forKey: "vaultPath")
        let root = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Cozy Notes", isDirectory: true)
        do { try openVault(root) }
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
    private func openVault(_ root: URL) throws {
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
        UserDefaults.standard.set(root.path, forKey: "vaultPath")
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
    @objc private func search() { workspace?.focusSearch(); workspace?.showAndFocus() }
    @objc private func makeSearchable() { workspace?.makeSearchable() }
    @objc private func recovery() { workspace?.showRecovery() }
    @objc private func showWorkspace() { workspace?.showAndFocus() }
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
    private func buildMenus() {
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
        add("New Capture", action: #selector(newCapture), key: "n", to: file)
        add("Quick Capture", action: #selector(quick), key: " ", modifiers: [.command, .shift], to: file)
        add("Keep / Save", action: #selector(save), key: "\r", to: file)
        file.addItem(.separator())
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
        let viewItem = NSMenuItem()
        viewItem.title = "View"
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        bar.addItem(viewItem)
        add("Capture", action: #selector(captureMode), key: "1", to: view)
        add("Find", action: #selector(findMode), key: "2", to: view)
        add("Search Captures", action: #selector(search), key: "f", to: view)
        add("Show Workspace", action: #selector(showWorkspace), key: "", to: view)
        NSApp.mainMenu = bar
    }
    private func add(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
