import AppKit
import UniformTypeIdentifiers

@MainActor final class MarkdownTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?
    var onClipboardImage: ((Data) -> Void)?
    var placeholder = "A thought, a link, a little thing to keep…" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 18),
            .foregroundColor: Theme.muted.withAlphaComponent(0.65)
        ]
        (placeholder as NSString).draw(in: NSRect(x: textContainerInset.width + 5, y: textContainerInset.height,
                                                width: max(0, bounds.width - 2 * textContainerInset.width - 10), height: 70),
                                     withAttributes: attributes)
    }

    override func paste(_ sender: Any?) {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls)
        } else if NSPasteboard.general.string(forType: .string) == nil,
                  let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            onClipboardImage?(png)
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

@MainActor final class CaptureEditor: NSView, NSTextViewDelegate {
    let textView = MarkdownTextView()
    let status = Theme.label("Markdown · files stay yours", size: 12)
    var onChange: (() -> Void)?
    var attachments: [URL] = [] { didSet { updateAttachments() } }
    var allowsAttachments = true {
        didSet { attachmentButton?.isHidden = !allowsAttachments }
    }
    private var attachmentButton: NSButton?
    private let chips = NSStackView()
    private var temporaryFiles: [URL] = []
    private let heading = try! NSRegularExpression(pattern: "(?m)^#{1,6} .+$")
    private let link = try! NSRegularExpression(pattern: "!?\\[[^\\]\\n]*\\]\\([^\\n]+?\\)")
    private let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.canvas.cgColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 30, height: 30)
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.accent
        textView.delegate = self
        textView.registerForDraggedTypes([.fileURL])
        textView.onFiles = { [weak self] in self?.addAttachments($0) }
        textView.onClipboardImage = { [weak self] in self?.addClipboardImage($0) }
        scroll.documentView = textView
        let add = Theme.button("Attach…", target: self, action: #selector(chooseAttachments))
        add.toolTip = "Attach files or screenshots. You can also paste an image or drop files into the editor."
        add.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingMiddle
        chips.orientation = .vertical
        chips.alignment = .leading
        chips.spacing = 4
        let footer = Theme.stack([add, status])
        let container = Theme.stack([scroll, chips, footer], orientation: .vertical, spacing: 12)
        attachmentButton = add
        container.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 14, right: 14)
        container.alignment = .leading
        Theme.fill(container, in: self)
        scroll.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24).isActive = true
        footer.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        formatMarkdown()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.undoManager?.removeAllActions()
            formatMarkdown()
            textView.needsDisplay = true
        }
    }
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    func focus() { window?.makeFirstResponder(textView) }
    func reset() {
        text = ""
        attachments = []
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles.removeAll()
        status.stringValue = "Markdown · files stay yours"
    }
    func textDidChange(_ notification: Notification) {
        formatMarkdown()
        textView.needsDisplay = true
        onChange?()
    }
    func addAttachments(_ urls: [URL]) {
        guard allowsAttachments else {
            status.stringValue = "Use New capture to save a new attachment."
            return
        }
        for url in urls where url.isFileURL {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue, !attachments.contains(url) {
                attachments.append(url)
            }
        }
        onChange?()
    }
    @objc private func chooseAttachments() {
        guard allowsAttachments else {
            status.stringValue = "Use New capture to save a new attachment."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.addAttachments(panel.urls) }
        }
    }
    private func addClipboardImage(_ data: Data) {
        guard allowsAttachments else {
            status.stringValue = "Use New capture to save a new screenshot."
            return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            temporaryFiles.append(url)
            addAttachments([url])
        } catch { showError(error, in: window) }
    }
    private func updateAttachments() {
        for view in chips.arrangedSubviews { chips.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, url) in attachments.enumerated() {
            let name = Theme.label(url.lastPathComponent, size: 12, color: Theme.ink)
            name.lineBreakMode = .byTruncatingMiddle
            let remove = Theme.button("Remove", target: self, action: #selector(removeAttachment(_:)))
            remove.tag = index
            let row = Theme.stack([name, remove], spacing: 8)
            chips.addArrangedSubview(row)
        }
        chips.isHidden = attachments.isEmpty
    }
    @objc private func removeAttachment(_ sender: NSButton) {
        guard attachments.indices.contains(sender.tag) else { return }
        attachments.remove(at: sender.tag)
        onChange?()
    }
    private func formatMarkdown() {
        guard let storage = textView.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let font = NSFont.systemFont(ofSize: 17)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.ink, .paragraphStyle: paragraph], range: range)
        for match in heading.matches(in: text, range: range) {
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: Theme.accent], range: match.range)
        }
        for match in link.matches(in: text, range: range) { storage.addAttribute(.foregroundColor, value: Theme.accent, range: match.range) }
        for match in code.matches(in: text, range: range) { storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: match.range) }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: Theme.ink, .paragraphStyle: paragraph]
    }
}
