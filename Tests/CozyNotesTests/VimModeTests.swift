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
private struct VimTestFixture {
    let rootDir: URL
    let vaultRoot: URL
    let historyRoot: URL
    let vault: Vault
    let previousVimMode: Bool
    let previousClipboard: String?

    init() throws {
        _ = NSApplication.shared
        previousVimMode = Theme.vimModeEnabled
        previousClipboard = NSPasteboard.general.string(forType: .string)
        rootDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyVimTests-\(UUID().uuidString)", isDirectory: true)
        vaultRoot = rootDir.appendingPathComponent("Vault", isDirectory: true)
        historyRoot = rootDir.appendingPathComponent("LocalHistory", isDirectory: true)
        vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        Theme.vimModeEnabled = true
    }

    func cleanup() {
        Theme.vimModeEnabled = previousVimMode
        let pb = NSPasteboard.general
        pb.clearContents()
        if let previousClipboard {
            pb.setString(previousClipboard, forType: .string)
        }
        try? FileManager.default.removeItem(at: rootDir)
    }
}

@MainActor
private func makeHostedVimEditor(text: String, width: CGFloat = 680, height: CGFloat = 460) -> (window: NSWindow, editor: CaptureEditor) {
    let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: width, height: height))
    editor.allowsVimMode = true
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = editor
    window.makeKeyAndOrderFront(nil)
    editor.layoutSubtreeIfNeeded()
    editor.text = text
    editor.layoutSubtreeIfNeeded()
    _ = window.makeFirstResponder(editor.textView)
    editor.textView.updateCaret()
    return (window, editor)
}

@MainActor
private func sendKey(
    _ chars: String,
    modifiers: NSEvent.ModifierFlags = [],
    keyCode: UInt16 = 0,
    ignoringModifiers: String? = nil,
    to window: NSWindow
) {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: chars,
        charactersIgnoringModifiers: ignoringModifiers ?? chars,
        isARepeat: false,
        keyCode: keyCode
    ) else { return }
    if modifiers.contains(.command) || modifiers.contains(.control) {
        if window.performKeyEquivalent(with: event) {
            return
        }
    }
    window.sendEvent(event)
}

@MainActor
private func sendCtrl(_ letter: Character, to window: NSWindow) {
    let lower = String(letter).lowercased()
    let scalar = lower.unicodeScalars.first!.value
    let ctrlChar = String(UnicodeScalar(scalar - 96)!)
    sendKey(ctrlChar, modifiers: .control, keyCode: 0, ignoringModifiers: lower, to: window)
}

@MainActor
private func sendEscape(to window: NSWindow) {
    sendKey("\u{1B}", keyCode: 53, to: window)
}

@MainActor
private func sendReturn(to window: NSWindow) {
    sendKey("\r", keyCode: 36, to: window)
}

@MainActor
private func sendBackspace(to window: NSWindow) {
    sendKey("\u{7F}", keyCode: 51, to: window)
}

@MainActor
private func sendTab(shift: Bool = false, to window: NSWindow) {
    if shift {
        sendKey("\u{19}", modifiers: .shift, keyCode: 48, ignoringModifiers: "\t", to: window)
    } else {
        sendKey("\t", keyCode: 48, to: window)
    }
}

@MainActor
private func sendSequence(_ keys: String, to window: NSWindow) {
    for ch in keys {
        let s = String(ch)
        if ch == " " {
            sendKey(" ", keyCode: 49, to: window)
        } else if ch.isUppercase || "!@#$%^&*()_+{}|:\"<>?~".contains(ch) {
            sendKey(s, modifiers: .shift, keyCode: 0, ignoringModifiers: s, to: window)
        } else {
            sendKey(s, keyCode: 0, to: window)
        }
    }
}

// MARK: - Shared Verification Routines

