#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
import CozyCore
@testable import CozyNotes

@MainActor
private func makeWhitespaceTestWorkspace() throws -> (workspace: WorkspaceController, window: NSWindow, directory: URL) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyWhitespaceCaretTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let workspace = WorkspaceController(vault: vault)
    guard let window = workspace.window else {
        workspace.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw NSError(domain: "WhitespaceCaretTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing workspace window"])
    }
    window.setContentSize(NSSize(width: 960, height: 680))
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return (workspace, window, directory)
}

@MainActor
private func sendKey(to textView: MarkdownTextView, window: NSWindow, characters: String, keyCode: UInt16) throws {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw NSError(domain: "WhitespaceCaretTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to synthesize keyDown for \(characters.debugDescription)"])
    }
    textView.keyDown(with: event)
}

@MainActor
private func verifyPressingSpaceAdvancesCaretAcrossVoices() throws {
    let savedVoice = Theme.voice
    let savedScale = Theme.fontScale
    let savedVimMode = Theme.vimModeEnabled
    defer {
        Theme.voice = savedVoice
        Theme.fontScale = savedScale
        Theme.vimModeEnabled = savedVimMode
    }

    Theme.fontScale = 0
    Theme.vimModeEnabled = false
    let (workspace, window, directory) = try makeWhitespaceTestWorkspace()
    defer {
        workspace.shutdown()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    let textView = workspace.editor.textView
    for voice in Theme.Voice.allCases {
        Theme.voice = voice
        workspace.newCapture()
        window.contentView?.layoutSubtreeIfNeeded()
        guard window.makeFirstResponder(textView) else {
            throw NSError(domain: "WhitespaceCaretTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not focus editor for voice \(voice)"])
        }

        var previousMinX = textView.currentCaretRect().minX
        let baselineY = textView.currentCaretRect().minY

        for count in 1...15 {
            try sendKey(to: textView, window: window, characters: " ", keyCode: 49)

            let expectedText = String(repeating: " ", count: count)
            guard workspace.editor.text == expectedText else {
                throw NSError(
                    domain: "WhitespaceCaretTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "[\(voice)] After \(count) spaces expected \(expectedText.debugDescription), got \(workspace.editor.text.debugDescription)"]
                )
            }
            let sel = textView.selectedRange()
            guard sel == NSRange(location: count, length: 0) else {
                throw NSError(
                    domain: "WhitespaceCaretTests",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "[\(voice)] After \(count) spaces expected selection {\(count), 0}, got \(sel)"]
                )
            }
            let rect = textView.currentCaretRect()
            guard rect.minX > previousMinX + 0.5 else {
                throw NSError(
                    domain: "WhitespaceCaretTests",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "[\(voice)] Caret snapped back/stalled after \(count) spaces: minX=\(rect.minX) previous=\(previousMinX) rect=\(rect)"]
                )
            }
            guard abs(rect.minY - baselineY) <= 1.0 else {
                throw NSError(
                    domain: "WhitespaceCaretTests",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "[\(voice)] Caret jumped vertically after \(count) spaces: minY=\(rect.minY) baselineY=\(baselineY)"]
                )
            }
            previousMinX = rect.minX
        }
    }
}

