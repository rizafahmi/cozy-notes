import XCTest
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
        XCTAssertTrue(notes.contains { $0.url == note && $0.title == "Reorganized" && $0.excerpt == "Companion text" })
        XCTAssertFalse(notes.contains { $0.title == "Not visible" })
    }

    func testCapturePreservesMarkdownCodeFencesAndWhitespace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let text = "```swift\nlet value = \"# not a heading\"\n```\n\n  Keep this indentation.\n"
        let note = try fixture.vault.capture(text: text)
        XCTAssertEqual(try fixture.vault.read(note.url), text)
        XCTAssertFalse(try fixture.vault.notes().contains { $0.url.lastPathComponent == "AGENTS.md" })
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
}
