import AppKit
import Darwin
import CozyCore
import CozySearch

@MainActor
struct MobyDickWorkout {
    struct MemorySample {
        let physFootprintMB: Double
        let residentSizeMB: Double
    }

    struct CPUSpan {
        let wallMs: Double
        let userMs: Double
        let systemMs: Double
        var cpuTimeMs: Double { userMs + systemMs }
        var cpuPercent: Double { wallMs > 0.05 ? (cpuTimeMs / wallMs) * 100.0 : 0.0 }
    }

    struct Step1Result {
        let openMs: Double
        let cpu: CPUSpan
        let charLength: Int
        let byteLength: Int
        let wordCountLabel: String
    }

    struct ScrollResizeResult {
        let scrollMs: Double
        let resizeStepMs: [Double]
        let resizeCPU: CPUSpan
        var resizeTotalMs: Double { resizeStepMs.reduce(0, +) }
        var resizeAvgMs: Double { resizeTotalMs / Double(max(1, resizeStepMs.count)) }
        let scrollOriginY: CGFloat
    }

    struct ClipboardUndoRedoResult {
        let selectAllMs: Double
        let cutMs: Double
        let pasteMs: Double
        let undoPasteMs: Double
        let undoCutMs: Double
        let redoCutMs: Double
        let redoPasteMs: Double
        let cpu: CPUSpan
        let intactAfterRedo: Bool
        var totalMs: Double {
            selectAllMs + cutMs + pasteMs + undoPasteMs + undoCutMs + redoCutMs + redoPasteMs
        }
    }

    struct MiddleTypingResult {
        let keystrokeCount: Int
        let keystrokeTimesMs: [Double]
        let avgKeystrokeMs: Double
        let p50KeystrokeMs: Double
        let p95KeystrokeMs: Double
        let maxKeystrokeMs: Double
        let totalTypingMs: Double
        let cpu: CPUSpan
        let maxScrollJumpPt: CGFloat
    }

    struct CycleSummary {
        let cycleIndex: Int
        let totalMs: Double
        let cpu: CPUSpan
        let step2: ScrollResizeResult
        let step3: ScrollResizeResult
        let step4: ClipboardUndoRedoResult
        let step5: MiddleTypingResult
        let memoryAfter: MemorySample
    }

    struct Report {
        let step1: Step1Result
        let step2: ScrollResizeResult
        let step3: ScrollResizeResult
        let step4: ClipboardUndoRedoResult
        let step5: MiddleTypingResult
        let repeats: [CycleSummary]
        let memoryBeforeOpen: MemorySample
        let memoryAfterOpen: MemorySample
        let memoryAfterFirstPass: MemorySample
        let memoryFinal: MemorySample

