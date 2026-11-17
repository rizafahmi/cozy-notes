#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
@testable import CozyNotes

@MainActor
private final class ClipBoundsRecorder {
    private let clipView: NSClipView
    private var observer: NSObjectProtocol?
    private(set) var recordedOrigins: [NSPoint] = []

    init(scrollView: NSScrollView) {
        self.clipView = scrollView.contentView
        self.clipView.postsBoundsChangedNotifications = true
        self.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordedOrigins.append(self.clipView.bounds.origin)
            }
        }
    }

    func reset() {
        recordedOrigins.removeAll(keepingCapacity: true)
    }

    func maxVerticalDeviation(from baselineY: CGFloat) -> CGFloat {
        let currentDiff = abs(clipView.bounds.origin.y - baselineY)
        let historyDiff = recordedOrigins.map { abs($0.y - baselineY) }.max() ?? 0
        return max(currentDiff, historyDiff)
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor
private func makeScrollStabilityFixture(markdown: String) -> (
    window: NSWindow,
    editor: CaptureEditor,
    scrollView: NSScrollView,
    pasteboard: NSPasteboard
)? {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 760, height: 520)
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let editor = CaptureEditor(frame: frame)
    let pasteboard = NSPasteboard.withUniqueName()
    editor.pasteboard = pasteboard
    window.contentView = editor
    window.makeKeyAndOrderFront(nil)
    _ = window.makeFirstResponder(editor.textView)
    editor.text = markdown
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let scrollView = editor.textView.enclosingScrollView else {
        pasteboard.releaseGlobally()
        window.orderOut(nil)
        return nil
    }
    editor.textView.customMouseSelectionTracker = { tv, ev in
        let localPt = tv.convert(ev.locationInWindow, from: nil)
        let idx = tv.characterIndexForInsertion(at: localPt)
        tv.setSelectedRange(NSRange(location: idx, length: 0))
    }
    return (window, editor, scrollView, pasteboard)
}

@MainActor
private func windowPointForCharacter(at charIndex: Int, in textView: MarkdownTextView) -> NSPoint? {
    guard let lm = textView.layoutManager,
          let tc = textView.textContainer,
          let storage = textView.textStorage,
          charIndex >= 0,
          charIndex < storage.length else {
        return nil
    }
    let ns = storage.mutableString
    let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
    lm.ensureLayout(forCharacterRange: lineRange)
    let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
    let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
    let ptInTextView = NSPoint(
        x: textView.textContainerOrigin.x + rect.midX,
        y: textView.textContainerOrigin.y + max(1, rect.midY)
    )
    return textView.convert(ptInTextView, to: nil)
}

@MainActor
private func clickCharacter(at charIndex: Int, in textView: MarkdownTextView, window: NSWindow) -> Bool {
    guard let winPt = windowPointForCharacter(at: charIndex, in: textView),
          let event = NSEvent.mouseEvent(
              with: .leftMouseDown,
              location: winPt,
              modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber,
              context: nil,
              eventNumber: 1,
              clickCount: 1,
              pressure: 1.0
          ) else {
        return false
    }
    textView.mouseDown(with: event)
    return true
}

@MainActor
private func sendKey(
    to window: NSWindow,
    characters: String,
    charactersIgnoringModifiers: String? = nil,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
) -> Bool {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        return false
    }
    window.sendEvent(event)
    return true
}

