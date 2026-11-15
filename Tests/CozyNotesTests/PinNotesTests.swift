#if canImport(Testing)
import Testing
#endif
#if canImport(XCTest)
import XCTest
#else
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") { #expect(a == b) }
func XCTAssertTrue(_ expr: Bool, _ message: String = "") { #expect(expr) }
func XCTAssertFalse(_ expr: Bool, _ message: String = "") { #expect(!expr) }
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "XCTUnwrap", code: 1) }
    return value
}
#endif
import AppKit
import CozyCore
@testable import CozyNotes

@MainActor
private struct PinWorkspaceFixture {
    let directory: URL
    let root: URL
    let history: URL
    let vault: Vault
    let workspace: WorkspaceController

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyPinNotesTests-\(UUID().uuidString)", isDirectory: true)
        root = directory.appendingPathComponent("Vault", isDirectory: true)
        history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
        vault = try Vault(root: root, historyRoot: history)
        workspace = WorkspaceController(vault: vault)
    }

    func cleanup() {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 15.0, condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return condition()
}

@MainActor
private func runPinningWorkflowAssertion() async throws {
    let fixture = try PinWorkspaceFixture()
    defer { fixture.cleanup() }

    let fm = FileManager.default
    let oldest = try fixture.vault.capture(text: "# Oldest Note\nBody A")
    let middle = try fixture.vault.capture(text: "# Middle Note\nBody B")
    let newest = try fixture.vault.capture(text: "# Newest Note\nBody C")

    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: oldest.url.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: middle.url.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)], ofItemAtPath: newest.url.path)

    fixture.workspace.window?.makeKeyAndOrderFront(nil)
    fixture.workspace.searchPanel.refresh()
    let loaded = await waitUntil {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count == 3
    }
    XCTAssertTrue(loaded)

    // Initial unpinned sidebar order: most recently modified first
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.title),
        ["Newest Note", "Middle Note", "Oldest Note"]
    )
    XCTAssertTrue(fixture.workspace.pinButton.isHidden)

    // Open oldest note and pin it via WorkspaceController
    fixture.workspace.openNote(oldest.url)
    XCTAssertFalse(fixture.workspace.pinButton.isHidden)
    XCTAssertEqual(fixture.workspace.pinButton.symbolName, "pin")
    XCTAssertFalse(fixture.workspace.targetNoteIsPinned)

    fixture.workspace.togglePinCurrentNote()
    XCTAssertTrue(fixture.vault.isPinned(oldest.url))
    XCTAssertTrue(fixture.workspace.targetNoteIsPinned)
    XCTAssertEqual(fixture.workspace.pinButton.symbolName, "pin.fill")
    // Immediate synchronous sidebar reorder (no async scan wait required)
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.title),
        ["Oldest Note", "Newest Note", "Middle Note"]
    )

    // Pinning a second note orders multiple pinned notes by most recently modified first
    fixture.workspace.togglePinNote(middle.url)
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.title),
        ["Middle Note", "Oldest Note", "Newest Note"]
    )

    // Quick Switcher lists pinned notes first when browsing and supports ⇧⌘P inline unpinning
    fixture.workspace.showQuickSwitcher()
    XCTAssertTrue(fixture.workspace.isQuickSwitcherVisible)
    XCTAssertEqual(
        fixture.workspace.quickSwitcher.hits.map(\.source.title),
        ["Middle Note", "Oldest Note", "Newest Note"]
    )
    if let win = fixture.workspace.window,
       let keyEvent = NSEvent.keyEvent(
           with: .keyDown,
           location: .zero,
           modifierFlags: [.command, .shift],
           timestamp: 0,
           windowNumber: win.windowNumber,
           context: nil,
           characters: "P",
           charactersIgnoringModifiers: "p",
           isARepeat: false,
           keyCode: 35
       ) {
        XCTAssertTrue(fixture.workspace.quickSwitcher.performKeyEquivalent(with: keyEvent))
    }
    XCTAssertFalse(fixture.vault.isPinned(middle.url))
    XCTAssertEqual(
        fixture.workspace.quickSwitcher.hits.map(\.source.title),
        ["Oldest Note", "Newest Note", "Middle Note"]
    )
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.title),
        ["Oldest Note", "Newest Note", "Middle Note"]
    )
    fixture.workspace.dismissQuickSwitcher()

    // Companion NoteWindowController stays synchronized when toggling pins
    let companion = try XCTUnwrap(fixture.workspace.openNoteInNewWindow(oldest.url))
    XCTAssertEqual(companion.pinButton.symbolName, "pin.fill")
    XCTAssertTrue(companion.isCurrentNotePinned)
    companion.togglePinCurrentNote()
    XCTAssertFalse(fixture.vault.isPinned(oldest.url))
    XCTAssertEqual(companion.pinButton.symbolName, "pin")
    XCTAssertEqual(fixture.workspace.pinButton.symbolName, "pin")
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.title),
        ["Newest Note", "Middle Note", "Oldest Note"]
    )
}