        func formattedSummary() -> String {
            let cycleList = repeats.map {
                String(format: "#%d: %.1f ms (CPU %.1f ms / %.0f%%, %.1f MB)", $0.cycleIndex, $0.totalMs, $0.cpu.cpuTimeMs, $0.cpu.cpuPercent, $0.memoryAfter.physFootprintMB)
            }.joined(separator: ", ")
            return """
            ================================================================================
            MOBY DICK WORKOUT BENCHMARK (\(step1.charLength) UTF-16 chars, \(step1.byteLength) bytes)
            Word count status: \(step1.wordCountLabel)
            ================================================================================
            1. Open "Moby Dick":
               - Open + Format + Layout + Display: \(String(format: "%.2f", step1.openMs)) ms (CPU: \(String(format: "%.1f", step1.cpu.cpuTimeMs)) ms [user \(String(format: "%.1f", step1.cpu.userMs)) + sys \(String(format: "%.1f", step1.cpu.systemMs))], \(String(format: "%.1f%%", step1.cpu.cpuPercent)))
            2. Scroll to End & Resize Window (\(step2.resizeStepMs.count) sizes):
               - Scroll to end:  \(String(format: "%.2f", step2.scrollMs)) ms (originY: \(String(format: "%.0f", step2.scrollOriginY)) pt)
               - Resize total:   \(String(format: "%.2f", step2.resizeTotalMs)) ms (avg \(String(format: "%.2f", step2.resizeAvgMs)) ms/resize, CPU: \(String(format: "%.1f", step2.resizeCPU.cpuTimeMs)) ms, \(String(format: "%.1f%%", step2.resizeCPU.cpuPercent)))
            3. Scroll to Middle & Resize Window (\(step3.resizeStepMs.count) sizes):
               - Scroll to mid:  \(String(format: "%.2f", step3.scrollMs)) ms (originY: \(String(format: "%.0f", step3.scrollOriginY)) pt)
               - Resize total:   \(String(format: "%.2f", step3.resizeTotalMs)) ms (avg \(String(format: "%.2f", step3.resizeAvgMs)) ms/resize, CPU: \(String(format: "%.1f", step3.resizeCPU.cpuTimeMs)) ms, \(String(format: "%.1f%%", step3.resizeCPU.cpuPercent)))
            4. Select All, Cut, Paste, Undo, Redo:
               - Select All:     \(String(format: "%.2f", step4.selectAllMs)) ms
               - Cut:            \(String(format: "%.2f", step4.cutMs)) ms
               - Paste:          \(String(format: "%.2f", step4.pasteMs)) ms
               - Undo (paste):   \(String(format: "%.2f", step4.undoPasteMs)) ms
               - Undo (cut):     \(String(format: "%.2f", step4.undoCutMs)) ms
               - Redo (cut):     \(String(format: "%.2f", step4.redoCutMs)) ms
               - Redo (paste):   \(String(format: "%.2f", step4.redoPasteMs)) ms
               - Total:          \(String(format: "%.2f", step4.totalMs)) ms (CPU: \(String(format: "%.1f", step4.cpu.cpuTimeMs)) ms, \(String(format: "%.1f%%", step4.cpu.cpuPercent)), standing & intact: \(step4.intactAfterRedo))
            5. Edit Content Near Middle (\(step5.keystrokeCount) keystrokes):
               - Avg keystroke:  \(String(format: "%.2f", step5.avgKeystrokeMs)) ms
               - P50 keystroke:  \(String(format: "%.2f", step5.p50KeystrokeMs)) ms
               - P95 keystroke:  \(String(format: "%.2f", step5.p95KeystrokeMs)) ms
               - Max keystroke:  \(String(format: "%.2f", step5.maxKeystrokeMs)) ms
               - Total typing:   \(String(format: "%.2f", step5.totalTypingMs)) ms (CPU: \(String(format: "%.1f", step5.cpu.cpuTimeMs)) ms, \(String(format: "%.1f%%", step5.cpu.cpuPercent)))
               - Max scroll jump: \(String(format: "%.2f", step5.maxScrollJumpPt)) pt
            6. Repeat Steps 2-5 (\(repeats.count) cycles) & Activity Monitor Memory:
               - Repeat cycles:  \(cycleList)
               - Memory before open:    \(String(format: "%.1f", memoryBeforeOpen.physFootprintMB)) MB phys_footprint (\(String(format: "%.1f", memoryBeforeOpen.residentSizeMB)) MB RSS)
               - Memory after open:     \(String(format: "%.1f", memoryAfterOpen.physFootprintMB)) MB phys_footprint (\(String(format: "%.1f", memoryAfterOpen.residentSizeMB)) MB RSS)
               - Memory after pass 1:   \(String(format: "%.1f", memoryAfterFirstPass.physFootprintMB)) MB phys_footprint (\(String(format: "%.1f", memoryAfterFirstPass.residentSizeMB)) MB RSS)
               - Memory final:          \(String(format: "%.1f", memoryFinal.physFootprintMB)) MB phys_footprint (\(String(format: "%.1f", memoryFinal.residentSizeMB)) MB RSS)
            ================================================================================
            """
        }
    }

    static func sampleMemory() -> MemorySample {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmKr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        let footprint = vmKr == KERN_SUCCESS ? Double(vmInfo.phys_footprint) / (1024.0 * 1024.0) : 0

        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicKr = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        let resident = basicKr == KERN_SUCCESS ? Double(basicInfo.resident_size) / (1024.0 * 1024.0) : 0
        return MemorySample(physFootprintMB: footprint, residentSizeMB: resident)
    }

