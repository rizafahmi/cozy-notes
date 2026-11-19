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
private func makeInlineImageTestWorkspace() throws -> (workspace: WorkspaceController, vault: Vault, window: NSWindow, directory: URL) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("CozyInlineImageTests-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("Vault", isDirectory: true)
    let history = directory.appendingPathComponent("LocalHistory", isDirectory: true)
    let vault = try Vault(root: root, historyRoot: history)
    let workspace = WorkspaceController(vault: vault)
    guard let window = workspace.window else {
        workspace.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw NSError(domain: "InlineImageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing workspace window"])
    }
    window.setContentSize(NSSize(width: 960, height: 720))
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return (workspace, vault, window, directory)
}

private func writeSyntheticPNG(to url: URL, pixelWidth: Int = 800, pixelHeight: Int = 400) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "InlineImageTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap rep"])
    }
    rep.size = NSSize(width: pixelWidth, height: pixelHeight)
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        NSColor(calibratedRed: 0.16, green: 0.44, blue: 0.78, alpha: 1.0).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)).fill()
        NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.22, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: NSRect(x: pixelWidth / 4, y: pixelHeight / 4, width: pixelWidth / 2, height: pixelHeight / 2)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "InlineImageTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try data.write(to: url, options: .atomic)
    return data
}

@MainActor
private func attachmentStripAndChips(in editor: CaptureEditor) throws -> (strip: NSScrollView, chips: NSStackView) {
    guard let strip = editor.subviews.compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView is NSStackView }),
          let chips = strip.documentView as? NSStackView else {
        throw NSError(domain: "InlineImageTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing attachment strip stack view"])
    }
    return (strip, chips)
}

