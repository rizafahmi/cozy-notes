import AppKit

@MainActor enum Theme {
    enum Atmosphere: String, CaseIterable {
        case study = "study"
        case botanical = "botanical"
        case neoAcid = "neoAcid"

        var title: String {
            switch self {
            case .study: return "Obsidian & Ivory"
            case .botanical: return "Midnight Ink & Porcelain"
            case .neoAcid: return "Neo-Acid & Plaster"
            }
        }

        var shortBadge: String {
            switch self {
            case .study: return "OBSIDIAN"
            case .botanical: return "MIDNIGHT"
            case .neoAcid: return "NEO-ACID"
            }
        }
    }
    enum Voice: String, CaseIterable {
        case humanist = "humanist"
        case bookSerif = "bookSerif"
        case editorial = "editorial"
        case typewriter = "typewriter"
        case neoAcid = "neoAcid"

        var title: String {
            switch self {
            case .humanist: return "Humanist Sans (Avenir & New York)"
            case .bookSerif: return "Book Serif (Charter)"
            case .editorial: return "Classic Essay (Iowan Old Style)"
            case .typewriter: return "Typewriter Draft (SF Mono)"
            case .neoAcid: return "Neo-Acid Display (Unbounded & Avenir)"
            }
        }

        var shortBadge: String {
            switch self {
            case .humanist: return "AVENIR"
            case .bookSerif: return "CHARTER"
            case .editorial: return "IOWAN"
            case .typewriter: return "MONO"
            case .neoAcid: return "UNBOUNDED"
            }
        }
    }

    static var atmosphere: Atmosphere = {
        if let saved = UserDefaults.standard.string(forKey: "cozyAtmosphere"),
           let value = Atmosphere(rawValue: saved) {
            return value
        }
        return .study
    }() {
        didSet {
            UserDefaults.standard.set(atmosphere.rawValue, forKey: "cozyAtmosphere")
        }
    }

    static var voice: Voice = {
        if let saved = UserDefaults.standard.string(forKey: "cozyVoice"),
           let value = Voice(rawValue: saved) {
            return value
        }
        return .humanist
    }() {
        didSet {
            UserDefaults.standard.set(voice.rawValue, forKey: "cozyVoice")
        }
    }

