import Foundation
import Accelerate
import CryptoKit
import CozyCore

public enum SemanticCategory: String, CaseIterable, Equatable, Sendable {
    case work
    case engineering
    case product
    case personal
    case finance
    case travel
    case reference

    public var displayName: String {
        switch self {
        case .work: return "Work"
        case .engineering: return "Engineering"
        case .product: return "Product"
        case .personal: return "Personal"
        case .finance: return "Finance"
        case .travel: return "Travel"
        case .reference: return "Reference"
        }
    }
}

public struct SuggestedCategory: Equatable, Sendable {
    public let category: SemanticCategory
    public let score: Float

    public init(category: SemanticCategory, score: Float) {
        self.category = category
        self.score = score
    }
}

public struct SuggestedTag: Equatable, Sendable {
    /// Strictly lowercase Cozy tag name without leading `#`, guaranteed valid under `Vault.tags(in:)`.
    public let name: String
    public let score: Float
    public let isExistingVaultTag: Bool

    public init(name: String, score: Float, isExistingVaultTag: Bool) {
        self.name = name
        self.score = score
        self.isExistingVaultTag = isExistingVaultTag
    }
}

public struct RelatedNoteHit: Equatable, Sendable {
    public let note: NoteRecord
    public let similarity: Float
    public let wikiTarget: String
    public let isAlreadyLinked: Bool

    public init(note: NoteRecord, similarity: Float, wikiTarget: String, isAlreadyLinked: Bool) {
        self.note = note
        self.similarity = similarity
        self.wikiTarget = wikiTarget
        self.isAlreadyLinked = isAlreadyLinked
    }
}

public struct NoteSemanticSuggestions: Equatable, Sendable {
    public let category: SuggestedCategory?
    public let tags: [SuggestedTag]
    public let relatedNotes: [RelatedNoteHit]

    public var isEmpty: Bool {
        category == nil && tags.isEmpty && relatedNotes.isEmpty
    }

    public static let empty = NoteSemanticSuggestions(category: nil, tags: [], relatedNotes: [])

    public init(category: SuggestedCategory?, tags: [SuggestedTag], relatedNotes: [RelatedNoteHit]) {
        self.category = category
        self.tags = tags
        self.relatedNotes = relatedNotes
    }
}

public enum SemanticIndexError: LocalizedError, Sendable {
    case unsafeCacheDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeCacheDirectory(let path):
            return "Semantic cache directory must live outside the synced vault: \(path)"
        }
    }
}

/// Incremental semantic index for Cozy Notes.
/// Stores cached 384d embeddings outside the synced Markdown vault and computes
/// closed-set categories, valid Cozy `#tag` suggestions, and cross-lingual `EN ↔ ID` related notes.
public final class SemanticIndex: @unchecked Sendable {
    public static let defaultMinCategoryScore: Float = 0.22
    public static let defaultMinTagScore: Float = 0.28
    public static let defaultMinRelatedSimilarity: Float = 0.38

    private struct CachedEntry {
        var contentHash: Data // 32-byte SHA256
        var vector: [Float]   // 384 floats
    }

    private struct IndexedNote {
        var record: NoteRecord
        var relativePath: String
        var contentHash: Data
        var vector: [Float]
    }

    private struct StarterTagSpec {
        let tag: String
        let category: SemanticCategory
        let prototypeText: String
    }

    public let vaultRoot: URL
    public let cacheDirectory: URL
    public let embedder: SemanticEmbedder

    private let cacheFileURL: URL
    private let lock = NSLock()
    private var cachedByRelativePath: [String: CachedEntry] = [:]
    private var indexedNotesByURL: [URL: IndexedNote] = [:]
    private var categoryPrototypes: [(category: SemanticCategory, vector: [Float])]?
    private var starterTagPrototypes: [(spec: StarterTagSpec, vector: [Float])]?
    private var customTagNameVectors: [String: [Float]] = [:]