@MainActor
private func verifyWhitespaceLineTransitionsAndEditing() throws {
    let savedVoice = Theme.voice
    let savedScale = Theme.fontScale
    let savedVimMode = Theme.vimModeEnabled
    defer {
        Theme.voice = savedVoice
        Theme.fontScale = savedScale
        Theme.vimModeEnabled = savedVimMode
    }

    Theme.fontScale = 0
    Theme.voice = .humanist
    Theme.vimModeEnabled = false
    let (workspace, window, directory) = try makeWhitespaceTestWorkspace()
    defer {
        workspace.shutdown()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    let textView = workspace.editor.textView
    workspace.newCapture()
    window.contentView?.layoutSubtreeIfNeeded()
    guard window.makeFirstResponder(textView) else {
        throw NSError(domain: "WhitespaceCaretTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not focus editor"])
    }

    // 1. Blank line after prose ("Hello\n" + 1...12 spaces) advances monotonically.
    textView.insertText("Hello\n", replacementRange: textView.selectedRange())
    let line2StartRect = textView.currentCaretRect()
    var prevX = line2StartRect.minX
    for count in 1...12 {
        try sendKey(to: textView, window: window, characters: " ", keyCode: 49)
        let rect = textView.currentCaretRect()
        guard rect.minX > prevX + 0.5 else {
            throw NSError(
                domain: "WhitespaceCaretTests",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Line 2 caret snapped after \(count) spaces: minX=\(rect.minX) prevX=\(prevX)"]
            )
        }
        guard abs(rect.minY - line2StartRect.minY) <= 1.0 else {
            throw NSError(
                domain: "WhitespaceCaretTests",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Line 2 caret jumped vertically after \(count) spaces: minY=\(rect.minY) expected=\(line2StartRect.minY)"]
            )
        }
        prevX = rect.minX
    }

    // 2. Typing text after leading spaces restores normal prose attributes, and deleting back to spaces keeps caret at column 5.
    workspace.newCapture()
    window.contentView?.layoutSubtreeIfNeeded()
    let col0X = textView.currentCaretRect().minX
    for _ in 1...5 {
        try sendKey(to: textView, window: window, characters: " ", keyCode: 49)
    }
    let col5BeforeLetterX = textView.currentCaretRect().minX
    guard col5BeforeLetterX > col0X + 10.0 else {
        throw NSError(
            domain: "WhitespaceCaretTests",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Expected 5 spaces to advance > 10pt, got \(col5BeforeLetterX - col0X)"]
        )
    }

    try sendKey(to: textView, window: window, characters: "a", keyCode: 0)
    guard workspace.editor.text == "     a" else {
        throw NSError(domain: "WhitespaceCaretTests", code: 14, userInfo: [NSLocalizedDescriptionKey: "Unexpected text: \(workspace.editor.text.debugDescription)"])
    }
    if let storage = textView.textStorage {
        let color = storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        let kern = (storage.attribute(.kern, at: 5, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        guard color == Theme.ink else {
            throw NSError(domain: "WhitespaceCaretTests", code: 15, userInfo: [NSLocalizedDescriptionKey: "Expected Theme.ink after spaces, got \(String(describing: color))"])
        }
        guard abs(kern - Double(Theme.proseTracking)) < 0.001 else {
            throw NSError(domain: "WhitespaceCaretTests", code: 16, userInfo: [NSLocalizedDescriptionKey: "Expected prose tracking \(Theme.proseTracking) after typing text, got \(kern)"])
        }
    }

    // Delete 'a' back to whitespace-only line "     "
    try sendKey(to: textView, window: window, characters: "\u{7F}", keyCode: 51)
    guard workspace.editor.text == "     " else {
        throw NSError(domain: "WhitespaceCaretTests", code: 17, userInfo: [NSLocalizedDescriptionKey: "Expected 5 spaces after backspace, got \(workspace.editor.text.debugDescription)"])
    }
    let col5AfterDeleteX = textView.currentCaretRect().minX
    guard abs(col5AfterDeleteX - col5BeforeLetterX) <= 1.0 else {
        throw NSError(
            domain: "WhitespaceCaretTests",
            code: 18,
            userInfo: [NSLocalizedDescriptionKey: "Caret snapped after deleting back to whitespace-only line: got \(col5AfterDeleteX), expected ~\(col5BeforeLetterX) (col0=\(col0X))"]
        )
    }

    // 3. Loading a note whose first line is whitespace-only above prose preserves caret position at end of spaces.
    workspace.editor.text = "     \nHello"
    window.contentView?.layoutSubtreeIfNeeded()
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    let loadedLine1Col5X = textView.currentCaretRect().minX
    guard loadedLine1Col5X > col0X + 10.0 else {
        throw NSError(
            domain: "WhitespaceCaretTests",
            code: 19,
            userInfo: [NSLocalizedDescriptionKey: "Loaded whitespace-only line collapsed caret to \(loadedLine1Col5X) (col0=\(col0X))"]
        )
    }

    // 4. Trailing spaces after text ("Hello" + 1...10 spaces) and markdown prefixes ("# ", "> ", "- ") advance monotonically.
    for prefix in ["Hello", "# ", "> ", "- "] {
        workspace.newCapture()
        window.contentView?.layoutSubtreeIfNeeded()
        textView.insertText(prefix, replacementRange: textView.selectedRange())
        var pX = textView.currentCaretRect().minX
        for count in 1...10 {
            try sendKey(to: textView, window: window, characters: " ", keyCode: 49)
            let rect = textView.currentCaretRect()
            guard rect.minX > pX + 0.5 else {
                throw NSError(
                    domain: "WhitespaceCaretTests",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Caret stalled after \(count) spaces following \(prefix.debugDescription): minX=\(rect.minX) prevX=\(pX)"]
                )
            }
            pX = rect.minX
        }
    }

    // 5. Splitting "Hello     " with Return leaves a whitespace-only line 2 whose end caret does not collapse.
    workspace.newCapture()
    window.contentView?.layoutSubtreeIfNeeded()
    textView.insertText("Hello     ", replacementRange: textView.selectedRange())
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    try sendKey(to: textView, window: window, characters: "\r", keyCode: 36)
    guard workspace.editor.text == "Hello\n     " else {
        throw NSError(domain: "WhitespaceCaretTests", code: 21, userInfo: [NSLocalizedDescriptionKey: "Unexpected split text: \(workspace.editor.text.debugDescription)"])
    }
    let splitLine2Col0X = textView.currentCaretRect().minX
    textView.setSelectedRange(NSRange(location: 11, length: 0))
    let splitLine2Col5X = textView.currentCaretRect().minX
    guard splitLine2Col5X > splitLine2Col0X + 10.0 else {
        throw NSError(
            domain: "WhitespaceCaretTests",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: "Split whitespace-only line collapsed caret to \(splitLine2Col5X) (col0=\(splitLine2Col0X))"]
        )
    }

    // 6. Undoing a typed character back to a whitespace-only line preserves caret width.
    workspace.newCapture()
    workspace.editor.text = "     "
    window.contentView?.layoutSubtreeIfNeeded()
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    let beforeUndoLetterX = textView.currentCaretRect().minX
    try sendKey(to: textView, window: window, characters: "x", keyCode: 7)
    guard workspace.editor.text == "     x" else {
        throw NSError(domain: "WhitespaceCaretTests", code: 23, userInfo: [NSLocalizedDescriptionKey: "Expected 5 spaces + x before undo, got \(workspace.editor.text.debugDescription)"])
    }
    textView.undoManager?.undo()
    guard workspace.editor.text == "     " else {
        throw NSError(domain: "WhitespaceCaretTests", code: 23, userInfo: [NSLocalizedDescriptionKey: "Expected 5 spaces after undo, got \(workspace.editor.text.debugDescription)"])
    }
    let afterUndoX = textView.currentCaretRect().minX
    guard abs(afterUndoX - beforeUndoLetterX) <= 1.0 else {
        throw NSError(
            domain: "WhitespaceCaretTests",
            code: 24,
            userInfo: [NSLocalizedDescriptionKey: "Undo back to whitespace-only line snapped caret to \(afterUndoX), expected ~\(beforeUndoLetterX)"]
        )
    }

    // 7. Mixed tabs and spaces on a whitespace-only line advance monotonically.
    workspace.newCapture()
    window.contentView?.layoutSubtreeIfNeeded()
    var tabSpaceX = textView.currentCaretRect().minX
    textView.insertText("\t", replacementRange: textView.selectedRange())
    let afterTabX = textView.currentCaretRect().minX
    guard afterTabX > tabSpaceX + 4.0 else {
        throw NSError(domain: "WhitespaceCaretTests", code: 25, userInfo: [NSLocalizedDescriptionKey: "Tab failed to advance caret: \(afterTabX) vs \(tabSpaceX)"])
    }
    tabSpaceX = afterTabX
    for count in 1...6 {
        try sendKey(to: textView, window: window, characters: " ", keyCode: 49)
        let nextX = textView.currentCaretRect().minX
        guard nextX > tabSpaceX + 0.5 else {
            throw NSError(
                domain: "WhitespaceCaretTests",
                code: 26,
                userInfo: [NSLocalizedDescriptionKey: "Space \(count) after tab collapsed caret: \(nextX) vs \(tabSpaceX)"]
            )
        }
        tabSpaceX = nextX
    }
}

@MainActor
private func verifyVimModeWhitespaceCaret() throws {
    let savedVoice = Theme.voice
    let savedAtmosphere = Theme.atmosphere
    let savedScale = Theme.fontScale
    let savedVimMode = Theme.vimModeEnabled
    defer {
        Theme.voice = savedVoice
        Theme.atmosphere = savedAtmosphere
        Theme.fontScale = savedScale
        Theme.vimModeEnabled = savedVimMode
    }

    Theme.fontScale = 0
    Theme.atmosphere = .neoAcid
    Theme.voice = .humanist
    Theme.vimModeEnabled = true

    let (workspace, window, directory) = try makeWhitespaceTestWorkspace()
    defer {
        workspace.shutdown()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    let textView = workspace.editor.textView
    workspace.newCapture()
    window.contentView?.layoutSubtreeIfNeeded()
    guard window.makeFirstResponder(textView) else {
        throw NSError(domain: "WhitespaceCaretTests", code: 30, userInfo: [NSLocalizedDescriptionKey: "Could not focus editor in Vim mode"])
    }
    guard textView.vim.isEnabled && textView.vim.mode == .insert else {
        throw NSError(domain: "WhitespaceCaretTests", code: 31, userInfo: [NSLocalizedDescriptionKey: "Expected newCapture in Vim mode to start in Insert mode, got \(textView.vim.mode)"])
    }

    // 1. Pressing Space 1...15 times in Vim Insert mode on a new note advances the caret monotonically.
    var prevX = textView.currentCaretRect().minX
    let baseX = prevX
    for count in 1...15 {
        try sendKey(to: textView, window: window, characters: " ", keyCode: 49)
        let rect = textView.currentCaretRect()
        guard rect.minX > prevX + 0.5 else {
            throw NSError(
                domain: "WhitespaceCaretTests",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "[Vim Insert] Caret snapped after \(count) spaces: minX=\(rect.minX) prevX=\(prevX)"]
            )
        }
        prevX = rect.minX
    }

    // 2. Pressing Escape into Vim Normal mode keeps the block cursor at the last space (not column 0).
    try sendKey(to: textView, window: window, characters: "\u{1B}", keyCode: 53)
    guard textView.vim.mode == .normal else {
        throw NSError(domain: "WhitespaceCaretTests", code: 33, userInfo: [NSLocalizedDescriptionKey: "Expected Normal mode after Escape"])
    }
    let normalBlockRect = textView.currentCaretRect()
    guard normalBlockRect.minX > baseX + 20.0 else {
        throw NSError(
            domain: "WhitespaceCaretTests",
            code: 34,
            userInfo: [NSLocalizedDescriptionKey: "[Vim Normal] Block cursor snapped to column 0 on whitespace-only line: minX=\(normalBlockRect.minX) baseX=\(baseX)"]
        )
    }

    // 3. Pressing 'o' from Normal mode on a prose line and typing 1...10 spaces advances monotonically.
    workspace.editor.text = "Hello"
    window.contentView?.layoutSubtreeIfNeeded()
    try sendKey(to: textView, window: window, characters: "o", keyCode: 31)
    guard textView.vim.mode == .insert else {
        throw NSError(domain: "WhitespaceCaretTests", code: 35, userInfo: [NSLocalizedDescriptionKey: "Expected Insert mode after 'o'"])
    }
    var line2X = textView.currentCaretRect().minX
    for count in 1...10 {
        try sendKey(to: textView, window: window, characters: " ", keyCode: 49)
        let rect = textView.currentCaretRect()
        guard rect.minX > line2X + 0.5 else {
            throw NSError(
                domain: "WhitespaceCaretTests",
                code: 36,
                userInfo: [NSLocalizedDescriptionKey: "[Vim o] Caret snapped after \(count) spaces: minX=\(rect.minX) prevX=\(line2X)"]
            )
        }
        line2X = rect.minX
    }
}

#if canImport(XCTest)
@MainActor
final class WhitespaceCaretTests: XCTestCase {
    func testPressingSpaceAdvancesCaretAcrossVoices() throws {
        try verifyPressingSpaceAdvancesCaretAcrossVoices()
    }

    func testWhitespaceLineTransitionsAndEditing() throws {
        try verifyWhitespaceLineTransitionsAndEditing()
    }

    func testVimModeWhitespaceCaret() throws {
        try verifyVimModeWhitespaceCaret()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Whitespace caret stability", .serialized)
    struct WhitespaceCaretSuite {
        @Test("Pressing Space repeatedly in a new document advances the caret across all writing voices")
        @MainActor
        func pressingSpaceAdvancesCaretAcrossVoices() throws {
            try verifyPressingSpaceAdvancesCaretAcrossVoices()
        }

        @Test("Whitespace-only lines, backspace-to-spaces, loaded blank-space lines, and trailing spaces preserve caret position")
        @MainActor
        func whitespaceLineTransitionsAndEditing() throws {
            try verifyWhitespaceLineTransitionsAndEditing()
        }

        @Test("Vim mode Insert, Normal block cursor, and o-open line preserve caret position on whitespace-only lines")
        @MainActor
        func vimModeWhitespaceCaret() throws {
            try verifyVimModeWhitespaceCaret()
        }
    }
}
#endif
