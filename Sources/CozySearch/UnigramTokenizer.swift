import Foundation

public enum SemanticTokenizerError: LocalizedError, Sendable {
    case missingTokenizerFile(URL)
    case invalidTokenizerJSON(String)

    public var errorDescription: String? {
        switch self {
        case .missingTokenizerFile(let url):
            return "Missing tokenizer.json at \(url.path)"
        case .invalidTokenizerJSON(let detail):
            return "Invalid tokenizer configuration: \(detail)"
        }
    }
}

public struct TokenizedEncoding: Equatable, Sendable {
    public let ids: [Int32]
    public let attentionMask: [Int32]

    public init(ids: [Int32], attentionMask: [Int32]) {
        self.ids = ids
        self.attentionMask = attentionMask
    }
}

/// Pure-Swift SentencePiece Unigram + Precompiled Darts normalizer compatible with HuggingFace `tokenizer.json`.
public final class UnigramTokenizer: Sendable {
    private struct HashSlot: Sendable {
        var offset: UInt32
        var length: UInt16
        var hashTag: UInt16
        var tokenId: Int32
        var score: Float
    }

    public let vocabSize: Int
    public let bosId: Int32
    public let padId: Int32
    public let eosId: Int32
    public let unkId: Int32
    public let defaultMaxLength: Int

    private let precompiledTrie: [UInt32]
    private let precompiledPool: [UInt8]
    private let vocabBytes: [UInt8]
    private let hashTable: [HashSlot]
    private let hashMask: Int
    private let maxPieceBytes: Int
    private let unkScore: Float

    private static let cacheMagic: [UInt8] = [0x43, 0x5A, 0x54, 0x4B, 0x00, 0x00, 0x00, 0x01] // "CZTK\0\0\0\x01"
    private static let fnvOffsetBasis: UInt64 = 14695981039346656037
    private static let fnvPrime: UInt64 = 1099511628211
    private static let metaspaceUTF8: [UInt8] = [0xE2, 0x96, 0x81] // "▁" (U+2581)

    public convenience init(directoryURL: URL) throws {
        let jsonURL = directoryURL.appendingPathComponent("tokenizer.json")
        let cacheURL = directoryURL.appendingPathComponent("tokenizer.cozytok")
        try self.init(tokenizerJSONURL: jsonURL, binaryCacheURL: cacheURL)
    }

