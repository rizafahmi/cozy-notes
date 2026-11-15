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
private func hrCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(
            domain: "HorizontalRuleRenderingTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
private func verifyHorizontalRuleParsingIncrementalAndRendering() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyHorizontalRuleTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let workspace = WorkspaceController(vault: vault)
    defer {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    workspace.window?.setFrame(NSRect(x: 0, y: 0, width: 960, height: 720), display: false)
    workspace.window?.layoutIfNeeded()
    let textView = workspace.editor.textView
    _ = workspace.window?.makeFirstResponder(textView)

    // 1. CommonMark variants vs non-matches (lists, indented code, fences, tables).
    do {
        let doc = """
        # Heading

        ---

        ***

        ___

        - - -

        * * *

        _ _ _

           ---   

        --
        - list item
        * bullet item
            ---
        --- not a rule

        ```markdown
        ---
        ***
        ```

        | Col A | Col B |
        | --- | --- |
        | 1 | 2 |

        Closing paragraph
        """
        let note = try vault.capture(text: doc)
        workspace.openNote(note.url)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let ns = workspace.editor.nsText
        let matchedStrings = textView.horizontalRuleRanges.map { ns.substring(with: $0) }
        let expected = [
            "---",
            "***",
            "___",
            "- - -",
            "* * *",
            "_ _ _",
            "   ---   "
        ]
        try hrCheck(
            matchedStrings == expected,
            "Expected horizontal rules \(expected), got \(matchedStrings)"
        )
        try hrCheck(
            textView.bulletItems.count == 2,
            "Expected 2 list items alongside horizontal rules, got \(textView.bulletItems.count)"
        )

        // Ensure spaced '* * *' and '_ _ _' clear inline italic/underline attributes.
        if let starRule = textView.horizontalRuleRanges.first(where: { ns.substring(with: $0) == "* * *" }),
           let storage = textView.textStorage {
            let font = storage.attribute(.font, at: starRule.location + 2, effectiveRange: nil) as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            try hrCheck(!traits.contains(.italicFontMask), "Spaced '* * *' rule should not keep italic font trait")
        }
    }

    // 2. Incremental typing ('---' + Return + prose, '___', plain-prose shift above, and backspace to '--').
    do {
        workspace.newCapture()
        _ = workspace.window?.makeFirstResponder(textView)

        for ch in "Intro\n" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        textView.insertText("-", replacementRange: textView.selectedRange())
        try hrCheck(textView.horizontalRuleRanges.isEmpty, "Single '-' must not be a horizontal rule")
        textView.insertText("-", replacementRange: textView.selectedRange())
        try hrCheck(textView.horizontalRuleRanges.isEmpty, "Double '--' must not be a horizontal rule")
        textView.insertText("-", replacementRange: textView.selectedRange())
        try hrCheck(
            textView.horizontalRuleRanges == [NSRange(location: 6, length: 3)],
            "Typing third '-' should register horizontal rule at (6,3), got \(textView.horizontalRuleRanges)"
        )

        // Press Return after '---' and type prose: rule syntax hides, prose keeps Theme.ink.
        textView.insertNewline(nil)
        for ch in "After rule" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        guard let storage = textView.textStorage else {
            throw NSError(domain: "HorizontalRuleRenderingTests", code: 2, userInfo: nil)
        }
        let ruleColorOff = storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor
        try hrCheck(ruleColorOff == NSColor.clear, "Rule characters should be hidden (NSColor.clear) when caret leaves line")
        let proseColor = storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor
        try hrCheck(proseColor == Theme.ink, "Prose typed after horizontal rule must use Theme.ink, got \(String(describing: proseColor))")

        // Insert plain prose on line 0 and verify horizontalRuleRanges shifts on the fast path.
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        for ch in " words" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        try hrCheck(
            textView.horizontalRuleRanges == [NSRange(location: 12, length: 3)],
            "Plain prose edit before rule must shift range to (12,3), got \(textView.horizontalRuleRanges)"
        )

        // Move caret onto the rule: syntax reveals in Theme.subtle with zero layout height shift.
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            throw NSError(domain: "HorizontalRuleRenderingTests", code: 3, userInfo: nil)
        }
        lm.ensureLayout(for: tc)
        let heightOff = lm.usedRect(for: tc).height

        textView.setSelectedRange(NSRange(location: 13, length: 0))
        let ruleColorOn = storage.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor
        try hrCheck(ruleColorOn == Theme.subtle, "Rule characters should reveal in Theme.subtle when caret is on rule")
        lm.ensureLayout(for: tc)
        let heightOn = lm.usedRect(for: tc).height
        try hrCheck(
            abs(heightOn - heightOff) < 0.01,
            "Moving caret onto/off horizontal rule must not shift layout height (\(heightOff) vs \(heightOn))"
        )

        // Delete one '-' so '---' becomes '--': rule must clear immediately and revert to Theme.ink.
        textView.setSelectedRange(NSRange(location: 15, length: 0))
        textView.deleteBackward(nil)
        try hrCheck(
            textView.horizontalRuleRanges.isEmpty,
            "Deleting '-' from '---' to '--' must remove horizontal rule, got \(textView.horizontalRuleRanges)"
        )
        let revertedColor = storage.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor
        try hrCheck(revertedColor == Theme.ink, "Unwrapped '--' should revert to Theme.ink")

        // Incremental underscore horizontal rule ('___').
        textView.setSelectedRange(NSRange(location: workspace.editor.nsText.length, length: 0))
        textView.insertNewline(nil)
        for ch in "___" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        try hrCheck(
            textView.horizontalRuleRanges.count == 1,
            "Typing '___' incrementally should register horizontal rule, got \(textView.horizontalRuleRanges)"
        )

        // Spaced horizontal rules ('- - -' and '* * *') must insert an ordinary newline on Return, never list continuation.
        for rule in ["- - -", "* * *"] {
            workspace.editor.text = rule
            textView.setSelectedRange(NSRange(location: workspace.editor.nsText.length, length: 0))
            textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try hrCheck(
                workspace.editor.text == "\(rule)\n",
                "Return at end of horizontal rule '\(rule)' must insert plain newline without bullet prefix, got \(workspace.editor.text.debugDescription)"
            )
            try hrCheck(
                textView.selectedRange() == NSRange(location: (rule as NSString).length + 1, length: 0),
                "Caret after Return on '\(rule)' must be right after newline, got \(textView.selectedRange())"
            )
            try hrCheck(
                textView.bulletItems.isEmpty,
                "Horizontal rule '\(rule)' must not register any bullet items, got \(textView.bulletItems)"
            )
        }
    }

    // 3. Rendered bitmap proof: verify drawBackground paints visible horizontal rule pixels when syntax is hidden.
    do {
        let note = try vault.capture(text: "---\n\nSecond paragraph")
        workspace.openNote(note.url)
        let endLoc = workspace.editor.nsText.length
        textView.setSelectedRange(NSRange(location: endLoc, length: 0))
        workspace.window?.layoutIfNeeded()
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            throw NSError(domain: "HorizontalRuleRenderingTests", code: 4, userInfo: nil)
        }
        lm.ensureLayout(for: tc)

        let captureRect = NSRect(x: 0, y: 0, width: max(320, textView.bounds.width), height: 140)
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: captureRect) else {
            throw NSError(domain: "HorizontalRuleRenderingTests", code: 5, userInfo: nil)
        }
        textView.cacheDisplay(in: captureRect, to: bitmap)

        let hrRange = textView.horizontalRuleRanges[0]
        let glyphRange = lm.glyphRange(forCharacterRange: hrRange, actualCharacterRange: nil)
        let lineFrag = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil, withoutAdditionalLayout: true)
        let origin = textView.textContainerOrigin
        let midX = Int(round(origin.x + (textView.bounds.width - 2 * origin.x) * 0.5))
        let bgSample = bitmap.colorAt(x: midX, y: 2)

        var foundRulePixel = false
        let scanMinY = max(0, Int(floor(origin.y + lineFrag.minY)))
        let scanMaxY = min(bitmap.pixelsHigh - 1, Int(ceil(origin.y + lineFrag.maxY + 8)))
        if let bg = bgSample?.usingColorSpace(.sRGB) {
            for py in scanMinY...scanMaxY {
                if let px = bitmap.colorAt(x: midX, y: py)?.usingColorSpace(.sRGB) {
                    let diff = abs(px.redComponent - bg.redComponent)
                        + abs(px.greenComponent - bg.greenComponent)
                        + abs(px.blueComponent - bg.blueComponent)
                    if diff > 0.08 {
                        foundRulePixel = true
                        break
                    }
                }
            }
        }
        try hrCheck(foundRulePixel, "Expected rendered horizontal rule pixels to contrast against paper background")
    }
}

#if canImport(XCTest)
@MainActor
final class HorizontalRuleRenderingTests: XCTestCase {
    func testHorizontalRuleParsingIncrementalAndRendering() throws {
        try verifyHorizontalRuleParsingIncrementalAndRendering()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Horizontal Rule Rendering", .serialized)
    @MainActor
    struct HorizontalRuleRenderingSuite {
        @Test("CommonMark horizontal rules parse, update incrementally, reveal syntax on cursor, and draw")
        func horizontalRuleParsingIncrementalAndRendering() throws {
            try verifyHorizontalRuleParsingIncrementalAndRendering()
        }
    }
}
#endif
