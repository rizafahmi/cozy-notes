import Foundation
import Accelerate
import CoreML

public enum SemanticEmbedderError: LocalizedError, Sendable {
    case missingModelWeights(URL)
    case invalidSafetensors(String)
    case coreMLInferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingModelWeights(let url):
            return "Missing semantic model weights in \(url.path)"
        case .invalidSafetensors(let detail):
            return "Invalid model weights file: \(detail)"
        case .coreMLInferenceFailed(let detail):
            return "CoreML inference failed: \(detail)"
        }
    }
}

/// Pure-Swift 384-dimensional multilingual sentence embedder (`paraphrase-multilingual-MiniLM-L12-v2`).
/// Supports both memory-mapped FP16/FP32 `safetensors` via Apple Accelerate (`vDSP`) and compiled CoreML `.mlmodelc` bundles.
public final class SemanticEmbedder: Sendable {
    public enum BackendKind: String, Sendable {
        case accelerateSafetensors = "Accelerate (Safetensors)"
        case coreML = "CoreML"
    }

    public static let dimension = 384
    public static let defaultMaxChunkCharacters = 480
    public static let defaultMaxChunks = 24

    public let tokenizer: UnigramTokenizer
    public let backendKind: BackendKind
    private let backend: any EmbedderBackend

    public init(directoryURL: URL) throws {
        let tok = try UnigramTokenizer(directoryURL: directoryURL)
        self.tokenizer = tok

        let fm = FileManager.default
        let compiledCoreML = directoryURL.appendingPathComponent("MiniLM-L12-v2.mlmodelc", isDirectory: true)
        let fp16Safetensors = directoryURL.appendingPathComponent("model.fp16.safetensors")
        let fp32Safetensors = directoryURL.appendingPathComponent("model.safetensors")

        if fm.fileExists(atPath: compiledCoreML.path) {
            self.backend = try CoreMLBertBackend(compiledModelURL: compiledCoreML)
            self.backendKind = .coreML
        } else if fm.fileExists(atPath: fp16Safetensors.path) {
            self.backend = try SafetensorsBertBackend(safetensorsURL: fp16Safetensors)
            self.backendKind = .accelerateSafetensors
        } else if fm.fileExists(atPath: fp32Safetensors.path) {
            self.backend = try SafetensorsBertBackend(safetensorsURL: fp32Safetensors)
            self.backendKind = .accelerateSafetensors
        } else {
            throw SemanticEmbedderError.missingModelWeights(directoryURL)
        }
    }

    /// Deterministically chunks `text` along paragraph boundaries, encodes each chunk up to 128 tokens,
    /// L2-normalizes each chunk vector, averages across chunks, and returns a unit-norm 384d vector.
    public func embed(
        _ text: String,
        maxChunkCharacters: Int = SemanticEmbedder.defaultMaxChunkCharacters,
        maxChunks: Int = SemanticEmbedder.defaultMaxChunks
    ) throws -> [Float] {
        let chunks = Self.chunkText(text, maxCharacters: maxChunkCharacters, maxChunks: maxChunks)
        var accumulated = [Float](repeating: 0, count: Self.dimension)
        for chunk in chunks {
            let encoding = tokenizer.encode(chunk)
            let chunkVec = try backend.encodeMeanPooledNormalized(encoding: encoding)
            vDSP_vadd(accumulated, 1, chunkVec, 1, &accumulated, 1, vDSP_Length(Self.dimension))
        }
        Self.l2Normalize(&accumulated)
        return accumulated
    }