@MainActor
private func verifyActivationAndScope() throws -> Bool {
    let fixture = try VimTestFixture()
    defer { fixture.cleanup() }

    Theme.vimModeEnabled = false
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.buildMenus()
    guard let viewMenu = app.mainMenu?.item(withTitle: "View")?.submenu,
          let vimMenuItem = viewMenu.item(withTitle: "Vim Mode"),
          vimMenuItem.keyEquivalent == "v",
          vimMenuItem.keyEquivalentModifierMask == [.command, .control],
          delegate.validateMenuItem(vimMenuItem),
          vimMenuItem.state == .off else {
        return false
    }

    let existing = try fixture.vault.capture(text: "# Heading\nBody line here.")

    let workspace = WorkspaceController(vault: fixture.vault)
    defer {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
    }
    workspace.showAndFocus()
    workspace.openNote(existing.url)
    guard !workspace.editor.isVimActive,
          workspace.editor.vimModePill.isHidden,
          workspace.editor.textView.vim.cursorShape == .beam else {
        return false
    }

    // Enable Vim mode dynamically via AppDelegate's View -> Vim Mode action
    delegate.toggleVimMode()
    workspace.syncVimModePreference()
    guard Theme.vimModeEnabled,
          delegate.validateMenuItem(vimMenuItem),
          vimMenuItem.state == .on,
          workspace.editor.isVimActive,
          !workspace.editor.vimModePill.isHidden,
          workspace.editor.vimModePill.badgeText == "NORMAL",
          workspace.editor.textView.vim.mode == .normal,
          workspace.editor.textView.vim.cursorShape == .block else {
        return false
    }

    // New empty folio starts in Insert mode
    workspace.newCapture()
    guard workspace.editor.textView.vim.mode == .insert,
          workspace.editor.vimModePill.badgeText == "INSERT",
          workspace.editor.textView.vim.cursorShape == .beam else {
        return false
    }

    // Reopening non-empty note starts in Normal mode
    workspace.openNote(existing.url)
    guard workspace.editor.textView.vim.mode == .normal,
          workspace.editor.vimModePill.badgeText == "NORMAL" else {
        return false
    }

    // Standalone NoteWindowController also participates in Vim mode
    guard let companion = workspace.openNoteInNewWindow(existing.url) else {
        return false
    }
    guard companion.editor.isVimActive,
          companion.editor.textView.vim.mode == .normal,
          companion.editor.vimModePill.badgeText == "NORMAL" else {
        return false
    }

    // QuickCaptureController stays standard (non-Vim) and Esc dismisses the panel
    let quick = QuickCaptureController(vault: fixture.vault)
    defer { quick.window?.orderOut(nil) }
    quick.summon()
    guard let quickWin = quick.window,
          quickWin.isVisible,
          !quick.editor.allowsVimMode,
          !quick.editor.isVimActive,
          quick.editor.vimModePill.isHidden else {
        return false
    }
    sendSequence("quick thought", to: quickWin)
    guard quick.editor.text == "quick thought" else { return false }
    sendEscape(to: quickWin)
    guard !quickWin.isVisible else { return false }

    return true
}

@MainActor
private func verifyMotionsCountsAndUnicode() throws -> Bool {
    let fixture = try VimTestFixture()
    defer { fixture.cleanup() }

    let sample = """
      alpha beta_gamma
    short
    0123456789abcdef
    pair (one [two] three) end
    café 🚀 world
    """
    let (window, editor) = makeHostedVimEditor(text: sample)
    defer { window.orderOut(nil) }
    let tv = editor.textView

    // ^ moves to first non-blank ('a' at index 2), 0 moves to line start (0)
    sendSequence("^", to: window)
    guard tv.selectedRange().location == 2 else { return false }
    sendSequence("0", to: window)
    guard tv.selectedRange().location == 0 else { return false }

    // w, e, b, W, E, B
    sendSequence("2w", to: window) // 0 -> 2 ("alpha") -> 8 ("beta_gamma")
    guard tv.selectedRange().location == 8 else { return false }
    sendSequence("e", to: window) // end of "beta_gamma" -> index 17 ('a')
    guard tv.selectedRange().location == 17 else { return false }
    sendSequence("b", to: window) // back to start of "beta_gamma" -> 8
    guard tv.selectedRange().location == 8 else { return false }

    // Sticky $ column across shorter middle line onto longer third line
    sendSequence("$", to: window) // end of line 1 -> index 17
    guard tv.selectedRange().location == 17 else { return false }
    sendSequence("j", to: window) // line 2 "short" (starts at 19, 't' at 23)
    guard tv.selectedRange().location == 23 else { return false }
    sendSequence("j", to: window) // line 3 "0123456789abcdef" (starts at 25, 'f' at 40)
    guard tv.selectedRange().location == 40 else { return false }

    // f / t / ; / , and % delimiter matching on line 4
    sendSequence("j0", to: window) // line 4 starts at 42: "pair (one [two] three) end"
    guard tv.selectedRange().location == 42 else { return false }
    sendSequence("f(", to: window) // '(' at 47
    guard tv.selectedRange().location == 47 else { return false }
    sendSequence("%", to: window) // matching ')' at 63
    guard tv.selectedRange().location == 63 else { return false }
    sendSequence("%", to: window) // back to '(' at 47
    guard tv.selectedRange().location == 47 else { return false }
    sendSequence("ft", to: window) // 't' in "[two]" at 53
    guard tv.selectedRange().location == 53 else { return false }
    sendSequence(";", to: window) // next 't' in "three" at 58
    guard tv.selectedRange().location == 58 else { return false }
    sendSequence(",", to: window) // previous 't' at 53
    guard tv.selectedRange().location == 53 else { return false }

    // Composed character / UTF-16 surrogate pair safety on line 5: "café 🚀 world"
    sendSequence("G0", to: window)
    let line5Start = (editor.text as NSString).range(of: "café").location
    guard tv.selectedRange().location == line5Start else { return false }
    sendSequence("w", to: window) // lands on 🚀 (length 2 UTF-16)
    let rocketRange = (editor.text as NSString).range(of: "🚀")
    guard tv.selectedRange().location == rocketRange.location else { return false }
    sendSequence("l", to: window) // steps across full surrogate pair to space after 🚀
    guard tv.selectedRange().location == NSMaxRange(rocketRange) else { return false }
    sendSequence("h", to: window) // steps back onto start of 🚀, never splitting UTF-16 pair
    guard tv.selectedRange().location == rocketRange.location else { return false }

    // gg and [count]G
    sendSequence("gg", to: window)
    guard tv.selectedRange().location == 2 else { return false } // first non-blank of line 1
    sendSequence("3G", to: window)
    guard tv.selectedRange().location == 25 else { return false }

    return true
}

