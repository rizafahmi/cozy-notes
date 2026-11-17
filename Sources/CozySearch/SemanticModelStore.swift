import Foundation
import CryptoKit
import CoreML

public enum SemanticModelError: LocalizedError, Sendable {
    case cancelled
    case downloadFailed(String)
    case checksumMismatch(file: String, expected: String, actual: String)
    case invalidSourceDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Model download was cancelled."
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .checksumMismatch(let file, let expected, let actual):
            return "Checksum mismatch for \(file) (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .invalidSourceDirectory(let reason):
            return reason
        }
    }
}

public struct SemanticDownloadProgress: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case downloadingTokenizer = "Downloading tokenizer…"
        case downloadingWeights = "Downloading model weights…"
        case verifyingAndOptimizing = "Verifying & compacting FP16 weights…"
    }

    public let phase: Phase
    public let downloadedBytes: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public init(phase: Phase, downloadedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}

public enum SemanticModelState: Equatable, Sendable {
    case notInstalled
    case downloading(SemanticDownloadProgress)
    case ready(installedBytes: Int64)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct SemanticRemoteSpec: Sendable {
    public let tokenizerURL: URL
    public let tokenizerSHA256: String?
    public let tokenizerExpectedBytes: Int64
    public let safetensorsURL: URL
    public let safetensorsSHA256: String?
    public let safetensorsExpectedBytes: Int64

    /// Official Apache-2.0 `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` files on HuggingFace Hub.
    public static let officialMiniLM = SemanticRemoteSpec(
        tokenizerURL: URL(string: "https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/resolve/main/tokenizer.json")!,
        tokenizerSHA256: "2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8",
        tokenizerExpectedBytes: 9_081_518,
        safetensorsURL: URL(string: "https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/resolve/main/model.safetensors")!,
        safetensorsSHA256: "eaa086f0ffee582aeb45b36e34cdd1fe2d6de2bef61f8a559a1bbc9bd955917b",
        safetensorsExpectedBytes: 470_641_600
    )

    public init(
        tokenizerURL: URL,
        tokenizerSHA256: String?,
        tokenizerExpectedBytes: Int64,
        safetensorsURL: URL,
        safetensorsSHA256: String?,
        safetensorsExpectedBytes: Int64
    ) {
        self.tokenizerURL = tokenizerURL
        self.tokenizerSHA256 = tokenizerSHA256
        self.tokenizerExpectedBytes = tokenizerExpectedBytes
        self.safetensorsURL = safetensorsURL
        self.safetensorsSHA256 = safetensorsSHA256
        self.safetensorsExpectedBytes = safetensorsExpectedBytes
    }
}

/// Opt-in local storage and lifecycle manager for `paraphrase-multilingual-MiniLM-L12-v2`.
/// Makes zero network requests unless `downloadModel` is explicitly invoked.
public final class SemanticModelStore: @unchecked Sendable {
    public static let modelFolderName = "paraphrase-multilingual-MiniLM-L12-v2"

    public static var defaultModelDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("CozyNotes/Models", isDirectory: true)
            .appendingPathComponent(modelFolderName, isDirectory: true)
    }