    static var fontScale: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "cozyFontScale")
        return saved == 0 ? 0 : min(6, max(-3, CGFloat(saved)))
    }() {
        didSet {
            let clamped = min(6, max(-3, fontScale))
            if fontScale != clamped { fontScale = clamped; return }
            UserDefaults.standard.set(Double(fontScale), forKey: "cozyFontScale")
        }
    }

    static var vimModeEnabled: Bool = {
        UserDefaults.standard.bool(forKey: "cozyVimMode")
    }() {
        didSet {
            UserDefaults.standard.set(vimModeEnabled, forKey: "cozyVimMode")
        }
    }
    private static func adaptive(
        _ name: String,
        studyLight: (CGFloat, CGFloat, CGFloat),
        studyDark: (CGFloat, CGFloat, CGFloat),
        botanicalLight: (CGFloat, CGFloat, CGFloat)? = nil,
        botanicalDark: (CGFloat, CGFloat, CGFloat)? = nil,
        neoAcidLight: (CGFloat, CGFloat, CGFloat)? = nil,
        neoAcidDark: (CGFloat, CGFloat, CGFloat)? = nil
    ) -> NSColor {
        NSColor(name: NSColor.Name("Cozy.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb: (CGFloat, CGFloat, CGFloat)
            switch atmosphere {
            case .study:
                rgb = isDark ? studyDark : studyLight
            case .botanical:
                rgb = isDark ? (botanicalDark ?? studyDark) : (botanicalLight ?? studyLight)
            case .neoAcid:
                rgb = isDark ? (neoAcidDark ?? studyDark) : (neoAcidLight ?? studyLight)
            }
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }

    /// Outer desk & sidebar surface — soft stone-alabaster / plaster in light mode, deep velvet obsidian (#131417), midnight (#0E1218), or obsidian clay (#121519) in dark mode.
    static let canvas = adaptive(
        "desk",
        studyLight: (0.942, 0.938, 0.925),
        studyDark: (0.075, 0.078, 0.090),
        botanicalLight: (0.928, 0.938, 0.955),
        botanicalDark: (0.055, 0.070, 0.098),
        neoAcidLight: (0.925, 0.925, 0.902),
        neoAcidDark: (0.071, 0.082, 0.098)
    )
    /// Inset folio page — clean ivory (#FAF9F6) or raw plaster (#F7F7F5) in light mode, elevated graphite-slate (#1B1D22), nocturnal navy (#141923), or obsidian surface (#1B2026) in dark mode.
    static let paper = adaptive(
        "paper",
        studyLight: (0.988, 0.985, 0.976),
        studyDark: (0.106, 0.112, 0.130),
        botanicalLight: (0.984, 0.988, 0.996),
        botanicalDark: (0.080, 0.100, 0.138),
        neoAcidLight: (0.969, 0.969, 0.961),
        neoAcidDark: (0.106, 0.125, 0.149)
    )
    /// Recessed search bar, code blocks, and attachment cards.
    static let elevated = adaptive(
        "elevated",
        studyLight: (0.958, 0.954, 0.942),
        studyDark: (0.138, 0.145, 0.168),
        botanicalLight: (0.950, 0.958, 0.974),
        botanicalDark: (0.110, 0.136, 0.186),
        neoAcidLight: (1.000, 1.000, 1.000),
        neoAcidDark: (0.133, 0.157, 0.192)
    )
    /// Distinct recessed surface for fenced code blocks and inline code pills.
    static let codeBackground = adaptive(
        "codeBackground",
        studyLight: (0.932, 0.928, 0.915),
        studyDark: (0.068, 0.072, 0.086),
        botanicalLight: (0.924, 0.935, 0.955),
        botanicalDark: (0.050, 0.064, 0.092),
        neoAcidLight: (0.925, 0.925, 0.902),
        neoAcidDark: (0.071, 0.082, 0.098)
    )
    /// Top header strip inside fenced code blocks.
    static let codeHeaderFill = adaptive(
        "codeHeaderFill",
        studyLight: (0.902, 0.896, 0.882),
        studyDark: (0.132, 0.140, 0.164),
        botanicalLight: (0.892, 0.908, 0.935),
        botanicalDark: (0.105, 0.130, 0.180),
        neoAcidLight: (0.886, 0.890, 0.863),
        neoAcidDark: (0.133, 0.157, 0.192)
    )
    /// Crisp border around fenced code blocks and inline code pills.
    static let codeBorder = adaptive(
        "codeBorder",
        studyLight: (0.825, 0.818, 0.800),
        studyDark: (0.215, 0.228, 0.265),
        botanicalLight: (0.805, 0.828, 0.870),
        botanicalDark: (0.180, 0.222, 0.300),
        neoAcidLight: (0.784, 0.796, 0.761),
        neoAcidDark: (0.263, 0.290, 0.337)
    )
    /// Dedicated semantic ink and tinted capsule surface for inline `code` tokens so they stand out from prose.
    static let inlineCodeInk = adaptive(
        "inlineCodeInk",
        studyLight: (0.755, 0.245, 0.195),
        studyDark: (0.955, 0.565, 0.485),
        botanicalLight: (0.180, 0.380, 0.780),
        botanicalDark: (0.555, 0.755, 0.990),
        neoAcidLight: (0.102, 0.231, 0.961),
        neoAcidDark: (0.549, 0.878, 1.000)
    )
    static let inlineCodeFill = adaptive(
        "inlineCodeFill",
        studyLight: (0.958, 0.928, 0.918),
        studyDark: (0.176, 0.146, 0.156),
        botanicalLight: (0.915, 0.938, 0.978),
        botanicalDark: (0.125, 0.165, 0.240),
        neoAcidLight: (0.925, 0.925, 0.902),
        neoAcidDark: (0.133, 0.157, 0.192)
    )
    static let inlineCodeBorder = adaptive(
        "inlineCodeBorder",
        studyLight: (0.885, 0.815, 0.795),
        studyDark: (0.295, 0.225, 0.235),
        botanicalLight: (0.805, 0.855, 0.940),
        botanicalDark: (0.215, 0.285, 0.410),
        neoAcidLight: (0.847, 0.855, 0.827),
        neoAcidDark: (0.263, 0.290, 0.337)
    )
    /// Active commonplace index slip in the sidebar.
    static let selectionFill = adaptive(
        "selectionFill",
        studyLight: (0.988, 0.985, 0.976),
        studyDark: (0.158, 0.166, 0.192),
        botanicalLight: (0.984, 0.988, 0.996),
        botanicalDark: (0.128, 0.158, 0.216),
        neoAcidLight: (0.969, 0.969, 0.961),
        neoAcidDark: (0.133, 0.157, 0.192)
    )
    /// High-presence ink for headings and **bold** spans so structure pops by both luminance and weight.
    static let headingInk = adaptive(
        "headingInk",
        studyLight: (0.085, 0.092, 0.108),
        studyDark: (0.952, 0.958, 0.974),
        botanicalLight: (0.075, 0.095, 0.135),
        botanicalDark: (0.945, 0.960, 0.985),
        neoAcidLight: (0.039, 0.043, 0.051),
        neoAcidDark: (0.906, 0.925, 0.949)
    )
    /// Primary body prose ink — velvety, zero-halation contrast (~11:1 in dark mode) for multi-hour writing comfort.
    static let ink = adaptive(
        "ink",
        studyLight: (0.165, 0.175, 0.195),
        studyDark: (0.848, 0.862, 0.890),
        botanicalLight: (0.140, 0.168, 0.215),
        botanicalDark: (0.838, 0.868, 0.912),
        neoAcidLight: (0.247, 0.271, 0.302),
        neoAcidDark: (0.761, 0.792, 0.839)
    )
    static let muted = adaptive(
        "muted",
        studyLight: (0.420, 0.430, 0.455),
        studyDark: (0.585, 0.605, 0.650),
        botanicalLight: (0.380, 0.420, 0.485),
        botanicalDark: (0.560, 0.615, 0.700),
        neoAcidLight: (0.322, 0.357, 0.396),
        neoAcidDark: (0.549, 0.588, 0.639)
    )
    /// Whisper-quiet Markdown syntax markers (#, *, `) and folio stamps.
    static let subtle = adaptive(
        "subtle",
        studyLight: (0.595, 0.605, 0.630),
        studyDark: (0.395, 0.412, 0.455),
        botanicalLight: (0.555, 0.595, 0.655),
        botanicalDark: (0.365, 0.415, 0.495),
        neoAcidLight: (0.365, 0.404, 0.447),
        neoAcidDark: (0.388, 0.427, 0.478)
    )
    /// Primary accent — refined coral-rose in Obsidian, periwinkle-indigo in Midnight, cobalt/acid in Neo-Acid.
    static let accent = adaptive(
        "inkAccent",
        studyLight: (0.820, 0.310, 0.270),
        studyDark: (0.925, 0.465, 0.420),
        botanicalLight: (0.245, 0.420, 0.825),
        botanicalDark: (0.455, 0.635, 0.965),
        neoAcidLight: (0.102, 0.231, 0.961),
        neoAcidDark: (0.773, 0.973, 0.165)
    )
    /// Secondary accent for completed tasks, saved seal, and file badges — cool celadon/seafoam or Neo-Acid mint.
    static let sage = adaptive(
        "sage",
        studyLight: (0.235, 0.525, 0.455),
        studyDark: (0.425, 0.745, 0.655),
        botanicalLight: (0.195, 0.535, 0.495),
        botanicalDark: (0.385, 0.765, 0.695),
        neoAcidLight: (0.082, 0.451, 0.278),
        neoAcidDark: (0.353, 0.902, 0.478)
    )
    /// Tertiary list-level accent — warm burnished amber in Obsidian, soft amethyst-lavender in Midnight, highlighter violet in Neo-Acid.
    static let bulletTertiary = adaptive(
        "bulletTertiary",
        studyLight: (0.765, 0.495, 0.145),
        studyDark: (0.945, 0.725, 0.345),
        botanicalLight: (0.485, 0.335, 0.785),
        botanicalDark: (0.725, 0.595, 0.965),
        neoAcidLight: (0.357, 0.129, 0.714),
        neoAcidDark: (0.663, 0.518, 1.000)
    )
    /// Highlight wash behind search matches.
    static let accentSoft = adaptive(
        "accentWash",
        studyLight: (0.965, 0.895, 0.885),
        studyDark: (0.255, 0.165, 0.175),
        botanicalLight: (0.885, 0.920, 0.985),
        botanicalDark: (0.145, 0.205, 0.320),
        neoAcidLight: (0.890, 0.976, 0.608),
        neoAcidDark: (0.165, 0.212, 0.094)
    )
    /// Subtle tint for blockquote callout blocks inside the journal page.
    static let quoteWash = adaptive(
        "quoteWash",
        studyLight: (0.962, 0.958, 0.948),
        studyDark: (0.126, 0.133, 0.154),
        botanicalLight: (0.956, 0.964, 0.980),
        botanicalDark: (0.098, 0.122, 0.168),
        neoAcidLight: (0.925, 0.925, 0.902),
        neoAcidDark: (0.133, 0.157, 0.192)
    )
    static let border = adaptive(
        "edge",
        studyLight: (0.855, 0.850, 0.835),
        studyDark: (0.188, 0.198, 0.226),
        botanicalLight: (0.835, 0.855, 0.890),
        botanicalDark: (0.155, 0.190, 0.255),
        neoAcidLight: (0.847, 0.855, 0.827),
        neoAcidDark: (0.204, 0.231, 0.275)
    )
    /// Delicate notebook margin line and dateline rule on the journal page.
    static let marginLine = adaptive(
        "marginLine",
        studyLight: (0.910, 0.905, 0.890),
        studyDark: (0.152, 0.160, 0.184),
        botanicalLight: (0.895, 0.910, 0.938),
        botanicalDark: (0.122, 0.150, 0.205),
        neoAcidLight: (0.886, 0.894, 0.867),
        neoAcidDark: (0.149, 0.173, 0.212)
    )
    /// 1px top catch-light along elevated cards and the folio sheet.
    static let topHighlight = adaptive(
        "topHighlight",
        studyLight: (1.0, 1.0, 1.0),
        studyDark: (0.235, 0.248, 0.282),
        botanicalLight: (1.0, 1.0, 1.0),
        botanicalDark: (0.195, 0.240, 0.320),
        neoAcidLight: (1.0, 1.0, 1.0),
        neoAcidDark: (0.263, 0.290, 0.337)
    )
    /// Calm text-selection highlight inside the editor.
    static let selectionHighlight = adaptive(
        "selectionHighlight",
        studyLight: (0.865, 0.895, 0.955),
        studyDark: (0.215, 0.250, 0.335),
        botanicalLight: (0.845, 0.890, 0.965),
        botanicalDark: (0.185, 0.260, 0.395),
        neoAcidLight: (0.863, 0.894, 1.000),
        neoAcidDark: (0.176, 0.231, 0.102)
    )
    fileprivate static let onAccent = adaptive(
        "onAccent",
        studyLight: (1, 0.99, 0.99),
        studyDark: (0.10, 0.10, 0.12),
        neoAcidLight: (1.0, 1.0, 1.0),
        neoAcidDark: (0.039, 0.043, 0.051)
    )

    static var baseProseSize: CGFloat {
        let base: CGFloat
        switch voice {
        case .humanist, .neoAcid: base = 17.0
        case .bookSerif: base = 17.5
        case .editorial: base = 17.5
        case .typewriter: base = 15.5
        }
        return base + fontScale
    }

    static var proseTracking: CGFloat {
        switch voice {
        case .humanist, .neoAcid: return 0.12
        case .bookSerif: return 0.08
        case .editorial: return 0.10
        case .typewriter: return 0.0
        }
    }

    static func displayFont(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    private static func unboundedHeadingFont(level: Int, size: CGFloat) -> NSFont {
        let scaled = max(14, size - 1.5)
        let preferredName: String
        switch level {
        case 1: preferredName = "Unbounded-ExtraBold"
        case 2: preferredName = "Unbounded-Bold"
        default: preferredName = "Unbounded-SemiBold"
        }
        let fallbackName = level == 1 ? "AvenirNext-Bold" : "AvenirNext-DemiBold"
        return NSFont(name: preferredName, size: scaled)
            ?? NSFont(name: "Unbounded-ExtraBold", size: scaled)
            ?? NSFont(name: fallbackName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .heavy)
    }

    static func headingFont(level: Int) -> NSFont {
        let scale = fontScale
        let size: CGFloat
        switch level {
        case 1: size = 27.5 + scale
        case 2: size = 21.5 + scale
        case 3: size = 18.5 + scale
        default: size = baseProseSize
        }
        switch voice {
        case .humanist:
            if atmosphere == .neoAcid {
                return unboundedHeadingFont(level: level, size: size)
            }
            let name = level == 1 ? "AvenirNext-Bold" : "AvenirNext-DemiBold"
            return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
        case .neoAcid:
            return unboundedHeadingFont(level: level, size: size)
        case .bookSerif:
            return NSFont(name: "Charter-Bold", size: size) ?? displayFont(size, weight: .bold)
        case .editorial:
            return NSFont(name: "IowanOldStyle-Bold", size: size) ?? displayFont(size, weight: .bold)
        case .typewriter:
            return monoFont(size - 1.5, weight: .bold)
        }
    }

    static func italicDisplayFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch voice {
        case .bookSerif:
            if let f = NSFont(name: "Charter-Italic", size: size) { return f }
        case .editorial:
            if let f = NSFont(name: "IowanOldStyle-Italic", size: size) { return f }
        default:
            break
        }
        let serif = displayFont(size, weight: weight)
        let descriptor = serif.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? italicBodyFont(size)
    }

    static func bodyFont(_ size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let pt = size ?? baseProseSize
        let bold = weight == .semibold || weight == .bold || weight == .heavy
        let medium = weight == .medium
        switch voice {
        case .humanist, .neoAcid:
            let name = bold ? "AvenirNext-DemiBold" : (medium ? "AvenirNext-Medium" : "AvenirNext-Regular")
            return NSFont(name: name, size: pt) ?? NSFont.systemFont(ofSize: pt, weight: weight)
        case .bookSerif:
            let name = (bold || medium) ? "Charter-Bold" : "Charter-Roman"
            return NSFont(name: name, size: pt) ?? displayFont(pt, weight: weight)
        case .editorial:
            let name = (bold || medium) ? "IowanOldStyle-Bold" : "IowanOldStyle-Roman"
            return NSFont(name: name, size: pt) ?? displayFont(pt, weight: weight)
        case .typewriter:
            return monoFont(pt, weight: weight)
        }
    }

    static func italicBodyFont(_ size: CGFloat? = nil) -> NSFont {
        let pt = size ?? baseProseSize
        switch voice {
        case .humanist, .neoAcid:
            return NSFont(name: "AvenirNext-Italic", size: pt) ?? NSFont.systemFont(ofSize: pt)
        case .bookSerif:
            return NSFont(name: "Charter-Italic", size: pt) ?? displayFont(pt)
        case .editorial:
            return NSFont(name: "IowanOldStyle-Italic", size: pt) ?? displayFont(pt)
        case .typewriter:
            let base = monoFont(pt)
            return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: pt) ?? base
        }
    }

    static func monoFont(_ size: CGFloat = 14.5, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
    static func label(_ text: String, size: CGFloat = 13, color: NSColor? = nil) -> NSTextField {
        let label = WindowDraggableLabel(labelWithString: text)
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
    static let feedbackTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    static func fade(_ layer: CALayer, to opacity: Float, duration: TimeInterval, from initialOpacity: Float? = nil, completion: (() -> Void)? = nil) {
        let start = initialOpacity ?? layer.presentation()?.opacity ?? layer.opacity
        let fadeDuration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? min(duration, 0.08) : duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        if fadeDuration > 0, abs(start - opacity) > 0.001 {
            if let completion {
                CATransaction.setCompletionBlock {
                    MainActor.assumeIsolated { completion() }
                }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = start
            fade.toValue = opacity
            fade.duration = fadeDuration
            fade.timingFunction = feedbackTimingFunction
            layer.add(fade, forKey: "feedback.opacity")
            CATransaction.commit()
        } else {
            layer.removeAnimation(forKey: "feedback.opacity")
            CATransaction.commit()
            completion?()
        }
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

/// Exit feedback must never intercept input in the space the removed content occupied.
@MainActor final class FeedbackOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Keep native button tracking, keyboard activation, and accessibility; draw the ink treatment ourselves.
@MainActor final class PrimaryButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        isBordered = false
        font = .systemFont(ofSize: 12.5, weight: .semibold)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12.5)]).width
        return NSSize(width: ceil(width) + 32, height: 32)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        let fill = isEnabled ? Theme.accent : Theme.accentSoft
        (cell?.isHighlighted == true ? fill.blended(withFraction: 0.18, of: .black) ?? fill : fill).setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: isEnabled ? Theme.onAccent : Theme.muted
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// Resolve semantic colors while drawing, including appearance and contrast changes.
@MainActor final class PaperSurface: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    private let radius: CGFloat
    private let color: NSColor
    private let bordered: Bool
    init(cornerRadius: CGFloat = 14, color: NSColor? = nil, bordered: Bool = true) {
        radius = cornerRadius
        self.color = color ?? Theme.paper
        self.bordered = bordered
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        if radius == 0 && !bordered {
            bounds.fill()
            return
        }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
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

/// Tactile inset journal folio sitting on the desk with a subtle shadow, top catch-light, and left scholarly margin rule.
@MainActor final class FolioPageSurface: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    var marginX: CGFloat = 56 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()

        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        shadow.set()
        Theme.paper.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Subtle scholarly vertical margin rule on the journal page
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Theme.marginLine.withAlphaComponent(0.65).setFill()
        NSRect(x: max(28, marginX), y: rect.minY, width: 1, height: rect.height).fill()
        // Top catch-light along the folio edge
        Theme.topHighlight.withAlphaComponent(0.55).setFill()
        NSRect(x: rect.minX + 10, y: rect.maxY - 1.5, width: max(0, rect.width - 20), height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()

        (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Theme.muted : Theme.border).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Custom borderless search bar that avoids AppKit's cold system bezel in dark and light appearances.
@MainActor final class CozySearchBar: NSView {
    let field = NSSearchField()
    private let icon = Theme.symbol("magnifyingglass", size: 12, color: Theme.muted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Theme.ink
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        Theme.elevated.setFill()
        path.fill()
        Theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        field.textColor = Theme.ink
        icon.contentTintColor = Theme.muted
        needsDisplay = true
    }
}

/// Trackless scroller so USB mice and offscreen renders never show a system scrollbar gutter on the folio page.
@MainActor final class CozyScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let knobRect = rect(for: .knob).insetBy(dx: 3, dy: 2)
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        Theme.border.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: knobRect.width / 2, yRadius: knobRect.width / 2).fill()
    }
}

@MainActor final class HairlineView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Theme.muted : Theme.border).setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Subtle borderless button with hover and press feedback so utility actions don't shout for attention.
@MainActor final class QuietButton: NSButton {
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    var tint: NSColor = Theme.muted { didSet { contentTintColor = tint; needsDisplay = true } }

