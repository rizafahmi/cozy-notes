#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
@testable import CozyCore
@testable import CozyNotes

@MainActor
private func listCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(
            domain: "ListContinuationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
private struct ListContinuationFixture {
    let rootDir: URL
    let vaultRoot: URL
    let historyRoot: URL
    let vault: Vault
    let previousVimMode: Bool

    init() throws {
        _ = NSApplication.shared
        previousVimMode = Theme.vimModeEnabled
        Theme.vimModeEnabled = false
        rootDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyListContinuationTests-\(UUID().uuidString)", isDirectory: true)
        vaultRoot = rootDir.appendingPathComponent("Vault", isDirectory: true)
        historyRoot = rootDir.appendingPathComponent("LocalHistory", isDirectory: true)
        vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
    }

    func cleanup() {
        Theme.vimModeEnabled = previousVimMode
        try? FileManager.default.removeItem(at: rootDir)
    }
}

@MainActor
private func dispatchReturnKey(
    modifiers: NSEvent.ModifierFlags = [],
    keyCode: UInt16 = 36,
    characters: String = "\r",
    in window: NSWindow
) throws {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw NSError(domain: "ListContinuationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to construct Return NSEvent"])
    }
    if !modifiers.isEmpty, window.performKeyEquivalent(with: event) {
        return
    }
    window.sendEvent(event)
}

@MainActor
private func dispatchCharKey(_ chars: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: chars,
        charactersIgnoringModifiers: chars,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw NSError(domain: "ListContinuationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to construct key NSEvent"])
    }
    if modifiers.contains(.command) || modifiers.contains(.control) {
        if window.performKeyEquivalent(with: event) {
            return
        }
    }
    window.sendEvent(event)
}

