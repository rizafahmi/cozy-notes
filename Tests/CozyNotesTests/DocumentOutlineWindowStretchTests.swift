#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
import CozyCore
@testable import CozyNotes

private func stretchCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(
            domain: "DocumentOutlineWindowStretchTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private func verifyOutlineWindowStretchGeometry() throws {
    let rail = CaptureEditor.outlineTotalWidth
    try stretchCheck(rail == 229, "Expected outlineTotalWidth to be 229 pt (228 rail + 1 divider), got \(rail)")

    let screen = NSRect(x: 0, y: 25, width: 1728, height: 1055)

    // 1. Standard stretch preserves minX and restores exact frame on close.
    do {
        var state = OutlineWindowStretchState()
        let initial = NSRect(x: 160, y: 120, width: 1060, height: 740)
        let stretched = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: true,
                currentFrame: initial,
                minWidth: 720,
                visibleScreenFrame: screen,
                isFullScreen: false
            ),
            "Expected standard window to stretch"
        )
        try stretchCheck(stretched == NSRect(x: 160, y: 120, width: 1060 + rail, height: 740), "Unexpected stretched frame: \(stretched)")

        let restored = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: false,
                currentFrame: stretched,
                minWidth: 720,
                visibleScreenFrame: screen,
                isFullScreen: false
            ),
            "Expected stretched window to shrink back on close"
        )
        try stretchCheck(restored == initial, "Expected exact restoration to \(initial), got \(restored)")
    }

    // 2. Window near right edge shifts origin.x left to stay inside screen.maxX, then restores on close.
    do {
        var state = OutlineWindowStretchState()
        let narrowScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = NSRect(x: 260, y: 80, width: 1060, height: 740) // maxX = 1320; +229 -> 1549 > 1440
        let stretched = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: true,
                currentFrame: initial,
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: false
            ),
            "Expected right-edge window to stretch and shift left"
        )
        try stretchCheck(stretched == NSRect(x: 151, y: 80, width: 1289, height: 740), "Expected shifted frame (151, 80, 1289, 740), got \(stretched)")

        let restored = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: false,
                currentFrame: stretched,
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: false
            ),
            "Expected right-edge shifted window to restore on close"
        )
        try stretchCheck(restored == initial, "Expected lossless restoration to \(initial), got \(restored)")
    }

    // 3. If user manually drags a shifted window while Outline is open, closing preserves user's new origin.x.
    do {
        var state = OutlineWindowStretchState()
        let narrowScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = NSRect(x: 260, y: 80, width: 1060, height: 740)
        _ = state.frameForVisibilityChange(
            visible: true,
            currentFrame: initial,
            minWidth: 720,
            visibleScreenFrame: narrowScreen,
            isFullScreen: false
        )
        let userMoved = NSRect(x: 40, y: 80, width: 1289, height: 740)
        let closed = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: false,
                currentFrame: userMoved,
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: false
            ),
            "Expected manually moved window to shrink width on close"
        )
        try stretchCheck(closed == NSRect(x: 40, y: 80, width: 1060, height: 740), "Expected user origin.x=40 preserved, got \(closed)")
    }

    // 4. Partial stretch when < 229 pt of screen width remains, and matching partial shrink on close.
    do {
        var state = OutlineWindowStretchState()
        let narrowScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = NSRect(x: 50, y: 60, width: 1340, height: 760)
        let stretched = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: true,
                currentFrame: initial,
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: false
            ),
            "Expected partial stretch up to screen width"
        )
        try stretchCheck(stretched == NSRect(x: 0, y: 60, width: 1440, height: 760), "Expected clamped full-width frame, got \(stretched)")

        let restored = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: false,
                currentFrame: stretched,
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: false
            ),
            "Expected partial stretch to restore original 1340 width"
        )
        try stretchCheck(restored == initial, "Expected exact restoration to \(initial), got \(restored)")
    }

    // 5. Already full screen width or native macOS Full Screen -> no frame change on open or close.
    do {
        var state = OutlineWindowStretchState()
        let narrowScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxed = NSRect(x: 0, y: 0, width: 1440, height: 900)
        try stretchCheck(
            state.frameForVisibilityChange(
                visible: true,
                currentFrame: maxed,
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: false
            ) == nil,
            "Window already spanning full screen width must not stretch"
        )
        try stretchCheck(
            state.frameForVisibilityChange(
                visible: false,
                currentFrame: maxed,
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: false
            ) == nil,
            "Closing Outline after no-op open must leave maxed window untouched"
        )
        try stretchCheck(
            state.frameForVisibilityChange(
                visible: true,
                currentFrame: NSRect(x: 100, y: 100, width: 1060, height: 740),
                minWidth: 720,
                visibleScreenFrame: narrowScreen,
                isFullScreen: true
            ) == nil,
            "Native full-screen window must not stretch"
        )
    }

    // 6. Manual user narrowing while Outline is open respects minWidth on close, and secondary display minX works.
    do {
        var state = OutlineWindowStretchState()
        let secondaryScreen = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        let initial = NSRect(x: 2500, y: 100, width: 1000, height: 700) // maxX = 3500; +229 -> 3729 > 3648
        let stretched = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: true,
                currentFrame: initial,
                minWidth: 720,
                visibleScreenFrame: secondaryScreen,
                isFullScreen: false
            ),
            "Expected stretch on secondary monitor"
        )
        try stretchCheck(stretched == NSRect(x: 2419, y: 100, width: 1229, height: 700), "Unexpected secondary monitor stretch: \(stretched)")

        let userNarrowed = NSRect(x: 2419, y: 100, width: 800, height: 700)
        let closed = try unwrapFrame(
            state.frameForVisibilityChange(
                visible: false,
                currentFrame: userNarrowed,
                minWidth: 720,
                visibleScreenFrame: secondaryScreen,
                isFullScreen: false
            ),
            "Expected shrink clamped to minWidth=720"
        )
        try stretchCheck(closed.width == 720, "Expected width clamped to minWidth 720, got \(closed.width)")
        try stretchCheck(closed.minX >= secondaryScreen.minX && closed.maxX <= secondaryScreen.maxX, "Closed frame escaped secondary monitor: \(closed)")
    }
}