    static func loadMobyDickMarkdown() throws -> String {
        let candidateRoots: [URL] = [
            ProcessInfo.processInfo.environment["COZY_VAULT"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            UserDefaults.standard.string(forKey: "vaultPath").map { URL(fileURLWithPath: $0, isDirectory: true) },
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Cozy Notes", isDirectory: true)
        ].compactMap { $0 }

        for root in candidateRoots {
            if let vault = try? Vault(root: root),
               let notes = try? vault.notes(),
               let moby = notes.first(where: { $0.title.localizedCaseInsensitiveContains("Moby Dick") }) {
                return try vault.read(moby.url)
            }
        }

        var chapters: [String] = ["# MOBY DICK; OR THE WHALE\n\nby Herman Melville\n"]
        let paragraph = "Call me Ishmael. Some years ago--never mind how long precisely--having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world. "
        for ch in 1...135 {
            chapters.append("## CHAPTER \(ch)\n\nLoomings.\n\n" + String(repeating: paragraph, count: 35) + "\n")
        }
        return chapters.joined(separator: "\n")
    }
    private static func cpuTimesMs() -> (userMs: Double, systemMs: Double) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
        let user = Double(usage.ru_utime.tv_sec) * 1000.0 + Double(usage.ru_utime.tv_usec) / 1000.0
        let sys = Double(usage.ru_stime.tv_sec) * 1000.0 + Double(usage.ru_stime.tv_usec) / 1000.0
        return (user, sys)
    }

    private static func measureSpan(_ block: () -> Void) -> CPUSpan {
        let cpuBefore = cpuTimesMs()
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let wallMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let cpuAfter = cpuTimesMs()
        return CPUSpan(
            wallMs: wallMs,
            userMs: max(0, cpuAfter.userMs - cpuBefore.userMs),
            systemMs: max(0, cpuAfter.systemMs - cpuBefore.systemMs)
        )
    }

    private static func measureMs(_ block: () -> Void) -> Double {
        measureSpan(block).wallMs
    }

    static func run(repeatCycles: Int = 1, typingSample: String = "Whale") throws -> Report {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyNotes-MobyDickWorkout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let vaultRoot = workspaceRoot.appendingPathComponent("Vault", isDirectory: true)
        let historyRoot = workspaceRoot.appendingPathComponent("History", isDirectory: true)
        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)

        let mobyText = try loadMobyDickMarkdown()
        let mobyRecord = try vault.capture(text: mobyText)
        let savedMobyText = try vault.read(mobyRecord.url)
        let expectedLength = (savedMobyText as NSString).length