    @inline(__always)
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == dimension, b.count == dimension else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(dimension))
        return dot
    }

    public static func l2Normalize(_ vector: inout [Float]) {
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        let norm = sqrtf(sumSq)
        guard norm > 1.0e-12 else { return }
        var inv = 1.0 / norm
        vDSP_vsmul(vector, 1, &inv, &vector, 1, vDSP_Length(vector.count))
    }

    public static func chunkText(
        _ text: String,
        maxCharacters: Int = defaultMaxChunkCharacters,
        maxChunks: Int = defaultMaxChunks
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [""] }
        let limit = max(64, maxCharacters)
        if trimmed.count <= limit {
            return [trimmed]
        }

        var chunks: [String] = []
        chunks.reserveCapacity(min(maxChunks, (trimmed.count / limit) + 2))
        var current = ""

        for rawParagraph in trimmed.components(separatedBy: "\n\n") {
            let p = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }

            if p.count > limit {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                    if chunks.count >= maxChunks { break }
                }
                var cursor = p.startIndex
                while cursor < p.endIndex && chunks.count < maxChunks {
                    let end = p.index(cursor, offsetBy: limit, limitedBy: p.endIndex) ?? p.endIndex
                    chunks.append(String(p[cursor..<end]))
                    cursor = end
                }
                if chunks.count >= maxChunks { break }
            } else if current.isEmpty {
                current = p
            } else if current.count + 2 + p.count <= limit {
                current += "\n\n" + p
            } else {
                chunks.append(current)
                if chunks.count >= maxChunks {
                    current = ""
                    break
                }
                current = p
            }
        }

        if !current.isEmpty && chunks.count < maxChunks {
            chunks.append(current)
        }
        return chunks.isEmpty ? [String(trimmed.prefix(limit))] : chunks
    }

    // MARK: - FP32 -> FP16 Safetensors Compactor

    /// Converts an upstream FP32 `model.safetensors` into a compact FP16 `model.fp16.safetensors` (~224 MB),
    /// dropping unused `pooler.*` and `embeddings.position_ids` tensors to save disk space.
    public static func compactSafetensorsToFP16(sourceURL: URL, destinationURL: URL) throws {
        let mapped = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let parsed = try SafetensorsHeader.parse(from: mapped)

        let keptNames = parsed.tensors.keys.sorted().filter { name in
            !name.hasPrefix("pooler.") && name != "embeddings.position_ids"
        }
        guard !keptNames.isEmpty else {
            throw SemanticEmbedderError.invalidSafetensors("No encoder tensors found in \(sourceURL.lastPathComponent)")
        }

        var newHeader: [String: Any] = [
            "__metadata__": ["format": "pt", "precision": "fp16"]
        ]
        var currentOffset = 0
        var plan: [(name: String, info: SafetensorsTensorInfo, outBytes: Int)] = []
        plan.reserveCapacity(keptNames.count)

        for name in keptNames {
            guard let info = parsed.tensors[name] else { continue }
            guard info.dtype == .f32 || info.dtype == .f16 else {
                throw SemanticEmbedderError.invalidSafetensors("Unsupported dtype for tensor \(name)")
            }
            let count = info.elementCount
            let outBytes = count * 2
            newHeader[name] = [
                "dtype": "F16",
                "shape": info.shape,
                "data_offsets": [currentOffset, currentOffset + outBytes]
            ]
            plan.append((name, info, outBytes))
            currentOffset += outBytes
        }

        var headerData = try JSONSerialization.data(withJSONObject: newHeader, options: [.sortedKeys])
        let pad = (8 - (headerData.count % 8)) % 8
        if pad > 0 {
            headerData.append(contentsOf: [UInt8](repeating: 0x20, count: pad))
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString).safetensors")
        fm.createFile(atPath: tempURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }

            var headerLenLE = UInt64(headerData.count).littleEndian
            try withUnsafeBytes(of: &headerLenLE) { try handle.write(contentsOf: Data($0)) }
            try handle.write(contentsOf: headerData)

            let chunkFloats = 262_144
            var inBuf = [Float](repeating: 0, count: chunkFloats)
            var outBuf = [UInt16](repeating: 0, count: chunkFloats)

            try mapped.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for item in plan {
                    let byteStart = parsed.dataSectionOffset + item.info.startOffset
                    if item.info.dtype == .f16 {
                        let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base.advanced(by: byteStart)), count: item.outBytes, deallocator: .none)
                        try handle.write(contentsOf: slice)
                    } else {
                        let totalElems = item.info.elementCount
                        var processed = 0
                        while processed < totalElems {
                            let batch = min(chunkFloats, totalElems - processed)
                            let srcPtr = base.advanced(by: byteStart + processed * 4)
                            inBuf.withUnsafeMutableBytes { dstRaw in
                                if let dstBase = dstRaw.baseAddress {
                                    memcpy(dstBase, srcPtr, batch * 4)
                                }
                            }
                            inBuf.withUnsafeMutableBufferPointer { inPtr in
                                outBuf.withUnsafeMutableBufferPointer { outPtr in
                                    var srcV = vImage_Buffer(
                                        data: inPtr.baseAddress,
                                        height: 1,
                                        width: vImagePixelCount(batch),
                                        rowBytes: batch * 4
                                    )
                                    var dstV = vImage_Buffer(
                                        data: outPtr.baseAddress,
                                        height: 1,
                                        width: vImagePixelCount(batch),
                                        rowBytes: batch * 2
                                    )
                                    vImageConvert_PlanarFtoPlanar16F(&srcV, &dstV, 0)
                                }
                            }
                            try outBuf.withUnsafeBytes { bufPtr in
                                let chunkData = Data(bytes: bufPtr.baseAddress!, count: batch * 2)
                                try handle.write(contentsOf: chunkData)
                            }
                            processed += batch
                        }
                    }
                }
            }

            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }
}

