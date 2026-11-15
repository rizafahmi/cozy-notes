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
@testable import CozyNotes

@MainActor
private struct ProjectHierarchyWorkspaceFixture {
    let directory: URL
    let root: URL
    let history: URL
    let vault: Vault
    let workspace: WorkspaceController

    init(preseedGitMarker: Bool = false) throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyProjectHierarchyTests-\(UUID().uuidString)", isDirectory: true)
        root = directory.appendingPathComponent("ProjectRepo", isDirectory: true)
        history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if preseedGitMarker {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        vault = try Vault(root: root, historyRoot: history)
        workspace = WorkspaceController(vault: vault)
    }

    func file(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
    }

    func cleanup() {
        workspace.shutdown()
        for companion in workspace.noteWindows {
            companion.window?.orderOut(nil)
        }
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func waitUntilHierarchy(timeout: TimeInterval = 15.0, condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return condition()
}

@MainActor
private func sendKey(
    to window: NSWindow,
    keyCode: UInt16,
    characters: String,
    charactersIgnoringModifiers: String? = nil,
    modifierFlags: NSEvent.ModifierFlags = []
) {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
        isARepeat: false,
        keyCode: keyCode
    ) else { return }
    window.sendEvent(event)
}

@MainActor
private func runOrdinaryInboxVaultStaysFlatAssertion() async throws {
    let fixture = try ProjectHierarchyWorkspaceFixture(preseedGitMarker: false)
    defer { fixture.cleanup() }

    let first = try fixture.vault.capture(text: "# Morning Pages\nPlain commonplace note.")
    let second = try fixture.vault.capture(text: "# Reading Marginalia\nSecond entry.")

    let attachmentSource = fixture.directory.appendingPathComponent("sketch.txt")
    try "plain sketch".write(to: attachmentSource, atomically: true, encoding: .utf8)
    let current = try fixture.vault.read(first.url)
    _ = try fixture.vault.attach([attachmentSource], to: first.url, text: current, expectedContent: current)

    fixture.workspace.window?.makeKeyAndOrderFront(nil)
    fixture.workspace.searchPanel.refresh()
    let loaded = await waitUntilHierarchy {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count == 3
    }
    XCTAssertTrue(loaded)

    // Ordinary Inbox/ + Attachments/ vault renders zero folder section headers
    XCTAssertEqual(fixture.workspace.searchPanel.visibleSectionTitles, [])
    XCTAssertEqual(fixture.workspace.searchPanel.totalRowCount, fixture.workspace.searchPanel.visibleHits.count)
    let secondRow = try XCTUnwrap(fixture.workspace.searchPanel.rowIndex(for: second.url))
    XCTAssertNil(fixture.workspace.searchPanel.displayedPath(atRow: secondRow))
}

@MainActor
private func runProjectFolderSidebarGroupingKeyboardAndTagMergeAssertion() async throws {
    let fixture = try ProjectHierarchyWorkspaceFixture(preseedGitMarker: true)
    defer { fixture.cleanup() }

    let fm = FileManager.default
    for dir in ["docs/adr", "packages/a", "packages/b", "node_modules/pkg", "build/out"] {
        try fm.createDirectory(at: fixture.file(dir), withIntermediateDirectories: true)
    }

    let rootReadme = fixture.file("README.md")
    let changelog = fixture.file("CHANGELOG.md")
    let docsArch = fixture.file("docs/architecture.md")
    let docsAdr = fixture.file("docs/adr/001-storage.md")
    let pkgAReadme = fixture.file("packages/a/README.md")
    let pkgBReadme = fixture.file("packages/b/README.md")

    try "# Overview\nRoot repository overview.".write(to: rootReadme, atomically: true, encoding: .utf8)
    try "# Changelog\nRelease notes.".write(to: changelog, atomically: true, encoding: .utf8)
    try "# Architecture\nClean module layers #work".write(to: docsArch, atomically: true, encoding: .utf8)
    try "# ADR 001 Storage\nPlain Markdown durability #work".write(to: docsAdr, atomically: true, encoding: .utf8)
    try "# Overview\nPackage A parser.".write(to: pkgAReadme, atomically: true, encoding: .utf8)
    try "# Overview\nPackage B worker.".write(to: pkgBReadme, atomically: true, encoding: .utf8)

    // Dependency/build noise must never appear
    try "# Ignored NodePkg\nNoise".write(to: fixture.file("node_modules/pkg/README.md"), atomically: true, encoding: .utf8)
    try "# Ignored Build\nNoise".write(to: fixture.file("build/out/README.md"), atomically: true, encoding: .utf8)

    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)], ofItemAtPath: rootReadme.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: changelog.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_300)], ofItemAtPath: docsArch.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_250)], ofItemAtPath: docsAdr.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_150)], ofItemAtPath: pkgAReadme.path)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_120)], ofItemAtPath: pkgBReadme.path)

    let window = try XCTUnwrap(fixture.workspace.window)
    window.makeKeyAndOrderFront(nil)
    fixture.workspace.searchPanel.refresh()
    let loaded = await waitUntilHierarchy {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count == 6
    }
    XCTAssertTrue(loaded)

    // Exact included paths in folder section order (ROOT first, then natural subfolder paths)
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.relativePath),
        [
            "README.md",
            "CHANGELOG.md",
            "docs/architecture.md",
            "docs/adr/001-storage.md",
            "packages/a/README.md",
            "packages/b/README.md",
        ]
    )
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleSectionTitles,
        ["ROOT", "DOCS", "DOCS/ADR", "PACKAGES/A", "PACKAGES/B"]
    )
    XCTAssertTrue(fixture.workspace.searchPanel.isSectionHeaderRow(0))

    // Duplicate "Overview" titles display their disambiguating relative paths on SearchHitCell
    let pkgARow = try XCTUnwrap(fixture.workspace.searchPanel.rowIndex(for: pkgAReadme))
    let pkgBRow = try XCTUnwrap(fixture.workspace.searchPanel.rowIndex(for: pkgBReadme))
    XCTAssertEqual(fixture.workspace.searchPanel.displayedTitle(atRow: pkgARow), "Overview")
    XCTAssertEqual(fixture.workspace.searchPanel.displayedPath(atRow: pkgARow), "packages/a/README.md")
    XCTAssertEqual(fixture.workspace.searchPanel.displayedPath(atRow: pkgBRow), "packages/b/README.md")

    // Focus sidebar (⌘2 equivalent): selects first note row (skipping row 0 section header)
    fixture.workspace.searchPanel.selectNote(nil)
    fixture.workspace.searchPanel.focusSidebar()
    XCTAssertTrue(fixture.workspace.searchPanel.isSidebarFocused)
    XCTAssertEqual(fixture.workspace.searchPanel.selectedNoteURL, rootReadme)

    // Real NSEvent arrow navigation skips folder section headers cleanly (including macOS .numericPad/.function arrow flags)
    sendKey(to: window, keyCode: 125, characters: "\u{F701}", modifierFlags: [.numericPad, .function]) // -> CHANGELOG.md
    XCTAssertEqual(fixture.workspace.searchPanel.selectedNoteURL, changelog)
    sendKey(to: window, keyCode: 125, characters: "\u{F701}", modifierFlags: [.numericPad, .function]) // skips DOCS header -> docs/architecture.md
    XCTAssertEqual(fixture.workspace.searchPanel.selectedNoteURL, docsArch)
    sendKey(to: window, keyCode: 125, characters: "\u{F701}", modifierFlags: [.numericPad, .function]) // skips DOCS/ADR header -> docs/adr/001-storage.md
    XCTAssertEqual(fixture.workspace.searchPanel.selectedNoteURL, docsAdr)

    // Return opens the selected nested note URL into the workspace editor
    sendKey(to: window, keyCode: 36, characters: "\r")
    let openedNested = await waitUntilHierarchy {
        fixture.workspace.noteURL == docsAdr
    }
    XCTAssertTrue(openedNested)

    // Re-focus sidebar, press Up arrow across DOCS/ADR header back to docs/architecture.md, then Option+Return to open companion window
    fixture.workspace.searchPanel.focusSidebar()
    sendKey(to: window, keyCode: 126, characters: "\u{F700}", modifierFlags: [.numericPad, .function])
    XCTAssertEqual(fixture.workspace.searchPanel.selectedNoteURL, docsArch)
    sendKey(to: window, keyCode: 36, characters: "\r", modifierFlags: .option)
    let openedCompanion = await waitUntilHierarchy {
        fixture.workspace.noteWindows.contains(where: { $0.noteURL == docsArch })
    }
    XCTAssertTrue(openedCompanion)

    // Pinning packages/b/README.md lifts it into PINNED at the top and hides the now-empty PACKAGES/B unpinned header
    fixture.workspace.togglePinNote(pkgBReadme)
    XCTAssertEqual(fixture.workspace.searchPanel.visibleHits.first?.source.url, pkgBReadme)
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleSectionTitles,
        ["PINNED", "ROOT", "DOCS", "DOCS/ADR", "PACKAGES/A"]
    )
    let pinnedRow = try XCTUnwrap(fixture.workspace.searchPanel.rowIndex(for: pkgBReadme))
    XCTAssertEqual(fixture.workspace.searchPanel.displayedPath(atRow: pinnedRow), "packages/b/README.md")

    // Tag filtering (#work) hides empty folder sections and preserves exact matching notes
    fixture.workspace.searchPanel.setTagFilter("work")
    XCTAssertEqual(fixture.workspace.searchPanel.visibleSectionTitles, ["DOCS", "DOCS/ADR"])
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleHits.map(\.source.url),
        [docsArch, docsAdr]
    )

    // Shift+Down range selection across DOCS/ADR header selects only note rows (never headers) and enables Merge Notes
    fixture.workspace.searchPanel.selectNote(docsArch)
    fixture.workspace.searchPanel.focusSidebar()
    sendKey(to: window, keyCode: 125, characters: "\u{F701}", modifierFlags: [.shift, .numericPad, .function])
    XCTAssertEqual(fixture.workspace.selectedNotesForMerge, [docsArch, docsAdr])
    XCTAssertTrue(fixture.workspace.canMergeNotes)
    let archRowInFiltered = try XCTUnwrap(fixture.workspace.searchPanel.rowIndex(for: docsArch))
    let mergeMenu = try XCTUnwrap(fixture.workspace.searchPanel.contextMenuForRow(archRowInFiltered))
    XCTAssertEqual(mergeMenu.items.first?.title, "Merge 2 Notes…")

    // Clearing tag filter restores all folder sections
    fixture.workspace.searchPanel.setTagFilter(nil)
    XCTAssertEqual(
        fixture.workspace.searchPanel.visibleSectionTitles,
        ["PINNED", "ROOT", "DOCS", "DOCS/ADR", "PACKAGES/A"]
    )
}