        let savedClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            if let savedClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedClipboard, forType: .string)
            }
        }

        let memBeforeOpen = sampleMemory()

        let controller = WorkspaceController(vault: vault)
        defer {
            controller.shutdown()
            controller.window?.orderOut(nil)
        }
        guard let window = controller.window else {
            throw NSError(domain: "MobyDickWorkout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing workspace window"])
        }
        window.setContentSize(NSSize(width: 1060, height: 740))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let textView = controller.editor.textView
        guard let scrollView = textView.enclosingScrollView else {
            throw NSError(domain: "MobyDickWorkout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing editor scrollView"])
        }
        let clipView = scrollView.contentView

        fputs("[Workout] Starting Step 1: Open Moby Dick (\(expectedLength) chars)...\n", stderr)
        // 1. Open "Moby Dick"
        let openSpan = measureSpan {
            controller.openNote(mobyRecord.url)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let step1 = Step1Result(
            openMs: openSpan.wallMs,
            cpu: openSpan,
            charLength: (textView.string as NSString).length,
            byteLength: savedMobyText.utf8.count,
            wordCountLabel: controller.editor.wordCount.stringValue
        )
        let memAfterOpen = sampleMemory()
        fputs(String(format: "[Workout] Step 1 done: %.1f ms (CPU: %.1f ms / %.1f%%, mem: %.1f MB)\n", openSpan.wallMs, openSpan.cpuTimeMs, openSpan.cpuPercent, memAfterOpen.physFootprintMB), stderr)
        let resizeFrames: [NSSize] = [
            NSSize(width: 1280, height: 860),
            NSSize(width: 820, height: 560),
            NSSize(width: 1180, height: 780),
            NSSize(width: 1060, height: 740)
        ]

        func runScrollEndAndResize() -> ScrollResizeResult {
            let scrollMs = measureMs {
                let endRange = NSRange(location: (textView.string as NSString).length, length: 0)
                textView.scrollRangeToVisible(endRange)
                scrollView.reflectScrolledClipView(clipView)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            let originY = clipView.bounds.origin.y
            var stepTimes: [Double] = []
            let resizeCPU = measureSpan {
                for size in resizeFrames {
                    let dt = measureMs {
                        window.setContentSize(size)
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    stepTimes.append(dt)
                }
            }
            return ScrollResizeResult(scrollMs: scrollMs, resizeStepMs: stepTimes, resizeCPU: resizeCPU, scrollOriginY: originY)
        }

        func runScrollMiddleAndResize() -> ScrollResizeResult {
            let midLoc = (textView.string as NSString).length / 2
            let scrollMs = measureMs {
                let midRange = NSRange(location: midLoc, length: 0)
                textView.scrollRangeToVisible(midRange)
                scrollView.reflectScrolledClipView(clipView)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            let originY = clipView.bounds.origin.y
            var stepTimes: [Double] = []
            let resizeCPU = measureSpan {
                for size in resizeFrames {
                    let dt = measureMs {
                        window.setContentSize(size)
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    stepTimes.append(dt)
                }
            }
            return ScrollResizeResult(scrollMs: scrollMs, resizeStepMs: stepTimes, resizeCPU: resizeCPU, scrollOriginY: originY)
        }

        func runSelectAllCutPasteUndoRedo() -> ClipboardUndoRedoResult {
            let um = textView.undoManager
            let prevGroupsByEvent = um?.groupsByEvent ?? true
            um?.groupsByEvent = false
            defer { um?.groupsByEvent = prevGroupsByEvent }

            var selectAllMs = 0.0
            var cutMs = 0.0
            var pasteMs = 0.0
            var undoPasteMs = 0.0
            var undoCutMs = 0.0
            var redoCutMs = 0.0
            var redoPasteMs = 0.0
            let stepCPU = measureSpan {
                selectAllMs = measureMs {
                    textView.selectAll(nil)
                    window.displayIfNeeded()
                }
                cutMs = measureMs {
                    um?.beginUndoGrouping()
                    textView.cut(nil)
                    um?.endUndoGrouping()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                pasteMs = measureMs {
                    um?.beginUndoGrouping()
                    textView.paste(nil)
                    um?.endUndoGrouping()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                undoPasteMs = measureMs {
                    um?.undo()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                undoCutMs = measureMs {
                    um?.undo()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                redoCutMs = measureMs {
                    um?.redo()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                redoPasteMs = measureMs {
                    um?.redo()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
            }
            let intact = (textView.string as NSString).length == expectedLength && textView.string == savedMobyText
            return ClipboardUndoRedoResult(
                selectAllMs: selectAllMs,
                cutMs: cutMs,
                pasteMs: pasteMs,
                undoPasteMs: undoPasteMs,
                undoCutMs: undoCutMs,
                redoCutMs: redoCutMs,
                redoPasteMs: redoPasteMs,
                cpu: stepCPU,
                intactAfterRedo: intact
            )
        }

        func runEditNearMiddle(sample: String) -> MiddleTypingResult {
            let ns = textView.string as NSString
            let rawMid = ns.length / 2
            let lineRange = ns.lineRange(for: NSRange(location: rawMid, length: 0))
            let insertLoc = lineRange.location

            textView.setSelectedRange(NSRange(location: insertLoc, length: 0))
            textView.scrollRangeToVisible(NSRange(location: insertLoc, length: 0))
            if let lm = textView.layoutManager, let tc = textView.textContainer {
                let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: insertLoc, length: 0), actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                let targetY = max(0, rect.minY + textView.textContainerOrigin.y - clipView.bounds.height * 0.45)
                clipView.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clipView)
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            let baselineScrollY = clipView.bounds.origin.y
            var keystrokeTimes: [Double] = []
            var maxScrollJump: CGFloat = 0

            let um = textView.undoManager
            let prevGroupsByEvent = um?.groupsByEvent ?? true
            um?.groupsByEvent = false
            um?.beginUndoGrouping()
            let typingCPU = measureSpan {
                for ch in sample {
                    let prevScrollY = clipView.bounds.origin.y
                    let dt = measureMs {
                        textView.insertText(String(ch), replacementRange: textView.selectedRange())
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    fputs(String(format: "  [key '%@'] %.1f ms (scrollY=%.1f)\n", String(ch), dt, clipView.bounds.origin.y), stderr)
                    keystrokeTimes.append(dt)
                    let jumpPrev = abs(clipView.bounds.origin.y - prevScrollY)
                    let jumpBase = abs(clipView.bounds.origin.y - baselineScrollY)
                    maxScrollJump = max(maxScrollJump, jumpPrev, jumpBase)
                }
            }
            um?.endUndoGrouping()

            um?.undo()
            um?.groupsByEvent = prevGroupsByEvent
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let sorted = keystrokeTimes.sorted()
            let total = sorted.reduce(0, +)
            let avg = total / Double(max(1, sorted.count))
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let maxK = sorted.last ?? 0

            return MiddleTypingResult(
                keystrokeCount: sample.count,
                keystrokeTimesMs: keystrokeTimes,
                avgKeystrokeMs: avg,
                p50KeystrokeMs: p50,
                p95KeystrokeMs: p95,
                maxKeystrokeMs: maxK,
                totalTypingMs: total,
                cpu: typingCPU,
                maxScrollJumpPt: maxScrollJump
            )
        }

        fputs("[Workout] Starting Step 2: Scroll to end & resize...\n", stderr)
        let step2 = runScrollEndAndResize()
        fputs(String(format: "[Workout] Step 2 done: scroll=%.1f ms, resizeTotal=%.1f ms\n", step2.scrollMs, step2.resizeTotalMs), stderr)
        fputs("[Workout] Starting Step 3: Scroll to middle & resize...\n", stderr)
        let step3 = runScrollMiddleAndResize()
        fputs(String(format: "[Workout] Step 3 done: scroll=%.1f ms, resizeTotal=%.1f ms\n", step3.scrollMs, step3.resizeTotalMs), stderr)
        fputs("[Workout] Starting Step 4: Select All, Cut, Paste, Undo, Redo...\n", stderr)
        let step4 = runSelectAllCutPasteUndoRedo()
        fputs(String(format: "[Workout] Step 4 done: selectAll=%.1f, cut=%.1f, paste=%.1f, undoPaste=%.1f, undoCut=%.1f, redoCut=%.1f, redoPaste=%.1f (total=%.1f ms)\n", step4.selectAllMs, step4.cutMs, step4.pasteMs, step4.undoPasteMs, step4.undoCutMs, step4.redoCutMs, step4.redoPasteMs, step4.totalMs), stderr)
        fputs("[Workout] Starting Step 5: Edit near middle...\n", stderr)
        let step5 = runEditNearMiddle(sample: typingSample)
        fputs(String(format: "[Workout] Step 5 done: avg=%.2f ms/key, p95=%.2f ms, max=%.2f ms, scrollJump=%.2f pt\n", step5.avgKeystrokeMs, step5.p95KeystrokeMs, step5.maxKeystrokeMs, step5.maxScrollJumpPt), stderr)
        let memAfterFirstPass = sampleMemory()

        var repeats: [CycleSummary] = []
        if repeatCycles > 0 {
        for idx in 1...repeatCycles {
            fputs("[Workout] Starting Repeat Cycle #\(idx)...\n", stderr)
            var s2: ScrollResizeResult!
            var s3: ScrollResizeResult!
            var s4: ClipboardUndoRedoResult!
            var s5: MiddleTypingResult!
            let cycleSpan = measureSpan {
                s2 = runScrollEndAndResize()
                s3 = runScrollMiddleAndResize()
                s4 = runSelectAllCutPasteUndoRedo()
                s5 = runEditNearMiddle(sample: typingSample)
            }
            let mem = sampleMemory()
            fputs(String(format: "[Workout] Repeat Cycle #%d done: %.1f ms (CPU: %.1f ms / %.1f%%, mem: %.1f MB)\n", idx, cycleSpan.wallMs, cycleSpan.cpuTimeMs, cycleSpan.cpuPercent, mem.physFootprintMB), stderr)
            repeats.append(CycleSummary(
                cycleIndex: idx,
                totalMs: cycleSpan.wallMs,
                cpu: cycleSpan,
                step2: s2,
                step3: s3,
                step4: s4,
                step5: s5,
                memoryAfter: mem
            ))
        }
        }
        let memFinal = sampleMemory()
        return Report(
            step1: step1,
            step2: step2,
            step3: step3,
            step4: step4,
            step5: step5,
            repeats: repeats,
            memoryBeforeOpen: memBeforeOpen,
            memoryAfterOpen: memAfterOpen,
            memoryAfterFirstPass: memAfterFirstPass,
            memoryFinal: memFinal
        )
    }
}
