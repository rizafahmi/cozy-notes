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
        XCTAssertGreaterThan(report.outlineFolding.headingCount, 100, "Moby Dick should contain >100 headings")
        XCTAssertTrue(report.outlineFolding.upstreamEditShiftsFoldCorrectly, "Upstream edits must shift downstream folded section ranges")
        XCTAssertTrue(report.outlineFolding.intactAfterCycle, "Outline fold cycle must restore document intact")
        XCTAssertLessThan(report.outlineFolding.foldSingleMs, 25.0, "Single chapter fold should be < 25ms")
        XCTAssertLessThan(report.outlineFolding.unfoldSingleMs, 25.0, "Single chapter unfold should be < 25ms")
        XCTAssertLessThan(report.outlineFolding.totalCycleMs, 100.0, "Full outline fold cycle (Overview -> Headings -> Show All) should be < 100ms")
        XCTAssertGreaterThan(report.inNoteFind.matchCount, 100, "In-Note Find should locate matches across Moby Dick")
        XCTAssertLessThan(report.inNoteFind.searchQueryMs, 50.0, "In-Note Find search across 1.2M chars should be < 50ms")
        XCTAssertLessThan(report.inNoteFind.nextAvgMs, 16.0, "In-Note Find next match navigation should be < 16ms")
        XCTAssertLessThan(report.inNoteFind.prevAvgMs, 16.0, "In-Note Find previous match navigation should be < 16ms")
        XCTAssertTrue(report.syntaxTyping.wikiAutocompleteTriggered, "Typing [[Cetology]] in Moby Dick must trigger wiki autocomplete")
        XCTAssertTrue(report.syntaxTyping.wikiLinkParsed, "Typing [[Cetology]] in Moby Dick must parse WikiLink item")
        XCTAssertTrue(report.syntaxTyping.bulletParsed, "Typing checklist item in Moby Dick must parse bullet item")
        XCTAssertTrue(report.syntaxTyping.intactAfterUndo, "Undoing syntax typing must leave Moby Dick intact")
        XCTAssertLessThan(report.syntaxTyping.p95KeystrokeMs, 12.0, "Syntax & [[WikiLink]] P95 keystroke latency should be < 12ms")
        XCTAssertTrue(report.comparisonWindow.companionSynced, "Saving in main workspace must sync 1.2M-char note to comparison window")
        XCTAssertTrue(report.comparisonWindow.intactAfterRestore, "Comparison window sync workout must leave Moby Dick intact")
        XCTAssertLessThan(report.comparisonWindow.openWindowMs, 200.0, "Opening 1.2M-char comparison window should be < 200ms")
        XCTAssertEqual(report.repeats.count, max(0, cycles), "Step 10 should complete repeated workout cycles")
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

    func testNeoAcidAtmosphereAndVoice() throws {
        _ = NSApplication.shared
        let savedAtmosphere = Theme.atmosphere
        let savedVoice = Theme.voice
        defer {
            Theme.atmosphere = savedAtmosphere
            Theme.voice = savedVoice
        }
        Theme.atmosphere = .neoAcid
        Theme.voice = .neoAcid
        let report = try MobyDickWorkout.run(repeatCycles: 1, typingSample: "Whale")
        XCTAssertLessThan(report.step1.cpu.cpuTimeMs, 150.0)
        XCTAssertLessThan(report.step2.resizeAvgMs, 16.0)
        XCTAssertLessThan(report.step3.resizeAvgMs, 16.0)
        XCTAssertLessThan(report.step5.p95KeystrokeMs, 8.0)
    }
}
#endif

#if canImport(Testing)
@Suite("Moby Dick Workout", .serialized)
struct MobyDickWorkoutSuite {
    @Test("Full Moby Dick Workout (Steps 1–10)")
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
        #expect(report.outlineFolding.headingCount > 100)
        #expect(report.outlineFolding.upstreamEditShiftsFoldCorrectly)
        #expect(report.outlineFolding.intactAfterCycle)
        #expect(report.outlineFolding.foldSingleMs < 25.0)
        #expect(report.outlineFolding.unfoldSingleMs < 25.0)
        #expect(report.outlineFolding.totalCycleMs < 100.0)
        #expect(report.inNoteFind.matchCount > 100)
        #expect(report.inNoteFind.searchQueryMs < 50.0)
        #expect(report.inNoteFind.nextAvgMs < 16.0)
        #expect(report.inNoteFind.prevAvgMs < 16.0)
        #expect(report.syntaxTyping.wikiAutocompleteTriggered)
        #expect(report.syntaxTyping.wikiLinkParsed)
        #expect(report.syntaxTyping.bulletParsed)
        #expect(report.syntaxTyping.intactAfterUndo)
        #expect(report.syntaxTyping.p95KeystrokeMs < 12.0)
        #expect(report.comparisonWindow.companionSynced)
        #expect(report.comparisonWindow.intactAfterRestore)
        #expect(report.comparisonWindow.openWindowMs < 200.0)
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
        workspace.deleteAlertMovesToTrash = false
        #expect(workspace.noteURL == note.url)
        #expect(!workspace.deleteButton.isHidden)
        #expect(workspace.canDeleteNote)
        #expect(workspace.editor.linkedAttachments.count == 1)
        let attachmentFolder = try #require(workspace.editor.linkedAttachments.first?.url.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path))

