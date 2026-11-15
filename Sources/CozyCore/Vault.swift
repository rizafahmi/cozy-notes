import Foundation
import CryptoKit
import Darwin

public struct NoteRecord: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let modifiedAt: Date
    public let excerpt: String
    public let isPinned: Bool
    public let tags: [String]

    public init(
        url: URL,
        title: String,
        modifiedAt: Date,
        excerpt: String,
        isPinned: Bool = false,
        tags: [String] = []
    ) {
        self.url = url
        self.title = title
        self.modifiedAt = modifiedAt
        self.excerpt = excerpt
        self.isPinned = isPinned
        self.tags = tags
    }
}

public struct NoteTag: Equatable, Sendable {
    public let name: String
    public let fullRange: NSRange
    public let nameRange: NSRange

    public init(name: String, fullRange: NSRange, nameRange: NSRange) {
        self.name = name
        self.fullRange = fullRange
        self.nameRange = nameRange
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

public struct VaultSnapshot: Equatable, Sendable {
    public let id: String
    public let label: String
    public let createdAt: Date
}

public struct MergePreview: Equatable, Sendable {
    public let orderedNotes: [NoteRecord]
    public let targetNote: NoteRecord
    public let mergedContent: String
    public let willBePinned: Bool
    public let affectedBacklinkNoteCount: Int

    public init(
        orderedNotes: [NoteRecord],
        targetNote: NoteRecord,
        mergedContent: String,
        willBePinned: Bool,
        affectedBacklinkNoteCount: Int
    ) {
        self.orderedNotes = orderedNotes
        self.targetNote = targetNote
        self.mergedContent = mergedContent
        self.willBePinned = willBePinned
        self.affectedBacklinkNoteCount = affectedBacklinkNoteCount
    }
}

public struct MergeResult: Equatable, Sendable {
    public let targetRecord: NoteRecord
    public let mergedContent: String
    public let removedNoteURLs: [URL]
    public let rewrittenNoteURLs: [URL]
    public let snapshot: VaultSnapshot

    public init(
        targetRecord: NoteRecord,
        mergedContent: String,
        removedNoteURLs: [URL],
        rewrittenNoteURLs: [URL],
        snapshot: VaultSnapshot
    ) {
        self.targetRecord = targetRecord
        self.mergedContent = mergedContent
        self.removedNoteURLs = removedNoteURLs
        self.rewrittenNoteURLs = rewrittenNoteURLs
        self.snapshot = snapshot
    }
}

public enum VaultError: LocalizedError {
    case unsafePath(String)
    case conflict(String)
    case invalidSnapshot(String)
    case invalidAttachment(String)
    case invalidMerge(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "Unsafe vault path: \(path)"
        case .conflict(let path): return "File changed externally; reload before saving: \(path)"
        case .invalidSnapshot(let id): return "Invalid or incomplete checkpoint: \(id)"
        case .invalidAttachment(let path): return "Attachment is not a regular, non-symlink file: \(path)"
        case .invalidMerge(let reason): return reason
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

    public func previewMerge(_ noteURLs: [URL]) throws -> MergePreview {
        try synchronized {
            let plan = try prepareMergeLocked(noteURLs, expectedContents: [:])
            let targetTitle = Self.extractedTitle(from: plan.mergedContent, fallbackURL: plan.targetURL)
            let targetExcerpt = Self.extractedExcerpt(from: plan.mergedContent)
            let updatedTarget = NoteRecord(
                url: plan.targetURL,
                title: targetTitle,
                modifiedAt: plan.orderedRecords[0].modifiedAt,
                excerpt: targetExcerpt,
                isPinned: plan.willBePinned
            )
            return MergePreview(
                orderedNotes: plan.orderedRecords,
                targetNote: updatedTarget,
                mergedContent: plan.mergedContent,
                willBePinned: plan.willBePinned,
                affectedBacklinkNoteCount: plan.externalRewrites.count
            )
        }
    }

    /// Merges two or more notes in order into the first note, preserving attachments and pin state,
    /// updating vault `[[WikiLinks]]` that pointed to absorbed notes, saving a recovery checkpoint first,
    /// and moving the absorbed note files to Trash.
    @discardableResult
    public func merge(
        _ noteURLs: [URL],
        expectedContents: [URL: String] = [:],
        moveToTrash: Bool = true
    ) throws -> MergeResult {
        try synchronized {
            let plan = try prepareMergeLocked(noteURLs, expectedContents: expectedContents)
            let checkpoint = try makeSnapshot(
                label: "Before merging \(plan.orderedURLs.count) notes into \(plan.orderedRecords[0].title)"
            )
            try atomicWrite(
                Data(plan.mergedContent.utf8),
                to: plan.targetURL,
                expectedContent: plan.originalTexts[plan.targetURL]
            )
            for rewrite in plan.externalRewrites {
                try atomicWrite(
                    Data(rewrite.updated.utf8),
                    to: rewrite.url,
                    expectedContent: rewrite.original
                )
            }
            if plan.updatedPinnedPaths != plan.previousPinnedPaths {
                try writePinnedRelativePathsLocked(plan.updatedPinnedPaths)
            }
            for absorbedURL in plan.absorbedURLs {
                try removeOrTrash(absorbedURL, moveToTrash: moveToTrash)
            }
            let finalTargetRecord = try record(plan.targetURL, pinnedPaths: plan.updatedPinnedPaths)
            return MergeResult(
                targetRecord: finalTargetRecord,
                mergedContent: plan.mergedContent,
                removedNoteURLs: plan.absorbedURLs,
                rewrittenNoteURLs: plan.externalRewrites.map(\.url),
                snapshot: checkpoint
            )
        }
    }

    private struct PreparedMerge {
        let orderedURLs: [URL]
        let orderedRecords: [NoteRecord]
        let targetURL: URL
        let absorbedURLs: [URL]
        let originalTexts: [URL: String]
        let mergedContent: String
        let willBePinned: Bool
        let previousPinnedPaths: Set<String>
        let updatedPinnedPaths: Set<String>
        let externalRewrites: [(url: URL, original: String, updated: String)]
    }

    private func prepareMergeLocked(
        _ noteURLs: [URL],
        expectedContents: [URL: String]
    ) throws -> PreparedMerge {
        var orderedURLs: [URL] = []
        orderedURLs.reserveCapacity(noteURLs.count)
        for rawURL in noteURLs {
            guard rawURL.isFileURL else { throw VaultError.unsafePath(rawURL.absoluteString) }
            let canonical = rawURL.standardizedFileURL.resolvingSymlinksInPath()
            if !orderedURLs.contains(canonical) {
                orderedURLs.append(canonical)
            }
        }
        guard orderedURLs.count >= 2 else {
            throw VaultError.invalidMerge("Select at least two notes to merge.")
        }

        var normalizedExpected: [URL: String] = [:]
        normalizedExpected.reserveCapacity(expectedContents.count)
        for (url, content) in expectedContents where url.isFileURL {
            normalizedExpected[url.standardizedFileURL.resolvingSymlinksInPath()] = content
        }

        for url in orderedURLs {
            try validateNote(url)
            guard !Self.isExtractedCompanion(url, root: root) else {
                throw VaultError.unsafePath(url.path)
            }
            try validateSource(url)
        }

        let allNotes = try notes()
        let pinnedPaths = pinnedRelativePathsLocked()
        let recordsByURL = Dictionary(uniqueKeysWithValues: allNotes.map { ($0.url, $0) })

        var originalTexts: [URL: String] = [:]
        originalTexts.reserveCapacity(orderedURLs.count)
        var orderedRecords: [NoteRecord] = []
        orderedRecords.reserveCapacity(orderedURLs.count)

        for url in orderedURLs {
            let text = try read(url)
            if let expected = normalizedExpected[url], text != expected {
                throw VaultError.conflict(url.path)
            }
            originalTexts[url] = text
            let rec = try recordsByURL[url] ?? record(url, pinnedPaths: pinnedPaths)
            orderedRecords.append(rec)
        }

        let targetURL = orderedURLs[0]
        let absorbedURLs = Array(orderedURLs.dropFirst())
        let absorbedSet = Set(absorbedURLs)

        var nonEmptySections: [(originalIndex: Int, text: String)] = []
        nonEmptySections.reserveCapacity(orderedURLs.count)
        for (idx, url) in orderedURLs.enumerated() {
            let rawSection = originalTexts[url] ?? ""
            let relinked = relinkedSectionLocked(
                rawSection,
                from: url,
                to: targetURL,
                absorbedSet: absorbedSet
            )
            if !relinked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nonEmptySections.append((idx, relinked))
            }
        }

        var combined: String
        if nonEmptySections.isEmpty {
            combined = originalTexts[targetURL] ?? ""
        } else {
            let trimmedPieces = nonEmptySections.enumerated().map { pieceOffset, entry -> String in
                var slice = Substring(entry.text)
                if pieceOffset > 0 || entry.originalIndex > 0 {
                    while let first = slice.first, first == "\n" || first == "\r" {
                        slice.removeFirst()
                    }
                }
                while let last = slice.last, last == "\n" || last == "\r" {
                    slice.removeLast()
                }
                return String(slice)
            }
            combined = trimmedPieces.joined(separator: "\n\n---\n\n") + "\n"
        }

        var updatedPins = pinnedPaths
        var willBePinned = false
        for url in orderedURLs {
            let rel = try relativeNotePathLocked(url)
            if pinnedPaths.contains(rel) {
                willBePinned = true
            }
            if url != targetURL {
                updatedPins.remove(rel)
            }
        }
        if willBePinned {
            updatedPins.insert(try validatedPinnableRelativePathLocked(targetURL))
        }

        var mergedTitle = Self.extractedTitle(from: combined, fallbackURL: targetURL)
        var simulatedPostMerge = Self.simulatedPostMergeNotes(
            from: allNotes,
            targetURL: targetURL,
            targetTitle: mergedTitle,
            targetPinned: willBePinned,
            absorbedSet: absorbedSet
        )
        var wikiTarget = Self.canonicalWikiTarget(
            for: targetURL,
            preferredTitle: mergedTitle,
            in: simulatedPostMerge,
            root: root
        )

        if combined.contains("[[") {
            let updatedCombined = Self.rewriteAbsorbedWikiLinks(
                in: combined,
                preMergeNotes: allNotes,
                absorbedSet: absorbedSet,
                replacementTarget: wikiTarget,
                root: root
            )
            if updatedCombined != combined {
                combined = updatedCombined
                let refreshedTitle = Self.extractedTitle(from: combined, fallbackURL: targetURL)
                if refreshedTitle != mergedTitle {
                    mergedTitle = refreshedTitle
                    simulatedPostMerge = Self.simulatedPostMergeNotes(
                        from: allNotes,
                        targetURL: targetURL,
                        targetTitle: mergedTitle,
                        targetPinned: willBePinned,
                        absorbedSet: absorbedSet
                    )
                    wikiTarget = Self.canonicalWikiTarget(
                        for: targetURL,
                        preferredTitle: mergedTitle,
                        in: simulatedPostMerge,
                        root: root
                    )
                }
            }
        }

        var externalRewrites: [(url: URL, original: String, updated: String)] = []
        for note in allNotes where note.url != targetURL && !absorbedSet.contains(note.url) {
            let extText = try read(note.url)
            guard extText.contains("[[") else { continue }
            let updatedExt = Self.rewriteAbsorbedWikiLinks(
                in: extText,
                preMergeNotes: allNotes,
                absorbedSet: absorbedSet,
                replacementTarget: wikiTarget,
                root: root
            )
            if updatedExt != extText {
                externalRewrites.append((note.url, extText, updatedExt))
            }
        }

        return PreparedMerge(
            orderedURLs: orderedURLs,
            orderedRecords: orderedRecords,
            targetURL: targetURL,
            absorbedURLs: absorbedURLs,
            originalTexts: originalTexts,
            mergedContent: combined,
            willBePinned: willBePinned,
            previousPinnedPaths: pinnedPaths,
            updatedPinnedPaths: updatedPins,
            externalRewrites: externalRewrites
        )
    }

    private func relinkedSectionLocked(
        _ text: String,
        from sourceURL: URL,
        to targetURL: URL,
        absorbedSet: Set<URL>
    ) -> String {
        let ns = text as NSString
        guard ns.length > 4, ns.range(of: "](", options: .literal).location != NSNotFound else {
            return text
        }
        let sourceDir = sourceURL.deletingLastPathComponent()
        let targetDir = targetURL.deletingLastPathComponent()
        let codeSpans = Self.markdownCodeRanges(in: ns)
        var edits: [(range: NSRange, replacement: String)] = []

        var searchStart = 0
        let totalLen = ns.length
        while searchStart < totalLen {
            let hit = ns.range(of: "](", options: .literal, range: NSRange(location: searchStart, length: totalLen - searchStart))
            guard hit.location != NSNotFound else { break }
            let lineRange = ns.lineRange(for: hit)
            let lineStr = ns.substring(with: lineRange)
            let lineNS = lineStr as NSString
            for match in Self.linkedAttachmentRegex.matches(in: lineStr, range: NSRange(location: 0, length: lineNS.length)) where match.numberOfRanges > 1 {
                let fullRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                if codeSpans.contains(where: { NSIntersectionRange($0, fullRange).length > 0 }) {
                    continue
                }
                let isImage = lineNS.character(at: match.range.location) == 0x21
                let rawInnerRange = match.range(at: 1)
                let rawInner = lineNS.substring(with: rawInnerRange)
                let trimmed = rawInner.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      !trimmed.contains("://"),
                      !trimmed.hasPrefix("/"),
                      !trimmed.hasPrefix("#"),
                      !trimmed.lowercased().hasPrefix("mailto:") else { continue }

                let pathPart: String
                let fragmentSuffix: String
                if let hashIdx = trimmed.firstIndex(of: "#") {
                    pathPart = String(trimmed[..<hashIdx])
                    fragmentSuffix = String(trimmed[hashIdx...])
                } else {
                    pathPart = trimmed
                    fragmentSuffix = ""
                }
                guard !pathPart.isEmpty,
                      let decoded = pathPart.removingPercentEncoding,
                      !decoded.isEmpty else { continue }

                let candidate = sourceDir.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
                guard (try? validateSource(candidate)) != nil else { continue }

                let destination: URL
                if !isImage && absorbedSet.contains(candidate) {
                    destination = targetURL
                } else {
                    destination = candidate
                }

                let nextTarget: String
                if destination == targetURL && !fragmentSuffix.isEmpty && !isImage {
                    nextTarget = fragmentSuffix
                } else if sourceDir.path != targetDir.path || destination != candidate {
                    nextTarget = Self.relativeMarkdownPath(from: targetDir, to: destination) + fragmentSuffix
                } else {
                    continue
                }

                if nextTarget != rawInner {
                    let fullInnerRange = NSRange(location: lineRange.location + rawInnerRange.location, length: rawInnerRange.length)
                    edits.append((fullInnerRange, nextTarget))
                }
            }
            searchStart = NSMaxRange(lineRange)
        }

        guard !edits.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for edit in edits.reversed() {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    private static func relativeMarkdownPath(from baseDir: URL, to targetFile: URL) -> String {
        let baseParts = baseDir.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true)
        let targetParts = targetFile.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true)
        var common = 0
        let limit = min(baseParts.count, targetParts.count)
        while common < limit && baseParts[common] == targetParts[common] {
            common += 1
        }
        var relParts = Array(repeating: "..", count: baseParts.count - common)
        for part in targetParts[common...] {
            relParts.append(encodedFilename(String(part)))
        }
        return relParts.isEmpty ? encodedFilename(targetFile.lastPathComponent) : relParts.joined(separator: "/")
    }

    public static func titleAndExcerpt(from text: String, fallbackURL: URL, maxExcerptCharacters: Int = 240) -> (title: String, excerpt: String) {
        var resolvedTitle: String?
        var excerpt = ""
        excerpt.reserveCapacity(min(maxExcerptCharacters + 64, 304))
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolvedTitle == nil {
                guard !trimmed.isEmpty else { return }
                resolvedTitle = title(from: line)
                if maxExcerptCharacters <= 0 {
                    stop = true
                }
                return
            }
            guard !trimmed.isEmpty else { return }
            if !excerpt.isEmpty {
                excerpt.append(" ")
            }
            let remaining = maxExcerptCharacters - excerpt.count
            if remaining <= 0 {
                stop = true
                return
            }
            if trimmed.count >= remaining {
                excerpt.append(contentsOf: trimmed.prefix(remaining))
                stop = true
            } else {
                excerpt.append(trimmed)
            }
        }
        let finalTitle = resolvedTitle ?? fallbackURL.deletingPathExtension().lastPathComponent
        return (finalTitle, String(excerpt.prefix(maxExcerptCharacters)))
    }

    public static func extractedTitle(from text: String, fallbackURL: URL) -> String {
        titleAndExcerpt(from: text, fallbackURL: fallbackURL, maxExcerptCharacters: 0).title
    }

    private static func extractedExcerpt(from text: String) -> String {
        var foundTitle = false
        var excerpt = ""
        excerpt.reserveCapacity(304)
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !foundTitle {
                if !trimmed.isEmpty {
                    foundTitle = true
                }
                return
            }
            guard !trimmed.isEmpty else { return }
            if !excerpt.isEmpty {
                excerpt.append(" ")
            }
            let remaining = 240 - excerpt.count
            if remaining <= 0 {
                stop = true
                return
            }
            if trimmed.count >= remaining {
                excerpt.append(contentsOf: trimmed.prefix(remaining))
                stop = true
            } else {
                excerpt.append(trimmed)
            }
        }
        return String(excerpt.prefix(240))
    }

