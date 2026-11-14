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
private func linkCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(
            domain: "LinkInteractionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
private func glyphMidpointInWindow(
    for charRange: NSRange,
    in textView: MarkdownTextView
) throws -> NSPoint {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else {
        throw NSError(domain: "LinkInteractionTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing layoutManager/textContainer"])
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
private func verifyMarkdownLinkParsingIncrementalAndInteractions() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyLinkInteractionTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let workspace = WorkspaceController(vault: vault)
    let isolatedPasteboard = NSPasteboard.withUniqueName()
    defer {
        isolatedPasteboard.releaseGlobally()
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    let editor = workspace.editor
    let textView = editor.textView
    var openedURLs: [URL] = []
    editor.urlOpener = { url in
        openedURLs.append(url)
        return true
    }
    editor.pasteboard = isolatedPasteboard

    workspace.window?.setFrame(NSRect(x: 0, y: 0, width: 960, height: 720), display: false)
    workspace.window?.layoutIfNeeded()
    _ = workspace.window?.makeFirstResponder(textView)

    // 1. Parsing coverage: inline links, nested parentheses, angle-wrapped URLs + titles,
    //    scheme-less domains, autolinks, bare URLs with trailing punctuation, and exclusions.
    do {
        let doc = """
        # Links Reference

        Read [Swift Docs](https://swift.org/documentation) and [Rust (language)](https://en.wikipedia.org/wiki/Rust_(programming_language)).
        Titled [Spec](<https://example.com/spec(v2)> "Specification") plus [Apple](apple.com) and [Forums](www.swift.org/forums).
        Autolinks: <https://developer.apple.com/macos> and <mailto:hello@example.com>.
        Bare URLs: (see https://cozynotes.app/guide?tab=links, or contact mailto:support@cozynotes.app.)

        Ignored inline code: `[Fake](https://ignored-inline.example)` and `https://ignored-bare.example`.
        Ignored local/unsafe: [Attachment](../Attachments/photo.png) [Relative](./note.md) [File](todo.md) [Anchor](#top) [Bad](javascript:alert(1)) [Empty](https://)

        ```markdown
        [Fenced](https://ignored-fenced.example)
        https://ignored-fenced-bare.example
        ```
        """
        let note = try vault.capture(text: doc)
        workspace.openNote(note.url)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let resolved = textView.markdownLinkItems.map(\.resolvedURL.absoluteString)
        let expected = [
            "https://swift.org/documentation",
            "https://en.wikipedia.org/wiki/Rust_(programming_language)",
            "https://example.com/spec(v2)",
            "https://apple.com",
            "https://www.swift.org/forums",
            "https://developer.apple.com/macos",
            "mailto:hello@example.com",
            "https://cozynotes.app/guide?tab=links",
            "mailto:support@cozynotes.app"
        ]
        try linkCheck(
            resolved == expected,
            "Expected parsed URLs \(expected), got \(resolved)"
        )
    }

    // 2. Incremental typing and fast-path range shifting.
    do {
        workspace.newCapture()
        _ = workspace.window?.makeFirstResponder(textView)

        for ch in "Intro line\n" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        // Incomplete ⌘K-style link should not register until host is present and closed.
        for ch in "[Portal](https://)" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        try linkCheck(
            textView.markdownLinkItems.isEmpty,
            "Empty-host '[Portal](https://)' must not produce a clickable link, got \(textView.markdownLinkItems)"
        )

        // Insert host before closing ')' incrementally.
        let insertHostAt = editor.nsText.length - 1
        textView.setSelectedRange(NSRange(location: insertHostAt, length: 0))
        for ch in "portal.example.org" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        try linkCheck(
            textView.markdownLinkItems.map(\.resolvedURL.absoluteString) == ["https://portal.example.org"],
            "Completing host inside '[Portal](https://...)' should register link incrementally, got \(textView.markdownLinkItems)"
        )

        // Type a bare URL on a new line followed by sentence punctuation.
        textView.setSelectedRange(NSRange(location: editor.nsText.length, length: 0))
        for ch in "\nCheck https://news.ycombinator.com." {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        try linkCheck(
            textView.markdownLinkItems.map(\.resolvedURL.absoluteString) == [
                "https://portal.example.org",
                "https://news.ycombinator.com"
            ],
            "Incremental bare URL with trailing period should strip punctuation, got \(textView.markdownLinkItems)"
        )

        // Plain prose edit on line 0 must shift subsequent markdownLinkItems ranges on the fast path.
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        for ch in " words" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        let nsAfterShift = editor.nsText
        let substrings = textView.markdownLinkItems.map { nsAfterShift.substring(with: $0.fullRange) }
        try linkCheck(
            substrings == ["[Portal](https://portal.example.org)", "https://news.ycombinator.com"],
            "Plain prose edit before links must shift fullRange accurately, got \(substrings)"
        )
    }

    // 3. AppKit interaction proof: plain click, drag-select suppression, Copy & Open pill buttons,
    //    ⌘-Click direct open, dismissal (Esc / selection move / typing), context menu, shortcut, and Vim.
    do {
        openedURLs.removeAll()
        isolatedPasteboard.clearContents()

        let doc = "Lead prose before link.\n\nVisit [Swift Documentation](https://swift.org/docs) for details.\n\nTrailing paragraph."
        let note = try vault.capture(text: doc)
        workspace.openNote(note.url)
        workspace.window?.layoutIfNeeded()
        _ = workspace.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        try linkCheck(textView.markdownLinkItems.count == 1, "Expected 1 link in interaction fixture")
        let link = textView.markdownLinkItems[0]
        let clickWinPt = try glyphMidpointInWindow(for: link.labelRange, in: textView)

        // Install deterministic single-click selection tracker so mouseDown exercises real glyph hit-testing
        // without blocking on AppKit's global event-queue mouseUp loop.
        textView.customMouseSelectionTracker = { tv, ev in
            let localPt = tv.convert(ev.locationInWindow, from: nil)
            let charIdx = tv.characterIndexForInsertion(at: localPt)
            tv.setSelectedRange(NSRange(location: charIdx, length: 0))
        }
        defer { textView.customMouseSelectionTracker = nil }

        guard let plainClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickWinPt,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 10,
            clickCount: 1,
            pressure: 1.0
        ) else {
            throw NSError(domain: "LinkInteractionTests", code: 3, userInfo: nil)
        }

        // 3a. Single plain click places caret inside link, keeps editor focused, and shows LinkActionBarView.
        textView.mouseDown(with: plainClick)
        let caretAfterClick = textView.selectedRange()
        try linkCheck(caretAfterClick.length == 0, "Plain click should place an insertion caret, not a range selection")
        try linkCheck(
            NSLocationInRange(caretAfterClick.location, link.fullRange),
            "Plain click caret (\(caretAfterClick.location)) should land inside link range \(link.fullRange)"
        )
        try linkCheck(editor.isLinkActionBarVisible && !editor.linkActionBar.isHidden, "Plain click on link must show LinkActionBarView")
        try linkCheck(workspace.window?.firstResponder === textView, "Showing LinkActionBarView must preserve textView as firstResponder")
        try linkCheck(openedURLs.isEmpty, "Plain click must not open browser immediately")

        if let linkRectInText = textView.enclosingRect(for: link) {
            let linkRectInEditor = editor.convert(linkRectInText, from: textView)
            try linkCheck(
                !editor.linkActionBar.frame.intersects(linkRectInEditor.insetBy(dx: 0, dy: 2)),
                "LinkActionBarView (\(editor.linkActionBar.frame)) must not cover the clicked link line (\(linkRectInEditor))"
            )
        }

        // 3b. Clicking Copy copies URL to pasteboard, updates pill to "Copied" with zero width shift, and keeps textView focused.
        let barWidthBeforeCopy = editor.linkActionBar.bounds.width
        let copyBtnWidthBeforeCopy = editor.linkActionBar.copyButton.frame.width
        editor.linkActionBar.copyButton.performClick(nil)
        try linkCheck(
            isolatedPasteboard.string(forType: .string) == "https://swift.org/docs",
            "Copy button should write resolved URL to pasteboard, got \(String(describing: isolatedPasteboard.string(forType: .string)))"
        )
        try linkCheck(editor.linkActionBar.isShowingCopied, "Copy button should enter 'Copied' confirmation state")
        try linkCheck(editor.linkActionBar.copyButton.title == "Copied", "Copy button title should change to 'Copied'")
        try linkCheck(
            abs(editor.linkActionBar.bounds.width - barWidthBeforeCopy) < 0.01
                && abs(editor.linkActionBar.copyButton.frame.width - copyBtnWidthBeforeCopy) < 0.01,
            "Transitioning Copy -> Copied must cause 0pt width shift"
        )
        try linkCheck(workspace.window?.firstResponder === textView, "Clicking Copy button must not steal focus from textView")

        // 3c. Clicking Open invokes urlOpener, dismisses LinkActionBarView, and preserves textView focus.
        textView.mouseDown(with: plainClick)
        try linkCheck(editor.isLinkActionBarVisible, "Re-clicking link should show LinkActionBarView")
        editor.linkActionBar.openButton.performClick(nil)
        try linkCheck(
            openedURLs == [URL(string: "https://swift.org/docs")!],
            "Clicking Open button should invoke urlOpener with https://swift.org/docs, got \(openedURLs)"
        )
        try linkCheck(!editor.isLinkActionBarVisible && editor.linkActionBar.isHidden, "Clicking Open should hide LinkActionBarView")
        try linkCheck(workspace.window?.firstResponder === textView, "Clicking Open must preserve textView focus")

        // 3d. Drag-selection across a link must NOT show LinkActionBarView.
        textView.customMouseSelectionTracker = { tv, _ in
            tv.setSelectedRange(link.labelRange)
        }
        textView.mouseDown(with: plainClick)
        try linkCheck(
            !editor.isLinkActionBarVisible,
            "Dragging to select link text (selectedRange.length > 0) must not show LinkActionBarView"
        )

        // Restore single-click tracker for dismissal checks.
        textView.customMouseSelectionTracker = { tv, ev in
            let localPt = tv.convert(ev.locationInWindow, from: nil)
            let charIdx = tv.characterIndexForInsertion(at: localPt)
            tv.setSelectedRange(NSRange(location: charIdx, length: 0))
        }

        // 3e. Esc (cancelOperation), moving caret outside link, and typing each dismiss LinkActionBarView.
        textView.mouseDown(with: plainClick)
        try linkCheck(editor.isLinkActionBarVisible, "Precondition: LinkActionBarView visible before Esc")
        textView.cancelOperation(nil)
        try linkCheck(!editor.isLinkActionBarVisible, "Pressing Esc (cancelOperation) should dismiss LinkActionBarView")

        textView.mouseDown(with: plainClick)
        try linkCheck(editor.isLinkActionBarVisible, "Precondition: LinkActionBarView visible before cursor move")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        try linkCheck(!editor.isLinkActionBarVisible, "Moving caret outside active link should dismiss LinkActionBarView")

        textView.mouseDown(with: plainClick)
        try linkCheck(editor.isLinkActionBarVisible, "Precondition: LinkActionBarView visible before typing")
        textView.insertText("!", replacementRange: textView.selectedRange())
        try linkCheck(!editor.isLinkActionBarVisible, "Editing text should immediately dismiss LinkActionBarView")
        textView.deleteBackward(nil)

        // 3f. ⌘-Click opens link immediately without moving caret or showing LinkActionBarView.
        openedURLs.removeAll()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let refreshedLink = textView.markdownLinkItems[0]
        let cmdWinPt = try glyphMidpointInWindow(for: refreshedLink.labelRange, in: textView)
        guard let cmdClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: cmdWinPt,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 11,
            clickCount: 1,
            pressure: 1.0
        ) else {
            throw NSError(domain: "LinkInteractionTests", code: 4, userInfo: nil)
        }
        textView.mouseDown(with: cmdClick)
        try linkCheck(
            openedURLs == [URL(string: "https://swift.org/docs")!],
            "⌘-Click on link should immediately open URL, got \(openedURLs)"
        )
        try linkCheck(!editor.isLinkActionBarVisible, "⌘-Click must not leave LinkActionBarView open")
        try linkCheck(
            textView.selectedRange() == NSRange(location: 0, length: 0),
            "⌘-Click must not move existing caret selection"
        )

        // 3g. Right-click context menu prepends "Open Link" and "Copy Link" and executes both actions.
        openedURLs.removeAll()
        isolatedPasteboard.clearContents()
        guard let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: cmdWinPt,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 12,
            clickCount: 1,
            pressure: 1.0
        ), let contextMenu = textView.menu(for: rightClick), contextMenu.items.count >= 2 else {
            throw NSError(domain: "LinkInteractionTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing link context menu"])
        }
        try linkCheck(
            contextMenu.items[0].title == "Open Link" && contextMenu.items[1].title == "Copy Link",
            "Expected 'Open Link' and 'Copy Link' at top of context menu, got \(contextMenu.items.prefix(3).map(\.title))"
        )
        _ = contextMenu.items[1].target?.perform(contextMenu.items[1].action, with: contextMenu.items[1])
        try linkCheck(
            isolatedPasteboard.string(forType: .string) == "https://swift.org/docs",
            "Context menu 'Copy Link' should copy URL to pasteboard"
        )
        if let menuAgain = textView.menu(for: rightClick) {
            _ = menuAgain.items[0].target?.perform(menuAgain.items[0].action, with: menuAgain.items[0])
        }
        try linkCheck(
            openedURLs == [URL(string: "https://swift.org/docs")!],
            "Context menu 'Open Link' should open URL"
        )

        // 3h. Keyboard ⌘Return and Vim Normal mode ('gd' and Return) open link at cursor.
        openedURLs.removeAll()
        textView.setSelectedRange(NSRange(location: refreshedLink.labelRange.location + 2, length: 0))
        if let cmdReturn = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) {
            let handled = textView.performKeyEquivalent(with: cmdReturn)
            try linkCheck(handled, "⌘Return with cursor on Markdown link should be handled")
        }
        try linkCheck(
            openedURLs == [URL(string: "https://swift.org/docs")!],
            "⌘Return should open Markdown link at cursor, got \(openedURLs)"
        )

        openedURLs.removeAll()
        let prevVimPref = Theme.vimModeEnabled
        let prevAllowsVim = editor.allowsVimMode
        Theme.vimModeEnabled = true
        editor.allowsVimMode = true
        editor.syncVimModePreference()
        defer {
            Theme.vimModeEnabled = prevVimPref
            editor.allowsVimMode = prevAllowsVim
            editor.syncVimModePreference()
        }
        textView.setSelectedRange(NSRange(location: refreshedLink.labelRange.location + 2, length: 0))
        for (ch, code) in [("g", UInt16(5)), ("d", UInt16(2))] {
            if let ev = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: workspace.window?.windowNumber ?? 0,
                context: nil,
                characters: ch,
                charactersIgnoringModifiers: ch,
                isARepeat: false,
                keyCode: code
            ) {
                textView.keyDown(with: ev)
            }
        }
        try linkCheck(
            openedURLs == [URL(string: "https://swift.org/docs")!],
            "Vim Normal mode 'gd' should open Markdown link at cursor, got \(openedURLs)"
        )
    }
}

#if canImport(XCTest)
@MainActor
final class LinkInteractionTests: XCTestCase {
    func testMarkdownLinkParsingIncrementalAndInteractions() throws {
        try verifyMarkdownLinkParsingIncrementalAndInteractions()
    }
}
#endif

#if canImport(Testing)
@Suite("Markdown Link Interactions", .serialized)
@MainActor
struct LinkInteractionSuite {
    @Test("Markdown links, autolinks, and bare URLs parse, update incrementally, and support click/open/copy")
    func markdownLinkParsingIncrementalAndInteractions() throws {
        try verifyMarkdownLinkParsingIncrementalAndInteractions()
    }
}
#endif