    public let modelDirectory: URL
    private let lock = NSLock()
    private var activeCancellation: (() -> Void)?
    private var isDownloadingFlag = false

    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = (modelDirectory ?? Self.defaultModelDirectory).standardizedFileURL
    }

    public var isInstalled: Bool {
        if case .ready = currentState() { return true }
        return false
    }

    public func currentState() -> SemanticModelState {
        lock.lock()
        let downloading = isDownloadingFlag
        lock.unlock()
        if downloading {
            return .downloading(SemanticDownloadProgress(phase: .downloadingWeights, downloadedBytes: 0, totalBytes: 1))
        }
        let fm = FileManager.default
        let tokURL = modelDirectory.appendingPathComponent("tokenizer.json")
        guard fm.fileExists(atPath: tokURL.path) else {
            return .notInstalled
        }
        let candidates = [
            modelDirectory.appendingPathComponent("MiniLM-L12-v2.mlmodelc"),
            modelDirectory.appendingPathComponent("model.fp16.safetensors"),
            modelDirectory.appendingPathComponent("model.safetensors")
        ]
        guard candidates.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            return .notInstalled
        }
        return .ready(installedBytes: Self.directoryByteSize(modelDirectory))
    }

    public func loadEmbedder() throws -> SemanticEmbedder {
        try SemanticEmbedder(directoryURL: modelDirectory)
    }

    public func cancelDownload() {
        lock.lock()
        let cancel = activeCancellation
        activeCancellation = nil
        isDownloadingFlag = false
        lock.unlock()
        cancel?()
    }

    public func removeInstalledModel() throws {
        cancelDownload()
        let fm = FileManager.default
        if fm.fileExists(atPath: modelDirectory.path) {
            try fm.removeItem(at: modelDirectory)
        }
    }

    /// Imports a local folder containing `tokenizer.json` and one of `model.fp16.safetensors`, `model.safetensors`, or `MiniLM-L12-v2.mlmodelc`/`.mlpackage`.
    @discardableResult
    public func importLocalModel(from sourceDirectory: URL) throws -> Int64 {
        let fm = FileManager.default
        let src = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let srcTok = src.appendingPathComponent("tokenizer.json")
        guard fm.fileExists(atPath: srcTok.path) else {
            throw SemanticModelError.invalidSourceDirectory("Selected folder does not contain tokenizer.json.")
        }

        let srcCompiledML = src.appendingPathComponent("MiniLM-L12-v2.mlmodelc")
        let srcPackageML = src.appendingPathComponent("MiniLM-L12-v2.mlpackage")
        let srcFP16 = src.appendingPathComponent("model.fp16.safetensors")
        let srcFP32 = src.appendingPathComponent("model.safetensors")

        guard fm.fileExists(atPath: srcCompiledML.path)
            || fm.fileExists(atPath: srcPackageML.path)
            || fm.fileExists(atPath: srcFP16.path)
            || fm.fileExists(atPath: srcFP32.path) else {
            throw SemanticModelError.invalidSourceDirectory(
                "Selected folder must contain model.fp16.safetensors, model.safetensors, or MiniLM-L12-v2.mlpackage."
            )
        }

        let parent = modelDirectory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let dstTok = staging.appendingPathComponent("tokenizer.json")
            try fm.copyItem(at: srcTok, to: dstTok)

            if fm.fileExists(atPath: srcCompiledML.path) {
                try fm.copyItem(at: srcCompiledML, to: staging.appendingPathComponent("MiniLM-L12-v2.mlmodelc"))
            } else if fm.fileExists(atPath: srcPackageML.path) {
                let compiledTemp = try MLModel.compileModel(at: srcPackageML)
                defer { try? fm.removeItem(at: compiledTemp) }
                try fm.copyItem(at: compiledTemp, to: staging.appendingPathComponent("MiniLM-L12-v2.mlmodelc"))
            } else if fm.fileExists(atPath: srcFP16.path) {
                try fm.copyItem(at: srcFP16, to: staging.appendingPathComponent("model.fp16.safetensors"))
            } else if fm.fileExists(atPath: srcFP32.path) {
                try SemanticEmbedder.compactSafetensorsToFP16(
                    sourceURL: srcFP32,
                    destinationURL: staging.appendingPathComponent("model.fp16.safetensors")
                )
            }

            // Validate loadability and prebuild fast binary tokenizer cache (`tokenizer.cozytok`)
            _ = try SemanticEmbedder(directoryURL: staging)

            if fm.fileExists(atPath: modelDirectory.path) {
                _ = try fm.replaceItemAt(modelDirectory, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: modelDirectory)
            }
            return Self.directoryByteSize(modelDirectory)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Explicitly downloads `paraphrase-multilingual-MiniLM-L12-v2`, verifies SHA-256 checksums,
    /// compacts FP32 weights to FP16 (~224 MB), and atomically installs into `modelDirectory`.
    @discardableResult
    public func downloadModel(
        spec: SemanticRemoteSpec = .officialMiniLM,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        onProgress: (@Sendable (SemanticDownloadProgress) -> Void)? = nil
    ) async throws -> Int64 {
        let fm = FileManager.default
        let parent = modelDirectory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        lock.withLock {
            isDownloadingFlag = true
        }

        defer {
            lock.withLock {
                isDownloadingFlag = false
                activeCancellation = nil
            }
            try? fm.removeItem(at: staging)
        }

        let combinedTotal = max(1, spec.tokenizerExpectedBytes + spec.safetensorsExpectedBytes)
        onProgress?(SemanticDownloadProgress(phase: .downloadingTokenizer, downloadedBytes: 0, totalBytes: combinedTotal))

        // 1. Download tokenizer.json
        let downloadedTok = staging.appendingPathComponent("tokenizer.json")
        try await downloadSingleFile(
            from: spec.tokenizerURL,
            to: downloadedTok,
            expectedBytes: spec.tokenizerExpectedBytes,
            configuration: sessionConfiguration
        ) { [weak self] written, _ in
            guard self != nil else { return }
            onProgress?(SemanticDownloadProgress(
                phase: .downloadingTokenizer,
                downloadedBytes: written,
                totalBytes: combinedTotal
            ))
        }
        try Task.checkCancellation()
        if let expectedSHA = spec.tokenizerSHA256 {
            let actualSHA = try Self.sha256Hex(of: downloadedTok)
            guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                throw SemanticModelError.checksumMismatch(file: "tokenizer.json", expected: expectedSHA, actual: actualSHA)
            }
        }

        // 2. Download model.safetensors
        let rawWeightsURL = staging.appendingPathComponent("raw-model.safetensors")
        let tokSize = (try? downloadedTok.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? spec.tokenizerExpectedBytes
        try await downloadSingleFile(
            from: spec.safetensorsURL,
            to: rawWeightsURL,
            expectedBytes: spec.safetensorsExpectedBytes,
            configuration: sessionConfiguration
        ) { [weak self] written, fileExpected in
            guard self != nil else { return }
            let total = tokSize + max(spec.safetensorsExpectedBytes, fileExpected)
            onProgress?(SemanticDownloadProgress(
                phase: .downloadingWeights,
                downloadedBytes: tokSize + written,
                totalBytes: total
            ))
        }
        try Task.checkCancellation()

        onProgress?(SemanticDownloadProgress(
            phase: .verifyingAndOptimizing,
            downloadedBytes: combinedTotal,
            totalBytes: combinedTotal
        ))

        if let expectedSHA = spec.safetensorsSHA256 {
            let actualSHA = try Self.sha256Hex(of: rawWeightsURL)
            guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                throw SemanticModelError.checksumMismatch(file: "model.safetensors", expected: expectedSHA, actual: actualSHA)
            }
        }
        try Task.checkCancellation()

        // 3. Compact FP32 -> FP16 (~224 MB) and delete raw FP32 download
        let installStaging = parent.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: installStaging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: installStaging) }

        try fm.moveItem(at: downloadedTok, to: installStaging.appendingPathComponent("tokenizer.json"))
        try SemanticEmbedder.compactSafetensorsToFP16(
            sourceURL: rawWeightsURL,
            destinationURL: installStaging.appendingPathComponent("model.fp16.safetensors")
        )
        try? fm.removeItem(at: rawWeightsURL)
        try Task.checkCancellation()

        // Warm binary tokenizer cache & validate model
        _ = try SemanticEmbedder(directoryURL: installStaging)

        if fm.fileExists(atPath: modelDirectory.path) {
            _ = try fm.replaceItemAt(modelDirectory, withItemAt: installStaging)
        } else {
            try fm.moveItem(at: installStaging, to: modelDirectory)
        }
        return Self.directoryByteSize(modelDirectory)
    }

    // MARK: - Streaming File Download Helper

    private func downloadSingleFile(
        from remoteURL: URL,
        to destinationURL: URL,
        expectedBytes: Int64,
        configuration: URLSessionConfiguration,
        onWrite: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try Task.checkCancellation()
        if remoteURL.isFileURL {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: remoteURL, to: destinationURL)
            let size = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? expectedBytes
            onWrite(size, max(size, expectedBytes))
            return
        }

        let delegate = FileDownloadDelegate(destinationURL: destinationURL, fallbackExpectedBytes: expectedBytes, onWrite: onWrite)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: remoteURL)

        lock.withLock {
            activeCancellation = {
                task.cancel()
                session.invalidateAndCancel()
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.attachContinuation(continuation, session: session)
                task.resume()
            }
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    public static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            data.withUnsafeBytes { raw in
                let slice = UnsafeRawBufferPointer(rebasing: raw[offset..<end])
                hasher.update(bufferPointer: slice)
            }
            offset = end
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func directoryByteSize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               vals.isRegularFile == true,
               let size = vals.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let fallbackExpectedBytes: Int64
    private let onWrite: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private weak var session: URLSession?
    private var moveError: Error?
    private var lastReportedTime: TimeInterval = 0

    init(
        destinationURL: URL,
        fallbackExpectedBytes: Int64,
        onWrite: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destinationURL = destinationURL
        self.fallbackExpectedBytes = fallbackExpectedBytes
        self.onWrite = onWrite
    }

    func attachContinuation(_ cont: CheckedContinuation<Void, Error>, session: URLSession) {
        lock.lock()
        self.continuation = cont
        self.session = session
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldEmit = (now - lastReportedTime) >= 0.08 || totalBytesWritten == totalBytesExpectedToWrite
        if shouldEmit { lastReportedTime = now }
        lock.unlock()
        if shouldEmit {
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackExpectedBytes
            onWrite(totalBytesWritten, expected)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            lock.lock()
            moveError = SemanticModelError.downloadFailed("HTTP \(http.statusCode)")
            lock.unlock()
            return
        }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let storedMoveError = moveError
        let sess = self.session
        lock.unlock()

        sess?.finishTasksAndInvalidate()

        if let nsErr = error as NSError?, nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            cont?.resume(throwing: SemanticModelError.cancelled)
        } else if let error {
            cont?.resume(throwing: SemanticModelError.downloadFailed(error.localizedDescription))
        } else if let storedMoveError {
            cont?.resume(throwing: storedMoveError)
        } else {
            cont?.resume(returning: ())
        }
    }
}