@MainActor
private func runQuickSwitcherHighlightedPathDisambiguationAssertion() async throws {
    let fixture = try ProjectHierarchyWorkspaceFixture(preseedGitMarker: true)
    defer { fixture.cleanup() }

    let fm = FileManager.default
    try fm.createDirectory(at: fixture.file("packages/a"), withIntermediateDirectories: true)
    try fm.createDirectory(at: fixture.file("packages/b"), withIntermediateDirectories: true)

    let rootReadme = fixture.file("README.md")
    let pkgAReadme = fixture.file("packages/a/README.md")
    let pkgBReadme = fixture.file("packages/b/README.md")

    try "# Overview\nWorkspace root entry.".write(to: rootReadme, atomically: true, encoding: .utf8)
    try "# Overview\nTokenizer implementation.".write(to: pkgAReadme, atomically: true, encoding: .utf8)
    try "# Overview\nBackground job scheduler.".write(to: pkgBReadme, atomically: true, encoding: .utf8)

    fixture.workspace.window?.makeKeyAndOrderFront(nil)
    fixture.workspace.searchPanel.refresh()
    let loaded = await waitUntilHierarchy {
        !fixture.workspace.searchPanel.isProcessing && fixture.workspace.searchPanel.visibleHits.count == 3
    }
    XCTAssertTrue(loaded)

    fixture.workspace.showQuickSwitcher()
    XCTAssertTrue(fixture.workspace.isQuickSwitcherVisible)

    // Active query with non-empty highlights keeps disambiguating relative paths visible on every duplicate-titled hit
    fixture.workspace.quickSwitcher.query = "overview"
    XCTAssertEqual(fixture.workspace.quickSwitcher.hits.count, 3)
    XCTAssertTrue(fixture.workspace.quickSwitcher.hits.allSatisfy { !$0.highlights.isEmpty })
    let displayedPaths = (0..<3).compactMap { fixture.workspace.quickSwitcher.displayedPath(atRow: $0) }
    XCTAssertEqual(
        Set(displayedPaths),
        Set(["README.md", "packages/a/README.md", "packages/b/README.md"])
    )

    // Cross-field path + title query narrows directly to packages/b/README.md and opens it on confirm
    fixture.workspace.quickSwitcher.query = "packages/b overview"
    XCTAssertEqual(fixture.workspace.quickSwitcher.hits.map(\.source.url), [pkgBReadme])
    XCTAssertEqual(fixture.workspace.quickSwitcher.displayedPath(atRow: 0), "packages/b/README.md")
    XCTAssertTrue(fixture.workspace.quickSwitcher.confirmSelection())
    XCTAssertFalse(fixture.workspace.isQuickSwitcherVisible)
    XCTAssertEqual(fixture.workspace.noteURL, pkgBReadme)
}

