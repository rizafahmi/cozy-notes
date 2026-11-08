#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
@testable import CozyCore
@testable import CozySearch
@testable import CozyNotes

#if canImport(XCTest)
@MainActor
final class MobyDickWorkoutTests: XCTestCase {
    func testMobyDickWorkout() throws {
        _ = NSApplication.shared
        let cycles = ProcessInfo.processInfo.environment["MOBY_DICK_CYCLES"].flatMap(Int.init) ?? 2
        let sample = ProcessInfo.processInfo.environment["MOBY_DICK_SAMPLE"] ?? "Whale"
        let report = try MobyDickWorkout.run(repeatCycles: cycles, typingSample: sample)
        print(report.formattedSummary())

        XCTAssertGreaterThan(report.step1.charLength, 1_000_000, "Moby Dick should contain >1M characters")
        XCTAssertTrue(report.step1.wordCountLabel.contains("WORDS"), "Word count footer should populate")
        XCTAssertGreaterThan(report.step2.scrollOriginY, 100_000, "Step 2 should scroll to the end of Moby Dick")
        XCTAssertEqual(report.step2.resizeStepMs.count, 4, "Step 2 should measure all 4 window resize steps")
        XCTAssertGreaterThan(report.step3.scrollOriginY, 50_000, "Step 3 should scroll to the middle of Moby Dick")
        XCTAssertEqual(report.step3.resizeStepMs.count, 4, "Step 3 should measure all 4 window resize steps")
        XCTAssertTrue(report.step4.intactAfterRedo, "Step 4 Select All / Cut / Paste / Undo / Redo must leave Moby Dick intact")
        XCTAssertEqual(report.step5.keystrokeCount, sample.count, "Step 5 should measure each keystroke")
        XCTAssertLessThan(report.step1.cpu.cpuTimeMs, 150.0, "Step 1 CPU time should be < 150ms")
        XCTAssertLessThan(report.step2.resizeAvgMs, 16.0, "Step 2 average resize time should be < 16ms")
        XCTAssertLessThan(report.step3.resizeAvgMs, 16.0, "Step 3 average resize time should be < 16ms")
        XCTAssertLessThan(report.step5.p95KeystrokeMs, 8.0, "Step 5 P95 keystroke latency should be < 8.0ms")
        XCTAssertEqual(report.repeats.count, max(0, cycles), "Step 6 should complete repeated workout cycles")
        for cycle in report.repeats {
            XCTAssertTrue(cycle.step4.intactAfterRedo, "Cycle #\(cycle.cycleIndex) must leave Moby Dick intact")
            XCTAssertLessThan(cycle.step2.resizeAvgMs, 16.0)
            XCTAssertLessThan(cycle.step3.resizeAvgMs, 16.0)
            XCTAssertLessThan(cycle.step5.p95KeystrokeMs, 8.0)
        }
        if !report.repeats.isEmpty {
            let growthPerCycle = (report.memoryFinal.physFootprintMB - report.memoryAfterFirstPass.physFootprintMB) / Double(report.repeats.count)
            XCTAssertLessThan(growthPerCycle, 5.0, "Memory growth per cycle should be < 5 MB/cycle")
        }
    }
}
#endif

