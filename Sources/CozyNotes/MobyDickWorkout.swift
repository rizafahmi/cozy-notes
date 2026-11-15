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

    struct OutlineFoldingResult {
        let headingCount: Int
        let foldSingleMs: Double
        let unfoldSingleMs: Double
        let overviewMs: Double
        let headingsOnlyMs: Double
        let showAllMs: Double
        let overviewFoldCount: Int
        let headingsOnlyFoldCount: Int
        let upstreamEditShiftsFoldCorrectly: Bool
        let intactAfterCycle: Bool
        let cpu: CPUSpan
        var totalCycleMs: Double { overviewMs + headingsOnlyMs + showAllMs }
    }

    struct InNoteFindResult {
        let query: String
        let matchCount: Int
        let searchQueryMs: Double
        let nextStepMs: [Double]
        let prevStepMs: [Double]
        let dismissMs: Double
        let cpu: CPUSpan
        var nextAvgMs: Double { nextStepMs.reduce(0, +) / Double(max(1, nextStepMs.count)) }
        var prevAvgMs: Double { prevStepMs.reduce(0, +) / Double(max(1, prevStepMs.count)) }
    }

    struct SyntaxTypingResult {
        let sample: String
        let keystrokeCount: Int
        let keystrokeTimesMs: [Double]
        let avgKeystrokeMs: Double
        let p50KeystrokeMs: Double
        let p95KeystrokeMs: Double
        let maxKeystrokeMs: Double
        let totalTypingMs: Double
        let cpu: CPUSpan
        let wikiAutocompleteTriggered: Bool
        let wikiLinkParsed: Bool
        let bulletParsed: Bool
        let intactAfterUndo: Bool
    }

    struct ComparisonWindowResult {
        let openWindowMs: Double
        let syncSaveMs: Double
        let closeWindowMs: Double
        let cpu: CPUSpan
        let companionSynced: Bool
        let intactAfterRestore: Bool
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
        let outlineFolding: OutlineFoldingResult
        let inNoteFind: InNoteFindResult
        let syntaxTyping: SyntaxTypingResult
        let comparisonWindow: ComparisonWindowResult
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
            6. Org-Mode Outline Folding & Cycling (\(outlineFolding.headingCount) headings):
               - Single chapter fold/unfold: \(String(format: "%.2f", outlineFolding.foldSingleMs)) ms / \(String(format: "%.2f", outlineFolding.unfoldSingleMs)) ms (upstream edit shift OK: \(outlineFolding.upstreamEditShiftsFoldCorrectly))
               - Cycle Overview -> Headings -> Show All: \(String(format: "%.2f", outlineFolding.overviewMs)) ms (\(outlineFolding.overviewFoldCount) folds) -> \(String(format: "%.2f", outlineFolding.headingsOnlyMs)) ms (\(outlineFolding.headingsOnlyFoldCount) folds) -> \(String(format: "%.2f", outlineFolding.showAllMs)) ms (total \(String(format: "%.2f", outlineFolding.totalCycleMs)) ms, intact: \(outlineFolding.intactAfterCycle))
            7. In-Note Find ("\(inNoteFind.query)", \(inNoteFind.matchCount) matches):
               - Search & highlight: \(String(format: "%.2f", inNoteFind.searchQueryMs)) ms
               - Next / Prev match:  \(String(format: "%.2f", inNoteFind.nextAvgMs)) ms avg next (\(inNoteFind.nextStepMs.count)x), \(String(format: "%.2f", inNoteFind.prevAvgMs)) ms avg prev (\(inNoteFind.prevStepMs.count)x), dismiss \(String(format: "%.2f", inNoteFind.dismissMs)) ms
            8. Syntax & [[WikiLink]] Typing Near Middle (\(syntaxTyping.keystrokeCount) keystrokes):
               - Avg / P50 / P95 / Max: \(String(format: "%.2f", syntaxTyping.avgKeystrokeMs)) / \(String(format: "%.2f", syntaxTyping.p50KeystrokeMs)) / \(String(format: "%.2f", syntaxTyping.p95KeystrokeMs)) / \(String(format: "%.2f", syntaxTyping.maxKeystrokeMs)) ms (total \(String(format: "%.2f", syntaxTyping.totalTypingMs)) ms)
               - Autocomplete & parse:  popup=\(syntaxTyping.wikiAutocompleteTriggered), wikiLink=\(syntaxTyping.wikiLinkParsed), bullet=\(syntaxTyping.bulletParsed), intact=\(syntaxTyping.intactAfterUndo)
            9. Comparison Window Open & Bidirectional Sync:
               - Open companion window: \(String(format: "%.2f", comparisonWindow.openWindowMs)) ms
               - Save & sync 1.2M note: \(String(format: "%.2f", comparisonWindow.syncSaveMs)) ms (close \(String(format: "%.2f", comparisonWindow.closeWindowMs)) ms, synced=\(comparisonWindow.companionSynced), intact=\(comparisonWindow.intactAfterRestore))
            10. Repeat Steps 2-5 (\(repeats.count) cycles) & Activity Monitor Memory:
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
        let candidateRoots: [URL]
        if let envVault = ProcessInfo.processInfo.environment["COZY_VAULT"] {
            candidateRoots = [URL(fileURLWithPath: envVault, isDirectory: true)]
        } else {
            candidateRoots = [
                UserDefaults.standard.string(forKey: "vaultPath").map { URL(fileURLWithPath: $0, isDirectory: true) },
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Cozy Notes", isDirectory: true)
            ].compactMap { $0 }
        }

        for root in candidateRoots {
            if let vault = try? Vault(root: root),
               let notes = try? vault.notes(),
               let moby = notes.first(where: { $0.title.localizedCaseInsensitiveContains("Moby Dick") }) {
                return try vault.read(moby.url)
            }
        }

        var chapters: [String] = ["# Moby-Dick; or, The Whale\n"]
        let para = "Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world and the White Whale. It is a way I have of driving off the spleen and regulating the circulation. Whenever I find myself growing grim about the mouth; whenever it is a damp, drizzly November in my soul, I account it high time to get to sea as soon as I can.\n\n"
        for ch in 1...135 {
            chapters.append("## CHAPTER \(ch). Loomings.\n\n" + String(repeating: para, count: 16))
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

        _ = try vault.capture(text: "# Cetology\n\nA systematic classification of whales and Leviathan lore.")
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

        func runOutlineFoldingWorkout() -> OutlineFoldingResult {
            let headingCount = textView.headingGutterItems.count
            let midIdx = max(1, headingCount / 2)
            var foldSingleMs = 0.0
            var unfoldSingleMs = 0.0
            var overviewMs = 0.0
            var headingsOnlyMs = 0.0
            var showAllMs = 0.0
            var overviewFoldCount = 0
            var headingsOnlyFoldCount = 0
            var upstreamShiftOK = false

            let cpu = measureSpan {
                if textView.headingGutterItems.indices.contains(midIdx) {
                    let midHeading = textView.headingGutterItems[midIdx]
                    textView.setSelectedRange(NSRange(location: midHeading.range.location, length: 0))
                    textView.scrollRangeToVisible(midHeading.range)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()

                    foldSingleMs = measureMs {
                        textView.toggleFold(forHeadingAt: midHeading.range.location)
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }

                    let upstreamIdx = max(0, midIdx - 1)
                    let upstreamLoc = NSMaxRange(textView.headingGutterItems[upstreamIdx].range)
                    let um = textView.undoManager
                    let prevGroups = um?.groupsByEvent ?? true
                    um?.groupsByEvent = false
                    um?.beginUndoGrouping()
                    textView.setSelectedRange(NSRange(location: upstreamLoc, length: 0))
                    textView.insertText(" [note]", replacementRange: NSRange(location: upstreamLoc, length: 0))
                    um?.endUndoGrouping()

                    if let shiftedFold = textView.foldedSections.first,
                       textView.headingGutterItems.indices.contains(midIdx) {
                        let updatedHeading = textView.headingGutterItems[midIdx]
                        upstreamShiftOK = (shiftedFold.headingLocation == updatedHeading.range.location)
                            && (shiftedFold.headingRange == updatedHeading.range)
                    }
                    um?.undo()
                    um?.groupsByEvent = prevGroups
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()

                    let restoredLoc = textView.headingGutterItems[midIdx].range.location
                    unfoldSingleMs = measureMs {
                        textView.toggleFold(forHeadingAt: restoredLoc)
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                }

                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                textView.layoutManager?.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: expectedLength))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()

                overviewMs = measureMs {
                    textView.cycleOutlineFolding(nil)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                overviewFoldCount = textView.foldedSections.count

                headingsOnlyMs = measureMs {
                    textView.cycleOutlineFolding(nil)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                headingsOnlyFoldCount = textView.foldedSections.count

                showAllMs = measureMs {
                    textView.cycleOutlineFolding(nil)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
            }

            let intact = textView.foldedSections.isEmpty
                && textView.outlineFoldMode == .showAll
                && (textView.string as NSString).length == expectedLength
            return OutlineFoldingResult(
                headingCount: headingCount,
                foldSingleMs: foldSingleMs,
                unfoldSingleMs: unfoldSingleMs,
                overviewMs: overviewMs,
                headingsOnlyMs: headingsOnlyMs,
                showAllMs: showAllMs,
                overviewFoldCount: overviewFoldCount,
                headingsOnlyFoldCount: headingsOnlyFoldCount,
                upstreamEditShiftsFoldCorrectly: upstreamShiftOK,
                intactAfterCycle: intact,
                cpu: cpu
            )
        }

        func runInNoteFindWorkout(query: String) -> InNoteFindResult {
            var searchQueryMs = 0.0
            var matchCount = 0
            var nextTimes: [Double] = []
            var prevTimes: [Double] = []
            var dismissMs = 0.0

            let cpu = measureSpan {
                searchQueryMs = measureMs {
                    controller.editor.showInNoteFind()
                    controller.editor.inNoteFindQuery = query
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                matchCount = controller.editor.inNoteFindMatchCount
                for _ in 0..<5 {
                    let dt = measureMs {
                        controller.editor.findNextInNote()
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    nextTimes.append(dt)
                }
                for _ in 0..<5 {
                    let dt = measureMs {
                        controller.editor.findPreviousInNote()
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    prevTimes.append(dt)
                }
                dismissMs = measureMs {
                    controller.editor.hideInNoteFind()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
            }
            return InNoteFindResult(
                query: query,
                matchCount: matchCount,
                searchQueryMs: searchQueryMs,
                nextStepMs: nextTimes,
                prevStepMs: prevTimes,
                dismissMs: dismissMs,
                cpu: cpu
            )
        }

        func runSyntaxAndWikiLinkTyping() -> SyntaxTypingResult {
            let syntaxSample = "- [ ] [[Cetology]] **whale** `folio`\n"
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
            var keystrokeTimes: [Double] = []
            var sawAutocomplete = false
            var sawWikiLink = false
            var sawBullet = false

            let um = textView.undoManager
            let prevGroups = um?.groupsByEvent ?? true
            um?.groupsByEvent = false
            um?.beginUndoGrouping()
            let typingCPU = measureSpan {
                for ch in syntaxSample {
                    let dt = measureMs {
                        textView.insertText(String(ch), replacementRange: textView.selectedRange())
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    keystrokeTimes.append(dt)
                    if controller.editor.isWikiAutocompleteVisible {
                        sawAutocomplete = true
                    }
                }
            }
            sawWikiLink = textView.wikiLinkItems.contains { $0.target == "Cetology" }
            sawBullet = !textView.bulletItems.isEmpty
            controller.editor.hideWikiAutocomplete()
            um?.endUndoGrouping()
            um?.undo()
            um?.groupsByEvent = prevGroups
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            let intact = (textView.string as NSString).length == expectedLength
            let sorted = keystrokeTimes.sorted()
            let total = sorted.reduce(0, +)
            let avg = total / Double(max(1, sorted.count))
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let maxK = sorted.last ?? 0

            return SyntaxTypingResult(
                sample: syntaxSample,
                keystrokeCount: syntaxSample.count,
                keystrokeTimesMs: keystrokeTimes,
                avgKeystrokeMs: avg,
                p50KeystrokeMs: p50,
                p95KeystrokeMs: p95,
                maxKeystrokeMs: maxK,
                totalTypingMs: total,
                cpu: typingCPU,
                wikiAutocompleteTriggered: sawAutocomplete,
                wikiLinkParsed: sawWikiLink,
                bulletParsed: sawBullet,
                intactAfterUndo: intact
            )
        }

        func runComparisonWindowWorkout() -> ComparisonWindowResult {
            var openWindowMs = 0.0
            var syncSaveMs = 0.0
            var closeWindowMs = 0.0
            var companionSynced = false
            var compController: NoteWindowController?

            let cpu = measureSpan {
                openWindowMs = measureMs {
                    compController = controller.openNoteInNewWindow(mobyRecord.url)
                    compController?.window?.contentView?.layoutSubtreeIfNeeded()
                    compController?.window?.displayIfNeeded()
                }
                let um = textView.undoManager
                let prevGroups = um?.groupsByEvent ?? true
                um?.groupsByEvent = false
                let midLoc = (textView.string as NSString).lineRange(for: NSRange(location: expectedLength / 2, length: 0)).location
                syncSaveMs = measureMs {
                    um?.beginUndoGrouping()
                    textView.setSelectedRange(NSRange(location: midLoc, length: 0))
                    textView.insertText("sync ", replacementRange: NSRange(location: midLoc, length: 0))
                    um?.endUndoGrouping()
                    _ = controller.persistCurrent()
                    compController?.window?.contentView?.layoutSubtreeIfNeeded()
                    compController?.window?.displayIfNeeded()
                }
                companionSynced = (compController?.editor.nsText.length == expectedLength + 5)

                um?.undo()
                um?.groupsByEvent = prevGroups
                _ = controller.persistCurrent()

                closeWindowMs = measureMs {
                    compController?.window?.close()
                    compController?.window?.orderOut(nil)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            let intact = (textView.string as NSString).length == expectedLength && textView.string == savedMobyText
            return ComparisonWindowResult(
                openWindowMs: openWindowMs,
                syncSaveMs: syncSaveMs,
                closeWindowMs: closeWindowMs,
                cpu: cpu,
                companionSynced: companionSynced,
                intactAfterRestore: intact
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
        fputs("[Workout] Starting Step 6: Org-mode outline folding & cycling...\n", stderr)
        let outlineFolding = runOutlineFoldingWorkout()
        fputs(String(format: "[Workout] Step 6 done: single=%.1f/%.1f ms, cycle=%.1f+%.1f+%.1f=%.1f ms\n", outlineFolding.foldSingleMs, outlineFolding.unfoldSingleMs, outlineFolding.overviewMs, outlineFolding.headingsOnlyMs, outlineFolding.showAllMs, outlineFolding.totalCycleMs), stderr)
        fputs("[Workout] Starting Step 7: In-note find...\n", stderr)
        let inNoteFind = runInNoteFindWorkout(query: typingSample)
        fputs(String(format: "[Workout] Step 7 done: search=%.1f ms (%d matches), nextAvg=%.2f ms, prevAvg=%.2f ms\n", inNoteFind.searchQueryMs, inNoteFind.matchCount, inNoteFind.nextAvgMs, inNoteFind.prevAvgMs), stderr)
        fputs("[Workout] Starting Step 8: Syntax & [[WikiLink]] typing near middle...\n", stderr)
        let syntaxTyping = runSyntaxAndWikiLinkTyping()
        fputs(String(format: "[Workout] Step 8 done: avg=%.2f ms/key, p95=%.2f ms, max=%.2f ms\n", syntaxTyping.avgKeystrokeMs, syntaxTyping.p95KeystrokeMs, syntaxTyping.maxKeystrokeMs), stderr)
        fputs("[Workout] Starting Step 9: Comparison window open & sync...\n", stderr)
        let comparisonWindow = runComparisonWindowWorkout()
        fputs(String(format: "[Workout] Step 9 done: open=%.1f ms, syncSave=%.1f ms, close=%.1f ms\n", comparisonWindow.openWindowMs, comparisonWindow.syncSaveMs, comparisonWindow.closeWindowMs), stderr)
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
            fputs(String(format: "[Workout] Repeat Cycle #%d done: %.1f ms (s2=%.1f, s3=%.1f, s4=%.1f [cut=%.1f paste=%.1f uP=%.1f uC=%.1f rC=%.1f rP=%.1f], s5=%.1f | CPU: %.1f ms / %.1f%%, mem: %.1f MB)\n", idx, cycleSpan.wallMs, s2.scrollMs + s2.resizeTotalMs, s3.scrollMs + s3.resizeTotalMs, s4.totalMs, s4.cutMs, s4.pasteMs, s4.undoPasteMs, s4.undoCutMs, s4.redoCutMs, s4.redoPasteMs, s5.totalTypingMs, cycleSpan.cpuTimeMs, cycleSpan.cpuPercent, mem.physFootprintMB), stderr)
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
            outlineFolding: outlineFolding,
            inNoteFind: inNoteFind,
            syntaxTyping: syntaxTyping,
            comparisonWindow: comparisonWindow,
            repeats: repeats,
            memoryBeforeOpen: memBeforeOpen,
            memoryAfterOpen: memAfterOpen,
            memoryAfterFirstPass: memAfterFirstPass,
            memoryFinal: memFinal
        )
    }
}