// MARK: - Internal Backend Protocol

private protocol EmbedderBackend: Sendable {
    func encodeMeanPooledNormalized(encoding: TokenizedEncoding) throws -> [Float]
}

// MARK: - Safetensors + Accelerate BERT Backend

private final class SafetensorsBertBackend: EmbedderBackend, @unchecked Sendable {
    private struct TransformerLayer {
        let qkvWeightT: [Float]          // [384, 1152] = [H, 3*H]
        let qkvBias: [Float]             // [1152]
        let attnOutWeightT: [Float]      // [384, 384]
        let attnOutBias: [Float]         // [384]
        let attnLNWeight: [Float]        // [384]
        let attnLNBias: [Float]          // [384]
        let interWeightT: [Float]        // [384, 1536]
        let interBias: [Float]           // [1536]
        let outputWeightT: [Float]       // [1536, 384]
        let outputBias: [Float]          // [384]
        let outputLNWeight: [Float]      // [384]
        let outputLNBias: [Float]        // [384]
    }

    private static let hidden = 384
    private static let intermediate = 1536
    private static let heads = 12
    private static let headDim = 32
    private static let numLayers = 12
    private static let maxPositions = 512
    private static let layerNormEps: Float = 1.0e-12
    private static let invSqrtHeadDim: Float = 1.0 / sqrtf(32.0)
    private static let invSqrt2: Float = 0.7071067811865475

    // Memory-mapped safetensors keeps the ~192 MB multilingual word-embedding table paged on disk!
    private let mappedData: Data
    private let dataSectionOffset: Int
    private let wordEmbeddingsInfo: SafetensorsTensorInfo
    private let vocabRows: Int

    private let positionEmbeddings: [Float]   // [512 * 384]
    private let tokenTypeZero: [Float]        // [384]
    private let embLNWeight: [Float]          // [384]
    private let embLNBias: [Float]            // [384]
    private let layers: [TransformerLayer]    // 12 layers