@MainActor
private func verifyMidDocumentAttachUndoAndChipFiltering() throws {
    let savedVim = Theme.vimModeEnabled
    defer { Theme.vimModeEnabled = savedVim }
    Theme.vimModeEnabled = false

    let (workspace, vault, window, directory) = try makeInlineImageTestWorkspace()
    defer {
        workspace.shutdown()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    let initialMarkdown = "# Design Review\n\nIntro paragraph.\n\nConclusion paragraph."
    let record = try vault.capture(text: initialMarkdown)
    workspace.openNote(record.url)
    window.contentView?.layoutSubtreeIfNeeded()

    let editor = workspace.editor
    let textView = editor.textView
    guard window.makeFirstResponder(textView) else {
        throw NSError(domain: "InlineImageTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not focus editor"])
    }

    let sourceDir = directory.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let pngURL = sourceDir.appendingPathComponent("architecture-diagram.png")
    _ = try writeSyntheticPNG(to: pngURL, pixelWidth: 800, pixelHeight: 400)

    let nsInitial = editor.nsText
    let conclusionRange = nsInitial.range(of: "Conclusion paragraph.")
    guard conclusionRange.location != NSNotFound else {
        throw NSError(domain: "InlineImageTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "Missing Conclusion paragraph"])
    }
    // Blank line right before "Conclusion paragraph."
    let midInsertionRange = NSRange(location: conclusionRange.location - 1, length: 0)

    editor.addAttachments([pngURL], at: midInsertionRange, animated: false)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let updatedText = editor.text
    let nsUpdated = updatedText as NSString
    let introLoc = nsUpdated.range(of: "Intro paragraph.").location
    let imageLoc = nsUpdated.range(of: "![architecture-diagram.png](../Attachments/").location
    let afterConclusionLoc = nsUpdated.range(of: "Conclusion paragraph.").location
    guard introLoc != NSNotFound, imageLoc != NSNotFound, afterConclusionLoc != NSNotFound,
          introLoc < imageLoc, imageLoc < afterConclusionLoc else {
        throw NSError(
            domain: "InlineImageTests",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: "Expected inline image between Intro and Conclusion, got:\n\(updatedText)"]
        )
    }

    guard textView.inlineImageItems.count == 1, let item = textView.inlineImageItems.first else {
        throw NSError(domain: "InlineImageTests", code: 13, userInfo: [NSLocalizedDescriptionKey: "Expected 1 inlineImageItem, got \(textView.inlineImageItems.count)"])
    }
    guard item.isReadableImage, item.isStandaloneLine, item.caption == nil else {
        throw NSError(domain: "InlineImageTests", code: 14, userInfo: [NSLocalizedDescriptionKey: "Unexpected inline image item metadata: \(item)"])
    }
    guard let cardRect = textView.inlineImageCardRect(for: item), cardRect.width > 120, cardRect.height > 60 else {
        throw NSError(domain: "InlineImageTests", code: 15, userInfo: [NSLocalizedDescriptionKey: "Missing or tiny inlineImageCardRect"])
    }

    // Verify TextKit 1 paragraphSpacing pushes "Conclusion paragraph." strictly below cardRect.maxY
    guard let lm = textView.layoutManager, let tc = textView.textContainer else {
        throw NSError(domain: "InlineImageTests", code: 16, userInfo: [NSLocalizedDescriptionKey: "Missing layoutManager/textContainer"])
    }
    let conclusionGlyphs = lm.glyphRange(forCharacterRange: NSRange(location: afterConclusionLoc, length: 10), actualCharacterRange: nil)
    let conclusionRectInView = lm.boundingRect(forGlyphRange: conclusionGlyphs, in: tc)
        .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    guard conclusionRectInView.minY >= cardRect.maxY - 1.0 else {
        throw NSError(
            domain: "InlineImageTests",
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: "Conclusion paragraph overlapped inline image card: conclusionMinY=\(conclusionRectInView.minY) cardMaxY=\(cardRect.maxY)"]
        )
    }

    // Verify rendered pixels inside cardRect actually draw the orange illustration center (not blank paper)
    if let bitmap = textView.bitmapImageRepForCachingDisplay(in: cardRect) {
        textView.cacheDisplay(in: cardRect, to: bitmap)
        let centerColor = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        guard let c = centerColor, c.redComponent > 0.70, c.blueComponent < 0.50 else {
            throw NSError(
                domain: "InlineImageTests",
                code: 171,
                userInfo: [NSLocalizedDescriptionKey: "Expected rendered illustration pixels at card center, got \(String(describing: centerColor))"]
            )
        }
    }

    // Verify dropInsertionRange(atViewPoint:) resolves above/below the inline image card
    let dropTop = textView.dropInsertionRange(atViewPoint: NSPoint(x: cardRect.midX, y: cardRect.minY + 4))
    let dropBottom = textView.dropInsertionRange(atViewPoint: NSPoint(x: cardRect.midX, y: cardRect.maxY - 4))
    guard dropTop.location == item.lineRange.location, dropBottom.location == NSMaxRange(item.fullLineRange) else {
        throw NSError(
            domain: "InlineImageTests",
            code: 172,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected dropInsertionRange on card: top=\(dropTop) bottom=\(dropBottom) item=\(item)"]
        )
    }

    // Verify linkedAttachments preserves the attachment for vault lifecycle while top chip strip hides inline images
    let (strip, chips) = try attachmentStripAndChips(in: editor)
    guard editor.linkedAttachments.count == 1, editor.linkedAttachments[0].isImage else {
        throw NSError(domain: "InlineImageTests", code: 18, userInfo: [NSLocalizedDescriptionKey: "Expected 1 image linkedAttachment, got \(editor.linkedAttachments)"])
    }
    guard strip.isHidden, chips.arrangedSubviews.isEmpty else {
        throw NSError(domain: "InlineImageTests", code: 19, userInfo: [NSLocalizedDescriptionKey: "Expected top attachment strip hidden for inline-only image, chips=\(chips.arrangedSubviews.count)"])
    }

    // Verify Undo & Redo round-trip
    textView.undoManager?.undo()
    window.contentView?.layoutSubtreeIfNeeded()
    guard editor.text == initialMarkdown, textView.inlineImageItems.isEmpty else {
        throw NSError(domain: "InlineImageTests", code: 20, userInfo: [NSLocalizedDescriptionKey: "Undo failed to restore initial markdown; got:\n\(editor.text)"])
    }

    textView.undoManager?.redo()
    window.contentView?.layoutSubtreeIfNeeded()
    guard editor.text == updatedText, textView.inlineImageItems.count == 1 else {
        throw NSError(domain: "InlineImageTests", code: 21, userInfo: [NSLocalizedDescriptionKey: "Redo failed to restore inline image; got:\n\(editor.text)"])
    }

    // Attach a non-image .txt file alongside the inline image: .txt gets a top chip, image stays inline-only
    let txtURL = sourceDir.appendingPathComponent("spec.txt")
    try "Reference specification".write(to: txtURL, atomically: true, encoding: .utf8)
    editor.addAttachments([txtURL], at: NSRange(location: editor.nsText.length, length: 0), animated: false)
    window.contentView?.layoutSubtreeIfNeeded()

    guard editor.linkedAttachments.count == 2 else {
        throw NSError(domain: "InlineImageTests", code: 22, userInfo: [NSLocalizedDescriptionKey: "Expected 2 linkedAttachments, got \(editor.linkedAttachments.count)"])
    }
    guard !strip.isHidden, chips.arrangedSubviews.count == 1 else {
        throw NSError(domain: "InlineImageTests", code: 23, userInfo: [NSLocalizedDescriptionKey: "Expected 1 chip for spec.txt only, got hidden=\(strip.isHidden) count=\(chips.arrangedSubviews.count)"])
    }
}

