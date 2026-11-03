import Foundation
import CryptoKit
import Darwin

public struct NoteRecord {
    public let url: URL
    public let title: String
    public let modifiedAt: Date
    public let excerpt: String
}

public struct VaultSnapshot {
    public let id: String
    public let label: String
    public let createdAt: Date
}

public enum VaultError: LocalizedError {
    case unsafePath(String)
    case conflict(String)
    case invalidSnapshot(String)
    case invalidAttachment(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "Unsafe vault path: \(path)"
        case .conflict(let path): return "File changed externally; reload before saving: \(path)"
        case .invalidSnapshot(let id): return "Invalid or incomplete checkpoint: \(id)"
        case .invalidAttachment(let path): return "Attachment is not a regular, non-symlink file: \(path)"
        }
    }
}

/// Plain Markdown storage. History deliberately lives outside the synced vault.
public final class Vault {
    public let root: URL
    private let historyRoot: URL
    private let fm = FileManager.default
    private let lock = NSRecursiveLock()

    private struct Manifest: Codable {
        let id: String
        let label: String
        let createdAt: Date
        let files: [String]
    }

    public init(root: URL, historyRoot: URL? = nil) throws {
        guard root.isFileURL else { throw VaultError.unsafePath(root.absoluteString) }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(self.root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.historyRoot = (historyRoot ?? support.appendingPathComponent("CozyNotes/History/\(digest)", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard self.historyRoot.isFileURL,
              !Self.contains(self.historyRoot, in: self.root),
              !Self.contains(self.root, in: self.historyRoot) else {
            throw VaultError.unsafePath(self.historyRoot.path)
        }
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        let instructions = self.root.appendingPathComponent("AGENTS.md")
        // O_EXCL means an existing instruction file (even a dangling symlink) is never replaced.
        let descriptor = Darwin.open(instructions.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        if descriptor >= 0 {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do { try handle.write(contentsOf: Data(Self.agentInstructions.utf8)); try handle.close() }
            catch { try? handle.close(); throw error }
        } else if errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func capture(text: String, attachments: [URL] = []) throws -> NoteRecord {
        try synchronized {
            let id = UUID().uuidString
            let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            let attachmentDirectory = root.appendingPathComponent("Attachments/\(id)", isDirectory: true)
            try safeDirectory(inbox)
            let stamp = Self.timestamp(Date())
            let note = inbox.appendingPathComponent("\(stamp)-\(id).md")
            var copiedNames: [String] = []
            do {
                if !attachments.isEmpty { try safeDirectory(attachmentDirectory) }
                for source in attachments {
                    guard source.isFileURL else { throw VaultError.invalidAttachment(source.absoluteString) }
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw VaultError.invalidAttachment(source.path)
                    }
                    let base = Self.sanitizedFilename(source.lastPathComponent)
                    var name = base
                    var suffix = 2
                    while copiedNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        let url = URL(fileURLWithPath: base)
                        let ext = url.pathExtension
                        name = "\(url.deletingPathExtension().lastPathComponent)-\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
                        suffix += 1
                    }
                    try fm.copyItem(at: source, to: attachmentDirectory.appendingPathComponent(name))
                    copiedNames.append(name)
                }
                var markdown = text
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    markdown = "# \(copiedNames.first ?? "Untitled capture")\n"
                } else if !markdown.hasSuffix("\n") {
                    markdown += "\n"
                }
                for name in copiedNames {
                    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                    let image = Self.imageExtensions.contains(ext)
                    let label = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    markdown += "\n\(image ? "!" : "")[\(label)](../Attachments/\(id)/\(Self.encodedFilename(name)))\n"
                }
                try atomicWrite(Data(markdown.utf8), to: note)
                return try record(note)
            } catch {
                try? fm.removeItem(at: note)
                if !attachments.isEmpty { try? fm.removeItem(at: attachmentDirectory) }
                throw error
            }
        }
    }

    public func notes() throws -> [NoteRecord] {
        try synchronized {
            try files(under: root).filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != "AGENTS.md" }
                .map(record).sorted {
                    $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
                }
        }
    }

    public func read(_ url: URL) throws -> String {
        try synchronized {
            try validateNote(url)
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    public func save(_ text: String, to url: URL, expectedContent: String) throws {
        try synchronized {
            try validateNote(url)
            try atomicWrite(Data(text.utf8), to: url, expectedContent: expectedContent)
        }
    }

    public func snapshot(label: String) throws -> VaultSnapshot {
        try synchronized { try makeSnapshot(label: label) }
    }

    public func snapshots() throws -> [VaultSnapshot] {
        try synchronized {
            guard fm.fileExists(atPath: historyRoot.path) else { return [] }
            try validateHistory()
            return try fm.contentsOfDirectory(at: historyRoot, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .compactMap { directory in
                    guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
                    let manifest = try loadManifest(directory.lastPathComponent)
                    return VaultSnapshot(id: manifest.id, label: manifest.label, createdAt: manifest.createdAt)
                }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Restore originals without deleting files added since the checkpoint.
    /// The current state is checkpointed first so the operation itself is recoverable.
    public func restore(snapshotID: String) throws {
        try synchronized {
            let manifest = try loadManifest(snapshotID)
            let stored = historyRoot.appendingPathComponent(snapshotID).appendingPathComponent("Files")
            // Validate every source and destination before changing any original.
            for path in manifest.files {
                try validateRelative(path)
                try validate(stored.appendingPathComponent(path), beneath: stored)
                try validate(root.appendingPathComponent(path), beneath: root)
                let values = try stored.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw VaultError.invalidSnapshot(snapshotID) }
            }
            _ = try makeSnapshot(label: "Before restoring \(manifest.label)")
            for path in manifest.files {
                let destination = root.appendingPathComponent(path)
                try safeDirectory(destination.deletingLastPathComponent())
                try atomicCopy(from: stored.appendingPathComponent(path), to: destination)
            }
        }
    }

    private func makeSnapshot(label: String) throws -> VaultSnapshot {
        try validateHistory()
        try fm.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let temporary = historyRoot.appendingPathComponent(".pending-\(id)", isDirectory: true)
        let destination = historyRoot.appendingPathComponent(id, isDirectory: true)
        let storage = temporary.appendingPathComponent("Files", isDirectory: true)
        do {
            try fm.createDirectory(at: storage, withIntermediateDirectories: true)
            let originals = try files(under: root)
            var paths: [String] = []
            for original in originals {
                try validate(original, beneath: root)
                let relative = String(original.path.dropFirst(root.path.count + 1))
                let target = storage.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: original, to: target)
                paths.append(relative)
            }
            let manifest = Manifest(id: id, label: label, createdAt: Date(), files: paths.sorted())
            try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
            try fm.moveItem(at: temporary, to: destination)
            return VaultSnapshot(id: id, label: label, createdAt: manifest.createdAt)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private func loadManifest(_ id: String) throws -> Manifest {
        guard UUID(uuidString: id) != nil else { throw VaultError.invalidSnapshot(id) }
        try validateHistory()
        let directory = historyRoot.appendingPathComponent(id)
        let url = directory.appendingPathComponent("manifest.json")
        try validate(url, beneath: historyRoot)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.id == id, Set(manifest.files).count == manifest.files.count else { throw VaultError.invalidSnapshot(id) }
        for file in manifest.files { try validateRelative(file) }
        return manifest
    }

    private func validateHistory() throws {
        // Re-resolving catches a history directory replaced by a symlink after init.
        guard historyRoot.resolvingSymlinksInPath().path == historyRoot.path else {
            throw VaultError.unsafePath(historyRoot.path)
        }
    }

    private func record(_ url: URL) throws -> NoteRecord {
        let text = try read(url)
        let lines = text.components(separatedBy: .newlines)
        let index = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let title = index.map { Self.title(from: lines[$0]) } ?? url.deletingPathExtension().lastPathComponent
        let excerpt = lines.enumerated().filter { $0.offset != index }.map(\.element)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        return NoteRecord(url: url, title: title, modifiedAt: modified, excerpt: String(excerpt.prefix(240)))
    }

    private func files(under directory: URL) throws -> [URL] {
        try validate(directory, beneath: directory)
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true {
                // FileManager enumeration can return physical aliases (e.g. /private/tmp)
                // while Foundation resolves the root to /tmp. Links were rejected above.
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                try validate(canonical, beneath: directory)
                result.append(canonical)
            }
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.path < $1.path }
    }

    private func validateNote(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "md" else { throw VaultError.unsafePath(url.path) }
        try validate(url, beneath: root)
    }

    private static func contains(_ url: URL, in directory: URL) -> Bool {
        url.path == directory.path || url.path.hasPrefix(directory.path == "/" ? "/" : directory.path + "/")
    }

    private func validate(_ url: URL, beneath directory: URL) throws {
        guard url.isFileURL, Self.contains(url.standardizedFileURL, in: directory),
              url.standardizedFileURL.path == url.path,
              directory.resolvingSymlinksInPath().path == directory.path,
              url.resolvingSymlinksInPath().path == url.path else { throw VaultError.unsafePath(url.path) }
        // Resolving does not necessarily expose a dangling symlink, so inspect each component.
        var cursor = url
        while Self.contains(cursor, in: directory) {
            if let attributes = try? fm.attributesOfItem(atPath: cursor.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw VaultError.unsafePath(cursor.path)
            }
            if cursor.path == directory.path { break }
            cursor.deleteLastPathComponent()
        }
    }

    private func validateRelative(_ path: String) throws {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !pieces.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }), !path.contains("\0") else {
            throw VaultError.unsafePath(path)
        }
    }

    private func safeDirectory(_ url: URL) throws {
        try validate(url, beneath: root)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try validate(url, beneath: root)
    }

    private func atomicWrite(_ data: Data, to url: URL, expectedContent: String? = nil) throws {
        try validate(url, beneath: root)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".cozy-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try validate(url, beneath: root)
        if let expectedContent {
            guard let current = try? String(contentsOf: url, encoding: .utf8), current == expectedContent else {
                throw VaultError.conflict(url.path)
            }
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }

    private func atomicCopy(from source: URL, to destination: URL) throws {
        try validate(destination, beneath: root)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".cozy-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        try validate(destination, beneath: root)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func title(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Untitled capture" : title
    }

    private static func sanitizedFilename(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" ? "_" : String(scalar)
        }.joined()
        let value = scalars.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "attachment" : value
    }

    private static func encodedFilename(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS"
        return formatter.string(from: date)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif", "ico"]

    private static let agentInstructions = """
    # Cozy Notes vault

    This folder is the source of truth: plain UTF-8 Markdown notes and original attachments, synced externally (for example by Syncthing). There is no database or built-in cloud sync.

    When explicitly asked to do housekeeping, review Inbox and existing notes. You may rename, group, link, merge, and rewrite related notes to improve their usefulness without losing the user's meaning or details. Read notes before modifying them. Do not invent facts or claim an attachment was inspected when it was not.

    For images and other attachments, create or update Markdown companion descriptions, searchable observations, and transcriptions when the actual agent tools can inspect the content. State uncertainty and limitations. Preserve the original attachment bytes and files; keep Markdown links valid when moving notes. Do not delete original attachments as part of housekeeping.

    Never overwrite or delete sync-conflict copies: report their paths and ask the user to resolve ambiguous changes. Report the paths of notes and companions you create or change. Skip hidden folders and local history. Do not follow symlinks outside this vault.

    Agent sessions have recovery checkpoints, not per-command backups. Request a checkpoint before destructive changes. Cloud-hosted agents may send note and attachment content to their provider under that provider's privacy policy; use a local harness/model when that is not acceptable. No OCR or transcription service is configured automatically.
    """ + "\n"
}
