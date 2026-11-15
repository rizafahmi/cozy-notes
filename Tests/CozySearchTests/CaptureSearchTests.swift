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

    func testProjectRepositorySearchIndexesOnlyMarkdownAndManagedFolders() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: fixture.file(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.file("node_modules/pkg"), withIntermediateDirectories: true)
        try "# Dependency Readme\nHidden from search".write(to: fixture.file("node_modules/pkg/README.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: fixture.file("Sources"), withIntermediateDirectories: true)
        try "let token = \"SWIFT_SOURCE_ONLY\"".write(to: fixture.file("Sources/main.swift"), atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: fixture.file("Sources/archive.zip"))
        try fm.createDirectory(at: fixture.file("docs"), withIntermediateDirectories: true)
        try "# Harness Spec\nThinking companion architecture".write(to: fixture.file("docs/SPEC.md"), atomically: true, encoding: .utf8)

        let snapshot = try CaptureSearch(vault: fixture.vault).scan()
        XCTAssertEqual(snapshot.sources.map(\.relativePath), ["docs/SPEC.md"])
        XCTAssertEqual(snapshot.search("Thinking companion").first?.source.title, "Harness Spec")
        XCTAssertTrue(snapshot.search("SWIFT_SOURCE_ONLY").isEmpty)
        XCTAssertTrue(snapshot.search("Dependency").isEmpty)
    }

    func testPinnedNotesSortFirstHidePinsManifestAndUpdateImmutably() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let fm = FileManager.default
        let older = try fixture.vault.capture(text: "# Older Note\nShared keyword alpha")
        let newer = try fixture.vault.capture(text: "# Newer Note\nShared keyword beta")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: older.url.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_500)], ofItemAtPath: newer.url.path)

        _ = try fixture.vault.setPinned(true, for: older.url)
        let snapshot = try CaptureSearch(vault: fixture.vault).scan()

        XCTAssertFalse(snapshot.sources.contains(where: { $0.relativePath == Vault.pinsFilename }))
        XCTAssertEqual(snapshot.search("").map(\.source.title), ["Older Note", "Newer Note"])
        XCTAssertEqual(snapshot.search("").map(\.source.isPinned), [true, false])
        // Tie-break on identical lexical match score favors pinned note
        XCTAssertEqual(snapshot.search("Shared keyword").map(\.source.title), ["Older Note", "Newer Note"])

        let newerRelPath = String(newer.url.path.dropFirst(fixture.vault.root.path.count + 1))
        let swapped = snapshot.updatingPinnedPaths([newerRelPath])
        XCTAssertEqual(swapped.search("").map(\.source.title), ["Newer Note", "Older Note"])
        XCTAssertEqual(swapped.search("").map(\.source.isPinned), [true, false])
    }

    func testTagAggregationHierarchicalFilteringAndQueryTagTokens() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.vault.capture(text: "# Q2 Roadmap\nShipping native tags #work #work/q2 and polish")
        _ = try fixture.vault.capture(text: "# Design Sync\nColor tokens #work #design")
        _ = try fixture.vault.capture(text: "# Weekend Reading\nBook notes #reading")

        let snapshot = try CaptureSearch(vault: fixture.vault).scan()
        XCTAssertEqual(
            snapshot.tagCounts,
            [
                TagCount(name: "work", count: 2),
                TagCount(name: "design", count: 1),
                TagCount(name: "reading", count: 1),
                TagCount(name: "work/q2", count: 1),
            ]
        )

        // Direct sidebar tagFilter (hierarchical: "work" matches both #work and #work/q2)
        XCTAssertEqual(
            Set(snapshot.search("", tagFilter: "work").map(\.source.title)),
            Set(["Q2 Roadmap", "Design Sync"])
        )
        XCTAssertEqual(
            snapshot.search("", tagFilter: "work/q2").map(\.source.title),
            ["Q2 Roadmap"]
        )
        XCTAssertEqual(
            snapshot.search("", tagFilter: "reading").map(\.source.title),
            ["Weekend Reading"]
        )

        // Query #tag tokens in Global Search combined with free-text keywords
        XCTAssertEqual(
            snapshot.search("#work tokens").map(\.source.title),
            ["Design Sync"]
        )
        XCTAssertEqual(
            snapshot.search("#work/q2").map(\.source.title),
            ["Q2 Roadmap"]
        )
        XCTAssertTrue(snapshot.search("#nonexistent").isEmpty)
    }
}

#if canImport(Testing)
import Testing

@Suite("Capture Search")
struct CaptureSearchSuite {
    @Test("AND case, original language, and grapheme-safe highlights")
    func andCaseAndGraphemeHighlights() throws {
        try CaptureSearchTests().testANDCaseOriginalLanguageAndGraphemeSafeHighlights()
    }

    @Test("Captured notes use content titles rather than storage identifiers")
    func capturedNotesUseContentTitles() throws {
        try CaptureSearchTests().testCapturedNotesUseContentTitlesRatherThanStorageIdentifiers()
    }

    @Test("Changed and deleted originals invalidate companions across restart")
    func changedOriginalsInvalidateCompanions() throws {
        try CaptureSearchTests().testChangedAndDeletedOriginalsInvalidateCompanionsAcrossRestart()
    }

    @Test("Original preservation, companion edits, and create collisions")
    func originalPreservationAndCompanionEdits() throws {
        try CaptureSearchTests().testOriginalPreservationCompanionEditsAndCreateCollisions()
    }

    @Test("PDF page references, partial, scanned, and corrupt statuses")
    func pdfPageReferencesAndStatuses() throws {
        try CaptureSearchTests().testPDFPageReferencesPartialScannedAndCorruptStatuses()
    }

    @Test("Symlink and hidden sources are not traversed and unsupported rows remain visible")
    func symlinkHiddenAndUnsupportedRows() throws {
        try CaptureSearchTests().testSymlinkAndHiddenSourcesAreNotTraversedAndUnsupportedRowsRemainVisible()
    }

    @Test("Cancellation before commit creates no companion")
    func cancellationBeforeCommit() throws {
        try CaptureSearchTests().testCancellationBeforeCommitCreatesNoCompanion()
    }

    @Test("Project repository search indexes only Markdown and managed folders")
    func projectRepositorySearchScoping() throws {
        try CaptureSearchTests().testProjectRepositorySearchIndexesOnlyMarkdownAndManagedFolders()
    }

    @Test("Pinned notes sort first, hide pins manifest, and update immutably")
    func pinnedNotesSearchOrderingAndImmutableUpdate() throws {
        try CaptureSearchTests().testPinnedNotesSortFirstHidePinsManifestAndUpdateImmutably()
    }

    @Test("Tag aggregation, hierarchical tag filtering, and #tag query tokens")
    func tagAggregationAndFiltering() throws {
        try CaptureSearchTests().testTagAggregationHierarchicalFilteringAndQueryTagTokens()
    }
}
#endif
