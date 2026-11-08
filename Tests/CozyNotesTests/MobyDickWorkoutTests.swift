#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
@testable import CozyCore
@testable import CozySearch
@testable import CozyNotes

#if canImport(XCTest)
@MainActor
final class MobyDickWorkoutTests: XCTestCase {
    func testMobyDickWorkout() throws {
        _ = NSApplication.shared
        let cycles = ProcessInfo.processInfo.environment["MOBY_DICK_CYCLES"].flatMap(Int.init) ?? 2
        let sample = ProcessInfo.processInfo.environment["MOBY_DICK_SAMPLE"] ?? "Whale"
        let report = try MobyDickWorkout.run(repeatCycles: cycles, typingSample: sample)
        print(report.formattedSummary())

        XCTAssertGreaterThan(report.step1.charLength, 1_000_000, "Moby Dick should contain >1M characters")
        XCTAssertTrue(report.step1.wordCountLabel.contains("WORDS"), "Word count footer should populate")
        XCTAssertGreaterThan(report.step2.scrollOriginY, 100_000, "Step 2 should scroll to the end of Moby Dick")
        XCTAssertEqual(report.step2.resizeStepMs.count, 4, "Step 2 should measure all 4 window resize steps")
        XCTAssertGreaterThan(report.step3.scrollOriginY, 50_000, "Step 3 should scroll to the middle of Moby Dick")
        XCTAssertEqual(report.step3.resizeStepMs.count, 4, "Step 3 should measure all 4 window resize steps")
        XCTAssertTrue(report.step4.intactAfterRedo, "Step 4 Select All / Cut / Paste / Undo / Redo must leave Moby Dick intact")
        XCTAssertEqual(report.step5.keystrokeCount, sample.count, "Step 5 should measure each keystroke")
        XCTAssertLessThan(report.step1.cpu.cpuTimeMs, 150.0, "Step 1 CPU time should be < 150ms")
        XCTAssertLessThan(report.step2.resizeAvgMs, 16.0, "Step 2 average resize time should be < 16ms")
        XCTAssertLessThan(report.step3.resizeAvgMs, 16.0, "Step 3 average resize time should be < 16ms")
        XCTAssertLessThan(report.step5.p95KeystrokeMs, 8.0, "Step 5 P95 keystroke latency should be < 8.0ms")
        XCTAssertEqual(report.repeats.count, max(0, cycles), "Step 6 should complete repeated workout cycles")
        for cycle in report.repeats {
            XCTAssertTrue(cycle.step4.intactAfterRedo, "Cycle #\(cycle.cycleIndex) must leave Moby Dick intact")
            XCTAssertLessThan(cycle.step2.resizeAvgMs, 16.0)
            XCTAssertLessThan(cycle.step3.resizeAvgMs, 16.0)
            XCTAssertLessThan(cycle.step5.p95KeystrokeMs, 8.0)
        }
        if !report.repeats.isEmpty {
            let growthPerCycle = (report.memoryFinal.physFootprintMB - report.memoryAfterFirstPass.physFootprintMB) / Double(report.repeats.count)
            XCTAssertLessThan(growthPerCycle, 5.0, "Memory growth per cycle should be < 5 MB/cycle")
        }
    }
}
#endif

#if canImport(Testing)
@Suite("Moby Dick Workout")
struct MobyDickWorkoutSuite {
    @Test("Full Moby Dick Workout (Steps 1–6)")
    @MainActor
    func mobyDickWorkout() throws {
        _ = NSApplication.shared
        let cycles = ProcessInfo.processInfo.environment["MOBY_DICK_CYCLES"].flatMap(Int.init) ?? 2
        let sample = ProcessInfo.processInfo.environment["MOBY_DICK_SAMPLE"] ?? "Whale"
        let report = try MobyDickWorkout.run(repeatCycles: cycles, typingSample: sample)
        print(report.formattedSummary())
        #expect(report.step1.charLength > 1_000_000)
        #expect(report.step1.wordCountLabel.contains("WORDS"))
        #expect(report.step2.scrollOriginY > 100_000)
        #expect(report.step2.resizeStepMs.count == 4)
        #expect(report.step3.scrollOriginY > 50_000)
        #expect(report.step3.resizeStepMs.count == 4)
        #expect(report.step4.intactAfterRedo)
        #expect(report.step5.keystrokeCount == sample.count)
        #expect(report.step1.cpu.cpuTimeMs < 150.0)
        #expect(report.step2.resizeAvgMs < 16.0)
        #expect(report.step3.resizeAvgMs < 16.0)
        #expect(report.step5.p95KeystrokeMs < 8.0)
        #expect(report.repeats.count == max(0, cycles))
        for cycle in report.repeats {
            #expect(cycle.step4.intactAfterRedo)
            #expect(cycle.step2.resizeAvgMs < 16.0)
            #expect(cycle.step3.resizeAvgMs < 16.0)
            #expect(cycle.step5.p95KeystrokeMs < 8.0)
        }
        if !report.repeats.isEmpty {
            let growthPerCycle = (report.memoryFinal.physFootprintMB - report.memoryAfterFirstPass.physFootprintMB) / Double(report.repeats.count)
            #expect(growthPerCycle < 5.0)
        }
    }

    @Test("Markdown formatting preserves headings, quotes, lists, inline tokens, and code fences")
    @MainActor
    func markdownFormattingInvariants() throws {
        _ = NSApplication.shared
        let editor = CaptureEditor(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let sample = """
        # Heading One
        ## Heading Two
        > Blockquote callout
        - [x] Completed task
        - [ ] Open task
        1. Numbered item
        Some **bold** and *italic* and `inline` and [link](https://example.com) prose.
        ```swift
        let answer = "42"
        ```
        """
        editor.text = sample
        #expect(editor.textView.headingGutterItems.count == 2)
        #expect(editor.textView.headingGutterItems[0].label == "H1")
        #expect(editor.textView.headingGutterItems[1].label == "H2")
        #expect(editor.textView.blockquoteRanges.count == 1)
        #expect(editor.textView.inlineCodeRanges.count == 1)
        #expect(editor.textView.fencedBlocks.count == 1)
        #expect(editor.wordCount.stringValue.contains("WORDS"))
    }
}
#endif
