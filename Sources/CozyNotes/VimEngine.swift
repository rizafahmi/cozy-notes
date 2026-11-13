import AppKit
import CozyCore

@MainActor enum VimMode: Equatable {
    case normal
    case insert
    case visual
    case visualLine

    var badgeTitle: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        }
    }

    var pillStyle: VimModePill.Style {
        switch self {
        case .normal: return .normal
        case .insert: return .insert
        case .visual, .visualLine: return .visual
        }
    }
}

@MainActor enum VimCursorShape: Equatable {
    case beam
    case block
    case underline
}

@MainActor enum VimSearchDirection: Equatable {
    case forward
    case backward
}

@MainActor enum VimRegisterStyle: Equatable {
    case charwise
    case linewise
}

@MainActor enum VimClipboard {
    private static var lastChangeCount: Int = -1
    private static var lastStyle: VimRegisterStyle = .charwise
    private static var lastText: String = ""

    static func write(_ text: String, style: VimRegisterStyle) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        lastStyle = style
        lastText = text
    }

    static func read() -> (text: String, style: VimRegisterStyle)? {
        let pb = NSPasteboard.general
        if pb.changeCount == lastChangeCount, !lastText.isEmpty {
            return (lastText, lastStyle)
        }
        guard let str = pb.string(forType: .string), !str.isEmpty else { return nil }
        return (str, .charwise)
    }
}

@MainActor enum VimKeyInput: Equatable {
    case char(String)
    case escape
    case returnKey
    case backspace
    case forwardDelete
    case tab
    case backtab
    case left
    case right
    case up
    case down
    case ctrl(Character)

    static func from(event: NSEvent) -> VimKeyInput? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return nil
        }
        if event.keyCode == 53 {
            return .escape
        }
        if flags.contains(.control) {
            if let ign = event.charactersIgnoringModifiers?.lowercased(), let first = ign.first {
                if first == "[" { return .escape }
                if first.isASCII { return .ctrl(first) }
            }
            if let scalar = event.characters?.unicodeScalars.first?.value {
                if scalar == 27 { return .escape }
                if scalar >= 1 && scalar <= 26, let ch = UnicodeScalar(scalar + 96) {
                    return .ctrl(Character(ch))
                }
            }
            return nil
        }

        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value {
            switch scalar {
            case 27: return .escape
            case 13, 3: return .returnKey
            case 127, 8: return .backspace
            case UInt32(NSDeleteFunctionKey): return .forwardDelete
            case 25: return .backtab
            case 9:
                return flags.contains(.shift) ? .backtab : .tab
            case UInt32(NSUpArrowFunctionKey): return .up
            case UInt32(NSDownArrowFunctionKey): return .down
            case UInt32(NSLeftArrowFunctionKey): return .left
            case UInt32(NSRightArrowFunctionKey): return .right
            default:
                if (0xF700...0xF8FF).contains(scalar) {
                    return nil
                }
            }
        }

        guard let chars = event.characters, !chars.isEmpty else { return nil }
        if chars == "\u{1B}" { return .escape }
        if chars == "\r" || chars == "\n" { return .returnKey }
        if chars == "\u{7F}" || chars == "\u{08}" { return .backspace }
        if chars == "\t" { return flags.contains(.shift) ? .backtab : .tab }
        if chars == "\u{19}" { return .backtab }
        return .char(chars)
    }
}

@MainActor protocol VimHost: AnyObject {
    var vimNSString: NSString { get }
    var vimSelectedRange: NSRange { get set }
    var vimUndoManager: UndoManager? { get }
    var vimHasMarkedText: Bool { get }
    var vimIsWikiAutocompleteVisible: Bool { get }

    func vimDismissWikiAutocomplete()
    func vimReplace(in range: NSRange, with replacement: String, selectedRangeAfter: NSRange?)
    func vimRegisterCoalescedUndo(inverseRange: NSRange, previousString: String, restoreSelection: NSRange)
    func vimIsCharacterFolded(_ location: Int) -> Bool
    func vimFoldedRangeEnclosing(_ location: Int) -> NSRange?
    func vimHeadingLocations() -> [Int]
    func vimToggleFoldAtCursor()
    func vimOpenFoldAtCursor()
    func vimCloseFoldAtCursor()
    func vimUnfoldAllHeadings()
    func vimFoldAllHeadings()
    func vimCycleOutlineFolding()
    func vimOpenWikiLinkAtCursor(inNewWindow: Bool) -> Bool
    func vimToggleTaskAt(range: NSRange) -> Bool
    func vimEnsureCaretVisible(typewriter: Bool)
    func vimScrollCursorLine(alignment: VimScrollAlignment)
    func vimScrollByHalfPages(_ halfPages: Int) -> Int?
    func vimViewportLineTarget(_ target: VimViewportTarget) -> Int?
    func vimVisualLineVerticalTarget(from location: Int, deltaLines: Int, preferredX: inout CGFloat?) -> Int?
    func vimVisualLineBoundary(from location: Int, kind: VimVisualBoundaryKind) -> Int?
    func vimBeginSearch(direction: VimSearchDirection)
    func vimFindMatchLocation(from location: Int, reverse: Bool, count: Int, inclusiveCurrent: Bool) -> NSRange?
    func vimSearchWord(_ word: String, forward: Bool, count: Int) -> NSRange?
    func vimDismissSearchHighlightsIfNeeded() -> Bool
    func vimSetStatus(_ message: String)
    func vimDidUpdateState()
}

@MainActor enum VimScrollAlignment {
    case center
    case top
    case bottom
}

@MainActor enum VimViewportTarget {
    case top
    case middle
    case bottom
}

@MainActor enum VimVisualBoundaryKind {
    case start
    case firstNonBlank
    case end
}

@MainActor final class VimEngine {
    enum OperatorKind: Equatable {
        case delete
        case change
        case yank
        case indent
        case outdent
        case lowercase
        case uppercase
        case toggleCase

        var symbol: String {
            switch self {
            case .delete: return "d"
            case .change: return "c"
            case .yank: return "y"
            case .indent: return ">"
            case .outdent: return "<"
            case .lowercase: return "gu"
            case .uppercase: return "gU"
            case .toggleCase: return "g~"
            }
        }
    }

    struct FindSpec: Equatable {
        enum Kind: Equatable {
            case findForward
            case findBackward
            case tillForward
            case tillBackward

            var inverted: Kind {
                switch self {
                case .findForward: return .findBackward
                case .findBackward: return .findForward
                case .tillForward: return .tillBackward
                case .tillBackward: return .tillForward
                }
            }

            var symbol: String {
                switch self {
                case .findForward: return "f"
                case .findBackward: return "F"
                case .tillForward: return "t"
                case .tillBackward: return "T"
                }
            }
        }
        let kind: Kind
        let target: String
    }

    enum PrefixKind: Equatable {
        case none
        case g
        case z
        case openBracket
        case closeBracket
        case replaceChar
        case findChar(FindSpec.Kind)
        case textObject(around: Bool)

        var symbol: String {
            switch self {
            case .none: return ""
            case .g: return "g"
            case .z: return "z"
            case .openBracket: return "["
            case .closeBracket: return "]"
            case .replaceChar: return "r"
            case .findChar(let kind): return kind.symbol
            case .textObject(let around): return around ? "a" : "i"
            }
        }
    }

    private struct LineInfo {
        let start: Int
        let contentEnd: Int
        let fullEnd: Int

        var isEmpty: Bool { contentEnd <= start }
    }

    private enum MotionStyle {
        case charExclusive
        case charInclusive
        case linewise
    }

    private struct ResolvedMotion {
        let target: Int
        let style: MotionStyle
        let preservesDesiredColumn: Bool
    }

    private struct InsertUndoTracker {
        var initialSelection: NSRange
        var hasMutation: Bool = false
        var regionStart: Int = 0
        var originalText: String = ""
        var currentLength: Int = 0

        mutating func absorb(safeRange: NSRange, previousString: String, replacementLength: Int) -> Bool {
            if !hasMutation {
                hasMutation = true
                regionStart = safeRange.location
                originalText = previousString
                currentLength = replacementLength
                return true
            }
            let regionEnd = regionStart + currentLength
            let editStart = safeRange.location
            let editEnd = NSMaxRange(safeRange)
            guard editEnd >= regionStart && editStart <= regionEnd else {
                return false
            }
            let prevNS = previousString as NSString
            var prefixLen = 0
            var suffixLen = 0
            if editStart < regionStart {
                prefixLen = regionStart - editStart
                let prefix = prevNS.substring(with: NSRange(location: 0, length: min(prefixLen, prevNS.length)))
                originalText = prefix + originalText
                regionStart = editStart
            }
            if editEnd > regionEnd {
                suffixLen = editEnd - regionEnd
                let suffixStart = max(0, prevNS.length - suffixLen)
                let suffix = prevNS.substring(with: NSRange(location: suffixStart, length: prevNS.length - suffixStart))
                originalText += suffix
            }
            currentLength = currentLength + prefixLen + suffixLen - safeRange.length + replacementLength
            return true
        }
    }

    private struct InsertRepeatTracker {
        let entryKeys: [VimKeyInput]
        let effectiveCount: Int
        let originLocation: Int
        var isValid: Bool = true
        var prefixConsumed: Int = 0
        var suffixConsumed: Int = 0
        var currentLength: Int = 0

        mutating func absorb(safeRange: NSRange, replacementLength: Int) {
            guard isValid else { return }
            let spanStart = originLocation - prefixConsumed
            let spanEnd = spanStart + currentLength
            let editStart = safeRange.location
            let editEnd = NSMaxRange(safeRange)
            guard editEnd >= spanStart && editStart <= spanEnd else {
                isValid = false
                return
            }
            var extraPrefix = 0
            var extraSuffix = 0
            if editStart < spanStart {
                extraPrefix = spanStart - editStart
                prefixConsumed += extraPrefix
            }
            if editEnd > spanEnd {
                extraSuffix = editEnd - spanEnd
                suffixConsumed += extraSuffix
            }
            currentLength = currentLength + extraPrefix + extraSuffix - safeRange.length + replacementLength
        }
    }

    private enum RepeatableAction {
        case normalSequence(coreKeys: [VimKeyInput], count: Int)
        case insertSession(entryKeys: [VimKeyInput], count: Int, prefixConsumed: Int, suffixConsumed: Int, insertedText: String)
        case visualEdit(isLinewise: Bool, spanLength: Int, lineCount: Int, op: OperatorKind, replacementText: String?)
    }

    weak var host: VimHost?

    private(set) var isEnabled: Bool = false
    private(set) var mode: VimMode = .normal
    private(set) var pendingOperator: OperatorKind?
    private(set) var prefix: PrefixKind = .none
    private var operatorCount: Int?
    private var motionCount: Int?

    private(set) var visualAnchor: Int = 0
    private(set) var visualHead: Int = 0
    private var lastVisualSnapshot: (mode: VimMode, anchor: Int, head: Int)?
    private var lastInsertExitLocation: Int?
    private var lastFindSpec: FindSpec?
    private var desiredColumn: Int?
    private var preferredVisualX: CGFloat?

    private var insertUndoTracker: InsertUndoTracker?
    private var insertRepeatTracker: InsertRepeatTracker?
    private var currentCommandKeys: [VimKeyInput] = []
    private var lastRepeatable: RepeatableAction?
    private var isReplayingRepeat = false
    private(set) var isApplyingInternalSelection = false

    var isCoalescingInsertUndo: Bool {
        isEnabled && insertUndoTracker != nil && !isReplayingRepeat
    }

    var cursorShape: VimCursorShape {
        guard isEnabled else { return .beam }
        if mode == .insert { return .beam }
        if pendingOperator != nil { return .underline }
        switch prefix {
        case .replaceChar, .findChar:
            return .underline
        default:
            return .block
        }
    }

    var activeBlockCursorLocation: Int? {
        guard isEnabled, mode != .insert else { return nil }
        switch mode {
        case .normal:
            return host?.vimSelectedRange.location ?? 0
        case .visual, .visualLine:
            return visualHead
        case .insert:
            return nil
        }
    }

    var pendingKeysDisplay: String {
        guard isEnabled, mode != .insert else { return "" }
        var out = ""
        if let oc = operatorCount { out += "\(oc)" }
        if let op = pendingOperator { out += op.symbol }
        if let mc = motionCount { out += "\(mc)" }
        out += prefix.symbol
        return out
    }

    // MARK: - Lifecycle & Mode Management

    func setEnabled(_ enabled: Bool, startInInsertIfEmpty: Bool = true) {
        if !enabled {
            flushInsertUndoIfNeeded()
            isEnabled = false
            mode = .insert
            clearPendingState()
            desiredColumn = nil
            preferredVisualX = nil
            host?.vimDidUpdateState()
            return
        }
        let wasEnabled = isEnabled
        isEnabled = true
        clearPendingState()
        guard let host else { return }
        let ns = host.vimNSString
        if startInInsertIfEmpty && ns.length == 0 {
            mode = .insert
        } else if !wasEnabled || mode == .insert {
            mode = .normal
            let clamped = clampNormalLocation(host.vimSelectedRange.location, in: ns)
            setHostSelection(NSRange(location: clamped, length: 0))
        }
        host.vimDidUpdateState()
    }

    func resetForLoadedDocument(isEmpty: Bool) {
        insertUndoTracker = nil
        insertRepeatTracker = nil
        clearPendingState()
        desiredColumn = nil
        preferredVisualX = nil
        lastVisualSnapshot = nil
        lastInsertExitLocation = nil
        guard isEnabled else { return }
        if isEmpty {
            mode = .insert
        } else {
            mode = .normal
            if let host {
                let ns = host.vimNSString
                let clamped = clampNormalLocation(host.vimSelectedRange.location, in: ns)
                setHostSelection(NSRange(location: clamped, length: 0))
            }
        }
        host?.vimDidUpdateState()
    }

    func enterInsertModeProgrammatically() {
        guard isEnabled else { return }
        flushInsertUndoIfNeeded()
        clearPendingState()
        mode = .insert
        desiredColumn = nil
        preferredVisualX = nil
        if let host {
            let loc = min(host.vimSelectedRange.location, host.vimNSString.length)
            setHostSelection(NSRange(location: loc, length: 0))
            insertUndoTracker = InsertUndoTracker(initialSelection: NSRange(location: loc, length: 0))
        }
        host?.vimDidUpdateState()
    }

    func enterNormalModeFromExternalControl(at targetLocation: Int? = nil) {
        guard isEnabled else { return }
        finalizeInsertSessionIfNeeded(stepCursorLeft: false)
        clearPendingState()
        mode = .normal
        desiredColumn = nil
        preferredVisualX = nil
        if let host {
            let ns = host.vimNSString
            let rawLoc = targetLocation ?? host.vimSelectedRange.location
            let clamped = clampNormalLocation(rawLoc, in: ns)
            setHostSelection(NSRange(location: clamped, length: 0))
        }
        host?.vimDidUpdateState()
    }

    func handleFocusLost() {
        flushInsertUndoIfNeeded()
        if prefix != .none || pendingOperator != nil || operatorCount != nil || motionCount != nil {
            clearPendingState()
            host?.vimDidUpdateState()
        }
    }