    init(safetensorsURL: URL) throws {
        let data = try Data(contentsOf: safetensorsURL, options: .mappedIfSafe)
        let header = try SafetensorsHeader.parse(from: data)

        func requireTensor(_ name: String, expectedShape: [Int]? = nil) throws -> SafetensorsTensorInfo {
            guard let info = header.tensors[name] else {
                throw SemanticEmbedderError.invalidSafetensors("Missing tensor '\(name)'")
            }
            if let expectedShape, info.shape != expectedShape {
                throw SemanticEmbedderError.invalidSafetensors("Tensor '\(name)' shape \(info.shape) != \(expectedShape)")
            }
            return info
        }

        let wordEmb = try requireTensor("embeddings.word_embeddings.weight")
        guard wordEmb.shape.count == 2, wordEmb.shape[1] == Self.hidden, wordEmb.shape[0] > 1000 else {
            throw SemanticEmbedderError.invalidSafetensors("Invalid word_embeddings shape \(wordEmb.shape)")
        }

        let posEmbInfo = try requireTensor("embeddings.position_embeddings.weight", expectedShape: [Self.maxPositions, Self.hidden])
        let tokTypeInfo = try requireTensor("embeddings.token_type_embeddings.weight")
        guard tokTypeInfo.shape.count == 2, tokTypeInfo.shape[1] == Self.hidden, tokTypeInfo.shape[0] >= 1 else {
            throw SemanticEmbedderError.invalidSafetensors("Invalid token_type_embeddings shape \(tokTypeInfo.shape)")
        }
        let embLNWInfo = try requireTensor("embeddings.LayerNorm.weight", expectedShape: [Self.hidden])
        let embLNBInfo = try requireTensor("embeddings.LayerNorm.bias", expectedShape: [Self.hidden])

        let posEmb = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: posEmbInfo)
        let fullTokType = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: tokTypeInfo)
        let tokType0 = Array(fullTokType.prefix(Self.hidden))
        let embLNW = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: embLNWInfo)
        let embLNB = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: embLNBInfo)

        var loadedLayers: [TransformerLayer] = []
        loadedLayers.reserveCapacity(Self.numLayers)

        for idx in 0..<Self.numLayers {
            let p = "encoder.layer.\(idx)"
            let qw = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.self.query.weight", expectedShape: [Self.hidden, Self.hidden]))
            let qb = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.self.query.bias", expectedShape: [Self.hidden]))
            let kw = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.self.key.weight", expectedShape: [Self.hidden, Self.hidden]))
            let kb = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.self.key.bias", expectedShape: [Self.hidden]))
            let vw = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.self.value.weight", expectedShape: [Self.hidden, Self.hidden]))
            let vb = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.self.value.bias", expectedShape: [Self.hidden]))

            // Fuse [Q; K; V] ([3*384, 384]) and transpose once to [384, 1152] for a single vDSP_mmul per layer!
            var fusedQKV = [Float]()
            fusedQKV.reserveCapacity(Self.hidden * Self.hidden * 3)
            fusedQKV.append(contentsOf: qw)
            fusedQKV.append(contentsOf: kw)
            fusedQKV.append(contentsOf: vw)
            let qkvWeightT = Self.transposeMatrix(fusedQKV, rows: Self.hidden * 3, cols: Self.hidden)

            var qkvBias = [Float]()
            qkvBias.reserveCapacity(Self.hidden * 3)
            qkvBias.append(contentsOf: qb)
            qkvBias.append(contentsOf: kb)
            qkvBias.append(contentsOf: vb)

            let ow = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.output.dense.weight", expectedShape: [Self.hidden, Self.hidden]))
            let ob = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.output.dense.bias", expectedShape: [Self.hidden]))
            let alnw = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.output.LayerNorm.weight", expectedShape: [Self.hidden]))
            let alnb = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).attention.output.LayerNorm.bias", expectedShape: [Self.hidden]))

            let iw = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).intermediate.dense.weight", expectedShape: [Self.intermediate, Self.hidden]))
            let ib = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).intermediate.dense.bias", expectedShape: [Self.intermediate]))

            let dw = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).output.dense.weight", expectedShape: [Self.hidden, Self.intermediate]))
            let db = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).output.dense.bias", expectedShape: [Self.hidden]))
            let olnw = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).output.LayerNorm.weight", expectedShape: [Self.hidden]))
            let olnb = Self.readFloatArray(from: data, baseOffset: header.dataSectionOffset, info: try requireTensor("\(p).output.LayerNorm.bias", expectedShape: [Self.hidden]))

            loadedLayers.append(TransformerLayer(
                qkvWeightT: qkvWeightT,
                qkvBias: qkvBias,
                attnOutWeightT: Self.transposeMatrix(ow, rows: Self.hidden, cols: Self.hidden),
                attnOutBias: ob,
                attnLNWeight: alnw,
                attnLNBias: alnb,
                interWeightT: Self.transposeMatrix(iw, rows: Self.intermediate, cols: Self.hidden),
                interBias: ib,
                outputWeightT: Self.transposeMatrix(dw, rows: Self.hidden, cols: Self.intermediate),
                outputBias: db,
                outputLNWeight: olnw,
                outputLNBias: olnb
            ))
        }

        self.mappedData = data
        self.dataSectionOffset = header.dataSectionOffset
        self.wordEmbeddingsInfo = wordEmb
        self.vocabRows = wordEmb.shape[0]
        self.positionEmbeddings = posEmb
        self.tokenTypeZero = tokType0
        self.embLNWeight = embLNW
        self.embLNBias = embLNB
        self.layers = loadedLayers
    }

    func encodeMeanPooledNormalized(encoding: TokenizedEncoding) throws -> [Float] {
        let seqLen = min(encoding.ids.count, Self.maxPositions)
        guard seqLen > 0 else {
            return [Float](repeating: 0, count: Self.hidden)
        }
        let H = Self.hidden
        let I = Self.intermediate
        let D = Self.headDim

        // 1. Embedding lookup + position + token_type_0 + LayerNorm
        var x = [Float](repeating: 0, count: seqLen * H)
        mappedData.withUnsafeBytes { raw in
            let wordStart = dataSectionOffset + wordEmbeddingsInfo.startOffset
            for t in 0..<seqLen {
                let rawId = Int(encoding.ids[t])
                let tokId = (rawId >= 0 && rawId < vocabRows) ? rawId : 3
                let dstBase = t * H
                let posBase = t * H
                if wordEmbeddingsInfo.dtype == .f16 {
                    let rowByteOffset = wordStart + tokId * H * 2
                    for d in 0..<H {
                        let bits = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: rowByteOffset + d * 2, as: UInt16.self))
                        x[dstBase + d] = HalfFloat.bitsToFloat(bits) + positionEmbeddings[posBase + d] + tokenTypeZero[d]
                    }
                } else {
                    let rowByteOffset = wordStart + tokId * H * 4
                    for d in 0..<H {
                        let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: rowByteOffset + d * 4, as: UInt32.self))
                        x[dstBase + d] = Float(bitPattern: bits) + positionEmbeddings[posBase + d] + tokenTypeZero[d]
                    }
                }
            }
        }
        Self.applyLayerNormInPlace(&x, rows: seqLen, cols: H, weight: embLNWeight, bias: embLNBias)

        // Reusable per-call scratch buffers (seqLen <= 128 -> ~1.1 MB total)
        var qkv = [Float](repeating: 0, count: seqLen * H * 3)
        var qHead = [Float](repeating: 0, count: seqLen * D)
        var kHeadT = [Float](repeating: 0, count: D * seqLen)
        var vHead = [Float](repeating: 0, count: seqLen * D)
        var scores = [Float](repeating: 0, count: seqLen * seqLen)
        var ctxHead = [Float](repeating: 0, count: seqLen * D)
        var attnConcat = [Float](repeating: 0, count: seqLen * H)
        var attnOut = [Float](repeating: 0, count: seqLen * H)
        var inter = [Float](repeating: 0, count: seqLen * I)
        var ffnOut = [Float](repeating: 0, count: seqLen * H)

        let validLen: Int = {
            var count = 0
            for t in 0..<min(seqLen, encoding.attentionMask.count) where encoding.attentionMask[t] != 0 {
                count = t + 1
            }
            return max(1, count)
        }()

        // 2. 12 Transformer Layers
        for layer in layers {
            // QKV = X [seqLen, 384] * qkvWeightT [384, 1152] + qkvBias
            vDSP_mmul(
                x, 1,
                layer.qkvWeightT, 1,
                &qkv, 1,
                vDSP_Length(seqLen),
                vDSP_Length(H * 3),
                vDSP_Length(H)
            )
            Self.addBiasInPlace(&qkv, rows: seqLen, cols: H * 3, bias: layer.qkvBias)

            // Multi-head self-attention across 12 heads (dim 32 each)
            let strideQKV = H * 3
            for h in 0..<Self.heads {
                let headColOffset = h * D
                for t in 0..<seqLen {
                    let rowBase = t * strideQKV
                    let qSrc = rowBase + headColOffset
                    let kSrc = rowBase + H + headColOffset
                    let vSrc = rowBase + 2 * H + headColOffset
                    let tD = t * D
                    for d in 0..<D {
                        qHead[tD + d] = qkv[qSrc + d]
                        kHeadT[d * seqLen + t] = qkv[kSrc + d]
                        vHead[tD + d] = qkv[vSrc + d]
                    }
                }

                // scores [seqLen, seqLen] = qHead [seqLen, 32] * kHeadT [32, seqLen]
                vDSP_mmul(
                    qHead, 1,
                    kHeadT, 1,
                    &scores, 1,
                    vDSP_Length(seqLen),
                    vDSP_Length(seqLen),
                    vDSP_Length(D)
                )

                var scale = Self.invSqrtHeadDim
                vDSP_vsmul(scores, 1, &scale, &scores, 1, vDSP_Length(seqLen * seqLen))

                // Masked row-wise softmax
                for r in 0..<seqLen {
                    let rBase = r * seqLen
                    var maxVal: Float = -Float.greatestFiniteMagnitude
                    for c in 0..<validLen {
                        let v = scores[rBase + c]
                        if v > maxVal { maxVal = v }
                    }
                    var sumExp: Float = 0
                    for c in 0..<validLen {
                        let e = expf(scores[rBase + c] - maxVal)
                        scores[rBase + c] = e
                        sumExp += e
                    }
                    for c in validLen..<seqLen {
                        scores[rBase + c] = 0
                    }
                    let invSum = sumExp > 0 ? (1.0 / sumExp) : 0
                    for c in 0..<validLen {
                        scores[rBase + c] *= invSum
                    }
                }

                // ctxHead [seqLen, 32] = scores [seqLen, seqLen] * vHead [seqLen, 32]
                vDSP_mmul(
                    scores, 1,
                    vHead, 1,
                    &ctxHead, 1,
                    vDSP_Length(seqLen),
                    vDSP_Length(D),
                    vDSP_Length(seqLen)
                )

                for t in 0..<seqLen {
                    let dst = t * H + headColOffset
                    let src = t * D
                    for d in 0..<D {
                        attnConcat[dst + d] = ctxHead[src + d]
                    }
                }
            }

            // Attention output projection + residual + LayerNorm
            vDSP_mmul(
                attnConcat, 1,
                layer.attnOutWeightT, 1,
                &attnOut, 1,
                vDSP_Length(seqLen),
                vDSP_Length(H),
                vDSP_Length(H)
            )
            Self.addBiasAndResidualInPlace(&x, proj: attnOut, rows: seqLen, cols: H, bias: layer.attnOutBias)
            Self.applyLayerNormInPlace(&x, rows: seqLen, cols: H, weight: layer.attnLNWeight, bias: layer.attnLNBias)

            // Intermediate FFN + exact GELU
            vDSP_mmul(
                x, 1,
                layer.interWeightT, 1,
                &inter, 1,
                vDSP_Length(seqLen),
                vDSP_Length(I),
                vDSP_Length(H)
            )
            let totalInter = seqLen * I
            for r in 0..<seqLen {
                let rBase = r * I
                for c in 0..<I {
                    let v = inter[rBase + c] + layer.interBias[c]
                    inter[rBase + c] = 0.5 * v * (1.0 + erff(v * Self.invSqrt2))
                }
            }
            _ = totalInter

            // Output FFN + residual + LayerNorm
            vDSP_mmul(
                inter, 1,
                layer.outputWeightT, 1,
                &ffnOut, 1,
                vDSP_Length(seqLen),
                vDSP_Length(H),
                vDSP_Length(I)
            )
            Self.addBiasAndResidualInPlace(&x, proj: ffnOut, rows: seqLen, cols: H, bias: layer.outputBias)
            Self.applyLayerNormInPlace(&x, rows: seqLen, cols: H, weight: layer.outputLNWeight, bias: layer.outputLNBias)
        }

        // 3. Masked Mean Pooling + L2 Normalization
        var pooled = [Float](repeating: 0, count: H)
        var activeCount: Float = 0
        for t in 0..<seqLen {
            let maskVal = t < encoding.attentionMask.count ? encoding.attentionMask[t] : 1
            guard maskVal != 0 else { continue }
            activeCount += 1
            let rowBase = t * H
            for d in 0..<H {
                pooled[d] += x[rowBase + d]
            }
        }
        if activeCount > 0 {
            var invCount = 1.0 / activeCount
            vDSP_vsmul(pooled, 1, &invCount, &pooled, 1, vDSP_Length(H))
        }
        SemanticEmbedder.l2Normalize(&pooled)
        return pooled
    }

    // MARK: - Math Helpers

    private static func transposeMatrix(_ src: [Float], rows: Int, cols: Int) -> [Float] {
        var dst = [Float](repeating: 0, count: rows * cols)
        vDSP_mtrans(src, 1, &dst, 1, vDSP_Length(cols), vDSP_Length(rows))
        return dst
    }

    private static func addBiasInPlace(_ mat: inout [Float], rows: Int, cols: Int, bias: [Float]) {
        mat.withUnsafeMutableBufferPointer { matBuf in
            bias.withUnsafeBufferPointer { biasBuf in
                guard let mPtr = matBuf.baseAddress, let bPtr = biasBuf.baseAddress else { return }
                for r in 0..<rows {
                    let rowPtr = mPtr.advanced(by: r * cols)
                    vDSP_vadd(rowPtr, 1, bPtr, 1, rowPtr, 1, vDSP_Length(cols))
                }
            }
        }
    }

    private static func addBiasAndResidualInPlace(_ residual: inout [Float], proj: [Float], rows: Int, cols: Int, bias: [Float]) {
        residual.withUnsafeMutableBufferPointer { resBuf in
            proj.withUnsafeBufferPointer { projBuf in
                bias.withUnsafeBufferPointer { biasBuf in
                    guard let rBase = resBuf.baseAddress, let pBase = projBuf.baseAddress, let bPtr = biasBuf.baseAddress else { return }
                    for r in 0..<rows {
                        let offset = r * cols
                        let rPtr = rBase.advanced(by: offset)
                        let pPtr = pBase.advanced(by: offset)
                        vDSP_vadd(rPtr, 1, pPtr, 1, rPtr, 1, vDSP_Length(cols))
                        vDSP_vadd(rPtr, 1, bPtr, 1, rPtr, 1, vDSP_Length(cols))
                    }
                }
            }
        }
    }

    private static func applyLayerNormInPlace(_ mat: inout [Float], rows: Int, cols: Int, weight: [Float], bias: [Float]) {
        let invCols = 1.0 / Float(cols)
        let n = vDSP_Length(cols)
        mat.withUnsafeMutableBufferPointer { matBuf in
            weight.withUnsafeBufferPointer { wBuf in
                bias.withUnsafeBufferPointer { bBuf in
                    guard let mBase = matBuf.baseAddress,
                          let wPtr = wBuf.baseAddress,
                          let bPtr = bBuf.baseAddress else { return }
                    for r in 0..<rows {
                        let rowPtr = mBase.advanced(by: r * cols)
                        var mean: Float = 0
                        vDSP_meanv(rowPtr, 1, &mean, n)
                        var negMean = -mean
                        vDSP_vsadd(rowPtr, 1, &negMean, rowPtr, 1, n)
                        var sumSq: Float = 0
                        vDSP_svesq(rowPtr, 1, &sumSq, n)
                        var invStd = 1.0 / sqrtf(sumSq * invCols + layerNormEps)
                        vDSP_vsmul(rowPtr, 1, &invStd, rowPtr, 1, n)
                        vDSP_vma(rowPtr, 1, wPtr, 1, bPtr, 1, rowPtr, 1, n)
                    }
                }
            }
        }
    }

    private static func readFloatArray(from data: Data, baseOffset: Int, info: SafetensorsTensorInfo) -> [Float] {
        let count = info.elementCount
        guard count > 0 else { return [] }
        let start = baseOffset + info.startOffset
        return [Float](unsafeUninitializedCapacity: count) { dst, initialized in
            data.withUnsafeBytes { raw in
                guard let rawBase = raw.baseAddress, let dstBase = dst.baseAddress else { return }
                let srcPtr = rawBase.advanced(by: start)
                if info.dtype == .f16 {
                    var alignedHalf = [UInt16](repeating: 0, count: count)
                    alignedHalf.withUnsafeMutableBufferPointer { halfBuf in
                        guard let hPtr = halfBuf.baseAddress else { return }
                        memcpy(hPtr, srcPtr, count * 2)
                        var srcV = vImage_Buffer(
                            data: hPtr,
                            height: 1,
                            width: vImagePixelCount(count),
                            rowBytes: count * 2
                        )
                        var dstV = vImage_Buffer(
                            data: dstBase,
                            height: 1,
                            width: vImagePixelCount(count),
                            rowBytes: count * 4
                        )
                        vImageConvert_Planar16FtoPlanarF(&srcV, &dstV, 0)
                    }
                } else {
                    memcpy(dstBase, srcPtr, count * 4)
                }
            }
            initialized = count
        }
    }
}