@MainActor
private func verifyOperatorsTextObjectsAndClipboard() throws -> Bool {
    let fixture = try VimTestFixture()
    defer { fixture.cleanup() }

    let initial = """
    hello "brave new" world
    call(foo, bar)
    first line
    second line
    """
    let (window, editor) = makeHostedVimEditor(text: initial)
    defer { window.orderOut(nil) }

    // ci" replaces inside quotes while preserving quotes
    sendSequence("ci\"cozy", to: window)
    sendEscape(to: window)
    guard editor.text.hasPrefix("hello \"cozy\" world\n") else { return false }

    // cw on "hello" preserves trailing space before "cozy"
    sendSequence("0cwhi", to: window)
    sendEscape(to: window)
    guard editor.text.hasPrefix("hi \"cozy\" world\n") else { return false }

    // ci( on second line replaces inside parentheses
    sendSequence("j0ci(baz", to: window)
    sendEscape(to: window)
    let linesAfterCall = editor.text.components(separatedBy: "\n")
    guard linesAfterCall[1] == "call(baz)" else { return false }

    // gUw uppercases word, ~ toggles case
    sendSequence("0gUw", to: window)
    guard editor.text.components(separatedBy: "\n")[1] == "CALL(baz)" else { return false }
    sendSequence("0guw", to: window)
    guard editor.text.components(separatedBy: "\n")[1] == "call(baz)" else { return false }

    // >> indents and << outdents
    sendSequence(">>", to: window)
    guard editor.text.components(separatedBy: "\n")[1] == "  call(baz)" else { return false }
    sendSequence("<<", to: window)
    guard editor.text.components(separatedBy: "\n")[1] == "call(baz)" else { return false }

    // yy + p pastes linewise below and syncs with NSPasteboard.general
    sendSequence("3Gyy", to: window)
    guard NSPasteboard.general.string(forType: .string) == "first line\n" else { return false }
    sendSequence("p", to: window)
    let afterPaste = editor.text.components(separatedBy: "\n")
    guard afterPaste[2] == "first line", afterPaste[3] == "first line", afterPaste[4] == "second line" else {
        return false
    }

    // dd deletes duplicate line (cursor lands on "second line"), then kJ joins "first line" and "second line"
    sendSequence("ddkJ", to: window)
    let afterJoin = editor.text.components(separatedBy: "\n")
    guard afterJoin[2] == "first line second line" else { return false }

    return true
}

