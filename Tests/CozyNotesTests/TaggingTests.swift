#if canImport(Testing)
import Testing
#endif
#if canImport(XCTest)
import XCTest
#else
private func XCTAssertNil<T>(_ value: T?, _ message: String = "") { #expect(value == nil) }
#endif
import AppKit
import CozyCore
import CozySearch
@testable import CozyNotes

@MainActor
private struct TagWorkspaceFixture {
    let directory: URL
    let root: URL
    let history: URL
    let vault: Vault
    let workspace: WorkspaceController

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyTaggingTests-\(UUID().uuidString)", isDirectory: true)
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
private func runTaggingWorkflowAssertion() async throws {
    let fixture = try TagWorkspaceFixture()
    defer { fixture.cleanup() }

    let roadmap = try fixture.vault.capture(text: "# Product Roadmap\nMilestones for #work and #work/q2 release.")
    _ = try fixture.vault.capture(text: "# Design Tokens\nWarm paper palette #work #design.")
    let reading = try fixture.vault.capture(text: "# Book Club\nNotes on #reading.")

    fixture.workspace.window?.makeKeyAndOrderFront(nil)
    fixture.workspace.searchPanel.refresh()
    let loaded = await waitUntil {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count == 3
    }
    XCTAssertTrue(loaded)

    // Sidebar aggregates tag counts sorted by frequency then name
    XCTAssertEqual(
        fixture.workspace.searchPanel.availableTags,
        [
            TagCount(name: "work", count: 2),
            TagCount(name: "design", count: 1),
            TagCount(name: "reading", count: 1),
            TagCount(name: "work/q2", count: 1),
        ]
    )
    XCTAssertNil(fixture.workspace.searchPanel.activeTagFilter)

    // Filtering by #work in sidebar shows both #work notes (including #work/q2)
    fixture.workspace.searchPanel.setTagFilter("work")
    XCTAssertEqual(fixture.workspace.searchPanel.activeTagFilter, "work")
    XCTAssertEqual(
        Set(fixture.workspace.searchPanel.visibleHits.map(\.source.title)),
        Set(["Product Roadmap", "Design Tokens"])
    )

    // Filtering by hierarchical child #work/q2 narrows to Product Roadmap
    fixture.workspace.searchPanel.setTagFilter("work/q2")
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.title),
        ["Product Roadmap"]
    )

    // Clearing tag filter restores all 3 notes
    fixture.workspace.searchPanel.setTagFilter(nil)
    XCTAssertEqual(fixture.workspace.searchPanel.visibleHits.count, 3)

    // Open Product Roadmap in editor and verify live #tag pill ranges are tracked
    fixture.workspace.openNote(roadmap.url)
    XCTAssertEqual(
        fixture.workspace.editor.textView.tagItems.map(\.name),
        ["work", "work/q2"]
    )

    // Triggering ⌘Return on a #tag inside the editor filters the sidebar to that tag
    let firstTagRange = try XCTUnwrap(fixture.workspace.editor.textView.tagItems.first?.fullRange)
    fixture.workspace.editor.textView.setSelectedRange(NSRange(location: firstTagRange.location + 2, length: 0))
    if let win = fixture.workspace.window,
       let cmdReturn = NSEvent.keyEvent(
           with: .keyDown,
           location: .zero,
           modifierFlags: [.command],
           timestamp: 0,
           windowNumber: win.windowNumber,
           context: nil,
           characters: "\r",
           charactersIgnoringModifiers: "\r",
           isARepeat: false,
           keyCode: 36
       ) {
        XCTAssertTrue(fixture.workspace.editor.textView.performKeyEquivalent(with: cmdReturn))
    }
    XCTAssertEqual(fixture.workspace.searchPanel.activeTagFilter, "work")
    XCTAssertEqual(
        Set(fixture.workspace.searchPanel.visibleHits.map(\.source.title)),
        Set(["Product Roadmap", "Design Tokens"])
    )

    // Triggering onClickTag on the already-active tag toggles the filter off
    fixture.workspace.editor.onClickTag?("work")
    XCTAssertNil(fixture.workspace.searchPanel.activeTagFilter)
    XCTAssertEqual(fixture.workspace.searchPanel.visibleHits.count, 3)

    // Verify #tag autocomplete item builder ranks existing tags and offers new tag creation
    let notes = try fixture.vault.notes()
    let emptyQueryItems = CaptureEditor.buildTagCompletionItems(for: "", notes: notes)
    XCTAssertEqual(emptyQueryItems.map(\.tagName), ["work", "design", "reading", "work/q2"])
    XCTAssertFalse(emptyQueryItems.contains(where: \.isCreateNew))

    let partialItems = CaptureEditor.buildTagCompletionItems(for: "wo", notes: notes)
    XCTAssertEqual(partialItems.map(\.tagName), ["work", "work/q2", "wo"])
    XCTAssertEqual(partialItems.last?.isCreateNew, true)

    // Open reading note and verify typing #des + Return autocompletes #design
    fixture.workspace.openNote(reading.url)
    let endLoc = (fixture.workspace.editor.text as NSString).length
    fixture.workspace.editor.textView.setSelectedRange(NSRange(location: endLoc, length: 0))
    fixture.workspace.editor.textView.insertText(" #des", replacementRange: NSRange(location: endLoc, length: 0))
    XCTAssertTrue(fixture.workspace.editor.isWikiAutocompleteVisible)
    XCTAssertTrue(fixture.workspace.editor.text.hasSuffix(" #des"))
    fixture.workspace.editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    XCTAssertFalse(fixture.workspace.editor.isWikiAutocompleteVisible)
    XCTAssertTrue(fixture.workspace.editor.text.hasSuffix(" #design"))
}

#if canImport(XCTest)
@MainActor
final class TaggingTests: XCTestCase {
    func testSidebarTagFilterEditorTagPillsAndTagAutocomplete() async throws {
        try await runTaggingWorkflowAssertion()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Tagging UI", .serialized)
    struct TaggingSuite {
        @Test("Sidebar tag filter bar, editor #tag pills, ⌘-Click filtering, and #tag autocomplete")
        @MainActor
        func taggingWorkflow() async throws {
            try await runTaggingWorkflowAssertion()
        }
    }
}
#endif