    private static func simulatedPostMergeNotes(
        from existingNotes: [NoteRecord],
        targetURL: URL,
        targetTitle: String,
        targetPinned: Bool,
        absorbedSet: Set<URL>
    ) -> [NoteRecord] {
        let now = Date()
        var next: [NoteRecord] = []
        next.reserveCapacity(existingNotes.count)
        var insertedTarget = false
        for item in existingNotes where !absorbedSet.contains(item.url) {
            if item.url == targetURL {
                next.append(NoteRecord(url: targetURL, title: targetTitle, modifiedAt: now, excerpt: item.excerpt, isPinned: targetPinned))
                insertedTarget = true
            } else {
                next.append(item)
            }
        }
        if !insertedTarget {
            next.append(NoteRecord(url: targetURL, title: targetTitle, modifiedAt: now, excerpt: "", isPinned: targetPinned))
        }
        next.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
        }
        return next
    }

    private static func canonicalWikiTarget(
        for targetURL: URL,
        preferredTitle: String,
        in postMergeNotes: [NoteRecord],
        root: URL
    ) -> String {
        let cleanedTitle = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty,
           !cleanedTitle.contains("["),
           !cleanedTitle.contains("]"),
           !cleanedTitle.contains("|"),
           !cleanedTitle.contains("#"),
           findMatchingNote(for: cleanedTitle, in: postMergeNotes, root: root)?.url == targetURL {
            return cleanedTitle
        }
        let stem = targetURL.deletingPathExtension().lastPathComponent
        if !stem.isEmpty,
           findMatchingNote(for: stem, in: postMergeNotes, root: root)?.url == targetURL {
            return stem
        }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if targetURL.path.hasPrefix(rootPrefix) {
            let rel = String(targetURL.path.dropFirst(rootPrefix.count))
            return (rel as NSString).deletingPathExtension
        }
        return stem
    }

    private static func resolveWikiTarget(_ rawTarget: String, in candidates: [NoteRecord], root: URL) -> NoteRecord? {
        let cleaned = normalizedWikiTarget(rawTarget)
        guard !cleaned.isEmpty else { return nil }
        if let match = findMatchingNote(for: cleaned, in: candidates, root: root) {
            return match
        }
        if let hashIndex = cleaned.firstIndex(of: "#") {
            let beforeHash = String(cleaned[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !beforeHash.isEmpty, let match = findMatchingNote(for: beforeHash, in: candidates, root: root) {
                return match
            }
        }
        return nil
    }

    private static func rewriteAbsorbedWikiLinks(
        in text: String,
        preMergeNotes: [NoteRecord],
        absorbedSet: Set<URL>,
        replacementTarget: String,
        root: URL
    ) -> String {
        let ns = text as NSString
        let links = wikiLinks(inNSString: ns)
        guard !links.isEmpty else { return text }
        let codeSpans = markdownCodeRanges(in: ns)
        var edits: [(range: NSRange, replacement: String)] = []

        for link in links {
            if codeSpans.contains(where: { NSIntersectionRange($0, link.fullRange).length > 0 }) {
                continue
            }
            guard let resolved = resolveWikiTarget(link.target, in: preMergeNotes, root: root),
                  absorbedSet.contains(resolved.url) else {
                continue
            }
            let fragmentSuffix: String
            if let hashIdx = link.target.firstIndex(of: "#"),
               findMatchingNote(for: normalizedWikiTarget(link.target), in: preMergeNotes, root: root) == nil {
                let beforeHash = String(link.target[..<hashIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                fragmentSuffix = beforeHash.isEmpty ? "" : String(link.target[hashIdx...])
            } else {
                fragmentSuffix = ""
            }
            let nextLink: String
            if let alias = link.alias, !alias.isEmpty {
                nextLink = "[[\(replacementTarget)\(fragmentSuffix)|\(alias)]]"
            } else {
                nextLink = "[[\(replacementTarget)\(fragmentSuffix)]]"
            }
            if nextLink != ns.substring(with: link.fullRange) {
                edits.append((link.fullRange, nextLink))
            }
        }

        guard !edits.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for edit in edits.reversed() {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    private static func markdownCodeRanges(in ns: NSString) -> [NSRange] {
        let total = ns.length
        guard total >= 2 else { return [] }
        var ranges: [NSRange] = []
        var activeFence: (char: unichar, count: Int, startLocation: Int)?
        var lineStart = 0

        while lineStart < total {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = NSMaxRange(lineRange)
            var contentEnd = lineEnd
            while contentEnd > lineRange.location {
                let c = ns.character(at: contentEnd - 1)
                if c == 0x0A || c == 0x0D { contentEnd -= 1 } else { break }
            }

            var cursor = lineRange.location
            var spaces = 0
            while cursor < contentEnd && spaces < 3 && ns.character(at: cursor) == 0x20 {
                cursor += 1
                spaces += 1
            }

            var handledFenceLine = false
            if cursor < contentEnd {
                let first = ns.character(at: cursor)
                if first == 0x60 || first == 0x7E {
                    var run = 0
                    while cursor + run < contentEnd && ns.character(at: cursor + run) == first {
                        run += 1
                    }
                    if run >= 3 {
                        if let open = activeFence {
                            if first == open.char && run >= open.count {
                                var trailingClean = true
                                var t = cursor + run
                                while t < contentEnd {
                                    let ch = ns.character(at: t)
                                    if ch != 0x20 && ch != 0x09 {
                                        trailingClean = false
                                        break
                                    }
                                    t += 1
                                }
                                if trailingClean {
                                    ranges.append(NSRange(location: open.startLocation, length: lineEnd - open.startLocation))
                                    activeFence = nil
                                    handledFenceLine = true
                                }
                            }
                        } else {
                            var validInfo = true
                            if first == 0x60 {
                                var t = cursor + run
                                while t < contentEnd {
                                    if ns.character(at: t) == 0x60 {
                                        validInfo = false
                                        break
                                    }
                                    t += 1
                                }
                            }
                            if validInfo {
                                activeFence = (first, run, lineRange.location)
                                handledFenceLine = true
                            }
                        }
                    }
                }
            }

            if activeFence == nil && !handledFenceLine {
                var idx = lineRange.location
                while idx < contentEnd {
                    if ns.character(at: idx) == 0x60 {
                        var openTicks = 0
                        while idx + openTicks < contentEnd && ns.character(at: idx + openTicks) == 0x60 {
                            openTicks += 1
                        }
                        var scan = idx + openTicks
                        var closedAt: Int?
                        while scan < contentEnd {
                            if ns.character(at: scan) == 0x60 {
                                var closeTicks = 0
                                while scan + closeTicks < contentEnd && ns.character(at: scan + closeTicks) == 0x60 {
                                    closeTicks += 1
                                }
                                if closeTicks == openTicks {
                                    closedAt = scan + closeTicks
                                    break
                                }
                                scan += closeTicks
                            } else {
                                scan += 1
                            }
                        }
                        if let endSpan = closedAt {
                            ranges.append(NSRange(location: idx, length: endSpan - idx))
                            idx = endSpan
                        } else {
                            idx += openTicks
                        }
                    } else {
                        idx += 1
                    }
                }
            }

            lineStart = lineEnd
        }

        if let open = activeFence {
            ranges.append(NSRange(location: open.startLocation, length: total - open.startLocation))
        }
        return ranges
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

    // MARK: - Inline Tags (#tag)

    public static func isTagChar(_ u: unichar) -> Bool {
        if (u >= 0x61 && u <= 0x7A) || (u >= 0x41 && u <= 0x5A) || (u >= 0x30 && u <= 0x39) {
            return true
        }
        if u == 0x5F || u == 0x2D || u == 0x2F { // '_', '-', '/'
            return true
        }
        guard u > 0x7F, let scalar = UnicodeScalar(u) else { return false }
        return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }

    private static func isTagLetter(_ u: unichar) -> Bool {
        if (u >= 0x61 && u <= 0x7A) || (u >= 0x41 && u <= 0x5A) {
            return true
        }
        guard u > 0x7F, let scalar = UnicodeScalar(u) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isHexDigit(_ u: unichar) -> Bool {
        (u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x66) || (u >= 0x41 && u <= 0x46)
    }

    private static func isAsciiDigit(_ u: unichar) -> Bool {
        u >= 0x30 && u <= 0x39
    }

    private static func isValidTagPrefix(in ns: NSString, hashLocation: Int, lineStart: Int) -> Bool {
        if hashLocation <= lineStart { return true }
        let prev = ns.character(at: hashLocation - 1)
        if prev == 0x20 || prev == 0x09 { return true }
        if prev == 0x28 { // '('
            if hashLocation >= lineStart + 2 && ns.character(at: hashLocation - 2) == 0x5D {
                return false
            }
            return true
        }
        return false
    }

    public static func tags(in text: String) -> [NoteTag] {
        tags(inNSString: text as NSString)
    }

    public static func tags(inNSString ns: NSString, range: NSRange? = nil) -> [NoteTag] {
        let searchRange = range ?? NSRange(location: 0, length: ns.length)
        guard searchRange.length >= 2,
              NSMaxRange(searchRange) <= ns.length,
              ns.range(of: "#", options: .literal, range: searchRange).location != NSNotFound else {
            return []
        }

        let fullDocCodeRanges: [NSRange] = (range == nil) ? markdownCodeRanges(in: ns) : []
        var results: [NoteTag] = []
        var searchStart = searchRange.location
        let searchEnd = NSMaxRange(searchRange)

        while searchStart < searchEnd {
            let hit = ns.range(of: "#", options: .literal, range: NSRange(location: searchStart, length: searchEnd - searchStart))
            guard hit.location != NSNotFound else { break }
            let lineRange = NSIntersectionRange(ns.lineRange(for: hit), searchRange)
            defer { searchStart = NSMaxRange(lineRange) }

            let lineStr = ns.substring(with: lineRange)
            let lineNS = lineStr as NSString
            let lineLen = lineNS.length
            guard lineLen >= 2 else { continue }

            var lineExcludedRanges: [NSRange] = []
            if range != nil, lineNS.range(of: "`", options: .literal).location != NSNotFound {
                for r in markdownCodeRanges(in: lineNS) {
                    lineExcludedRanges.append(NSRange(location: lineRange.location + r.location, length: r.length))
                }
            }
            if lineNS.range(of: "[[", options: .literal).location != NSNotFound {
                for link in wikiLinks(inNSString: lineNS) {
                    lineExcludedRanges.append(NSRange(location: lineRange.location + link.fullRange.location, length: link.fullRange.length))
                }
            }
            if lineNS.range(of: "](", options: .literal).location != NSNotFound {
                for match in linkedAttachmentRegex.matches(in: lineStr, range: NSRange(location: 0, length: lineLen)) {
                    lineExcludedRanges.append(NSRange(location: lineRange.location + match.range.location, length: match.range.length))
                }
            }

            var idx = 0
            while idx < lineLen {
                let ch = lineNS.character(at: idx)
                guard ch == 0x23 else {
                    idx += 1
                    continue
                }
                if idx + 1 < lineLen && lineNS.character(at: idx + 1) == 0x23 {
                    while idx < lineLen && lineNS.character(at: idx) == 0x23 {
                        idx += 1
                    }
                    continue
                }
                guard isValidTagPrefix(in: lineNS, hashLocation: idx, lineStart: 0) else {
                    idx += 1
                    continue
                }
                let nameStart = idx + 1
                var end = nameStart
                while end < lineLen && isTagChar(lineNS.character(at: end)) {
                    end += 1
                }
                let nameLen = end - nameStart
                guard nameLen >= 1 && nameLen <= 64 else {
                    idx = max(idx + 1, end)
                    continue
                }
                if end < lineLen && lineNS.character(at: end) == 0x23 {
                    idx = end + 1
                    continue
                }
                let firstCh = lineNS.character(at: nameStart)
                let lastCh = lineNS.character(at: end - 1)
                if firstCh == 0x2F || firstCh == 0x2D || lastCh == 0x2F || lastCh == 0x2D {
                    idx = end
                    continue
                }
                var hasLetter = false
                var hasDigit = false
                var allHex = true
                var hasDoubleSlash = false
                var prevSlash = false
                for pos in nameStart..<end {
                    let c = lineNS.character(at: pos)
                    if isTagLetter(c) { hasLetter = true }
                    if isAsciiDigit(c) { hasDigit = true }
                    if !isHexDigit(c) { allHex = false }
                    if c == 0x2F {
                        if prevSlash {
                            hasDoubleSlash = true
                            break
                        }
                        prevSlash = true
                    } else {
                        prevSlash = false
                    }
                }
                if !hasLetter || hasDoubleSlash {
                    idx = end
                    continue
                }
                if (nameLen == 3 || nameLen == 6 || nameLen == 8) && hasDigit && allHex {
                    idx = end
                    continue
                }

                let fullRange = NSRange(location: lineRange.location + idx, length: 1 + nameLen)
                let nameRange = NSRange(location: lineRange.location + nameStart, length: nameLen)
                let isExcluded = fullDocCodeRanges.contains(where: { NSIntersectionRange($0, fullRange).length > 0 })
                    || lineExcludedRanges.contains(where: { NSIntersectionRange($0, fullRange).length > 0 })
                if !isExcluded {
                    let tagName = lineNS.substring(with: NSRange(location: nameStart, length: nameLen)).lowercased()
                    results.append(NoteTag(name: tagName, fullRange: fullRange, nameRange: nameRange))
                }
                idx = end
            }
        }
        return results
    }

    public static func tag(in text: String, at location: Int, includeTrailingEdge: Bool = false) -> NoteTag? {
        tag(inNSString: text as NSString, at: location, includeTrailingEdge: includeTrailingEdge)
    }

    public static func tag(inNSString ns: NSString, at location: Int, includeTrailingEdge: Bool = false) -> NoteTag? {
        guard ns.length >= 2, location >= 0, location <= ns.length else { return nil }
        let probe = min(location, ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let lineTags = tags(inNSString: ns, range: lineRange)
        return lineTags.first { tag in
            if includeTrailingEdge {
                return location >= tag.fullRange.location && location <= NSMaxRange(tag.fullRange)
            } else {
                return NSLocationInRange(location, tag.fullRange)
            }
        }
    }

    public static func extractTagNames(from text: String) -> [String] {
        let parsed = tags(in: text)
        guard !parsed.isEmpty else { return [] }
        var seen: Set<String> = []
        var unique: [String] = []
        for item in parsed {
            let key = item.name.lowercased()
            if seen.insert(key).inserted {
                unique.append(item.name)
            }
        }
        return unique
    }

    /// Detects an active `#query` being typed at `cursorLocation`.
    /// Returns the full range (including `#`) to replace when a tag is chosen and the current query string.
    public static func activeTagQuery(inNSString ns: NSString, cursorLocation: Int) -> (replacementRange: NSRange, query: String)? {
        guard cursorLocation >= 1, cursorLocation <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(cursorLocation, max(0, ns.length - 1)), length: 0))
        guard cursorLocation > lineRange.location else { return nil }

        var idx = cursorLocation - 1
        while idx >= lineRange.location && isTagChar(ns.character(at: idx)) {
            idx -= 1
        }
        guard idx >= lineRange.location, ns.character(at: idx) == 0x23 else {
            return nil
        }
        let hashLocation = idx
        guard isValidTagPrefix(in: ns, hashLocation: hashLocation, lineStart: lineRange.location) else {
            return nil
        }
        if hashLocation > lineRange.location && ns.character(at: hashLocation - 1) == 0x23 {
            return nil
        }

        let queryStart = hashLocation + 1
        let queryRange = NSRange(location: queryStart, length: cursorLocation - queryStart)
        let query = ns.substring(with: queryRange)
        if query.hasPrefix("/") || query.hasPrefix("-") || query.contains("//") || query.count > 64 {
            return nil
        }

        let lineStr = ns.substring(with: lineRange)
        let lineNS = lineStr as NSString
        let localHashRange = NSRange(location: hashLocation - lineRange.location, length: 1)
        if lineNS.range(of: "`", options: .literal).location != NSNotFound {
            let codeSpans = markdownCodeRanges(in: lineNS)
            if codeSpans.contains(where: { NSIntersectionRange($0, localHashRange).length > 0 }) {
                return nil
            }
        }
        if lineNS.range(of: "[[", options: .literal).location != NSNotFound {
            let links = wikiLinks(inNSString: lineNS)
            if links.contains(where: { NSIntersectionRange($0.fullRange, localHashRange).length > 0 }) {
                return nil
            }
        }

        var replaceEnd = cursorLocation
        let lineEnd = NSMaxRange(lineRange)
        while replaceEnd < lineEnd && isTagChar(ns.character(at: replaceEnd)) {
            replaceEnd += 1
        }
        if replaceEnd < lineEnd && ns.character(at: replaceEnd) == 0x23 {
            return nil
        }
        return (NSRange(location: hashLocation, length: replaceEnd - hashLocation), query)
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
        let (title, excerpt) = Self.titleAndExcerpt(from: text, fallbackURL: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let pinnedSet = pinnedPaths ?? pinnedRelativePathsLocked()
        let isPinned = (try? relativeNotePathLocked(url)).map { pinnedSet.contains($0) } ?? false
        let tags = Self.extractTagNames(from: text)
        return NoteRecord(url: url, title: title, modifiedAt: modified, excerpt: excerpt, isPinned: isPinned, tags: tags)
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
        "bin", "obj", "coverage", "gradle", "checkouts",
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
        "CACHEDIR.TAG",
        "repositories.config"
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