@MainActor
private func exerciseHeadingEditsAndRecordDeviations(
    window: NSWindow,
    editor: CaptureEditor,
    recorder: ClipBoundsRecorder,
    baselineY: CGFloat,
    label: String
) -> [String] {
    var failures: [String] = []
    let textView = editor.textView

    // 1. Regular character typing via real NSEvent keyDown dispatch
    let typedLetters: [(String, UInt16)] = [
        (" ", 49), ("U", 32), ("p", 35), ("d", 2), ("a", 0), ("t", 17), ("e", 14), ("d", 2)
    ]
    for (ch, code) in typedLetters {
        recorder.reset()
        if !sendKey(to: window, characters: ch, keyCode: code) {
            failures.append("\(label): failed to create key event for '\(ch)'")
            break
        }
        window.displayIfNeeded()
        let dev = recorder.maxVerticalDeviation(from: baselineY)
        if dev > 0.5 {
            failures.append("\(label): typing '\(ch)' bounced clipView.bounds.origin.y by \(dev)pt (baseline \(baselineY), origins \(recorder.recordedOrigins.map(\.y)))")
            break
        }
    }

    // 2. IME / dead-key marked text composition + commit (AppKit passes NSNotFound to replace active markedRange)
    recorder.reset()
    textView.setMarkedText(
        "´",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    if !textView.hasMarkedText() {
        failures.append("\(label): expected active marked text during composition")
    }
    textView.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
    if textView.hasMarkedText() {
        failures.append("\(label): expected marked text to clear after insertText commit")
    }
    window.displayIfNeeded()
    let imeDev = recorder.maxVerticalDeviation(from: baselineY)
    if imeDev > 0.5 {
        failures.append("\(label): marked-text composition bounced clipView.bounds.origin.y by \(imeDev)pt (baseline \(baselineY), origins \(recorder.recordedOrigins.map(\.y)))")
    }

    // 3. Same-line Left Arrow, Forward Delete, Backspace, Right Arrow
    let navAndDeleteKeys: [(String, String, UInt16)] = [
        ("Left", "\u{F702}", 123),
        ("Backspace", "\u{7F}", 51),
        ("Left2", "\u{F702}", 123),
        ("ForwardDelete", "\u{F728}", 117),
        ("Right", "\u{F703}", 124)
    ]
    for (name, chars, code) in navAndDeleteKeys {
        recorder.reset()
        if !sendKey(to: window, characters: chars, keyCode: code) {
            failures.append("\(label): failed to create \(name) key event")
            break
        }
        window.displayIfNeeded()
        let dev = recorder.maxVerticalDeviation(from: baselineY)
        if dev > 0.5 {
            failures.append("\(label): \(name) bounced clipView.bounds.origin.y by \(dev)pt (baseline \(baselineY), origins \(recorder.recordedOrigins.map(\.y)))")
            break
        }
    }

    return failures
}

@MainActor
private func runCopyPasteAtEndAndEditHeadingScenario(markdown: String, label: String) -> [String] {
    guard let fixture = makeScrollStabilityFixture(markdown: markdown) else {
        return ["\(label): could not create editor fixture"]
    }
    let (window, editor, scrollView, pasteboard) = fixture
    let recorder = ClipBoundsRecorder(scrollView: scrollView)
    defer {
        recorder.stop()
        editor.textView.customMouseSelectionTracker = nil
        pasteboard.releaseGlobally()
        window.orderOut(nil)
    }

    var failures: [String] = []
    let textView = editor.textView
    guard window.makeFirstResponder(textView) else {
        return ["\(label): editor could not become first responder"]
    }

    let snippet = """
    ## Pasted Section Heading

    Supporting paragraph text right under the heading so the section has realistic height.

    - First bullet item in the copied section
    - Second bullet item in the copied section
    - Third bullet item in the copied section
    """
    let sourceRange = editor.nsText.range(of: snippet)
    guard sourceRange.location != NSNotFound else {
        return ["\(label): source snippet missing from fixture"]
    }

    // Copy heading + text + bullets via real copy(_:), jump to document end (⌘↓), insert spacing, and paste(_:).
    textView.setSelectedRange(sourceRange)
    textView.copy(nil)
    guard sendKey(to: window, characters: "\u{F701}", keyCode: 125, modifiers: .command) else {
        return ["\(label): failed to send ⌘↓"]
    }
    _ = sendKey(to: window, characters: "\r", keyCode: 36)
    _ = sendKey(to: window, characters: "\r", keyCode: 36)
    textView.paste(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let pastedHeadingRange = editor.nsText.range(of: "## Pasted Section Heading", options: .backwards)
    guard pastedHeadingRange.location != NSNotFound, pastedHeadingRange.location > sourceRange.location else {
        return ["\(label): pasted heading was not found at end of document"]
    }

    let scrolledBaselineY = scrollView.contentView.bounds.origin.y
    if scrolledBaselineY <= 100 {
        failures.append("\(label): expected viewport scrolled near bottom after paste, got y=\(scrolledBaselineY)")
        return failures
    }

    // Click into the end of the pasted heading line and verify selection change itself does not bounce scroll.
    recorder.reset()
    let clickTarget = NSMaxRange(pastedHeadingRange) - 1
    if !clickCharacter(at: clickTarget, in: textView, window: window) {
        return ["\(label): could not click pasted heading character at \(clickTarget)"]
    }
    textView.setSelectedRange(NSRange(location: NSMaxRange(pastedHeadingRange), length: 0))
    window.displayIfNeeded()
    let clickDev = recorder.maxVerticalDeviation(from: scrolledBaselineY)
    if clickDev > 0.5 {
        failures.append("\(label): selecting pasted heading bounced clipView.bounds.origin.y by \(clickDev)pt (baseline \(scrolledBaselineY), origins \(recorder.recordedOrigins.map(\.y)))")
    }

    let baselineAfterSelect = scrollView.contentView.bounds.origin.y
    failures.append(contentsOf: exerciseHeadingEditsAndRecordDeviations(
        window: window,
        editor: editor,
        recorder: recorder,
        baselineY: baselineAfterSelect,
        label: label
    ))

    let finalTail = editor.nsText.substring(from: pastedHeadingRange.location)
    if !finalTail.hasPrefix("## Pasted Section Heading Updaté") {
        failures.append("\(label): unexpected edited heading text at tail: \(finalTail.prefix(60))")
    }
    return failures
}

private let smallMixedMarkdown: String = {
    var doc = """
    # Architecture Notes

    Introductory context before blocks.

    ```swift
    struct Sample {
        let count: Int
    }
    ```

    | Phase | Owner |
    | --- | --- |
    | Design | Cozy |

    ## Pasted Section Heading

    Supporting paragraph text right under the heading so the section has realistic height.

    - First bullet item in the copied section
    - Second bullet item in the copied section
    - Third bullet item in the copied section

    """
    for idx in 1...35 {
        doc += """
        ### Section \(idx)

        Prose filler paragraph \(idx) with enough words to wrap across multiple visual lines inside the editor viewport and push the end of the note well past a single screen height.

        """
    }
    return doc
}()

private let largeLazyMixedMarkdown: String = {
    let filler = String(
        repeating: "Long lazy-layout filler paragraph that keeps non-contiguous layout active across more than one hundred thousand UTF-16 characters in the editor.\n\n",
        count: 800
    )
    return """
    # Large Note

    ```swift
    let lazyLayoutEnabled = true
    ```

    ## Pasted Section Heading

    Supporting paragraph text right under the heading so the section has realistic height.

    - First bullet item in the copied section
    - Second bullet item in the copied section
    - Third bullet item in the copied section

    """ + filler
}()

@MainActor
private func runBottomFenceAndTableDirectEditScenario() -> [String] {
    var doc = smallMixedMarkdown
    doc += """

    ```swift
    let bottomValue = 42
    ```

    | Metric | Value |
    | --- | --- |
    | Scroll | Stable |
    """
    guard let fixture = makeScrollStabilityFixture(markdown: doc) else {
        return ["bottom-blocks: could not create fixture"]
    }
    let (window, editor, scrollView, pasteboard) = fixture
    let recorder = ClipBoundsRecorder(scrollView: scrollView)
    defer {
        recorder.stop()
        editor.textView.customMouseSelectionTracker = nil
        pasteboard.releaseGlobally()
        window.orderOut(nil)
    }

    var failures: [String] = []
    let textView = editor.textView
    _ = window.makeFirstResponder(textView)

    // Scroll to the end of the document so both the bottom fence and bottom table are visible.
    _ = sendKey(to: window, characters: "\u{F701}", keyCode: 125, modifiers: .command)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let baselineY = scrollView.contentView.bounds.origin.y
    if baselineY <= 100 {
        return ["bottom-blocks: expected scrolled document, got y=\(baselineY)"]
    }

    // Edit directly inside the bottom fenced code block (triggers genuine full formatMarkdown()).
    let fenceTarget = editor.nsText.range(of: "bottomValue = 42")
    guard fenceTarget.location != NSNotFound else {
        return ["bottom-blocks: missing bottom fence target"]
    }
    textView.setSelectedRange(NSRange(location: NSMaxRange(fenceTarget), length: 0))
    window.displayIfNeeded()
    let fenceBaselineY = scrollView.contentView.bounds.origin.y
    recorder.reset()
    _ = sendKey(to: window, characters: "0", keyCode: 29)
    window.displayIfNeeded()
    let fenceDev = recorder.maxVerticalDeviation(from: fenceBaselineY)
    if fenceDev > 0.5 {
        failures.append("bottom-blocks: typing inside bottom code fence bounced scroll by \(fenceDev)pt (origins \(recorder.recordedOrigins.map(\.y)))")
    }

    // Edit directly inside the bottom Markdown table cell (also triggers genuine full formatMarkdown()).
    let tableTarget = editor.nsText.range(of: "Stable")
    guard tableTarget.location != NSNotFound else {
        return ["bottom-blocks: missing bottom table target"]
    }
    textView.setSelectedRange(NSRange(location: NSMaxRange(tableTarget), length: 0))
    window.displayIfNeeded()
    let tableBaselineY = scrollView.contentView.bounds.origin.y
    recorder.reset()
    _ = sendKey(to: window, characters: "!", keyCode: 18, modifiers: .shift)
    window.displayIfNeeded()
    let tableDev = recorder.maxVerticalDeviation(from: tableBaselineY)
    if tableDev > 0.5 {
        failures.append("bottom-blocks: typing inside bottom table bounced scroll by \(tableDev)pt (origins \(recorder.recordedOrigins.map(\.y)))")
    }

    return failures
}

@MainActor
private func runPlainNoteTopEdgeHeadingEditAndBottomTypewriterScenario() -> [String] {
    var plainDoc = "# Plain Note\n\n"
    for idx in 1...30 {
        plainDoc += "Plain paragraph \(idx) with steady prose and zero code fences or tables anywhere in the document so incremental formatting stays active.\n\n"
    }
    let tallPaste = """
    ## Top Edge Heading

    Introductory line right beneath the pasted heading.

    - Bullet one
    - Bullet two
    - Bullet three
    - Bullet four
    - Bullet five
    - Bullet six
    - Bullet seven
    - Bullet eight
    - Bullet nine
    """

    guard let fixture = makeScrollStabilityFixture(markdown: plainDoc) else {
        return ["plain-top-edge: could not create fixture"]
    }
    let (window, editor, scrollView, pasteboard) = fixture
    let recorder = ClipBoundsRecorder(scrollView: scrollView)
    defer {
        recorder.stop()
        editor.textView.customMouseSelectionTracker = nil
        pasteboard.releaseGlobally()
        window.orderOut(nil)
    }

    var failures: [String] = []
    let textView = editor.textView
    _ = window.makeFirstResponder(textView)

    pasteboard.clearContents()
    pasteboard.setString(tallPaste, forType: .string)

    _ = sendKey(to: window, characters: "\u{F701}", keyCode: 125, modifiers: .command)
    textView.paste(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let headingRange = editor.nsText.range(of: "## Top Edge Heading", options: .backwards)
    guard headingRange.location != NSNotFound,
          let lm = textView.layoutManager,
          let tc = textView.textContainer else {
        return ["plain-top-edge: missing pasted heading"]
    }
    lm.ensureLayout(forCharacterRange: headingRange)
    let headingGlyphs = lm.glyphRange(forCharacterRange: headingRange, actualCharacterRange: nil)
    let headingRect = lm.boundingRect(forGlyphRange: headingGlyphs, in: tc)
    let headingDocY = headingRect.minY + textView.textContainerOrigin.y

    // Position the viewport so the pasted heading sits visibly near the top edge (inside the top 22% margin).
    let clipView = scrollView.contentView
    let topEdgeOriginY = max(0, headingDocY - 24)
    clipView.setBoundsOrigin(NSPoint(x: 0, y: topEdgeOriginY))
    scrollView.reflectScrolledClipView(clipView)
    window.displayIfNeeded()

    let baselineY = clipView.bounds.origin.y
    textView.setSelectedRange(NSRange(location: NSMaxRange(headingRange), length: 0))
    window.displayIfNeeded()

    failures.append(contentsOf: exerciseHeadingEditsAndRecordDeviations(
        window: window,
        editor: editor,
        recorder: recorder,
        baselineY: baselineY,
        label: "plain-top-edge"
    ))

    // Also verify that pressing Return at the very bottom of the note below the 75% threshold still advances scroll.
    _ = sendKey(to: window, characters: "\u{F701}", keyCode: 125, modifiers: .command)
    window.displayIfNeeded()
    // Align the last line near 85% of viewport height so pressing Return crosses below the 75% typewriter threshold.
    let endLoc = max(0, editor.nsText.length - 1)
    let endGlyphs = lm.glyphRange(forCharacterRange: NSRange(location: endLoc, length: 1), actualCharacterRange: nil)
    let endRect = lm.boundingRect(forGlyphRange: endGlyphs, in: tc)
    let endDocY = endRect.minY + textView.textContainerOrigin.y
    let preReturnOriginY = max(0, endDocY - clipView.bounds.height * 0.85)
    clipView.setBoundsOrigin(NSPoint(x: 0, y: preReturnOriginY))
    scrollView.reflectScrolledClipView(clipView)
    window.displayIfNeeded()

    _ = sendKey(to: window, characters: "\r", keyCode: 36)
    window.displayIfNeeded()
    if clipView.bounds.origin.y <= preReturnOriginY + 1 {
        failures.append("plain-top-edge: pressing Return below 75% viewport height should still auto-scroll (before \(preReturnOriginY), after \(clipView.bounds.origin.y))")
    }

    return failures
}

#if canImport(XCTest)
@MainActor
final class PastedHeadingScrollStabilityTests: XCTestCase {
    func testEditingPastedHeadingAtEndDoesNotBounceScrollInNoteWithFenceAndTable() {
        let failures = runCopyPasteAtEndAndEditHeadingScenario(markdown: smallMixedMarkdown, label: "small-mixed")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEditingPastedHeadingAtEndDoesNotBounceScrollInLargeLazyNote() {
        let failures = runCopyPasteAtEndAndEditHeadingScenario(markdown: largeLazyMixedMarkdown, label: "large-lazy")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testDirectEditsInsideBottomFenceAndTableKeepViewportStable() {
        let failures = runBottomFenceAndTableDirectEditScenario()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testSameLineHeadingEditsNearTopEdgeStayStableWhileBottomNewlineStillScrolls() {
        let failures = runPlainNoteTopEdgeHeadingEditAndBottomTypewriterScenario()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Pasted heading scroll stability", .serialized)
    struct PastedHeadingScrollStabilitySuite {
        @Test("Editing a pasted heading at document end keeps scroll stable in notes with fences and tables")
        @MainActor
        func smallMixedNoteScrollStability() {
            let failures = runCopyPasteAtEndAndEditHeadingScenario(markdown: smallMixedMarkdown, label: "small-mixed")
            #expect(failures.isEmpty, "\(failures)")
        }

        @Test("Editing a pasted heading at document end keeps scroll stable in large lazy notes")
        @MainActor
        func largeLazyNoteScrollStability() {
            let failures = runCopyPasteAtEndAndEditHeadingScenario(markdown: largeLazyMixedMarkdown, label: "large-lazy")
            #expect(failures.isEmpty, "\(failures)")
        }

        @Test("Editing directly inside a bottom code fence or Markdown table preserves viewport origin")
        @MainActor
        func bottomFenceAndTableScrollStability() {
            let failures = runBottomFenceAndTableDirectEditScenario()
            #expect(failures.isEmpty, "\(failures)")
        }

        @Test("Same-line heading edits near the top viewport edge stay put while bottom newlines still scroll")
        @MainActor
        func topEdgeSameLineAndBottomReturnBehavior() {
            let failures = runPlainNoteTopEdgeHeadingEditAndBottomTypewriterScenario()
            #expect(failures.isEmpty, "\(failures)")
        }
    }
}
#endif