private func unwrapFrame(_ frame: NSRect?, _ message: String) throws -> NSRect {
    guard let frame else {
        throw NSError(domain: "DocumentOutlineWindowStretchTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return frame
}

@MainActor
private func verifyControllersStretchWindowOnOutlineToggle() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyOutlineStretchTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let note = try vault.capture(text: "# Heading One\nParagraph text.\n\n## Heading Two\nMore details.")

    let workspace = WorkspaceController(vault: vault)
    let quick = QuickCaptureController(vault: vault)
    defer {
        quick.window?.orderOut(nil)
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    workspace.openNote(note.url)
    let wsWindow = try unwrapWindow(workspace.window)
    let screenFrame = (wsWindow.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)

    // Pick a deterministic starting frame guaranteed to leave >= 229 pt of headroom inside screenFrame.
    let rail = CaptureEditor.outlineTotalWidth
    let startWidth = min(900, max(wsWindow.minSize.width, screenFrame.width - rail - 80))
    let startFrame = NSRect(x: screenFrame.minX + 24, y: screenFrame.minY + 40, width: startWidth, height: 640)
    wsWindow.setFrame(startFrame, display: false)
    wsWindow.contentView?.layoutSubtreeIfNeeded()
    let scrollWidthBefore = try unwrapCGFloat(workspace.editor.textView.enclosingScrollView?.frame.width, "Expected editor scroll view")
    let columnWidthBefore = try unwrapCGFloat(workspace.editor.textView.textContainer?.containerSize.width, "Expected text container")

    // 1. Toolbar / controller toggle stretches window by +229 pt and preserves editor scroll & column width.
    workspace.toggleOutline()
    try stretchCheck(workspace.editor.isOutlineVisible, "Expected outline visible after toggleOutline()")
    try stretchCheck(abs(wsWindow.frame.width - (startWidth + rail)) < 0.5, "Expected workspace width \(startWidth + rail), got \(wsWindow.frame.width)")
    try stretchCheck(abs(wsWindow.frame.minX - startFrame.minX) < 0.5, "Expected workspace minX anchored at \(startFrame.minX), got \(wsWindow.frame.minX)")
    let scrollWidthAfter = try unwrapCGFloat(workspace.editor.textView.enclosingScrollView?.frame.width, "Expected editor scroll view")
    let columnWidthAfter = try unwrapCGFloat(workspace.editor.textView.textContainer?.containerSize.width, "Expected text container")
    try stretchCheck(abs(scrollWidthAfter - scrollWidthBefore) < 1.0, "Expected editor scroll width preserved (\(scrollWidthBefore)), got \(scrollWidthAfter)")
    try stretchCheck(abs(columnWidthAfter - columnWidthBefore) < 1.0, "Expected text column width preserved (\(columnWidthBefore)), got \(columnWidthAfter)")
    try stretchCheck(abs((workspace.baseWindowFrameForReplacement()?.width ?? 0) - startWidth) < 0.5, "Replacement base frame must strip temporary outline stretch")

    // 2. Clicking the outline rail's close action shrinks the window back.
    workspace.editor.outlineView.onClose?()
    try stretchCheck(!workspace.editor.isOutlineVisible, "Expected outline hidden after close callback")
    try stretchCheck(abs(wsWindow.frame.width - startWidth) < 0.5, "Expected workspace width restored to \(startWidth), got \(wsWindow.frame.width)")

    // 3. Direct ⌥⌘\ key equivalent inside MarkdownTextView stretches and restores window width.
    if let shortcutEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .option],
        timestamp: 0,
        windowNumber: wsWindow.windowNumber,
        context: nil,
        characters: "\\",
        charactersIgnoringModifiers: "\\",
        isARepeat: false,
        keyCode: 42
    ) {
        let handledOpen = workspace.editor.textView.performKeyEquivalent(with: shortcutEvent)
        try stretchCheck(handledOpen && workspace.editor.isOutlineVisible, "Expected ⌥⌘\\ to show Document Outline")
        try stretchCheck(abs(wsWindow.frame.width - (startWidth + rail)) < 0.5, "Expected ⌥⌘\\ to stretch workspace width to \(startWidth + rail), got \(wsWindow.frame.width)")

        let handledClose = workspace.editor.textView.performKeyEquivalent(with: shortcutEvent)
        try stretchCheck(handledClose && !workspace.editor.isOutlineVisible, "Expected second ⌥⌘\\ to hide Document Outline")
        try stretchCheck(abs(wsWindow.frame.width - startWidth) < 0.5, "Expected second ⌥⌘\\ to restore workspace width to \(startWidth), got \(wsWindow.frame.width)")
    }

    // 4. Full-screen-width workspace window does not exceed screen.visibleFrame.width.
    let fullWidthFrame = NSRect(x: screenFrame.minX, y: screenFrame.minY + 40, width: screenFrame.width, height: 640)
    wsWindow.setFrame(fullWidthFrame, display: false)
    workspace.toggleOutline()
    try stretchCheck(workspace.editor.isOutlineVisible, "Expected outline visible on full-width window")
    try stretchCheck(abs(wsWindow.frame.width - screenFrame.width) < 0.5, "Full-width window must stay at \(screenFrame.width), got \(wsWindow.frame.width)")
    workspace.toggleOutline()
    try stretchCheck(abs(wsWindow.frame.width - screenFrame.width) < 0.5, "Closing outline on full-width window must keep \(screenFrame.width), got \(wsWindow.frame.width)")

    // 5. Standalone NoteWindowController and QuickCaptureController also stretch and restore.
    guard let noteWinController = workspace.openNoteInNewWindow(note.url) else {
        throw NSError(domain: "DocumentOutlineWindowStretchTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Expected openNoteInNewWindow to return NoteWindowController"])
    }
    let noteWindow = try unwrapWindow(noteWinController.window)
    let noteStartWidth = min(680, max(noteWindow.minSize.width, screenFrame.width - rail - 80))
    noteWindow.setFrame(NSRect(x: screenFrame.minX + 30, y: screenFrame.minY + 60, width: noteStartWidth, height: 560), display: false)
    noteWinController.toggleOutline()
    try stretchCheck(abs(noteWindow.frame.width - (noteStartWidth + rail)) < 0.5, "Expected standalone note window to stretch to \(noteStartWidth + rail), got \(noteWindow.frame.width)")
    noteWinController.toggleOutline()
    try stretchCheck(abs(noteWindow.frame.width - noteStartWidth) < 0.5, "Expected standalone note window to shrink back to \(noteStartWidth), got \(noteWindow.frame.width)")

    let quickWindow = try unwrapWindow(quick.window)
    let quickStartWidth = min(560, max(quickWindow.minSize.width, screenFrame.width - rail - 80))
    quickWindow.setFrame(NSRect(x: screenFrame.minX + 40, y: screenFrame.minY + 80, width: quickStartWidth, height: 360), display: false)
    quick.editor.toggleOutline()
    try stretchCheck(abs(quickWindow.frame.width - (quickStartWidth + rail)) < 0.5, "Expected Quick Capture panel to stretch to \(quickStartWidth + rail), got \(quickWindow.frame.width)")
    quick.editor.toggleOutline()
    try stretchCheck(abs(quickWindow.frame.width - quickStartWidth) < 0.5, "Expected Quick Capture panel to shrink back to \(quickStartWidth), got \(quickWindow.frame.width)")

    // 6. Close button tooltip reflects ⌥⌘\ shortcut.
    let closeButtons = workspace.editor.outlineView.subviews
        .flatMap { [$0] + $0.subviews }
        .filter { $0.accessibilityLabel() == "Hide Outline" }
    try stretchCheck(closeButtons.first?.toolTip == "Hide Outline (⌥⌘\\)", "Expected Hide Outline tooltip to list ⌥⌘\\, got \(String(describing: closeButtons.first?.toolTip))")
}