    func handleMouseSelectionCompleted() {
        guard isEnabled, !isApplyingInternalSelection, let host else { return }
        let ns = host.vimNSString
        let sel = host.vimSelectedRange
        clearPendingState()
        desiredColumn = nil
        preferredVisualX = nil

        if mode == .insert {
            flushInsertUndoIfNeeded()
            insertRepeatTracker?.isValid = false
            insertUndoTracker = InsertUndoTracker(initialSelection: sel)
            host.vimDidUpdateState()
            return
        }

        if sel.length > 0, ns.length > 0 {
            mode = .visual
            visualAnchor = min(sel.location, ns.length - 1)
            let endChar = prevCharStart(before: min(NSMaxRange(sel), ns.length), in: ns)
            visualHead = max(visualAnchor, endChar)
        } else {
            mode = .normal
            let clamped = clampNormalLocation(sel.location, in: ns)
            if clamped != sel.location {
                setHostSelection(NSRange(location: clamped, length: 0))
            }
        }
        host.vimDidUpdateState()
    }

    func clampSelectionIfNeeded() {
        guard isEnabled, mode == .normal, let host else { return }
        let ns = host.vimNSString
        let sel = host.vimSelectedRange
        let clamped = clampNormalLocation(sel.location, in: ns)
        if sel.length != 0 || sel.location != clamped {
            setHostSelection(NSRange(location: clamped, length: 0))
        }
        host.vimDidUpdateState()
    }

    // MARK: - Coalesced Insert Undo Hook

    func recordMutationInInsertSession(
        safeRange: NSRange,
        previousString: String,
        replacementLength: Int,
        selectionBefore: NSRange
    ) -> Bool {
        guard isEnabled, !isReplayingRepeat else { return false }
        insertRepeatTracker?.absorb(safeRange: safeRange, replacementLength: replacementLength)
        if mode == .insert && insertUndoTracker == nil {
            insertUndoTracker = InsertUndoTracker(initialSelection: selectionBefore)
        }
        guard insertUndoTracker != nil else { return false }
        if insertUndoTracker!.absorb(safeRange: safeRange, previousString: previousString, replacementLength: replacementLength) {
            return true
        }
        flushInsertUndoIfNeeded()
        var fresh = InsertUndoTracker(initialSelection: selectionBefore)
        _ = fresh.absorb(safeRange: safeRange, previousString: previousString, replacementLength: replacementLength)
        insertUndoTracker = fresh
        return true
    }

    func flushInsertUndoIfNeeded() {
        insertRepeatTracker?.isValid = false
        guard let tracker = insertUndoTracker else { return }
        insertUndoTracker = nil
        guard tracker.hasMutation, let host else { return }
        let nsLen = host.vimNSString.length
        let safeStart = min(max(0, tracker.regionStart), nsLen)
        let safeLen = min(max(0, tracker.currentLength), nsLen - safeStart)
        host.vimRegisterCoalescedUndo(
            inverseRange: NSRange(location: safeStart, length: safeLen),
            previousString: tracker.originalText,
            restoreSelection: tracker.initialSelection
        )
    }

    // MARK: - Key Handling Entry Point

