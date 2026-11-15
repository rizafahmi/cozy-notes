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
private struct MergeWorkspaceFixture {
    let directory: URL
    let root: URL
    let history: URL
    let vault: Vault
    let workspace: WorkspaceController

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyMergeNotesTests-\(UUID().uuidString)", isDirectory: true)
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
private func runMergeNotesWorkflowAssertion() async throws {
    let fixture = try MergeWorkspaceFixture()
    defer { fixture.cleanup() }

    let fm = FileManager.default
    let alpha = try fixture.vault.capture(text: "# Alpha Intro\nOpening context.")
    let beta = try fixture.vault.capture(text: "# Beta Details\nKey implementation notes.")
    let gamma = try fixture.vault.capture(text: "# Gamma Summary\nFinal checklist.")
    let observer = try fixture.vault.capture(text: "# Index\nSee [[Alpha Intro]] and [[Beta Details#Key]].")

    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_400)], ofItemAtPath: alpha.url.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_300)], ofItemAtPath: beta.url.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)], ofItemAtPath: gamma.url.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: observer.url.path)

    // Pin Beta so pin inheritance can be verified in the merge preview and final workspace state
    XCTAssertTrue(try fixture.vault.setPinned(true, for: beta.url))

    fixture.workspace.window?.makeKeyAndOrderFront(nil)
    fixture.workspace.searchPanel.refresh()
    let loaded = await waitUntil {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count == 4
    }
    XCTAssertTrue(loaded)

    // Single selection cannot merge
    fixture.workspace.searchPanel.selectNote(alpha.url)
    XCTAssertFalse(fixture.workspace.canMergeNotes)
    XCTAssertEqual(fixture.workspace.selectedNotesForMerge, [alpha.url])

    // Multi-select three notes in explicit order: Alpha, Beta, Gamma
    fixture.workspace.searchPanel.selectNotes([alpha.url, beta.url, gamma.url])
    XCTAssertTrue(fixture.workspace.canMergeNotes)
    XCTAssertEqual(fixture.workspace.selectedNotesForMerge, [alpha.url, beta.url, gamma.url])

    // Right-click context menu on any selected row offers "Merge 3 Notes…"
    if let alphaRow = fixture.workspace.searchPanel.visibleHits.firstIndex(where: { $0.source.url == alpha.url }),
       let menu = fixture.workspace.searchPanel.contextMenuForRow(alphaRow) {
        XCTAssertEqual(menu.items.first?.title, "Merge 3 Notes…")
    } else {
        XCTAssertTrue(false, "Expected multi-selection context menu on selected row")
    }

    // Open companion windows for Gamma (will become target), Alpha (will be absorbed), and Observer (will have WikiLinks rewritten)
    let gammaCompanion = try XCTUnwrap(fixture.workspace.openNoteInNewWindow(gamma.url))
    let alphaCompanion = try XCTUnwrap(fixture.workspace.openNoteInNewWindow(alpha.url))
    let observerCompanion = try XCTUnwrap(fixture.workspace.openNoteInNewWindow(observer.url))
    XCTAssertEqual(fixture.workspace.noteWindows.count, 3)

    // Present the merge confirmation/preview sheet
    fixture.workspace.window?.makeKeyAndOrderFront(nil)
    let sheet = try XCTUnwrap(
        fixture.workspace.presentMergeNotesSheet(
            for: [alpha.url, beta.url, gamma.url],
            in: nil,
            moveToTrash: false
        )
    )
    XCTAssertEqual(sheet.orderedURLs, [alpha.url, beta.url, gamma.url])
    XCTAssertEqual(sheet.currentPreview?.targetNote.url, alpha.url)
    XCTAssertTrue(sheet.previewText.hasPrefix("# Alpha Intro\nOpening context.\n\n---\n\n# Beta Details"))
    XCTAssertTrue(sheet.impactSummary.contains("2 notes move to Trash"))
    XCTAssertTrue(sheet.impactSummary.contains("keeps pinned"))
    XCTAssertFalse(sheet.moveUpButton.isEnabled)
    XCTAssertTrue(sheet.moveDownButton.isEnabled)
    XCTAssertFalse(sheet.makeTargetButton.isEnabled)

    // Reorder inside the sheet: select Gamma (index 2) and promote it to Target (index 0)
    sheet.selectRow(2)
    XCTAssertTrue(sheet.moveUpButton.isEnabled)
    XCTAssertFalse(sheet.moveDownButton.isEnabled)
    XCTAssertTrue(sheet.makeTargetButton.isEnabled)

    sheet.promoteSelectedToTarget()
    XCTAssertEqual(sheet.orderedURLs, [gamma.url, alpha.url, beta.url])
    XCTAssertEqual(sheet.currentPreview?.targetNote.url, gamma.url)
    XCTAssertEqual(sheet.currentPreview?.targetNote.title, "Gamma Summary")
    XCTAssertTrue(sheet.previewText.hasPrefix("# Gamma Summary\nFinal checklist.\n\n---\n\n# Alpha Intro"))

    // Test step-wise moveSelectedDown / moveSelectedUp on Alpha (row 1 <-> row 2)
    sheet.selectRow(1)
    sheet.moveSelectedDown()
    XCTAssertEqual(sheet.orderedURLs, [gamma.url, beta.url, alpha.url])
    sheet.moveSelectedUp()
    XCTAssertEqual(sheet.orderedURLs, [gamma.url, alpha.url, beta.url])

    // Confirm merge from the sheet
    sheet.confirmMerge()
    XCTAssertTrue(fixture.workspace.activeMergeSheet == nil)

    // Workspace active note is now Gamma with merged content and inherited pin status
    XCTAssertEqual(fixture.workspace.noteURL, gamma.url)
    XCTAssertTrue(fixture.vault.isPinned(gamma.url))
    XCTAssertTrue(fixture.workspace.targetNoteIsPinned)
    XCTAssertEqual(fixture.workspace.pinButton.symbolName, "pin.fill")
    let expectedMerged = """
    # Gamma Summary
    Final checklist.

    ---

    # Alpha Intro
    Opening context.

    ---

    # Beta Details
    Key implementation notes.
    """ + "\n"
    XCTAssertEqual(fixture.workspace.editor.text, expectedMerged)

    // Absorbed Alpha companion window was closed; Gamma and Observer companion windows stayed open and updated live
    XCTAssertEqual(fixture.workspace.noteWindows.count, 2)
    XCTAssertFalse(fixture.workspace.noteWindows.contains { $0 === alphaCompanion })
    XCTAssertEqual(gammaCompanion.editor.text, expectedMerged)
    XCTAssertEqual(
        observerCompanion.editor.text,
        "# Index\nSee [[Gamma Summary]] and [[Gamma Summary#Key]].\n"
    )

    // Sidebar refreshes down to the 2 remaining notes (Gamma pinned first, then Index)
    let refreshed = await waitUntil {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count == 2
    }
    XCTAssertTrue(refreshed)
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.title),
        ["Gamma Summary", "Index"]
    )
}

#if canImport(XCTest)
@MainActor
final class MergeNotesTests: XCTestCase {
    func testSidebarMultiSelectPreviewReorderAndWorkspaceMerge() async throws {
        try await runMergeNotesWorkflowAssertion()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Merge Notes UI", .serialized)
    struct MergeNotesSuite {
        @Test("Sidebar multi-selection, reorderable preview sheet, and companion window sync during note merge")
        @MainActor
        func workspaceMergeNotesWorkflow() async throws {
            try await runMergeNotesWorkflowAssertion()
        }
    }
}
#endif