        func sheetKeyEvent(_ chars: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16, in sheetWindow: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheetWindow.windowNumber,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        // 1. Triggering deleteCurrentNote() (⌘⌫) presents confirmation sheet; Escape cancels without deleting
        workspace.deleteCurrentNote()
        let firstAlert = try #require(workspace.activeDeleteAlert)
        let firstConfirmBtn = try #require(firstAlert.buttons.first)
        #expect(firstConfirmBtn.hasDestructiveAction)
        #expect(firstConfirmBtn.keyEquivalent == "\r")
        #expect(firstAlert.window.defaultButtonCell === firstConfirmBtn.cell)
        #expect(firstAlert.window.firstResponder === firstConfirmBtn)
        #expect(firstAlert.window.performKeyEquivalent(with: try sheetKeyEvent("\u{1B}", keyCode: 53, in: firstAlert.window)))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(workspace.activeDeleteAlert == nil)
        #expect(FileManager.default.fileExists(atPath: note.url.path))
        #expect(workspace.noteURL == note.url)

        // 2. Triggering deleteCurrentNote() (⌘⌫) and pressing Return (\r) on the sheet confirms deletion
        workspace.deleteCurrentNote()
        let secondAlert = try #require(workspace.activeDeleteAlert)
        #expect(secondAlert.window.performKeyEquivalent(with: try sheetKeyEvent("\r", keyCode: 36, in: secondAlert.window)))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(workspace.activeDeleteAlert == nil)
        #expect(!FileManager.default.fileExists(atPath: note.url.path))
        #expect(!FileManager.default.fileExists(atPath: attachmentFolder.path))
        #expect(workspace.noteURL == nil)
        #expect(workspace.editor.text.isEmpty)
        #expect(workspace.deleteButton.isHidden)
        #expect(workspace.editor.status.stringValue == "Moved to Trash")

        let snapshots = try vault.snapshots()
        #expect(snapshots.count == 1)
        #expect(snapshots[0].label == "Before deleting Disposable Note")

        // 3. Triggering deleteCurrentNote() (⌘⌫) and pressing ⌘Return while holding Command also confirms deletion
        let secondNote = try vault.capture(text: "# Second Disposable Note\nBody.")
        workspace.openNote(secondNote.url)
        workspace.deleteCurrentNote()
        let thirdAlert = try #require(workspace.activeDeleteAlert)
        #expect(thirdAlert.window.performKeyEquivalent(with: try sheetKeyEvent("\r", modifiers: .command, keyCode: 36, in: thirdAlert.window)))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(workspace.activeDeleteAlert == nil)
        #expect(!FileManager.default.fileExists(atPath: secondNote.url.path))
        #expect(workspace.noteURL == nil)
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

        // Verify Return preserves nested indentation & marker, and Return on empty nested item stops the list while keeping indentation
        editor.textView.indentListLevel(nil)
        editor.textView.indentListLevel(nil)
        #expect(editor.text == "    - Adjustable point")
        editor.textView.setSelectedRange(NSRange(location: editor.nsText.length, length: 0))
        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.text == "    - Adjustable point\n    - ")
        #expect(editor.textView.selectedRange() == NSRange(location: editor.nsText.length, length: 0))
        #expect(editor.textView.bulletItems.map(\.level) == [2, 2])

        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.text == "    - Adjustable point\n    ")
        #expect(editor.textView.selectedRange() == NSRange(location: editor.nsText.length, length: 0))
        #expect(editor.textView.bulletItems.map(\.level) == [2])
    }

    @Test("Quick Capture deduplicates repeated URLs within one attachment batch before copying files")
    @MainActor
    func quickCaptureDeduplicatesAttachmentBatch() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CozyQuickCaptureAttachments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: base.appendingPathComponent("Vault"), historyRoot: base.appendingPathComponent("History"))
        let source = base.appendingPathComponent("reference.txt")
        let bytes = Data("Preserve this attachment once.".utf8)
        try bytes.write(to: source)
        let quick = QuickCaptureController(vault: vault)
        defer { quick.window?.orderOut(nil) }

        quick.editor.addAttachments([source, source])
        #expect(quick.editor.attachments == [source])
        quick.editor.addAttachments([source, source])
        #expect(quick.editor.attachments == [source])
        quick.save()

        let record = try #require(vault.notes().first)
        let links = vault.linkedAttachments(in: try vault.read(record.url), relativeTo: record.url)
        #expect(links.map { $0.url.lastPathComponent } == ["reference.txt"])
        let attachment = try #require(links.first)
        let files = try FileManager.default.contentsOfDirectory(at: attachment.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent) == ["reference.txt"])
        #expect(try Data(contentsOf: attachment.url) == bytes)
    }

    @Test("Attachment removal keeps the surviving file and reading position, including repeated links and updated button targets")
    @MainActor
    func attachmentRemovalPreservesIdentityAndViewport() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CozyAttachmentFeedback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: base.appendingPathComponent("Vault"), historyRoot: base.appendingPathComponent("History"))
        let firstFile = base.appendingPathComponent("first.txt")
        let secondFile = base.appendingPathComponent("second.txt")
        try "First attachment".write(to: firstFile, atomically: true, encoding: .utf8)
        try "Second attachment".write(to: secondFile, atomically: true, encoding: .utf8)
        let prose = (1...80).map { "Reading anchor line \($0)." }.joined(separator: "\n")
        let record = try vault.capture(text: prose, attachments: [firstFile, secondFile])
        let initialText = try vault.read(record.url)
        let links = vault.linkedAttachments(in: initialText, relativeTo: record.url)
        let firstLink = try #require(links.first)
        let duplicate = (initialText as NSString).substring(with: firstLink.markdownRange)
        try vault.save(initialText + "\n" + duplicate + "\n", to: record.url, expectedContent: initialText)
        let workspace = WorkspaceController(vault: vault)
        workspace.showAndFocus()
        defer {
            workspace.shutdown()
            workspace.window?.orderOut(nil)
        }
        workspace.openNote(record.url)
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let editor = workspace.editor
        let strip = try #require(editor.subviews.compactMap { $0 as? NSScrollView }.first { $0.documentView is NSStackView })
        let chips = try #require(strip.documentView as? NSStackView)
        #expect(editor.linkedAttachments.map(\.url) == [links[0].url, links[1].url, links[0].url])
        let secondCard = chips.arrangedSubviews[1]
        let repeatedCard = chips.arrangedSubviews[2]
        let textScroll = try #require(editor.textView.enclosingScrollView)
        let clip = textScroll.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: 500))
        textScroll.reflectScrolledClipView(clip)
        let anchor = editor.textView.convert(NSPoint(x: 0, y: 560), to: nil)

        func removeButton(in card: NSView) throws -> NSButton {
            let row = try #require(card.subviews.first as? NSStackView)
            return try #require(row.arrangedSubviews.compactMap { $0 as? NSButton }.last)
        }
        func activate(_ button: NSButton) throws {
            let action = try #require(button.action)
            _ = NSApp.sendAction(action, to: button.target, from: button)
        }
        try activate(try removeButton(in: chips.arrangedSubviews[0]))
        #expect(editor.linkedAttachments.map(\.url) == [links[1].url, links[0].url])
        #expect(chips.arrangedSubviews[0] === secondCard)
        #expect(chips.arrangedSubviews[1] === repeatedCard)
        #expect(editor.textView.convert(NSPoint(x: 0, y: 560), to: nil) == anchor)
        try activate(try removeButton(in: secondCard))
        #expect(editor.linkedAttachments.map(\.url) == [links[0].url])
        #expect(chips.arrangedSubviews[0] === repeatedCard)
        try activate(try removeButton(in: repeatedCard))
        #expect(editor.linkedAttachments.isEmpty)
        #expect(strip.isHidden)
        #expect(editor.textView.convert(NSPoint(x: 0, y: 560), to: nil) == anchor)
        #expect((try vault.read(record.url)).hasPrefix(prose))
        for link in links { #expect(FileManager.default.fileExists(atPath: link.url.path)) }
    }

    @Test("Checking and unchecking tasks near viewport edges preserves the caret line, indentation, and scroll position", arguments: [false, true])
    @MainActor
    func checklistMarkerEditsPreserveViewport(includesCodeFence: Bool) throws {
        _ = NSApplication.shared
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

        let prefix = includesCodeFence ? "```text\nExample\n```\n\n" : ""
        editor.text = prefix + (1...40).map { "  - [ ] Task number \($0)" }.joined(separator: "\n")
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let textView = editor.textView
        let scrollView = try #require(textView.enclosingScrollView)
        let clipView = scrollView.contentView
        let marker = editor.nsText.range(of: "[ ] Task number 20")
        let stateRange = NSRange(location: marker.location + 1, length: 1)
        let taskLine = editor.nsText.lineRange(for: marker)

        for nearTop in [true, false] {
            textView.setSelectedRange(stateRange)
            let caretBefore = textView.currentCaretRect()
            let originY = nearTop
                ? caretBefore.minY - 12
                : caretBefore.maxY - clipView.bounds.height + 18
            clipView.setBoundsOrigin(NSPoint(x: 0, y: originY))
            scrollView.reflectScrolledClipView(clipView)

            for state in ["x", " ", "X", " "] {
                textView.setSelectedRange(stateRange)
                let savedOrigin = clipView.bounds.origin
                let caretY = textView.currentCaretRect().minY - savedOrigin.y
                textView.insertText(state, replacementRange: stateRange)

                #expect(editor.nsText.substring(with: NSRange(location: marker.location, length: 3)) == "[\(state)]")
                #expect(textView.selectedRange() == NSRange(location: NSMaxRange(stateRange), length: 0))
                #expect(editor.nsText.lineRange(for: textView.selectedRange()) == taskLine)
                #expect(clipView.bounds.origin == savedOrigin, "Changing a visible checkbox must not scroll the viewport")
                #expect(abs(textView.currentCaretRect().minY - clipView.bounds.origin.y - caretY) <= 0.5)
                let task = try #require(textView.bulletItems.first { $0.lineRange.location == taskLine.location })
                #expect(task.level == 1)
                #expect(task.kind == .task(completed: state != " "))
            }
        }
    }

    @Test("Typing, newlines, and arrow navigation below the fold automatically scroll the cursor up with ~30% breathing room")
    @MainActor
    func belowTheFoldAutoScroll() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }

        let textView = editor.textView
        let scrollView = try #require(textView.enclosingScrollView)
        let clipView = scrollView.contentView
        let visHeight = clipView.bounds.height
        #expect(editor.bounds.height - visHeight <= 50, "Hidden attachment strip must collapse to zero height so text extends down to the footer rule")

        // Start with 20 lines so the bottom lines extend well below the 320pt window
        let lines = (1...20).map { "Line number \($0) of the journal folio." }.joined(separator: "\n")
        editor.text = lines
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Scroll to top (originY = 0) while placing the cursor at the very end of line 20 (below the fold)
        clipView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(clipView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))

        // Navigating to the end below the fold must scroll clipView up so the caret sits at ~70% of visHeight (~30% breathing room below)
        let caretAfterNav = textView.currentCaretRect()
        let scrolledOriginAfterNav = clipView.bounds.origin.y
        #expect(scrolledOriginAfterNav > 0, "Viewport should scroll down when cursor moves below the fold")
        let bottomRoomAfterNav = (scrolledOriginAfterNav + visHeight) - caretAfterNav.maxY
        #expect(abs(bottomRoomAfterNav - round(visHeight * 0.30)) <= 4.0, "Cursor should have ~30% viewport breathing room below it")

        // Typing new lines at the end of the document keeps scrolling up and expanding document height to preserve ~30% breathing room
        let originBeforeNewlines = clipView.bounds.origin.y
        for i in 1...4 {
            textView.insertText("\nAppended line \(i) below the fold", replacementRange: textView.selectedRange())
        }
        let caretAfterTyping = textView.currentCaretRect()
        let originAfterTyping = clipView.bounds.origin.y
        #expect(originAfterTyping > originBeforeNewlines, "Typing new lines at the bottom must continue scrolling up")
        let bottomRoomAfterTyping = (originAfterTyping + visHeight) - caretAfterTyping.maxY
        let minComfortRoom = max(28.0, min(56.0, round(visHeight * 0.12))) - 2.0
        let maxTypewriterRoom = round(visHeight * 0.30) + 4.0
        #expect(bottomRoomAfterTyping >= minComfortRoom && bottomRoomAfterTyping <= maxTypewriterRoom, "Even on the last line, cursor must stay inside the typewriter comfort band")

        // Typing while already inside the comfort zone must not jump the scroll origin
        let steadyOrigin = clipView.bounds.origin.y
        textView.insertText("!", replacementRange: textView.selectedRange())
        #expect(abs(clipView.bounds.origin.y - steadyOrigin) < 0.01, "Same-line typing inside the comfort zone must remain steady")
    }

    @Test("Org-mode heading folding collapses subtrees in layout, cycles Overview -> Headings Only -> Show All, and auto-unfolds on edit without mutating Markdown text")
    @MainActor
    func orgModeHeadingFolding() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)
        let formatMenu = try #require(mainMenu.item(withTitle: "Format")?.submenu)
        #expect(formatMenu.item(withTitle: "Toggle Heading Fold")?.keyEquivalent == "[")
        #expect(formatMenu.item(withTitle: "Unfold Heading Section")?.keyEquivalent == "]")
        #expect(formatMenu.item(withTitle: "Cycle Outline Folding")?.keyEquivalent == "[")
        #expect(formatMenu.item(withTitle: "Unfold All Headings")?.keyEquivalent == "]")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))
        defer { window.orderOut(nil) }

        let markdown = """
        # Part One
        Intro paragraph line 1.
        Intro paragraph line 2.
        ## Subsection 1.1
        Details inside subsection 1.1.
        More details inside 1.1.
        # Part Two
        Second part prose line.
        """
        editor.text = markdown
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let textView = editor.textView
        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        #expect(textView.headingGutterItems.count == 3)
        let h1PartOne = textView.headingGutterItems[0]
        let h2Sub = textView.headingGutterItems[1]
        let h1PartTwo = textView.headingGutterItems[2]

        func yOfHeading(_ item: MarkdownTextView.HeadingGutter) -> CGFloat {
            let gr = lm.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
            return lm.boundingRect(forGlyphRange: gr, in: tc).minY
        }

        let partTwoUnfoldedY = yOfHeading(h1PartTwo)
        #expect(partTwoUnfoldedY > yOfHeading(h1PartOne) + 80)

        // 1. Place cursor on "# Part One" and press Tab -> folds Part One's entire subtree (including ## Subsection 1.1) up to "# Part Two"
        textView.setSelectedRange(NSRange(location: h1PartOne.range.location + 2, length: 0))
        textView.insertTab(nil)
        window.displayIfNeeded()

        #expect(textView.foldedSections.count == 1)
        #expect(textView.foldedSections[0].headingLocation == h1PartOne.range.location)
        #expect(textView.foldedSections[0].hiddenLineCount == 5)
        #expect(textView.isCharacterFolded(h2Sub.range.location))
        #expect(!textView.isCharacterFolded(h1PartTwo.range.location))
        #expect(editor.text == markdown, "Folding must never alter underlying Markdown text")

        let partTwoFoldedY = yOfHeading(h1PartTwo)
        let firstGlyphs = lm.glyphRange(forCharacterRange: h1PartOne.range, actualCharacterRange: nil)
        let firstHeadingRect = lm.boundingRect(forGlyphRange: firstGlyphs, in: tc)
        #expect(partTwoFoldedY - firstHeadingRect.maxY <= 40, "Folding must leave only normal heading spacing, not hidden body height")

        // Pressing Tab again on "# Part One" unfolds it
        textView.insertTab(nil)
        #expect(textView.foldedSections.isEmpty)
        #expect(abs(yOfHeading(h1PartTwo) - partTwoUnfoldedY) < 1.0)

        // 2. Shift+Tab on a heading cycles Org-mode global outline states: Overview -> Headings Only -> Show All
        textView.insertBacktab(nil)
        #expect(textView.outlineFoldMode == .overview)
        #expect(textView.foldedSections.count == 2) // Both H1 sections folded
        #expect(textView.isCharacterFolded(h2Sub.range.location))

        textView.insertBacktab(nil)
        #expect(textView.outlineFoldMode == .headingsOnly)
        #expect(textView.foldedSections.count == 3) // Body under each heading folded, all headings visible
        #expect(!textView.isCharacterFolded(h2Sub.range.location))

        textView.insertBacktab(nil)
        #expect(textView.outlineFoldMode == .showAll)
        #expect(textView.foldedSections.isEmpty)

        // 3. Upstream edit while a later heading is folded shifts the folded section's range in lockstep
        textView.toggleFold(forHeadingAt: h1PartTwo.range.location)
        #expect(textView.foldedSections.count == 1)
        let insertLoc = NSMaxRange(h1PartOne.range)
        textView.insertText(" — Expanded", replacementRange: NSRange(location: insertLoc, length: 0))
        let updatedPartTwo = textView.headingGutterItems[2]
        #expect(textView.foldedSections.count == 1)
        #expect(textView.foldedSections[0].headingLocation == updatedPartTwo.range.location)
        #expect(textView.foldedSections[0].headingRange == updatedPartTwo.range)
        textView.toggleFold(forHeadingAt: updatedPartTwo.range.location)
        #expect(textView.foldedSections.isEmpty)

        // 4. Auto-unfold on edit: folding a section and editing inside/on it automatically unfolds
        let currentSub = textView.headingGutterItems[1]
        textView.toggleFold(forHeadingAt: currentSub.range.location)
        #expect(textView.foldedSections.count == 1)
        textView.insertText("!", replacementRange: NSRange(location: NSMaxRange(currentSub.range), length: 0))
        #expect(textView.foldedSections.isEmpty, "Editing a folded heading automatically unfolds its section")
    }

    @Test("Folding mixed Markdown removes hidden layout height and preserves the next heading through resize, unfold, and outline cycles", arguments: [1, 160], ["\n", "\r\n"])
    @MainActor
    func foldedSectionsCollapseMixedContent(repetitions: Int, newline: String) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))
        defer { window.orderOut(nil) }

        let block = """
        ### Nested heading

        Prose with **bold**, *italic*, __underline__, `inline code`, and [[Reference]].
        A second paragraph keeps its own font and paragraph spacing before the next construct.

        ```swift
        let message = "Hidden code"
        print(message)
        ```

        - [ ] Open task
          - [x] Nested completed task

        > Quoted text with a different font and indentation.

        | Name | Description |
        |------|-------------|
        | Item | A table cell with `inline code` and enough text to exercise wrapping. |


        """
        let markdown = ("## First section\n\n" + String(repeating: block, count: repetitions)
            + "## Next section\n\nVisible body.\n\n## Final section\n\n" + block)
            .replacingOccurrences(of: "\n", with: newline)
        editor.text = markdown
        window.contentView?.layoutSubtreeIfNeeded()
        let textView = editor.textView
        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        let storage = try #require(textView.textStorage)
        let first = try #require(textView.headingGutterItems.first { $0.title == "First section" })
        let next = try #require(textView.headingGutterItems.first { $0.title == "Next section" })
        let final = try #require(textView.headingGutterItems.first { $0.title == "Final section" })
        textView.setSelectedRange(NSRange(location: first.range.location + 3, length: 0))
        lm.ensureLayout(for: tc)
        window.displayIfNeeded()

        func headingRect(_ heading: MarkdownTextView.HeadingGutter) -> NSRect {
            lm.ensureLayout(forCharacterRange: heading.range)
            let glyphs = lm.glyphRange(forCharacterRange: heading.range, actualCharacterRange: nil)
            return lm.boundingRect(forGlyphRange: glyphs, in: tc)
        }
        let unfoldedNext = headingRect(next)
        let firstParagraph = try #require(storage.attribute(.paragraphStyle, at: first.range.location, effectiveRange: nil) as? NSParagraphStyle)
        let nextParagraph = try #require(storage.attribute(.paragraphStyle, at: next.range.location, effectiveRange: nil) as? NSParagraphStyle)
        let normalSpacing = firstParagraph.paragraphSpacing + nextParagraph.paragraphSpacingBefore

        func expectCompactFold() throws {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let firstRect = headingRect(first)
            let nextRect = headingRect(next)
            #expect(abs(nextRect.minY - firstRect.maxY - normalSpacing) <= 1)
            #expect(abs(nextRect.minX - unfoldedNext.minX) <= 0.5)
            #expect(abs(nextRect.height - unfoldedNext.height) <= 0.5)
            #expect(textView.visibleRect.intersects(nextRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)), "The next header must be visible without scrolling through hidden content")
            let fold = try #require(textView.foldedSection(forHeadingAt: first.range.location))
            let glyphs = lm.glyphRange(forCharacterRange: fold.foldedCharRange, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, fragmentGlyphs, _ in
                let characters = lm.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
                if characters.location >= fold.foldedCharRange.location, NSMaxRange(characters) <= NSMaxRange(fold.foldedCharRange) {
                    #expect(rect.height == 0, "Hidden paragraphs must occupy no vertical layout space")
                }
                for index in fragmentGlyphs.location..<NSMaxRange(fragmentGlyphs) {
                    #expect(lm.notShownAttribute(forGlyphAt: index), "Folded text must not draw over the next visible section")
                }
            }
            #expect(editor.text == markdown)
        }

        textView.toggleFold(forHeadingAt: first.range.location)
        try expectCompactFold()
        window.setContentSize(NSSize(width: 620, height: 520))
        try expectCompactFold()
        window.setContentSize(NSSize(width: 760, height: 520))
        try expectCompactFold()

        textView.toggleFold(forHeadingAt: first.range.location)
        lm.ensureLayout(for: tc)
        #expect(abs(headingRect(next).minY - unfoldedNext.minY) <= 1, "Unfolding must restore the original section layout")
        textView.cycleOutlineFolding(nil)
        try expectCompactFold()
        let finalRect = headingRect(final)
        #expect(lm.usedRect(for: tc).maxY - finalRect.maxY <= 40, "Folding the last section must not leave a blank document tail")
        textView.cycleOutlineFolding(nil)
        #expect(!textView.isCharacterFolded(textView.headingGutterItems[1].range.location), "Headings Only must retain nested headings")
        for fold in textView.foldedSections {
            let glyphs = lm.glyphRange(forCharacterRange: fold.foldedCharRange, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, fragmentGlyphs, _ in
                let characters = lm.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
                if characters.location >= fold.foldedCharRange.location, NSMaxRange(characters) <= NSMaxRange(fold.foldedCharRange) {
                    #expect(rect.height == 0, "Headings Only must collapse body layout without hiding nested titles")
                }
            }
        }
        textView.cycleOutlineFolding(nil)
        lm.ensureLayout(for: tc)
        #expect(abs(headingRect(next).minY - unfoldedNext.minY) <= 1)
        #expect(editor.text == markdown)
    }

    @Test("Gutter and outline folding stay compact after resizing with the caret outside the folded headings", arguments: [false, true], [false, true])
    @MainActor
    func foldedMouseControlsResizeWithCaretElsewhere(useOutline: Bool, caretBelow: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 1120, height: 540))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))
        defer { window.orderOut(nil) }
        let block = """
        Prose with **bold**, *italic*, and `inline code`.

        ```swift
        let message = "Hidden code"
        print(message)
        ```

        - [ ] Open task
          - [x] Nested completed task

        > Quoted text with different indentation.

        | Name | Description |
        |------|-------------|
        | Item | Hidden table cell |


        """
        let body = String(repeating: block, count: 40)
        let markdown = "# Preface\n\nKeep writing above.\n\n## First fold\n\n" + body
            + "## Second fold\n\n" + body + "## Next section\n\nKeep writing below."
        editor.text = markdown
        editor.setOutlineVisible(useOutline)
        window.contentView?.layoutSubtreeIfNeeded()
        let textView = editor.textView
        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        let scrollView = try #require(textView.enclosingScrollView)
        lm.ensureLayout(for: tc)
        let first = try #require(textView.headingGutterItems.first { $0.title == "First fold" })
        let second = try #require(textView.headingGutterItems.first { $0.title == "Second fold" })
        let next = try #require(textView.headingGutterItems.first { $0.title == "Next section" })
        let caretText = caretBelow ? "Keep writing below." : "Keep writing above."
        let selection = NSRange(location: editor.nsText.range(of: caretText).location + 5, length: 0)
        textView.setSelectedRange(selection)
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        func headingRect(_ heading: MarkdownTextView.HeadingGutter) -> NSRect {
            lm.ensureLayout(forCharacterRange: heading.range)
            return lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: heading.range, actualCharacterRange: nil), in: tc)
        }
        func clickFold(_ heading: MarkdownTextView.HeadingGutter) throws {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            textView.display()
            let target: NSView
            let point: NSPoint
            if useOutline {
                let outline = try #require(editor.subviews.compactMap { $0 as? DocumentOutlineView }.first)
                let outlineScroll = try #require(outline.subviews.compactMap { $0 as? NSScrollView }.first)
                target = try #require(outlineScroll.documentView)
                let index = try #require(outline.items.firstIndex { $0.headingLocation == heading.range.location })
                point = NSPoint(x: 16, y: 6 + CGFloat(index) * DocumentOutlineView.rowHeight + DocumentOutlineView.rowHeight / 2)
            } else {
                target = textView
                let rect = headingRect(heading)
                let origin = textView.textContainerOrigin
                let badgeSize = ("▾ \(heading.label)" as NSString).size(withAttributes: [.font: Theme.monoFont(9.5, weight: .semibold)])
                point = NSPoint(
                    x: origin.x - 18 - badgeSize.width / 2,
                    y: origin.y + rect.minY + max(0, (rect.height - badgeSize.height) / 2) - 2 + badgeSize.height / 2
                )
            }
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: target.convert(point, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            target.mouseDown(with: event)
            #expect(textView.foldedSection(forHeadingAt: heading.range.location) != nil)
            #expect(textView.selectedRange() == selection, "Folding through mouse controls must preserve the caret elsewhere")
        }

        try clickFold(first)
        try clickFold(second)
        let firstParagraph = try #require(textView.textStorage?.attribute(.paragraphStyle, at: first.range.location, effectiveRange: nil) as? NSParagraphStyle)
        let secondParagraph = try #require(textView.textStorage?.attribute(.paragraphStyle, at: second.range.location, effectiveRange: nil) as? NSParagraphStyle)
        let nextParagraph = try #require(textView.textStorage?.attribute(.paragraphStyle, at: next.range.location, effectiveRange: nil) as? NSParagraphStyle)
        for width: CGFloat in [1120, 620, 1120] {
            window.setContentSize(NSSize(width: width, height: 540))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let firstRect = headingRect(first)
            let secondRect = headingRect(second)
            let nextRect = headingRect(next)
            #expect(abs(secondRect.minY - firstRect.maxY - firstParagraph.paragraphSpacing - secondParagraph.paragraphSpacingBefore) <= 1)
            #expect(abs(nextRect.minY - secondRect.maxY - secondParagraph.paragraphSpacing - nextParagraph.paragraphSpacingBefore) <= 1)
            #expect(textView.visibleRect.intersects(nextRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)), "Visible mouse-folded spans must stay collapsed regardless of caret location")
            #expect(textView.selectedRange() == selection)
            #expect(editor.text == markdown)
        }
    }

    @Test("Wiki-links highlight, trigger floating [[ autocomplete, and navigate or create notes on ⌘-Click and ⌥⌘Return")
    @MainActor
    func wikiLinksAutocompleteAndNavigation() throws {
        _ = NSApplication.shared
        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CozyNotesWikiTests-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        let historyRoot = tempRoot.appendingPathComponent("History", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        let targetNote = try vault.capture(text: "# Field Research\n Botanical observations and sketches.")
        let secondNote = try vault.capture(text: "# Reading List\n Books to read.")

        let workspace = WorkspaceController(vault: vault)
        workspace.showWindow(nil)
        defer {
            workspace.shutdown()
            workspace.window?.orderOut(nil)
        }

        let editor = workspace.editor
        let textView = editor.textView
        workspace.openNote(secondNote.url)
        #expect(workspace.noteURL == secondNote.url)

        // 1. Typing `[[` at the end of the note triggers the floating autocomplete popup
        let endLoc = editor.nsText.length
        textView.setSelectedRange(NSRange(location: endLoc, length: 0))
        textView.insertText("\nSee [[", replacementRange: NSRange(location: endLoc, length: 0))
        #expect(editor.isWikiAutocompleteVisible)
        #expect(editor.wikiCompletionItems.contains { $0.title == "Field Research" && !$0.isCreateNew })

        // 2. Typing filter query narrows completion items to matching note
        textView.insertText("Field", replacementRange: textView.selectedRange())
        #expect(editor.isWikiAutocompleteVisible)
        #expect(editor.wikiCompletionItems.first?.title == "Field Research")

        // 3. Pressing Return commits `[[Field Research]]` and dismisses the popup
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(!editor.isWikiAutocompleteVisible)
        #expect(editor.text.hasSuffix("See [[Field Research]]"))
        #expect(textView.wikiLinkItems.count == 1)
        #expect(textView.wikiLinkItems[0].target == "Field Research")

        // 4. ⌘-Clicking the `[[Field Research]]` link navigates WorkspaceController to Field Research
        let linkItem = textView.wikiLinkItems[0]
        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        lm.ensureLayout(for: tc)
        let gr = lm.glyphRange(forCharacterRange: linkItem.innerRange, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
        let clickPointInTextView = NSPoint(
            x: textView.textContainerOrigin.x + rect.midX,
            y: textView.textContainerOrigin.y + rect.midY
        )
        let clickPointInWindow = textView.convert(clickPointInTextView, to: nil)
        let cmdClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPointInWindow,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ))
        textView.mouseDown(with: cmdClick)
        #expect(workspace.noteURL == targetNote.url)

        // 5. Typing a link to a non-existent note `[[Uncharted Territory]]` and activating via `openWikiLinkAtCursor` creates & opens it
        let targetEnd = editor.nsText.length
        textView.setSelectedRange(NSRange(location: targetEnd, length: 0))
        textView.insertText("\nNext: [[Uncharted Territory", replacementRange: NSRange(location: targetEnd, length: 0))
        #expect(editor.isWikiAutocompleteVisible)
        #expect(editor.wikiCompletionItems.contains { $0.title == "Uncharted Territory" && $0.isCreateNew })

        // Commit via Tab
        textView.insertTab(nil)
        #expect(!editor.isWikiAutocompleteVisible)
        #expect(editor.text.hasSuffix("[[Uncharted Territory]]"))

        // Place cursor inside the new link and open via ⌘Return (Command + Return) keyboard shortcut
        textView.setSelectedRange(NSRange(location: editor.nsText.length - 3, length: 0))
        let cmdReturn = try #require(NSEvent.keyEvent(
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
        ))
        #expect(textView.performKeyEquivalent(with: cmdReturn))
        let createdURL = try #require(workspace.noteURL)
        #expect(createdURL != targetNote.url)
        #expect(createdURL != secondNote.url)
        #expect(editor.text == "# Uncharted Territory\n\n")

        // Also verify ⌥⌘K wraps selection in [[...]] and ⌥⌘Return / ⌘O open it
        textView.insertText("Back to Reading List", replacementRange: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: editor.nsText.length - 12, length: 12)) // "Reading List"
        let optCmdK = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        ))
        #expect(textView.performKeyEquivalent(with: optCmdK))
        #expect(editor.text.hasSuffix("[[Reading List]]"))

        let optCmdReturn = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        #expect(textView.performKeyEquivalent(with: optCmdReturn))
        #expect(workspace.noteURL == secondNote.url)
    }

    @Test("Global Note Search Quick Switcher (⌘P / ⇧⌘F / ⌘O) works in Focus Mode, boosts title matches across all vault items, and opens selected note")
    @MainActor
    func globalNoteSearchQuickSwitcher() throws {
        _ = NSApplication.shared
        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CozyQuickSwitcherTests-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        let historyRoot = tempRoot.appendingPathComponent("History", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        // Create a note that mentions "Atlas" only in the body first (alphabetically earlier path)
        let bodyMatchNote = try vault.capture(text: "# Daily Log\nReviewed the Atlas specification today.")
        Thread.sleep(forTimeInterval: 0.01)
        // Create a note whose title is "Atlas Architecture"
        let titleMatchNote = try vault.capture(text: "# Atlas Architecture\nCore system boundaries.")
        // Also add a non-note text file in the vault to verify all vault items are included
        let clipURL = vaultRoot.appendingPathComponent("atlas-notes.txt")
        try "Plain text clipping for Atlas.".write(to: clipURL, atomically: true, encoding: .utf8)

        let workspace = WorkspaceController(vault: vault)
        workspace.showWindow(nil)
        defer {
            workspace.shutdown()
            workspace.window?.orderOut(nil)
        }

        workspace.openNote(bodyMatchNote.url)
        // Collapse sidebar into Focus Mode (⌘\)
        workspace.toggleSidebar()
        #expect(workspace.isSidebarCollapsed)
        #expect(!workspace.isQuickSwitcherVisible)

        // 1. Summon Quick Switcher via ⌘P while sidebar remains collapsed
        let cmdP = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ))
        #expect(workspace.editor.textView.performKeyEquivalent(with: cmdP))
        #expect(workspace.isQuickSwitcherVisible)
        #expect(workspace.isSidebarCollapsed, "Quick Switcher must not force sidebar open in Focus Mode")
        #expect(workspace.quickSwitcher.hits.count == 3)

        // 2. Typing "Atlas" ranks the title match ("Atlas Architecture") ahead of body/filename matches
        workspace.quickSwitcher.query = "Atlas"
        #expect(workspace.quickSwitcher.hits.count == 3)
        #expect(workspace.quickSwitcher.hits[0].source.url == titleMatchNote.url)
        #expect(workspace.quickSwitcher.selectedIndex == 0)

        // 3. Confirming selection opens "Atlas Architecture" and dismisses the Quick Switcher
        #expect(workspace.quickSwitcher.confirmSelection())
        #expect(!workspace.isQuickSwitcherVisible)
        #expect(workspace.noteURL == titleMatchNote.url)
        #expect(workspace.isSidebarCollapsed)

        // 4. Summoning via ⇧⌘F and navigating down with ↓ opens the second result
        let shiftCmdF = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            characters: "F",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ))
        #expect(workspace.editor.textView.performKeyEquivalent(with: shiftCmdF))
        #expect(workspace.isQuickSwitcherVisible)
        workspace.quickSwitcher.query = "Daily"
        #expect(workspace.quickSwitcher.hits.first?.source.url == bodyMatchNote.url)
        #expect(workspace.quickSwitcher.confirmSelection())
        #expect(workspace.noteURL == bodyMatchNote.url)

        // 5. Pressing ⌘F opens In-Note Find inside the active editor document without expanding the sidebar
        workspace.editor.text = "# Daily Log\nAtlas first match and Atlas second match."
        workspace.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let cmdF = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ))
        #expect(workspace.editor.textView.performKeyEquivalent(with: cmdF))
        #expect(workspace.editor.isInNoteFindVisible)
        #expect(workspace.isSidebarCollapsed)

        workspace.editor.inNoteFindQuery = "Atlas"
        #expect(workspace.editor.inNoteFindMatchCount == 2)
        #expect(workspace.editor.activeInNoteFindMatchIndex == 0)
        let firstMatchRange = workspace.editor.textView.selectedRange()
        #expect(firstMatchRange.length == 5)

        workspace.editor.findNextInNote()
        #expect(workspace.editor.activeInNoteFindMatchIndex == 1)
        #expect(workspace.editor.textView.selectedRange().location > firstMatchRange.location)

        workspace.editor.findPreviousInNote()
        #expect(workspace.editor.activeInNoteFindMatchIndex == 0)
        #expect(workspace.editor.textView.selectedRange() == firstMatchRange)

        workspace.editor.hideInNoteFind()
        #expect(!workspace.editor.isInNoteFindVisible)
        #expect(workspace.editor.inNoteFindMatchCount == 0)
    }

    @Test("Comparison note windows open via header/menu, Quick Switcher ⌥Return, and WikiLink ⌥⌘-Click, deduplicate per note, sync clean edits bidirectional without CAS conflict, and close on note deletion")
    @MainActor
    func comparisonNoteWindows() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)
        let fileMenu = try #require(mainMenu.item(withTitle: "File")?.submenu)
        #expect(fileMenu.item(withTitle: "Open in New Window")?.keyEquivalent == "o")
        let formatMenu = try #require(mainMenu.item(withTitle: "Format")?.submenu)
        #expect(formatMenu.item(withTitle: "Open Note Link in New Window") != nil)

        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CozyComparisonWindowTests-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        let historyRoot = tempRoot.appendingPathComponent("History", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        let noteA = try vault.capture(text: "# Primary Hypothesis\nCompare against [[Counter Hypothesis]].")
        Thread.sleep(forTimeInterval: 0.01)
        let noteB = try vault.capture(text: "# Counter Hypothesis\nAlternative observations.")
        Thread.sleep(forTimeInterval: 0.01)
        let noteC = try vault.capture(text: "# Synthesis Notes\nThird reference document.")

        let workspace = WorkspaceController(vault: vault)
        workspace.showWindow(nil)
        defer {
            workspace.shutdown()
            workspace.window?.orderOut(nil)
        }

        #expect(workspace.openInNewWindowButton.isHidden)
        workspace.openNote(noteA.url)
        #expect(!workspace.openInNewWindowButton.isHidden)
        #expect(workspace.noteWindows.isEmpty)

        // 1. ⌥⌘-Clicking [[Counter Hypothesis]] opens noteB in a secondary comparison window while main workspace stays on noteA
        let textView = workspace.editor.textView
        let linkItem = try #require(textView.wikiLinkItems.first)
        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        lm.ensureLayout(for: tc)
        let gr = lm.glyphRange(forCharacterRange: linkItem.innerRange, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
        let clickPt = textView.convert(
            NSPoint(x: textView.textContainerOrigin.x + rect.midX, y: textView.textContainerOrigin.y + rect.midY),
            to: nil
        )
        let optCmdClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPt,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ))
        textView.mouseDown(with: optCmdClick)

        #expect(workspace.noteURL == noteA.url, "Main workspace must remain on Primary Hypothesis")
        #expect(workspace.noteWindows.count == 1)
        let winB = try #require(workspace.noteWindows.first)
        #expect(winB.noteURL == noteB.url)
        #expect(winB.editor.text.contains("Alternative observations."))
        #expect(winB.window?.frame.width == 720)

        // 2. Requesting openNoteInNewWindow for an already-open note reuses the existing NoteWindowController
        let duplicateB = workspace.openNoteInNewWindow(noteB.url)
        #expect(duplicateB === winB)
        #expect(workspace.noteWindows.count == 1)

        // 3. Quick Switcher confirmSelection(inNewWindow: true) opens noteC in a second comparison window without changing workspace.noteURL
        workspace.showQuickSwitcher()
        workspace.quickSwitcher.query = "Synthesis"
        #expect(workspace.quickSwitcher.hits.first?.source.url == noteC.url)
        #expect(workspace.quickSwitcher.confirmSelection(inNewWindow: true))
        #expect(workspace.noteURL == noteA.url)
        #expect(workspace.noteWindows.count == 2)
        let winC = try #require(workspace.noteWindows.last)
        #expect(winC.noteURL == noteC.url)

        // 4. Same-note bidirectional sync: open noteA in a comparison window too, edit in comparison window, verify main workspace updates cleanly
        let winA = try #require(workspace.openNoteInNewWindow(noteA.url))
        #expect(workspace.noteWindows.count == 3)
        let endA = winA.editor.nsText.length
        winA.editor.textView.setSelectedRange(NSRange(location: endA, length: 0))
        winA.editor.textView.insertText("\nAdded from comparison window.", replacementRange: NSRange(location: endA, length: 0))
        #expect(winA.persistCurrent())
        #expect(workspace.editor.text.hasSuffix("Added from comparison window."))

        // Edit noteA in main workspace and verify winA receives the update cleanly without CAS conflict
        let mainEndA = workspace.editor.nsText.length
        workspace.editor.textView.setSelectedRange(NSRange(location: mainEndA, length: 0))
        workspace.editor.textView.insertText("\nAdded from main workspace.", replacementRange: NSRange(location: mainEndA, length: 0))
        #expect(workspace.persistCurrent())
        #expect(!winA.noteConflicted)
        #expect(winA.editor.text.hasSuffix("Added from main workspace."))

        // 5. Deleting noteB closes winB automatically while keeping winA and winC open
        #expect(workspace.performDeleteNote(noteB.url, moveToTrash: false))
        #expect(workspace.noteWindows.count == 2)
        #expect(!workspace.noteWindows.contains { $0 === winB })
    }

    @Test("Document Outline rail excludes fenced code comments, tracks active heading, jumps/unfolds sections, and External Edit Review Banner handles Reload, Overwrite, and Keep Copy")
    @MainActor
    func documentOutlineAndExternalEditReviewBanner() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)
        let viewMenu = try #require(mainMenu.item(withTitle: "View")?.submenu)
        #expect(viewMenu.item(withTitle: "Toggle Document Outline") != nil)

        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CozyHarnessCompanionTests-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempRoot.appendingPathComponent("RepoVault", isDirectory: true)
        let historyRoot = tempRoot.appendingPathComponent("History", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        let planURL = vaultRoot.appendingPathComponent("PLAN.md")
        let initialPlan = """
        # Architecture Plan
        Initial overview paragraph.

        ```sh
        # This shell comment inside a code fence is NOT a heading
        - Nor is this a bullet item
        echo "hello"
        ```

        ## Storage Layer
        Details about storage invariants.

        ### Atomic Writes
        Temp file + rename details.
        """
        try initialPlan.write(to: planURL, atomically: true, encoding: .utf8)

        let workspace = WorkspaceController(vault: vault)
        workspace.showWindow(nil)
        defer {
            workspace.shutdown()
            workspace.window?.orderOut(nil)
        }

        workspace.openNote(planURL)
        #expect(workspace.noteURL == planURL)
        #expect(!workspace.editor.isOutlineVisible)

        // 1. Toggle Document Outline and verify fenced code comments are excluded from headings
        workspace.toggleOutline()
        #expect(workspace.editor.isOutlineVisible)
        let items = workspace.editor.outlineItems
        #expect(items.map(\.title) == ["Architecture Plan", "Storage Layer", "Atomic Writes"])
        #expect(items.map(\.level) == [1, 2, 3])

        // Incremental typing inside an existing ``` code fence must not add a heading to the outline
        let fenceRange = (workspace.editor.text as NSString).range(of: "echo \"hello\"")
        #expect(fenceRange.location != NSNotFound)
        workspace.editor.textView.setSelectedRange(NSRange(location: fenceRange.location, length: 0))
        workspace.editor.textView.insertText("# Incremental comment inside fence\n", replacementRange: NSRange(location: fenceRange.location, length: 0))
        #expect(workspace.editor.outlineItems.map(\.title) == ["Architecture Plan", "Storage Layer", "Atomic Writes"])
        #expect(workspace.persistCurrent())
        let savedAfterFenceEdit = workspace.editor.text

        // 2. Fold "Storage Layer" from the outline, then click "Atomic Writes" to jump & auto-unfold
        workspace.editor.toggleFoldForOutlineItem(at: 1)
        #expect(workspace.editor.outlineItems[1].isFolded)
        workspace.editor.jumpToHeading(at: 2)
        #expect(!workspace.editor.outlineItems[1].isFolded, "Jumping to a child heading inside a folded section must unfold it")
        #expect(workspace.editor.activeOutlineIndex == 2)

        // 3. External agent modifies PLAN.md on disk while editor is clean -> Review Banner appears,
        //    and clean buffer does NOT block persistCurrent() / window close!
        let agentUpdatedPlan = savedAfterFenceEdit + "\n## Verification Suite\nAdded by coding agent.\n"
        try agentUpdatedPlan.write(to: planURL, atomically: true, encoding: .utf8)
        workspace.refreshNoteIfClean()

        #expect(workspace.hasExternalDiskChange)
        #expect(!workspace.noteDirty)
        #expect(!workspace.reviewBanner.isHidden)
        #expect(workspace.persistCurrent(), "Clean buffer with external change banner must not block window close or quit")
        #expect(workspace.editor.text == savedAfterFenceEdit, "Editor text must not be silently replaced before user clicks Reload Disk")

        // Click Reload Disk -> loads agent version and highlights changed lines
        workspace.reloadFromDisk()
        #expect(!workspace.hasExternalDiskChange)
        #expect(workspace.reviewBanner.isHidden)
        #expect(workspace.editor.text == agentUpdatedPlan)
        #expect(!workspace.editor.textView.externalChangeRanges.isEmpty)
        #expect(workspace.editor.outlineItems.map(\.title).contains("Verification Suite"))

        // 4. Local edit + concurrent external edit -> CAS-guarded Overwrite Disk rejects unseen v3, then succeeds once reviewed
        let endLoc = workspace.editor.nsText.length
        workspace.editor.textView.setSelectedRange(NSRange(location: endLoc, length: 0))
        workspace.editor.textView.insertText("\n### Local User Decision\nKeep this.\n", replacementRange: NSRange(location: endLoc, length: 0))
        let concurrentAgentV2 = agentUpdatedPlan + "\n### Concurrent Agent Draft v2\n"
        try concurrentAgentV2.write(to: planURL, atomically: true, encoding: .utf8)
        workspace.refreshNoteIfClean()

        #expect(workspace.hasExternalDiskChange)
        #expect(workspace.noteConflicted)
        #expect(!workspace.reviewBanner.isHidden)

        // Agent writes an unseen v3 after the banner appeared -> Overwrite Disk must NOT destroy v3 unseen
        let unseenAgentV3 = agentUpdatedPlan + "\n### Unseen Agent Draft v3\n"
        try unseenAgentV3.write(to: planURL, atomically: true, encoding: .utf8)
        workspace.overwriteDiskWithCurrent()
        #expect(workspace.hasExternalDiskChange, "Overwrite must catch unseen v3 conflict and refresh banner")
        #expect(try vault.read(planURL) == unseenAgentV3, "Unseen v3 on disk must be preserved")

        // Clicking Overwrite Disk now (against refreshed v3 baseline) succeeds
        workspace.overwriteDiskWithCurrent()
        #expect(!workspace.hasExternalDiskChange)
        #expect(!workspace.noteConflicted)
        #expect(workspace.reviewBanner.isHidden)
        let afterOverwriteText = try vault.read(planURL)
        #expect(afterOverwriteText.contains("### Local User Decision"))

        // 5. Keep Copy creates a new Inbox note with local edits while leaving PLAN.md with the agent's text
        let endLoc2 = workspace.editor.nsText.length
        workspace.editor.textView.setSelectedRange(NSRange(location: endLoc2, length: 0))
        workspace.editor.textView.insertText("\n### Forked Local Thought\nSave to Inbox.\n", replacementRange: NSRange(location: endLoc2, length: 0))
        let agentFinalPlan = afterOverwriteText + "\n## Agent Final Section\nPreserved on PLAN.md.\n"
        try agentFinalPlan.write(to: planURL, atomically: true, encoding: .utf8)
        workspace.refreshNoteIfClean()
        #expect(workspace.hasExternalDiskChange)

        workspace.resolveConflictAsNewNote()
        #expect(!workspace.hasExternalDiskChange)
        #expect(!workspace.noteConflicted)
        #expect(workspace.noteURL != planURL)
        #expect(workspace.noteURL?.path.contains("/Inbox/") == true)
        #expect(workspace.editor.text.contains("### Forked Local Thought"))
        #expect(try vault.read(planURL) == agentFinalPlan, "PLAN.md on disk must retain the agent's version")

        // 6. Secondary NoteWindowController external-change banner flow
        let noteWin = try #require(workspace.openNoteInNewWindow(planURL))
        #expect(noteWin.noteURL == planURL)
        #expect(!noteWin.hasExternalDiskChange)
        let agentCompanionUpdate = agentFinalPlan + "\n### Companion Window Agent Update\n"
        try agentCompanionUpdate.write(to: planURL, atomically: true, encoding: .utf8)
        noteWin.refreshNoteIfClean()
        #expect(noteWin.hasExternalDiskChange)
        #expect(!noteWin.reviewBanner.isHidden)
        #expect(noteWin.persistCurrent(), "Clean secondary window with external change banner must allow closing")
        noteWin.reloadFromDisk()
        #expect(!noteWin.hasExternalDiskChange)
        #expect(noteWin.reviewBanner.isHidden)
        #expect(noteWin.editor.text == agentCompanionUpdate)
        #expect(!noteWin.editor.textView.externalChangeRanges.isEmpty)
    }

    @Test("Opening a project folder in a new workspace window keeps both the notes vault and project workspace open, deduplicates folders, and routes menu actions to the active workspace")
    @MainActor
    func multipleWorkspaceWindowsForVaultAndProject() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.buildMenus()
        let mainMenu = try #require(app.mainMenu)
        let fileMenu = try #require(mainMenu.item(withTitle: "File")?.submenu)
        #expect(fileMenu.item(withTitle: "Open Folder in New Window…") != nil)

        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CozyMultiWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempRoot.appendingPathComponent("PersonalVault", isDirectory: true)
        let projectRoot = tempRoot.appendingPathComponent("CodingProject", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let vaultNoteURL = vaultRoot.appendingPathComponent("journal.md")
        let projectPlanURL = projectRoot.appendingPathComponent("PLAN.md")
        try "# Daily Journal\nPersonal thoughts.".write(to: vaultNoteURL, atomically: true, encoding: .utf8)
        try "# Project Plan\nAgent milestones.".write(to: projectPlanURL, atomically: true, encoding: .utf8)

        let primaryWS = try delegate.openVault(vaultRoot, persistPreference: false)
        primaryWS.showWindow(nil)
        primaryWS.openNote(vaultNoteURL)
        defer {
            for ws in delegate.workspaces {
                ws.shutdown()
                ws.window?.orderOut(nil)
            }
        }

        #expect(delegate.workspaces.count == 1)
        #expect(primaryWS.editor.text.contains("Daily Journal"))

        // Open project folder in a second WorkspaceController window
        let projectWS = try delegate.openWorkspaceInNewWindow(projectRoot)
        projectWS.openNote(projectPlanURL)
        #expect(delegate.workspaces.count == 2)
        #expect(primaryWS !== projectWS)
        #expect(primaryWS.editor.text.contains("Daily Journal"))
        #expect(projectWS.editor.text.contains("Project Plan"))
        #expect(delegate.workspace === projectWS)

        // Requesting openWorkspaceInNewWindow for an already-open folder reuses that window
        let duplicateProjectWS = try delegate.openWorkspaceInNewWindow(projectRoot)
        #expect(duplicateProjectWS === projectWS)
        #expect(delegate.workspaces.count == 2)

        // Closing the secondary project workspace window removes it while keeping the primary vault open
        if let projWin = projectWS.window {
            #expect(projectWS.windowShouldClose(projWin))
        }
        #expect(delegate.workspaces.count == 1)
        #expect(delegate.workspace === primaryWS)
    }

    @Test("Markdown pipe tables align columns horizontally, indent wrapped multi-line cells under their column, collapse delimiter rows, and draw per-fragment inline code pills")
    @MainActor
    func markdownTableRenderingAndAlignment() throws {
        _ = NSApplication.shared
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 760, height: 540))
        editor.layoutSubtreeIfNeeded()
        let markdown = """
        ## Diagnosa skrip DB (sebelum)

        | Script | Masalah |
        |--------|---------|
        | `db:migrate` (`migration up`) | Hanya DB **local** Docker; sering dikira apply ke production |
        | `db:migrate:remote` / `--linked` | **Tidak didukung** CLI stabil untuk `migration up` |
        | `db:push` vs `db:push:remote` | Duplikatif / membingungkan; cukup `db:push` setelah link |
        | `db:types` | Gagal diam-diam tanpa project id / token; tidak ada jalur `--local` |
        | Tidak ada preflight | User tidak tahu Docker / link / env kurang |
        """
        editor.text = markdown
        let textView = editor.textView
        #expect(textView.tableBlocks.count == 1)
        let table = try #require(textView.tableBlocks.first)
        #expect(table.rows.count == 7)
        #expect(table.columnDividerOffsets.count == 1)

        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        lm.ensureLayout(for: tc)
        let ns = editor.nsText

        func glyphMinX(for substring: String) throws -> CGFloat {
            let r = ns.range(of: substring)
            #expect(r.location != NSNotFound)
            let g = lm.glyphIndexForCharacter(at: r.location)
            return lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).minX
        }

        // Column 1 ("Masalah") cells across header and all 5 data rows must start at the same X coordinate
        let headerCol1X = try glyphMinX(for: "Masalah")
        let row1Col1X = try glyphMinX(for: "Hanya DB")
        let row2Col1X = try glyphMinX(for: "Tidak didukung")
        let row3Col1X = try glyphMinX(for: "Duplikatif")
        let row4Col1X = try glyphMinX(for: "Gagal diam-diam")
        let row5Col1X = try glyphMinX(for: "User tidak tahu")

        #expect(abs(row1Col1X - headerCol1X) <= 1.5)
        #expect(abs(row2Col1X - headerCol1X) <= 1.5)
        #expect(abs(row3Col1X - headerCol1X) <= 1.5)
        #expect(abs(row4Col1X - headerCol1X) <= 1.5)
        #expect(abs(row5Col1X - headerCol1X) <= 1.5)

        // Wrapped continuation line in Column 1 must indent under Column 1 rather than wrapping to x = 0
        let prodRange = ns.range(of: "production")
        let prodGlyph = lm.glyphIndexForCharacter(at: prodRange.location)
        var wrappedLineGlyphRange = NSRange(location: 0, length: 0)
        _ = lm.lineFragmentUsedRect(forGlyphAt: prodGlyph, effectiveRange: &wrappedLineGlyphRange)
        let wrappedFirstGlyphX = lm.boundingRect(forGlyphRange: NSRange(location: wrappedLineGlyphRange.location, length: 1), in: tc).minX
        #expect(abs(wrappedFirstGlyphX - headerCol1X) <= 1.5)

        let hostWin = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let bgView = PaperSurface(cornerRadius: 0, color: Theme.paper, bordered: false)
        Theme.fill(editor, in: bgView)
        hostWin.contentView = bgView
        for appName in [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua] {
            hostWin.appearance = NSAppearance(named: appName)
            editor.refreshTypography()
            bgView.layoutSubtreeIfNeeded()
            let rep = try #require(bgView.bitmapImageRepForCachingDisplay(in: bgView.bounds))
            bgView.cacheDisplay(in: bgView.bounds, to: rep)
            #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        }

        // Delimiter row (|--------|---------|) must be collapsed when unfocused
        let delimGlyphs = lm.glyphRange(forCharacterRange: table.delimiterRange, actualCharacterRange: nil)
        let delimRect = lm.boundingRect(forGlyphRange: delimGlyphs, in: tc)
        #expect(delimRect.height <= 3.0)

        // Per-fragment inline code pill rects must stay tight around each code token rather than spanning full column width
        for inner in textView.inlineCodeRanges {
            let gr = lm.glyphRange(forCharacterRange: inner, actualCharacterRange: nil)
            var gIdx = gr.location
            while gIdx < NSMaxRange(gr) {
                var lineGR = NSRange(location: 0, length: 0)
                _ = lm.lineFragmentRect(forGlyphAt: gIdx, effectiveRange: &lineGR)
                let sub = NSIntersectionRange(gr, lineGR)
                let rect = lm.boundingRect(forGlyphRange: sub, in: tc)
                #expect(rect.width < 180.0)
                gIdx = max(gIdx + 1, NSMaxRange(lineGR))
            }
        }

        // Wide 4-column table in a narrow editor falls back cleanly without overflowing vertical column dividers
        let narrowEditor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 380, height: 420))
        narrowEditor.compactLayout = true
        narrowEditor.layoutSubtreeIfNeeded()
        narrowEditor.text = """
        | Component | Responsibility | Failure Mode | Mitigation Strategy |
        |-----------|----------------|--------------|---------------------|
        | Migration Runner | Applies SQL schema migrations | Silent failure without token | Add preflight verification |
        """
        let narrowTable = try #require(narrowEditor.textView.tableBlocks.first)
        #expect(narrowTable.columnDividerOffsets.isEmpty, "Wide multi-column table exceeding narrow width must omit vertical dividers rather than overflowing across them")
    }

    @Test("Scrolling down and up after heading cursor transitions and newline edits above blockquotes invalidates full visible viewport without stale tile artifacts")
    @MainActor
    func scrollAfterHeadingAndBlockquoteEditsInvalidatesFullViewport() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 780, height: 420))
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor.textView))
        defer { window.orderOut(nil) }

        var paragraphs: [String] = [
            "**Create a staging environment with fictional agencies and travelers**. You will need at least **two agencies to test data separation**.",
            "Your first deliverable should be a **reproducible setup** and an explicit list of unknowns.",
            "## 3. Learn the system one complete business workflow at a time.",
            "Reading every file sequentially would be slow and would obscure how the pieces interact. Start with this UConnect workflow.",
            "> Agency receives a lead → creates a booking group → assigns a departure → issues an invoice → receives payment → updates commission eligibility → gives the jamaah portal access."
        ]
        for i in 1...18 {
            paragraphs.append("Paragraph \(i): demonstrate how the app handles a new inquiry, a family booking, an installment payment, a cancellation, and missing travel documents.")
        }
        editor.text = paragraphs.joined(separator: "\n\n")
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let textView = editor.textView
        let scrollView = try #require(textView.enclosingScrollView)
        let clipView = scrollView.contentView
        #expect(textView.preparedContentRect == textView.visibleRect)

        // Requesting display of a narrow left-tile rect (x < 512) must expand to the full visibleRect (crossing x = 512)
        textView.setNeedsDisplay(NSRect(x: 180, y: 240, width: 10, height: 24), avoidAdditionalLayout: false)
        #expect(textView.lastInvalidatedRect == textView.visibleRect)
        #expect(textView.lastInvalidatedRect.maxX > 512, "Full-viewport invalidation must span across the 512pt tile boundary")

        // Move cursor onto the H2 heading, then onto the blank line before the blockquote and insert a newline
        let ns = editor.nsText
        let headingRange = ns.range(of: "## 3. Learn")
        #expect(headingRange.location != NSNotFound)
        textView.setSelectedRange(NSRange(location: headingRange.location + 3, length: 0))
        #expect(textView.lastInvalidatedRect == textView.visibleRect)
        window.displayIfNeeded()

        let quoteRange = ns.range(of: "> Agency receives")
        #expect(quoteRange.location != NSNotFound)
        textView.setSelectedRange(NSRange(location: quoteRange.location - 1, length: 0))
        textView.insertText("\n", replacementRange: textView.selectedRange())
        #expect(textView.lastInvalidatedRect == textView.visibleRect)
        window.displayIfNeeded()

        // Scrolling down and back up must immediately invalidate the new visibleRect via clipView bounds observer
        for targetY in [CGFloat(140), CGFloat(280), CGFloat(90), CGFloat(0)] {
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
            #expect(textView.lastInvalidatedRect == textView.visibleRect)
            #expect(abs(textView.lastInvalidatedRect.minY - targetY) <= 1.0)
            window.displayIfNeeded()
            #expect(textView.preparedContentRect == textView.visibleRect)
        }
        #expect(textView.blockquoteRanges.count == 1)
    }

    @Test("Neo-Acid atmosphere and voice resolve H1-H3 Unbounded/Avenir typography, satisfy WCAG contrast in light and dark appearances, and cycle across workspace controls")
    @MainActor
    func neoAcidAtmosphereAndVoiceTypographyContrastAndCycling() throws {
        _ = NSApplication.shared
        let savedAtmosphere = Theme.atmosphere
        let savedVoice = Theme.voice
        let savedScale = Theme.fontScale
        defer {
            Theme.atmosphere = savedAtmosphere
            Theme.voice = savedVoice
            Theme.fontScale = savedScale
        }

        Theme.fontScale = 0
        Theme.atmosphere = .study
        Theme.voice = .humanist
        let baselineH1 = Theme.headingFont(level: 1)
        let baselineH2 = Theme.headingFont(level: 2)
        let baselineH3 = Theme.headingFont(level: 3)
        let baselineBody = Theme.bodyFont()
        let baselineItalic = Theme.italicBodyFont()

        // Switching atmosphere to .neoAcid with default .humanist voice activates scaled H1-H3 display headings while keeping Midnight/Avenir body
        Theme.atmosphere = .neoAcid
        let neoH1 = Theme.headingFont(level: 1)
        let neoH2 = Theme.headingFont(level: 2)
        let neoH3 = Theme.headingFont(level: 3)
        #expect(abs(neoH1.pointSize - (baselineH1.pointSize - 1.5)) < 0.01)
        #expect(abs(neoH2.pointSize - (baselineH2.pointSize - 1.5)) < 0.01)
        #expect(abs(neoH3.pointSize - (baselineH3.pointSize - 1.5)) < 0.01)
        #expect( neoH1.pointSize > neoH2.pointSize && neoH2.pointSize > neoH3.pointSize )
        if NSFont(name: "Unbounded-ExtraBold", size: 20) != nil {
            #expect(neoH1.fontName.contains("Unbounded"))
            #expect(neoH2.fontName.contains("Unbounded"))
            #expect(neoH3.fontName.contains("Unbounded"))
        }

        // Explicit .neoAcid voice preserves Midnight/humanist body & italic typography and H1-H3 display headings even in other atmospheres
        Theme.atmosphere = .botanical
        Theme.voice = .neoAcid
        #expect(Theme.bodyFont().fontName == baselineBody.fontName)
        #expect(Theme.bodyFont(weight: .bold).fontName == Theme.bodyFont(weight: .semibold).fontName)
        #expect(Theme.italicBodyFont().fontName == baselineItalic.fontName)
        #expect(Theme.headingFont(level: 1).fontName == neoH1.fontName)
        #expect(Theme.headingFont(level: 2).fontName == neoH2.fontName)
        #expect(Theme.headingFont(level: 3).fontName == neoH3.fontName)

        // Verify WCAG 2.1 contrast ratios for Neo-Acid tokens across Dark (.darkAqua) and Light (.aqua) appearances
        func relativeLuminance(_ color: NSColor, in appearance: NSAppearance) -> Double {
            var resolved: NSColor = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            func linear(_ c: CGFloat) -> Double {
                let v = Double(max(0, min(1, c)))
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(resolved.redComponent)
                + 0.7152 * linear(resolved.greenComponent)
                + 0.0722 * linear(resolved.blueComponent)
        }
        func contrastRatio(_ a: NSColor, _ b: NSColor, in appearance: NSAppearance) -> Double {
            let l1 = relativeLuminance(a, in: appearance)
            let l2 = relativeLuminance(b, in: appearance)
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }

        Theme.atmosphere = .neoAcid
        let darkApp = try #require(NSAppearance(named: .darkAqua))
        let lightApp = try #require(NSAppearance(named: .aqua))

        #expect(contrastRatio(Theme.headingInk, Theme.paper, in: darkApp) >= 12.0)
        #expect(contrastRatio(Theme.ink, Theme.paper, in: darkApp) >= 9.0)
        #expect(contrastRatio(Theme.muted, Theme.paper, in: darkApp) >= 4.5)
        #expect(contrastRatio(Theme.muted, Theme.canvas, in: darkApp) >= 4.5)
        #expect(contrastRatio(Theme.accent, Theme.paper, in: darkApp) >= 10.0)

        #expect(contrastRatio(Theme.headingInk, Theme.paper, in: lightApp) >= 15.0)
        #expect(contrastRatio(Theme.ink, Theme.paper, in: lightApp) >= 8.0)
        #expect(contrastRatio(Theme.muted, Theme.paper, in: lightApp) >= 5.0)
        #expect(contrastRatio(Theme.muted, Theme.canvas, in: lightApp) >= 5.0)
        #expect(contrastRatio(Theme.subtle, Theme.canvas, in: lightApp) >= 4.5)
        #expect(contrastRatio(Theme.accent, Theme.paper, in: lightApp) >= 5.5)

        // Verify CaptureEditor applies H1, H2, H3, inline code, and WikiLink attributes under Neo-Acid and cycles cleanly in WorkspaceController
        let tempBase = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("cozy-neo-acid-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempBase.appendingPathComponent("Vault", isDirectory: true)
        let historyRoot = tempBase.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        Theme.atmosphere = .study
        Theme.voice = .humanist
        let workspace = WorkspaceController(vault: vault)
        defer {
            workspace.shutdown()
            workspace.window?.orderOut(nil)
        }

        workspace.cycleAtmosphere()
        #expect(Theme.atmosphere == .botanical)
        workspace.cycleAtmosphere()
        #expect(Theme.atmosphere == .neoAcid)
        workspace.cycleAtmosphere()
        #expect(Theme.atmosphere == .study)

        for expected in [Theme.Voice.bookSerif, .editorial, .typewriter, .neoAcid, .humanist] {
            workspace.cycleVoice()
            #expect(Theme.voice == expected)
        }

        workspace.switchAtmosphere(.neoAcid)
        workspace.switchVoice(.neoAcid)
        workspace.editor.text = "# Heading One\n\n## Heading Two\n\n### Heading Three\n\nBody prose with `inlineCode` and [[TargetNote]]."
        let storage = try #require(workspace.editor.textView.textStorage)
        let ns = storage.string as NSString
        let h1Font = try #require(storage.attribute(.font, at: ns.range(of: "Heading One").location, effectiveRange: nil) as? NSFont)
        let h2Font = try #require(storage.attribute(.font, at: ns.range(of: "Heading Two").location, effectiveRange: nil) as? NSFont)
        let h3Font = try #require(storage.attribute(.font, at: ns.range(of: "Heading Three").location, effectiveRange: nil) as? NSFont)
        let proseFont = try #require(storage.attribute(.font, at: ns.range(of: "Body prose").location, effectiveRange: nil) as? NSFont)
        #expect(h1Font.fontName == neoH1.fontName && abs(h1Font.pointSize - neoH1.pointSize) < 0.01)
        #expect(h2Font.fontName == neoH2.fontName && abs(h2Font.pointSize - neoH2.pointSize) < 0.01)
        #expect(h3Font.fontName == neoH3.fontName && abs(h3Font.pointSize - neoH3.pointSize) < 0.01)
        #expect(proseFont.fontName == baselineBody.fontName)

        workspace.shutdown()
        workspace.window?.orderOut(nil)

        // Verify Neo-Acid atmosphere + Unbounded H1-H3 headings meet Moby-Dick layout, resize, typing, and memory budgets
        let report = try MobyDickWorkout.run(repeatCycles: 1, typingSample: "Whale")
        #expect(report.step1.cpu.cpuTimeMs < 150.0)
        #expect(report.step2.resizeAvgMs < 16.0)
        #expect(report.step3.resizeAvgMs < 16.0)
        #expect(report.step5.p95KeystrokeMs < 8.0)
        if !report.repeats.isEmpty {
            let growthPerCycle = (report.memoryFinal.physFootprintMB - report.memoryAfterFirstPass.physFootprintMB) / Double(report.repeats.count)
            #expect(growthPerCycle < 5.0)
        }
    }
}
#endif
