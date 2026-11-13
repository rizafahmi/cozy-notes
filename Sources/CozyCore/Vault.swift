import Foundation
import CryptoKit
import Darwin

public struct NoteRecord: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let modifiedAt: Date
    public let excerpt: String
    public let isPinned: Bool

    public init(url: URL, title: String, modifiedAt: Date, excerpt: String, isPinned: Bool = false) {
        self.url = url
        self.title = title
        self.modifiedAt = modifiedAt
        self.excerpt = excerpt
        self.isPinned = isPinned
    }
}

public struct WikiLink: Equatable, Sendable {
    public let target: String
    public let alias: String?
    public let fullRange: NSRange
    public let innerRange: NSRange
    public let targetRange: NSRange
    public let aliasRange: NSRange?

    public var displayText: String {
        if let alias, !alias.isEmpty { return alias }
        return target
    }

    public init(
        target: String,
        alias: String? = nil,
        fullRange: NSRange,
        innerRange: NSRange,
        targetRange: NSRange,
        aliasRange: NSRange? = nil
    ) {
        self.target = target
        self.alias = alias
        self.fullRange = fullRange
        self.innerRange = innerRange
        self.targetRange = targetRange
        self.aliasRange = aliasRange
    }
}

public struct LinkedAttachment: Equatable {
    public let url: URL
    public let markdownRange: NSRange

    public init(url: URL, markdownRange: NSRange) {
        self.url = url
        self.markdownRange = markdownRange
    }
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
// Configuration is immutable; every instance operation is protected by lock.
public final class Vault: @unchecked Sendable {
    public static let pinsFilename = ".cozy-pins.json"
    public let root: URL
    private let historyRoot: URL
    private let fm = FileManager.default
    private let lock = NSRecursiveLock()
    private var cachedPins: (stamp: PinsStamp?, paths: Set<String>)?

    private struct Manifest: Codable {
        let id: String
        let label: String
        let createdAt: Date
        let files: [String]
    }

    private struct PinnedManifest: Codable {
        let version: Int
        let pinned: [String]
    }

