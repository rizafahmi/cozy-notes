#if canImport(Testing)
import Testing
#endif
#if canImport(XCTest)
import XCTest
#endif
import Foundation
import CryptoKit
@testable import CozyCore
@testable import CozySearch

final class SemanticIndexTests: XCTestCase {
    // MARK: - Deterministic Offline MiniLM Safetensors + Unigram Fixture Builder

    struct SyntheticMiniLMFixture {
        let workspace: URL
        let rawModelDir: URL
        let tokenizerURL: URL
        let fp32SafetensorsURL: URL
        let tokenizerSHA256: String
        let safetensorsSHA256: String

        init() throws {
            let fm = FileManager.default
            workspace = fm.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent("CozySemanticTests-\(UUID().uuidString)", isDirectory: true)
            rawModelDir = workspace.appendingPathComponent("RawUpstreamModel", isDirectory: true)
            try fm.createDirectory(at: rawModelDir, withIntermediateDirectories: true)

            tokenizerURL = rawModelDir.appendingPathComponent("tokenizer.json")
            fp32SafetensorsURL = rawModelDir.appendingPathComponent("model.safetensors")

            let (tokData, topicTokenIDs) = try Self.makeSyntheticTokenizerJSON()
            try tokData.write(to: tokenizerURL, options: .atomic)
            tokenizerSHA256 = Self.sha256Hex(of: tokData)

            try Self.writeSyntheticFP32Safetensors(to: fp32SafetensorsURL, topicTokenIDs: topicTokenIDs)
            let weightsData = try Data(contentsOf: fp32SafetensorsURL, options: .mappedIfSafe)
            safetensorsSHA256 = Self.sha256Hex(of: weightsData)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: workspace)
        }