    public init(tokenizerJSONURL: URL, binaryCacheURL: URL? = nil) throws {
        guard FileManager.default.fileExists(atPath: tokenizerJSONURL.path) else {
            throw SemanticTokenizerError.missingTokenizerFile(tokenizerJSONURL)
        }
        let jsonSourceSize = (try? tokenizerJSONURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0

        if let binaryCacheURL,
           jsonSourceSize > 0,
           let cached = try? Self.loadBinaryCache(from: binaryCacheURL, expectedSourceSize: jsonSourceSize) {
            self.vocabSize = cached.vocabSize
            self.bosId = cached.bosId
            self.padId = cached.padId
            self.eosId = cached.eosId
            self.unkId = cached.unkId
            self.defaultMaxLength = cached.defaultMaxLength
            self.precompiledTrie = cached.precompiledTrie
            self.precompiledPool = cached.precompiledPool
            self.vocabBytes = cached.vocabBytes
            self.maxPieceBytes = cached.maxPieceBytes
            self.unkScore = cached.unkScore
            let built = Self.buildHashTable(entries: cached.entries, vocabBytes: cached.vocabBytes)
            self.hashTable = built.slots
            self.hashMask = built.mask
            return
        }

        let rawData = try Data(contentsOf: tokenizerJSONURL, options: .mappedIfSafe)
        guard let root = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw SemanticTokenizerError.invalidTokenizerJSON("Root is not a JSON object")
        }

        // Parse Precompiled normalizer if present
        var trieUnits: [UInt32] = []
        var triePool: [UInt8] = []
        if let normDict = root["normalizer"] as? [String: Any],
           let b64 = normDict["precompiled_charsmap"] as? String,
           let decoded = Data(base64Encoded: b64),
           decoded.count >= 4 {
            let trieByteLen = decoded.withUnsafeBytes { ptr -> Int in
                Int(UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
            }
            if trieByteLen > 0, trieByteLen % 4 == 0, 4 + trieByteLen <= decoded.count {
                let unitCount = trieByteLen / 4
                trieUnits = [UInt32](unsafeUninitializedCapacity: unitCount) { buf, initialized in
                    decoded.withUnsafeBytes { rawPtr in
                        for idx in 0..<unitCount {
                            let val = rawPtr.loadUnaligned(fromByteOffset: 4 + idx * 4, as: UInt32.self)
                            buf[idx] = UInt32(littleEndian: val)
                        }
                    }
                    initialized = unitCount
                }
                triePool = Array(decoded[(4 + trieByteLen)...])
            }
        }

        // Special token IDs
        var specialIDs = Set<Int>()
        var detectedBos: Int32 = 0
        var detectedPad: Int32 = 1
        var detectedEos: Int32 = 2
        if let added = root["added_tokens"] as? [[String: Any]] {
            for tok in added {
                guard let id = tok["id"] as? Int, let content = tok["content"] as? String else { continue }
                if (tok["special"] as? Bool) == true {
                    specialIDs.insert(id)
                }
                switch content {
                case "<s>", "[CLS]": detectedBos = Int32(id)
                case "<pad>", "[PAD]": detectedPad = Int32(id)
                case "</s>", "[SEP]": detectedEos = Int32(id)
                default: break
                }
            }
        }

        var maxLen = 128
        if let truncDict = root["truncation"] as? [String: Any],
           let m = truncDict["max_length"] as? Int, m >= 8 {
            maxLen = m
        }

        guard let modelDict = root["model"] as? [String: Any],
              let vocabArray = modelDict["vocab"] as? [[Any]],
              !vocabArray.isEmpty else {
            throw SemanticTokenizerError.invalidTokenizerJSON("Missing model.vocab array")
        }
        let parsedUnkId = Int32((modelDict["unk_id"] as? Int) ?? 3)
        specialIDs.insert(Int(detectedBos))
        specialIDs.insert(Int(detectedPad))
        specialIDs.insert(Int(detectedEos))
        specialIDs.insert(Int(parsedUnkId))

        var flatBytes: [UInt8] = []
        flatBytes.reserveCapacity(vocabArray.count * 8)
        var entries: [VocabEntry] = []
        entries.reserveCapacity(vocabArray.count)

        var minScore: Float = 0.0
        var maxBytes = 1

        for (idx, item) in vocabArray.enumerated() {
            guard item.count >= 2,
                  let piece = item[0] as? String,
                  let num = item[1] as? NSNumber else {
                throw SemanticTokenizerError.invalidTokenizerJSON("Malformed vocab item at index \(idx)")
            }
            let score = num.floatValue
            if score < minScore {
                minScore = score
            }
            if specialIDs.contains(idx) || piece.isEmpty {
                continue
            }
            let utf8 = Array(piece.utf8)
            guard utf8.count <= Int(UInt16.max) else { continue }
            let offset = UInt32(flatBytes.count)
            flatBytes.append(contentsOf: utf8)
            if utf8.count > maxBytes {
                maxBytes = utf8.count
            }
            entries.append(VocabEntry(
                offset: offset,
                length: UInt16(utf8.count),
                tokenId: Int32(idx),
                score: score
            ))
        }

        let computedUnkScore = minScore - 10.0
        self.vocabSize = vocabArray.count
        self.bosId = detectedBos
        self.padId = detectedPad
        self.eosId = detectedEos
        self.unkId = parsedUnkId
        self.defaultMaxLength = maxLen
        self.precompiledTrie = trieUnits
        self.precompiledPool = triePool
        self.vocabBytes = flatBytes
        self.maxPieceBytes = maxBytes
        self.unkScore = computedUnkScore

        let built = Self.buildHashTable(entries: entries, vocabBytes: flatBytes)
        self.hashTable = built.slots
        self.hashMask = built.mask

        if let binaryCacheURL, jsonSourceSize > 0 {
            try? Self.writeBinaryCache(
                to: binaryCacheURL,
                sourceSize: jsonSourceSize,
                vocabSize: vocabArray.count,
                bosId: detectedBos,
                padId: detectedPad,
                eosId: detectedEos,
                unkId: parsedUnkId,
                defaultMaxLength: maxLen,
                maxPieceBytes: maxBytes,
                unkScore: computedUnkScore,
                precompiledTrie: trieUnits,
                precompiledPool: triePool,
                vocabBytes: flatBytes,
                entries: entries
            )
        }
    }

    // MARK: - Public Encoding

    public func encode(_ text: String, maxLength: Int? = nil) -> TokenizedEncoding {
        let cap = max(4, maxLength ?? defaultMaxLength)
        let normalized = normalize(text)

        var ids: [Int32] = []
        ids.reserveCapacity(min(cap, 128))
        ids.append(bosId)

        let pieceBudget = cap - 1 // reserve final slot for eosId
        var wordBuffer: [UInt8] = []
        wordBuffer.reserveCapacity(64)

        var currentWordScalars: [UnicodeScalar] = []
        currentWordScalars.reserveCapacity(24)

        func flushWord() -> Bool {
            guard !currentWordScalars.isEmpty else { return true }
            wordBuffer.removeAll(keepingCapacity: true)
            wordBuffer.append(contentsOf: Self.metaspaceUTF8)
            for sc in currentWordScalars {
                UTF8.encode(sc) { wordBuffer.append($0) }
            }
            currentWordScalars.removeAll(keepingCapacity: true)
            encodeWordViterbi(wordBuffer, into: &ids, limit: pieceBudget)
            return ids.count < pieceBudget
        }

        for scalar in normalized.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !flushWord() { break }
            } else {
                currentWordScalars.append(scalar)
            }
        }
        if ids.count < pieceBudget {
            _ = flushWord()
        }
        if ids.count > pieceBudget {
            ids.removeSubrange(pieceBudget..<ids.count)
        }
        ids.append(eosId)