    private struct PinsStamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
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
            let pinned = pinnedRelativePathsLocked()
            return try files(under: root).filter {
                ["md", "markdown"].contains($0.pathExtension.lowercased()) && !Self.isExtractedCompanion($0, root: root)
            }.map { try record($0, pinnedPaths: pinned) }.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
            }
        }
    }

    public func pinnedRelativePaths() -> Set<String> {
        synchronized { pinnedRelativePathsLocked() }
    }

    public func isPinned(_ noteURL: URL) -> Bool {
        synchronized {
            guard let rel = try? relativeNotePathLocked(noteURL) else { return false }
            return pinnedRelativePathsLocked().contains(rel)
        }
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, for noteURL: URL) throws -> Bool {
        try synchronized {
            let rel = try validatedPinnableRelativePathLocked(noteURL)
            let pinsURL = root.appendingPathComponent(Self.pinsFilename)
            try validate(pinsURL, beneath: root)
            var paths = pinnedRelativePathsLocked()
            if pinned {
                paths.insert(rel)
            } else {
                paths.remove(rel)
            }
            try writePinnedRelativePathsLocked(paths)
            return pinned
        }
    }

    @discardableResult
    public func togglePinned(for noteURL: URL) throws -> Bool {
        try synchronized {
            let rel = try validatedPinnableRelativePathLocked(noteURL)
            let pinsURL = root.appendingPathComponent(Self.pinsFilename)
            try validate(pinsURL, beneath: root)
            var paths = pinnedRelativePathsLocked()
            let nextPinned: Bool
            if paths.contains(rel) {
                paths.remove(rel)
                nextPinned = false
            } else {
                paths.insert(rel)
                nextPinned = true
            }
            try writePinnedRelativePathsLocked(paths)
            return nextPinned
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


    public var isProjectRepository: Bool {
        synchronized {
            Self.isRepositoryDirectory(root, fileManager: fm)
        }
    }

    /// Creates a recovery checkpoint, then moves the note and its dedicated `Attachments/<uuid>` folder to Trash (or removes them if Trash is unavailable or disabled).
    @discardableResult
    public func delete(_ noteURL: URL, moveToTrash: Bool = true) throws -> VaultSnapshot {
        try synchronized {
            try validateNote(noteURL)
            guard !Self.isExtractedCompanion(noteURL, root: root) else {
                throw VaultError.unsafePath(noteURL.path)
            }
            try validateSource(noteURL)
            let noteRecord = try record(noteURL)
            let noteText = try read(noteURL)
            let checkpoint = try makeSnapshot(label: "Before deleting \(noteRecord.title)")

            var attachmentFolders: Set<URL> = []
            let attachmentsRoot = root.appendingPathComponent("Attachments", isDirectory: true)
            let stem = noteURL.deletingPathExtension().lastPathComponent
            if stem.count > 37, let uuid = UUID(uuidString: String(stem.suffix(36))) {
                let dir = attachmentsRoot.appendingPathComponent(uuid.uuidString, isDirectory: true)
                if fm.fileExists(atPath: dir.path) {
                    attachmentFolders.insert(dir)
                }
            }
            for linked in linkedAttachments(in: noteText, relativeTo: noteURL) {
                let parent = linked.url.deletingLastPathComponent()
                if parent.deletingLastPathComponent().path == attachmentsRoot.path,
                   UUID(uuidString: parent.lastPathComponent) != nil {
                    attachmentFolders.insert(parent)
                }
            }

            try removeOrTrash(noteURL, moveToTrash: moveToTrash)
            if let rel = try? relativeNotePathLocked(noteURL) {
                var pinned = pinnedRelativePathsLocked()
                if pinned.remove(rel) != nil {
                    try? writePinnedRelativePathsLocked(pinned)
                }
            }
            for folder in attachmentFolders.sorted(by: { $0.path < $1.path }) where fm.fileExists(atPath: folder.path) {
                try validate(folder, beneath: root)
                try removeOrTrash(folder, moveToTrash: moveToTrash)
            }
            return checkpoint
        }
    }

    private func removeOrTrash(_ url: URL, moveToTrash: Bool) throws {
        try validate(url, beneath: root)
        if moveToTrash {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                // Fall back to direct removal when the volume does not support Trash
            }
        }
        try fm.removeItem(at: url)
    }

    public func attach(_ attachments: [URL], to noteURL: URL, text: String, expectedContent: String) throws -> String {
        try synchronized {
            try validateNote(noteURL)
            guard !attachments.isEmpty else {
                try atomicWrite(Data(text.utf8), to: noteURL, expectedContent: expectedContent)
                return text
            }
            let stem = noteURL.deletingPathExtension().lastPathComponent
            let bucket: String
            if stem.count > 37, let uuid = UUID(uuidString: String(stem.suffix(36))) {
                bucket = uuid.uuidString
            } else {
                bucket = UUID().uuidString
            }
            let attachmentDirectory = root.appendingPathComponent("Attachments/\(bucket)", isDirectory: true)
            let existed = fm.fileExists(atPath: attachmentDirectory.path)
            var copiedURLs: [URL] = []
            var copiedNames: [String] = []
            do {
                try safeDirectory(attachmentDirectory)
                var reserved = (try? fm.contentsOfDirectory(atPath: attachmentDirectory.path)) ?? []
                for source in attachments {
                    guard source.isFileURL else { throw VaultError.invalidAttachment(source.absoluteString) }
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw VaultError.invalidAttachment(source.path)
                    }
                    let base = Self.sanitizedFilename(source.lastPathComponent)
                    var name = base
                    var suffix = 2
                    while reserved.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        let url = URL(fileURLWithPath: base)
                        let ext = url.pathExtension
                        name = "\(url.deletingPathExtension().lastPathComponent)-\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
                        suffix += 1
                    }
                    let destination = attachmentDirectory.appendingPathComponent(name)
                    try fm.copyItem(at: source, to: destination)
                    copiedURLs.append(destination)
                    copiedNames.append(name)
                    reserved.append(name)
                }
                let noteDir = noteURL.deletingLastPathComponent().path
                let relativeDir = noteDir.count > root.path.count ? String(noteDir.dropFirst(root.path.count + 1)) : ""
                let depth = relativeDir.isEmpty ? 0 : relativeDir.split(separator: "/").count
                let prefix = String(repeating: "../", count: depth)
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
                    markdown += "\n\(image ? "!" : "")[\(label)](\(prefix)Attachments/\(bucket)/\(Self.encodedFilename(name)))\n"
                }
                try atomicWrite(Data(markdown.utf8), to: noteURL, expectedContent: expectedContent)
                return markdown
            } catch {
                for copied in copiedURLs { try? fm.removeItem(at: copied) }
                if !existed { try? fm.removeItem(at: attachmentDirectory) }
                throw error
            }
        }
    }

    private static let linkedAttachmentRegex = try! NSRegularExpression(pattern: "!?\\[[^\\]\\n]*\\]\\(([^\\)\\n]+)\\)")

    public func linkedAttachments(in text: String, relativeTo noteURL: URL) -> [LinkedAttachment] {
        linkedAttachments(inNSString: text as NSString, relativeTo: noteURL)
    }

    public func linkedAttachments(inNSString ns: NSString, relativeTo noteURL: URL) -> [LinkedAttachment] {
        synchronized {
            guard ns.length > 4,
                  ns.range(of: "](", options: .literal).location != NSNotFound,
                  (try? validateNote(noteURL)) != nil else { return [] }
            let baseDir = noteURL.deletingLastPathComponent()
            var items: [LinkedAttachment] = []
            var searchStart = 0
            let totalLen = ns.length
            while searchStart < totalLen {
                let hit = ns.range(of: "](", options: .literal, range: NSRange(location: searchStart, length: totalLen - searchStart))
                guard hit.location != NSNotFound else { break }
                let lineRange = ns.lineRange(for: hit)
                let lineStr = ns.substring(with: lineRange)
                let lineNS = lineStr as NSString
                for match in Self.linkedAttachmentRegex.matches(in: lineStr, range: NSRange(location: 0, length: lineNS.length)) where match.numberOfRanges > 1 {
                    let rawTarget = lineNS.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    guard !rawTarget.contains("://"), !rawTarget.hasPrefix("/"),
                          let decoded = rawTarget.removingPercentEncoding,
                          !decoded.isEmpty else { continue }
                    let candidate = baseDir.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
                    guard (try? validateSource(candidate)) != nil else { continue }
                    let fullRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                    items.append(LinkedAttachment(url: candidate, markdownRange: fullRange))
                }
                searchStart = NSMaxRange(lineRange)
            }
            return items
        }
    }

    private static let wikiLinkRegex = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+)\\]\\]")

    public static func wikiLinks(in text: String) -> [WikiLink] {
        wikiLinks(inNSString: text as NSString)
    }

    public static func wikiLinks(inNSString ns: NSString, range: NSRange? = nil) -> [WikiLink] {
        let searchRange = range ?? NSRange(location: 0, length: ns.length)
        guard searchRange.length >= 5,
              NSMaxRange(searchRange) <= ns.length,
              ns.range(of: "[[", options: .literal, range: searchRange).location != NSNotFound else {
            return []
        }
        var results: [WikiLink] = []
        var searchStart = searchRange.location
        let searchEnd = NSMaxRange(searchRange)
        while searchStart < searchEnd {
            let hit = ns.range(of: "[[", options: .literal, range: NSRange(location: searchStart, length: searchEnd - searchStart))
            guard hit.location != NSNotFound else { break }
            let lineRange = NSIntersectionRange(ns.lineRange(for: hit), searchRange)
            let lineStr = ns.substring(with: lineRange)
            let lineNS = lineStr as NSString
            for match in wikiLinkRegex.matches(in: lineStr, range: NSRange(location: 0, length: lineNS.length)) where match.numberOfRanges > 1 {
                let fullRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                let innerRange = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
                let innerStr = lineNS.substring(with: match.range(at: 1))
                let innerNS = innerStr as NSString
                let pipeRange = innerNS.range(of: "|", options: .literal)
                if pipeRange.location != NSNotFound {
                    let rawTarget = innerNS.substring(to: pipeRange.location).trimmingCharacters(in: .whitespaces)
                    guard !rawTarget.isEmpty else { continue }
                    let rawAlias = innerNS.substring(from: NSMaxRange(pipeRange)).trimmingCharacters(in: .whitespaces)
                    let tRange = NSRange(location: innerRange.location, length: pipeRange.location)
                    let aRange = NSRange(location: innerRange.location + NSMaxRange(pipeRange), length: innerNS.length - NSMaxRange(pipeRange))
                    results.append(WikiLink(
                        target: rawTarget,
                        alias: rawAlias.isEmpty ? nil : rawAlias,
                        fullRange: fullRange,
                        innerRange: innerRange,
                        targetRange: tRange,
                        aliasRange: aRange
                    ))
                } else {
                    let rawTarget = innerStr.trimmingCharacters(in: .whitespaces)
                    guard !rawTarget.isEmpty else { continue }
                    results.append(WikiLink(
                        target: rawTarget,
                        alias: nil,
                        fullRange: fullRange,
                        innerRange: innerRange,
                        targetRange: innerRange,
                        aliasRange: nil
                    ))
                }
            }
            searchStart = NSMaxRange(lineRange)
        }
        return results
    }

    public static func wikiLink(in text: String, at location: Int, includeTrailingEdge: Bool = false) -> WikiLink? {
        wikiLink(inNSString: text as NSString, at: location, includeTrailingEdge: includeTrailingEdge)
    }

    public static func wikiLink(inNSString ns: NSString, at location: Int, includeTrailingEdge: Bool = false) -> WikiLink? {
        guard ns.length >= 5, location >= 0, location <= ns.length else { return nil }
        let probe = min(location, ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let links = wikiLinks(inNSString: ns, range: lineRange)
        return links.first { link in
            if includeTrailingEdge {
                return location >= link.fullRange.location && location <= NSMaxRange(link.fullRange)
            } else {
                return NSLocationInRange(location, link.fullRange)
            }
        }
    }

    /// Detects an active `[[query` being typed at `cursorLocation`.
    /// Returns the full range to replace when a note is chosen and the current query string.
    public static func activeWikiLinkQuery(inNSString ns: NSString, cursorLocation: Int) -> (replacementRange: NSRange, query: String)? {
        guard cursorLocation >= 2, cursorLocation <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(cursorLocation, max(0, ns.length - 1)), length: 0))
        guard cursorLocation >= lineRange.location + 2 else { return nil }

        var openLocation: Int?
        var idx = cursorLocation - 1
        while idx > lineRange.location {
            let ch = ns.character(at: idx)
            if ch == 0x0A || ch == 0x0D || ch == 0x5D {
                return nil
            }
            if ch == 0x5B {
                if ns.character(at: idx - 1) == 0x5B {
                    openLocation = idx - 1
                    break
                } else {
                    return nil
                }
            }
            idx -= 1
        }
        guard let openStart = openLocation else { return nil }
        let queryStart = openStart + 2
        let queryRange = NSRange(location: queryStart, length: cursorLocation - queryStart)
        let query = ns.substring(with: queryRange)
        if query.contains("|") || query.contains("\n") || query.contains("\r") {
            return nil
        }

        var replaceEnd = cursorLocation
        let lineEnd = NSMaxRange(lineRange)
        if cursorLocation + 2 <= lineEnd,
           ns.character(at: cursorLocation) == 0x5D,
           ns.character(at: cursorLocation + 1) == 0x5D {
            replaceEnd = cursorLocation + 2
        }
        return (NSRange(location: openStart, length: replaceEnd - openStart), query)
    }

    public static func normalizedWikiTarget(_ rawTarget: String) -> String {
        let firstPart = rawTarget.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawTarget
        return firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func resolveNote(matching rawTarget: String, in existingNotes: [NoteRecord]? = nil) throws -> NoteRecord? {
        try synchronized {
            let cleaned = Self.normalizedWikiTarget(rawTarget)
            guard !cleaned.isEmpty else { return nil }
            let candidates = try existingNotes ?? notes()
            if let match = Self.findMatchingNote(for: cleaned, in: candidates, root: root) {
                return match
            }
            if let hashIndex = cleaned.firstIndex(of: "#") {
                let beforeHash = String(cleaned[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !beforeHash.isEmpty, let match = Self.findMatchingNote(for: beforeHash, in: candidates, root: root) {
                    return match
                }
            }
            return nil
        }
    }

    private static func findMatchingNote(for target: String, in candidates: [NoteRecord], root: URL) -> NoteRecord? {
        if let exact = candidates.first(where: { $0.title == target }) {
            return exact
        }
        if let ci = candidates.first(where: { $0.title.caseInsensitiveCompare(target) == .orderedSame }) {
            return ci
        }
        let strippedExt: String = {
            let lower = target.lowercased()
            if lower.hasSuffix(".markdown") { return String(target.dropLast(9)) }
            if lower.hasSuffix(".md") { return String(target.dropLast(3)) }
            return target
        }()
        if let stemExact = candidates.first(where: { $0.url.deletingPathExtension().lastPathComponent == strippedExt }) {
            return stemExact
        }
        if let stemCI = candidates.first(where: { $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(strippedExt) == .orderedSame }) {
            return stemCI
        }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if let relMatch = candidates.first(where: { note in
            guard note.url.path.hasPrefix(rootPrefix) else { return false }
            let rel = String(note.url.path.dropFirst(rootPrefix.count))
            let relNoExt = (rel as NSString).deletingPathExtension
            return rel.caseInsensitiveCompare(target) == .orderedSame
                || relNoExt.caseInsensitiveCompare(strippedExt) == .orderedSame
        }) {
            return relMatch
        }
        return nil
    }

    public func openOrCreateNote(matching rawTarget: String) throws -> (record: NoteRecord, created: Bool) {
        try synchronized {
            var cleaned = Self.normalizedWikiTarget(rawTarget)
            if let hashIndex = cleaned.firstIndex(of: "#") {
                let beforeHash = String(cleaned[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !beforeHash.isEmpty {
                    cleaned = beforeHash
                }
            }
            guard !cleaned.isEmpty else {
                throw VaultError.unsafePath(rawTarget)
            }
            if let existing = try resolveNote(matching: cleaned) {
                return (existing, false)
            }
            let created = try capture(text: "# \(cleaned)\n\n")
            return (created, true)
        }
    }

    /// Safe original enumeration shared by local indexing and capture.
    public func sourceFiles() throws -> [URL] {
        try synchronized { try files(under: root) }
    }

    public func validateSource(_ url: URL) throws {
        try synchronized {
            try validate(url, beneath: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw VaultError.unsafePath(url.path)
            }
        }
    }

    public static func isExtractedCompanion(_ url: URL, root: URL) -> Bool {
        guard url.isFileURL,
              url.deletingLastPathComponent().path == root.appendingPathComponent("Extracted Text").path,
              url.pathExtension == "md",
              url.resolvingSymlinksInPath().path == url.path else { return false }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        var data = Data()
        do {
            while data.firstIndex(of: 10) == nil {
                guard let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty else { return false }
                data.append(chunk)
                if data.count >= 28, !data.starts(with: Data("<!-- cozy-extracted-text:v1 ".utf8)) { return false }
            }
        } catch { return false }
        guard let end = data.firstIndex(of: 10),
              let first = String(data: data[..<end], encoding: .utf8),
              first.hasPrefix("<!-- cozy-extracted-text:v1 "), first.hasSuffix(" -->"),
              let payload = Data(base64Encoded: String(first.dropFirst(28).dropLast(4))),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["source"] is String, object["fingerprint"] is String,
              object["bodyHash"] is String else { return false }
        return true
    }

    /// Creates without replacement, or updates only the exact previously read contents.
    /// Cancellation is checked at the final commit boundary.
    public func writeExtractedCompanion(_ text: String, to url: URL, expectedContent: String?,
                                        cancelled: () -> Bool) throws {
        try synchronized {
            guard url.deletingLastPathComponent().path == root.appendingPathComponent("Extracted Text").path,
                  url.pathExtension == "md" else { throw VaultError.unsafePath(url.path) }
            try safeDirectory(url.deletingLastPathComponent())
            try atomicWrite(Data(text.utf8), to: url, expectedContent: expectedContent,
                            exclusive: expectedContent == nil, cancelled: cancelled)
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
            cachedPins = nil
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
            let pinsURL = root.appendingPathComponent(Self.pinsFilename)
            if fm.fileExists(atPath: pinsURL.path),
               (try? validateSource(pinsURL)) != nil {
                try fm.copyItem(at: pinsURL, to: storage.appendingPathComponent(Self.pinsFilename))
                paths.append(Self.pinsFilename)
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

    private func record(_ url: URL, pinnedPaths: Set<String>? = nil) throws -> NoteRecord {
        let text = try read(url)
        let lines = text.components(separatedBy: .newlines)
        let index = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let title = index.map { Self.title(from: lines[$0]) } ?? url.deletingPathExtension().lastPathComponent
        let excerpt = lines.enumerated().filter { $0.offset != index }.map(\.element)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let pinnedSet = pinnedPaths ?? pinnedRelativePathsLocked()
        let isPinned = (try? relativeNotePathLocked(url)).map { pinnedSet.contains($0) } ?? false
        return NoteRecord(url: url, title: title, modifiedAt: modified, excerpt: String(excerpt.prefix(240)), isPinned: isPinned)
    }

    private func relativeNotePathLocked(_ noteURL: URL) throws -> String {
        try validateNote(noteURL)
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard noteURL.path.hasPrefix(prefix) else { throw VaultError.unsafePath(noteURL.path) }
        let rel = String(noteURL.path.dropFirst(prefix.count))
        try validateRelative(rel)
        return rel
    }

    private func validatedPinnableRelativePathLocked(_ noteURL: URL) throws -> String {
        let rel = try relativeNotePathLocked(noteURL)
        guard !Self.isExtractedCompanion(noteURL, root: root) else {
            throw VaultError.unsafePath(noteURL.path)
        }
        try validateSource(noteURL)
        return rel
    }

    private func pinsStampLocked(_ pinsURL: URL) -> PinsStamp? {
        var info = Darwin.stat()
        guard Darwin.lstat(pinsURL.path, &info) == 0 else { return nil }
        return PinsStamp(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec,
            changedNanos: info.st_ctimespec.tv_nsec
        )
    }

    private func pinnedRelativePathsLocked() -> Set<String> {
        let pinsURL = root.appendingPathComponent(Self.pinsFilename)
        guard (try? validate(pinsURL, beneath: root)) != nil else {
            cachedPins = nil
            return []
        }
        let currentStamp = pinsStampLocked(pinsURL)
        if let cached = cachedPins, cached.stamp == currentStamp {
            return cached.paths
        }
        guard let currentStamp else {
            cachedPins = (stamp: nil, paths: [])
            return []
        }
        let descriptor = Darwin.open(pinsURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = Darwin.stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == currentStamp.device,
              opened.st_ino == currentStamp.inode,
              opened.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.readToEnd() else {
            return []
        }
        let rawPaths: [String]
        if let manifest = try? JSONDecoder().decode(PinnedManifest.self, from: data) {
            rawPaths = manifest.pinned
        } else if let array = try? JSONDecoder().decode([String].self, from: data) {
            rawPaths = array
        } else {
            cachedPins = (stamp: currentStamp, paths: [])
            return []
        }
        var valid: Set<String> = []
        valid.reserveCapacity(rawPaths.count)
        for item in rawPaths {
            guard (try? validateRelative(item)) != nil else { continue }
            let ext = URL(fileURLWithPath: item).pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            valid.insert(item)
        }
        cachedPins = (stamp: currentStamp, paths: valid)
        return valid
    }

    private func writePinnedRelativePathsLocked(_ paths: Set<String>) throws {
        let pinsURL = root.appendingPathComponent(Self.pinsFilename)
        try validate(pinsURL, beneath: root)
        if paths.isEmpty {
            if fm.fileExists(atPath: pinsURL.path) {
                try validateSource(pinsURL)
                try fm.removeItem(at: pinsURL)
            }
            cachedPins = (stamp: nil, paths: [])
            return
        }
        let manifest = PinnedManifest(version: 1, pinned: paths.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        try atomicWrite(data, to: pinsURL)
        cachedPins = (stamp: pinsStampLocked(pinsURL), paths: paths)
    }

    private func files(under directory: URL) throws -> [URL] {
        try validate(directory, beneath: directory)
        let isRepo = Self.isRepositoryDirectory(root, fileManager: fm)
        let inboxRoot = root.appendingPathComponent("Inbox", isDirectory: true)
        let attachmentsRoot = root.appendingPathComponent("Attachments", isDirectory: true)
        let extractedRoot = root.appendingPathComponent("Extracted Text", isDirectory: true)
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { return [] }
        var result: [URL] = []
        var nestedRepoRoots: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                let canonicalDir = url.standardizedFileURL.resolvingSymlinksInPath()
                let inManagedSubfolder = Self.contains(canonicalDir, in: inboxRoot)
                    || Self.contains(canonicalDir, in: attachmentsRoot)
                    || Self.contains(canonicalDir, in: extractedRoot)
                if !inManagedSubfolder {
                    let inRepo = isRepo || nestedRepoRoots.contains(where: { Self.contains(canonicalDir, in: $0) })
                    if Self.shouldIgnoreDirectory(url, inRepository: inRepo, fileManager: fm) {
                        enumerator.skipDescendants()
                        continue
                    }
                    if !inRepo && Self.isRepositoryDirectory(url, fileManager: fm) {
                        nestedRepoRoots.append(canonicalDir)
                    }
                }
            }
            if values.isRegularFile == true {
                // FileManager enumeration can return physical aliases (e.g. /private/tmp)
                // while Foundation resolves the root to /tmp. Links were rejected above.
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                try validate(canonical, beneath: directory)
                if isRepo {
                    let inManagedSubfolder = Self.contains(canonical, in: inboxRoot)
                        || Self.contains(canonical, in: attachmentsRoot)
                        || Self.contains(canonical, in: extractedRoot)
                    if !inManagedSubfolder {
                        let ext = canonical.pathExtension.lowercased()
                        guard ext == "md" || ext == "markdown" else { continue }
                    }
                }
                result.append(canonical)
            }
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.path < $1.path }
    }

    private func validateNote(_ url: URL) throws {
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw VaultError.unsafePath(url.path) }
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

    private func atomicWrite(_ data: Data, to url: URL, expectedContent: String? = nil,
                             exclusive: Bool = false, cancelled: () -> Bool = { false }) throws {
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
        if cancelled() { throw CocoaError(.userCancelled) }
        if exclusive {
            guard Darwin.link(temporary.path, url.path) == 0 else {
                if errno == EEXIST { throw VaultError.conflict(url.path) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
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

    public static func title(from line: String) -> String {
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

    public static let alwaysIgnoredDirectoryNames: Set<String> = [
        "node_modules", "bower_components", "jspm_packages", "web_modules",
        "pods", "carthage", "deriveddata", "sourcepackages", "xcuserdata",
        "__pycache__", "__pypackages__", "site-packages", "dist-packages",
        "venv", "virtualenv", "pip-wheel-metadata",
        "elm-stuff", "vcpkg_installed", "zig-cache", "lua_modules",
        "dist-newstyle", "_opam", "renv", "packrat"
    ]

    public static let projectIgnoredDirectoryNames: Set<String> = [
        "build", "dist", "out", "target", "vendor",
        "deps", "_build", "_checkouts", "ebin",
        "bin", "obj", "coverage", "gradle", "packages", "checkouts",
        "subprojects", "third_party", "third-party", "3rdparty", "3rd-party", "thirdparty",
        "artifacts", "testresults", "zig-out",
        "_esy", "_site", "godeps", "blib",
        "cmake-build-debug", "cmake-build-release",
        "cmake-build-relwithdebinfo", "cmake-build-minsizerel",
        "cdk.out", "terraform.tfstate.d"
    ]
    public static let ignoredDirectoryNames: Set<String> = alwaysIgnoredDirectoryNames.union(projectIgnoredDirectoryNames)

    public static let projectIgnoredDirectoryPrefixes: [String] = [
        "cmake-build-",
        "bazel-"
    ]

    public static let alwaysIgnoredDirectorySuffixes: [String] = [
        ".egg-info",
        ".dist-info",
        ".egg",
        ".framework",
        ".xcframework",
        ".dsym",
        ".xcodeproj",
        ".xcworkspace",
        ".playground",
        ".doccarchive",
        ".xctest"
    ]

    private static let ignoredDirectoryMarkerFiles: [String] = [
        "pyvenv.cfg",
        "conda-meta",
        "CACHEDIR.TAG"
    ]

    public static func shouldIgnoreDirectory(_ url: URL, inRepository: Bool, fileManager: FileManager = .default) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard !name.isEmpty else { return false }
        if name.hasPrefix(".") { return true }
        if alwaysIgnoredDirectoryNames.contains(name) { return true }
        if alwaysIgnoredDirectorySuffixes.contains(where: { name.hasSuffix($0) }) { return true }
        if inRepository {
            if projectIgnoredDirectoryNames.contains(name) { return true }
            if projectIgnoredDirectoryPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        }
        for marker in ignoredDirectoryMarkerFiles {
            if fileManager.fileExists(atPath: url.appendingPathComponent(marker).path) {
                return true
            }
        }
        return false
    }

    public static let ignoredSourceExtensions: Set<String> = [
        "swift", "kt", "kts", "java", "c", "cc", "cpp", "h", "hpp", "m", "mm",
        "rs", "go", "py", "pyc", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "rb", "php", "cs", "sh", "bash", "zsh", "fish", "toml", "yaml", "yml",
        "json", "jsonl", "xml", "plist", "gradle", "properties", "lock", "sum", "mod",
        "pbxproj", "xcworkspacedata", "storyboard", "xib", "strings", "sql", "sqlite", "db",
        "o", "a", "dylib", "so", "dll", "exe", "class", "jar", "aar", "apk", "ipa", "wasm", "map",
        "css", "scss", "less", "html", "htm", "vue", "svelte", "ex", "exs", "erl", "hrl",
        "gleam", "zig", "hs", "ml", "mli", "elm", "lua", "r", "jl", "dart", "cmake", "nix"
    ]

    private static let repositoryMarkers: Set<String> = [
        ".git", "Package.swift", "Podfile", "Cartfile",
        "package.json", "deno.json", "deno.jsonc", "bunfig.toml", "pnpm-workspace.yaml",
        "Cargo.toml", "go.mod", "go.work",
        "mix.exs", "rebar.config", "gleam.toml",
        "pyproject.toml", "setup.py", "Pipfile",
        "Gemfile", "composer.json",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pom.xml", "build.sbt",
        "deps.edn", "project.clj",
        "pubspec.yaml", "elm.json", "dune-project", "stack.yaml", "cabal.project",
        "build.zig", "build.zig.zon", "renv.lock",
        "Makefile", "CMakeLists.txt", "meson.build",
        "vcpkg.json", "conanfile.py", "BUILD.bazel", "MODULE.bazel",
        "global.json", "Directory.Build.props", "flake.nix"
    ]

    private static func isRepositoryDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return entries.contains(where: { repositoryMarkers.contains($0) })
    }

}