private func unwrapWindow(_ window: NSWindow?) throws -> NSWindow {
    guard let window else {
        throw NSError(domain: "DocumentOutlineWindowStretchTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected controller to own an NSWindow"])
    }
    return window
}

private func unwrapCGFloat(_ value: CGFloat?, _ message: String) throws -> CGFloat {
    guard let value else {
        throw NSError(domain: "DocumentOutlineWindowStretchTests", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return value
}

#if canImport(XCTest)
@MainActor
final class DocumentOutlineWindowStretchTests: XCTestCase {
    func testOutlineWindowStretchGeometry() throws {
        try verifyOutlineWindowStretchGeometry()
    }

    func testControllersStretchWindowOnOutlineToggle() throws {
        try verifyControllersStretchWindowOnOutlineToggle()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Document outline window stretch", .serialized)
    struct DocumentOutlineWindowStretchSuite {
        @Test("OutlineWindowStretchState stretches, shifts at screen edge, clamps at full width, and restores reversibly")
        func outlineWindowStretchGeometry() throws {
            try verifyOutlineWindowStretchGeometry()
        }

        @Test("Workspace, standalone Note window, and Quick Capture stretch and restore window width across all Outline toggles")
        @MainActor
        func controllersStretchWindowOnOutlineToggle() throws {
            try verifyControllersStretchWindowOnOutlineToggle()
        }
    }
}
#endif