    convenience init(title: String = "", symbol: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        if let symbol {
            self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            self.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        contentTintColor = tint
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        if title.isEmpty {
            return NSSize(width: max(28, base.width + 10), height: max(26, base.height + 6))
        }
        return NSSize(width: base.width + 16, height: max(26, base.height + 6))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        if (hovered || pressed) && isEnabled {
            let fill = pressed ? Theme.selectionFill : Theme.elevated
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        contentTintColor = isEnabled ? (hovered || pressed ? Theme.ink : tint) : Theme.subtle
        super.draw(dirtyRect)
    }
}


@MainActor final class WindowDraggableLabel: NSTextField {
    override func mouseDown(with event: NSEvent) {
        if !isEditable && !isSelectable, let window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Subtle semantic mode badge in the editor footer when Vim mode is enabled.
@MainActor final class VimModePill: NSView {
    enum Style: Equatable {
        case normal
        case insert
        case visual
    }

    var badgeText: String = "NORMAL" {
        didSet {
            if badgeText != oldValue {
                invalidateIntrinsicContentSize()
                setAccessibilityValue(badgeText)
                needsDisplay = true
            }
        }
    }

    var style: Style = .normal {
        didSet {
            if style != oldValue { needsDisplay = true }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Vim mode")
        setAccessibilityValue(badgeText)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override var intrinsicContentSize: NSSize {
        let font = Theme.monoFont(9.5, weight: .semibold)
        let width = (badgeText as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 14, height: 19)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let fill: NSColor
        let border: NSColor
        let ink: NSColor
        switch style {
        case .normal:
            fill = Theme.elevated
            border = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Theme.muted : Theme.border
            ink = Theme.muted
        case .insert:
            fill = Theme.accentSoft
            border = Theme.accent.withAlphaComponent(0.45)
            ink = Theme.accent
        case .visual:
            fill = Theme.selectionHighlight
            border = Theme.accent.withAlphaComponent(0.55)
            ink = Theme.headingInk
        }
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let font = Theme.monoFont(9.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
            .kern: 0.35
        ]
        let size = (badgeText as NSString).size(withAttributes: attrs)
        let pt = NSPoint(
            x: round((bounds.width - size.width) * 0.5),
            y: round((bounds.height - size.height) * 0.5)
        )
        (badgeText as NSString).draw(at: pt, withAttributes: attrs)
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
