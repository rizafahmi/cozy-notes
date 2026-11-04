import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor final class MarkdownTextView: NSTextView {
    private let editorUndoManager = UndoManager()
    override var undoManager: UndoManager? { editorUndoManager }
    var onFiles: (([URL]) -> Void)?
    var onClipboardImage: ((Data) -> Void)?
    var placeholder = "What's on your mind?" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 18),
            .foregroundColor: Theme.muted
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
    let status = Theme.label("Just capture. Organize later.", size: 11)
    var onChange: (() -> Void)?
    var attachments: [URL] = [] { didSet { updateAttachments() } }
    var allowsAttachments = true {
        didSet { attachmentButton?.isHidden = !allowsAttachments }
    }
    private var attachmentButton: NSButton?
    private let chips = NSStackView()
    private let attachmentScroll = NSScrollView()
    private var previews: [URL: NSImage] = [:]
    private var temporaryFiles: [URL] = []
    private let heading = try! NSRegularExpression(pattern: "(?m)^#{1,6} .+$")
    private let link = try! NSRegularExpression(pattern: "!?\\[[^\\]\\n]*\\]\\([^\\n]+?\\)")
    private let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.setAccessibilityLabel("Note text")
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
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.accent
        textView.delegate = self
        textView.registerForDraggedTypes([.fileURL])
        textView.onFiles = { [weak self] in self?.addAttachments($0) }
        textView.onClipboardImage = { [weak self] in self?.addClipboardImage($0) }
        scroll.documentView = textView
        let add = Theme.button("Attach…", target: self, action: #selector(chooseAttachments))
        add.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.toolTip = "Attach files or screenshots. You can also paste an image or drop files into the editor."
        add.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingMiddle
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 8
        chips.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        attachmentScroll.documentView = chips
        attachmentScroll.drawsBackground = false
        attachmentScroll.hasHorizontalScroller = true
        attachmentScroll.autohidesScrollers = true
        attachmentScroll.scrollerStyle = .overlay
        attachmentScroll.isHidden = true
        attachmentScroll.setAccessibilityLabel("Captured attachments")
        let footer = Theme.stack([add, status])
        let container = Theme.stack([scroll, attachmentScroll, footer], orientation: .vertical, spacing: 8)
        attachmentButton = add
        container.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 12, right: 14)
        container.alignment = .leading
        Theme.fill(container, in: self)
        scroll.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -28).isActive = true
        attachmentScroll.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        attachmentScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
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
        status.stringValue = "Just capture. Organize later."
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
        previews = previews.filter { attachments.contains($0.key) }
        for (index, url) in attachments.enumerated() {
            let preview = NSImageView()
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.image = thumbnail(for: url) ?? NSWorkspace.shared.icon(forFile: url.path)
            preview.setAccessibilityElement(false)
            preview.widthAnchor.constraint(equalToConstant: 48).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 48).isActive = true
            let name = Theme.label(url.lastPathComponent, size: 12, color: Theme.ink)
            name.font = .systemFont(ofSize: 12, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let kind = Theme.label(url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased(), size: 10)
            let description = Theme.stack([name, kind], orientation: .vertical, spacing: 4)
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 128).isActive = true
            let remove = Theme.button("Remove", target: self, action: #selector(removeAttachment(_:)))
            remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            remove.imagePosition = .imageOnly
            remove.bezelStyle = .inline
            remove.setAccessibilityLabel("Remove \(url.lastPathComponent)")
            remove.toolTip = "Remove \(url.lastPathComponent) from this capture"
            remove.tag = index
            let row = Theme.stack([preview, description, remove], spacing: 8)
            let card = PaperSurface(cornerRadius: 10, color: Theme.canvas, bordered: false)
            Theme.fill(row, in: card, inset: 8)
            card.widthAnchor.constraint(equalToConstant: 236).isActive = true
            card.heightAnchor.constraint(equalToConstant: 68).isActive = true
            chips.addArrangedSubview(card)
        }
        chips.setFrameSize(chips.fittingSize)
        attachmentScroll.isHidden = attachments.isEmpty
    }
    private func thumbnail(for url: URL) -> NSImage? {
        if let cached = previews[url] { return cached }
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 120
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        previews[url] = thumbnail
        return thumbnail
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
            storage.addAttributes([.font: Theme.displayFont(25), .foregroundColor: Theme.ink], range: match.range)
            let separator = (text as NSString).range(of: " ", range: match.range)
            storage.addAttributes([.font: font, .foregroundColor: Theme.muted],
                                  range: NSRange(location: match.range.location, length: separator.location - match.range.location))
        }
        for match in link.matches(in: text, range: range) { storage.addAttribute(.foregroundColor, value: Theme.accent, range: match.range) }
        for match in code.matches(in: text, range: range) { storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: match.range) }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: Theme.ink, .paragraphStyle: paragraph]
    }
}