    public init(vaultRoot: URL, embedder: SemanticEmbedder, cacheDirectory: URL? = nil) throws {
        let standardizedVault = vaultRoot.standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(standardizedVault.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let defaultCache = support
            .appendingPathComponent("CozyNotes/SemanticCache", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        let resolvedCache = (cacheDirectory ?? defaultCache).standardizedFileURL.resolvingSymlinksInPath()

        guard resolvedCache.isFileURL,
              !Self.contains(resolvedCache, in: standardizedVault),
              !Self.contains(standardizedVault, in: resolvedCache) else {
            throw SemanticIndexError.unsafeCacheDirectory(resolvedCache.path)
        }

        self.vaultRoot = standardizedVault
        self.cacheDirectory = resolvedCache
        self.cacheFileURL = resolvedCache.appendingPathComponent("embeddings-v1.bin")
        self.embedder = embedder

        self.cachedByRelativePath = Self.loadBinaryCache(from: self.cacheFileURL)
    }

    public var indexedNoteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexedNotesByURL.count
    }

    /// Incrementally synchronizes vault notes, reusing cached 384d vectors when SHA-256 content hashes match.
    /// Returns `true` if synchronization finished without cancellation.
    @discardableResult
    public func syncNotes(
        _ notes: [NoteRecord],
        vault: Vault,
        cancelled: () -> Bool = { false }
    ) throws -> Bool {
        try ensurePrototypesBuilt()
        if cancelled() { return false }

        lock.lock()
        let snapshotCache = cachedByRelativePath
        lock.unlock()

        var updatedCache: [String: CachedEntry] = [:]
        updatedCache.reserveCapacity(notes.count)
        var updatedIndexed: [URL: IndexedNote] = [:]
        updatedIndexed.reserveCapacity(notes.count)
        var cacheDirty = false

        for note in notes {
            if cancelled() { return false }
            let stdURL = note.url.standardizedFileURL.resolvingSymlinksInPath()
            let relPath = Self.relativePath(for: stdURL, root: vaultRoot)
            guard let content = try? vault.read(note.url) else { continue }
            let hashData = Data(SHA256.hash(data: Data(content.utf8)))

            let vector: [Float]
            if let existing = snapshotCache[relPath],
               existing.contentHash == hashData,
               existing.vector.count == SemanticEmbedder.dimension {
                vector = existing.vector
            } else {
                vector = try embedder.embed(Self.embeddingInput(title: note.title, content: content))
                cacheDirty = true
            }

            let entry = CachedEntry(contentHash: hashData, vector: vector)
            updatedCache[relPath] = entry
            updatedIndexed[stdURL] = IndexedNote(
                record: note,
                relativePath: relPath,
                contentHash: hashData,
                vector: vector
            )
        }

        if snapshotCache.count != updatedCache.count {
            cacheDirty = true
        }

        if cancelled() { return false }

        lock.lock()
        cachedByRelativePath = updatedCache
        indexedNotesByURL = updatedIndexed
        lock.unlock()

        if cacheDirty {
            try? Self.saveBinaryCache(updatedCache, to: cacheFileURL)
        }
        return true
    }

    /// Incrementally updates or inserts a single note after save without rescanning the vault.
    public func upsertNote(_ record: NoteRecord, content: String) throws {
        try ensurePrototypesBuilt()
        let stdURL = record.url.standardizedFileURL.resolvingSymlinksInPath()
        let relPath = Self.relativePath(for: stdURL, root: vaultRoot)
        let hashData = Data(SHA256.hash(data: Data(content.utf8)))

        lock.lock()
        let existing = cachedByRelativePath[relPath]
        lock.unlock()

        let vector: [Float]
        let changed: Bool
        if let existing, existing.contentHash == hashData, existing.vector.count == SemanticEmbedder.dimension {
            vector = existing.vector
            changed = false
        } else {
            vector = try embedder.embed(Self.embeddingInput(title: record.title, content: content))
            changed = true
        }

        var snapshotToSave: [String: CachedEntry]?
        lock.lock()
        let entry = CachedEntry(contentHash: hashData, vector: vector)
        cachedByRelativePath[relPath] = entry
        indexedNotesByURL[stdURL] = IndexedNote(
            record: record,
            relativePath: relPath,
            contentHash: hashData,
            vector: vector
        )
        if changed {
            snapshotToSave = cachedByRelativePath
        }
        lock.unlock()

        if let snapshotToSave {
            try? Self.saveBinaryCache(snapshotToSave, to: cacheFileURL)
        }
    }

    public func removeNote(at url: URL) {
        let stdURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let relPath = Self.relativePath(for: stdURL, root: vaultRoot)
        var snapshotToSave: [String: CachedEntry]?
        lock.lock()
        indexedNotesByURL.removeValue(forKey: stdURL)
        if cachedByRelativePath.removeValue(forKey: relPath) != nil {
            snapshotToSave = cachedByRelativePath
        }
        lock.unlock()

        if let snapshotToSave {
            try? Self.saveBinaryCache(snapshotToSave, to: cacheFileURL)
        }
    }

    /// Computes category, Cozy `#tag`, and cross-lingual `EN ↔ ID` related note suggestions for `text`.
    public func suggest(
        for text: String,
        currentNoteURL: URL? = nil,
        vault: Vault? = nil,
        maxTags: Int = 4,
        maxRelated: Int = 4,
        minCategoryScore: Float = SemanticIndex.defaultMinCategoryScore,
        minTagScore: Float = SemanticIndex.defaultMinTagScore,
        minRelatedSimilarity: Float = SemanticIndex.defaultMinRelatedSimilarity
    ) throws -> NoteSemanticSuggestions {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else {
            return .empty
        }

        try ensurePrototypesBuilt()
        let queryVector = try embedder.embed(trimmed)

        lock.lock()
        let catProtos = categoryPrototypes ?? []
        let starterProtos = starterTagPrototypes ?? []
        let indexedSnapshot = Array(indexedNotesByURL.values)
        lock.unlock()

        // 1. Closed 7-category classification
        var bestCategory: SuggestedCategory?
        for item in catProtos {
            let sim = SemanticEmbedder.cosineSimilarity(queryVector, item.vector)
            if sim >= minCategoryScore, sim > (bestCategory?.score ?? -1) {
                bestCategory = SuggestedCategory(category: item.category, score: sim)
            }
        }

        let currentStdURL = currentNoteURL?.standardizedFileURL.resolvingSymlinksInPath()
        let inlineTags = Set(Vault.extractTagNames(from: text).map { $0.lowercased() })

        // 2. Build candidate tag centroids (blending user's existing vault tags + 21 starter tags)
        var vaultTagSums: [String: (sum: [Float], count: Int)] = [:]
        for entry in indexedSnapshot where entry.record.url.standardizedFileURL.resolvingSymlinksInPath() != currentStdURL {
            for rawTag in entry.record.tags {
                let tag = rawTag.lowercased()
                guard Self.isValidCozyTagName(tag) else { continue }
                if var acc = vaultTagSums[tag] {
                    vDSP_vadd(acc.sum, 1, entry.vector, 1, &acc.sum, 1, vDSP_Length(SemanticEmbedder.dimension))
                    acc.count += 1
                    vaultTagSums[tag] = acc
                } else {
                    vaultTagSums[tag] = (entry.vector, 1)
                }
            }
        }

        var starterByTag: [String: (spec: StarterTagSpec, vector: [Float])] = [:]
        starterByTag.reserveCapacity(starterProtos.count)
        for p in starterProtos {
            starterByTag[p.spec.tag] = p
        }

        var allCandidateTags = Set(starterByTag.keys)
        allCandidateTags.formUnion(vaultTagSums.keys)

        var scoredTags: [SuggestedTag] = []
        scoredTags.reserveCapacity(allCandidateTags.count)

        for tag in allCandidateTags {
            guard !inlineTags.contains(tag), Self.isValidCozyTagName(tag) else { continue }
            let vaultEntry = vaultTagSums[tag]
            let isExisting = vaultEntry != nil

            let centroid: [Float]
            if let starter = starterByTag[tag], var userCentroid = vaultEntry?.sum {
                SemanticEmbedder.l2Normalize(&userCentroid)
                centroid = Self.blendNormalized(primary: userCentroid, primaryWeight: 0.65, secondary: starter.vector, secondaryWeight: 0.35)
            } else if let starter = starterByTag[tag] {
                centroid = starter.vector
            } else if var userCentroid = vaultEntry?.sum {
                SemanticEmbedder.l2Normalize(&userCentroid)
                if let labelVec = try? customTagVector(for: tag) {
                    centroid = Self.blendNormalized(primary: userCentroid, primaryWeight: 0.75, secondary: labelVec, secondaryWeight: 0.25)
                } else {
                    centroid = userCentroid
                }
            } else {
                continue
            }

            var score = SemanticEmbedder.cosineSimilarity(queryVector, centroid)
            if let starter = starterByTag[tag], starter.spec.category == bestCategory?.category {
                score += 0.025
            }
            if isExisting {
                score += 0.020
            }

            if score >= minTagScore {
                scoredTags.append(SuggestedTag(name: tag, score: min(1.0, score), isExistingVaultTag: isExisting))
            }
        }

        scoredTags.sort { a, b in
            if abs(a.score - b.score) > 1.0e-5 { return a.score > b.score }
            if a.isExistingVaultTag != b.isExistingVaultTag { return a.isExistingVaultTag && !b.isExistingVaultTag }
            return a.name < b.name
        }
        let topTags = Array(scoredTags.prefix(max(0, maxTags)))

        // 3. Cross-lingual EN <-> ID related notes
        let allRecords = indexedSnapshot.map(\.record)
        let linkedURLs: Set<URL> = Self.linkedNoteURLs(in: text, candidates: allRecords, vault: vault, root: vaultRoot)

        var relatedHits: [RelatedNoteHit] = []
        for entry in indexedSnapshot {
            let entryStdURL = entry.record.url.standardizedFileURL.resolvingSymlinksInPath()
            if let currentStdURL, entryStdURL == currentStdURL { continue }

            let sim = SemanticEmbedder.cosineSimilarity(queryVector, entry.vector)
            guard sim >= minRelatedSimilarity else { continue }

            let wikiTarget = Self.preferredWikiTarget(for: entry.record, in: allRecords, vault: vault, root: vaultRoot)
            let alreadyLinked = linkedURLs.contains(entryStdURL)
            relatedHits.append(RelatedNoteHit(
                note: entry.record,
                similarity: sim,
                wikiTarget: wikiTarget,
                isAlreadyLinked: alreadyLinked
            ))
        }

        relatedHits.sort { a, b in
            if abs(a.similarity - b.similarity) > 1.0e-5 { return a.similarity > b.similarity }
            if a.note.modifiedAt != b.note.modifiedAt { return a.note.modifiedAt > b.note.modifiedAt }
            return a.note.url.path < b.note.url.path
        }
        let topRelated = Array(relatedHits.prefix(max(0, maxRelated)))

        return NoteSemanticSuggestions(
            category: bestCategory,
            tags: topTags,
            relatedNotes: topRelated
        )
    }

    public static func isValidCozyTagName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == trimmed.lowercased(),
              !trimmed.contains(where: \.isWhitespace) else {
            return false
        }
        let probe = "#" + trimmed
        let parsed = Vault.tags(in: probe)
        return parsed.count == 1
            && parsed[0].name == trimmed
            && parsed[0].fullRange == NSRange(location: 0, length: (probe as NSString).length)
    }

