#if canImport(XCTest)
import XCTest
#else
import Testing
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") { #expect(a == b) }
func XCTAssertTrue(_ expr: Bool, _ message: String = "") { #expect(expr) }
func XCTAssertFalse(_ expr: Bool, _ message: String = "") { #expect(!expr) }
func XCTFail(_ message: String = "") { Issue.record(Comment(rawValue: message)) }
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "XCTUnwrap", code: 1) }
    return value
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        Issue.record("Expected error to be thrown")
    } catch {
        errorHandler(error)
    }
}
#endif
import Foundation
@testable import CozyCore

final class VaultTests: XCTestCase {
    private struct Fixture {
        let workspace: URL
        let root: URL
        let history: URL
        let vault: Vault

        init() throws {
            workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CozyCoreTests-\(UUID().uuidString)", isDirectory: true)
            root = workspace.appendingPathComponent("Vault", isDirectory: true)
            history = workspace.appendingPathComponent("LocalHistory", isDirectory: true)
            vault = try Vault(root: root, historyRoot: history)
        }

        func cleanup() { try? FileManager.default.removeItem(at: workspace) }
    }

    func testCapturePreservesAttachmentBytesAndEncodesMarkdownPaths() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.workspace.appendingPathComponent("One", isDirectory: true)
        let second = fixture.workspace.appendingPathComponent("Two", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let filename = "résumé [scan] #1%.png"
        let image = first.appendingPathComponent(filename)
        let duplicate = second.appendingPathComponent(filename)
        let originalBytes = Data([0, 1, 2, 255, 13, 10])
        let duplicateBytes = Data([42, 0, 255])
        try originalBytes.write(to: image)
        try duplicateBytes.write(to: duplicate)
        let note = try fixture.vault.capture(text: "\nReceipt\nKeep the original.", attachments: [image, duplicate])
        let markdown = try fixture.vault.read(note.url)
        XCTAssertEqual(note.title, "Receipt")
        XCTAssertTrue(markdown.hasPrefix("\nReceipt\nKeep the original.\n"))
        XCTAssertEqual(markdown.components(separatedBy: "Receipt").count, 2)
        XCTAssertTrue(markdown.contains("![résumé \\[scan\\] #1%.png]"))
        XCTAssertTrue(markdown.contains("%20%5Bscan%5D%20%231%25.png"))
        XCTAssertTrue(markdown.contains("%20%5Bscan%5D%20%231%25-2.png"))
        let directories = try FileManager.default.contentsOfDirectory(at: fixture.root.appendingPathComponent("Attachments"), includingPropertiesForKeys: nil)
        XCTAssertEqual(directories.count, 1)
        XCTAssertEqual(try Data(contentsOf: directories[0].appendingPathComponent(filename)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: directories[0].appendingPathComponent("résumé [scan] #1%-2.png")), duplicateBytes)
    }