#if canImport(Testing)
@Suite("Moby Dick Workout")
struct MobyDickWorkoutSuite {
    @Test("Full Moby Dick Workout (Steps 1–6)")
    @MainActor
    func mobyDickWorkout() throws {
        _ = NSApplication.shared
        let cycles = ProcessInfo.processInfo.environment["MOBY_DICK_CYCLES"].flatMap(Int.init) ?? 2
        let sample = ProcessInfo.processInfo.environment["MOBY_DICK_SAMPLE"] ?? "Whale"
        let report = try MobyDickWorkout.run(repeatCycles: cycles, typingSample: sample)
        print(report.formattedSummary())
        #expect(report.step1.charLength > 1_000_000)
        #expect(report.step1.wordCountLabel.contains("WORDS"))
        #expect(report.step2.scrollOriginY > 100_000)
        #expect(report.step2.resizeStepMs.count == 4)
        #expect(report.step3.scrollOriginY > 50_000)
        #expect(report.step3.resizeStepMs.count == 4)
        #expect(report.step4.intactAfterRedo)
        #expect(report.step5.keystrokeCount == sample.count)
        #expect(report.step1.cpu.cpuTimeMs < 150.0)
        #expect(report.step2.resizeAvgMs < 16.0)
        #expect(report.step3.resizeAvgMs < 16.0)
        #expect(report.step5.p95KeystrokeMs < 8.0)
        #expect(report.repeats.count == max(0, cycles))
        for cycle in report.repeats {
            #expect(cycle.step4.intactAfterRedo)
            #expect(cycle.step2.resizeAvgMs < 16.0)
            #expect(cycle.step3.resizeAvgMs < 16.0)
            #expect(cycle.step5.p95KeystrokeMs < 8.0)
        }
        if !report.repeats.isEmpty {
            let growthPerCycle = (report.memoryFinal.physFootprintMB - report.memoryAfterFirstPass.physFootprintMB) / Double(report.repeats.count)
            #expect(growthPerCycle < 5.0)
        }
    }

    @Test("Markdown formatting preserves headings, quotes, lists, inline tokens, and code fences")
    @MainActor
    func markdownFormattingInvariants() throws {
        _ = NSApplication.shared
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let sample = """
        # Heading One
        ## Heading Two
        > Blockquote callout
        - [x] Completed task
        - [ ] Open task
        1. Numbered item
        Some **bold** and *italic* and `inline` and [link](https://example.com) prose.
        ```swift
        let answer = "42"
        ```
        """
        editor.text = sample
        #expect(editor.textView.headingGutterItems.count == 2)
        #expect(editor.textView.headingGutterItems[0].label == "H1")
        #expect(editor.textView.headingGutterItems[1].label == "H2")
        #expect(editor.textView.blockquoteRanges.count == 1)
        #expect(editor.textView.inlineCodeRanges.count == 1)
        #expect(editor.textView.fencedBlocks.count == 1)
        #expect(editor.wordCount.stringValue.contains("WORDS"))
    }