    // MARK: - Prototypes & Helpers

    private func ensurePrototypesBuilt() throws {
        lock.lock()
        if categoryPrototypes != nil && starterTagPrototypes != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let probeVec = try embedder.embed("cozy-proto-v1")
        let protoCacheURL = cacheDirectory.appendingPathComponent("prototypes-v1.bin")
        let totalExpected = Self.categoryPrototypeSpecs.count + Self.starterTagSpecs.count

        if let cached = Self.loadPrototypesCache(from: protoCacheURL, expectedCount: totalExpected, probeVector: probeVec) {
            let catCount = Self.categoryPrototypeSpecs.count
            var loadedCats: [(SemanticCategory, [Float])] = []
            loadedCats.reserveCapacity(catCount)
            for idx in 0..<catCount {
                loadedCats.append((Self.categoryPrototypeSpecs[idx].0, cached[idx]))
            }
            var loadedTags: [(StarterTagSpec, [Float])] = []
            loadedTags.reserveCapacity(Self.starterTagSpecs.count)
            for idx in 0..<Self.starterTagSpecs.count {
                loadedTags.append((Self.starterTagSpecs[idx], cached[catCount + idx]))
            }
            lock.lock()
            if categoryPrototypes == nil { categoryPrototypes = loadedCats }
            if starterTagPrototypes == nil { starterTagPrototypes = loadedTags }
            lock.unlock()
            return
        }

        var builtCats: [(SemanticCategory, [Float])] = []
        builtCats.reserveCapacity(Self.categoryPrototypeSpecs.count)
        var allVectors: [[Float]] = []
        allVectors.reserveCapacity(totalExpected)

        for (cat, protoText) in Self.categoryPrototypeSpecs {
            let vec = try embedder.embed(protoText)
            builtCats.append((cat, vec))
            allVectors.append(vec)
        }

        var builtTags: [(StarterTagSpec, [Float])] = []
        builtTags.reserveCapacity(Self.starterTagSpecs.count)
        for spec in Self.starterTagSpecs {
            let vec = try embedder.embed(spec.prototypeText)
            builtTags.append((spec, vec))
            allVectors.append(vec)
        }

        try? Self.savePrototypesCache(allVectors, probeVector: probeVec, to: protoCacheURL)

        lock.lock()
        if categoryPrototypes == nil {
            categoryPrototypes = builtCats
        }
        if starterTagPrototypes == nil {
            starterTagPrototypes = builtTags
        }
        lock.unlock()
    }