    /// Returns `true` if VimEngine handled and consumed the event; `false` to pass to AppKit (`super.keyDown`).
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isEnabled, let host else { return false }
        if host.vimHasMarkedText {
            return false
        }
        guard let input = VimKeyInput.from(event: event) else {
            return false
        }
        return processInput(input)
    }

    @discardableResult
    func processInput(_ input: VimKeyInput) -> Bool {
        guard isEnabled, let host else { return false }

        if mode == .insert {
            return handleInsertInput(input, host: host)
        }

        // Escape / Ctrl-[ / Ctrl-C always returns cleanly to Normal mode
        if input == .escape || input == .ctrl("c") {
            let hadPending = pendingOperator != nil || prefix != .none || operatorCount != nil || motionCount != nil
            clearPendingState()
            currentCommandKeys.removeAll(keepingCapacity: true)
            if mode == .visual || mode == .visualLine {
                lastVisualSnapshot = (mode, visualAnchor, visualHead)
                mode = .normal
                let clamped = clampNormalLocation(visualHead, in: host.vimNSString)
                setHostSelection(NSRange(location: clamped, length: 0))
            } else if !hadPending {
                _ = host.vimDismissSearchHighlightsIfNeeded()
            }
            host.vimDidUpdateState()
            return true
        }

        // Single-char pending states (`r{char}` and `f`/`F`/`t`/`T` `{char}`)
        if prefix == .replaceChar {
            return finishReplaceSingleChar(input, host: host)
        }
        if case .findChar(let findKind) = prefix {
            return finishFindChar(findKind, input: input, host: host)
        }

        // Count accumulation (`1`..`9`, plus `0` once count has started)
        if prefix == .none, case .char(let s) = input, s.count == 1, let digit = s.first?.wholeNumberValue {
            let activeCount = pendingOperator == nil ? operatorCount : motionCount
            if digit > 0 || activeCount != nil {
                let nextVal = min(99_999, (activeCount ?? 0) * 10 + digit)
                if pendingOperator == nil {
                    operatorCount = nextVal
                } else {
                    motionCount = nextVal
                }
                host.vimDidUpdateState()
                return true
            }
        }

        currentCommandKeys.append(input)
        let consumed = dispatchModalInput(input, host: host)
        host.vimDidUpdateState()
        return consumed
    }

    // MARK: - Insert Mode Input

    private func handleInsertInput(_ input: VimKeyInput, host: VimHost) -> Bool {
        switch input {
        case .escape, .ctrl("c"):
            if host.vimIsWikiAutocompleteVisible {
                host.vimDismissWikiAutocomplete()
                return true
            }
            finalizeInsertSessionIfNeeded(stepCursorLeft: true)
            mode = .normal
            clearPendingState()
            host.vimDidUpdateState()
            return true

        case .ctrl("w"):
            deleteWordBackwardInInsert(host: host)
            return true

        case .ctrl("u"):
            deleteToLineStartInInsert(host: host)
            return true

        case .up, .down:
            if host.vimIsWikiAutocompleteVisible {
                return false
            }
            insertRepeatTracker?.isValid = false
            flushInsertUndoIfNeeded()
            return false

        case .left, .right:
            insertRepeatTracker?.isValid = false
            flushInsertUndoIfNeeded()
            return false

        default:
            return false
        }
    }

    private func deleteWordBackwardInInsert(host: VimHost) {
        let ns = host.vimNSString
        let sel = host.vimSelectedRange
        if sel.length > 0 {
            host.vimReplace(in: sel, with: "", selectedRangeAfter: NSRange(location: sel.location, length: 0))
            return
        }
        guard sel.location > 0 else { return }
        let line = lineInfo(for: sel.location, in: ns)
        if sel.location <= line.start {
            let prevLoc = prevCharStart(before: sel.location, in: ns)
            host.vimReplace(in: NSRange(location: prevLoc, length: sel.location - prevLoc), with: "", selectedRangeAfter: NSRange(location: prevLoc, length: 0))
            return
        }
        var p = sel.location
        while p > line.start {
            let prev = prevCharStart(before: p, in: ns)
            if charClass(at: prev, in: ns, bigWord: false) == .whitespace {
                p = prev
            } else {
                break
            }
        }
        if p > line.start {
            let targetClass = charClass(at: prevCharStart(before: p, in: ns), in: ns, bigWord: false)
            while p > line.start {
                let prev = prevCharStart(before: p, in: ns)
                if charClass(at: prev, in: ns, bigWord: false) == targetClass {
                    p = prev
                } else {
                    break
                }
            }
        }
        let delRange = NSRange(location: p, length: sel.location - p)
        host.vimReplace(in: delRange, with: "", selectedRangeAfter: NSRange(location: p, length: 0))
    }

    private func deleteToLineStartInInsert(host: VimHost) {
        let ns = host.vimNSString
        let sel = host.vimSelectedRange
        let line = lineInfo(for: sel.location, in: ns)
        guard sel.location > line.start else { return }
        let delRange = NSRange(location: line.start, length: sel.location - line.start)
        host.vimReplace(in: delRange, with: "", selectedRangeAfter: NSRange(location: line.start, length: 0))
    }

    private func beginInsertSession(entryKeys: [VimKeyInput], count: Int, cursorBeforeEntry: NSRange, host: VimHost) {
        if !isReplayingRepeat {
            if insertUndoTracker == nil {
                insertUndoTracker = InsertUndoTracker(initialSelection: cursorBeforeEntry)
            }
            let origin = host.vimSelectedRange.location
            insertRepeatTracker = InsertRepeatTracker(
                entryKeys: entryKeys,
                effectiveCount: count,
                originLocation: origin
            )
        }
        mode = .insert
        clearPendingState()
        desiredColumn = nil
        preferredVisualX = nil
    }

    private func finalizeInsertSessionIfNeeded(stepCursorLeft: Bool) {
        guard let host else { return }
        let ns = host.vimNSString
        let endCursor = min(host.vimSelectedRange.location, ns.length)
        lastInsertExitLocation = endCursor

        if let repeatTracker = insertRepeatTracker, !isReplayingRepeat {
            insertRepeatTracker = nil
            if repeatTracker.isValid {
                let start = min(max(0, repeatTracker.originLocation - repeatTracker.prefixConsumed), ns.length)
                let len = min(max(0, repeatTracker.currentLength), ns.length - start)
                let inserted = len > 0 ? ns.substring(with: NSRange(location: start, length: len)) : ""
                lastRepeatable = .insertSession(
                    entryKeys: repeatTracker.entryKeys,
                    count: repeatTracker.effectiveCount,
                    prefixConsumed: repeatTracker.prefixConsumed,
                    suffixConsumed: repeatTracker.suffixConsumed,
                    insertedText: inserted
                )
            }
        } else {
            insertRepeatTracker = nil
        }

        flushInsertUndoIfNeeded()

        if stepCursorLeft, ns.length > 0 {
            let line = lineInfo(for: endCursor, in: ns)
            let stepped: Int
            if endCursor > line.start {
                let candidate = min(endCursor, line.contentEnd)
                stepped = candidate > line.start ? prevCharStart(before: candidate, in: ns) : line.start
            } else {
                stepped = line.start
            }
            setHostSelection(NSRange(location: stepped, length: 0))
        }
    }

    // MARK: - Normal / Visual / Operator-Pending Dispatch

    private var effectiveCount: Int {
        let a = operatorCount ?? 1
        let b = motionCount ?? 1
        return min(99_999, max(1, a * b))
    }

    private var hasExplicitCount: Bool {
        operatorCount != nil || motionCount != nil
    }

    private func clearPendingState() {
        pendingOperator = nil
        prefix = .none
        operatorCount = nil
        motionCount = nil
    }

    private func resetCommandTracking() {
        clearPendingState()
        currentCommandKeys.removeAll(keepingCapacity: true)
    }

    private func dispatchModalInput(_ input: VimKeyInput, host: VimHost) -> Bool {
        // 1. Handle multi-key prefixes (`g`, `z`, `[`, `]`, `i`/`a` text object)
        switch prefix {
        case .g:
            return handleGPrefix(input, host: host)
        case .z:
            return handleZPrefix(input, host: host)
        case .openBracket:
            return handleBracketPrefix(open: true, input: input, host: host)
        case .closeBracket:
            return handleBracketPrefix(open: false, input: input, host: host)
        case .textObject(let around):
            return handleTextObjectTarget(around: around, input: input, host: host)
        case .replaceChar, .findChar:
            return true
        case .none:
            break
        }

        // 2. Ctrl commands in Normal / Visual
        if case .ctrl(let ctrlChar) = input {
            return handleCtrlCommand(ctrlChar, host: host)
        }

        // 3. Special non-character keys in Normal / Visual
        switch input {
        case .left, .backspace:
            applyMotion(resolveHorizontalMotion(delta: -1, count: effectiveCount, in: host.vimNSString), host: host)
            return true
        case .right:
            applyMotion(resolveHorizontalMotion(delta: 1, count: effectiveCount, in: host.vimNSString), host: host)
            return true
        case .up:
            applyMotion(resolveVerticalMotion(delta: -1, count: effectiveCount, host: host), host: host)
            return true
        case .down:
            applyMotion(resolveVerticalMotion(delta: 1, count: effectiveCount, host: host), host: host)
            return true
        case .returnKey:
            return handleReturnInModal(host: host)
        case .tab:
            if mode == .normal && pendingOperator == nil {
                host.vimToggleFoldAtCursor()
            }
            resetCommandTracking()
            return true
        case .backtab:
            if mode == .normal && pendingOperator == nil {
                host.vimCycleOutlineFolding()
            }
            resetCommandTracking()
            return true
        default:
            break
        }

        guard case .char(let key) = input else {
            resetCommandTracking()
            return true
        }

        // 4. Text object introducers (`i` / `a`) when inside Operator-Pending or Visual mode
        if (pendingOperator != nil || mode == .visual || mode == .visualLine) && (key == "i" || key == "a") {
            prefix = .textObject(around: key == "a")
            return true
        }

        // 5. Prefix starters
        switch key {
        case "g":
            prefix = .g
            return true
        case "z":
            if pendingOperator == nil {
                prefix = .z
                return true
            }
            resetCommandTracking()
            return true
        case "[":
            prefix = .openBracket
            return true
        case "]":
            prefix = .closeBracket
            return true
        case "f":
            prefix = .findChar(.findForward)
            return true
        case "F":
            prefix = .findChar(.findBackward)
            return true
        case "t":
            prefix = .findChar(.tillForward)
            return true
        case "T":
            prefix = .findChar(.tillBackward)
            return true
        default:
            break
        }

        // 6. Double-operator linewise shortcuts (`dd`, `cc`, `yy`, `>>`, `<<`)
        if let pending = pendingOperator {
            if (pending == .delete && key == "d")
                || (pending == .change && key == "c")
                || (pending == .yank && key == "y")
                || (pending == .indent && key == ">")
                || (pending == .outdent && key == "<") {
                executeLinewiseOperator(pending, count: effectiveCount, host: host)
                return true
            }
        }

        // 7. Pure Motions (valid in Normal, Visual, and Operator-Pending)
        if let motion = resolveDirectMotion(for: key, host: host) {
            applyMotion(motion, forKey: key, host: host)
            return true
        }

        // If an operator was pending and key was not a valid motion/textobj, cancel cleanly
        if pendingOperator != nil {
            resetCommandTracking()
            return true
        }

        // 8. Visual / Visual-Line specific commands
        if mode == .visual || mode == .visualLine {
            return handleVisualCommand(key: key, host: host)
        }

        // 9. Normal-mode commands & operators
        return handleNormalCommand(key: key, host: host)
    }

    // MARK: - Normal Mode Commands

    private func handleNormalCommand(key: String, host: VimHost) -> Bool {
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let count = effectiveCount
        let coreKeys = currentCommandKeys

        switch key {
        // Insert entry
        case "i":
            let before = NSRange(location: cursor, length: 0)
            setHostSelection(before)
            beginInsertSession(entryKeys: [.char("i")], count: 1, cursorBeforeEntry: before, host: host)
            resetCommandTracking()
            return true

        case "I":
            let before = NSRange(location: cursor, length: 0)
            let line = lineInfo(for: cursor, in: ns)
            let target = firstNonBlank(on: line, in: ns)
            setHostSelection(NSRange(location: target, length: 0))
            beginInsertSession(entryKeys: [.char("I")], count: 1, cursorBeforeEntry: before, host: host)
            resetCommandTracking()
            return true

        case "a":
            let before = NSRange(location: cursor, length: 0)
            let line = lineInfo(for: cursor, in: ns)
            let target = cursor < line.contentEnd ? nextCharLocation(after: cursor, in: ns) : line.contentEnd
            setHostSelection(NSRange(location: min(target, line.contentEnd), length: 0))
            beginInsertSession(entryKeys: [.char("a")], count: 1, cursorBeforeEntry: before, host: host)
            resetCommandTracking()
            return true

        case "A":
            let before = NSRange(location: cursor, length: 0)
            let line = lineInfo(for: cursor, in: ns)
            setHostSelection(NSRange(location: line.contentEnd, length: 0))
            beginInsertSession(entryKeys: [.char("A")], count: 1, cursorBeforeEntry: before, host: host)
            resetCommandTracking()
            return true

        case "o":
            let before = NSRange(location: cursor, length: 0)
            if insertUndoTracker == nil && !isReplayingRepeat {
                insertUndoTracker = InsertUndoTracker(initialSelection: before)
            }
            let line = lineInfo(for: cursor, in: ns)
            let indent = leadingWhitespace(on: line, in: ns)
            if line.fullEnd > line.contentEnd {
                let insertText = indent + "\n"
                let nextCaret = line.fullEnd + (indent as NSString).length
                host.vimReplace(
                    in: NSRange(location: line.fullEnd, length: 0),
                    with: insertText,
                    selectedRangeAfter: NSRange(location: nextCaret, length: 0)
                )
            } else {
                let insertText = "\n" + indent
                let nextCaret = line.contentEnd + 1 + (indent as NSString).length
                host.vimReplace(
                    in: NSRange(location: line.contentEnd, length: 0),
                    with: insertText,
                    selectedRangeAfter: NSRange(location: nextCaret, length: 0)
                )
            }
            beginInsertSession(entryKeys: [.char("o")], count: 1, cursorBeforeEntry: before, host: host)
            host.vimEnsureCaretVisible(typewriter: true)
            resetCommandTracking()
            return true

        case "O":
            let before = NSRange(location: cursor, length: 0)
            if insertUndoTracker == nil && !isReplayingRepeat {
                insertUndoTracker = InsertUndoTracker(initialSelection: before)
            }
            let line = lineInfo(for: cursor, in: ns)
            let indent = leadingWhitespace(on: line, in: ns)
            let insertText = indent + "\n"
            let nextCaret = line.start + (indent as NSString).length
            host.vimReplace(
                in: NSRange(location: line.start, length: 0),
                with: insertText,
                selectedRangeAfter: NSRange(location: nextCaret, length: 0)
            )
            beginInsertSession(entryKeys: [.char("O")], count: 1, cursorBeforeEntry: before, host: host)
            host.vimEnsureCaretVisible(typewriter: true)
            resetCommandTracking()
            return true

        // Visual entry
        case "v":
            mode = .visual
            visualAnchor = cursor
            visualHead = cursor
            syncVisualSelection(host: host)
            resetCommandTracking()
            return true

        case "V":
            mode = .visualLine
            visualAnchor = cursor
            visualHead = cursor
            syncVisualSelection(host: host)
            resetCommandTracking()
            return true

        // Operators
        case "d":
            pendingOperator = .delete
            return true
        case "c":
            pendingOperator = .change
            return true
        case "y":
            pendingOperator = .yank
            return true
        case ">":
            pendingOperator = .indent
            return true
        case "<":
            pendingOperator = .outdent
            return true

        // Shorthand operators
        case "D":
            let line = lineInfo(for: cursor, in: ns)
            if cursor < line.contentEnd {
                let delRange = NSRange(location: cursor, length: line.contentEnd - cursor)
                let deleted = ns.substring(with: delRange)
                VimClipboard.write(deleted, style: .charwise)
                let nextLoc = clampNormalLocation(cursor, in: nsAfterDeleting(delRange, in: ns), fallbackStart: line.start)
                host.vimReplace(in: delRange, with: "", selectedRangeAfter: NSRange(location: nextLoc, length: 0))
            }
            recordNormalRepeat(coreKeys: [.char("D")], count: count)
            desiredColumn = nil
            resetCommandTracking()
            return true

        case "C":
            let before = NSRange(location: cursor, length: 0)
            if insertUndoTracker == nil && !isReplayingRepeat {
                insertUndoTracker = InsertUndoTracker(initialSelection: before)
            }
            let line = lineInfo(for: cursor, in: ns)
            if cursor < line.contentEnd {
                let delRange = NSRange(location: cursor, length: line.contentEnd - cursor)
                VimClipboard.write(ns.substring(with: delRange), style: .charwise)
                host.vimReplace(in: delRange, with: "", selectedRangeAfter: NSRange(location: cursor, length: 0))
            }
            beginInsertSession(entryKeys: [.char("C")], count: count, cursorBeforeEntry: before, host: host)
            resetCommandTracking()
            return true

        case "s":
            let before = NSRange(location: cursor, length: 0)
            if insertUndoTracker == nil && !isReplayingRepeat {
                insertUndoTracker = InsertUndoTracker(initialSelection: before)
            }
            let line = lineInfo(for: cursor, in: ns)
            let endLoc = advanceCharsOnLine(from: cursor, count: count, line: line, in: ns)
            if endLoc > cursor {
                let delRange = NSRange(location: cursor, length: endLoc - cursor)
                VimClipboard.write(ns.substring(with: delRange), style: .charwise)
                host.vimReplace(in: delRange, with: "", selectedRangeAfter: NSRange(location: cursor, length: 0))
            }
            beginInsertSession(entryKeys: [.char("s")], count: count, cursorBeforeEntry: before, host: host)
            resetCommandTracking()
            return true

        case "S":
            executeLinewiseOperator(.change, count: count, host: host, overrideEntryKeys: [.char("S")])
            return true

        case "Y":
            executeLinewiseOperator(.yank, count: count, host: host)
            return true

        case "x":
            let line = lineInfo(for: cursor, in: ns)
            let endLoc = advanceCharsOnLine(from: cursor, count: count, line: line, in: ns)
            if endLoc > cursor {
                let delRange = NSRange(location: cursor, length: endLoc - cursor)
                VimClipboard.write(ns.substring(with: delRange), style: .charwise)
                host.vimReplace(in: delRange, with: "", selectedRangeAfter: NSRange(location: cursor, length: 0))
                let clamped = clampNormalLocation(cursor, in: host.vimNSString)
                setHostSelection(NSRange(location: clamped, length: 0))
            }
            recordNormalRepeat(coreKeys: [.char("x")], count: count)
            desiredColumn = nil
            resetCommandTracking()
            return true

        case "X":
            let line = lineInfo(for: cursor, in: ns)
            var startLoc = cursor
            for _ in 0..<count where startLoc > line.start {
                startLoc = prevCharStart(before: startLoc, in: ns)
            }
            if startLoc < cursor {
                let delRange = NSRange(location: startLoc, length: cursor - startLoc)
                VimClipboard.write(ns.substring(with: delRange), style: .charwise)
                host.vimReplace(in: delRange, with: "", selectedRangeAfter: NSRange(location: startLoc, length: 0))
            }
            recordNormalRepeat(coreKeys: [.char("X")], count: count)
            desiredColumn = nil
            resetCommandTracking()
            return true

        case "r":
            prefix = .replaceChar
            return true

        case "~":
            toggleCaseAtCursor(count: count, host: host)
            recordNormalRepeat(coreKeys: [.char("~")], count: count)
            resetCommandTracking()
            return true

        case "J":
            joinLines(count: max(2, hasExplicitCount ? count : 2), trimSpaces: true, host: host)
            recordNormalRepeat(coreKeys: [.char("J")], count: max(2, hasExplicitCount ? count : 2))
            resetCommandTracking()
            return true

        case "p":
            pasteFromClipboard(after: true, count: count, host: host)
            recordNormalRepeat(coreKeys: [.char("p")], count: count)
            resetCommandTracking()
            return true

        case "P":
            pasteFromClipboard(after: false, count: count, host: host)
            recordNormalRepeat(coreKeys: [.char("P")], count: count)
            resetCommandTracking()
            return true

        case "u":
            performUndo(count: count, host: host)
            resetCommandTracking()
            return true

        case ".":
            replayLastEdit(overrideCount: hasExplicitCount ? count : nil, host: host)
            resetCommandTracking()
            return true

        case "/":
            host.vimBeginSearch(direction: .forward)
            resetCommandTracking()
            return true

        case "?":
            host.vimBeginSearch(direction: .backward)
            resetCommandTracking()
            return true

        default:
            let _ = coreKeys
            resetCommandTracking()
            return true
        }
    }

    // MARK: - Visual Mode Commands

    private func handleVisualCommand(key: String, host: VimHost) -> Bool {
        let isLinewise = (mode == .visualLine)
        switch key {
        case "v":
            if mode == .visual {
                exitVisualToNormal(host: host)
            } else {
                mode = .visual
                syncVisualSelection(host: host)
            }
            resetCommandTracking()
            return true

        case "V":
            if mode == .visualLine {
                exitVisualToNormal(host: host)
            } else {
                mode = .visualLine
                syncVisualSelection(host: host)
            }
            resetCommandTracking()
            return true

        case "o", "O":
            swap(&visualAnchor, &visualHead)
            syncVisualSelection(host: host)
            resetCommandTracking()
            return true

        case "d", "x", "X":
            executeVisualOperator(.delete, isLinewise: isLinewise, host: host)
            resetCommandTracking()
            return true

        case "c", "s", "S", "C":
            executeVisualOperator(.change, isLinewise: isLinewise || key == "S", host: host)
            resetCommandTracking()
            return true

        case "y", "Y":
            executeVisualOperator(.yank, isLinewise: isLinewise || key == "Y", host: host)
            resetCommandTracking()
            return true

        case ">":
            executeVisualOperator(.indent, isLinewise: true, host: host)
            resetCommandTracking()
            return true

        case "<":
            executeVisualOperator(.outdent, isLinewise: true, host: host)
            resetCommandTracking()
            return true

        case "~":
            executeVisualOperator(.toggleCase, isLinewise: isLinewise, host: host)
            resetCommandTracking()
            return true

        case "u":
            executeVisualOperator(.lowercase, isLinewise: isLinewise, host: host)
            resetCommandTracking()
            return true

        case "U":
            executeVisualOperator(.uppercase, isLinewise: isLinewise, host: host)
            resetCommandTracking()
            return true

        case "J":
            let range = resolvedVisualRange(isLinewise: true, in: host.vimNSString)
            lastVisualSnapshot = (mode, visualAnchor, visualHead)
            mode = .normal
            joinLinesInRange(range, trimSpaces: true, host: host)
            resetCommandTracking()
            return true

        case "p", "P":
            pasteOverVisualSelection(isLinewise: isLinewise, swapClipboard: key == "p", host: host)
            resetCommandTracking()
            return true

        case "/":
            host.vimBeginSearch(direction: .forward)
            resetCommandTracking()
            return true

        case "?":
            host.vimBeginSearch(direction: .backward)
            resetCommandTracking()
            return true

        default:
            resetCommandTracking()
            return true
        }
    }

    private func exitVisualToNormal(host: VimHost) {
        lastVisualSnapshot = (mode, visualAnchor, visualHead)
        mode = .normal
        let clamped = clampNormalLocation(visualHead, in: host.vimNSString)
        setHostSelection(NSRange(location: clamped, length: 0))
    }

    // MARK: - Prefix Handlers (`g`, `z`, `[`, `]`, `r`, `f`/`t`)

    private func handleGPrefix(_ input: VimKeyInput, host: VimHost) -> Bool {
        prefix = .none
        guard case .char(let key) = input else {
            resetCommandTracking()
            return true
        }
        let ns = host.vimNSString
        let count = effectiveCount

        switch key {
        case "g":
            let targetLine = hasExplicitCount ? count : 1
            let loc = locationForOneBasedLine(targetLine, in: ns)
            let motion = ResolvedMotion(target: loc, style: .linewise, preservesDesiredColumn: false)
            applyMotion(motion, host: host)
            return true

        case "j":
            var px = preferredVisualX
            let cursor = currentCursorLocation(in: ns)
            if let next = host.vimVisualLineVerticalTarget(from: cursor, deltaLines: count, preferredX: &px) {
                preferredVisualX = px
                applyMotion(ResolvedMotion(target: next, style: .charExclusive, preservesDesiredColumn: true), host: host)
            } else {
                applyMotion(resolveVerticalMotion(delta: 1, count: count, host: host), host: host)
            }
            return true

        case "k":
            var px = preferredVisualX
            let cursor = currentCursorLocation(in: ns)
            if let next = host.vimVisualLineVerticalTarget(from: cursor, deltaLines: -count, preferredX: &px) {
                preferredVisualX = px
                applyMotion(ResolvedMotion(target: next, style: .charExclusive, preservesDesiredColumn: true), host: host)
            } else {
                applyMotion(resolveVerticalMotion(delta: -1, count: count, host: host), host: host)
            }
            return true

        case "0":
            let cursor = currentCursorLocation(in: ns)
            let target = host.vimVisualLineBoundary(from: cursor, kind: .start) ?? lineInfo(for: cursor, in: ns).start
            applyMotion(ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false), host: host)
            return true

        case "^":
            let cursor = currentCursorLocation(in: ns)
            let target = host.vimVisualLineBoundary(from: cursor, kind: .firstNonBlank) ?? firstNonBlank(on: lineInfo(for: cursor, in: ns), in: ns)
            applyMotion(ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false), host: host)
            return true

        case "$":
            let cursor = currentCursorLocation(in: ns)
            let target = host.vimVisualLineBoundary(from: cursor, kind: .end) ?? lineInfo(for: cursor, in: ns).contentEnd
            applyMotion(ResolvedMotion(target: target, style: .charInclusive, preservesDesiredColumn: false), host: host)
            return true

        case "e":
            let cursor = currentCursorLocation(in: ns)
            let target = moveBackwardWordEnd(from: cursor, count: count, bigWord: false, in: ns)
            applyMotion(ResolvedMotion(target: target, style: .charInclusive, preservesDesiredColumn: false), host: host)
            return true

        case "E":
            let cursor = currentCursorLocation(in: ns)
            let target = moveBackwardWordEnd(from: cursor, count: count, bigWord: true, in: ns)
            applyMotion(ResolvedMotion(target: target, style: .charInclusive, preservesDesiredColumn: false), host: host)
            return true

        case "v":
            if pendingOperator == nil, let snap = lastVisualSnapshot {
                let len = ns.length
                if len > 0 {
                    mode = snap.mode
                    visualAnchor = min(snap.anchor, len - 1)
                    visualHead = min(snap.head, len - 1)
                    syncVisualSelection(host: host)
                }
            }
            resetCommandTracking()
            return true

        case "i":
            if pendingOperator == nil && mode == .normal {
                let loc = min(lastInsertExitLocation ?? currentCursorLocation(in: ns), ns.length)
                let before = NSRange(location: currentCursorLocation(in: ns), length: 0)
                setHostSelection(NSRange(location: loc, length: 0))
                beginInsertSession(entryKeys: [.char("i")], count: 1, cursorBeforeEntry: before, host: host)
            }
            resetCommandTracking()
            return true

        case "J":
            if pendingOperator == nil && mode == .normal {
                let joinCount = max(2, hasExplicitCount ? count : 2)
                joinLines(count: joinCount, trimSpaces: false, host: host)
                recordNormalRepeat(coreKeys: [.char("g"), .char("J")], count: joinCount)
            }
            resetCommandTracking()
            return true

        case "u":
            if mode == .normal && pendingOperator == nil {
                pendingOperator = .lowercase
                return true
            }
            resetCommandTracking()
            return true

        case "U":
            if mode == .normal && pendingOperator == nil {
                pendingOperator = .uppercase
                return true
            }
            resetCommandTracking()
            return true

        case "~":
            if mode == .normal && pendingOperator == nil {
                pendingOperator = .toggleCase
                return true
            }
            resetCommandTracking()
            return true

        case "d", "f":
            if pendingOperator == nil {
                _ = host.vimOpenWikiLinkAtCursor(inNewWindow: false)
            }
            resetCommandTracking()
            return true

        case "F":
            if pendingOperator == nil {
                _ = host.vimOpenWikiLinkAtCursor(inNewWindow: true)
            }
            resetCommandTracking()
            return true

        case "x":
            if pendingOperator == nil {
                let targetRange: NSRange
                if mode == .visual || mode == .visualLine {
                    targetRange = resolvedVisualRange(isLinewise: true, in: ns)
                    lastVisualSnapshot = (mode, visualAnchor, visualHead)
                    mode = .normal
                } else {
                    targetRange = NSRange(location: currentCursorLocation(in: ns), length: 0)
                }
                if host.vimToggleTaskAt(range: targetRange) {
                    recordNormalRepeat(coreKeys: [.char("g"), .char("x")], count: 1)
                }
                let clamped = clampNormalLocation(host.vimSelectedRange.location, in: host.vimNSString)
                setHostSelection(NSRange(location: clamped, length: 0))
            }
            resetCommandTracking()
            return true

        default:
            resetCommandTracking()
            return true
        }
    }

    private func handleZPrefix(_ input: VimKeyInput, host: VimHost) -> Bool {
        prefix = .none
        guard case .char(let key) = input else {
            resetCommandTracking()
            return true
        }
        switch key {
        case "a":
            host.vimToggleFoldAtCursor()
        case "o":
            host.vimOpenFoldAtCursor()
        case "c":
            host.vimCloseFoldAtCursor()
        case "R":
            host.vimUnfoldAllHeadings()
        case "M":
            host.vimFoldAllHeadings()
        case "m", "r":
            host.vimCycleOutlineFolding()
        case "z", ".":
            host.vimScrollCursorLine(alignment: .center)
        case "t":
            host.vimScrollCursorLine(alignment: .top)
        case "b":
            host.vimScrollCursorLine(alignment: .bottom)
        default:
            break
        }
        resetCommandTracking()
        return true
    }

    private func handleBracketPrefix(open: Bool, input: VimKeyInput, host: VimHost) -> Bool {
        prefix = .none
        guard case .char(let key) = input else {
            resetCommandTracking()
            return true
        }
        if (open && key == "[") || (!open && key == "]") {
            let headings = host.vimHeadingLocations()
            let ns = host.vimNSString
            let cursor = currentCursorLocation(in: ns)
            let count = effectiveCount
            if !headings.isEmpty {
                var target = cursor
                for _ in 0..<count {
                    if open {
                        if let prev = headings.last(where: { $0 < target }) {
                            target = prev
                        } else {
                            target = 0
                            break
                        }
                    } else {
                        if let next = headings.first(where: { $0 > target }) {
                            target = next
                        } else {
                            target = ns.length > 0 ? lineInfo(for: ns.length - 1, in: ns).start : 0
                            break
                        }
                    }
                }
                applyMotion(ResolvedMotion(target: target, style: .linewise, preservesDesiredColumn: false), host: host)
                return true
            }
        }
        resetCommandTracking()
        return true
    }

    private func finishReplaceSingleChar(_ input: VimKeyInput, host: VimHost) -> Bool {
        prefix = .none
        let replacementUnit: String
        switch input {
        case .returnKey:
            replacementUnit = "\n"
        case .tab:
            replacementUnit = "\t"
        case .char(let s) where !s.isEmpty:
            replacementUnit = s
        default:
            resetCommandTracking()
            host.vimDidUpdateState()
            return true
        }

        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let line = lineInfo(for: cursor, in: ns)
        let count = effectiveCount

        var pos = cursor
        var available = 0
        while available < count && pos < line.contentEnd {
            pos = nextCharLocation(after: pos, in: ns)
            available += 1
        }
        if available == count && pos > cursor {
            let rep = replacementUnit == "\n" ? "\n" : String(repeating: replacementUnit, count: count)
            let repNS = rep as NSString
            let lastCharLoc = repNS.length > 0 ? prevCharStart(before: repNS.length, in: repNS) : 0
            let afterLoc = cursor + lastCharLoc
            host.vimReplace(
                in: NSRange(location: cursor, length: pos - cursor),
                with: rep,
                selectedRangeAfter: NSRange(location: afterLoc, length: 0)
            )
            let clamped = clampNormalLocation(afterLoc, in: host.vimNSString)
            setHostSelection(NSRange(location: clamped, length: 0))
            recordNormalRepeat(coreKeys: [.char("r"), input], count: count)
        }
        desiredColumn = nil
        resetCommandTracking()
        host.vimDidUpdateState()
        return true
    }

    private func finishFindChar(_ kind: FindSpec.Kind, input: VimKeyInput, host: VimHost) -> Bool {
        prefix = .none
        guard case .char(let target) = input, !target.isEmpty else {
            resetCommandTracking()
            host.vimDidUpdateState()
            return true
        }
        currentCommandKeys.append(input)
        let spec = FindSpec(kind: kind, target: target)
        lastFindSpec = spec
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        if let loc = findCharacterOnLine(spec: spec, from: cursor, count: effectiveCount, isRepeat: false, in: ns) {
            let style: MotionStyle = (kind == .findForward || kind == .tillForward) ? .charInclusive : .charExclusive
            applyMotion(ResolvedMotion(target: loc, style: style, preservesDesiredColumn: false), host: host)
        } else {
            resetCommandTracking()
        }
        host.vimDidUpdateState()
        return true
    }

    private func handleCtrlCommand(_ ctrlChar: Character, host: VimHost) -> Bool {
        switch ctrlChar {
        case "r":
            if mode == .normal && pendingOperator == nil {
                performRedo(count: effectiveCount, host: host)
            }
            resetCommandTracking()
            return true

        case "d":
            scrollHalfPages(effectiveCount, host: host)
            resetCommandTracking()
            return true

        case "u":
            scrollHalfPages(-effectiveCount, host: host)
            resetCommandTracking()
            return true

        case "f":
            scrollHalfPages(effectiveCount * 2, host: host)
            resetCommandTracking()
            return true

        case "b":
            scrollHalfPages(-effectiveCount * 2, host: host)
            resetCommandTracking()
            return true

        case "l":
            if pendingOperator == nil {
                let ns = host.vimNSString
                let targetRange: NSRange
                if mode == .visual || mode == .visualLine {
                    targetRange = resolvedVisualRange(isLinewise: true, in: ns)
                    lastVisualSnapshot = (mode, visualAnchor, visualHead)
                    mode = .normal
                } else {
                    targetRange = NSRange(location: currentCursorLocation(in: ns), length: 0)
                }
                if host.vimToggleTaskAt(range: targetRange) {
                    recordNormalRepeat(coreKeys: [.ctrl("l")], count: 1)
                }
                let clamped = clampNormalLocation(host.vimSelectedRange.location, in: host.vimNSString)
                setHostSelection(NSRange(location: clamped, length: 0))
            }
            resetCommandTracking()
            return true

        default:
            resetCommandTracking()
            return true
        }
    }

    private func handleReturnInModal(host: VimHost) -> Bool {
        if pendingOperator == nil && mode == .normal {
            if host.vimOpenWikiLinkAtCursor(inNewWindow: false) {
                resetCommandTracking()
                return true
            }
            let ns = host.vimNSString
            let cursor = currentCursorLocation(in: ns)
            if isCursorOnTaskCheckbox(at: cursor, in: ns) {
                if host.vimToggleTaskAt(range: NSRange(location: cursor, length: 0)) {
                    recordNormalRepeat(coreKeys: [.ctrl("l")], count: 1)
                }
                resetCommandTracking()
                return true
            }
        }
        let motion = resolveVerticalFirstNonBlankMotion(delta: 1, count: effectiveCount, host: host)
        applyMotion(motion, host: host)
        return true
    }

    private func isCursorOnTaskCheckbox(at cursor: Int, in ns: NSString) -> Bool {
        let line = lineInfo(for: cursor, in: ns)
        guard line.contentEnd > line.start else { return false }
        let lineStr = ns.substring(with: NSRange(location: line.start, length: line.contentEnd - line.start))
        guard let bracketRange = lineStr.range(of: #"^\s*(?:[-*+]|\d+\.)\s+\[[ xX]\]"#, options: .regularExpression) else {
            return false
        }
        let prefixLen = (String(lineStr[..<bracketRange.upperBound]) as NSString).length
        return cursor <= line.start + prefixLen
    }

    // MARK: - Direct Motion Resolution

    private func resolveDirectMotion(for key: String, host: VimHost) -> ResolvedMotion? {
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let count = effectiveCount

        switch key {
        case "h":
            return resolveHorizontalMotion(delta: -1, count: count, in: ns)
        case "l", " ":
            return resolveHorizontalMotion(delta: 1, count: count, in: ns)
        case "j":
            return resolveVerticalMotion(delta: 1, count: count, host: host)
        case "k":
            return resolveVerticalMotion(delta: -1, count: count, host: host)
        case "+":
            return resolveVerticalFirstNonBlankMotion(delta: 1, count: count, host: host)
        case "-":
            return resolveVerticalFirstNonBlankMotion(delta: -1, count: count, host: host)
        case "0":
            let line = lineInfo(for: cursor, in: ns)
            return ResolvedMotion(target: line.start, style: .charExclusive, preservesDesiredColumn: false)
        case "^":
            let line = lineInfo(for: cursor, in: ns)
            return ResolvedMotion(target: firstNonBlank(on: line, in: ns), style: .charExclusive, preservesDesiredColumn: false)
        case "_":
            if count > 1 {
                return resolveVerticalFirstNonBlankMotion(delta: 1, count: count - 1, host: host)
            }
            let line = lineInfo(for: cursor, in: ns)
            return ResolvedMotion(target: firstNonBlank(on: line, in: ns), style: .charExclusive, preservesDesiredColumn: false)
        case "$":
            var line = lineInfo(for: cursor, in: ns)
            if count > 1 {
                let stepped = stepVisibleLines(from: cursor, delta: count - 1, in: ns, host: host)
                line = lineInfo(for: stepped, in: ns)
            }
            desiredColumn = Int.max
            let endTarget: Int
            if pendingOperator != nil || mode == .visual || mode == .visualLine {
                endTarget = line.contentEnd
            } else {
                endTarget = line.contentEnd > line.start ? prevCharStart(before: line.contentEnd, in: ns) : line.start
            }
            return ResolvedMotion(target: endTarget, style: .charExclusive, preservesDesiredColumn: true)

        case "w":
            if pendingOperator == .change, cursor < ns.length,
               charClass(at: cursor, in: ns, bigWord: false) != .whitespace,
               charClass(at: cursor, in: ns, bigWord: false) != .newline {
                let target = moveWordEnd(from: cursor, count: count, bigWord: false, in: ns)
                return ResolvedMotion(target: target, style: .charInclusive, preservesDesiredColumn: false)
            }
            let target = moveWordForward(from: cursor, count: count, bigWord: false, forOperator: pendingOperator != nil, in: ns)
            return ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false)

        case "W":
            if pendingOperator == .change, cursor < ns.length,
               charClass(at: cursor, in: ns, bigWord: true) != .whitespace,
               charClass(at: cursor, in: ns, bigWord: true) != .newline {
                let target = moveWordEnd(from: cursor, count: count, bigWord: true, in: ns)
                return ResolvedMotion(target: target, style: .charInclusive, preservesDesiredColumn: false)
            }
            let target = moveWordForward(from: cursor, count: count, bigWord: true, forOperator: pendingOperator != nil, in: ns)
            return ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false)

        case "b":
            let target = moveWordBackward(from: cursor, count: count, bigWord: false, in: ns)
            return ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false)

        case "B":
            let target = moveWordBackward(from: cursor, count: count, bigWord: true, in: ns)
            return ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false)

        case "e":
            let target = moveWordEnd(from: cursor, count: count, bigWord: false, in: ns)
            return ResolvedMotion(target: target, style: .charInclusive, preservesDesiredColumn: false)

        case "E":
            let target = moveWordEnd(from: cursor, count: count, bigWord: true, in: ns)
            return ResolvedMotion(target: target, style: .charInclusive, preservesDesiredColumn: false)

        case "{":
            let target = moveParagraph(from: cursor, count: count, forward: false, in: ns)
            return ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false)

        case "}":
            let target = moveParagraph(from: cursor, count: count, forward: true, in: ns)
            return ResolvedMotion(target: target, style: .charExclusive, preservesDesiredColumn: false)

        case "G":
            if hasExplicitCount {
                let loc = locationForOneBasedLine(count, in: ns)
                return ResolvedMotion(target: loc, style: .linewise, preservesDesiredColumn: false)
            }
            let lastStart = lastLineStart(in: ns)
            let lastLine = lineInfo(for: lastStart, in: ns)
            return ResolvedMotion(target: firstNonBlank(on: lastLine, in: ns), style: .linewise, preservesDesiredColumn: false)

        case "%":
            if let match = findMatchingPair(from: cursor, in: ns) {
                return ResolvedMotion(target: match, style: .charInclusive, preservesDesiredColumn: false)
            }
            resetCommandTracking()
            return nil

        case ";":
            if let spec = lastFindSpec,
               let loc = findCharacterOnLine(spec: spec, from: cursor, count: count, isRepeat: true, in: ns) {
                let style: MotionStyle = (spec.kind == .findForward || spec.kind == .tillForward) ? .charInclusive : .charExclusive
                return ResolvedMotion(target: loc, style: style, preservesDesiredColumn: false)
            }
            resetCommandTracking()
            return nil

        case ",":
            if let spec = lastFindSpec {
                let inverted = FindSpec(kind: spec.kind.inverted, target: spec.target)
                if let loc = findCharacterOnLine(spec: inverted, from: cursor, count: count, isRepeat: true, in: ns) {
                    let style: MotionStyle = (inverted.kind == .findForward || inverted.kind == .tillForward) ? .charInclusive : .charExclusive
                    return ResolvedMotion(target: loc, style: style, preservesDesiredColumn: false)
                }
            }
            resetCommandTracking()
            return nil

        case "H":
            if let target = host.vimViewportLineTarget(.top) {
                let line = lineInfo(for: target, in: ns)
                return ResolvedMotion(target: firstNonBlank(on: line, in: ns), style: .linewise, preservesDesiredColumn: false)
            }
            return nil

        case "M":
            if let target = host.vimViewportLineTarget(.middle) {
                let line = lineInfo(for: target, in: ns)
                return ResolvedMotion(target: firstNonBlank(on: line, in: ns), style: .linewise, preservesDesiredColumn: false)
            }
            return nil

        case "L":
            if let target = host.vimViewportLineTarget(.bottom) {
                let line = lineInfo(for: target, in: ns)
                return ResolvedMotion(target: firstNonBlank(on: line, in: ns), style: .linewise, preservesDesiredColumn: false)
            }
            return nil

        case "n":
            if let match = host.vimFindMatchLocation(from: cursor, reverse: false, count: count, inclusiveCurrent: false) {
                return ResolvedMotion(target: match.location, style: .charExclusive, preservesDesiredColumn: false)
            }
            resetCommandTracking()
            return nil

        case "N":
            if let match = host.vimFindMatchLocation(from: cursor, reverse: true, count: count, inclusiveCurrent: false) {
                return ResolvedMotion(target: match.location, style: .charExclusive, preservesDesiredColumn: false)
            }
            resetCommandTracking()
            return nil

        case "*":
            if let word = wordUnderCursor(at: cursor, in: ns),
               let match = host.vimSearchWord(word, forward: true, count: count) {
                return ResolvedMotion(target: match.location, style: .charExclusive, preservesDesiredColumn: false)
            }
            resetCommandTracking()
            return nil

        case "#":
            if let word = wordUnderCursor(at: cursor, in: ns),
               let match = host.vimSearchWord(word, forward: false, count: count) {
                return ResolvedMotion(target: match.location, style: .charExclusive, preservesDesiredColumn: false)
            }
            resetCommandTracking()
            return nil

        default:
            return nil
        }
    }

    // MARK: - Applying Motions & Operators

    private func applyMotion(_ motion: ResolvedMotion, forKey key: String? = nil, host: VimHost) {
        let ns = host.vimNSString
        if !motion.preservesDesiredColumn {
            desiredColumn = nil
            preferredVisualX = nil
        } else if key != "j" && key != "k" && key != "$" {
            // Keep preferredVisualX only for gj/gk
        }
        if key == "j" || key == "k" {
            preferredVisualX = nil
        }

        if let op = pendingOperator {
            let start = currentCursorLocation(in: ns)
            executeOperatorWithMotion(op, from: start, motion: motion, host: host)
            resetCommandTracking()
            return
        }

        switch mode {
        case .normal:
            let clamped = clampNormalLocation(motion.target, in: ns)
            setHostSelection(NSRange(location: clamped, length: 0))
            host.vimEnsureCaretVisible(typewriter: false)
        case .visual, .visualLine:
            let clamped = mode == .visualLine
                ? min(max(0, motion.target), ns.length)
                : clampVisualLocation(motion.target, in: ns)
            visualHead = clamped
            syncVisualSelection(host: host)
            host.vimEnsureCaretVisible(typewriter: false)
        case .insert:
            break
        }
        resetCommandTracking()
    }

    private func executeOperatorWithMotion(_ op: OperatorKind, from start: Int, motion: ResolvedMotion, host: VimHost) {
        let ns = host.vimNSString
        let totalCount = effectiveCount
        let coreKeys = stripDigits(from: currentCommandKeys)

        if motion.style == .linewise {
            let lo = min(start, motion.target)
            let hi = max(start, motion.target)
            let firstLine = lineInfo(for: lo, in: ns)
            let lastLine = lineInfo(for: hi, in: ns)
            let span = NSRange(location: firstLine.start, length: lastLine.fullEnd - firstLine.start)
            applyOperatorToLineSpan(op, lineSpan: span, coreKeys: coreKeys, count: totalCount, host: host)
            return
        }

        let lo: Int
        let hi: Int
        if start <= motion.target {
            lo = start
            if motion.style == .charInclusive {
                hi = motion.target < ns.length ? nextCharLocation(after: motion.target, in: ns) : ns.length
            } else {
                hi = motion.target
            }
        } else {
            lo = motion.target
            if motion.style == .charInclusive {
                hi = start < ns.length ? nextCharLocation(after: start, in: ns) : ns.length
            } else {
                hi = start
            }
        }
        let targetRange = NSRange(location: lo, length: max(0, hi - lo))
        applyOperatorToCharRange(op, range: targetRange, coreKeys: coreKeys, count: totalCount, host: host)
    }

    private func executeLinewiseOperator(
        _ op: OperatorKind,
        count: Int,
        host: VimHost,
        overrideEntryKeys: [VimKeyInput]? = nil
    ) {
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let firstLine = lineInfo(for: cursor, in: ns)
        var endLine = firstLine
        var pos = firstLine.start
        for _ in 1..<count {
            let nextPos = stepVisibleLines(from: pos, delta: 1, in: ns, host: host)
            if nextPos == pos { break }
            pos = nextPos
            endLine = lineInfo(for: pos, in: ns)
        }
        let span = NSRange(location: firstLine.start, length: endLine.fullEnd - firstLine.start)
        let keys = overrideEntryKeys ?? stripDigits(from: currentCommandKeys)
        applyOperatorToLineSpan(op, lineSpan: span, coreKeys: keys, count: count, host: host)
        resetCommandTracking()
    }

    private func applyOperatorToLineSpan(
        _ op: OperatorKind,
        lineSpan: NSRange,
        coreKeys: [VimKeyInput],
        count: Int,
        host: VimHost
    ) {
        let ns = host.vimNSString
        let cursorBefore = NSRange(location: currentCursorLocation(in: ns), length: 0)

        switch op {
        case .yank:
            guard lineSpan.length > 0 else { return }
            var text = ns.substring(with: lineSpan)
            if !text.hasSuffix("\n") { text += "\n" }
            VimClipboard.write(text, style: .linewise)
            let targetLoc = clampNormalLocation(lineSpan.location, in: ns)
            setHostSelection(NSRange(location: targetLoc, length: 0))
            let linesYanked = max(1, text.filter { $0 == "\n" }.count)
            host.vimSetStatus(linesYanked == 1 ? "Yanked line" : "Yanked \(linesYanked) lines")

        case .delete:
            if ns.length == 0 { return }
            var rawText = ns.substring(with: lineSpan)
            if !rawText.hasSuffix("\n") { rawText += "\n" }
            VimClipboard.write(rawText, style: .linewise)

            var deleteRange = lineSpan
            // If deleting up to EOF without a trailing newline and there is a preceding newline, consume it cleanly.
            if NSMaxRange(deleteRange) == ns.length,
               deleteRange.location > 0,
               (deleteRange.length == 0 || ns.character(at: NSMaxRange(deleteRange) - 1) != 10),
               ns.character(at: deleteRange.location - 1) == 10 {
                deleteRange = NSRange(location: deleteRange.location - 1, length: deleteRange.length + 1)
            }
            host.vimReplace(in: deleteRange, with: "", selectedRangeAfter: NSRange(location: min(lineSpan.location, max(0, ns.length - deleteRange.length)), length: 0))
            let updatedNS = host.vimNSString
            let landedLine = lineInfo(for: min(lineSpan.location, updatedNS.length), in: updatedNS)
            let landed = clampNormalLocation(firstNonBlank(on: landedLine, in: updatedNS), in: updatedNS)
            setHostSelection(NSRange(location: landed, length: 0))
            recordNormalRepeat(coreKeys: coreKeys, count: count)

        case .change:
            if insertUndoTracker == nil && !isReplayingRepeat {
                insertUndoTracker = InsertUndoTracker(initialSelection: cursorBefore)
            }
            var rawText = lineSpan.length > 0 ? ns.substring(with: lineSpan) : ""
            if !rawText.hasSuffix("\n") { rawText += "\n" }
            VimClipboard.write(rawText, style: .linewise)

            let hadTrailingNL = lineSpan.length > 0 && ns.character(at: NSMaxRange(lineSpan) - 1) == 10
            let firstLine = lineInfo(for: lineSpan.location, in: ns)
            let indent = leadingWhitespace(on: firstLine, in: ns)
            let replacement = hadTrailingNL ? (indent + "\n") : indent
            let caretAfter = lineSpan.location + (indent as NSString).length
            host.vimReplace(in: lineSpan, with: replacement, selectedRangeAfter: NSRange(location: caretAfter, length: 0))
            beginInsertSession(entryKeys: coreKeys, count: count, cursorBeforeEntry: cursorBefore, host: host)

        case .indent:
            indentOrOutdentLines(in: lineSpan, indent: true, host: host)
            recordNormalRepeat(coreKeys: coreKeys, count: count)

        case .outdent:
            indentOrOutdentLines(in: lineSpan, indent: false, host: host)
            recordNormalRepeat(coreKeys: coreKeys, count: count)

        case .lowercase, .uppercase, .toggleCase:
            transformCase(in: lineSpan, op: op, host: host)
            recordNormalRepeat(coreKeys: coreKeys, count: count)
        }
        desiredColumn = nil
    }

    private func applyOperatorToCharRange(
        _ op: OperatorKind,
        range: NSRange,
        coreKeys: [VimKeyInput],
        count: Int,
        host: VimHost
    ) {
        let ns = host.vimNSString
        let cursorBefore = NSRange(location: currentCursorLocation(in: ns), length: 0)

        switch op {
        case .yank:
            guard range.length > 0 else { return }
            let text = ns.substring(with: range)
            VimClipboard.write(text, style: .charwise)
            let landed = clampNormalLocation(range.location, in: ns)
            setHostSelection(NSRange(location: landed, length: 0))
            host.vimSetStatus("Yanked")

        case .delete:
            guard range.length > 0 else { return }
            VimClipboard.write(ns.substring(with: range), style: .charwise)
            host.vimReplace(in: range, with: "", selectedRangeAfter: NSRange(location: range.location, length: 0))
            let clamped = clampNormalLocation(range.location, in: host.vimNSString)
            setHostSelection(NSRange(location: clamped, length: 0))
            recordNormalRepeat(coreKeys: coreKeys, count: count)

        case .change:
            if insertUndoTracker == nil && !isReplayingRepeat {
                insertUndoTracker = InsertUndoTracker(initialSelection: cursorBefore)
            }
            if range.length > 0 {
                VimClipboard.write(ns.substring(with: range), style: .charwise)
                host.vimReplace(in: range, with: "", selectedRangeAfter: NSRange(location: range.location, length: 0))
            } else {
                setHostSelection(NSRange(location: range.location, length: 0))
            }
            beginInsertSession(entryKeys: coreKeys, count: count, cursorBeforeEntry: cursorBefore, host: host)

        case .indent:
            let lineSpan = ns.lineRange(for: range)
            indentOrOutdentLines(in: lineSpan, indent: true, host: host)
            recordNormalRepeat(coreKeys: coreKeys, count: count)

        case .outdent:
            let lineSpan = ns.lineRange(for: range)
            indentOrOutdentLines(in: lineSpan, indent: false, host: host)
            recordNormalRepeat(coreKeys: coreKeys, count: count)

        case .lowercase, .uppercase, .toggleCase:
            transformCase(in: range, op: op, host: host)
            recordNormalRepeat(coreKeys: coreKeys, count: count)
        }
        desiredColumn = nil
    }

    private func executeVisualOperator(_ op: OperatorKind, isLinewise: Bool, host: VimHost) {
        let ns = host.vimNSString
        let range = resolvedVisualRange(isLinewise: isLinewise, in: ns)
        lastVisualSnapshot = (mode, visualAnchor, visualHead)
        let lineCount = max(1, ns.substring(with: range).components(separatedBy: "\n").count - (range.length > 0 && ns.character(at: NSMaxRange(range) - 1) == 10 ? 1 : 0))

        mode = .normal
        if isLinewise {
            let coreKeys: [VimKeyInput]
            switch op {
            case .delete: coreKeys = [.char("d"), .char("d")]
            case .change: coreKeys = [.char("c"), .char("c")]
            case .indent: coreKeys = [.char(">"), .char(">")]
            case .outdent: coreKeys = [.char("<"), .char("<")]
            default: coreKeys = []
            }
            applyOperatorToLineSpan(op, lineSpan: range, coreKeys: coreKeys, count: lineCount, host: host)
        } else {
            if !isReplayingRepeat, op != .yank && op != .change {
                lastRepeatable = .visualEdit(isLinewise: false, spanLength: range.length, lineCount: 1, op: op, replacementText: nil)
            }
            applyOperatorToCharRange(op, range: range, coreKeys: op == .change ? [.char("s")] : [.char("x")], count: max(1, range.length), host: host)
        }
    }

    // MARK: - Text Objects (`iw`/`aw`, `iW`/`aW`, `ip`/`ap`, Quotes, Delimiters)

    private func handleTextObjectTarget(around: Bool, input: VimKeyInput, host: VimHost) -> Bool {
        prefix = .none
        guard case .char(let key) = input else {
            resetCommandTracking()
            return true
        }
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let count = effectiveCount

        guard let objResult = resolveTextObject(key: key, around: around, from: cursor, count: count, in: ns) else {
            resetCommandTracking()
            return true
        }

        if let op = pendingOperator {
            let coreKeys = stripDigits(from: currentCommandKeys)
            if objResult.isLinewise {
                applyOperatorToLineSpan(op, lineSpan: objResult.range, coreKeys: coreKeys, count: count, host: host)
            } else {
                applyOperatorToCharRange(op, range: objResult.range, coreKeys: coreKeys, count: count, host: host)
            }
            resetCommandTracking()
            return true
        }

        if mode == .visual || mode == .visualLine {
            if objResult.isLinewise {
                mode = .visualLine
            } else {
                mode = .visual
            }
            visualAnchor = objResult.range.location
            if objResult.range.length > 0 {
                visualHead = prevCharStart(before: NSMaxRange(objResult.range), in: ns)
            } else {
                visualHead = objResult.range.location
            }
            syncVisualSelection(host: host)
        }
        resetCommandTracking()
        return true
    }

    private func resolveTextObject(
        key: String,
        around: Bool,
        from cursor: Int,
        count: Int,
        in ns: NSString
    ) -> (range: NSRange, isLinewise: Bool)? {
        guard ns.length > 0 else { return nil }
        switch key {
        case "w":
            return wordTextObject(at: cursor, around: around, bigWord: false, count: count, in: ns).map { ($0, false) }
        case "W":
            return wordTextObject(at: cursor, around: around, bigWord: true, count: count, in: ns).map { ($0, false) }
        case "p":
            return paragraphTextObject(at: cursor, around: around, in: ns).map { ($0, true) }
        case "\"":
            return quoteTextObject(quote: 0x22, at: cursor, around: around, allowEscape: true, in: ns).map { ($0, false) }
        case "'":
            return quoteTextObject(quote: 0x27, at: cursor, around: around, allowEscape: true, in: ns).map { ($0, false) }
        case "`":
            return quoteTextObject(quote: 0x60, at: cursor, around: around, allowEscape: false, in: ns).map { ($0, false) }
        case "(", ")", "b":
            return pairTextObject(open: 0x28, close: 0x29, at: cursor, around: around, count: count, in: ns).map { ($0, false) }
        case "[", "]":
            return pairTextObject(open: 0x5B, close: 0x5D, at: cursor, around: around, count: count, in: ns).map { ($0, false) }
        case "{", "}", "B":
            return pairTextObject(open: 0x7B, close: 0x7D, at: cursor, around: around, count: count, in: ns).map { ($0, false) }
        case "<", ">":
            return pairTextObject(open: 0x3C, close: 0x3E, at: cursor, around: around, count: count, in: ns).map { ($0, false) }
        default:
            return nil
        }
    }

    private func wordTextObject(at cursor: Int, around: Bool, bigWord: Bool, count: Int, in ns: NSString) -> NSRange? {
        let clamped = min(cursor, ns.length - 1)
        let line = lineInfo(for: clamped, in: ns)
        guard line.contentEnd > line.start else { return NSRange(location: line.start, length: 0) }
        let probe = min(clamped, prevCharStart(before: line.contentEnd, in: ns))
        let startClass = charClass(at: probe, in: ns, bigWord: bigWord)

        var lo = probe
        while lo > line.start {
            let prev = prevCharStart(before: lo, in: ns)
            if charClass(at: prev, in: ns, bigWord: bigWord) == startClass {
                lo = prev
            } else {
                break
            }
        }

        var hi = nextCharLocation(after: probe, in: ns)
        while hi < line.contentEnd && charClass(at: hi, in: ns, bigWord: bigWord) == startClass {
            hi = nextCharLocation(after: hi, in: ns)
        }

        for _ in 1..<count where hi < line.contentEnd {
            let c = charClass(at: hi, in: ns, bigWord: bigWord)
            while hi < line.contentEnd && charClass(at: hi, in: ns, bigWord: bigWord) == c {
                hi = nextCharLocation(after: hi, in: ns)
            }
        }

        if around {
            if startClass != .whitespace {
                var trail = hi
                while trail < line.contentEnd && charClass(at: trail, in: ns, bigWord: bigWord) == .whitespace {
                    trail = nextCharLocation(after: trail, in: ns)
                }
                if trail > hi {
                    hi = trail
                } else {
                    var lead = lo
                    while lead > line.start {
                        let prev = prevCharStart(before: lead, in: ns)
                        if charClass(at: prev, in: ns, bigWord: bigWord) == .whitespace {
                            lead = prev
                        } else {
                            break
                        }
                    }
                    lo = lead
                }
            } else {
                while hi < line.contentEnd && charClass(at: hi, in: ns, bigWord: bigWord) != .whitespace {
                    hi = nextCharLocation(after: hi, in: ns)
                }
            }
        }
        return NSRange(location: lo, length: max(0, hi - lo))
    }

    private func paragraphTextObject(at cursor: Int, around: Bool, in ns: NSString) -> NSRange? {
        let clamped = min(cursor, max(0, ns.length - 1))
        let curLine = lineInfo(for: clamped, in: ns)
        let startBlank = isBlankLine(curLine, in: ns)

        var loLine = curLine
        while loLine.start > 0 {
            let prevLine = lineInfo(for: loLine.start - 1, in: ns)
            if isBlankLine(prevLine, in: ns) == startBlank {
                loLine = prevLine
            } else {
                break
            }
        }

        var hiLine = curLine
        while hiLine.fullEnd < ns.length {
            let nextLine = lineInfo(for: hiLine.fullEnd, in: ns)
            if isBlankLine(nextLine, in: ns) == startBlank {
                hiLine = nextLine
            } else {
                break
            }
        }

        if around && !startBlank {
            var trailLine = hiLine
            var foundTrailingBlank = false
            while trailLine.fullEnd < ns.length {
                let nextLine = lineInfo(for: trailLine.fullEnd, in: ns)
                if isBlankLine(nextLine, in: ns) {
                    trailLine = nextLine
                    foundTrailingBlank = true
                } else {
                    break
                }
            }
            if foundTrailingBlank {
                hiLine = trailLine
            }
        }
        return NSRange(location: loLine.start, length: hiLine.fullEnd - loLine.start)
    }

    private func quoteTextObject(quote: unichar, at cursor: Int, around: Bool, allowEscape: Bool, in ns: NSString) -> NSRange? {
        let line = lineInfo(for: min(cursor, ns.length), in: ns)
        guard line.contentEnd > line.start else { return nil }
        var positions: [Int] = []
        var escaped = false
        for idx in line.start..<line.contentEnd {
            let ch = ns.character(at: idx)
            if allowEscape && escaped {
                escaped = false
                continue
            }
            if allowEscape && ch == 0x5C {
                escaped = true
                continue
            }
            if ch == quote {
                positions.append(idx)
            }
        }
        guard positions.count >= 2 else { return nil }

        // Check paired quotes first; if cursor is before a pair on the same line, jump into that pair.
        var pairIndex = 0
        while pairIndex + 1 < positions.count {
            let openPos = positions[pairIndex]
            let closePos = positions[pairIndex + 1]
            if cursor <= closePos {
                if around {
                    return NSRange(location: openPos, length: closePos - openPos + 1)
                } else {
                    return NSRange(location: openPos + 1, length: max(0, closePos - openPos - 1))
                }
            }
            pairIndex += 2
        }
        return nil
    }

    private func pairTextObject(open: unichar, close: unichar, at cursor: Int, around: Bool, count: Int, in ns: NSString) -> NSRange? {
        let len = ns.length
        guard len >= 2 else { return nil }
        let clamped = min(cursor, len - 1)
        let windowRadius = 32_768
        let minScan = max(0, clamped - windowRadius)
        let maxScan = min(len, clamped + windowRadius)

        func enclosingPair(around probe: Int, level: Int) -> (Int, Int)? {
            var targetDepth = level
            var bPos = probe
            if ns.character(at: probe) == open {
                if level == 1 {
                    var fwdDepth = 1
                    var f = probe + 1
                    while f < maxScan {
                        let c = ns.character(at: f)
                        if c == open { fwdDepth += 1 }
                        else if c == close {
                            fwdDepth -= 1
                            if fwdDepth == 0 { return (probe, f) }
                        }
                        f += 1
                    }
                    return nil
                }
                targetDepth -= 1
                bPos = probe - 1
            } else if ns.character(at: probe) == close {
                bPos = probe - 1
            }

            var depth = 0
            var foundOpen: Int?
            var p = bPos
            while p >= minScan {
                let c = ns.character(at: p)
                if c == close {
                    depth += 1
                } else if c == open {
                    if depth == 0 {
                        targetDepth -= 1
                        if targetDepth == 0 {
                            foundOpen = p
                            break
                        }
                    } else {
                        depth -= 1
                    }
                }
                if p == 0 { break }
                p -= 1
            }
            guard let openIdx = foundOpen else { return nil }
            var fwdDepth = 1
            var f = openIdx + 1
            while f < maxScan {
                let c = ns.character(at: f)
                if c == open {
                    fwdDepth += 1
                } else if c == close {
                    fwdDepth -= 1
                    if fwdDepth == 0 {
                        return (openIdx, f)
                    }
                }
                f += 1
            }
            return nil
        }

        var resolved = enclosingPair(around: clamped, level: max(1, count))
        if resolved == nil {
            // Seek forward on the current line for the next opening delimiter
            let line = lineInfo(for: clamped, in: ns)
            var seek = clamped
            while seek < line.contentEnd {
                if ns.character(at: seek) == open {
                    resolved = enclosingPair(around: seek, level: 1)
                    break
                }
                seek += 1
            }
        }
        guard let (openIdx, closeIdx) = resolved else { return nil }
        if around {
            return NSRange(location: openIdx, length: closeIdx - openIdx + 1)
        } else {
            return NSRange(location: openIdx + 1, length: max(0, closeIdx - openIdx - 1))
        }
    }

    // MARK: - Editing Operations (Paste, Join, Indent, Case, Undo/Redo, Dot-Repeat)

    private func pasteFromClipboard(after: Bool, count: Int, host: VimHost) {
        guard let clip = VimClipboard.read() else { return }
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let line = lineInfo(for: cursor, in: ns)

        if clip.style == .linewise {
            var clean = clip.text
            if clean.hasSuffix("\r\n") { clean.removeLast(2) }
            else if clean.hasSuffix("\n") || clean.hasSuffix("\r") { clean.removeLast() }
            let repeated = Array(repeating: clean, count: max(1, count)).joined(separator: "\n")

            if after {
                if line.fullEnd > line.contentEnd {
                    let payload = repeated + "\n"
                    let pasteStart = line.fullEnd
                    host.vimReplace(in: NSRange(location: pasteStart, length: 0), with: payload, selectedRangeAfter: NSRange(location: pasteStart, length: 0))
                    let updated = host.vimNSString
                    let newLine = lineInfo(for: pasteStart, in: updated)
                    let landed = clampNormalLocation(firstNonBlank(on: newLine, in: updated), in: updated)
                    setHostSelection(NSRange(location: landed, length: 0))
                } else {
                    let payload = "\n" + repeated
                    let pasteStart = line.contentEnd
                    let firstInsertedLineStart = pasteStart + 1
                    host.vimReplace(in: NSRange(location: pasteStart, length: 0), with: payload, selectedRangeAfter: NSRange(location: firstInsertedLineStart, length: 0))
                    let updated = host.vimNSString
                    let newLine = lineInfo(for: firstInsertedLineStart, in: updated)
                    let landed = clampNormalLocation(firstNonBlank(on: newLine, in: updated), in: updated)
                    setHostSelection(NSRange(location: landed, length: 0))
                }
            } else {
                let payload = repeated + "\n"
                let pasteStart = line.start
                host.vimReplace(in: NSRange(location: pasteStart, length: 0), with: payload, selectedRangeAfter: NSRange(location: pasteStart, length: 0))
                let updated = host.vimNSString
                let newLine = lineInfo(for: pasteStart, in: updated)
                let landed = clampNormalLocation(firstNonBlank(on: newLine, in: updated), in: updated)
                setHostSelection(NSRange(location: landed, length: 0))
            }
            host.vimEnsureCaretVisible(typewriter: false)
            return
        }

        // Characterwise paste
        let payload = String(repeating: clip.text, count: max(1, count))
        let payloadNS = payload as NSString
        let insertLoc: Int
        if after && cursor < line.contentEnd {
            insertLoc = nextCharLocation(after: cursor, in: ns)
        } else {
            insertLoc = cursor
        }
        let endOffset = payloadNS.length > 0 ? prevCharStart(before: payloadNS.length, in: payloadNS) : 0
        let targetAfter = insertLoc + endOffset
        host.vimReplace(in: NSRange(location: insertLoc, length: 0), with: payload, selectedRangeAfter: NSRange(location: targetAfter, length: 0))
        let clamped = clampNormalLocation(targetAfter, in: host.vimNSString)
        setHostSelection(NSRange(location: clamped, length: 0))
        host.vimEnsureCaretVisible(typewriter: false)
    }

    private func pasteOverVisualSelection(isLinewise: Bool, swapClipboard: Bool, host: VimHost) {
        guard let clip = VimClipboard.read() else { return }
        let ns = host.vimNSString
        let range = resolvedVisualRange(isLinewise: isLinewise, in: ns)
        let overwritten = ns.substring(with: range)
        lastVisualSnapshot = (mode, visualAnchor, visualHead)
        mode = .normal

        var payload = clip.text
        if isLinewise && !payload.hasSuffix("\n") && overwritten.hasSuffix("\n") {
            payload += "\n"
        } else if !isLinewise && clip.style == .linewise && payload.hasSuffix("\n") {
            payload.removeLast()
        }
        let payloadNS = payload as NSString
        let afterLoc = range.location + (payloadNS.length > 0 ? prevCharStart(before: payloadNS.length, in: payloadNS) : 0)
        host.vimReplace(in: range, with: payload, selectedRangeAfter: NSRange(location: afterLoc, length: 0))
        if swapClipboard && !overwritten.isEmpty {
            VimClipboard.write(overwritten, style: isLinewise ? .linewise : .charwise)
        }
        let clamped = clampNormalLocation(isLinewise ? range.location : afterLoc, in: host.vimNSString)
        setHostSelection(NSRange(location: clamped, length: 0))
    }

    private func toggleCaseAtCursor(count: Int, host: VimHost) {
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let line = lineInfo(for: cursor, in: ns)
        let endLoc = advanceCharsOnLine(from: cursor, count: count, line: line, in: ns)
        guard endLoc > cursor else { return }
        let span = NSRange(location: cursor, length: endLoc - cursor)
        let sub = ns.substring(with: span)
        let toggled = String(sub.map { ch -> Character in
            let s = String(ch)
            let upper = s.uppercased()
            let lower = s.lowercased()
            if s == lower && s != upper { return Character(upper) }
            if s == upper && s != lower { return Character(lower) }
            return ch
        })
        let nextLoc = min(endLoc, line.contentEnd > line.start ? prevCharStart(before: line.contentEnd, in: ns) : line.start)
        host.vimReplace(in: span, with: toggled, selectedRangeAfter: NSRange(location: nextLoc, length: 0))
        let clamped = clampNormalLocation( cursor + (toggled as NSString).length, in: host.vimNSString)
        setHostSelection(NSRange(location: clamped, length: 0))
    }

    private func transformCase(in range: NSRange, op: OperatorKind, host: VimHost) {
        guard range.length > 0 else { return }
        let ns = host.vimNSString
        let sub = ns.substring(with: range)
        let transformed: String
        switch op {
        case .lowercase:
            transformed = sub.lowercased()
        case .uppercase:
            transformed = sub.uppercased()
        case .toggleCase:
            transformed = String(sub.map { ch -> Character in
                let s = String(ch)
                let upper = s.uppercased()
                let lower = s.lowercased()
                if s == lower && s != upper { return Character(upper) }
                if s == upper && s != lower { return Character(lower) }
                return ch
            })
        default:
            return
        }
        host.vimReplace(in: range, with: transformed, selectedRangeAfter: NSRange(location: range.location, length: 0))
        let clamped = clampNormalLocation(range.location, in: host.vimNSString)
        setHostSelection(NSRange(location: clamped, length: 0))
    }

    private func joinLines(count: Int, trimSpaces: Bool, host: VimHost) {
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let firstLine = lineInfo(for: cursor, in: ns)
        guard firstLine.fullEnd < ns.length || firstLine.fullEnd > firstLine.contentEnd else { return }

        var lastLine = firstLine
        for _ in 1..<count {
            guard lastLine.fullEnd < ns.length else { break }
            lastLine = lineInfo(for: lastLine.fullEnd, in: ns)
        }
        guard lastLine.start > firstLine.start else { return }
        let fullSpan = NSRange(location: firstLine.start, length: lastLine.fullEnd - firstLine.start)
        joinLinesInRange(fullSpan, trimSpaces: trimSpaces, host: host)
    }

    private func joinLinesInRange(_ span: NSRange, trimSpaces: Bool, host: VimHost) {
        let ns = host.vimNSString
        guard span.length > 0 else { return }
        let raw = ns.substring(with: span)
        let hasTrailingNL = raw.hasSuffix("\n")
        let body = hasTrailingNL ? String(raw.dropLast()) : raw
        let parts = body.components(separatedBy: "\n").map { part -> String in
            part.hasSuffix("\r") ? String(part.dropLast()) : part
        }
        guard parts.count >= 2 else { return }

        var acc = parts[0]
        var joinCursorOffset = (acc as NSString).length
        for idx in 1..<parts.count {
            let nextPart = trimSpaces ? String(parts[idx].drop(while: { $0 == " " || $0 == "\t" })) : parts[idx]
            if trimSpaces {
                if !acc.isEmpty && !acc.hasSuffix(" ") && !acc.hasSuffix("\t") && !nextPart.isEmpty {
                    joinCursorOffset = (acc as NSString).length
                    acc += " " + nextPart
                } else {
                    joinCursorOffset = (acc as NSString).length
                    acc += nextPart
                }
            } else {
                joinCursorOffset = (acc as NSString).length
                acc += nextPart
            }
        }
        let finalText = acc + (hasTrailingNL ? "\n" : "")
        let landed = span.location + min(joinCursorOffset, max(0, (acc as NSString).length - 1))
        host.vimReplace(in: span, with: finalText, selectedRangeAfter: NSRange(location: landed, length: 0))
        let clamped = clampNormalLocation(landed, in: host.vimNSString)
        setHostSelection(NSRange(location: clamped, length: 0))
    }

    private func indentOrOutdentLines(in lineSpan: NSRange, indent: Bool, host: VimHost) {
        let ns = host.vimNSString
        guard lineSpan.length > 0 else { return }
        let block = ns.substring(with: lineSpan)
        let hasTrailingNL = block.hasSuffix("\n")
        let content = hasTrailingNL ? String(block.dropLast()) : block
        let lines = content.components(separatedBy: "\n")

        let transformed = lines.map { line -> String in
            if indent {
                return line.isEmpty ? line : ("  " + line)
            } else {
                if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
                if line.hasPrefix("\t") || line.hasPrefix(" ") { return String(line.dropFirst(1)) }
                return line
            }
        }
        let joined = transformed.joined(separator: "\n") + (hasTrailingNL ? "\n" : "")
        host.vimReplace(in: lineSpan, with: joined, selectedRangeAfter: NSRange(location: lineSpan.location, length: 0))
        let updated = host.vimNSString
        let firstLine = lineInfo(for: min(lineSpan.location, updated.length), in: updated)
        let landed = clampNormalLocation(firstNonBlank(on: firstLine, in: updated), in: updated)
        setHostSelection(NSRange(location: landed, length: 0))
    }

    private func performUndo(count: Int, host: VimHost) {
        guard let um = host.vimUndoManager else { return }
        var didUndo = false
        for _ in 0..<count where um.canUndo {
            um.undo()
            didUndo = true
        }
        if didUndo {
            let clamped = clampNormalLocation(host.vimSelectedRange.location, in: host.vimNSString)
            setHostSelection(NSRange(location: clamped, length: 0))
            host.vimEnsureCaretVisible(typewriter: false)
        }
    }

    private func performRedo(count: Int, host: VimHost) {
        guard let um = host.vimUndoManager else { return }
        var didRedo = false
        for _ in 0..<count where um.canRedo {
            um.redo()
            didRedo = true
        }
        if didRedo {
            let clamped = clampNormalLocation(host.vimSelectedRange.location, in: host.vimNSString)
            setHostSelection(NSRange(location: clamped, length: 0))
            host.vimEnsureCaretVisible(typewriter: false)
        }
    }

    private func recordNormalRepeat(coreKeys: [VimKeyInput], count: Int) {
        guard !isReplayingRepeat, !coreKeys.isEmpty else { return }
        lastRepeatable = .normalSequence(coreKeys: coreKeys, count: max(1, count))
    }

    private func replayLastEdit(overrideCount: Int?, host: VimHost) {
        guard let action = lastRepeatable, !isReplayingRepeat else { return }
        let um = host.vimUndoManager
        let prevGroupsByEvent = um?.groupsByEvent ?? true
        um?.groupsByEvent = false
        um?.beginUndoGrouping()
        isReplayingRepeat = true
        defer {
            isReplayingRepeat = false
            um?.endUndoGrouping()
            um?.groupsByEvent = prevGroupsByEvent
        }

        switch action {
        case .normalSequence(let coreKeys, let savedCount):
            let replayCount = overrideCount ?? savedCount
            clearPendingState()
            if replayCount > 1 {
                for ch in String(replayCount) {
                    _ = processInput(.char(String(ch)))
                }
            }
            for key in coreKeys {
                _ = processInput(key)
            }

        case .insertSession(let entryKeys, let savedCount, let prefixConsumed, let suffixConsumed, let insertedText):
            let replayCount = overrideCount ?? savedCount
            clearPendingState()
            if replayCount > 1 {
                for ch in String(replayCount) {
                    _ = processInput(.char(String(ch)))
                }
            }
            for key in entryKeys {
                _ = processInput(key)
            }
            if mode == .insert {
                let ns = host.vimNSString
                let origin = host.vimSelectedRange.location
                let repStart = max(0, origin - prefixConsumed)
                let repEnd = min(ns.length, origin + suffixConsumed)
                let insLen = (insertedText as NSString).length
                host.vimReplace(
                    in: NSRange(location: repStart, length: max(0, repEnd - repStart)),
                    with: insertedText,
                    selectedRangeAfter: NSRange(location: repStart + insLen, length: 0)
                )
                finalizeInsertSessionIfNeeded(stepCursorLeft: true)
                mode = .normal
            }

        case .visualEdit(_, let spanLength, _, let op, _):
            let ns = host.vimNSString
            let cursor = currentCursorLocation(in: ns)
            let len = min(overrideCount ?? spanLength, ns.length - cursor)
            if len > 0 {
                applyOperatorToCharRange(op, range: NSRange(location: cursor, length: len), coreKeys: [], count: 1, host: host)
            }
        }
    }

    private func scrollHalfPages(_ halfPages: Int, host: VimHost) {
        if let target = host.vimScrollByHalfPages(halfPages) {
            let ns = host.vimNSString
            let line = lineInfo(for: target, in: ns)
            let loc = firstNonBlank(on: line, in: ns)
            if mode == .visual || mode == .visualLine {
                visualHead = loc
                syncVisualSelection(host: host)
            } else {
                let clamped = clampNormalLocation(loc, in: ns)
                setHostSelection(NSRange(location: clamped, length: 0))
            }
        }
    }

    // MARK: - Visual Selection Sync

    private func resolvedVisualRange(isLinewise: Bool, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let lo = min(visualAnchor, visualHead)
        let hi = max(visualAnchor, visualHead)
        if isLinewise {
            let first = lineInfo(for: min(lo, ns.length - 1), in: ns)
            let last = lineInfo(for: min(hi, ns.length - 1), in: ns)
            return NSRange(location: first.start, length: last.fullEnd - first.start)
        }
        let clampedLo = min(lo, ns.length)
        let clampedHi = min(hi, ns.length)
        let end = clampedHi < ns.length ? nextCharLocation(after: clampedHi, in: ns) : ns.length
        return NSRange(location: clampedLo, length: max(0, end - clampedLo))
    }

    private func syncVisualSelection(host: VimHost) {
        let ns = host.vimNSString
        let range = resolvedVisualRange(isLinewise: mode == .visualLine, in: ns)
        setHostSelection(range)
    }

    private func setHostSelection(_ range: NSRange) {
        guard let host else { return }
        let wasInternal = isApplyingInternalSelection
        isApplyingInternalSelection = true
        host.vimSelectedRange = range
        isApplyingInternalSelection = wasInternal
    }

    // MARK: - Pure UTF-16 String & Motion Primitives

    private enum CharClass: Equatable {
        case newline
        case whitespace
        case word
        case punctuation
    }

    private func currentCursorLocation(in ns: NSString) -> Int {
        if mode == .visual || mode == .visualLine {
            return min(max(0, visualHead), ns.length)
        }
        return min(max(0, host?.vimSelectedRange.location ?? 0), ns.length)
    }

    private func lineInfo(for location: Int, in ns: NSString) -> LineInfo {
        let len = ns.length
        guard len > 0 else { return LineInfo(start: 0, contentEnd: 0, fullEnd: 0) }
        let clamped = min(max(0, location), len)
        if clamped == len {
            let prev = ns.character(at: len - 1)
            if prev == 10 || prev == 13 {
                return LineInfo(start: len, contentEnd: len, fullEnd: len)
            }
            let r = ns.lineRange(for: NSRange(location: len - 1, length: 0))
            return makeLineInfo(from: r, in: ns)
        }
        let r = ns.lineRange(for: NSRange(location: clamped, length: 0))
        return makeLineInfo(from: r, in: ns)
    }

    private func makeLineInfo(from lineRange: NSRange, in ns: NSString) -> LineInfo {
        let fullEnd = min(ns.length, NSMaxRange(lineRange))
        var contentEnd = fullEnd
        while contentEnd > lineRange.location {
            let ch = ns.character(at: contentEnd - 1)
            if ch == 10 || ch == 13 {
                contentEnd -= 1
            } else {
                break
            }
        }
        return LineInfo(start: lineRange.location, contentEnd: contentEnd, fullEnd: fullEnd)
    }

    private func clampNormalLocation(_ location: Int, in ns: NSString, fallbackStart: Int? = nil) -> Int {
        guard ns.length > 0 else { return 0 }
        let clamped = min(max(0, location), ns.length)
        let line = lineInfo(for: clamped, in: ns)
        if line.contentEnd <= line.start {
            return fallbackStart.map { min($0, line.start) } ?? line.start
        }
        let maxValid = prevCharStart(before: line.contentEnd, in: ns)
        return min(max(line.start, clamped), maxValid)
    }

    private func clampVisualLocation(_ location: Int, in ns: NSString) -> Int {
        guard ns.length > 0 else { return 0 }
        let clamped = min(max(0, location), ns.length - 1)
        let line = lineInfo(for: clamped, in: ns)
        if line.contentEnd <= line.start { return line.start }
        return min(clamped, prevCharStart(before: line.contentEnd, in: ns))
    }

    private func nsAfterDeleting(_ range: NSRange, in ns: NSString) -> NSString {
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return ns }
        return ns.replacingCharacters(in: range, with: "") as NSString
    }

    private func nextCharLocation(after location: Int, in ns: NSString) -> Int {
        guard location < ns.length else { return ns.length }
        let seq = ns.rangeOfComposedCharacterSequence(at: location)
        return max(location + 1, NSMaxRange(seq))
    }

    private func prevCharStart(before location: Int, in ns: NSString) -> Int {
        guard location > 0, ns.length > 0 else { return 0 }
        let probe = min(location - 1, ns.length - 1)
        return ns.rangeOfComposedCharacterSequence(at: probe).location
    }

    private func advanceCharsOnLine(from start: Int, count: Int, line: LineInfo, in ns: NSString) -> Int {
        var pos = start
        for _ in 0..<count where pos < line.contentEnd {
            pos = nextCharLocation(after: pos, in: ns)
        }
        return min(pos, line.contentEnd)
    }

    private func firstNonBlank(on line: LineInfo, in ns: NSString) -> Int {
        var p = line.start
        while p < line.contentEnd {
            let ch = ns.character(at: p)
            if ch == 0x20 || ch == 0x09 {
                p += 1
            } else {
                break
            }
        }
        return p
    }

    private func leadingWhitespace(on line: LineInfo, in ns: NSString) -> String {
        let end = firstNonBlank(on: line, in: ns)
        guard end > line.start else { return "" }
        return ns.substring(with: NSRange(location: line.start, length: end - line.start))
    }

    private func isBlankLine(_ line: LineInfo, in ns: NSString) -> Bool {
        firstNonBlank(on: line, in: ns) >= line.contentEnd
    }

    private func resolveHorizontalMotion(delta: Int, count: Int, in ns: NSString) -> ResolvedMotion {
        let cursor = currentCursorLocation(in: ns)
        let line = lineInfo(for: cursor, in: ns)
        var pos = cursor
        if delta < 0 {
            for _ in 0..<count where pos > line.start {
                pos = prevCharStart(before: pos, in: ns)
            }
        } else {
            let limit: Int
            if pendingOperator != nil || mode == .visual || mode == .visualLine {
                limit = line.contentEnd
            } else {
                limit = line.contentEnd > line.start ? prevCharStart(before: line.contentEnd, in: ns) : line.start
            }
            for _ in 0..<count where pos < limit {
                pos = min(limit, nextCharLocation(after: pos, in: ns))
            }
        }
        return ResolvedMotion(target: pos, style: .charExclusive, preservesDesiredColumn: false)
    }

    private func graphemeColumn(of location: Int, on line: LineInfo, in ns: NSString) -> Int {
        var col = 0
        var p = line.start
        let target = min(location, line.contentEnd)
        while p < target {
            p = nextCharLocation(after: p, in: ns)
            col += 1
        }
        return col
    }

    private func locationForGraphemeColumn(_ col: Int, on line: LineInfo, in ns: NSString) -> Int {
        if line.contentEnd <= line.start { return line.start }
        if col == Int.max {
            if pendingOperator != nil || mode == .visual || mode == .visualLine {
                return line.contentEnd
            }
            return prevCharStart(before: line.contentEnd, in: ns)
        }
        var p = line.start
        var remaining = col
        let maxPos = (pendingOperator != nil || mode == .visual || mode == .visualLine)
            ? line.contentEnd
            : prevCharStart(before: line.contentEnd, in: ns)
        while remaining > 0 && p < maxPos {
            p = min(maxPos, nextCharLocation(after: p, in: ns))
            remaining -= 1
        }
        return p
    }

    private func stepVisibleLines(from location: Int, delta: Int, in ns: NSString, host: VimHost) -> Int {
        guard ns.length > 0, delta != 0 else { return location }
        var curLine = lineInfo(for: location, in: ns)
        let steps = abs(delta)
        if delta > 0 {
            for _ in 0..<steps {
                var nextStart = curLine.fullEnd
                if let fold = host.vimFoldedRangeEnclosing(nextStart) {
                    nextStart = NSMaxRange(fold)
                }
                if nextStart > ns.length { break }
                if nextStart == ns.length {
                    if ns.character(at: ns.length - 1) == 10 || ns.character(at: ns.length - 1) == 13 {
                        curLine = LineInfo(start: ns.length, contentEnd: ns.length, fullEnd: ns.length)
                    }
                    break
                }
                curLine = lineInfo(for: nextStart, in: ns)
            }
        } else {
            for _ in 0..<steps {
                guard curLine.start > 0 else { break }
                var probe = curLine.start - 1
                if probe > 0, ns.character(at: probe) == 10, probe > 0, ns.character(at: probe - 1) == 13 {
                    probe -= 1
                }
                if let fold = host.vimFoldedRangeEnclosing(probe), fold.location > 0 {
                    probe = fold.location - 1
                }
                curLine = lineInfo(for: probe, in: ns)
            }
        }
        return curLine.start
    }

    private func resolveVerticalMotion(delta: Int, count: Int, host: VimHost) -> ResolvedMotion {
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let curLine = lineInfo(for: cursor, in: ns)
        if desiredColumn == nil {
            desiredColumn = graphemeColumn(of: cursor, on: curLine, in: ns)
        }
        let targetCol = desiredColumn ?? 0
        let targetLineStart = stepVisibleLines(from: cursor, delta: delta * count, in: ns, host: host)
        let targetLine = lineInfo(for: targetLineStart, in: ns)
        let targetLoc = locationForGraphemeColumn(targetCol, on: targetLine, in: ns)
        return ResolvedMotion(target: targetLoc, style: .linewise, preservesDesiredColumn: true)
    }

    private func resolveVerticalFirstNonBlankMotion(delta: Int, count: Int, host: VimHost) -> ResolvedMotion {
        let ns = host.vimNSString
        let cursor = currentCursorLocation(in: ns)
        let targetLineStart = stepVisibleLines(from: cursor, delta: delta * count, in: ns, host: host)
        let targetLine = lineInfo(for: targetLineStart, in: ns)
        return ResolvedMotion(target: firstNonBlank(on: targetLine, in: ns), style: .linewise, preservesDesiredColumn: false)
    }

    private func charClass(at location: Int, in ns: NSString, bigWord: Bool) -> CharClass {
        guard location < ns.length else { return .newline }
        let ch = ns.character(at: location)
        if ch == 10 || ch == 13 { return .newline }
        if ch == 0x20 || ch == 0x09 { return .whitespace }
        if bigWord { return .word }
        if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x30 && ch <= 0x39) || ch == 0x5F {
            return .word
        }
        if ch < 0x80 {
            return .punctuation
        }
        let seq = ns.rangeOfComposedCharacterSequence(at: location)
        let str = ns.substring(with: seq)
        if let scalar = str.unicodeScalars.first {
            if CharacterSet.whitespaces.contains(scalar) { return .whitespace }
            if CharacterSet.alphanumerics.contains(scalar) { return .word }
        }
        return .punctuation
    }

    private func moveWordForward(from start: Int, count: Int, bigWord: Bool, forOperator: Bool, in ns: NSString) -> Int {
        let len = ns.length
        guard len > 0 else { return 0 }
        var pos = min(start, len)

        for step in 0..<count {
            guard pos < len else { break }
            let c0 = charClass(at: pos, in: ns, bigWord: bigWord)
            if c0 == .newline {
                pos = nextCharLocation(after: pos, in: ns)
            } else if c0 != .whitespace {
                while pos < len && charClass(at: pos, in: ns, bigWord: bigWord) == c0 {
                    pos = nextCharLocation(after: pos, in: ns)
                }
            }
            // Skip horizontal whitespace; stop on an empty line unless operator-pending on final step
            while pos < len {
                let c = charClass(at: pos, in: ns, bigWord: bigWord)
                if c == .whitespace {
                    pos = nextCharLocation(after: pos, in: ns)
                } else if c == .newline {
                    if forOperator && step == count - 1 {
                        break
                    }
                    let next = nextCharLocation(after: pos, in: ns)
                    if next < len && charClass(at: next, in: ns, bigWord: bigWord) == .newline {
                        pos = next
                        break
                    }
                    pos = next
                } else {
                    break
                }
            }
        }
        return min(pos, len)
    }

    private func moveWordBackward(from start: Int, count: Int, bigWord: Bool, in ns: NSString) -> Int {
        guard ns.length > 0, start > 0 else { return 0 }
        var pos = min(start, ns.length)

        for _ in 0..<count {
            guard pos > 0 else { break }
            pos = prevCharStart(before: pos, in: ns)

            // Skip whitespace & newlines, stopping on empty lines
            while pos > 0 {
                let c = charClass(at: pos, in: ns, bigWord: bigWord)
                if c == .whitespace {
                    pos = prevCharStart(before: pos, in: ns)
                } else if c == .newline {
                    let line = lineInfo(for: pos, in: ns)
                    if line.start == line.contentEnd {
                        break
                    }
                    pos = prevCharStart(before: pos, in: ns)
                } else {
                    break
                }
            }
            let targetClass = charClass(at: pos, in: ns, bigWord: bigWord)
            if targetClass != .newline && targetClass != .whitespace {
                while pos > 0 {
                    let prev = prevCharStart(before: pos, in: ns)
                    if charClass(at: prev, in: ns, bigWord: bigWord) == targetClass {
                        pos = prev
                    } else {
                        break
                    }
                }
            }
        }
        return pos
    }

    private func moveWordEnd(from start: Int, count: Int, bigWord: Bool, in ns: NSString) -> Int {
        let len = ns.length
        guard len > 0 else { return 0 }
        var pos = min(start, len - 1)

        for _ in 0..<count {
            let next = nextCharLocation(after: pos, in: ns)
            guard next < len else {
                pos = prevCharStart(before: len, in: ns)
                break
            }
            pos = next
            while pos < len {
                let c = charClass(at: pos, in: ns, bigWord: bigWord)
                if c == .whitespace || c == .newline {
                    pos = nextCharLocation(after: pos, in: ns)
                } else {
                    break
                }
            }
            guard pos < len else {
                pos = prevCharStart(before: len, in: ns)
                break
            }
            let targetClass = charClass(at: pos, in: ns, bigWord: bigWord)
            while true {
                let step = nextCharLocation(after: pos, in: ns)
                if step < len && charClass(at: step, in: ns, bigWord: bigWord) == targetClass {
                    pos = step
                } else {
                    break
                }
            }
        }
        return min(pos, max(0, len - 1))
    }

    private func moveBackwardWordEnd(from start: Int, count: Int, bigWord: Bool, in ns: NSString) -> Int {
        guard ns.length > 0, start > 0 else { return 0 }
        var pos = min(start, ns.length - 1)

        for _ in 0..<count {
            guard pos > 0 else { break }
            let curClass = charClass(at: pos, in: ns, bigWord: bigWord)
            if curClass != .whitespace && curClass != .newline {
                while pos > 0 {
                    let prev = prevCharStart(before: pos, in: ns)
                    if charClass(at: prev, in: ns, bigWord: bigWord) == curClass {
                        pos = prev
                    } else {
                        pos = prev
                        break
                    }
                }
            } else {
                pos = prevCharStart(before: pos, in: ns)
            }
            while pos > 0 {
                let c = charClass(at: pos, in: ns, bigWord: bigWord)
                if c == .whitespace || c == .newline {
                    pos = prevCharStart(before: pos, in: ns)
                } else {
                    break
                }
            }
        }
        return pos
    }

    private func moveParagraph(from start: Int, count: Int, forward: Bool, in ns: NSString) -> Int {
        let len = ns.length
        guard len > 0 else { return 0 }
        var curLine = lineInfo(for: start, in: ns)

        for _ in 0..<count {
            if forward {
                while curLine.fullEnd < len && isBlankLine(curLine, in: ns) {
                    curLine = lineInfo(for: curLine.fullEnd, in: ns)
                }
                while curLine.fullEnd < len && !isBlankLine(curLine, in: ns) {
                    curLine = lineInfo(for: curLine.fullEnd, in: ns)
                }
                if !isBlankLine(curLine, in: ns) && curLine.fullEnd >= len {
                    return curLine.contentEnd
                }
            } else {
                if curLine.start > 0 {
                    curLine = lineInfo(for: curLine.start - 1, in: ns)
                }
                while curLine.start > 0 && isBlankLine(curLine, in: ns) {
                    curLine = lineInfo(for: curLine.start - 1, in: ns)
                }
                while curLine.start > 0 && !isBlankLine(curLine, in: ns) {
                    let prev = lineInfo(for: curLine.start - 1, in: ns)
                    if isBlankLine(prev, in: ns) {
                        curLine = prev
                        break
                    }
                    curLine = prev
                }
            }
        }
        return curLine.start
    }

    private func locationForOneBasedLine(_ targetLine: Int, in ns: NSString) -> Int {
        guard ns.length > 0 else { return 0 }
        if targetLine <= 1 {
            let first = lineInfo(for: 0, in: ns)
            return firstNonBlank(on: first, in: ns)
        }
        var currentLine = 1
        var offset = 0
        let len = ns.length
        while offset < len && currentLine < targetLine {
            let r = ns.lineRange(for: NSRange(location: offset, length: 0))
            let next = NSMaxRange(r)
            if next <= offset { break }
            offset = next
            currentLine += 1
        }
        let line = lineInfo(for: min(offset, len), in: ns)
        return firstNonBlank(on: line, in: ns)
    }

    private func lastLineStart(in ns: NSString) -> Int {
        let len = ns.length
        guard len > 0 else { return 0 }
        if ns.character(at: len - 1) == 10 || ns.character(at: len - 1) == 13 {
            if len >= 2 {
                return ns.lineRange(for: NSRange(location: len - 1, length: 0)).location == len
                    ? len
                    : lineInfo(for: len, in: ns).start
            }
            return len
        }
        return ns.lineRange(for: NSRange(location: len - 1, length: 0)).location
    }

    private func findCharacterOnLine(spec: FindSpec, from cursor: Int, count: Int, isRepeat: Bool, in ns: NSString) -> Int? {
        let line = lineInfo(for: cursor, in: ns)
        guard line.contentEnd > line.start else { return nil }
        let targetNS = spec.target as NSString
        guard targetNS.length > 0 else { return nil }

        switch spec.kind {
        case .findForward, .tillForward:
            var searchPos = nextCharLocation(after: cursor, in: ns)
            if isRepeat && spec.kind == .tillForward && searchPos < line.contentEnd {
                let peek = ns.range(of: spec.target, options: .literal, range: NSRange(location: searchPos, length: line.contentEnd - searchPos))
                if peek.location == searchPos {
                    searchPos = nextCharLocation(after: searchPos, in: ns)
                }
            }
            var foundLoc: Int?
            for _ in 0..<count {
                guard searchPos < line.contentEnd else { return nil }
                let hit = ns.range(of: spec.target, options: .literal, range: NSRange(location: searchPos, length: line.contentEnd - searchPos))
                guard hit.location != NSNotFound else { return nil }
                foundLoc = hit.location
                searchPos = NSMaxRange(hit)
            }
            guard let match = foundLoc else { return nil }
            return spec.kind == .tillForward ? max(cursor, prevCharStart(before: match, in: ns)) : match

        case .findBackward, .tillBackward:
            var searchEnd = cursor
            if isRepeat && spec.kind == .tillBackward && searchEnd > line.start {
                let prev = prevCharStart(before: searchEnd, in: ns)
                let peek = ns.range(of: spec.target, options: .literal, range: NSRange(location: prev, length: searchEnd - prev))
                if peek.location == prev {
                    searchEnd = prev
                }
            }
            var foundLoc: Int?
            for _ in 0..<count {
                guard searchEnd > line.start else { return nil }
                let hit = ns.range(of: spec.target, options: [.literal, .backwards], range: NSRange(location: line.start, length: searchEnd - line.start))
                guard hit.location != NSNotFound else { return nil }
                foundLoc = hit.location
                searchEnd = hit.location
            }
            guard let match = foundLoc else { return nil }
            return spec.kind == .tillBackward ? min(cursor, nextCharLocation(after: match, in: ns)) : match
        }
    }

    private func findMatchingPair(from cursor: Int, in ns: NSString) -> Int? {
        let len = ns.length
        guard len > 0 else { return nil }
        let line = lineInfo(for: cursor, in: ns)
        let pairs: [(open: unichar, close: unichar)] = [(0x28, 0x29), (0x5B, 0x5D), (0x7B, 0x7D)]

        var bracketLoc: Int?
        var openChar: unichar = 0
        var closeChar: unichar = 0
        var forward = true

        var seek = min(cursor, max(line.start, line.contentEnd - 1))
        while seek < line.contentEnd {
            let ch = ns.character(at: seek)
            if let pair = pairs.first(where: { $0.open == ch || $0.close == ch }) {
                bracketLoc = seek
                openChar = pair.open
                closeChar = pair.close
                forward = (ch == pair.open)
                break
            }
            seek += 1
        }
        guard let startIdx = bracketLoc else { return nil }
        let limit = 65_536
        var depth = 1
        if forward {
            let end = min(len, startIdx + limit)
            var idx = startIdx + 1
            while idx < end {
                let ch = ns.character(at: idx)
                if ch == openChar { depth += 1 }
                else if ch == closeChar {
                    depth -= 1
                    if depth == 0 { return idx }
                }
                idx += 1
            }
        } else {
            let minIdx = max(0, startIdx - limit)
            var idx = startIdx
            while idx > minIdx {
                idx -= 1
                let ch = ns.character(at: idx)
                if ch == closeChar { depth += 1 }
                else if ch == openChar {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
        }
        return nil
    }

    private func wordUnderCursor(at cursor: Int, in ns: NSString) -> String? {
        guard ns.length > 0 else { return nil }
        let line = lineInfo(for: cursor, in: ns)
        guard line.contentEnd > line.start else { return nil }
        var probe = min(cursor, prevCharStart(before: line.contentEnd, in: ns))
        if charClass(at: probe, in: ns, bigWord: false) != .word {
            var seek = probe
            var found: Int?
            while seek < line.contentEnd {
                if charClass(at: seek, in: ns, bigWord: false) == .word {
                    found = seek
                    break
                }
                seek = nextCharLocation(after: seek, in: ns)
            }
            guard let f = found else { return nil }
            probe = f
        }
        guard let range = wordTextObject(at: probe, around: false, bigWord: false, count: 1, in: ns),
              range.length > 0 else { return nil }
        return ns.substring(with: range)
    }

    private func stripDigits(from keys: [VimKeyInput]) -> [VimKeyInput] {
        var result: [VimKeyInput] = []
        result.reserveCapacity(keys.count)
        for (idx, k) in keys.enumerated() {
            if case .char(let s) = k, s.count == 1, let d = s.first?.wholeNumberValue {
                // Keep `0` only if it was the 0-motion (not preceded by another digit)
                if d == 0 {
                    let prevWasDigit: Bool
                    if idx > 0, case .char(let ps) = keys[idx - 1], ps.first?.wholeNumberValue != nil {
                        prevWasDigit = true
                    } else {
                        prevWasDigit = false
                    }
                    if !prevWasDigit {
                        result.append(k)
                    }
                }
                continue
            }
            result.append(k)
        }
        return result
    }
}
