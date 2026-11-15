#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
@testable import CozyNotes

@MainActor
private func makeKeyWindow(contentView: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    contentView.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    contentView.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func sendCommandArrow(to window: NSWindow, keyCode: UInt16, characters: String) {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else { return }
    window.sendEvent(event)
}

/// Focuses a single-line search field, then exercises ⌘↓ and ⌘↑ through the real
/// field-editor key route. AppKit reports `moveToEndOfDocument:`/`moveToBeginningOfDocument:`
/// for these keys, which are no-ops inside a field editor unless the delegate routes them to the line ends.
@MainActor
private func fieldNavigationRanges(field: NSSearchField, in window: NSWindow) -> (down: NSRange, up: NSRange)? {
    field.stringValue = "hello world"
    guard window.makeFirstResponder(field), let editor = window.firstResponder as? NSTextView else { return nil }
    let length = (editor.string as NSString).length

    editor.setSelectedRange(NSRange(location: 2, length: 0))
    sendCommandArrow(to: window, keyCode: 125, characters: "\u{F701}")
    let down = editor.selectedRange()

    editor.setSelectedRange(NSRange(location: min(7, length), length: 0))
    sendCommandArrow(to: window, keyCode: 126, characters: "\u{F700}")
    let up = editor.selectedRange()
    return (down, up)
}

#if canImport(XCTest)
@MainActor
final class CommandDownNavigationTests: XCTestCase {
    func testCommandDownMovesQuickSwitcherQueryToLineEnd() throws {
        _ = NSApplication.shared
        let overlay = QuickSwitcherOverlay(frame: .zero)
        let window = makeKeyWindow(contentView: overlay)
        defer { window.orderOut(nil) }
        let ranges = try XCTUnwrap(fieldNavigationRanges(field: overlay.searchField, in: window))
        XCTAssertEqual(ranges.down, NSRange(location: 11, length: 0))
        XCTAssertEqual(ranges.up, NSRange(location: 0, length: 0))
    }

    func testCommandDownMovesFindInNoteQueryToLineEnd() throws {
        _ = NSApplication.shared
        let bar = InNoteFindBar(frame: .zero)
        let window = makeKeyWindow(contentView: bar)
        defer { window.orderOut(nil) }
        let ranges = try XCTUnwrap(fieldNavigationRanges(field: bar.searchBar.field, in: window))
        XCTAssertEqual(ranges.down, NSRange(location: 11, length: 0))
        XCTAssertEqual(ranges.up, NSRange(location: 0, length: 0))
    }

    func testCommandDownStillMovesNoteEditorToDocumentEnd() throws {
        _ = NSApplication.shared
        let editor = CaptureEditor(frame: .zero)
        let window = makeKeyWindow(contentView: editor)
        defer { window.orderOut(nil) }
        editor.text = "first line\nsecond line\nthird line"
        window.contentView?.layoutSubtreeIfNeeded()
        let textView = editor.textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        sendCommandArrow(to: window, keyCode: 125, characters: "\u{F701}")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: editor.nsText.length, length: 0))
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Command-arrow navigation", .serialized)
    struct CommandDownNavigationSuite {
        @Test("Command+Down moves the Quick Switcher query to the line end and Command+Up returns to the start")
        @MainActor
        func quickSwitcherFieldNavigation() throws {
            _ = NSApplication.shared
            let overlay = QuickSwitcherOverlay(frame: .zero)
            let window = makeKeyWindow(contentView: overlay)
            defer { window.orderOut(nil) }
            let ranges = try #require(fieldNavigationRanges(field: overlay.searchField, in: window))
            #expect(ranges.down == NSRange(location: 11, length: 0))
            #expect(ranges.up == NSRange(location: 0, length: 0))
        }

        @Test("Command+Down moves the Find in Note query to the line end and Command+Up returns to the start")
        @MainActor
        func findInNoteFieldNavigation() throws {
            _ = NSApplication.shared
            let bar = InNoteFindBar(frame: .zero)
            let window = makeKeyWindow(contentView: bar)
            defer { window.orderOut(nil) }
            let ranges = try #require(fieldNavigationRanges(field: bar.searchBar.field, in: window))
            #expect(ranges.down == NSRange(location: 11, length: 0))
            #expect(ranges.up == NSRange(location: 0, length: 0))
        }

        @Test("Command+Down still moves the note editor to the end of the document")
        @MainActor
        func noteEditorDocumentEnd() throws {
            _ = NSApplication.shared
            let editor = CaptureEditor(frame: .zero)
            let window = makeKeyWindow(contentView: editor)
            defer { window.orderOut(nil) }
            editor.text = "first line\nsecond line\nthird line"
            window.contentView?.layoutSubtreeIfNeeded()
            let textView = editor.textView
            #expect(window.makeFirstResponder(textView))
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            sendCommandArrow(to: window, keyCode: 125, characters: "\u{F701}")
            #expect(textView.selectedRange() == NSRange(location: editor.nsText.length, length: 0))
        }
    }
}
#endif