#if canImport(XCTest)
@MainActor
final class ProjectFolderHierarchyTests: XCTestCase {
    func testOrdinaryInboxVaultRendersNoFolderSectionHeaders() async throws {
        try await runOrdinaryInboxVaultStaysFlatAssertion()
    }

    func testProjectFolderSidebarGroupingKeyboardNavigationTagFilterAndMultiSelect() async throws {
        try await runProjectFolderSidebarGroupingKeyboardAndTagMergeAssertion()
    }

    func testQuickSwitcherPreservesRelativePathsWhenQueryHighlightsArePresent() async throws {
        try await runQuickSwitcherHighlightedPathDisambiguationAssertion()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Project Folder Hierarchy UI", .serialized)
    struct ProjectFolderHierarchySuite {
        @Test("Ordinary Inbox vault renders flat chronological list with zero folder headers")
        @MainActor
        func ordinaryInboxVaultStaysFlat() async throws {
            try await runOrdinaryInboxVaultStaysFlatAssertion()
        }

        @Test("Project folder sidebar groups by folder headers, skips headers on arrow keys, filters tags, and multi-selects notes")
        @MainActor
        func projectFolderSidebarGroupingAndNavigation() async throws {
            try await runProjectFolderSidebarGroupingKeyboardAndTagMergeAssertion()
        }

        @Test("Quick Switcher preserves relative paths on highlighted matches and supports path+title queries")
        @MainActor
        func quickSwitcherHighlightedPathDisambiguation() async throws {
            try await runQuickSwitcherHighlightedPathDisambiguationAssertion()
        }
    }
}
#endif