@MainActor
private func verifyVisualModesCursorShapesAndBadges() throws -> Bool {
    let fixture = try VimTestFixture()
    defer { fixture.cleanup() }

    let (window, editor) = makeHostedVimEditor(text: "alpha beta\ngamma delta\nepsilon")
    defer { window.orderOut(nil) }
    let tv = editor.textView

    // Normal mode: block cursor + NORMAL pill
    guard tv.vim.cursorShape == .block,
          editor.vimModePill.badgeText == "NORMAL",
          editor.vimPendingLabel.isHidden else { return false }

    // Operator-pending ('d'): underline cursor + pending keys label
    sendSequence("d", to: window)
    guard tv.vim.cursorShape == .underline,
          !editor.vimPendingLabel.isHidden,
          editor.vimPendingLabel.stringValue == "d" else { return false }
    sendEscape(to: window)
    guard tv.vim.cursorShape == .block,
          editor.vimPendingLabel.isHidden else { return false }

    // Visual mode ('v'): VISUAL pill, o swaps anchor/head, U uppercases selection, gv reselects
    sendSequence("ve", to: window) // selects "alpha"
    guard tv.vim.mode == .visual,
          editor.vimModePill.badgeText == "VISUAL",
          tv.selectedRange() == NSRange(location: 0, length: 5) else { return false }
    sendSequence("o", to: window)
    guard tv.vim.visualHead == 0, tv.vim.visualAnchor == 4 else { return false }
    sendSequence("U", to: window)
    guard tv.vim.mode == .normal,
          editor.text.hasPrefix("ALPHA beta\n") else { return false }
    sendSequence("gv", to: window)
    guard tv.vim.mode == .visual,
          tv.selectedRange() == NSRange(location: 0, length: 5) else { return false }
    sendSequence("u", to: window)
    guard editor.text.hasPrefix("alpha beta\n") else { return false }

    // Visual Line mode ('V'): V-LINE pill + linewise indent '>'
    sendSequence("Vj>", to: window)
    guard tv.vim.mode == .normal,
          editor.text == "  alpha beta\n  gamma delta\nepsilon" else { return false }

    // Insert mode ('i'): INSERT pill + narrow beam cursor
    sendSequence("i", to: window)
    guard tv.vim.mode == .insert,
          editor.vimModePill.badgeText == "INSERT",
          tv.vim.cursorShape == .beam else { return false }
    sendEscape(to: window)
    guard tv.vim.mode == .normal else { return false }

    return true
}

@MainActor
private func verifyDeepUndoCoalescingAndDotRepeat() throws -> Bool {
    let fixture = try VimTestFixture()
    defer { fixture.cleanup() }

    // 1. Deep undo/redo well beyond 2 levels (10 sequential Normal edits)
    let (window, editor) = makeHostedVimEditor(text: "0123456789")
    defer { window.orderOut(nil) }

    for _ in 0..<8 {
        sendSequence("x", to: window)
    }
    guard editor.text == "89" else { return false }

    sendSequence("8u", to: window)
    guard editor.text == "0123456789" else { return false }

    for _ in 0..<8 {
        sendCtrl("r", to: window)
    }
    guard editor.text == "89" else { return false }

    // 2. Atomic Insert-session undo coalescing (including Backspace mid-insert) and dot-repeat
    editor.text = "one two three"
    _ = window.makeFirstResponder(editor.textView)
    sendSequence("cwfirstX", to: window)
    sendBackspace(to: window)
    sendEscape(to: window)
    guard editor.text == "first two three" else { return false }

    // Single 'u' reverts the entire cw + typing + backspace session atomically
    sendSequence("u", to: window)
    guard editor.text == "one two three" else { return false }

    // Ctrl-R redoes the entire Insert session, then 'w.' repeats it on "two"!
    sendCtrl("r", to: window)
    guard editor.text == "first two three" else { return false }
    sendSequence("w.", to: window)
    guard editor.text == "first first three" else { return false }

    return true
}

