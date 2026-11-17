#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import AppKit
import CozyCore
import CozySearch
@testable import CozyNotes

@MainActor
private struct SemanticUIFixture {
    let rootDir: URL
    let modelSourceDir: URL
    let modelStoreDir: URL
    let cacheDir: URL
    let vault: Vault
    let modelStore: SemanticModelStore
    let workspace: WorkspaceController

    init() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        rootDir = fm.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozySemanticUITests-\(UUID().uuidString)", isDirectory: true)
        modelSourceDir = rootDir.appendingPathComponent("SourceModel", isDirectory: true)
        modelStoreDir = rootDir.appendingPathComponent("InstalledModelStore", isDirectory: true)
        cacheDir = rootDir.appendingPathComponent("SemanticCache", isDirectory: true)
        try fm.createDirectory(at: modelSourceDir, withIntermediateDirectories: true)

        try Self.writeSyntheticMiniLMFolder(to: modelSourceDir)

        vault = try Vault(
            root: rootDir.appendingPathComponent("Vault", isDirectory: true),
            historyRoot: rootDir.appendingPathComponent("LocalHistory", isDirectory: true)
        )
        modelStore = SemanticModelStore(modelDirectory: modelStoreDir)
        workspace = WorkspaceController(
            vault: vault,
            semanticModelStore: modelStore,
            semanticCacheDirectory: cacheDir
        )
    }

    func cleanup() {
        workspace.shutdown()
        workspace.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: rootDir)
    }

    private static func writeSyntheticMiniLMFolder(to folder: URL) throws {
        var vocab: [[Any]] = [
            ["<s>", 0.0],
            ["<pad>", 0.0],
            ["</s>", 0.0],
            ["<unk>", -10.0],
            ["\u{2581}", -1.5]
        ]
        for ch in Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:/-_#[]()!?\"'") {
            vocab.append([String(ch), -4.0])
            vocab.append(["\u{2581}\(ch)", -3.8])
        }

        let clusters: [(Int, [String])] = [
            (0, ["software", "engineering", "code", "debugging", "appkit", "macos", "sinkronisasi", "berkas", "perbaikan", "memori"]),
            (1, ["finance", "bills", "invoices", "invoice", "receipts", "payments", "keuangan", "tagihan", "bulanan", "listrik", "pembayaran", "cicilan"]),
            (2, ["travel", "flights", "trains", "airport", "hotel", "changi", "perjalanan", "tiket", "bandara", "penginapan"])
        ]

        var topicTokenIDs: [Int: Int] = [:]
        for (clusterIdx, words) in clusters {
            for word in words {
                let idLower = vocab.count
                vocab.append(["\u{2581}\(word)", -0.5])
                topicTokenIDs[idLower] = clusterIdx

                let cap = word.prefix(1).uppercased() + word.dropFirst()
                let idCap = vocab.count
                vocab.append(["\u{2581}\(cap)", -0.5])
                topicTokenIDs[idCap] = clusterIdx
            }
        }
        var filler = 0
        while vocab.count < 1040 {
            vocab.append(["\u{2581}u\(filler)", -8.0])
            filler += 1
        }

        let tokObj: [String: Any] = [
            "added_tokens": [
                ["id": 0, "content": "<s>", "special": true],
                ["id": 1, "content": "<pad>", "special": true],
                ["id": 2, "content": "</s>", "special": true],
                ["id": 3, "content": "<unk>", "special": true]
            ],
            "truncation": ["max_length": 128],
            "model": ["type": "Unigram", "unk_id": 3, "vocab": vocab]
        ]
        let tokData = try JSONSerialization.data(withJSONObject: tokObj, options: [.sortedKeys])
        try tokData.write(to: folder.appendingPathComponent("tokenizer.json"), options: .atomic)

        let vocabRows = 1040
        let hidden = 384
        let intermediate = 1536
        let maxPos = 512
        let numLayers = 12

        enum Fill { case wordEmb, ones, zeros }
        var specs: [(String, [Int], Fill)] = [
            ("embeddings.word_embeddings.weight", [vocabRows, hidden], .wordEmb),
            ("embeddings.position_embeddings.weight", [maxPos, hidden], .zeros),
            ("embeddings.token_type_embeddings.weight", [2, hidden], .zeros),
            ("embeddings.LayerNorm.weight", [hidden], .ones),
            ("embeddings.LayerNorm.bias", [hidden], .zeros)
        ]
        for layer in 0..<numLayers {
            let p = "encoder.layer.\(layer)"
            specs.append(contentsOf: [
                ("\(p).attention.self.query.weight", [hidden, hidden], .zeros),
                ("\(p).attention.self.query.bias", [hidden], .zeros),
                ("\(p).attention.self.key.weight", [hidden, hidden], .zeros),
                ("\(p).attention.self.key.bias", [hidden], .zeros),
                ("\(p).attention.self.value.weight", [hidden, hidden], .zeros),
                ("\(p).attention.self.value.bias", [hidden], .zeros),
                ("\(p).attention.output.dense.weight", [hidden, hidden], .zeros),
                ("\(p).attention.output.dense.bias", [hidden], .zeros),
                ("\(p).attention.output.LayerNorm.weight", [hidden], .ones),
                ("\(p).attention.output.LayerNorm.bias", [hidden], .zeros),
                ("\(p).intermediate.dense.weight", [intermediate, hidden], .zeros),
                ("\(p).intermediate.dense.bias", [intermediate], .zeros),
                ("\(p).output.dense.weight", [hidden, intermediate], .zeros),
                ("\(p).output.dense.bias", [hidden], .zeros),
                ("\(p).output.LayerNorm.weight", [hidden], .ones),
                ("\(p).output.LayerNorm.bias", [hidden], .zeros)
            ])
        }

        // Write directly as FP16 model.fp16.safetensors so UI tests load & import instantaneously
        var headerObj: [String: Any] = ["__metadata__": ["format": "pt", "precision": "fp16"]]
        var offset = 0
        for (name, shape, _) in specs {
            let bytes = shape.reduce(1, *) * 2
            headerObj[name] = ["dtype": "F16", "shape": shape, "data_offsets": [offset, offset + bytes]]
            offset += bytes
        }
        var headerData = try JSONSerialization.data(withJSONObject: headerObj, options: [.sortedKeys])
        let pad = (8 - (headerData.count % 8)) % 8
        if pad > 0 { headerData.append(contentsOf: [UInt8](repeating: 0x20, count: pad)) }

        let fp16URL = folder.appendingPathComponent("model.fp16.safetensors")
        FileManager.default.createFile(atPath: fp16URL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fp16URL)
        defer { try? handle.close() }

        var lenLE = UInt64(headerData.count).littleEndian
        try handle.write(contentsOf: Data(bytes: &lenLE, count: 8))
        try handle.write(contentsOf: headerData)

        let oneFP16: UInt16 = 0x3C00 // +1.0 in IEEE-754 binary16
        let negOneFP16: UInt16 = 0xBC00 // -1.0 in IEEE-754 binary16
        let tinyPosFP16: UInt16 = 0x211E // ~0.01 in binary16
        let tinyNegFP16: UInt16 = 0xA11E // ~-0.01 in binary16

        var onesRow = [UInt16](repeating: oneFP16.littleEndian, count: hidden)
        let onesData = onesRow.withUnsafeMutableBytes { Data($0) }
        let zeroChunk = Data(count: 65_536)

        for (_, shape, fill) in specs {
            let count = shape.reduce(1, *)
            switch fill {
            case .ones:
                try handle.write(contentsOf: onesData)
            case .zeros:
                var rem = count * 2
                while rem > 0 {
                    let step = min(rem, zeroChunk.count)
                    try handle.write(contentsOf: zeroChunk.prefix(step))
                    rem -= step
                }
            case .wordEmb:
                var table = [UInt16](repeating: 0, count: vocabRows * hidden)
                for (tokID, cluster) in topicTokenIDs {
                    let baseDim = (cluster * 48) % hidden
                    let rowStart = tokID * hidden
                    for d in 0..<24 {
                        table[rowStart + baseDim + d] = oneFP16.littleEndian
                        table[rowStart + baseDim + 24 + d] = negOneFP16.littleEndian
                    }
                }
                for tokID in 5..<vocabRows where topicTokenIDs[tokID] == nil {
                    let d0 = (tokID * 7) % (hidden - 1)
                    table[tokID * hidden + d0] = tinyPosFP16.littleEndian
                    table[tokID * hidden + d0 + 1] = tinyNegFP16.littleEndian
                }
                let tableData = table.withUnsafeMutableBytes { Data($0) }
                try handle.write(contentsOf: tableData)
            }
        }
    }
}

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(domain: "SemanticConnectionsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
private func verifySemanticConnectionsOptInTagUndoAndRelatedNoteNavigation() async throws {
    let fixture = try SemanticUIFixture()
    defer { fixture.cleanup() }

    let idFinanceNote = try fixture.vault.capture(
        text: "# Tagihan Listrik & Cicilan Bulanan\nRekap pembayaran tagihan listrik bulanan dan kwitansi keuangan.\n#tagihan-pln"
    )
    let enNote = try fixture.vault.capture(
        text: "# Q2 Monthly Bills & Invoice Payments\nReviewing monthly utility bills and bank invoice payments."
    )
    fixture.workspace.openNote(enNote.url)
    fixture.workspace.window?.layoutIfNeeded()

    // 1. Default state is hidden & .notInstalled with zero model files
    try check(!fixture.workspace.editor.isSemanticConnectionsVisible, "Semantic strip should be hidden by default")
    try check(fixture.workspace.semanticCoordinator.modelState == .notInstalled, "Model should start .notInstalled")

    // 2. Clicking header connectionsButton reveals the opt-in card
    fixture.workspace.connectionsButton.performClick(nil)
    fixture.workspace.window?.layoutIfNeeded()
    try check(fixture.workspace.editor.isSemanticConnectionsVisible, "Clicking connectionsButton should show SemanticConnectionsView")
    try check(!fixture.workspace.editor.semanticView.isHidden, "semanticView should be unhidden")
    try check(!fixture.workspace.editor.semanticView.downloadButton.isHidden, "Opt-in Download button should be visible when not installed")

    // 3. Import local FP16 model folder and await background suggestion completion
    try fixture.workspace.semanticCoordinator.importModel(from: fixture.modelSourceDir)
    await fixture.workspace.semanticCoordinator.waitForIdle()
    fixture.workspace.window?.layoutIfNeeded()

    let semView = fixture.workspace.editor.semanticView
    try check(semView.modelState.isReady, "Model state should transition to .ready after local import")
    try check(semView.categoryBadge.text == "FINANCE", "Expected FINANCE category badge, got '\(semView.categoryBadge.text)'")
    try check(!semView.tagButtons.isEmpty, "Expected suggested #tag pill buttons")
    try check(!semView.relatedChips.isEmpty, "Expected cross-lingual EN <-> ID related note chip")

    // 4. Clicking a suggested + #tag pill inserts valid #tag AND supports ⌘Z Undo
    let originalText = fixture.workspace.editor.text
    let tagPill = semView.tagButtons[0]
    let insertedTagName = tagPill.tagName
    tagPill.performClick(nil)
    await fixture.workspace.semanticCoordinator.waitForIdle()

    let textAfterTag = fixture.workspace.editor.text
    try check(textAfterTag.contains("#\(insertedTagName)"), "Expected editor text to contain #\(insertedTagName)")
    try check(Vault.tags(in: textAfterTag).contains(where: { $0.name == insertedTagName }), "Inserted #\(insertedTagName) must parse as valid Cozy tag")

    fixture.workspace.editor.textView.undoManager?.undo()
    try check(fixture.workspace.editor.text == originalText, "⌘Z Undo must restore exact text prior to clicking + #tag")

    // Refresh suggestions after undo so relatedChips are current
    fixture.workspace.semanticCoordinator.scheduleSuggestionUpdate(for: fixture.workspace.editor, immediate: true)
    await fixture.workspace.semanticCoordinator.waitForIdle()

    // 5. Clicking [[]] on the Indonesian related note chip inserts undoable [[WikiLink]]
    let relatedChip = try {
        guard let chip = semView.relatedChips.first(where: { $0.hit.note.url.standardizedFileURL == idFinanceNote.url.standardizedFileURL }) ?? semView.relatedChips.first else {
            throw NSError(domain: "SemanticConnectionsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing related note chip"])
        }
        return chip
    }()
    let expectedWikiTarget = relatedChip.hit.wikiTarget
    relatedChip.linkButton.performClick(nil)
    await fixture.workspace.semanticCoordinator.waitForIdle()

    try check(fixture.workspace.editor.text.contains("[[\(expectedWikiTarget)]]"), "Expected [[\(expectedWikiTarget)]] in note after clicking [[]]")
    fixture.workspace.editor.textView.undoManager?.undo()
    try check(fixture.workspace.editor.text == originalText, "⌘Z Undo must restore exact text prior to clicking [[]]")

    // 6. Companion NoteWindowController also supports Semantic Connections
    guard let companion = fixture.workspace.openNoteInNewWindow(enNote.url) else {
        throw NSError(domain: "SemanticConnectionsTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to open companion window"])
    }
    companion.connectionsButton.performClick(nil)
    await fixture.workspace.semanticCoordinator.waitForIdle()
    try check(companion.editor.isSemanticConnectionsVisible, "Companion window connectionsButton should toggle semantic strip")
    try check(companion.editor.semanticView.categoryBadge.text == "FINANCE", "Companion window should receive FINANCE category")

    // 7. Clicking the related note chip opens the Indonesian note in the workspace
    fixture.workspace.semanticCoordinator.scheduleSuggestionUpdate(for: fixture.workspace.editor, immediate: true)
    await fixture.workspace.semanticCoordinator.waitForIdle()
    semView.relatedChips[0].openButton.performClick(nil)
    try check(
        fixture.workspace.noteURL?.standardizedFileURL == idFinanceNote.url.standardizedFileURL,
        "Clicking related note chip should navigate workspace to the Indonesian note"
    )

    // 8. Empty/new note shows calm, instructive 'TAGS & LINKS' badge (never 'LOCAL AI')
    fixture.workspace.newCapture()
    await fixture.workspace.semanticCoordinator.waitForIdle()
    try check(
        semView.categoryBadge.text == "TAGS & LINKS",
        "Expected instructive 'TAGS & LINKS' badge on empty note, got '\(semView.categoryBadge.text)'"
    )
    try check(
        !semView.emptyHintLabel.isHidden && semView.emptyHintLabel.stringValue == "Write a sentence to suggest a category, #tags, and related notes.",
        "Expected instructive empty-note hint, got '\(semView.emptyHintLabel.stringValue)'"
    )

    // 9. Removing the local model resets state cleanly to .notInstalled
    fixture.workspace.semanticCoordinator.removeModel()
    try check(fixture.workspace.semanticCoordinator.modelState == .notInstalled, "Model state should reset to .notInstalled after removal")
    try check(semView.modelState == .notInstalled, "SemanticConnectionsView should return to opt-in .notInstalled state")
}

#if canImport(XCTest)
@MainActor
final class SemanticConnectionsTests: XCTestCase {
    func testSemanticConnectionsOptInTagUndoAndRelatedNoteNavigation() async throws {
        try await verifySemanticConnectionsOptInTagUndoAndRelatedNoteNavigation()
    }
}
#endif

#if canImport(Testing)
extension MobyDickWorkoutSuite {
    @Suite("Semantic Connections UI & Coordinator", .serialized)
    struct SemanticConnectionsSuite {
        @Test("Opt-in model import, + #tag pill with Undo, EN <-> ID [[WikiLink]] insertion, companion window, and model removal")
        @MainActor
        func semanticConnectionsEndToEnd() async throws {
            try await verifySemanticConnectionsOptInTagUndoAndRelatedNoteNavigation()
        }
    }
}
#endif
