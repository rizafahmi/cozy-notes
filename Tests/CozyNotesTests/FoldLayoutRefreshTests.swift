#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
@testable import CozyNotes

private let smallFoldMarkdown: String = {
    var text = """
    # Root

    Intro paragraph.

    ## Target Audience

    Audience line one.
    Audience line two.

    ## Next Section

    Visible prose after the fold.

    """
    for index in 1...20 {
        let paragraph = String(
            repeating: "A prose paragraph for this section keeps the layout busy and wraps across the editor line. ",
            count: 8
        )
        text += """
        ### Detail \(index)

        \(paragraph)

        ```swift
        let value\(index) = \(index)
        ```

        """
    }
    return text
}()

private let largeFoldMarkdown: String = {
    let filler = String(
        repeating: "Filler paragraph with enough words to wrap across the editor line and keep lazy layout busy.\n\n",
        count: 900
    )
    return """
    # Root

    ```swift
    let value = 1
    ```

    ## Target Audience

    Audience line one.
    Audience line two.

    ## Next Section

    Visible prose after the fold.

    """ + filler
}()

@MainActor
private func sendCommandUp(to window: NSWindow) -> Bool {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\u{F700}",
        charactersIgnoringModifiers: "\u{F700}",
        isARepeat: false,
        keyCode: 126
    ) else { return false }
    window.sendEvent(event)
    return true
}

@MainActor
private func makeFoldWindow(markdown: String) -> (window: NSWindow, editor: CaptureEditor) {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 760, height: 520)
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let editor = CaptureEditor(frame: frame)
    window.contentView = editor
    window.makeKeyAndOrderFront(nil)
    _ = window.makeFirstResponder(editor.textView)
    editor.text = markdown
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return (window, editor)
}

/// Folds `## Target Audience`, then moves the caret to the H1. That selection change runs
/// `refreshCursorDependentLines`, which takes the full `formatMarkdown()` path because the
/// document contains a fence. The folded body must stay collapsed after that reformat.
@MainActor
private func foldedLayoutFailures(markdown: String, label: String) -> [String] {
    var failures: [String] = []
    let (window, editor) = makeFoldWindow(markdown: markdown)
    defer { window.orderOut(nil) }

    let textView = editor.textView
    guard let lm = textView.layoutManager, let tc = textView.textContainer else {
        return ["\(label): missing layout manager or text container"]
    }
    guard let target = textView.headingGutterItems.first(where: { $0.title == "Target Audience" }),
          let next = textView.headingGutterItems.first(where: { $0.title == "Next Section" }) else {
        return ["\(label): missing headings: \(textView.headingGutterItems.map(\.title))"]
    }

    textView.setSelectedRange(NSRange(location: target.range.location + 1, length: 0))
    textView.insertTab(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    lm.ensureLayout(for: tc)
    guard let fold = textView.foldedSection(forHeadingAt: target.range.location) else {
        return ["\(label): fold was not created"]
    }

    // Tab folded the heading; ⌘↑ must move the caret off it and run the full reformat.
    if !window.makeFirstResponder(textView) {
        failures.append("\(label): could not focus the editor")
    }
    if !sendCommandUp(to: window) {
        failures.append("\(label): could not create the ⌘↑ event")
    }
    window.contentView?.layoutSubtreeIfNeeded()
    lm.ensureLayout(for: tc)
    window.displayIfNeeded()
    if textView.selectedRange().location >= target.range.location {
        failures.append(
            "\(label): ⌘↑ did not leave the folded heading line (selection \(textView.selectedRange()))"
        )
    }

    if textView.foldedSections.count != 1 {
        failures.append("\(label): expected 1 fold, got \(textView.foldedSections.count)")
    }
    if fold.foldedCharRange.length > 0, !textView.isCharacterFolded(fold.foldedCharRange.location) {
        failures.append("\(label): folded body is no longer marked folded")
    }

    let glyphRange = lm.glyphRange(forCharacterRange: fold.foldedCharRange, actualCharacterRange: nil)
    lm.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragmentGlyphs, _ in
        let characters = lm.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
        if characters.location >= fold.foldedCharRange.location,
           NSMaxRange(characters) <= NSMaxRange(fold.foldedCharRange),
           rect.height != 0 {
            failures.append("\(label): hidden fragment has height \(rect.height) at \(characters)")
        }
        if fragmentGlyphs.length > 0 {
            for index in fragmentGlyphs.location..<NSMaxRange(fragmentGlyphs) where !lm.notShownAttribute(forGlyphAt: index) {
                failures.append("\(label): folded glyph \(index) is still drawn")
                break
            }
        }
    }

    func headingRect(_ item: MarkdownTextView.HeadingGutter) -> NSRect {
        let glyphs = lm.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
        return lm.boundingRect(forGlyphRange: glyphs, in: tc)
    }

    let targetRect = headingRect(target)
    let nextRect = headingRect(next)
    if nextRect.minY - targetRect.maxY > 40 {
        failures.append(
            "\(label): folded body added \(nextRect.minY - targetRect.maxY)pt before the next heading"
        )
    }
    if editor.text != markdown {
        failures.append("\(label): folding or reformatting changed the Markdown source")
    }
    return failures
}

#if canImport(XCTest)
@MainActor
final class FoldLayoutRefreshTests: XCTestCase {
    func testFoldStaysCollapsedAfterFullReformatInSmallDocument() {
        let failures = foldedLayoutFailures(markdown: smallFoldMarkdown, label: "small")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testFoldStaysCollapsedAfterFullReformatInLargeDocument() {
        let failures = foldedLayoutFailures(markdown: largeFoldMarkdown, label: "large")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
#endif

#if canImport(Testing)
@Suite("Fold layout refresh", .serialized)
struct FoldLayoutRefreshSuite {
    @Test("A folded body stays collapsed after a full reformat in a small document")
    @MainActor
    func smallDocumentFoldRefresh() {
        let failures = foldedLayoutFailures(markdown: smallFoldMarkdown, label: "small")
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test("A folded body stays collapsed after a full reformat in a large lazy document")
    @MainActor
    func largeDocumentFoldRefresh() {
        let failures = foldedLayoutFailures(markdown: largeFoldMarkdown, label: "large")
        #expect(failures.isEmpty, "\(failures)")
    }
}
#endif