@MainActor
private func verifyMarkdownFoldsTasksWikiLinksAndSearch() throws -> Bool {
    let fixture = try VimTestFixture()
    defer { fixture.cleanup() }

    let linkedNote = try fixture.vault.capture(text: "# Existing Target\nTarget content.")
    _ = linkedNote
    let source = try fixture.vault.capture(text: """
    # Section One
    Hidden line A
    Hidden line B
    # Section Two
    - [ ] Ship Vim mode
    See [[Existing Target]] and [[Fresh Linked Note]]
    findme first and findme second
    """)

    let workspace = WorkspaceController(vault: fixture.vault)
    defer {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
    }
    workspace.showAndFocus()
    workspace.openNote(source.url)
    guard let win = workspace.window else { return false }
    workspace.editor.layoutSubtreeIfNeeded()
    _ = win.makeFirstResponder(workspace.editor.textView)
    let tv = workspace.editor.textView

    // 1. Heading fold bindings: zc folds Section One, j skips folded body directly to Section Two!
    sendSequence("ggzc", to: win)
    guard tv.foldedSections.count == 1 else { return false }
    let secTwoLoc = (workspace.editor.text as NSString).range(of: "# Section Two").location
    sendSequence("j", to: win)
    guard tv.selectedRange().location == secTwoLoc else { return false }
    sendSequence("zR", to: win)
    guard tv.foldedSections.isEmpty else { return false }

    // 2. Checklist toggle via gx and Return on checkbox
    sendSequence("/Ship", to: win)
    sendReturn(to: win)
    guard tv.vim.mode == .normal else { return false }
    sendSequence("gx", to: win)
    guard workspace.editor.text.contains("- [x] Ship Vim mode") else { return false }
    sendSequence("0", to: win)
    sendReturn(to: win) // cursor at checkbox prefix -> toggles back to [ ]
    guard workspace.editor.text.contains("- [ ] Ship Vim mode") else { return false }

    // 3. Search motions: /, n, N, *, and Esc dismissing highlights
    sendSequence("/findme", to: win)
    sendReturn(to: win)
    let firstFindMe = (workspace.editor.text as NSString).range(of: "findme first").location
    let secondFindMe = (workspace.editor.text as NSString).range(of: "findme second").location
    guard tv.selectedRange().location == firstFindMe,
          workspace.editor.isInNoteFindVisible else { return false }
    sendSequence("n", to: win)
    guard tv.selectedRange().location == secondFindMe else { return false }
    sendSequence("N", to: win)
    guard tv.selectedRange().location == firstFindMe else { return false }
    sendEscape(to: win)
    guard !workspace.editor.isInNoteFindVisible,
          tv.inNoteFindRanges.isEmpty else { return false }

    // * whole-word search under cursor
    sendSequence("*", to: win)
    guard tv.selectedRange().location == secondFindMe else { return false }
    sendEscape(to: win)

    // 4. WikiLink navigation: gf on [[Existing Target]] opens in Normal mode;
    //    gf on [[Fresh Linked Note]] creates note and enters Insert mode!
    sendSequence("/Existing Target", to: win)
    sendReturn(to: win)
    sendSequence("gf", to: win)
    guard workspace.noteURL == linkedNote.url,
          tv.vim.mode == .normal else { return false }

    workspace.openNote(source.url)
    _ = win.makeFirstResponder(tv)
    sendSequence("/Fresh Linked Note", to: win)
    sendReturn(to: win)
    sendSequence("gf", to: win)
    guard workspace.noteURL != source.url,
          workspace.editor.text.contains("# Fresh Linked Note"),
          tv.vim.mode == .insert else { return false }

    return true
}

#if canImport(XCTest)
@MainActor
final class VimModeTests: XCTestCase {
    func testActivationAndScopeAcrossWorkspaceNoteWindowAndQuickCapture() throws {
        XCTAssertTrue(try verifyActivationAndScope())
    }

    func testCoreMotionsCountsStickyColumnAndUnicodeSafety() throws {
        XCTAssertTrue(try verifyMotionsCountsAndUnicode())
    }

    func testOperatorsTextObjectsAndClipboardSync() throws {
        XCTAssertTrue(try verifyOperatorsTextObjectsAndClipboard())
    }

    func testVisualModesCursorShapesAndFooterBadges() throws {
        XCTAssertTrue(try verifyVisualModesCursorShapesAndBadges())
    }

    func testDeepUndoInsertCoalescingAndDotRepeat() throws {
        XCTAssertTrue(try verifyDeepUndoCoalescingAndDotRepeat())
    }

    func testMarkdownFoldsTasksWikiLinksAndSearchMotions() throws {
        XCTAssertTrue(try verifyMarkdownFoldsTasksWikiLinksAndSearch())
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Vim Modal Editing", .serialized)
    struct VimModeSuite {
        @Test("Activation & scope across Workspace, Note Window, and Quick Capture")
        @MainActor
        func activationAndScope() throws {
            #expect(try verifyActivationAndScope())
        }

        @Test("Core motions, counts, sticky $ column, delimiter %, and UTF-16 safety")
        @MainActor
        func motionsCountsAndUnicode() throws {
            #expect(try verifyMotionsCountsAndUnicode())
        }

        @Test("Operators, text objects, and system clipboard linewise/charwise sync")
        @MainActor
        func operatorsTextObjectsAndClipboard() throws {
            #expect(try verifyOperatorsTextObjectsAndClipboard())
        }

        @Test("Visual & Visual Line modes, cursor shapes, and footer badges")
        @MainActor
        func visualModesCursorShapesAndBadges() throws {
            #expect(try verifyVisualModesCursorShapesAndBadges())
        }

        @Test("Deep undo/redo history, atomic Insert undo coalescing, and dot-repeat")
        @MainActor
        func deepUndoInsertCoalescingAndDotRepeat() throws {
            #expect(try verifyDeepUndoCoalescingAndDotRepeat())
        }

        @Test("Cozy Markdown folds, checklists, WikiLinks, and search motions")
        @MainActor
        func markdownFoldsTasksWikiLinksAndSearch() throws {
            #expect(try verifyMarkdownFoldsTasksWikiLinksAndSearch())
        }
    }
}
#endif