    @Test("Cut, Copy, Paste, Select All, Undo, and Redo keyboard shortcuts work via menu bar and key equivalents")
    @MainActor
    func clipboardKeyboardShortcuts() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))

        let um = try #require(editor.textView.undoManager)
        let prevGroupsByEvent = um.groupsByEvent
        um.groupsByEvent = false
        defer {
            um.groupsByEvent = prevGroupsByEvent
            window.orderOut(nil)
        }

        func keyEvent(_ chars: String, modifiers: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 0) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars.lowercased(),
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        editor.text = "Hello Cozy World"
        editor.textView.setSelectedRange(NSRange(location: 6, length: 4)) // "Cozy"

        // ⌘C copies "Cozy"
        #expect(window.performKeyEquivalent(with: try keyEvent("c", keyCode: 8)))
        #expect(NSPasteboard.general.string(forType: .string) == "Cozy")

        // ⌘X cuts "Cozy "
        editor.textView.setSelectedRange(NSRange(location: 6, length: 5))
        um.beginUndoGrouping()
        #expect(window.performKeyEquivalent(with: try keyEvent("x", keyCode: 7)))
        um.endUndoGrouping()
        #expect(editor.text == "Hello World")
        #expect(NSPasteboard.general.string(forType: .string) == "Cozy ")

        // ⌘V pastes "Cozy " at the end
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        um.beginUndoGrouping()
        #expect(window.performKeyEquivalent(with: try keyEvent("v", keyCode: 9)))
        um.endUndoGrouping()
        #expect(editor.text == "Hello WorldCozy ")

        // ⌘Z undoes paste, then ⌘Z undoes cut
        #expect(window.performKeyEquivalent(with: try keyEvent("z", keyCode: 6)))
        #expect(editor.text == "Hello World")
        #expect(window.performKeyEquivalent(with: try keyEvent("z", keyCode: 6)))
        #expect(editor.text == "Hello Cozy World")

        // ⇧⌘Z redoes cut and paste
        #expect(window.performKeyEquivalent(with: try keyEvent("Z", modifiers: [.command, .shift], keyCode: 6)))
        #expect(editor.text == "Hello World")
        #expect(window.performKeyEquivalent(with: try keyEvent("Z", modifiers: [.command, .shift], keyCode: 6)))
        #expect(editor.text == "Hello WorldCozy ")

        // ⌘A selects all
        #expect(window.performKeyEquivalent(with: try keyEvent("a", keyCode: 0)))
        #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 16))

        // Verify Edit menu items exist in NSApp.mainMenu with standard key equivalents
        let editMenu = try #require(mainMenu.item(withTitle: "Edit")?.submenu)
        #expect(editMenu.item(withTitle: "Cut")?.keyEquivalent == "x")
        #expect(editMenu.item(withTitle: "Copy")?.keyEquivalent == "c")
        #expect(editMenu.item(withTitle: "Paste")?.keyEquivalent == "v")
        #expect(editMenu.item(withTitle: "Select All")?.keyEquivalent == "a")

        // Verify short strings with identical endpoints/midpoints still copy fresh content
        editor.text = "cat! cut!"
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(window.performKeyEquivalent(with: try keyEvent("c", keyCode: 8)))
        #expect(NSPasteboard.general.string(forType: .string) == "cat!")
        editor.textView.setSelectedRange(NSRange(location: 5, length: 4))
        #expect(window.performKeyEquivalent(with: try keyEvent("c", keyCode: 8)))
        #expect(NSPasteboard.general.string(forType: .string) == "cut!")
    }

    @Test("Deleting an active note checkpoints recovery, removes attachments, and resets workspace to a blank New Folio")
    @MainActor
    func workspaceDeleteNoteFlow() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)
        let fileMenu = try #require(mainMenu.item(withTitle: "File")?.submenu)
        let deleteItem = try #require(fileMenu.item(withTitle: "Delete Note…"))
        #expect(deleteItem.keyEquivalent == "\u{08}")

        let tempBase = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyDeleteTests-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempBase.appendingPathComponent("Vault", isDirectory: true)
        let historyRoot = tempBase.appendingPathComponent("History", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)

        let attachmentFile = tempBase.appendingPathComponent("diagram.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: attachmentFile)

        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        let note = try vault.capture(text: "# Disposable Note\nWith an image attachment.", attachments: [attachmentFile])
        let workspace = WorkspaceController(vault: vault)
        defer {
            workspace.shutdown()
            workspace.window?.orderOut(nil)
        }

        // Initially on a blank New Folio: deleteButton is hidden
        #expect(workspace.noteURL == nil)
        #expect(workspace.deleteButton.isHidden)
        #expect(!workspace.canDeleteNote)

        // Opening the note reveals deleteButton and enables note deletion
        workspace.openNote(note.url)
        #expect(workspace.noteURL == note.url)
        #expect(!workspace.deleteButton.isHidden)
        #expect(workspace.canDeleteNote)
        #expect(workspace.editor.linkedAttachments.count == 1)
        let attachmentFolder = try #require(workspace.editor.linkedAttachments.first?.url.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path))

        // Deleting the active note checkpoints history, removes note & attachment folder, and resets to blank New Folio
        #expect(workspace.performDeleteNote(note.url, moveToTrash: false))
        #expect(!FileManager.default.fileExists(atPath: note.url.path))
        #expect(!FileManager.default.fileExists(atPath: attachmentFolder.path))
        #expect(workspace.noteURL == nil)
        #expect(workspace.editor.text.isEmpty)
        #expect(workspace.deleteButton.isHidden)
        #expect(workspace.editor.status.stringValue == "Moved to Trash")

        let snapshots = try vault.snapshots()
        #expect(snapshots.count == 1)
        #expect(snapshots[0].label == "Before deleting Disposable Note")
    }

    @Test("Markdown formatting keyboard shortcuts toggle bold, italic, underline, strikethrough, inline code, code blocks, links, headings, quotes, and lists")
    @MainActor
    func markdownFormattingKeyboardShortcuts() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)
        let formatMenu = try #require(mainMenu.item(withTitle: "Format")?.submenu)
        #expect(formatMenu.item(withTitle: "Bold")?.keyEquivalent == "b")
        #expect(formatMenu.item(withTitle: "Italic")?.keyEquivalent == "i")
        #expect(formatMenu.item(withTitle: "Underline")?.keyEquivalent == "u")
        #expect(formatMenu.item(withTitle: "Strikethrough")?.keyEquivalent == "x")
        #expect(formatMenu.item(withTitle: "Inline Code")?.keyEquivalent == "e")
        #expect(formatMenu.item(withTitle: "Code Block")?.keyEquivalent == "c")
        #expect(formatMenu.item(withTitle: "Insert Link")?.keyEquivalent == "k")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))
        defer { window.orderOut(nil) }

        func keyEvent(_ chars: String, modifiers: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 0) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars.lowercased(),
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        // 1. Bold (⌘B) wraps and unwraps, and chains cleanly with Italic (⌘I)
        editor.text = "Hello Cozy"
        editor.textView.setSelectedRange(NSRange(location: 6, length: 4)) // "Cozy"
        #expect(window.performKeyEquivalent(with: try keyEvent("b")))
        #expect(editor.text == "Hello **Cozy**")
        #expect(editor.textView.selectedRange() == NSRange(location: 8, length: 4))

        // Chaining ⌘I on **Cozy** produces ***Cozy*** (bold + italic)
        #expect(window.performKeyEquivalent(with: try keyEvent("i")))
        #expect(editor.text == "Hello ***Cozy***")
        #expect(editor.textView.selectedRange() == NSRange(location: 9, length: 4))

        // Toggling ⌘I then ⌘B unwraps back to "Hello Cozy"
        #expect(window.performKeyEquivalent(with: try keyEvent("i")))
        #expect(editor.text == "Hello **Cozy**")
        #expect(window.performKeyEquivalent(with: try keyEvent("b")))
        #expect(editor.text == "Hello Cozy")
        #expect(editor.textView.selectedRange() == NSRange(location: 6, length: 4))

        // 2. Underline (⌘U) wraps in __...__ and applies NSUnderlineStyle.single attribute
        #expect(window.performKeyEquivalent(with: try keyEvent("u")))
        #expect(editor.text == "Hello __Cozy__")
        #expect(editor.textView.selectedRange() == NSRange(location: 8, length: 4))
        let storage = try #require(editor.textView.textStorage)
        let underlineStyle = storage.attribute(.underlineStyle, at: 8, effectiveRange: nil) as? Int
        #expect(underlineStyle == NSUnderlineStyle.single.rawValue)
        #expect(window.performKeyEquivalent(with: try keyEvent("u")))
        #expect(editor.text == "Hello Cozy")

        // 3. Strikethrough (⇧⌘X) wraps in ~~...~~ and applies strikethroughStyle attribute
        #expect(window.performKeyEquivalent(with: try keyEvent("x", modifiers: [.command, .shift])))
        #expect(editor.text == "Hello ~~Cozy~~")
        let strikeStyle = storage.attribute(.strikethroughStyle, at: 8, effectiveRange: nil) as? Int
        #expect(strikeStyle == NSUnderlineStyle.single.rawValue)
        #expect(window.performKeyEquivalent(with: try keyEvent("x", modifiers: [.command, .shift])))
        #expect(editor.text == "Hello Cozy")

        // 4. Inline Code (⌘E) wraps in `...` and populates inlineCodeRanges
        #expect(window.performKeyEquivalent(with: try keyEvent("e")))
        #expect(editor.text == "Hello `Cozy`")
        #expect(editor.textView.inlineCodeRanges == [NSRange(location: 7, length: 4)])
        #expect(window.performKeyEquivalent(with: try keyEvent("e")))
        #expect(editor.text == "Hello Cozy")

        // 5. Code Block (⇧⌘C) wraps and unwraps ```\n...\n``` and populates fencedBlocks
        editor.text = "let x = 42"
        editor.textView.setSelectedRange(NSRange(location: 0, length: 10))
        #expect(window.performKeyEquivalent(with: try keyEvent("c", modifiers: [.command, .shift])))
        #expect(editor.text == "```\nlet x = 42\n```")
        #expect(editor.textView.fencedBlocks.count == 1)
        #expect(window.performKeyEquivalent(with: try keyEvent("c", modifiers: [.command, .shift])))
        #expect(editor.text == "let x = 42")

        // 6. Headings (⌥⌘1, ⌥⌘2), Blockquote (⇧⌘.), Bullet List (⇧⌘8), Numbered List (⇧⌘7), Checklist (⇧⌘L)
        editor.text = "Section Title"
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(window.performKeyEquivalent(with: try keyEvent("1", modifiers: [.command, .option])))
        #expect(editor.text == "# Section Title")
        #expect(window.performKeyEquivalent(with: try keyEvent("2", modifiers: [.command, .option])))
        #expect(editor.text == "## Section Title")
        #expect(window.performKeyEquivalent(with: try keyEvent("2", modifiers: [.command, .option])))
        #expect(editor.text == "Section Title")

        #expect(window.performKeyEquivalent(with: try keyEvent(".", modifiers: [.command, .shift])))
        #expect(editor.text == "> Section Title")
        #expect(window.performKeyEquivalent(with: try keyEvent(".", modifiers: [.command, .shift])))
        #expect(editor.text == "Section Title")

        #expect(window.performKeyEquivalent(with: try keyEvent("8", modifiers: [.command, .shift])))
        #expect(editor.text == "- Section Title")
        #expect(window.performKeyEquivalent(with: try keyEvent("8", modifiers: [.command, .shift])))
        #expect(editor.text == "Section Title")

        #expect(window.performKeyEquivalent(with: try keyEvent("7", modifiers: [.command, .shift])))
        #expect(editor.text == "1. Section Title")
        #expect(window.performKeyEquivalent(with: try keyEvent("7", modifiers: [.command, .shift])))
        #expect(editor.text == "Section Title")

        #expect(window.performKeyEquivalent(with: try keyEvent("l", modifiers: [.command, .shift])))
        #expect(editor.text == "- [ ] Section Title")
        #expect(window.performKeyEquivalent(with: try keyEvent("l", modifiers: [.command, .shift])))
        #expect(editor.text == "Section Title")
    }

    @Test("Multi-level bullet lists compute nesting levels, distinct indentation steps, and indent/outdent via Tab, Shift+Tab, and ⌘] / ⌘[")
    @MainActor
    func multiLevelBulletHierarchy() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)
        let formatMenu = try #require(mainMenu.item(withTitle: "Format")?.submenu)
        #expect(formatMenu.item(withTitle: "Indent List Level")?.keyEquivalent == "]")
        #expect(formatMenu.item(withTitle: "Outdent List Level")?.keyEquivalent == "[")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))
        defer { window.orderOut(nil) }

        editor.text = """
        - Level 0 bullet
          - Level 1 bullet
            - Level 2 bullet
              - Level 3 bullet
        """
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let items = editor.textView.bulletItems
        #expect(items.count == 4)
        #expect(items.map(\.level) == [0, 1, 2, 3])
        #expect(items.allSatisfy { $0.kind == .unordered })

        // Verify progressive 22pt firstLineHeadIndent per level
        let storage = try #require(editor.textView.textStorage)
        for (idx, item) in items.enumerated() {
            let para = try #require(storage.attribute(.paragraphStyle, at: item.lineRange.location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(para.firstLineHeadIndent == CGFloat(idx) * 22.0)
            #expect(para.headIndent == CGFloat(idx) * 22.0 + 18.0)
        }

        // Verify Tab and Shift+Tab / ⌘] and ⌘[ step bullet levels incrementally
        editor.text = "- Adjustable point"
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(editor.textView.bulletItems.first?.level == 0)

        editor.textView.insertTab(nil)
        #expect(editor.text == "  - Adjustable point")
        #expect(editor.textView.bulletItems.first?.level == 1)

        editor.textView.indentListLevel(nil)
        #expect(editor.text == "    - Adjustable point")
        #expect(editor.textView.bulletItems.first?.level == 2)

        editor.textView.insertBacktab(nil)
        #expect(editor.text == "  - Adjustable point")
        #expect(editor.textView.bulletItems.first?.level == 1)

        editor.textView.outdentListLevel(nil)
        #expect(editor.text == "- Adjustable point")
        #expect(editor.textView.bulletItems.first?.level == 0)
    }
}
#endif