@MainActor
private func verifyNumberedBulletsNestingEmptyExitUnicodeAndUndoRedo() throws {
    let fixture = try ListContinuationFixture()
    let workspace = WorkspaceController(vault: fixture.vault)
    defer {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        fixture.cleanup()
    }
    guard let window = workspace.window else {
        throw NSError(domain: "ListContinuationTests", code: 4, userInfo: nil)
    }
    window.setFrame(NSRect(x: 0, y: 0, width: 960, height: 700), display: false)
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    let editor = workspace.editor
    let textView = editor.textView
    try listCheck(window.makeFirstResponder(textView), "Expected editor textView to become first responder")

    guard let um = textView.undoManager else {
        throw NSError(domain: "ListContinuationTests", code: 5, userInfo: nil)
    }
    let prevGroupsByEvent = um.groupsByEvent
    um.groupsByEvent = false
    defer { um.groupsByEvent = prevGroupsByEvent }

    func performDiscrete(_ body: () throws -> Void) throws {
        um.beginUndoGrouping()
        defer { um.endUndoGrouping() }
        try body()
    }

    // 1. Ordered list continuation (`1. line 1` -> `2. `, `9. -> 10.`, no renumbering of other lines) + single-step Undo/Redo
    editor.text = "1. line 1"
    um.removeAllActions()
    textView.setSelectedRange(NSRange(location: 9, length: 0))
    try performDiscrete {
        try dispatchReturnKey(in: window)
    }
    try listCheck(editor.text == "1. line 1\n2. ", "Expected '1. line 1\\n2. ', got \(editor.text.debugDescription)")
    try listCheck(textView.selectedRange() == NSRange(location: 13, length: 0), "Expected caret at (13, 0), got \(textView.selectedRange())")
    try listCheck(textView.bulletItems.count == 2 && textView.bulletItems.allSatisfy { $0.kind == .ordered }, "Expected 2 ordered bullet items")

    // Move cursor away before Undo/Redo to verify exact selection restoration on both Undo and Redo
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    um.undo()
    try listCheck(editor.text == "1. line 1", "Single Undo must remove both newline and '2. ', got \(editor.text.debugDescription)")
    try listCheck(textView.selectedRange() == NSRange(location: 9, length: 0), "Undo must restore caret to (9, 0), got \(textView.selectedRange())")
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    um.redo()
    try listCheck(editor.text == "1. line 1\n2. ", "Redo must restore '1. line 1\\n2. ', got \(editor.text.debugDescription)")
    try listCheck(textView.selectedRange() == NSRange(location: 13, length: 0), "Redo must restore caret to (13, 0), got \(textView.selectedRange())")

    // `9. -> 10.` rollover and non-renumbering of existing lines below
    editor.text = "9. ninth item\n2. untouched below"
    um.removeAllActions()
    textView.setSelectedRange(NSRange(location: 13, length: 0))
    try performDiscrete {
        try dispatchReturnKey(in: window)
    }
    try listCheck(
        editor.text == "9. ninth item\n10. \n2. untouched below",
        "Expected '9. -> 10.' without renumbering following line, got \(editor.text.debugDescription)"
    )
    try listCheck(textView.selectedRange() == NSRange(location: 18, length: 0), "Expected caret after '10. ' at (18, 0), got \(textView.selectedRange())")

    // 2. Unordered markers (`-`, `*`, `+`) and preserved spaces/tabs nesting + empty-item exit
    for (marker, indent) in [("-", ""), ("*", "  "), ("+", "\t\t")] {
        let initial = "\(indent)\(marker) first entry"
        editor.text = initial
        um.removeAllActions()
        let initialLen = (initial as NSString).length
        textView.setSelectedRange(NSRange(location: initialLen, length: 0))

        try performDiscrete {
            try dispatchReturnKey(in: window)
        }
        let continued = "\(initial)\n\(indent)\(marker) "
        let continuedLen = (continued as NSString).length
        try listCheck(editor.text == continued, "Expected continued list \(continued.debugDescription), got \(editor.text.debugDescription)")
        try listCheck(textView.selectedRange() == NSRange(location: continuedLen, length: 0), "Expected caret after space at \(continuedLen)")
        try listCheck(textView.bulletItems.count == 2, "Expected 2 unordered bullet items for marker '\(marker)'")

        // Second Return on empty item removes marker + separator, preserving indentation on blank line
        try performDiscrete {
            try dispatchReturnKey(in: window)
        }
        let exited = "\(initial)\n\(indent)"
        let exitedLen = (exited as NSString).length
        try listCheck(editor.text == exited, "Expected empty-item exit \(exited.debugDescription), got \(editor.text.debugDescription)")
        try listCheck(textView.selectedRange() == NSRange(location: exitedLen, length: 0), "Expected caret at preserved indent \(exitedLen)")
        try listCheck(textView.bulletItems.count == 1, "Empty-item exit must clear bullet decoration on exited line")

        if !indent.isEmpty, let storage = textView.textStorage {
            let indentLoc = initialLen + 1
            let fg = storage.attribute(.foregroundColor, at: indentLoc, effectiveRange: nil) as? NSColor
            let para = storage.attribute(.paragraphStyle, at: indentLoc, effectiveRange: nil) as? NSParagraphStyle
            try listCheck(fg == Theme.ink, "Remaining indentation on blank line should restore Theme.ink, got \(String(describing: fg))")
            try listCheck((para?.headIndent ?? 0) == 0, "Remaining indentation on blank line should clear list headIndent, got \(String(describing: para?.headIndent))")
        }

        // Undo empty-item exit restores marker + separator and caret; Undo continuation restores single line
        um.undo()
        try listCheck(editor.text == continued && textView.selectedRange() == NSRange(location: continuedLen, length: 0), "Undo after exit must restore continued prefix and caret")
        um.redo()
        try listCheck(editor.text == exited && textView.selectedRange() == NSRange(location: exitedLen, length: 0), "Redo must re-apply empty-item exit and caret")
        um.undo()
        um.undo()
        try listCheck(editor.text == initial && textView.selectedRange() == NSRange(location: initialLen, length: 0), "Second Undo must restore initial list item and caret")
    }

    // 3. Unicode before caret (decomposed accents, astral emoji, ZWJ sequence, CJK) + CRLF line endings
    let unicodeLine = "- Café e\u{0301} 🦀 👨‍👩‍👧‍👦 日本語"
    editor.text = unicodeLine
    um.removeAllActions()
    let utf16Len = (unicodeLine as NSString).length
    try listCheck(utf16Len != unicodeLine.count, "Unicode fixture must exercise UTF-16 != Character.count (\(utf16Len) vs \(unicodeLine.count))")
    textView.setSelectedRange(NSRange(location: utf16Len, length: 0))
    try performDiscrete {
        try dispatchReturnKey(in: window)
    }
    let expectedUnicode = unicodeLine + "\n- "
    let expectedUnicodeLen = (expectedUnicode as NSString).length
    try listCheck(editor.text == expectedUnicode, "Unicode list continuation corrupted text: \(editor.text.debugDescription)")
    try listCheck(textView.selectedRange() == NSRange(location: expectedUnicodeLen, length: 0), "Unicode caret mismatch: \(textView.selectedRange()) vs \(expectedUnicodeLen)")
    um.undo()
    try listCheck(editor.text == unicodeLine && textView.selectedRange() == NSRange(location: utf16Len, length: 0), "Unicode Undo must restore exact UTF-16 text and caret")

    // CRLF preservation without splitting \r\n or corrupting surrounding lines
    editor.text = "  1. first crlf\r\nTrailing paragraph\r\n"
    um.removeAllActions()
    textView.setSelectedRange(NSRange(location: 15, length: 0))
    try performDiscrete {
        try dispatchReturnKey(in: window)
    }
    try listCheck(
        editor.text == "  1. first crlf\r\n  2. \r\nTrailing paragraph\r\n",
        "CRLF continuation must preserve \\r\\n and surrounding text, got \(editor.text.debugDescription)"
    )
    try listCheck(textView.selectedRange() == NSRange(location: 22, length: 0), "CRLF continuation caret expected (22, 0), got \(textView.selectedRange())")
    try performDiscrete {
        try dispatchReturnKey(in: window)
    }
    try listCheck(
        editor.text == "  1. first crlf\r\n  \r\nTrailing paragraph\r\n",
        "CRLF empty-item exit must preserve indent and \\r\\n, got \(editor.text.debugDescription)"
    )
    try listCheck(textView.selectedRange() == NSRange(location: 19, length: 0), "CRLF empty-item exit caret expected (19, 0), got \(textView.selectedRange())")
}

