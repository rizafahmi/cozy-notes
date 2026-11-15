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
private func verifyNewNotePlainTextUsesThemeInk() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyNewNoteTextColorTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let workspace = WorkspaceController(vault: vault)
    defer {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    // Seed an existing note first, then trigger Cmd+N (newCapture) to reset into a fresh note.
    workspace.editor.text = "# Existing Heading\nSome body"
    workspace.newCapture()

    let textView = workspace.editor.textView
    guard let storage = textView.textStorage else {
        throw NSError(domain: "NewNoteTextColorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing textStorage"])
    }
    precondition(storage.length == 0)

    // Type plain text without any heading or markdown syntax.
    for ch in "plain text without markdown" {
        textView.insertText(String(ch), replacementRange: textView.selectedRange())
    }

    guard workspace.editor.text == "plain text without markdown" else {
        throw NSError(domain: "NewNoteTextColorTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected editor text: \(workspace.editor.text)"])
    }
    for idx in 0..<storage.length {
        let color = storage.attribute(.foregroundColor, at: idx, effectiveRange: nil) as? NSColor
        guard color == Theme.ink else {
            throw NSError(domain: "NewNoteTextColorTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Character at \(idx) had color \(String(describing: color)) instead of Theme.ink"])
        }
        let font = storage.attribute(.font, at: idx, effectiveRange: nil) as? NSFont
        guard font == Theme.bodyFont(Theme.baseProseSize) else {
            throw NSError(domain: "NewNoteTextColorTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Character at \(idx) had font \(String(describing: font)) instead of bodyFont"])
        }
    }

    // Also verify single-line markdown unwrapping (e.g. removing `# ` on the only line) restores Theme.ink.
    workspace.newCapture()
    textView.insertText("# Heading", replacementRange: textView.selectedRange())
    textView.toggleHeading1(nil)
    guard workspace.editor.text == "Heading" else {
        throw NSError(domain: "NewNoteTextColorTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unexpected unwrapped text: \(workspace.editor.text)"])
    }
    for idx in 0..<storage.length {
        let color = storage.attribute(.foregroundColor, at: idx, effectiveRange: nil) as? NSColor
        guard color == Theme.ink else {
            throw NSError(domain: "NewNoteTextColorTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unwrapped heading character at \(idx) had color \(String(describing: color)) instead of Theme.ink"])
        }
    }
}

#if canImport(XCTest)
@MainActor
final class NewNoteTextColorTests: XCTestCase {
    func testNewNotePlainTextUsesThemeInk() throws {
        try verifyNewNotePlainTextUsesThemeInk()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("New note plain text attributes", .serialized)
    struct NewNoteTextColorSuite {
        @Test("Typing plain text in a new note after Cmd+N applies Theme.ink and body font")
        @MainActor
        func newNotePlainTextUsesThemeInk() throws {
            try verifyNewNotePlainTextUsesThemeInk()
        }
    }
}
#endif