        let mask = [Int32](repeating: 1, count: ids.count)
        return TokenizedEncoding(ids: ids, attentionMask: mask)
    }

    public func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        guard !precompiledTrie.isEmpty else {
            return text.precomposedStringWithCompatibilityMapping
        }
        let src = Array(text.utf8)
        let n = src.count
        var out: [UInt8] = []
        out.reserveCapacity(n + 16)

        let rootUnit = precompiledTrie[0]
        let rootPos = Int((rootUnit >> 10) << ((rootUnit & (1 << 9)) >> 6))
        let trieCount = precompiledTrie.count
        let poolCount = precompiledPool.count

        var i = 0
        while i < n {
            var nodePos = rootPos
            var bestLen = 0
            var bestPoolOffset = -1
            let maxProbe = min(n, i + 32)
            var j = i
            while j < maxProbe {
                let c = Int(src[j])
                nodePos ^= c
                if nodePos < 0 || nodePos >= trieCount {
                    break
                }
                let unit = precompiledTrie[nodePos]
                if Int(unit & 0xFF) != c {
                    break
                }
                nodePos ^= Int((unit >> 10) << ((unit & (1 << 9)) >> 6))
                if (unit & (1 << 8)) != 0, nodePos >= 0, nodePos < trieCount {
                    bestPoolOffset = Int(precompiledTrie[nodePos] & 0x7FFF_FFFF)
                    bestLen = j + 1 - i
                }
                j += 1
            }

            if bestLen > 0, bestPoolOffset >= 0, bestPoolOffset < poolCount {
                var p = bestPoolOffset
                while p < poolCount && precompiledPool[p] != 0 {
                    out.append(precompiledPool[p])
                    p += 1
                }
                i += bestLen
            } else {
                let fb = src[i]
                let step: Int
                if fb < 0x80 { step = 1 }
                else if fb < 0xE0 { step = 2 }
                else if fb < 0xF0 { step = 3 }
                else { step = 4 }
                let end = min(n, i + step)
                out.append(contentsOf: src[i..<end])
                i = end
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Unigram Viterbi

    private func encodeWordViterbi(_ wordUTF8: [UInt8], into output: inout [Int32], limit: Int) {
        let n = wordUTF8.count
        guard n > 0 else { return }

        var isBoundary = [Bool](repeating: false, count: n + 1)
        var charStarts: [Int] = []
        charStarts.reserveCapacity(n)

        var pos = 0
        while pos < n {
            isBoundary[pos] = true
            charStarts.append(pos)
            let fb = wordUTF8[pos]
            if fb < 0x80 { pos += 1 }
            else if fb < 0xE0 { pos += min(2, n - pos) }
            else if fb < 0xF0 { pos += min(3, n - pos) }
            else { pos += min(4, n - pos) }
        }
        isBoundary[n] = true

        let negInf: Float = -1.0e30
        var bestScore = [Float](repeating: negInf, count: n + 1)
        var bestPrev = [Int](repeating: -1, count: n + 1)
        var bestToken = [Int32](repeating: unkId, count: n + 1)
        bestScore[0] = 0.0

        for start in charStarts {
            let baseScore = bestScore[start]
            if baseScore <= -1.0e29 { continue }

            let fb = wordUTF8[start]
            let firstCharLen: Int
            if fb < 0x80 { firstCharLen = min(1, n - start) }
            else if fb < 0xE0 { firstCharLen = min(2, n - start) }
            else if fb < 0xF0 { firstCharLen = min(3, n - start) }
            else { firstCharLen = min(4, n - start) }

            var hasSingleCodepointMatch = false
            let endLimit = min(n, start + maxPieceBytes)
            var rollingHash = Self.fnvOffsetBasis

            for idx in start..<endLimit {
                rollingHash ^= UInt64(wordUTF8[idx])
                rollingHash &*= Self.fnvPrime
                let end = idx + 1
                if !isBoundary[end] { continue }

                let sliceLen = end - start
                if let match = lookupPiece(wordUTF8, start: start, length: sliceLen, hash: rollingHash) {
                    if sliceLen == firstCharLen {
                        hasSingleCodepointMatch = true
                    }
                    let candidate = baseScore + match.score
                    if candidate > bestScore[end] {
                        bestScore[end] = candidate
                        bestPrev[end] = start
                        bestToken[end] = match.tokenId
                    }
                }
            }

            if !hasSingleCodepointMatch {
                let end = start + firstCharLen
                let candidate = baseScore + unkScore
                if candidate > bestScore[end] {
                    bestScore[end] = candidate
                    bestPrev[end] = start
                    bestToken[end] = unkId
                }
            }
        }

        // Backtrack and fuse consecutive unkId tokens (matching SentencePiece / HuggingFace Unigram)
        var reversedIds: [Int32] = []
        reversedIds.reserveCapacity(charStarts.count)
        var cur = n
        while cur > 0 {
            let tid = bestToken[cur]
            let prev = bestPrev[cur]
            if tid == unkId, reversedIds.last == unkId {
                // Fuse adjacent <unk> codepoints into single <unk>
            } else {
                reversedIds.append(tid)
            }
            if prev < 0 { break }
            cur = prev
        }

        for tid in reversedIds.reversed() {
            if output.count >= limit { break }
            output.append(tid)
        }
    }

    @inline(__always)
    private func lookupPiece(_ input: [UInt8], start: Int, length: Int, hash: UInt64) -> (tokenId: Int32, score: Float)? {
        let len16 = UInt16(length)
        let tag16 = UInt16(truncatingIfNeeded: hash >> 32)
        var slotIdx = Int(truncatingIfNeeded: hash) & hashMask
        while true {
            let slot = hashTable[slotIdx]
            if slot.length == 0 {
                return nil
            }
            if slot.length == len16 && slot.hashTag == tag16 {
                let vStart = Int(slot.offset)
                var matches = true
                for k in 0..<length {
                    if vocabBytes[vStart + k] != input[start + k] {
                        matches = false
                        break
                    }
                }
                if matches {
                    return (slot.tokenId, slot.score)
                }
            }
            slotIdx = (slotIdx + 1) & hashMask
        }
    }

    // MARK: - Hash Table & Binary Cache

    private struct VocabEntry {
        let offset: UInt32
        let length: UInt16
        let tokenId: Int32
        let score: Float
    }

    private struct CachedPayload {
        let vocabSize: Int
        let bosId: Int32
        let padId: Int32
        let eosId: Int32
        let unkId: Int32
        let defaultMaxLength: Int
        let maxPieceBytes: Int
        let unkScore: Float
        let precompiledTrie: [UInt32]
        let precompiledPool: [UInt8]
        let vocabBytes: [UInt8]
        let entries: [VocabEntry]
    }

    private static func buildHashTable(entries: [VocabEntry], vocabBytes: [UInt8]) -> (slots: [HashSlot], mask: Int) {
        var capacity = 1024
        let target = max(1024, entries.count * 2)
        while capacity < target {
            capacity <<= 1
        }
        let mask = capacity - 1
        var slots = [HashSlot](
            repeating: HashSlot(offset: 0, length: 0, hashTag: 0, tokenId: 0, score: 0),
            count: capacity
        )

        for entry in entries {
            var h = fnvOffsetBasis
            let start = Int(entry.offset)
            let len = Int(entry.length)
            for k in 0..<len {
                h ^= UInt64(vocabBytes[start + k])
                h &*= fnvPrime
            }
            let tag = UInt16(truncatingIfNeeded: h >> 32)
            var idx = Int(truncatingIfNeeded: h) & mask
            while slots[idx].length != 0 {
                idx = (idx + 1) & mask
            }
            slots[idx] = HashSlot(
                offset: entry.offset,
                length: entry.length,
                hashTag: tag,
                tokenId: entry.tokenId,
                score: entry.score
            )
        }
        return (slots, mask)
    }

    private static func writeBinaryCache(
        to url: URL,
        sourceSize: UInt64,
        vocabSize: Int,
        bosId: Int32,
        padId: Int32,
        eosId: Int32,
        unkId: Int32,
        defaultMaxLength: Int,
        maxPieceBytes: Int,
        unkScore: Float,
        precompiledTrie: [UInt32],
        precompiledPool: [UInt8],
        vocabBytes: [UInt8],
        entries: [VocabEntry]
    ) throws {
        var data = Data()
        data.reserveCapacity(64 + precompiledTrie.count * 4 + precompiledPool.count + vocabBytes.count + entries.count * 14)
        data.append(contentsOf: cacheMagic)

        func appendU64(_ v: UInt64) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendI32(_ v: Int32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendF32(_ v: Float) { var le = v.bitPattern.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

        appendU64(sourceSize)
        appendU32(UInt32(vocabSize))
        appendI32(bosId)
        appendI32(padId)
        appendI32(eosId)
        appendI32(unkId)
        appendU32(UInt32(defaultMaxLength))
        appendU32(UInt32(maxPieceBytes))
        appendF32(unkScore)
        appendU32(UInt32(precompiledTrie.count))
        appendU32(UInt32(precompiledPool.count))
        appendU32(UInt32(vocabBytes.count))
        appendU32(UInt32(entries.count))

        for unit in precompiledTrie { appendU32(unit) }
        data.append(contentsOf: precompiledPool)
        data.append(contentsOf: vocabBytes)
        for entry in entries {
            appendU32(entry.offset)
            appendU16(entry.length)
            appendI32(entry.tokenId)
            appendF32(entry.score)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func loadBinaryCache(from url: URL, expectedSourceSize: UInt64) throws -> CachedPayload? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let headerLen = 8 + 8 + 4 * 11
        guard data.count >= headerLen else { return nil }

        return data.withUnsafeBytes { raw -> CachedPayload? in
            for idx in 0..<8 {
                if raw[idx] != cacheMagic[idx] { return nil }
            }
            var cursor = 8
            func readU64() -> UInt64 {
                defer { cursor += 8 }
                return UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self))
            }
            func readU32() -> UInt32 {
                defer { cursor += 4 }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
            }
            func readI32() -> Int32 {
                defer { cursor += 4 }
                return Int32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
            }
            func readU16() -> UInt16 {
                defer { cursor += 2 }
                return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt16.self))
            }
            func readF32() -> Float {
                defer { cursor += 4 }
                let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
                return Float(bitPattern: bits)
            }

            let sourceSize = readU64()
            guard sourceSize == expectedSourceSize else { return nil }
            let vocabSize = Int(readU32())
            let bosId = readI32()
            let padId = readI32()
            let eosId = readI32()
            let unkId = readI32()
            let defaultMaxLength = Int(readU32())
            let maxPieceBytes = Int(readU32())
            let unkScore = readF32()
            let trieCount = Int(readU32())
            let poolCount = Int(readU32())
            let vocabBytesCount = Int(readU32())
            let entriesCount = Int(readU32())

            let expectedTotal = cursor + trieCount * 4 + poolCount + vocabBytesCount + entriesCount * 14
            guard expectedTotal == data.count else { return nil }

            var trie = [UInt32]()
            trie.reserveCapacity(trieCount)
            for _ in 0..<trieCount { trie.append(readU32()) }

            let poolSlice = Data(bytes: raw.baseAddress!.advanced(by: cursor), count: poolCount)
            cursor += poolCount
            let vBytesSlice = Data(bytes: raw.baseAddress!.advanced(by: cursor), count: vocabBytesCount)
            cursor += vocabBytesCount

            var entries = [VocabEntry]()
            entries.reserveCapacity(entriesCount)
            for _ in 0..<entriesCount {
                let offset = readU32()
                let length = readU16()
                let tokenId = readI32()
                let score = readF32()
                if Int(offset) + Int(length) > vocabBytesCount { return nil }
                entries.append(VocabEntry(offset: offset, length: length, tokenId: tokenId, score: score))
            }

            return CachedPayload(
                vocabSize: vocabSize,
                bosId: bosId,
                padId: padId,
                eosId: eosId,
                unkId: unkId,
                defaultMaxLength: defaultMaxLength,
                maxPieceBytes: maxPieceBytes,
                unkScore: unkScore,
                precompiledTrie: trie,
                precompiledPool: Array(poolSlice),
                vocabBytes: Array(vBytesSlice),
                entries: entries
            )
        }
    }
}