@MainActor
private func verifyUnsavedDraftPasteScreenshotInsertsInlineAtCaret() throws {
    let savedVim = Theme.vimModeEnabled
    defer { Theme.vimModeEnabled = savedVim }
    Theme.vimModeEnabled = false

    let (workspace, _, window, directory) = try makeInlineImageTestWorkspace()
    defer {
        workspace.shutdown()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    workspace.newCapture()
    let editor = workspace.editor
    let textView = editor.textView
    let isolatedPB = NSPasteboard(name: NSPasteboard.Name("CozyInlinePaste-\(UUID().uuidString)"))
    editor.pasteboard = isolatedPB
    defer { isolatedPB.releaseGlobally() }

    let draft = "# Unsaved Draft\n\nBefore screenshot.\n\nAfter screenshot."
    editor.text = draft
    window.contentView?.layoutSubtreeIfNeeded()
    guard workspace.noteURL == nil else {
        throw NSError(domain: "InlineImageTests", code: 30, userInfo: [NSLocalizedDescriptionKey: "Expected unsaved draft before paste"])
    }

    let pngTemp = directory.appendingPathComponent("clip.png")
    let pngData = try writeSyntheticPNG(to: pngTemp, pixelWidth: 640, pixelHeight: 360)
    isolatedPB.clearContents()
    isolatedPB.setData(pngData, forType: .png)

    let afterLoc = (draft as NSString).range(of: "After screenshot.").location
    textView.setSelectedRange(NSRange(location: afterLoc - 1, length: 0))
    textView.paste(nil)
    window.contentView?.layoutSubtreeIfNeeded()

    guard workspace.noteURL != nil else {
        throw NSError(domain: "InlineImageTests", code: 31, userInfo: [NSLocalizedDescriptionKey: "Expected unsaved draft to persist upon screenshot paste"])
    }
    let nsResult = editor.nsText
    let beforeIdx = nsResult.range(of: "Before screenshot.").location
    let shotIdx = nsResult.range(of: "![Screenshot-").location
    let afterIdx = nsResult.range(of: "After screenshot.").location
    guard beforeIdx != NSNotFound, shotIdx != NSNotFound, afterIdx != NSNotFound,
          beforeIdx < shotIdx, shotIdx < afterIdx else {
        throw NSError(domain: "InlineImageTests", code: 32, userInfo: [NSLocalizedDescriptionKey: "Expected pasted screenshot inline at caret, got:\n\(editor.text)"])
    }
    guard textView.inlineImageItems.count == 1,
          let item = textView.inlineImageItems.first,
          item.isReadableImage,
          textView.inlineImageCardRect(for: item) != nil else {
        throw NSError(domain: "InlineImageTests", code: 33, userInfo: [NSLocalizedDescriptionKey: "Expected rendered inline screenshot item after draft capture"])
    }
}

@MainActor
private func verifyGeometryFoldingResizeContextMenuAndCompanionWindow() throws {
    let savedVim = Theme.vimModeEnabled
    defer { Theme.vimModeEnabled = savedVim }
    Theme.vimModeEnabled = false

    let (workspace, vault, window, directory) = try makeInlineImageTestWorkspace()
    defer {
        workspace.shutdown()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    let sourceDir = directory.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let heroURL = sourceDir.appendingPathComponent("hero-chart.png")
    _ = try writeSyntheticPNG(to: heroURL, pixelWidth: 900, pixelHeight: 450)

    let record = try vault.capture(text: "# Architecture\n\nBody text.")
    let copied = try vault.copyAttachments([heroURL], for: record.url)
    guard let copiedHero = copied.first else {
        throw NSError(domain: "InlineImageTests", code: 40, userInfo: [NSLocalizedDescriptionKey: "Failed to copy hero-chart.png"])
    }
    // Extract relative path inside parentheses from `![hero-chart](Attachments/.../hero-chart.png)`
    guard let openParen = copiedHero.markdown.firstIndex(of: "("),
          let closeParen = copiedHero.markdown.lastIndex(of: ")") else {
        throw NSError(domain: "InlineImageTests", code: 41, userInfo: [NSLocalizedDescriptionKey: "Malformed markdown snippet: \(copiedHero.markdown)"])
    }
    let relPath = String(copiedHero.markdown[copiedHero.markdown.index(after: openParen)..<closeParen])

    let noteBody = """
    # Architecture

    ![System overview caption](\(relPath))

    Plain file link: [hero-chart.png](\(relPath))

    ```markdown
    ![Ignored inside code fence](\(relPath))
    ```

    Closing paragraph.
    """
    try vault.save(noteBody, to: record.url, expectedContent: try vault.read(record.url))

    workspace.openNote(record.url)
    window.setContentSize(NSSize(width: 960, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let editor = workspace.editor
    let textView = editor.textView
    guard window.makeFirstResponder(textView) else {
        throw NSError(domain: "InlineImageTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "Failed to focus textView"])
    }

    // Only the real Markdown image outside code fences and with leading `!` becomes an InlineImageItem
    guard textView.inlineImageItems.count == 1, let wideItem = textView.inlineImageItems.first else {
        throw NSError(domain: "InlineImageTests", code: 43, userInfo: [NSLocalizedDescriptionKey: "Expected exactly 1 inlineImageItem (excluding plain link & fenced block), got \(textView.inlineImageItems.count)"])
    }
    guard wideItem.caption == "System overview caption" else {
        throw NSError(domain: "InlineImageTests", code: 44, userInfo: [NSLocalizedDescriptionKey: "Expected custom alt caption, got \(String(describing: wideItem.caption))"])
    }

    // Plain link `[hero-chart.png](...)` has isImage == false, so it appears in the chip strip while `![...]` items do not
    let (_, chips) = try attachmentStripAndChips(in: editor)
    guard editor.linkedAttachments.count == 3,
          editor.linkedAttachments.filter({ !$0.isImage }).count == 1,
          chips.arrangedSubviews.count == 1 else {
        throw NSError(domain: "InlineImageTests", code: 45, userInfo: [NSLocalizedDescriptionKey: "Expected 3 linkedAttachments (2 ![] + 1 plain link) and 1 chip, got linked=\(editor.linkedAttachments.count) chips=\(chips.arrangedSubviews.count)"])
    }

    // Place caret away from the image line -> raw syntax hidden (clear foreground + reserved paragraphSpacing)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    window.contentView?.layoutSubtreeIfNeeded()
    let hiddenColor = textView.textStorage?.attribute(.foregroundColor, at: wideItem.lineRange.location, effectiveRange: nil) as? NSColor
    let hiddenPara = textView.textStorage?.attribute(.paragraphStyle, at: wideItem.lineRange.location, effectiveRange: nil) as? NSParagraphStyle
    guard hiddenColor == .clear, (hiddenPara?.paragraphSpacing ?? 0) >= wideItem.displaySize.height else {
        throw NSError(domain: "InlineImageTests", code: 46, userInfo: [NSLocalizedDescriptionKey: "Expected hidden clear syntax + paragraphSpacing when caret is off standalone image line, got color=\(String(describing: hiddenColor)) spacing=\(String(describing: hiddenPara?.paragraphSpacing))"])
    }

    // Move caret onto the image line -> raw syntax revealed & caret height stays single-line (<= 30pt)
    textView.setSelectedRange(NSRange(location: wideItem.lineRange.location + 2, length: 0))
    window.contentView?.layoutSubtreeIfNeeded()
    let caretRect = textView.currentCaretRect()
    guard caretRect.height > 10, caretRect.height <= 30 else {
        throw NSError(domain: "InlineImageTests", code: 47, userInfo: [NSLocalizedDescriptionKey: "Expected single-line caret height on inline image line, got \(caretRect)"])
    }
    let revealedColor = textView.textStorage?.attribute(.foregroundColor, at: wideItem.lineRange.location + 2, effectiveRange: nil) as? NSColor
    guard revealedColor != .clear else {
        throw NSError(domain: "InlineImageTests", code: 48, userInfo: [NSLocalizedDescriptionKey: "Expected raw image syntax to be visible when caret is on the image line"])
    }

    // Move caret back to `# Architecture` and fold the heading -> inline image card collapses with section
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    textView.foldHeadingAtCursor(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    if let foldedItem = textView.inlineImageItems.first {
        guard textView.inlineImageCardRect(for: foldedItem) == nil else {
            throw NSError(domain: "InlineImageTests", code: 49, userInfo: [NSLocalizedDescriptionKey: "Expected inlineImageCardRect == nil while parent heading is folded"])
        }
    }
    textView.unfoldHeadingAtCursor(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    guard let unfoldedItem = textView.inlineImageItems.first,
          let wideCardRect = textView.inlineImageCardRect(for: unfoldedItem) else {
        throw NSError(domain: "InlineImageTests", code: 50, userInfo: [NSLocalizedDescriptionKey: "Expected inlineImageCardRect restored after unfolding heading"])
    }

    // Responsive width downscaling: narrow window from 960pt -> 420pt and verify 2:1 aspect ratio preserved
    window.setContentSize(NSSize(width: 420, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()
    guard let narrowItem = textView.inlineImageItems.first else {
        throw NSError(domain: "InlineImageTests", code: 51, userInfo: [NSLocalizedDescriptionKey: "Missing inlineImageItem after narrowing window"])
    }
    let aspect = narrowItem.displaySize.width / max(1, narrowItem.displaySize.height)
    guard narrowItem.displaySize.width < wideCardRect.width, abs(aspect - 2.0) < 0.06 else {
        throw NSError(
            domain: "InlineImageTests",
            code: 52,
            userInfo: [NSLocalizedDescriptionKey: "Expected narrower responsive width with 2:1 aspect ratio; wide=\(wideCardRect.width) narrow=\(narrowItem.displaySize)"]
        )
    }

    // Companion NoteWindowController renders inline images identically
    guard let companion = workspace.openNoteInNewWindow(record.url) else {
        throw NSError(domain: "InlineImageTests", code: 53, userInfo: [NSLocalizedDescriptionKey: "Failed to open companion NoteWindowController"])
    }
    defer { companion.close() }
    companion.window?.contentView?.layoutSubtreeIfNeeded()
    guard companion.editor.textView.inlineImageItems.count == 1,
          companion.editor.textView.inlineImageItems[0].isReadableImage else {
        throw NSError(domain: "InlineImageTests", code: 54, userInfo: [NSLocalizedDescriptionKey: "Expected companion NoteWindowController to resolve and render inline image"])
    }

    // Context menu over inline image card exposes Remove Image and undoably deletes the image line
    window.setContentSize(NSSize(width: 960, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()
    guard let targetItem = textView.inlineImageItems.first,
          let targetCard = textView.inlineImageCardRect(for: targetItem) else {
        throw NSError(domain: "InlineImageTests", code: 55, userInfo: [NSLocalizedDescriptionKey: "Missing target inline image card for context menu"])
    }
    let clickInView = NSPoint(x: targetCard.midX, y: targetCard.midY)
    let clickInWindow = textView.convert(clickInView, to: nil)
    guard let rightClick = NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: clickInWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1.0
    ), let menu = textView.menu(for: rightClick) else {
        throw NSError(domain: "InlineImageTests", code: 56, userInfo: [NSLocalizedDescriptionKey: "Expected context menu on right-clicking inline image card"])
    }
    let titles = menu.items.map(\.title)
    guard titles.contains("Open Image"), titles.contains("Reveal in Finder"),
          titles.contains("Copy Image"), titles.contains("Remove Image"),
          let removeItem = menu.items.first(where: { $0.title == "Remove Image" }),
          let action = removeItem.action else {
        throw NSError(domain: "InlineImageTests", code: 57, userInfo: [NSLocalizedDescriptionKey: "Missing expected inline image menu items; got \(titles)"])
    }
    _ = NSApp.sendAction(action, to: removeItem.target, from: removeItem)
    window.contentView?.layoutSubtreeIfNeeded()
    guard textView.inlineImageItems.isEmpty, !editor.text.contains("![System overview caption]") else {
        throw NSError(domain: "InlineImageTests", code: 58, userInfo: [NSLocalizedDescriptionKey: "Remove Image menu item did not remove inline image line"])
    }
    textView.undoManager?.undo()
    window.contentView?.layoutSubtreeIfNeeded()
    guard textView.inlineImageItems.count == 1 else {
        throw NSError(domain: "InlineImageTests", code: 59, userInfo: [NSLocalizedDescriptionKey: "Undo after Remove Image did not restore inline image"])
    }
}

#if canImport(XCTest)
@MainActor
final class InlineImageXCTests: XCTestCase {
    func testMidDocumentAttachUndoAndChipFiltering() throws {
        try verifyMidDocumentAttachUndoAndChipFiltering()
    }

    func testUnsavedDraftPasteScreenshotInsertsInlineAtCaret() throws {
        try verifyUnsavedDraftPasteScreenshotInsertsInlineAtCaret()
    }

    func testGeometryFoldingResizeContextMenuAndCompanionWindow() throws {
        try verifyGeometryFoldingResizeContextMenuAndCompanionWindow()
    }
}
#endif

#if canImport(Testing)
@Suite("Inline Images", .serialized)
@MainActor
struct InlineImageSwiftTests {
    @Test("Dropping or attaching an image inserts inline Markdown at the target position with undo/redo and no duplicate top chip")
    func midDocumentAttachUndoAndChipFiltering() throws {
        try verifyMidDocumentAttachUndoAndChipFiltering()
    }

    @Test("Pasting a screenshot into an unsaved draft captures and renders inline at the caret")
    func unsavedDraftPasteScreenshotInsertsInlineAtCaret() throws {
        try verifyUnsavedDraftPasteScreenshotInsertsInlineAtCaret()
    }

    @Test("Inline image geometry, caret height, syntax reveal, folding, responsive resize, context menu, and companion window")
    func geometryFoldingResizeContextMenuAndCompanionWindow() throws {
        try verifyGeometryFoldingResizeContextMenuAndCompanionWindow()
    }
}
#endif
