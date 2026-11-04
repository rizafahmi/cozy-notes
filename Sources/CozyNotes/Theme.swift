import AppKit

@MainActor enum Theme {
    private static func adaptive(_ name: String, light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: NSColor.Name("Cozy.\(name)")) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
    static let canvas = adaptive("desk", light: (0.94, 0.925, 0.90), dark: (0.10, 0.105, 0.11))
    static let paper = adaptive("paper", light: (0.995, 0.985, 0.965), dark: (0.155, 0.155, 0.16))
    static let ink = adaptive("ink", light: (0.20, 0.18, 0.175), dark: (0.94, 0.92, 0.88))
    static let muted = adaptive("muted", light: (0.44, 0.405, 0.38), dark: (0.72, 0.69, 0.65))
    static let accent = adaptive("inkAccent", light: (0.70, 0.255, 0.18), dark: (0.97, 0.48, 0.35))
    static let accentSoft = adaptive("accentWash", light: (0.96, 0.885, 0.845), dark: (0.27, 0.175, 0.15))
    static let border = adaptive("edge", light: (0.84, 0.81, 0.765), dark: (0.32, 0.305, 0.29))
    fileprivate static let onAccent = adaptive("onAccent", light: (1, 0.99, 0.97), dark: (0.15, 0.105, 0.09))

    static func displayFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    static func label(_ text: String, size: CGFloat = 13, color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color ?? muted
        return label
    }
    static func symbol(_ name: String, size: CGFloat = 16, color: NSColor? = nil) -> NSImageView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        image.contentTintColor = color ?? accent
        image.setAccessibilityElement(false)
        return image
    }
    static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.contentTintColor = ink
        return button
    }
    static func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .horizontal, spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.distribution = .fill
        stack.spacing = spacing
        stack.alignment = orientation == .vertical ? .leading : .centerY
        return stack
    }
    static func fill(_ view: NSView, in parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}
/// Keep native button tracking, keyboard activation, and accessibility; draw the ink treatment ourselves.
@MainActor final class PrimaryButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .semibold)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: ceil(width) + 36, height: 36)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        let fill = isEnabled ? Theme.accent : Theme.accentSoft
        (cell?.isHighlighted == true ? fill.blended(withFraction: 0.18, of: .black) ?? fill : fill).setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isEnabled ? Theme.onAccent : Theme.muted
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}


/// Resolve semantic colors while drawing, including appearance and contrast changes.
@MainActor final class PaperSurface: NSView {
    private let radius: CGFloat
    private let color: NSColor
    private let bordered: Bool
    init(cornerRadius: CGFloat = 18, color: NSColor? = nil, bordered: Bool = true) {
        radius = cornerRadius
        self.color = color ?? Theme.paper
        self.bordered = bordered
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        path.fill()
        if bordered {
            (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Theme.muted : Theme.border).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor func showError(_ error: Error, in window: NSWindow?) {
    let alert = NSAlert(error: error)
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}
