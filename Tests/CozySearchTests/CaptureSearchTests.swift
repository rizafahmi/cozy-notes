import XCTest
import Foundation
import CoreGraphics
import CoreText
import CryptoKit
@testable import CozyCore
@testable import CozySearch

final class CaptureSearchTests: XCTestCase {
    private struct Fixture {
        let workspace: URL
        let vault: Vault
        init() throws {
            workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CozySearchTests-\(UUID().uuidString)", isDirectory: true)
            vault = try Vault(root: workspace.appendingPathComponent("Vault", isDirectory: true), historyRoot: workspace.appendingPathComponent("History", isDirectory: true))
        }
        func cleanup() { try? FileManager.default.removeItem(at: workspace) }
        func file(_ path: String) -> URL { vault.root.appendingPathComponent(path) }
        func companion(_ path: String) -> URL {
            let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            return file("Extracted Text/\(hash).md")
        }
    }

    private func pdf(_ url: URL, pages: [String?]) throws {
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil)])
                context.textPosition = CGPoint(x: 40, y: 700)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func process(_ engine: CaptureSearch) throws -> SearchSnapshot {
        try engine.makeSearchable(progress: { _, _, _ in }, cancelled: { false })
    }

    func testANDCaseOriginalLanguageAndGraphemeSafeHighlights() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let text = "Family 👨‍👩‍👧‍👦 — cafe\u{301} — BELANJA kebutuhan rumah"
        try text.write(to: fixture.file("capture.txt"), atomically: true, encoding: .utf8)
        let snapshot = try CaptureSearch(vault: fixture.vault).scan()
        XCTAssertEqual(snapshot.search("belanja RUMAH").count, 1)
        XCTAssertTrue(snapshot.search("belanja absent").isEmpty)
        let hit = try XCTUnwrap(snapshot.search("👨‍👩‍👧‍👦 café").first)
        XCTAssertFalse(hit.highlights.isEmpty)
        for highlight in hit.highlights {
            let range = try XCTUnwrap(Range(highlight, in: hit.snippet))
            XCTAssertTrue(hit.snippet.indices.contains(range.lowerBound))
            XCTAssertTrue(range.upperBound == hit.snippet.endIndex || hit.snippet.indices.contains(range.upperBound))
        }
        XCTAssertEqual(snapshot.search("").count, 1)
    }

    func testCapturedNotesUseContentTitlesRatherThanStorageIdentifiers() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let note = try fixture.vault.capture(text: "\n# Rencana perjalanan\nPesanan MERAPI742 untuk Yogyakarta.")
        let snapshot = try CaptureSearch(vault: fixture.vault).scan()
        let hit = try XCTUnwrap(snapshot.search("MERAPI742").first)
        XCTAssertEqual(hit.source.url, note.url)
        XCTAssertEqual(hit.source.title, "Rencana perjalanan")
    }

    func testChangedAndDeletedOriginalsInvalidateCompanionsAcrossRestart() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = fixture.file("receipt.pdf")
        try pdf(original, pages: ["Old secret token"])
        let engine = CaptureSearch(vault: fixture.vault)
        XCTAssertEqual(try process(engine).search("secret").first?.page, 1)
        XCTAssertEqual(try CaptureSearch(vault: fixture.vault).scan().search("secret").count, 1)
        try pdf(original, pages: ["Replacement text"])
        let changed = try engine.scan()
        XCTAssertTrue(changed.search("secret").isEmpty)
        XCTAssertEqual(changed.sources.first?.state, .pending)
        XCTAssertTrue(try CaptureSearch(vault: fixture.vault).scan().search("secret").isEmpty)
        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(try engine.scan().sources.isEmpty)
    }

    func testOriginalPreservationCompanionEditsAndCreateCollisions() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = fixture.file("original.pdf")
        try pdf(original, pages: ["Preserve this original"])
        let bytes = try Data(contentsOf: original)
        let engine = CaptureSearch(vault: fixture.vault)
        _ = try process(engine)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let companion = fixture.companion("original.pdf")
        let edited = try String(contentsOf: companion, encoding: .utf8) + "\nUser annotation\n"
        try edited.write(to: companion, atomically: true, encoding: .utf8)
        XCTAssertTrue(try engine.scan().search("Preserve").isEmpty)
        XCTAssertEqual(try process(engine).sources.first?.state, .unreadable)
        XCTAssertEqual(try String(contentsOf: companion, encoding: .utf8), edited)
        XCTAssertTrue(try fixture.vault.notes().isEmpty)
        try FileManager.default.removeItem(at: companion)
        let userNote = "# My own note\nDo not replace me."
        try userNote.write(to: companion, atomically: true, encoding: .utf8)
        _ = try process(engine)
        XCTAssertEqual(try String(contentsOf: companion, encoding: .utf8), userNote)
        XCTAssertTrue(try fixture.vault.notes().contains { $0.url == companion })
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testPDFPageReferencesPartialScannedAndCorruptStatuses() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try pdf(fixture.file("mixed.pdf"), pages: ["First page alpha", nil, "Third page beta"])
        try pdf(fixture.file("scanned.pdf"), pages: [nil])
        try Data("not a PDF".utf8).write(to: fixture.file("broken.pdf"))
        try Data([0, 1, 2]).write(to: fixture.file("broken.png"))
        let snapshot = try process(CaptureSearch(vault: fixture.vault))
        let hit = try XCTUnwrap(snapshot.search("beta").first)
        XCTAssertEqual(hit.page, 3)
        XCTAssertEqual(hit.source.url, fixture.file("mixed.pdf"))
        XCTAssertEqual(hit.source.state, .partial)
        XCTAssertTrue(hit.source.detail.contains("2"))
        for name in ["scanned.pdf", "broken.pdf", "broken.png"] {
            XCTAssertEqual(snapshot.sources.first { $0.relativePath == name }?.state, .unreadable)
        }
        XCTAssertTrue(snapshot.search("alpha beta").isEmpty)
    }

    func testSymlinkAndHiddenSourcesAreNotTraversedAndUnsupportedRowsRemainVisible() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let outside = fixture.workspace.appendingPathComponent("outside.txt")
        try "Private external words".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.file("linked.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.file("external-folder"), withDestinationURL: fixture.workspace)
        try "Hidden".write(to: fixture.file(".hidden.txt"), atomically: true, encoding: .utf8)
        try Data([1, 2]).write(to: fixture.file("archive.zip"))
        let snapshot = try CaptureSearch(vault: fixture.vault).scan()
        XCTAssertEqual(snapshot.sources.map(\.relativePath), ["archive.zip"])
        XCTAssertEqual(snapshot.search("archive").first?.source.state, .unsupported)
        XCTAssertEqual(snapshot.search("").count, 1)
    }

    func testCancellationBeforeCommitCreatesNoCompanion() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try pdf(fixture.file("cancel.pdf"), pages: ["Do not commit"])
        let engine = CaptureSearch(vault: fixture.vault)
        var cancelled = false
        let snapshot = try engine.makeSearchable(progress: { _, _, _ in cancelled = true }, cancelled: { cancelled })
        XCTAssertEqual(snapshot.sources.first?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.companion("cancel.pdf").path))
    }
}