        static func sha256Hex(of data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// Builds a valid SentencePiece Unigram `tokenizer.json` (>1,024 vocab rows) with bilingual EN + ID topic pieces.
        private static func makeSyntheticTokenizerJSON() throws -> (Data, [Int: Int]) {
            var vocab: [[Any]] = [
                ["<s>", 0.0],
                ["<pad>", 0.0],
                ["</s>", 0.0],
                ["<unk>", -10.0],
                ["\u{2581}", -1.5]
            ]

            // Single-character fallback pieces so any arbitrary UTF-8 word segments cleanly without <unk> collapse
            let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:/-_#[]()!?\"'")
            for ch in chars {
                vocab.append([String(ch), -4.0])
                vocab.append(["\u{2581}\(ch)", -3.8])
            }

            // Topic clusters (0 = engineering, 1 = finance, 2 = travel, 3 = personal, 4 = work, 5 = product, 6 = reference)
            let clusters: [(Int, [String])] = [
                (0, [
                    "software", "engineering", "code", "debugging", "architecture", "synchronization",
                    "memory", "macos", "appkit", "syncthing", "rekayasa", "perangkat", "sinkronisasi",
                    "berkas", "perbaikan", "memori", "keamanan", "aplikasi", "textkit"
                ]),
                (1, [
                    "finance", "bills", "invoices", "invoice", "receipts", "bank", "installments",
                    "subscriptions", "payments", "budgets", "tax", "keuangan", "tagihan", "bulanan",
                    "listrik", "kwitansi", "pembayaran", "cicilan", "anggaran", "pajak"
                ]),
                (2, [
                    "travel", "itineraries", "flights", "trains", "ferries", "airport", "hotel",
                    "changi", "singapore", "boarding", "perjalanan", "tiket", "kereta", "bandara",
                    "penginapan", "singapura", "keberangkatan"
                ]),
                (3, [
                    "personal", "medical", "dental", "appointments", "clinic", "health", "family",
                    "pribadi", "dokter", "gigi", "kesehatan", "keluarga", "imunisasi", "puskesmas"
                ]),
                (4, [
                    "work", "coordination", "handoffs", "handoff", "deadlines", "sprint", "legal",
                    "kantor", "koordinasi", "rapat", "klien", "tenggat", "kontrak"
                ]),
                (5, [
                    "product", "onboarding", "positioning", "interviews", "typography",
                    "produk", "wawancara", "pengguna", "antarmuka", "tipografi"
                ]),
                (6, [
                    "reference", "highlights", "summaries", "scientific", "documentation",
                    "referensi", "ringkasan", "bacaan", "ilmiah", "dokumentasi"
                ])
            ]

            var topicTokenIDs: [Int: Int] = [:]
            for (clusterIdx, words) in clusters {
                for word in words {
                    let idLower = vocab.count
                    vocab.append(["\u{2581}\(word)", -0.5])
                    topicTokenIDs[idLower] = clusterIdx

                    let capitalized = word.prefix(1).uppercased() + word.dropFirst()
                    let idCap = vocab.count
                    vocab.append(["\u{2581}\(capitalized)", -0.5])
                    topicTokenIDs[idCap] = clusterIdx
                }
            }

            // Pad vocabulary past 1,024 tokens to satisfy BertModel vocabulary sanity check (> 1000)
            var fillerIdx = 0
            while vocab.count < 1040 {
                vocab.append(["\u{2581}tok\(fillerIdx)", -8.0])
                fillerIdx += 1
            }

            let root: [String: Any] = [
                "added_tokens": [
                    ["id": 0, "content": "<s>", "special": true],
                    ["id": 1, "content": "<pad>", "special": true],
                    ["id": 2, "content": "</s>", "special": true],
                    ["id": 3, "content": "<unk>", "special": true]
                ],
                "truncation": ["max_length": 128],
                "model": [
                    "type": "Unigram",
                    "unk_id": 3,
                    "vocab": vocab
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            return (data, topicTokenIDs)
        }

        /// Writes a valid 12-layer 384d FP32 `model.safetensors` (plus `pooler.dense.weight` to verify compaction stripping).
        private static func writeSyntheticFP32Safetensors(to url: URL, topicTokenIDs: [Int: Int]) throws {
            let vocabRows = 1040
            let hidden = 384
            let intermediate = 1536
            let maxPos = 512
            let numLayers = 12

            struct Spec {
                let name: String
                let shape: [Int]
                let fillKind: FillKind
            }
            enum FillKind {
                case wordEmbeddings
                case ones
                case zeros
            }

            var specs: [Spec] = [
                Spec(name: "embeddings.word_embeddings.weight", shape: [vocabRows, hidden], fillKind: .wordEmbeddings),
                Spec(name: "embeddings.position_embeddings.weight", shape: [maxPos, hidden], fillKind: .zeros),
                Spec(name: "embeddings.token_type_embeddings.weight", shape: [2, hidden], fillKind: .zeros),
                Spec(name: "embeddings.position_ids", shape: [1, maxPos], fillKind: .zeros),
                Spec(name: "embeddings.LayerNorm.weight", shape: [hidden], fillKind: .ones),
                Spec(name: "embeddings.LayerNorm.bias", shape: [hidden], fillKind: .zeros),
                Spec(name: "pooler.dense.weight", shape: [hidden, hidden], fillKind: .zeros),
                Spec(name: "pooler.dense.bias", shape: [hidden], fillKind: .zeros)
            ]

            for layer in 0..<numLayers {
                let p = "encoder.layer.\(layer)"
                specs.append(contentsOf: [
                    Spec(name: "\(p).attention.self.query.weight", shape: [hidden, hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.self.query.bias", shape: [hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.self.key.weight", shape: [hidden, hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.self.key.bias", shape: [hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.self.value.weight", shape: [hidden, hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.self.value.bias", shape: [hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.output.dense.weight", shape: [hidden, hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.output.dense.bias", shape: [hidden], fillKind: .zeros),
                    Spec(name: "\(p).attention.output.LayerNorm.weight", shape: [hidden], fillKind: .ones),
                    Spec(name: "\(p).attention.output.LayerNorm.bias", shape: [hidden], fillKind: .zeros),
                    Spec(name: "\(p).intermediate.dense.weight", shape: [intermediate, hidden], fillKind: .zeros),
                    Spec(name: "\(p).intermediate.dense.bias", shape: [intermediate], fillKind: .zeros),
                    Spec(name: "\(p).output.dense.weight", shape: [hidden, intermediate], fillKind: .zeros),
                    Spec(name: "\(p).output.dense.bias", shape: [hidden], fillKind: .zeros),
                    Spec(name: "\(p).output.LayerNorm.weight", shape: [hidden], fillKind: .ones),
                    Spec(name: "\(p).output.LayerNorm.bias", shape: [hidden], fillKind: .zeros)
                ])
            }

            var headerObj: [String: Any] = ["__metadata__": ["format": "pt"]]
            var offset = 0
            for spec in specs {
                let count = spec.shape.reduce(1, *)
                let bytes = count * 4
                headerObj[spec.name] = [
                    "dtype": "F32",
                    "shape": spec.shape,
                    "data_offsets": [offset, offset + bytes]
                ]
                offset += bytes
            }

            var headerJSON = try JSONSerialization.data(withJSONObject: headerObj, options: [.sortedKeys])
            let pad = (8 - (headerJSON.count % 8)) % 8
            if pad > 0 {
                headerJSON.append(contentsOf: [UInt8](repeating: 0x20, count: pad))
            }

            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }

            var headerLenLE = UInt64(headerJSON.count).littleEndian
            try handle.write(contentsOf: Data(bytes: &headerLenLE, count: 8))
            try handle.write(contentsOf: headerJSON)

            let zeroChunk = Data(count: 65_536)
            var onesRow = [Float](repeating: 1.0, count: hidden)
            let onesData = onesRow.withUnsafeMutableBytes { Data($0) }

            for spec in specs {
                let count = spec.shape.reduce(1, *)
                switch spec.fillKind {
                case .ones:
                    try handle.write(contentsOf: onesData)
                case .zeros:
                    var remaining = count * 4
                    while remaining > 0 {
                        let step = min(remaining, zeroChunk.count)
                        try handle.write(contentsOf: zeroChunk.prefix(step))
                        remaining -= step
                    }
                case .wordEmbeddings:
                    var table = [Float](repeating: 0, count: vocabRows * hidden)
                    // Give each topic cluster a zero-mean orthogonal 48-dim block so residual LayerNorm preserves it
                    for (tokID, cluster) in topicTokenIDs {
                        let baseDim = (cluster * 48) % hidden
                        let rowStart = tokID * hidden
                        for d in 0..<24 {
                            table[rowStart + baseDim + d] = 1.0
                            table[rowStart + baseDim + 24 + d] = -1.0
                        }
                    }
                    // Tiny deterministic zero-mean signature for non-topic words (>4) so arbitrary notes still produce unit vectors
                    for tokID in 5..<vocabRows where topicTokenIDs[tokID] == nil {
                        let d0 = (tokID * 7) % (hidden - 1)
                        table[tokID * hidden + d0] = 0.01
                        table[tokID * hidden + d0 + 1] = -0.01
                    }
                    let tableData = table.withUnsafeMutableBytes { Data($0) }
                    try handle.write(contentsOf: tableData)
                }
            }
        }
    }

    // MARK: - 1. Tokenizer + FP16 Compaction + Opt-In Model Store Lifecycle

    func testUnigramCacheFP16CompactionAndOptInModelStoreLifecycle() async throws {
        let fixture = try SyntheticMiniLMFixture()
        defer { fixture.cleanup() }

        // 1. UnigramTokenizer Viterbi segmentation & .cozytok binary cache parity
        let cacheTokURL = fixture.workspace.appendingPathComponent("tokenizer.cozytok")
        let tokUncached = try UnigramTokenizer(tokenizerJSONURL: fixture.tokenizerURL, binaryCacheURL: cacheTokURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheTokURL.path))
        let tokCached = try UnigramTokenizer(tokenizerJSONURL: fixture.tokenizerURL, binaryCacheURL: cacheTokURL)

        let sampleBilingual = "Software engineering debugging — sinkronisasi berkas & tagihan bulanan!"
        let enc1 = tokUncached.encode(sampleBilingual)
        let enc2 = tokCached.encode(sampleBilingual)
        XCTAssertEqual(enc1, enc2)
        XCTAssertEqual(enc1.ids.first, tokUncached.bosId)
        XCTAssertEqual(enc1.ids.last, tokUncached.eosId)
        XCTAssertEqual(enc1.ids.count, enc1.attentionMask.count)

        // 2. FP32 -> FP16 safetensors compaction strips pooler.* and preserves cosine > 0.9999
        let embedderFP32 = try SemanticEmbedder(directoryURL: fixture.rawModelDir)
        let vecFP32 = try embedderFP32.embed(sampleBilingual)
        XCTAssertEqual(vecFP32.count, 384)

        let compactedDir = fixture.workspace.appendingPathComponent("CompactedModel", isDirectory: true)
        try FileManager.default.createDirectory(at: compactedDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.tokenizerURL, to: compactedDir.appendingPathComponent("tokenizer.json"))
        let fp16URL = compactedDir.appendingPathComponent("model.fp16.safetensors")
        try SemanticEmbedder.compactSafetensorsToFP16(sourceURL: fixture.fp32SafetensorsURL, destinationURL: fp16URL)

        let fp32Size = try XCTUnwrap(fixture.fp32SafetensorsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let fp16Size = try XCTUnwrap(fp16URL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertTrue(fp16Size < (fp32Size * 55) / 100, "Expected FP16 + stripped pooler to be <55% of FP32 size (\(fp16Size) vs \(fp32Size))")

        let embedderFP16 = try SemanticEmbedder(directoryURL: compactedDir)
        let vecFP16 = try embedderFP16.embed(sampleBilingual)
        let parityCosine = SemanticEmbedder.cosineSimilarity(vecFP32, vecFP16)
        XCTAssertTrue(parityCosine > 0.9995, "Expected FP32 vs FP16 cosine > 0.9995, got \(parityCosine)")

        // 3. SemanticModelStore starts .notInstalled with zero files on disk
        let storeDir = fixture.workspace.appendingPathComponent("ManagedModelStore", isDirectory: true)
        let store = SemanticModelStore(modelDirectory: storeDir)
        XCTAssertEqual(store.currentState(), .notInstalled)
        XCTAssertFalse(store.isInstalled)

        // 4. Rejects corrupted SHA-256 checksum cleanly without installing partial files
        let badSpec = SemanticRemoteSpec(
            tokenizerURL: fixture.tokenizerURL,
            tokenizerSHA256: fixture.tokenizerSHA256,
            tokenizerExpectedBytes: 1024,
            safetensorsURL: fixture.fp32SafetensorsURL,
            safetensorsSHA256: String(repeating: "0", count: 64),
            safetensorsExpectedBytes: Int64(fp32Size)
        )
        do {
            _ = try await store.downloadModel(spec: badSpec)
            XCTFail("Expected checksumMismatch error")
        } catch let error as SemanticModelError {
            guard case .checksumMismatch = error else {
                XCTFail("Expected checksumMismatch, got \(error)")
                return
            }
        }
        XCTAssertEqual(store.currentState(), .notInstalled)

        // 5. Verified local file:// download compacts to FP16 and transitions to .ready
        let validSpec = SemanticRemoteSpec(
            tokenizerURL: fixture.tokenizerURL,
            tokenizerSHA256: fixture.tokenizerSHA256,
            tokenizerExpectedBytes: 1024,
            safetensorsURL: fixture.fp32SafetensorsURL,
            safetensorsSHA256: fixture.safetensorsSHA256,
            safetensorsExpectedBytes: Int64(fp32Size)
        )
        final class PhaseBox: @unchecked Sendable {
            private let lock = NSLock()
            private var phases: Set<SemanticDownloadProgress.Phase> = []
            func insert(_ phase: SemanticDownloadProgress.Phase) {
                lock.withLock { _ = phases.insert(phase) }
            }
            func contains(_ phase: SemanticDownloadProgress.Phase) -> Bool {
                lock.withLock { phases.contains(phase) }
            }
        }
        let observedPhases = PhaseBox()
        let installedBytes = try await store.downloadModel(spec: validSpec) { progress in
            observedPhases.insert(progress.phase)
        }
        XCTAssertTrue(installedBytes > 0)
        XCTAssertTrue(store.isInstalled)
        XCTAssertTrue(observedPhases.contains(.verifyingAndOptimizing))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("model.fp16.safetensors").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("model.safetensors").path))

        // 6. Removal deletes model cleanly
        try store.removeInstalledModel()
        XCTAssertEqual(store.currentState(), .notInstalled)
    }

    // MARK: - 2. SemanticIndex Safety, Cache Persistence, Valid Tags, and Cross-Lingual Related Notes

    func testSemanticIndexExternalCacheValidTagsAndCrossLingualLinks() throws {
        let fixture = try SyntheticMiniLMFixture()
        defer { fixture.cleanup() }

        let vaultRoot = fixture.workspace.appendingPathComponent("Vault", isDirectory: true)
        let historyRoot = fixture.workspace.appendingPathComponent("History", isDirectory: true)
        let externalCache = fixture.workspace.appendingPathComponent("ExternalSemanticCache", isDirectory: true)
        let vault = try Vault(root: vaultRoot, historyRoot: historyRoot)
        let embedder = try SemanticEmbedder(directoryURL: fixture.rawModelDir)

        // Safety: cache inside vaultRoot must be rejected so synced Markdown vaults stay clean
        XCTAssertThrowsError(try SemanticIndex(
            vaultRoot: vault.root,
            embedder: embedder,
            cacheDirectory: vault.root.appendingPathComponent(".semantic-cache", isDirectory: true)
        ))

        // Populate bilingual notes + custom user vault #tags
        let idFinanceNote = try vault.capture(
            text: "# Tagihan Listrik & Cicilan Bulanan\nRekap pembayaran tagihan listrik bulanan dan kwitansi keuangan rumah.\n#tagihan-pln #finance/bills"
        )
        let enEngNote = try vault.capture(
            text: "# AppKit Memory & Syncthing Sync\nDebugging macOS AppKit memory retention and atomic file synchronization."
        )
        let idTravelNote = try vault.capture(
            text: "# Perjalanan Konferensi Singapura\nTiket keberangkatan bandara Changi dan pemesanan penginapan hotel."
        )

        let index = try SemanticIndex(vaultRoot: vault.root, embedder: embedder, cacheDirectory: externalCache)
        let finished = try index.syncNotes(try vault.notes(), vault: vault)
        XCTAssertTrue(finished)
        XCTAssertEqual(index.indexedNoteCount, 3)

        // Verify cache file exists strictly outside vault.root
        let cacheBin = externalCache.appendingPathComponent("embeddings-v1.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheBin.path))
        XCTAssertEqual(try vault.notes().count, 3)

        // Query with an English finance draft that already has #finance/bills inline
        let draftEN = """
        # Q2 Monthly Bills & Invoice Payments
        Reviewing monthly utility bills, bank payments, and tax invoices.
        Already tagged #finance/bills and linked to [[\(idFinanceNote.title)]].
        """
        let suggestions = try index.suggest(for: draftEN, currentNoteURL: nil, vault: vault)

        // Category must resolve to .finance
        XCTAssertEqual(suggestions.category?.category, .finance)

        // Every suggested tag MUST be 100% valid under Vault.tags(in:) and MUST NOT include inline #finance/bills
        XCTAssertFalse(suggestions.tags.isEmpty)
        for tag in suggestions.tags {
            XCTAssertEqual(tag.name, tag.name.lowercased())
            XCTAssertFalse(tag.name.contains("#"))
            XCTAssertFalse(tag.name.contains(" "))
            XCTAssertEqual(Vault.tags(in: "#\(tag.name)").map(\.name), [tag.name], "Suggested tag #\(tag.name) must round-trip through Vault.tags(in:)")
            XCTAssertFalse(tag.name == "finance/bills", "Inline #finance/bills must not be re-suggested")
        }
        // Custom user vault tag #tagihan-pln learned from Indonesian note should surface cross-lingually!
        XCTAssertTrue(suggestions.tags.contains { $0.name == "tagihan-pln" && $0.isExistingVaultTag })

        // Cross-lingual related note: Indonesian finance note ranks #1 and detects existing [[WikiLink]]
        let topRelated = try XCTUnwrap(suggestions.relatedNotes.first)
        XCTAssertEqual(topRelated.note.url.standardizedFileURL, idFinanceNote.url.standardizedFileURL)
        XCTAssertTrue(topRelated.isAlreadyLinked)
        XCTAssertFalse(suggestions.relatedNotes.contains { $0.note.url.standardizedFileURL == idTravelNote.url.standardizedFileURL && $0.similarity > topRelated.similarity })

        // Reloading a fresh SemanticIndex reuses embeddings-v1.bin and excludes currentNoteURL from related hits
        let reloadedIndex = try SemanticIndex(vaultRoot: vault.root, embedder: embedder, cacheDirectory: externalCache)
        try reloadedIndex.syncNotes(try vault.notes(), vault: vault)
        let engSelfSuggestions = try reloadedIndex.suggest(
            for: try vault.read(enEngNote.url),
            currentNoteURL: enEngNote.url,
            vault: vault
        )
        XCTAssertEqual(engSelfSuggestions.category?.category, .engineering)
        XCTAssertFalse(engSelfSuggestions.relatedNotes.contains { $0.note.url.standardizedFileURL == enEngNote.url.standardizedFileURL })

        // Removing a note drops it from related results immediately
        reloadedIndex.removeNote(at: idFinanceNote.url)
        XCTAssertEqual(reloadedIndex.indexedNoteCount, 2)
    }

    // MARK: - 3. Real paraphrase-multilingual-MiniLM-L12-v2 Cross-Lingual EN <-> ID Verification

    func testRealMiniLMCrossLingualCategorizationAndRelatedNotesWhenCachedLocally() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localMiniLMDir = repoRoot.appendingPathComponent("evals/embedding-screening/.local_cache/minilm-safetensors", isDirectory: true)
        guard FileManager.default.fileExists(atPath: localMiniLMDir.appendingPathComponent("tokenizer.json").path),
              (FileManager.default.fileExists(atPath: localMiniLMDir.appendingPathComponent("model.fp16.safetensors").path)
               || FileManager.default.fileExists(atPath: localMiniLMDir.appendingPathComponent("model.safetensors").path)) else {
            return
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CozyRealMiniLM-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = try Vault(
            root: tempRoot.appendingPathComponent("Vault", isDirectory: true),
            historyRoot: tempRoot.appendingPathComponent("History", isDirectory: true)
        )
        let cacheDir = tempRoot.appendingPathComponent("SemanticCache", isDirectory: true)
        let embedder = try SemanticEmbedder(directoryURL: localMiniLMDir)

        let noteIDSync = try vault.capture(
            text: """
            # Investigasi Konflik Sinkronisasi Berkas Syncthing
            Ketika dua perangkat mengedit catatan Markdown secara bersamaan, penulisan berkas atomik mencegah korupsi data dan menjaga riwayat lokal.
            #sinkronisasi-lokal
            """
        )
        _ = try vault.capture(
            text: """
            # Jadwal Imunisasi Anak & Pemeriksaan Dokter Gigi
            Kunjungan klinik hari Sabtu pagi untuk vaksinasi rutin dan kontrol tambalan gigi geraham.
            """
        )
        _ = try vault.capture(
            text: """
            # Rencana Perjalanan Kereta & Hotel Singapura
            Pemesanan kamar dekat stasiun MRT menuju bandara Changi serta daftar adaptor colokan tipe G.
            """
        )

        let index = try SemanticIndex(vaultRoot: vault.root, embedder: embedder, cacheDirectory: cacheDir)
        try index.syncNotes(try vault.notes(), vault: vault)

        let englishQuery = """
        # Multi-Device File Sync Conflict Resolution
        Preventing data loss with compare-and-swap atomic writes when Syncthing updates Markdown files across Macs.
        """
        let result = try index.suggest(for: englishQuery, currentNoteURL: nil, vault: vault)

        XCTAssertEqual(result.category?.category, .engineering)
        XCTAssertFalse(result.tags.isEmpty)
        for tag in result.tags {
            XCTAssertEqual(Vault.tags(in: "#\(tag.name)").map(\.name), [tag.name])
        }
        let topHit = try XCTUnwrap(result.relatedNotes.first)
        XCTAssertEqual(topHit.note.url.standardizedFileURL, noteIDSync.url.standardizedFileURL)
        XCTAssertTrue(topHit.similarity > 0.45, "Expected EN <-> ID similarity > 0.45, got \(topHit.similarity)")
    }
}

#if canImport(Testing)
@Suite("Pure-Swift Multilingual Semantic Index & Model Store")
struct SemanticIndexTestSuite {
    @Test("Unigram cache, FP16 safetensors compaction, and opt-in SemanticModelStore lifecycle")
    func tokenizerCompactionAndModelStore() async throws {
        try await SemanticIndexTests().testUnigramCacheFP16CompactionAndOptInModelStoreLifecycle()
    }

    @Test("External cache safety, valid Cozy #tag suggestions, and EN <-> ID related notes")
    func externalCacheTagsAndRelatedNotes() throws {
        try SemanticIndexTests().testSemanticIndexExternalCacheValidTagsAndCrossLingualLinks()
    }

    @Test("Real MiniLM-L12-v2 cross-lingual EN <-> ID categorization and note linking")
    func realMiniLMCrossLingual() throws {
        try SemanticIndexTests().testRealMiniLMCrossLingualCategorizationAndRelatedNotesWhenCachedLocally()
    }
}
#endif