@MainActor
private func runQuickSwitcherSearchMatchHandoffAssertion() async throws {
    let fixture = try PinWorkspaceFixture()
    defer { fixture.cleanup() }

    let firstNote = try fixture.vault.capture(text: "# First Note\nNothing special here.")
    let deepBody = (1...30).map { "Paragraph \($0) filler prose." }.joined(separator: "\n\n")
    let targetNote = try fixture.vault.capture(
        text: "# Research Log\n\n\(deepBody)\n\n## Hidden Section\n\nThe ambergris specimen was catalogued at dawn.\n\nAnother ambergris reference appears below."
    )

    let attachmentSource = fixture.directory.appendingPathComponent("field-sketch.txt")
    try "sketch contents".write(to: attachmentSource, atomically: true, encoding: .utf8)
    let firstNoteText = try fixture.vault.read(firstNote.url)
    let updatedWithAttachment = try fixture.vault.attach(
        [attachmentSource],
        to: firstNote.url,
        text: firstNoteText,
        expectedContent: firstNoteText
    )
    XCTAssertTrue(updatedWithAttachment.contains("field-sketch.txt"))

    fixture.workspace.window?.makeKeyAndOrderFront(nil)
    fixture.workspace.openNote(firstNote.url)
    fixture.workspace.searchPanel.refresh()
    let indexed = await waitUntil {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count >= 2
    }
    XCTAssertTrue(indexed)

    // Fold the "## Hidden Section" in targetNote first, then verify Quick Switcher unfolds, selects, and highlights matches
    fixture.workspace.openNote(targetNote.url)
    fixture.workspace.editor.textView.foldAllHeadings(nil)
    fixture.workspace.openNote(firstNote.url)

    fixture.workspace.showQuickSwitcher()
    XCTAssertTrue(fixture.workspace.isQuickSwitcherVisible)
    fixture.workspace.quickSwitcher.query = "ambergris"
    XCTAssertEqual(fixture.workspace.quickSwitcher.hits.first?.source.url, targetNote.url)

    XCTAssertTrue(fixture.workspace.quickSwitcher.confirmSelection())
    XCTAssertFalse(fixture.workspace.isQuickSwitcherVisible)
    XCTAssertEqual(fixture.workspace.noteURL, targetNote.url)
    XCTAssertFalse(fixture.workspace.editor.inNoteFindBar.isHidden)
    XCTAssertEqual(fixture.workspace.editor.inNoteFindBar.query, "ambergris")
    XCTAssertEqual(fixture.workspace.editor.textView.inNoteFindRanges.count, 2)
    XCTAssertEqual(fixture.workspace.editor.textView.activeInNoteFindIndex, 0)
    let firstMatchRange = fixture.workspace.editor.textView.inNoteFindRanges[0]
    XCTAssertEqual(fixture.workspace.editor.textView.selectedRange(), firstMatchRange)
    XCTAssertTrue(fixture.workspace.window?.firstResponder === fixture.workspace.editor.textView)

    // ⌘G advances directly to the second match without re-typing the query
    fixture.workspace.findNextInNote()
    XCTAssertEqual(fixture.workspace.editor.textView.activeInNoteFindIndex, 1)
    XCTAssertEqual(fixture.workspace.editor.textView.selectedRange(), fixture.workspace.editor.textView.inNoteFindRanges[1])

    // Confirming an attachment hit in Quick Switcher navigates to the referencing parent note and selects its markdown link
    fixture.workspace.showQuickSwitcher()
    fixture.workspace.quickSwitcher.query = "field-sketch"
    let attachmentHitIndex = try XCTUnwrap(
        fixture.workspace.quickSwitcher.hits.firstIndex(where: { $0.source.kind != .note })
    )
    XCTAssertTrue(fixture.workspace.quickSwitcher.confirmSelection(at: attachmentHitIndex))
    XCTAssertEqual(fixture.workspace.noteURL, firstNote.url)
    let selectedInFirst = (fixture.workspace.editor.nsText).substring(with: fixture.workspace.editor.textView.selectedRange())
    XCTAssertTrue(selectedInFirst.contains("field-sketch.txt"))
}

#if canImport(XCTest)
@MainActor
final class PinNotesTests: XCTestCase {
    func testWorkspaceSidebarQuickSwitcherAndCompanionPinning() async throws {
        try await runPinningWorkflowAssertion()
    }

    func testQuickSwitcherSearchMatchHandoffAndAttachmentParentNavigation() async throws {
        try await runQuickSwitcherSearchMatchHandoffAssertion()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Pin Notes UI", .serialized)
    struct PinNotesSuite {
        @Test("Workspace header, sidebar, Quick Switcher, and companion window synchronize pinned notes")
        @MainActor
        func workspacePinningWorkflow() async throws {
            try await runPinningWorkflowAssertion()
        }

        @Test("Quick Switcher hands off search query to in-note find and resolves attachment hits to parent note")
        @MainActor
        func quickSwitcherSearchMatchHandoff() async throws {
            try await runQuickSwitcherSearchMatchHandoffAssertion()
        }
    }
}
#endif