// MARK: - Optional CoreML Backend

private final class CoreMLBertBackend: EmbedderBackend, @unchecked Sendable {
    private let model: MLModel
    private let lock = NSLock()

    init(compiledModelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: compiledModelURL, configuration: config)
    }

    func encodeMeanPooledNormalized(encoding: TokenizedEncoding) throws -> [Float] {
        let seqLen = min(encoding.ids.count, 128)
        let idsArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let typeArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)

        for idx in 0..<seqLen {
            idsArray[idx] = NSNumber(value: encoding.ids[idx])
            maskArray[idx] = NSNumber(value: encoding.attentionMask[idx])
            typeArray[idx] = 0
        }

        var features: [String: Any] = [
            "input_ids": idsArray,
            "attention_mask": maskArray
        ]
        if model.modelDescription.inputDescriptionsByName["token_type_ids"] != nil {
            features["token_type_ids"] = typeArray
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: features)

        lock.lock()
        let prediction = try model.prediction(from: provider)
        lock.unlock()

        if let pooled = prediction.featureValue(for: "embedding")?.multiArrayValue,
           pooled.count == SemanticEmbedder.dimension {
            var vec = (0..<SemanticEmbedder.dimension).map { pooled[$0].floatValue }
            SemanticEmbedder.l2Normalize(&vec)
            return vec
        }

        guard let hidden = prediction.featureValue(for: "last_hidden_state")?.multiArrayValue,
              hidden.count >= seqLen * SemanticEmbedder.dimension else {
            throw SemanticEmbedderError.coreMLInferenceFailed("Expected 'embedding' or 'last_hidden_state' output")
        }

        var vec = [Float](repeating: 0, count: SemanticEmbedder.dimension)
        var count: Float = 0
        for t in 0..<seqLen where encoding.attentionMask[t] != 0 {
            count += 1
            let base = t * SemanticEmbedder.dimension
            for d in 0..<SemanticEmbedder.dimension {
                vec[d] += hidden[base + d].floatValue
            }
        }
        if count > 0 {
            for d in 0..<SemanticEmbedder.dimension { vec[d] /= count }
        }
        SemanticEmbedder.l2Normalize(&vec)
        return vec
    }
}