    func testAttachmentFilenameSanitizationAndFailedCaptureRollback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.workspace.appendingPathComponent("photo\\draft\n.png")
        try Data([0, 255]).write(to: source)
        let note = try fixture.vault.capture(text: "", attachments: [source])
        XCTAssertEqual(note.title, "photo_draft_.png")
        XCTAssertTrue(try fixture.vault.read(note.url).contains("photo_draft_.png"))
        let before = try fixture.vault.notes().map(\.url)
        let attachmentsRoot = fixture.root.appendingPathComponent("Attachments")
        let beforeDirectories = try FileManager.default.contentsOfDirectory(atPath: attachmentsRoot.path).sorted()
        XCTAssertThrowsError(try fixture.vault.capture(text: "Should not commit", attachments: [source, fixture.workspace.appendingPathComponent("missing")]))
        XCTAssertEqual(try fixture.vault.notes().map(\.url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attachmentsRoot.path).sorted(), beforeDirectories)
    }

    func testOptimisticSaveRejectsExternalEditAndDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let note = try fixture.vault.capture(text: "Original\nBody")
        let expected = try fixture.vault.read(note.url)
        let external = "# External edit\n\nPreserve this.\n"
        try external.write(to: note.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.vault.save("# Stale editor\n", to: note.url, expectedContent: expected)) { error in
            guard case VaultError.conflict = error else { return XCTFail("Expected conflict, got \(error)") }
        }
        XCTAssertEqual(try fixture.vault.read(note.url), external)
        try fixture.vault.save("# Saved\n", to: note.url, expectedContent: external)
        XCTAssertEqual(try fixture.vault.read(note.url), "# Saved\n")
        try FileManager.default.removeItem(at: note.url)
        XCTAssertThrowsError(try fixture.vault.save("# Do not recreate\n", to: note.url, expectedContent: "# Saved\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.url.path))
    }

    func testRestoreRecoversChangedAndDeletedOriginalsButKeepsNewFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.workspace.appendingPathComponent("scan.png")
        let bytes = Data([9, 8, 7, 0, 255])
        try bytes.write(to: source)
        let changed = try fixture.vault.capture(text: "Changed later", attachments: [source])
        let deleted = try fixture.vault.capture(text: "Deleted later")
        let originalText = try fixture.vault.read(changed.url)
        let deletedText = try fixture.vault.read(deleted.url)
        let checkpoint = try fixture.vault.snapshot(label: "Before agent")
        let attachment = try XCTUnwrap(FileManager.default.enumerator(at: fixture.root.appendingPathComponent("Attachments"), includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "png" })
        try "# Agent rewrite\n".write(to: changed.url, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: deleted.url)
        try FileManager.default.removeItem(at: attachment)
        let new = try fixture.vault.capture(text: "New companion\nActual agent description.")
        let newText = try fixture.vault.read(new.url)
        try fixture.vault.restore(snapshotID: checkpoint.id)
        XCTAssertEqual(try fixture.vault.read(changed.url), originalText)
        XCTAssertEqual(try fixture.vault.read(deleted.url), deletedText)
        XCTAssertEqual(try fixture.vault.read(new.url), newText)
        XCTAssertEqual(try Data(contentsOf: attachment), bytes)
        let history = try fixture.vault.snapshots()
        XCTAssertEqual(history.count, 2)
        let beforeRestore = try XCTUnwrap(history.first { $0.id != checkpoint.id })
        // The automatic safety checkpoint can itself recover the pre-restore rewrite.
        try fixture.vault.restore(snapshotID: beforeRestore.id)
        XCTAssertEqual(try fixture.vault.read(changed.url), "# Agent rewrite\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deleted.url.path), "Restore always keeps newly present files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("History").path))
        XCTAssertThrowsError(try Vault(root: fixture.root, historyRoot: fixture.root.appendingPathComponent("history")))
    }

    func testSymlinkEscapesAreNeitherReadWrittenNorSnapshotted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = fixture.workspace.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let privateNote = outside.appendingPathComponent("secret.md")
        try "Private outside vault".write(to: privateNote, atomically: true, encoding: .utf8)
        let linkedDirectory = fixture.root.appendingPathComponent("Escaped")
        let linkedFile = fixture.root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: privateNote)
        XCTAssertThrowsError(try fixture.vault.read(linkedDirectory.appendingPathComponent("secret.md")))
        XCTAssertThrowsError(try fixture.vault.read(linkedFile))
        XCTAssertThrowsError(try fixture.vault.save("Overwrite", to: linkedFile, expectedContent: "Private outside vault"))
        XCTAssertThrowsError(try fixture.vault.read(privateNote))
        XCTAssertFalse(try fixture.vault.notes().contains { $0.title == "Private outside vault" })
        let checkpoint = try fixture.vault.snapshot(label: "Skip links")
        let storage = fixture.history.appendingPathComponent(checkpoint.id).appendingPathComponent("Files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("Escaped").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("linked.md").path))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Inbox"), withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.vault.capture(text: "Do not escape"))
        XCTAssertEqual(try String(contentsOf: privateNote, encoding: .utf8), "Private outside vault")
    }

    func testInitializationPreservesInstructionsAndDiscoveryFindsReorganizedNotes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let instructions = fixture.root.appendingPathComponent("AGENTS.md")
        try "# Existing user instructions\nKeep these.".write(to: instructions, atomically: true, encoding: .utf8)
        _ = try Vault(root: fixture.root, historyRoot: fixture.history)
        XCTAssertEqual(try String(contentsOf: instructions, encoding: .utf8), "# Existing user instructions\nKeep these.")
        let folder = fixture.root.appendingPathComponent("Projects/Research", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("agent-created.MD")
        try "# Reorganized\nCompanion text".write(to: note, atomically: true, encoding: .utf8)
        for hidden in [".hidden"] {
            let directory = fixture.root.appendingPathComponent(hidden)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "# Not visible".write(to: directory.appendingPathComponent("ignored.md"), atomically: true, encoding: .utf8)
        }
        let notes = try fixture.vault.notes()
        XCTAssertTrue(notes.contains { $0.url == instructions && $0.title == "Existing user instructions" })
        XCTAssertTrue(notes.contains { $0.url == note && $0.title == "Reorganized" && $0.excerpt == "Companion text" })
        XCTAssertFalse(notes.contains { $0.title == "Not visible" })
    }

    func testCapturePreservesMarkdownCodeFencesAndWhitespace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let text = "```swift\nlet value = \"# not a heading\"\n```\n\n  Keep this indentation.\n"
        let note = try fixture.vault.capture(text: text)
        XCTAssertEqual(try fixture.vault.read(note.url), text)
    }

    func testCaseVariantAttachmentNamesPreserveBothOriginals() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstFolder = fixture.workspace.appendingPathComponent("First")
        let secondFolder = fixture.workspace.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let first = firstFolder.appendingPathComponent("Picture.PNG")
        let second = secondFolder.appendingPathComponent("picture.png")
        let firstBytes = Data([1, 2, 3])
        let secondBytes = Data([4, 5, 6])
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        _ = try fixture.vault.capture(text: "Two screenshots", attachments: [first, second])
        let buckets = try FileManager.default.contentsOfDirectory(at: fixture.root.appendingPathComponent("Attachments"), includingPropertiesForKeys: nil)
        let files = try FileManager.default.contentsOfDirectory(at: XCTUnwrap(buckets.first), includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(try files.map { try Data(contentsOf: $0) }), Set([firstBytes, secondBytes]))
    }

    func testAttachToExistingNoteDeduplicatesAndResolvesLinkedAttachments() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.workspace.appendingPathComponent("diagram.png")
        let second = fixture.workspace.appendingPathComponent("Sub/diagram.png")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([10, 20, 30]).write(to: first)
        try Data([40, 50, 60]).write(to: second)

        let note = try fixture.vault.capture(text: "# Architecture\nInitial thought.", attachments: [first])
        let initial = try fixture.vault.read(note.url)
        let updated = try fixture.vault.attach([second], to: note.url, text: initial, expectedContent: initial)
        XCTAssertTrue(updated.contains("diagram.png"))
        XCTAssertTrue(updated.contains("diagram-2.png"))

        let linked = fixture.vault.linkedAttachments(in: updated, relativeTo: note.url)
        XCTAssertEqual(linked.count, 2)
        XCTAssertEqual(try Data(contentsOf: linked[0].url), Data([10, 20, 30]))
        XCTAssertEqual(try Data(contentsOf: linked[1].url), Data([40, 50, 60]))
    }

    func testDeleteNoteCreatesRecoveryCheckpointAndRemovesAttachmentFolder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let image = fixture.workspace.appendingPathComponent("sketch.png")
        let imageBytes = Data([1, 3, 3, 7, 255])
        try imageBytes.write(to: image)

        let doomed = try fixture.vault.capture(text: "# Ephemeral Draft\nDelete this note and its attachment.", attachments: [image])
        let keeper = try fixture.vault.capture(text: "# Keeper\nStay in the vault.")
        let doomedText = try fixture.vault.read(doomed.url)
        let linked = fixture.vault.linkedAttachments(in: doomedText, relativeTo: doomed.url)
        XCTAssertEqual(linked.count, 1)
        let attachmentURL = try XCTUnwrap(linked.first?.url)
        let attachmentFolder = attachmentURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentFolder.path))

        let checkpoint = try fixture.vault.delete(doomed.url, moveToTrash: false)
        XCTAssertTrue(checkpoint.label.contains("Ephemeral Draft"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentFolder.path))
        XCTAssertEqual(try fixture.vault.notes().map(\.url), [keeper.url])

        // Restoring the automatic checkpoint recovers both the deleted note and its attachment folder
        try fixture.vault.restore(snapshotID: checkpoint.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doomed.url.path))
        XCTAssertEqual(try fixture.vault.read(doomed.url), doomedText)
        XCTAssertEqual(try Data(contentsOf: attachmentURL), imageBytes)

        // Deleting paths outside the vault must be rejected
        let outside = fixture.workspace.appendingPathComponent("outside.md")
        try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.vault.delete(outside, moveToTrash: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testWikiLinkParsingResolutionAndNoteCreation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let roadmap = try fixture.vault.capture(text: "# Product Roadmap\nQ4 milestones and release plan.")
        let design = try fixture.vault.capture(text: "# Design System\nTypography and color tokens.")

        let sample = "See [[Product Roadmap]] and [[Design System|UI Tokens]], ignore [[]] and [[   ]]."
        let links = Vault.wikiLinks(in: sample)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].target, "Product Roadmap")
        XCTAssertEqual(links[0].alias, nil)
        XCTAssertEqual(links[0].displayText, "Product Roadmap")
        XCTAssertEqual(links[1].target, "Design System")
        XCTAssertEqual(links[1].alias, "UI Tokens")
        XCTAssertEqual(links[1].displayText, "UI Tokens")

        // Active query detection while typing [[...
        let typing = "Link to [[Prod" as NSString
        let active = try XCTUnwrap(Vault.activeWikiLinkQuery(inNSString: typing, cursorLocation: typing.length))
        XCTAssertEqual(active.query, "Prod")
        XCTAssertEqual(active.replacementRange, NSRange(location: 8, length: 6))

        // Resolution by title (case-insensitive) and filename stem
        XCTAssertEqual(try fixture.vault.resolveNote(matching: "product roadmap")?.url, roadmap.url)
        XCTAssertEqual(try fixture.vault.resolveNote(matching: "Design System#Colors")?.url, design.url)
        let stem = roadmap.url.deletingPathExtension().lastPathComponent
        XCTAssertEqual(try fixture.vault.resolveNote(matching: stem)?.url, roadmap.url)

        // openOrCreateNote resolves existing note without creating a duplicate
        let existingResult = try fixture.vault.openOrCreateNote(matching: "Product Roadmap")
        XCTAssertFalse(existingResult.created)
        XCTAssertEqual(existingResult.record.url, roadmap.url)

        // openOrCreateNote creates a new note initialized with "# <Title>" when missing
        let createdResult = try fixture.vault.openOrCreateNote(matching: "Architecture RFC")
        XCTAssertTrue(createdResult.created)
        XCTAssertEqual(createdResult.record.title, "Architecture RFC")
        XCTAssertEqual(try fixture.vault.read(createdResult.record.url), "# Architecture RFC\n\n")
        XCTAssertEqual(try fixture.vault.resolveNote(matching: "Architecture RFC")?.url, createdResult.record.url)
    }

    func testProjectRepositoryPrunesBuildDirectoriesAndScopesToMarkdownAndManagedFolders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default

        // Mark root as a project repository (.git + Package.swift)
        try fm.createDirectory(at: fixture.root.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\n".write(to: fixture.root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        XCTAssertTrue(fixture.vault.isProjectRepository)

        // Create Markdown docs at root and in docs/
        let planURL = fixture.root.appendingPathComponent("PLAN.md")
        let archURL = fixture.root.appendingPathComponent("docs/architecture.md")
        try fm.createDirectory(at: archURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Execution Plan\nStep 1".write(to: planURL, atomically: true, encoding: .utf8)
        try "# System Architecture\nLayers".write(to: archURL, atomically: true, encoding: .utf8)

        // Create ignored directories (node_modules, build, target, vendor) containing .md files
        for ignored in ["node_modules/pkg", "build/gen", "target/debug", "vendor/bundle", "DerivedData/Index"] {
            let dir = fixture.root.appendingPathComponent(ignored, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "# Ignored Dependency Doc\nNoise".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }

        // Create repo source files and non-vault assets outside Attachments/
        let srcDir = fixture.root.appendingPathComponent("Sources/App", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "struct App {}".write(to: srcDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: srcDir.appendingPathComponent("icon.png"))

        // Capture a note with an attachment inside managed Inbox/ and Attachments/
        let externalImg = fixture.workspace.appendingPathComponent("screenshot.png")
        try Data([10, 20, 30]).write(to: externalImg)
        let captured = try fixture.vault.capture(text: "# Captured Scratchpad\nNotes", attachments: [externalImg])

        let noteURLs = Set(try fixture.vault.notes().map(\.url))
        XCTAssertEqual(noteURLs, Set([planURL, archURL, captured.url]))

        let sources = try fixture.vault.sourceFiles()
        XCTAssertTrue(sources.contains(planURL))
        XCTAssertTrue(sources.contains(archURL))
        XCTAssertTrue(sources.contains(captured.url))
        XCTAssertTrue(sources.contains { $0.lastPathComponent == "screenshot.png" && $0.path.contains("/Attachments/") })
        XCTAssertFalse(sources.contains { $0.lastPathComponent == "main.swift" })
        XCTAssertFalse(sources.contains { $0.lastPathComponent == "icon.png" })
        XCTAssertFalse(sources.contains { $0.path.contains("/node_modules/") || $0.path.contains("/build/") || $0.path.contains("/target/") })

        // Verify CAS save works for in-place external conflict resolution against reviewed disk content
        try "# Execution Plan\nExternal Agent Edit".write(to: planURL, atomically: true, encoding: .utf8)
        try fixture.vault.save("# Execution Plan\nUser Overwrite", to: planURL, expectedContent: "# Execution Plan\nExternal Agent Edit")
        XCTAssertEqual(try fixture.vault.read(planURL), "# Execution Plan\nUser Overwrite")
    }

    func testDependencyDirectoriesAreHiddenWhileUserNoteFoldersRemainVisibleAndSnapshotted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default
        XCTAssertFalse(fixture.vault.isProjectRepository)

        // User folders in a non-repo vault (including "Captures/" and "notes/build/") must stay visible and snapshotted
        let capturesNote = fixture.root.appendingPathComponent("Captures/idea.md")
        let buildNote = fixture.root.appendingPathComponent("notes/build/idea.md")
        let rootBuildNote = fixture.root.appendingPathComponent("build/plan.md")
        for url in [capturesNote, buildNote, rootBuildNote] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# \(url.deletingLastPathComponent().lastPathComponent) Note\nUser content".write(to: url, atomically: true, encoding: .utf8)
        }

        // Nested Node project with package.json + node_modules, plus a custom Python virtualenv with pyvenv.cfg
        let nestedProj = fixture.root.appendingPathComponent("proj", isDirectory: true)
        let nestedNodeMod = nestedProj.appendingPathComponent("node_modules/x", isDirectory: true)
        let nestedProjReadme = nestedProj.appendingPathComponent("README.md")
        try fm.createDirectory(at: nestedNodeMod, withIntermediateDirectories: true)
        try "{\"name\":\"proj\"}".write(to: nestedProj.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "# Project Readme".write(to: nestedProjReadme, atomically: true, encoding: .utf8)
        try "# Hidden NPM Readme".write(to: nestedNodeMod.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let customVenv = fixture.root.appendingPathComponent("custom-py-env", isDirectory: true)
        let venvPkg = customVenv.appendingPathComponent("lib/python3.12/site-packages/pkg", isDirectory: true)
        try fm.createDirectory(at: venvPkg, withIntermediateDirectories: true)
        try "home = /usr/bin\n".write(to: customVenv.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
        try "# Hidden Venv Readme".write(to: venvPkg.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // Nested Elixir project with mix.exs + deps/ and _build/
        let elixirProj = fixture.root.appendingPathComponent("elixir-app", isDirectory: true)
        let elixirDeps = elixirProj.appendingPathComponent("deps/phoenix", isDirectory: true)
        let elixirBuild = elixirProj.appendingPathComponent("_build/dev", isDirectory: true)
        let elixirGuide = elixirProj.appendingPathComponent("GUIDE.md")
        try fm.createDirectory(at: elixirDeps, withIntermediateDirectories: true)
        try fm.createDirectory(at: elixirBuild, withIntermediateDirectories: true)
        try "defmodule App.MixProject do end".write(to: elixirProj.appendingPathComponent("mix.exs"), atomically: true, encoding: .utf8)
        try "# Elixir Guide".write(to: elixirGuide, atomically: true, encoding: .utf8)
        try "# Phoenix Dep Readme".write(to: elixirDeps.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Mix Build Artifact".write(to: elixirBuild.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let noteURLs = Set(try fixture.vault.notes().map(\.url))
        XCTAssertEqual(noteURLs, Set([capturesNote, buildNote, rootBuildNote, nestedProjReadme, elixirGuide]))

        let checkpoint = try fixture.vault.snapshot(label: "Preserve user folders")
        let snapshotStorage = fixture.history.appendingPathComponent(checkpoint.id).appendingPathComponent("Files")
        XCTAssertTrue(fm.fileExists(atPath: snapshotStorage.appendingPathComponent("Captures/idea.md").path))
        XCTAssertTrue(fm.fileExists(atPath: snapshotStorage.appendingPathComponent("notes/build/idea.md").path))
        XCTAssertTrue(fm.fileExists(atPath: snapshotStorage.appendingPathComponent("build/plan.md").path))
        XCTAssertFalse(fm.fileExists(atPath: snapshotStorage.appendingPathComponent("proj/node_modules/x/README.md").path))
        XCTAssertFalse(fm.fileExists(atPath: snapshotStorage.appendingPathComponent("elixir-app/deps/phoenix/README.md").path))
    }

    func testPinningPersistsDotfileSortsModifiedFirstAndRecoversAcrossDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default
        let pinsFile = fixture.root.appendingPathComponent(Vault.pinsFilename)

        let olderPinned = try fixture.vault.capture(text: "# Older Pinned\nFirst note")
        let newerPinned = try fixture.vault.capture(text: "# Newer Pinned\nSecond note")
        let newestUnpinned = try fixture.vault.capture(text: "# Newest Unpinned\nThird note")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        try fm.setAttributes([.modificationDate: t0], ofItemAtPath: olderPinned.url.path)
        try fm.setAttributes([.modificationDate: t1], ofItemAtPath: newerPinned.url.path)
        try fm.setAttributes([.modificationDate: t2], ofItemAtPath: newestUnpinned.url.path)

        let olderBytesBefore = try Data(contentsOf: olderPinned.url)
        let olderModBefore = try fm.attributesOfItem(atPath: olderPinned.url.path)[.modificationDate] as? Date

        XCTAssertFalse(fm.fileExists(atPath: pinsFile.path))
        XCTAssertEqual(try fixture.vault.notes().map(\.title), ["Newest Unpinned", "Newer Pinned", "Older Pinned"])

        XCTAssertTrue(try fixture.vault.togglePinned(for: olderPinned.url))
        XCTAssertTrue(try fixture.vault.setPinned(true, for: newerPinned.url))
        XCTAssertTrue(fm.fileExists(atPath: pinsFile.path))
        XCTAssertEqual(try Data(contentsOf: olderPinned.url), olderBytesBefore)
        XCTAssertEqual(try fm.attributesOfItem(atPath: olderPinned.url.path)[.modificationDate] as? Date, olderModBefore)

        let sorted = try fixture.vault.notes()
        XCTAssertEqual(sorted.map(\.title), ["Newer Pinned", "Older Pinned", "Newest Unpinned"])
        XCTAssertEqual(sorted.map(\.isPinned), [true, true, false])

        // Re-open vault on the same directory to verify persistence across launches
        let reopened = try Vault(root: fixture.root, historyRoot: fixture.history)
        XCTAssertTrue(reopened.isPinned(olderPinned.url))
        XCTAssertTrue(reopened.isPinned(newerPinned.url))
        XCTAssertFalse(reopened.isPinned(newestUnpinned.url))

        // Deleting a pinned note removes its stale pin entry, and restoring the pre-delete checkpoint restores both
        let checkpoint = try fixture.vault.delete(newerPinned.url, moveToTrash: false)
        XCTAssertFalse(fixture.vault.isPinned(newerPinned.url))
        XCTAssertTrue(fixture.vault.isPinned(olderPinned.url))

        try fixture.vault.restore(snapshotID: checkpoint.id)
        XCTAssertTrue(fm.fileExists(atPath: newerPinned.url.path))
        XCTAssertTrue(fixture.vault.isPinned(newerPinned.url))
        XCTAssertTrue(fixture.vault.isPinned(olderPinned.url))

        // Unpinning the remaining notes removes .cozy-pins.json cleanly
        XCTAssertFalse(try fixture.vault.setPinned(false, for: olderPinned.url))
        XCTAssertFalse(try fixture.vault.togglePinned(for: newerPinned.url))
        XCTAssertFalse(fm.fileExists(atPath: pinsFile.path))

        // Security invariants: outside paths, Extracted Text companions, and symlinked .cozy-pins.json are rejected
        let outsideNote = fixture.workspace.appendingPathComponent("outside.md")
        try "# Outside".write(to: outsideNote, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.vault.setPinned(true, for: outsideNote))

        let extractedDir = fixture.root.appendingPathComponent("Extracted Text", isDirectory: true)
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        let companionMeta = Data("{\"source\":\"doc.pdf\",\"fingerprint\":\"fp1\",\"bodyHash\":\"bh1\"}".utf8).base64EncodedString()
        let companionNote = extractedDir.appendingPathComponent("companion.md")
        try "<!-- cozy-extracted-text:v1 \(companionMeta) -->\n# Companion".write(to: companionNote, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.vault.setPinned(true, for: companionNote))

        let symlinkTarget = fixture.workspace.appendingPathComponent("hijack.json")
        try "{\"version\":1,\"pinned\":[]}".write(to: symlinkTarget, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: pinsFile, withDestinationURL: symlinkTarget)
        XCTAssertTrue(fixture.vault.pinnedRelativePaths().isEmpty)
        XCTAssertThrowsError(try fixture.vault.setPinned(true, for: olderPinned.url))
    }
}

#if canImport(Testing)
import Testing

@Suite("Vault Core")
struct VaultCoreSuite {
    @Test("Capture preserves attachment bytes and encodes Markdown paths")
    func capturePreservesAttachmentBytes() throws {
        try VaultTests().testCapturePreservesAttachmentBytesAndEncodesMarkdownPaths()
    }

    @Test("Attachment filename sanitization and failed capture rollback")
    func attachmentSanitizationAndRollback() throws {
        try VaultTests().testAttachmentFilenameSanitizationAndFailedCaptureRollback()
    }

    @Test("Optimistic save rejects external edit and deletion")
    func optimisticSaveRejectsConflict() throws {
        try VaultTests().testOptimisticSaveRejectsExternalEditAndDeletion()
    }

    @Test("Restore recovers changed and deleted originals but keeps new files")
    func restoreRecoversOriginals() throws {
        try VaultTests().testRestoreRecoversChangedAndDeletedOriginalsButKeepsNewFiles()
    }

    @Test("Symlink escapes are neither read, written, nor snapshotted")
    func symlinkEscapesRejected() throws {
        try VaultTests().testSymlinkEscapesAreNeitherReadWrittenNorSnapshotted()
    }

    @Test("Initialization preserves instructions and discovery finds reorganized notes")
    func initializationPreservesInstructions() throws {
        try VaultTests().testInitializationPreservesInstructionsAndDiscoveryFindsReorganizedNotes()
    }

    @Test("Capture preserves Markdown code fences and whitespace")
    func capturePreservesCodeFences() throws {
        try VaultTests().testCapturePreservesMarkdownCodeFencesAndWhitespace()
    }

    @Test("Case-variant attachment names preserve both originals")
    func caseVariantAttachments() throws {
        try VaultTests().testCaseVariantAttachmentNamesPreserveBothOriginals()
    }

    @Test("Attach to existing note deduplicates and resolves linked attachments")
    func attachToExistingNote() throws {
        try VaultTests().testAttachToExistingNoteDeduplicatesAndResolvesLinkedAttachments()
    }

    @Test("Deleting a note checkpoints recovery and removes its attachment folder")
    func deleteNoteAndRecover() throws {
        try VaultTests().testDeleteNoteCreatesRecoveryCheckpointAndRemovesAttachmentFolder()
    }

    @Test("Wiki-links parse, resolve by title or stem, and create missing notes")
    func wikiLinksResolveAndCreate() throws {
        try VaultTests().testWikiLinkParsingResolutionAndNoteCreation()
    }

    @Test("Project repository prunes build/dependency dirs and scopes indexing to Markdown and managed folders")
    func projectRepositoryScoping() throws {
        try VaultTests().testProjectRepositoryPrunesBuildDirectoriesAndScopesToMarkdownAndManagedFolders()
    }

    @Test("Dependency directories are hidden while user note folders remain visible and snapshotted")
    func dependencyDirectoriesHiddenWhileUserNoteFoldersPreserved() throws {
        try VaultTests().testDependencyDirectoriesAreHiddenWhileUserNoteFoldersRemainVisibleAndSnapshotted()
    }

    @Test("Pinning persists dotfile, sorts modified first, and recovers across deletion")
    func pinningPersistsSortsAndRecovers() throws {
        try VaultTests().testPinningPersistsDotfileSortsModifiedFirstAndRecoversAcrossDeletion()
    }
}
#endif
