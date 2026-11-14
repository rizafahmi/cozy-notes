#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
import CozyCore
@testable import CozyNotes

private struct OutlineSignature: Equatable, CustomStringConvertible {
    let label: String
    let title: String
    let range: NSRange

    var description: String {
        "\(label):\(title)@(\(range.location),\(range.length))"
    }
}

@MainActor
private func outlineSignatures(in editor: CaptureEditor) -> [OutlineSignature] {
    editor.outlineItems.map { OutlineSignature(label: $0.label, title: $0.title, range: $0.range) }
}

@MainActor
private func assertOutline(_ actual: [OutlineSignature], equals expected: [OutlineSignature], context: String) throws {
    guard actual == expected else {
        throw NSError(
            domain: "DocumentOutlineRefreshTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(context): expected \(expected), got \(actual)"]
        )
    }
}

@MainActor
private func verifyOutlineUpdatesOnPasteAndPrependingHeading() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyOutlineRefreshTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let otherNote = try vault.capture(text: "# Other Note\nBody")
    let workspace = WorkspaceController(vault: vault)
    defer {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    workspace.editor.setOutlineVisible(true)
    workspace.window?.layoutIfNeeded()
    let textView = workspace.editor.textView

    // 1. Paste multi-heading text starting with plain prose into a blank note.
    do {
        workspace.newCapture()
        let pasted = "Overview paragraph\n\n# Heading 1\nIntro\n\n## Section 1\nBody\n\n## Section 2\nMore"
        textView.applyUndoableReplacement(in: textView.selectedRange(), with: pasted)
        let immediate = outlineSignatures(in: workspace.editor)

        _ = workspace.persistCurrent()
        let savedURL = workspace.noteURL!
        workspace.openNote(otherNote.url)
        workspace.openNote(savedURL)
        let afterReload = outlineSignatures(in: workspace.editor)
        try assertOutline(immediate, equals: afterReload, context: "Paste starting with prose into blank note")
        guard immediate.map(\.title) == ["Heading 1", "Section 1", "Section 2"] else {
            throw NSError(domain: "DocumentOutlineRefreshTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected titles: \(immediate)"])
        }
    }

    // 2. Paste multi-heading text starting with prose below an existing H1.
    do {
        let seed = try vault.capture(text: "# Main Title\n\n")
        workspace.openNote(seed.url)
        textView.setSelectedRange(NSRange(location: workspace.editor.nsText.length, length: 0))
        let pasted = "Intro text before sections\n\n## First Pasted H2\nAlpha\n\n### Nested H3\nBeta\n\n## Second Pasted H2\nGamma"
        textView.applyUndoableReplacement(in: textView.selectedRange(), with: pasted)
        let immediate = outlineSignatures(in: workspace.editor)

        _ = workspace.persistCurrent()
        workspace.openNote(otherNote.url)
        workspace.openNote(seed.url)
        let afterReload = outlineSignatures(in: workspace.editor)
        try assertOutline(immediate, equals: afterReload, context: "Paste starting with prose below existing H1")
    }

    // 3. Paste newline-terminated heading(s) above existing H2 sections.
    do {
        let seed = try vault.capture(text: "# Title\n\n## Second H2\nBody\n\n## Third H2\nEnd")
        workspace.openNote(seed.url)
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.applyUndoableReplacement(in: textView.selectedRange(), with: "## Pasted First H2\nDetails\n")
        let immediate = outlineSignatures(in: workspace.editor)

        _ = workspace.persistCurrent()
        workspace.openNote(otherNote.url)
        workspace.openNote(seed.url)
        let afterReload = outlineSignatures(in: workspace.editor)
        try assertOutline(immediate, equals: afterReload, context: "Paste newline-terminated H2 above existing H2s")
    }

    // 4. Add H2 before current H2 by pressing Return at column 0 of current H2, moving up, and typing.
    do {
        let seed = try vault.capture(text: "# Title\n\n## Current H2\nBody\n\n## Later H2\nMore")
        workspace.openNote(seed.url)
        let h2Loc = workspace.editor.nsText.range(of: "## Current H2").location
        textView.setSelectedRange(NSRange(location: h2Loc, length: 0))
        textView.insertNewline(nil)
        guard workspace.editor.outlineItems.map(\.title) == ["Title", "Current H2", "Later H2"] else {
            throw NSError(
                domain: "DocumentOutlineRefreshTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Pressing Return before H2 dropped headings: \(outlineSignatures(in: workspace.editor))"]
            )
        }
        textView.moveUp(nil)
        for ch in "## First H2" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        let immediate = outlineSignatures(in: workspace.editor)

        _ = workspace.persistCurrent()
        workspace.openNote(otherNote.url)
        workspace.openNote(seed.url)
        let afterReload = outlineSignatures(in: workspace.editor)
        try assertOutline(immediate, equals: afterReload, context: "Return before current H2 then type new H2")
    }

    // 5. Add H2 before current H2 by typing at column 0 of current H2 and pressing Return to split the line.
    do {
        let seed = try vault.capture(text: "# Title\n\n## Current H2\nBody")
        workspace.openNote(seed.url)
        let h2Loc = workspace.editor.nsText.range(of: "## Current H2").location
        textView.setSelectedRange(NSRange(location: h2Loc, length: 0))
        for ch in "## First H2" {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        textView.insertNewline(nil)
        let immediate = outlineSignatures(in: workspace.editor)

        _ = workspace.persistCurrent()
        workspace.openNote(otherNote.url)
        workspace.openNote(seed.url)
        let afterReload = outlineSignatures(in: workspace.editor)
        try assertOutline(immediate, equals: afterReload, context: "Type H2 prefix before current H2 then split with Return")
    }
}

#if canImport(XCTest)
@MainActor
final class DocumentOutlineRefreshTests: XCTestCase {
    func testOutlineUpdatesOnPasteAndPrependingHeading() throws {
        try verifyOutlineUpdatesOnPasteAndPrependingHeading()
    }
}
#endif

#if canImport(Testing)
@Suite("Document outline incremental refresh", .serialized)
struct DocumentOutlineRefreshSuite {
    @Test("Outline renders all headings immediately after paste and prepending H2 before H2")
    @MainActor
    func outlineUpdatesOnPasteAndPrependingHeading() throws {
        try verifyOutlineUpdatesOnPasteAndPrependingHeading()
    }
}
#endif