// MARK: - Safetensors Header Parser & IEEE-754 Half Conversion

private enum SafetensorsDType {
    case f16
    case f32
    case other

    var byteSize: Int {
        switch self {
        case .f16: return 2
        case .f32: return 4
        case .other: return 0
        }
    }
}

private struct SafetensorsTensorInfo {
    let dtype: SafetensorsDType
    let shape: [Int]
    let startOffset: Int
    let endOffset: Int

    var elementCount: Int {
        shape.reduce(1, *)
    }
}

private struct SafetensorsHeader {
    let dataSectionOffset: Int
    let tensors: [String: SafetensorsTensorInfo]

    static func parse(from data: Data) throws -> SafetensorsHeader {
        guard data.count >= 16 else {
            throw SemanticEmbedderError.invalidSafetensors("File truncated (< 16 bytes)")
        }
        let headerByteLen: UInt64 = data.withUnsafeBytes { raw in
            UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
        }
        guard headerByteLen > 0, headerByteLen <= 16_777_216, 8 + Int(headerByteLen) <= data.count else {
            throw SemanticEmbedderError.invalidSafetensors("Invalid safetensors header length \(headerByteLen)")
        }
        let dataOffset = 8 + Int(headerByteLen)
        let headerSlice = data.subdata(in: 8..<dataOffset)
        guard let json = try JSONSerialization.jsonObject(with: headerSlice) as? [String: Any] else {
            throw SemanticEmbedderError.invalidSafetensors("Safetensors header is not a JSON dictionary")
        }

        var map: [String: SafetensorsTensorInfo] = [:]
        map.reserveCapacity(json.count)

        for (key, value) in json {
            if key == "__metadata__" { continue }
            guard let dict = value as? [String: Any],
                  let dtypeStr = dict["dtype"] as? String,
                  let shapeNums = dict["shape"] as? [Int],
                  let offsets = dict["data_offsets"] as? [Int],
                  offsets.count == 2 else {
                continue
            }
            let dtype: SafetensorsDType
            switch dtypeStr {
            case "F16": dtype = .f16
            case "F32": dtype = .f32
            default: dtype = .other
            }
            let start = offsets[0]
            let end = offsets[1]
            guard start >= 0, end >= start, dataOffset + end <= data.count else {
                throw SemanticEmbedderError.invalidSafetensors("Out-of-bounds data_offsets for tensor \(key)")
            }
            if dtype != .other {
                let elemCount = shapeNums.reduce(1, *)
                guard elemCount * dtype.byteSize == (end - start) else {
                    throw SemanticEmbedderError.invalidSafetensors("Byte length mismatch for tensor \(key)")
                }
            }
            map[key] = SafetensorsTensorInfo(dtype: dtype, shape: shapeNums, startOffset: start, endOffset: end)
        }
        return SafetensorsHeader(dataSectionOffset: dataOffset, tensors: map)
    }
}

private enum HalfFloat {
    @inline(__always)
    static func bitsToFloat(_ h: UInt16) -> Float {
        #if arch(arm64)
        return Float(Float16(bitPattern: h))
        #else
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32((h >> 10) & 0x1F)
        let mant = UInt32(h & 0x03FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            let val = Float(mant) * (1.0 / 16777216.0)
            return (sign != 0) ? -val : val
        } else if exp == 31 {
            let bits = sign | 0x7F80_0000 | (mant << 13)
            return Float(bitPattern: bits)
        } else {
            let bits = sign | ((exp + 112) << 23) | (mant << 13)
            return Float(bitPattern: bits)
        }
        #endif
    }

    @inline(__always)
    static func floatToBits(_ f: Float) -> UInt16 {
        #if arch(arm64)
        return Float16(f).bitPattern
        #else
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp = Int((bits >> 23) & 0xFF) - 127 + 15
        let mant = bits & 0x007F_FFFF
        if exp <= 0 {
            return sign
        } else if exp >= 31 {
            return sign | 0x7C00
        } else {
            return sign | (UInt16(exp) << 10) | UInt16(mant >> 13)
        }
        #endif
    }
}
