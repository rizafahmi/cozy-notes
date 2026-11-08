import AppKit
import CozyCore

@MainActor final class QuickCaptureController: NSWindowController, NSWindowDelegate {
    let editor = CaptureEditor(frame: .zero)
    private let vault: Vault
    var onCapture: (() -> Void)?
    var onOpenWikiLink: ((WikiLink) -> Void)?
    private var previousApp: NSRunningApplication?

    init(vault: Vault) {
        self.vault = vault
        editor.compactLayout = true
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Capture"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = Theme.paper
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 440, height: 260)
        super.init(window: panel)
        panel.delegate = self
        editor.noteRecordsProvider = { [weak self] in (try? self?.vault.notes()) ?? [] }
        editor.onOpenWikiLink = { [weak self] link in self?.onOpenWikiLink?(link) }

        let headerLabel = Theme.label("Quick capture", size: 11.5, color: Theme.muted)
        let header = NSView()
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 68),
            headerLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 32)
        ])

        let keep = PrimaryButton()
        keep.title = "Keep capture"
        keep.target = self
        keep.action = #selector(save)
        keep.keyEquivalent = "\r"
        keep.keyEquivalentModifierMask = .command
        let cancel = QuietButton(title: "Tuck away", target: self, action: #selector(hide))
        cancel.toolTip = "Close without clearing your draft (Escape)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let hint = Theme.label("⌘Return to keep · Esc to tuck away", size: 11, color: Theme.subtle)
        let footer = Theme.stack([hint, spacer, cancel, keep], spacing: 10)
        footer.edgeInsets = NSEdgeInsets(top: 2, left: 22, bottom: 14, right: 18)
        let layout = Theme.stack([header, editor, footer], orientation: .vertical, spacing: 0)
        header.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
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