@MainActor
private func verifyExclusionsAutocompleteShortcutsCompositionVimAndSharedEditors() throws {
    let fixture = try ListContinuationFixture()
    let targetNote = try fixture.vault.capture(text: "# Field Research\nNotes.")
    let sourceNote = try fixture.vault.capture(text: "- Seed")
    let workspace = WorkspaceController(vault: fixture.vault)
    var noteWindow: NoteWindowController?
    let quickCapture = QuickCaptureController(vault: fixture.vault)
    defer {
        noteWindow?.close()
        quickCapture.window?.orderOut(nil)
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        fixture.cleanup()
    }

    guard let window = workspace.window else {
        throw NSError(domain: "ListContinuationTests", code: 10, userInfo: nil)
    }
    window.setFrame(NSRect(x: 0, y: 0, width: 960, height: 700), display: false)
    window.makeKeyAndOrderFront(nil)
    workspace.openNote(sourceNote.url)
    window.layoutIfNeeded()
    let editor = workspace.editor
    let textView = editor.textView
    _ = window.makeFirstResponder(textView)

    // 1. Exclusions: plain prose, numbers in prose, non-dot parens, checklists
    let plainNewlineCases = [
        "Ordinary prose sentence",
        "We met at 1. pm sharp",
        "In 2026. a milestone",
        "Pi is roughly 3.14159",
        "1) parenthesis marker",
        "- [ ] unchecked task",
        "- [x] completed task",
        "1. [ ] numbered task",
        "- [ ] "
    ]
    for line in plainNewlineCases {
        editor.text = line
        let len = (line as NSString).length
        textView.setSelectedRange(NSRange(location: len, length: 0))
        try dispatchReturnKey(in: window)
        try listCheck(
            editor.text == line + "\n",
            "Expected ordinary newline for \(line.debugDescription), got \(editor.text.debugDescription)"
        )
        try listCheck(
            textView.selectedRange() == NSRange(location: len + 1, length: 0),
            "Expected caret at \(len + 1) for \(line.debugDescription), got \(textView.selectedRange())"
        )
    }

    // 2. Exclusions: non-empty selection at end of item, and Return inside an item
    editor.text = "- replace tail"
    textView.setSelectedRange(NSRange(location: 10, length: 4)) // "tail"
    try dispatchReturnKey(in: window)
    try listCheck(editor.text == "- replace \n", "Selection replacement on Return must not continue list, got \(editor.text.debugDescription)")
    try listCheck(textView.selectedRange() == NSRange(location: 11, length: 0), "Expected caret at (11, 0) after replacing selection")

    editor.text = "- split middle"
    textView.setSelectedRange(NSRange(location: 7, length: 0)) // after "- split"
    try dispatchReturnKey(in: window)
    try listCheck(editor.text == "- split\n middle", "Return inside an item must keep ordinary newline behavior, got \(editor.text.debugDescription)")

    // 3. Exclusions: closed and unclosed fenced code blocks
    let closedFence = "```markdown\n- code list item\n```"
    editor.text = closedFence
    let codeItemEnd = (closedFence as NSString).range(of: "- code list item").upperBound
    textView.setSelectedRange(NSRange(location: codeItemEnd, length: 0))
    try dispatchReturnKey(in: window)
    try listCheck(
        editor.text == "```markdown\n- code list item\n\n```",
        "Return inside closed fenced code must not continue list, got \(editor.text.debugDescription)"
    )

    let unclosedFence = "```markdown\n1. unclosed code item"
    editor.text = unclosedFence
    textView.setSelectedRange(NSRange(location: (unclosedFence as NSString).length, length: 0))
    try dispatchReturnKey(in: window)
    try listCheck(
        editor.text == "```markdown\n1. unclosed code item\n",
        "Return inside unclosed fenced code must not continue list, got \(editor.text.debugDescription)"
    )

    // 4. Modified-Return shortcuts (`Shift+Return` soft newline; `⌘Return` opens WikiLink on list item)
    editor.text = "- soft break line"
    textView.setSelectedRange(NSRange(location: editor.nsText.length, length: 0))
    try dispatchReturnKey(modifiers: [.shift], in: window)
    try listCheck(editor.text == "- soft break line\n", "Shift+Return must insert newline without continuing list, got \(editor.text.debugDescription)")

    // 5. WikiLink autocomplete acceptance on a list item (`[[Field` + Return commits link, next Return continues list)
    editor.text = "- Read "
    textView.setSelectedRange(NSRange(location: editor.nsText.length, length: 0))
    textView.insertText("[[Field", replacementRange: textView.selectedRange())
    try listCheck(editor.isWikiAutocompleteVisible, "Expected [[WikiLink]] autocomplete popup on list line")
    try dispatchReturnKey(in: window)
    try listCheck(!editor.isWikiAutocompleteVisible, "Return must accept and dismiss [[WikiLink]] autocomplete")
    try listCheck(editor.text == "- Read [[Field Research]]", "Return during autocomplete must commit [[Field Research]], got \(editor.text.debugDescription)")
    try dispatchReturnKey(in: window)
    try listCheck(editor.text == "- Read [[Field Research]]\n- ", "Subsequent plain Return at end of list item must continue list")

    // `⌘Return` inside `[[Field Research]]` on a list line still opens the target note
    textView.setSelectedRange(NSRange(location: 12, length: 0))
    try dispatchReturnKey(modifiers: [.command], in: window)
    try listCheck(workspace.noteURL == targetNote.url, "⌘Return on [[WikiLink]] inside list item must navigate to target note")

    // 6. Marked-text IME composition intact: Return while marked text is active must never insert a list continuation prefix
    workspace.openNote(sourceNote.url)
    _ = window.makeFirstResponder(textView)
    editor.text = "- Caf"
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    textView.setMarkedText("e\u{0301}", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 5, length: 0))
    try listCheck(textView.hasMarkedText(), "Expected active marked text")
    try dispatchReturnKey(in: window)
    try listCheck(
        !editor.text.contains("\n- "),
        "Return during active marked-text composition must not continue list, got \(editor.text.debugDescription)"
    )
    if textView.hasMarkedText() {
        textView.insertText("é", replacementRange: textView.markedRange())
    }
    try listCheck(!textView.hasMarkedText(), "Expected marked text to be committed")

    // 7. Vim Normal mode intact vs Vim Insert mode continuation + atomic Insert-session undo coalescing
    Theme.vimModeEnabled = true
    editor.syncVimModePreference()
    editor.text = "1. alpha\n   next line"
    textView.vim.resetForLoadedDocument(isEmpty: false)
    if let um = textView.undoManager { um.removeAllActions() }
    try listCheck(textView.vim.mode == .normal, "Expected Vim Normal mode")
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    try dispatchReturnKey(in: window) // Normal-mode <CR>: moves to first non-blank on next line (index 12 'n')
    try listCheck(editor.text == "1. alpha\n   next line", "Vim Normal-mode Return must not mutate list text")
    try listCheck(textView.selectedRange() == NSRange(location: 12, length: 0), "Vim Normal-mode Return should move to first non-blank on next line, got \(textView.selectedRange())")

    // Enter Insert mode at end of line 1 (`gg` -> `A`), continue list, type item 2, continue to 3., exit empty 3., Esc, single `u`
    editor.text = "1. alpha"
    textView.vim.resetForLoadedDocument(isEmpty: false)
    if let um = textView.undoManager { um.removeAllActions() }
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    try dispatchCharKey("A", in: window)
    try listCheck(textView.vim.mode == .insert, "Expected Vim Insert mode after 'A'")
    try dispatchReturnKey(in: window)
    try listCheck(editor.text == "1. alpha\n2. ", "Vim Insert-mode Return should continue list to '2. ', got \(editor.text.debugDescription)")
    for ch in "beta" {
        try dispatchCharKey(String(ch), in: window)
    }
    try dispatchReturnKey(in: window)
    try listCheck(editor.text == "1. alpha\n2. beta\n3. ", "Second Return in Vim Insert should continue to '3. '")
    try dispatchReturnKey(in: window)
    try listCheck(editor.text == "1. alpha\n2. beta\n", "Third Return on empty '3. ' in Vim Insert should exit list")
    try dispatchCharKey("\u{1B}", keyCode: 53, in: window)
    try listCheck(textView.vim.mode == .normal, "Expected Normal mode after Esc")
    try dispatchCharKey("u", in: window)
    try listCheck(editor.text == "1. alpha", "Single 'u' in Vim Normal mode must undo entire Insert session including list continuations, got \(editor.text.debugDescription)")

    Theme.vimModeEnabled = false
    editor.syncVimModePreference()

    // 8. Shared editor agreement across standalone NoteWindowController and QuickCaptureController
    workspace.openNoteInNewWindow(sourceNote.url)
    guard let companion = workspace.noteWindows.first, let companionWindow = companion.window else {
        throw NSError(domain: "ListContinuationTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "Missing standalone NoteWindowController"])
    }
    noteWindow = companion
    companionWindow.makeKeyAndOrderFront(nil)
    _ = companionWindow.makeFirstResponder(companion.editor.textView)
    companion.editor.text = "1. standalone one"
    companion.editor.textView.setSelectedRange(NSRange(location: companion.editor.nsText.length, length: 0))
    try dispatchReturnKey(in: companionWindow)
    try listCheck(companion.editor.text == "1. standalone one\n2. ", "Standalone NoteWindowController must continue ordered list")

    guard let qcWindow = quickCapture.window else {
        throw NSError(domain: "ListContinuationTests", code: 12, userInfo: nil)
    }
    qcWindow.makeKeyAndOrderFront(nil)
    _ = qcWindow.makeFirstResponder(quickCapture.editor.textView)
    quickCapture.editor.text = "- quick item"
    quickCapture.editor.textView.setSelectedRange(NSRange(location: quickCapture.editor.nsText.length, length: 0))
    try dispatchReturnKey(in: qcWindow)
    try listCheck(quickCapture.editor.text == "- quick item\n- ", "QuickCaptureController must continue bullet list on plain Return")
}

#if canImport(XCTest)
@MainActor
final class ListContinuationTests: XCTestCase {
    func testNumberedBulletsNestingEmptyExitUnicodeAndUndoRedo() throws {
        try verifyNumberedBulletsNestingEmptyExitUnicodeAndUndoRedo()
    }

    func testExclusionsAutocompleteShortcutsCompositionVimAndSharedEditors() throws {
        try verifyExclusionsAutocompleteShortcutsCompositionVimAndSharedEditors()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("List Continuation", .serialized)
    @MainActor
    struct ListContinuationSuite {
        @Test("Numbered and bullet continuation, preserved nesting, empty-item exit, Unicode UTF-16 offsets, CRLF, and Undo/Redo")
        func numberedBulletsNestingEmptyExitUnicodeAndUndoRedo() throws {
            try verifyNumberedBulletsNestingEmptyExitUnicodeAndUndoRedo()
        }

        @Test("Exclusions, autocomplete acceptance, modified-Return, marked text, Vim modes, and shared editors")
        func exclusionsAutocompleteShortcutsCompositionVimAndSharedEditors() throws {
            try verifyExclusionsAutocompleteShortcutsCompositionVimAndSharedEditors()
        }
    }
}
#endif