    private static let protoCacheMagic: [UInt8] = Array("COZYPRT1".utf8)

    private static var prototypeDefinitionDigest: Data {
        var raw = ""
        for (cat, text) in categoryPrototypeSpecs { raw += "\(cat.rawValue):\(text)\n" }
        for spec in starterTagSpecs { raw += "\(spec.tag):\(spec.category.rawValue):\(spec.prototypeText)\n" }
        return Data(SHA256.hash(data: Data(raw.utf8)))
    }

    private static func loadPrototypesCache(from url: URL, expectedCount: Int, probeVector: [Float]) -> [[Float]]? {
        let dim = SemanticEmbedder.dimension
        let vecBytes = dim * 4
        let expectedBytes = 8 + 32 + vecBytes + 4 + expectedCount * vecBytes
        guard let data = try? Data(contentsOf: url), data.count == expectedBytes else { return nil }
        return data.withUnsafeBytes { raw -> [[Float]]? in
            for i in 0..<8 where raw[i] != protoCacheMagic[i] { return nil }
            let digest = Data(raw[8..<40])
            guard digest == prototypeDefinitionDigest, let base = raw.baseAddress else { return nil }

            var storedProbe = [Float](repeating: 0, count: dim)
            storedProbe.withUnsafeMutableBytes { dst in
                if let d = dst.baseAddress { memcpy(d, base.advanced(by: 40), vecBytes) }
            }
            guard SemanticEmbedder.cosineSimilarity(storedProbe, probeVector) > 0.9999 else { return nil }

            let count = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 40 + vecBytes, as: UInt32.self)))
            guard count == expectedCount else { return nil }

            var out: [[Float]] = []
            out.reserveCapacity(count)
            var cursor = 44 + vecBytes
            for _ in 0..<count {
                var v = [Float](repeating: 0, count: dim)
                v.withUnsafeMutableBytes { dst in
                    if let d = dst.baseAddress { memcpy(d, base.advanced(by: cursor), vecBytes) }
                }
                out.append(v)
                cursor += vecBytes
            }
            return out
        }
    }

    private static func savePrototypesCache(_ vectors: [[Float]], probeVector: [Float], to url: URL) throws {
        let dim = SemanticEmbedder.dimension
        guard probeVector.count == dim else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var out = Data()
        out.reserveCapacity(44 + (vectors.count + 1) * dim * 4)
        out.append(contentsOf: protoCacheMagic)
        out.append(prototypeDefinitionDigest)
        probeVector.withUnsafeBytes { out.append(contentsOf: $0) }
        var countLE = UInt32(vectors.count).littleEndian
        withUnsafeBytes(of: &countLE) { out.append(contentsOf: $0) }
        for v in vectors where v.count == dim {
            v.withUnsafeBytes { out.append(contentsOf: $0) }
        }
        try out.write(to: url, options: .atomic)
    }

    private func customTagVector(for tag: String) throws -> [Float] {
        lock.lock()
        if let existing = customTagNameVectors[tag] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let humanized = tag
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let label = "Topic #\(tag): \(humanized). Catatan bertopik \(humanized)."
        let vec = try embedder.embed(label)

        lock.lock()
        customTagNameVectors[tag] = vec
        lock.unlock()
        return vec
    }

    private static func blendNormalized(
        primary: [Float],
        primaryWeight: Float,
        secondary: [Float],
        secondaryWeight: Float
    ) -> [Float] {
        var out = [Float](repeating: 0, count: SemanticEmbedder.dimension)
        var w1 = primaryWeight
        var w2 = secondaryWeight
        vDSP_vsma(primary, 1, &w1, out, 1, &out, 1, vDSP_Length(SemanticEmbedder.dimension))
        vDSP_vsma(secondary, 1, &w2, out, 1, &out, 1, vDSP_Length(SemanticEmbedder.dimension))
        SemanticEmbedder.l2Normalize(&out)
        return out
    }

    private static func embeddingInput(title: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return title }
        if trimmed.hasPrefix("#") {
            return trimmed
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty || trimmed.localizedCaseInsensitiveContains(cleanTitle) {
            return trimmed
        }
        return "\(cleanTitle)\n\n\(trimmed)"
    }

    private static func linkedNoteURLs(
        in text: String,
        candidates: [NoteRecord],
        vault: Vault?,
        root: URL
    ) -> Set<URL> {
        let links = Vault.wikiLinks(in: text)
        guard !links.isEmpty else { return [] }
        var urls: Set<URL> = []
        for link in links {
            if let vault, let match = try? vault.resolveNote(matching: link.target, in: candidates) {
                urls.insert(match.url.standardizedFileURL.resolvingSymlinksInPath())
            } else if let fallback = fallbackResolve(target: link.target, in: candidates, root: root) {
                urls.insert(fallback.url.standardizedFileURL.resolvingSymlinksInPath())
            }
        }
        return urls
    }

    private static func preferredWikiTarget(
        for note: NoteRecord,
        in candidates: [NoteRecord],
        vault: Vault?,
        root: URL
    ) -> String {
        let cleanedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetStdURL = note.url.standardizedFileURL.resolvingSymlinksInPath()
        if !cleanedTitle.isEmpty,
           !cleanedTitle.contains("["),
           !cleanedTitle.contains("]"),
           !cleanedTitle.contains("|"),
           !cleanedTitle.contains("#") {
            if let vault {
                if let resolved = try? vault.resolveNote(matching: cleanedTitle, in: candidates),
                   resolved.url.standardizedFileURL.resolvingSymlinksInPath() == targetStdURL {
                    return cleanedTitle
                }
            } else if fallbackResolve(target: cleanedTitle, in: candidates, root: root)?.url.standardizedFileURL.resolvingSymlinksInPath() == targetStdURL {
                return cleanedTitle
            }
        }

        let stem = note.url.deletingPathExtension().lastPathComponent
        if !stem.isEmpty {
            if let vault,
               let resolved = try? vault.resolveNote(matching: stem, in: candidates),
               resolved.url.standardizedFileURL.resolvingSymlinksInPath() == targetStdURL {
                return stem
            } else if vault == nil,
                      fallbackResolve(target: stem, in: candidates, root: root)?.url.standardizedFileURL.resolvingSymlinksInPath() == targetStdURL {
                return stem
            }
        }

        let rel = relativePath(for: targetStdURL, root: root)
        return (rel as NSString).deletingPathExtension
    }

    private static func fallbackResolve(target rawTarget: String, in candidates: [NoteRecord], root: URL) -> NoteRecord? {
        let cleaned = Vault.normalizedWikiTarget(rawTarget)
        guard !cleaned.isEmpty else { return nil }
        if let exact = candidates.first(where: { $0.title == cleaned }) { return exact }
        if let ci = candidates.first(where: { $0.title.caseInsensitiveCompare(cleaned) == .orderedSame }) { return ci }
        let stemMatches = candidates.first {
            $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(cleaned) == .orderedSame
        }
        return stemMatches
    }

    private static func relativePath(for fileURL: URL, root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if fileURL.path.hasPrefix(prefix) {
            return String(fileURL.path.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    // MARK: - Binary Embedding Cache (`COZYSEM1`)

    private static let cacheMagic: [UInt8] = Array("COZYSEM1".utf8)

    private static func loadBinaryCache(from fileURL: URL) -> [String: CachedEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              data.count >= 16 else {
            return [:]
        }
        return data.withUnsafeBytes { raw -> [String: CachedEntry] in
            guard raw.count >= 16 else { return [:] }
            for i in 0..<8 where raw[i] != cacheMagic[i] {
                return [:]
            }
            let dim = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            let count = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            guard dim == SemanticEmbedder.dimension, count >= 0, count <= 200_000 else {
                return [:]
            }

            var cursor = 16
            var loaded: [String: CachedEntry] = [:]
            loaded.reserveCapacity(min(count, 4096))
            let vecBytes = dim * 4

            for _ in 0..<count {
                guard cursor + 4 <= raw.count else { return [:] }
                let pathLen = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)))
                cursor += 4
                guard pathLen > 0, pathLen <= 4096, cursor + pathLen + 32 + vecBytes <= raw.count else {
                    return [:]
                }
                let pathSlice = Data(raw[cursor..<(cursor + pathLen)])
                cursor += pathLen
                guard let relPath = String(data: pathSlice, encoding: .utf8) else { return [:] }

                let hashData = Data(raw[cursor..<(cursor + 32)])
                cursor += 32

                var vec = [Float](repeating: 0, count: dim)
                for idx in 0..<dim {
                    let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor + idx * 4, as: UInt32.self))
                    vec[idx] = Float(bitPattern: bits)
                }
                cursor += vecBytes
                loaded[relPath] = CachedEntry(contentHash: hashData, vector: vec)
            }
            return loaded
        }
    }

    private static func saveBinaryCache(_ entries: [String: CachedEntry], to fileURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sortedKeys = entries.keys.sorted()
        let dim = SemanticEmbedder.dimension
        var out = Data()
        out.reserveCapacity(16 + sortedKeys.count * (64 + dim * 4))
        out.append(contentsOf: cacheMagic)

        var dimLE = UInt32(dim).littleEndian
        var countLE = UInt32(sortedKeys.count).littleEndian
        withUnsafeBytes(of: &dimLE) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &countLE) { out.append(contentsOf: $0) }

        for key in sortedKeys {
            guard let entry = entries[key],
                  entry.contentHash.count == 32,
                  entry.vector.count == dim else {
                continue
            }
            let keyBytes = Array(key.utf8)
            var keyLenLE = UInt32(keyBytes.count).littleEndian
            withUnsafeBytes(of: &keyLenLE) { out.append(contentsOf: $0) }
            out.append(contentsOf: keyBytes)
            out.append(entry.contentHash)
            for value in entry.vector {
                var bitsLE = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bitsLE) { out.append(contentsOf: $0) }
            }
        }

        try out.write(to: fileURL, options: .atomic)
    }

    // MARK: - Bilingual EN + ID Prototypes

    private static let categoryPrototypeSpecs: [(SemanticCategory, String)] = [
        (.work, "Work tasks, project coordination, team syncs, action items, client handoffs, legal or operational reviews, and deadlines. Catatan pekerjaan kantor, koordinasi tim, tindak lanjut rapat, serah terima klien, dan tenggat proyek."),
        (.engineering, "Software engineering, code debugging, system architecture, file synchronization, memory leaks, operating system security, CLI commands, and incident postmortems. Rekayasa perangkat lunak, arsitektur sistem, sinkronisasi berkas, perbaikan bug, dan keamanan aplikasi."),
        (.product, "Product strategy, user experience design, user interviews, onboarding flows, market positioning, and feature prioritization. Strategi produk, riset dan wawancara pengguna, alur orientasi aplikasi, dan prinsip pengalaman pengguna."),
        (.personal, "Personal life, medical or dental appointments, family health, clinic visits, vaccinations, household errands, and daily reminders. Urusan pribadi, jadwal dokter atau gigi, kesehatan keluarga, imunisasi anak, dan pengingat rumah tangga."),
        (.finance, "Personal and business finance, bills, invoices, receipts, bank transfers, installments, subscriptions, payments, and budgets. Keuangan, tagihan bulanan, kwitansi pembayaran, cicilan tabungan, langganan tahunan, dan anggaran biaya."),
        (.travel, "Travel itineraries, flights, trains, ferries, airport or port transit, hotel bookings, boarding passes, and packing checklists. Rencana perjalanan, tiket kereta atau kapal feri, transit bandara, penginapan hotel, dan persiapan keberangkatan."),
        (.reference, "General reference notes, book highlights, reading summaries, scientific concepts, learning notes, and evergreen documentation. Catatan referensi umum, ringkasan buku bacaan, kutipan konsep ilmiah, dan kumpulan pengetahuan.")
    ]

    private static let starterTagSpecs: [StarterTagSpec] = [
        StarterTagSpec(tag: "work/q2", category: .work, prototypeText: "Quarterly sprint planning, Q2 audit action items, and team milestones. Rencana kerja kuartal dan audit tim."),
        StarterTagSpec(tag: "work/handoff", category: .work, prototypeText: "One-on-one meeting recaps, client documentation handoff, and operations coordination. Serah terima dokumentasi klien dan rekap koordinasi tim operasional."),
        StarterTagSpec(tag: "legal/q2", category: .work, prototypeText: "Vendor contracts, data processing agreements, legal clause revisions, and contract signing. Revisi kontrak vendor dan klausul tim hukum."),
        StarterTagSpec(tag: "engineering/sync", category: .engineering, prototypeText: "Multi-device file synchronization, Syncthing conflict resolution, compare-and-swap saves, FSEvents watchers, and atomic temporary file writes. Sinkronisasi berkas antar perangkat, resolusi konflik, dan penulisan berkas atomik."),
        StarterTagSpec(tag: "engineering/macos", category: .engineering, prototypeText: "macOS app packaging, Gatekeeper quarantine security, checksum verification, AppKit NSTextStorage memory leaks, and desktop native internals. Keamanan Gatekeeper macOS, instalasi aplikasi, dan perbaikan memori AppKit."),
        StarterTagSpec(tag: "engineering/incident", category: .engineering, prototypeText: "Bug postmortems, crash investigations, race conditions, and production safety rules. Investigasi insiden bug, kondisi balapan, dan catatan kegagalan sistem."),
        StarterTagSpec(tag: "product/positioning", category: .product, prototypeText: "Product positioning, target developer audience, bilingual local-first capture value proposition, and launch messaging. Posisi produk untuk pengembang dan catatan lokal dua bahasa."),
        StarterTagSpec(tag: "product/onboarding", category: .product, prototypeText: "User research interviews, onboarding empty states, UI clarity, and reducing friction before typing. Wawancara pengguna baru, tampilan awal aplikasi, dan kemudahan antarmuka."),
        StarterTagSpec(tag: "product/design", category: .product, prototypeText: "Typography, visual atmosphere themes, keyboard-first editor navigation, and Markdown workspace craft. Tipografi, tema tampilan editor, dan navigasi papan ketik."),
        StarterTagSpec(tag: "personal/health", category: .personal, prototypeText: "Doctor lab appointments, blood tests, dental crown visits, prescriptions, and medication instructions. Jadwal pemeriksaan laboratorium, dokter gigi, dan aturan minum obat."),
        StarterTagSpec(tag: "personal/family", category: .personal, prototypeText: "Family care, child immunization schedules at community clinics, and household reminders for relatives. Jadwal imunisasi anak di puskesmas dan urusan keluarga."),
        StarterTagSpec(tag: "personal/errands", category: .personal, prototypeText: "Everyday personal errands, shopping pickups, and household chores. Keperluan harian rumah tangga dan belanja pribadi."),
        StarterTagSpec(tag: "finance/bills", category: .finance, prototypeText: "Monthly electricity utility bills, neighborhood dues, clinic payment receipts, and bank virtual account transfers. Tagihan listrik bulanan, iuran warga, dan bukti pembayaran tunai."),
        StarterTagSpec(tag: "finance/subscriptions", category: .finance, prototypeText: "Annual software or cloud subscriptions, shared family plan renewals, invoices, and cancelling card auto-renewal. Langganan tahunan perangkat lunak, tagihan layanan awan, dan perpanjangan otomatis."),
        StarterTagSpec(tag: "finance/installments", category: .finance, prototypeText: "Monthly installment payments, automatic bank savings debits, and remaining loan payoff balances. Cicilan bulanan autodebet tabungan dan sisa pelunasan."),
        StarterTagSpec(tag: "travel/sg", category: .travel, prototypeText: "Singapore conference travel, Changi airport flights, hotel deposit, local eSIM, and Type G adapter checklist. Perjalanan konferensi Singapura, bandara Changi, dan daftar bawaan."),
        StarterTagSpec(tag: "travel/transit", category: .travel, prototypeText: "Train departures, ferry port boarding passes, airport rail connections, Suica transit cards, and arrival buffer times. Keberangkatan kereta api, pelabuhan kapal feri, dan koneksi kereta bandara."),
        StarterTagSpec(tag: "travel/lodging", category: .travel, prototypeText: "Hotel reservations, check-in deposits, and overnight accommodation notes. Pemesanan kamar hotel dan deposit penginapan."),
        StarterTagSpec(tag: "reference/reading", category: .reference, prototypeText: "Book notes, reading highlights, research problem-solving essays, and commonplace quotes. Catatan buku bacaan, kutipan esai ilmiah, dan ide riset."),
        StarterTagSpec(tag: "reference/docs", category: .reference, prototypeText: "Technical reference manuals, architecture overview documentation, and recovery checkpoint guides. Dokumentasi panduan teknis, arsitektur aplikasi, dan pemulihan cadangan."),
        StarterTagSpec(tag: "reference/security", category: .reference, prototypeText: "Security verification references, SHA-256 checksums, symlink protection flags, and safe OS configuration practices. Panduan verifikasi keamanan checksum dan konfigurasi sistem.")
    ]
}
