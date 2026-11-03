import AppKit

@MainActor enum Theme {
    static let canvas = NSColor(calibratedRed: 0.98, green: 0.965, blue: 0.94, alpha: 1)
    static let sidebar = NSColor(calibratedRed: 0.945, green: 0.925, blue: 0.89, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.24, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.47, green: 0.49, blue: 0.44, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.30, green: 0.40, blue: 0.29, alpha: 1)
    static func label(_ text: String, size: CGFloat = 13, color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color ?? muted
        return label
    }
    static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.contentTintColor = accent
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

@MainActor func showError(_ error: Error, in window: NSWindow?) {
    let alert = NSAlert(error: error)
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}
