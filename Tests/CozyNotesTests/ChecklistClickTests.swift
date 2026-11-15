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
private func checklistCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(
            domain: "ChecklistClickTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
private func glyphPointInWindow(
    for charRange: NSRange,
    in textView: MarkdownTextView
) throws -> NSPoint {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else {
        throw NSError(domain: "ChecklistClickTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing layoutManager/textContainer"])
    }
    lm.ensureLayout(for: tc)
    let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
    var targetRect: NSRect?
    lm.enumerateEnclosingRects(
        forGlyphRange: glyphRange,
        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: tc
    ) { rect, stop in
        targetRect = rect
        stop.pointee = true
    }
    let rect = targetRect ?? lm.boundingRect(forGlyphRange: glyphRange, in: tc)
    let pointInTextView = NSPoint(
        x: textView.textContainerOrigin.x + rect.midX,
        y: textView.textContainerOrigin.y + rect.midY
    )
    return textView.convert(pointInTextView, to: nil)
}

@MainActor
private func verifyChecklistMouseClickToggle() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyChecklistClickTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let workspace = WorkspaceController(vault: vault)
    defer {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    let editor = workspace.editor
    let textView = editor.textView
    guard let um = textView.undoManager else {
        throw NSError(domain: "ChecklistClickTests", code: 10, userInfo: nil)
    }
    let prevGroupsByEvent = um.groupsByEvent
    um.groupsByEvent = false
    defer { um.groupsByEvent = prevGroupsByEvent }

    workspace.window?.setFrame(NSRect(x: 0, y: 0, width: 960, height: 720), display: false)
    workspace.window?.layoutIfNeeded()
    _ = workspace.window?.makeFirstResponder(textView)

    let doc = """
    # Tasks

    - [ ] Ship clickable checkboxes
      * [x] Nested star task
    1. [X] Ordered uppercase task

    Trailing paragraph line.
    """
    let note = try vault.capture(text: doc)
    workspace.openNote(note.url)
    workspace.window?.layoutIfNeeded()
    _ = workspace.window?.makeFirstResponder(textView)

    let trailingRange = editor.nsText.range(of: "Trailing paragraph line.")
    try checklistCheck(trailingRange.location != NSNotFound, "Expected trailing paragraph in fixture")
    textView.setSelectedRange(NSRange(location: trailingRange.location + 8, length: 0))
    let initialCaret = textView.selectedRange()

    textView.customMouseSelectionTracker = { tv, ev in
        let localPt = tv.convert(ev.locationInWindow, from: nil)
        let charIdx = tv.characterIndexForInsertion(at: localPt)
        tv.setSelectedRange(NSRange(location: charIdx, length: 0))
    }
    defer { textView.customMouseSelectionTracker = nil }

    // 1. Click inside `[ ]` of `- [ ] Ship clickable checkboxes` -> toggles to `- [x]`, preserves caret on trailing line.
    let bracket1Range = editor.nsText.range(of: "[ ] Ship clickable checkboxes")
    try checklistCheck(bracket1Range.location != NSNotFound, "Expected first task in fixture")
    let clickRange1 = NSRange(location: bracket1Range.location, length: 3)
    let winPt1 = try glyphPointInWindow(for: clickRange1, in: textView)
    let localPt1 = textView.convert(winPt1, from: nil)
    try checklistCheck(
        textView.taskCheckbox(atPoint: localPt1)?.kind == .task(completed: false),
        "Hit-test on `[ ]` should resolve to incomplete task item"
    )

    guard let click1 = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: winPt1,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: workspace.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1.0
    ) else {
        throw NSError(domain: "ChecklistClickTests", code: 3, userInfo: nil)
    }

    um.beginUndoGrouping()
    textView.mouseDown(with: click1)
    um.endUndoGrouping()
    try checklistCheck(
        editor.text.contains("- [x] Ship clickable checkboxes"),
        "Clicking `- [ ]` should toggle task to `- [x]`, got:\n\(editor.text)"
    )
    try checklistCheck(
        textView.selectedRange() == initialCaret,
        "Clicking checkbox should preserve existing caret selection \(initialCaret), got \(textView.selectedRange())"
    )
    try checklistCheck(
        textView.taskCheckbox(atPoint: localPt1)?.kind == .task(completed: true),
        "Task item state should update to completed after click"
    )

    // 2. Click on the leading `-` marker of `- [x] Ship clickable checkboxes` -> toggles back to `- [ ]`.
    let dash1Range = editor.nsText.range(of: "- [x] Ship clickable checkboxes")
    let dashOnlyRange = NSRange(location: dash1Range.location, length: 1)
    let winPtDash = try glyphPointInWindow(for: dashOnlyRange, in: textView)
    guard let clickDash = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: winPtDash,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: workspace.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 1.0
    ) else {
        throw NSError(domain: "ChecklistClickTests", code: 4, userInfo: nil)
    }
    um.beginUndoGrouping()
    textView.mouseDown(with: clickDash)
    um.endUndoGrouping()
    try checklistCheck(
        editor.text.contains("- [ ] Ship clickable checkboxes"),
        "Clicking `-` of `- [x]` should toggle task back to `- [ ]`, got:\n\(editor.text)"
    )

    // 3. Undo & Redo restore checkbox state cleanly.
    um.undo()
    try checklistCheck(
        editor.text.contains("- [x] Ship clickable checkboxes"),
        "Undo after unchecking should restore `- [x]`"
    )
    um.redo()
    try checklistCheck(
        editor.text.contains("- [ ] Ship clickable checkboxes"),
        "Redo should re-apply `- [ ]`"
    )

    // 4. Nested `* [x]` and ordered `1. [X]` also toggle on click, while clicking task body text places caret normally.
    let nestedBracket = editor.nsText.range(of: "[x] Nested star task")
    let nestedPt = try glyphPointInWindow(for: NSRange(location: nestedBracket.location, length: 3), in: textView)
    if let ev = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: nestedPt,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: workspace.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 3,
        clickCount: 1,
        pressure: 1.0
    ) {
        um.beginUndoGrouping()
        textView.mouseDown(with: ev)
        um.endUndoGrouping()
    }
    try checklistCheck(
        editor.text.contains("  * [ ] Nested star task"),
        "Clicking nested `* [x]` should toggle to `  * [ ]`, got:\n\(editor.text)"
    )

    let orderedBracket = editor.nsText.range(of: "[X] Ordered uppercase task")
    let orderedPt = try glyphPointInWindow(for: NSRange(location: orderedBracket.location, length: 3), in: textView)
    if let ev = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: orderedPt,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: workspace.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 4,
        clickCount: 1,
        pressure: 1.0
    ) {
        um.beginUndoGrouping()
        textView.mouseDown(with: ev)
        um.endUndoGrouping()
    }
    try checklistCheck(
        editor.text.contains("1. [ ] Ordered uppercase task"),
        "Clicking ordered `1. [X]` should toggle to `1. [ ]`, got:\n\(editor.text)"
    )

    // Clicking prose label ("Ship clickable checkboxes") must NOT toggle the checkbox; it should move caret there.
    let proseWordRange = editor.nsText.range(of: "clickable")
    let prosePt = try glyphPointInWindow(for: proseWordRange, in: textView)
    if let ev = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: prosePt,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: workspace.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 5,
        clickCount: 1,
        pressure: 1.0
    ) {
        textView.mouseDown(with: ev)
    }
    try checklistCheck(
        editor.text.contains("- [ ] Ship clickable checkboxes"),
        "Clicking task prose label must not toggle checkbox state"
    )
    try checklistCheck(
        NSLocationInRange(textView.selectedRange().location, proseWordRange),
        "Clicking task prose label should place caret inside prose word, got \(textView.selectedRange())"
    )
}

#if canImport(XCTest)
@MainActor
final class ChecklistClickTests: XCTestCase {
    func testChecklistMouseClickToggle() throws {
        try verifyChecklistMouseClickToggle()
    }
}
#endif

#if canImport(Testing)
@Suite("Checklist Click Interactions", .serialized)
@MainActor
struct ChecklistClickSuite {
    @Test("Clicking task checkbox toggles between todo and done with undo support and without stealing caret")
    func checklistMouseClickToggle() throws {
        try verifyChecklistMouseClickToggle()
    }
}
#endif
