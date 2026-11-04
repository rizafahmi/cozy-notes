import AppKit
import CozyCore

@MainActor final class QuickCaptureController: NSWindowController, NSWindowDelegate {
    let editor = CaptureEditor(frame: .zero)
    private let vault: Vault
    var onCapture: (() -> Void)?
    private var previousApp: NSRunningApplication?

    init(vault: Vault) {
        self.vault = vault
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Keep a little something"
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = Theme.paper
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 440, height: 280)
        super.init(window: panel)
        panel.delegate = self
        let keep = PrimaryButton()
        keep.title = "Keep capture"
        keep.target = self
        keep.action = #selector(save)
        keep.keyEquivalent = "\r"
        keep.keyEquivalentModifierMask = .command
        let cancel = Theme.button("Close", target: self, action: #selector(hide))
        cancel.toolTip = "Close without clearing your draft (Escape)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Theme.stack([Theme.label("⌘Return to keep · Esc to tuck away", size: 11), spacer, cancel, keep])
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 16, right: 18)
        let layout = Theme.stack([editor, footer], orientation: .vertical, spacing: 0)
        editor.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        if let content = panel.contentView { Theme.fill(layout, in: content) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func summon() {
        if window?.isVisible == true { hide(); return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? frontmost : nil
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        editor.focus()
    }
    @objc func save() {
        guard editor.hasContent else { editor.focus(); return }
        do {
            _ = try vault.capture(text: editor.text, attachments: editor.attachments)
            editor.reset()
            onCapture?()
            hide()
        } catch { showError(error, in: window) }
    }
    @objc func hide() {
        window?.orderOut(nil)
        previousApp?.activate(options: [])
        previousApp = nil
    }
    override func cancelOperation(_ sender: Any?) { hide() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func persistDraft() -> Bool {
        guard editor.hasContent else { return true }
        do {
            _ = try vault.capture(text: editor.text, attachments: editor.attachments)
            editor.reset()
            onCapture?()
            return true
        } catch { showError(error, in: window); return false }
    }
}
