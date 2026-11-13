import Foundation
import CryptoKit
import PDFKit
import Vision
import ImageIO
import Darwin
import CozyCore

public enum SearchSourceKind: String, Sendable { case note, text, pdf, image, unsupported }
public enum SearchReadiness: String, Sendable { case ready, pending, partial, unreadable, unsupported }

public struct SearchSource: Sendable {
    public let url: URL
    public let relativePath: String
    public let title: String
    public let kind: SearchSourceKind
    public let state: SearchReadiness
    public let detail: String
    public let isPinned: Bool

    public init(
        url: URL,
        relativePath: String,
        title: String,
        kind: SearchSourceKind,
        state: SearchReadiness,
        detail: String,
        isPinned: Bool = false
    ) {
        self.url = url
        self.relativePath = relativePath
        self.title = title
        self.kind = kind
        self.state = state
        self.detail = detail
        self.isPinned = isPinned
    }
}

public struct SearchHit: Sendable {
    public let source: SearchSource
    public let snippet: String
    public let highlights: [NSRange]
    public let page: Int?
}

private struct SearchPage: Sendable {
    let number: Int?
    let text: String
}

private struct SearchEntry: Sendable {
    let source: SearchSource
    let pages: [SearchPage]
}

public struct SearchSnapshot: Sendable {
    public let sources: [SearchSource]
    public var readyCount: Int { sources.reduce(0) { $0 + ($1.state == .ready ? 1 : 0) } }
    public var pendingCount: Int { sources.reduce(0) { $0 + ($1.state == .pending ? 1 : 0) } }
    public var issueCount: Int { sources.reduce(0) { $0 + ([.partial, .unreadable, .unsupported].contains($1.state) ? 1 : 0) } }
    fileprivate let entries: [SearchEntry]

    fileprivate init(entries: [SearchEntry]) {
        self.entries = entries
        self.sources = entries.map(\.source)
    }

    public func updatingPinnedPaths(_ pinnedPaths: Set<String>) -> SearchSnapshot {
        SearchSnapshot(entries: entries.map { item in
            let shouldPin = item.source.kind == .note && pinnedPaths.contains(item.source.relativePath)
            guard item.source.isPinned != shouldPin else { return item }
            return SearchEntry(
                source: SearchSource(
                    url: item.source.url,
                    relativePath: item.source.relativePath,
                    title: item.source.title,
                    kind: item.source.kind,
                    state: item.source.state,
                    detail: item.source.detail,
                    isPinned: shouldPin
                ),
                pages: item.pages
            )
        })
    }

    public func search(_ query: String) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if terms.isEmpty {
            var hits: [SearchHit] = []
            hits.reserveCapacity(entries.count)
            for entry in entries {
                let page = entry.pages.first
                let snippet = Self.snippet(page?.text ?? entry.source.detail, terms: [])
                hits.append(SearchHit(source: entry.source, snippet: snippet.0, highlights: snippet.1, page: page?.number))
            }
            if hits.contains(where: \.source.isPinned) {
                var pinnedHits: [SearchHit] = []
                var unpinnedHits: [SearchHit] = []
                for hit in hits {
                    if hit.source.isPinned { pinnedHits.append(hit) }
                    else { unpinnedHits.append(hit) }
                }
                return pinnedHits + unpinnedHits
            }
            return hits
        }

        var scored: [(score: Int, order: Int, hit: SearchHit)] = []
        for entry in entries {
            let score = Self.titleScore(for: entry.source, query: trimmed, terms: terms)
            var matched = false
            for page in entry.pages where Self.matches(page.text, terms: terms) {
                let snippet = Self.snippet(page.text, terms: terms)
                let hit = SearchHit(source: entry.source, snippet: snippet.0, highlights: snippet.1, page: page.number)
                scored.append((score, scored.count, hit))
                matched = true
            }
            if !matched && (Self.matches(entry.source.title, terms: terms) || Self.matches(entry.source.relativePath, terms: terms)) {
                let targetText = Self.matches(entry.source.title, terms: terms) ? entry.source.title : entry.source.relativePath
                let snippet = Self.snippet(targetText, terms: terms)
                let hit = SearchHit(source: entry.source, snippet: snippet.0, highlights: snippet.1, page: nil)
                scored.append((score, scored.count, hit))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.hit.source.isPinned != b.hit.source.isPinned { return a.hit.source.isPinned && !b.hit.source.isPinned }
            return a.order < b.order
        }
        return scored.map(\.hit)
    }

    private static func titleScore(for source: SearchSource, query: String, terms: [String]) -> Int {
        let kindBonus = source.kind == .note ? 10 : 0
        if source.title.caseInsensitiveCompare(query) == .orderedSame {
            return 400 + kindBonus
        }
        if source.title.lowercased().hasPrefix(query.lowercased()) {
            return 300 + kindBonus
        }
        if matches(source.title, terms: terms) {
            return 200 + kindBonus
        }
        if terms.contains(where: { source.title.range(of: $0, options: .caseInsensitive) != nil }) {
            return 100 + kindBonus
        }
        return kindBonus
    }

    private static func matches(_ text: String, terms: [String]) -> Bool {
        terms.allSatisfy { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    private static func snippet(_ text: String, terms: [String]) -> (String, [NSRange]) {
        let ns = text as NSString
        let first = terms.compactMap { term -> NSRange? in
            guard let range = text.range(of: term, options: .caseInsensitive) else { return nil }
            return NSRange(range, in: text)
        }.min { $0.location < $1.location }
        let start = max(0, (first?.location ?? 0) - 80)
        let window = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(360, ns.length - start)))
        let value = String(ns.substring(with: window).map { $0.isWhitespace ? Character(" ") : $0 })
        let valueNS = value as NSString
        var ranges: [NSRange] = []
        for term in terms {
            var cursor = value.startIndex
            while cursor < value.endIndex, let range = value.range(of: term, options: .caseInsensitive, range: cursor..<value.endIndex) {
                let expanded = valueNS.rangeOfComposedCharacterSequences(for: NSRange(range, in: value))
                ranges.append(expanded)
                cursor = range.upperBound
            }
        }
        // Merging also prevents overlapping attributes on composed characters.
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let previous = merged.last, NSMaxRange(previous) >= range.location {
                merged[merged.count - 1] = NSUnionRange(previous, range)
            } else { merged.append(range) }
        }
        return (value, merged)
    }
}

/// Public work is serialized by lock; immutable snapshots can cross queues.
public final class CaptureSearch: @unchecked Sendable {
    private let vault: Vault
    private let lock = NSLock()
    private var cache: [String: CachedBytes] = [:]
    private var companionCache: [String: (stamp: Stamp, value: Companion)] = [:]
    private static let marker = "<!-- cozy-extracted-text:v1 "
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif", "ico"]

    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }
    private struct CachedBytes {
        let stamp: Stamp
        let fingerprint: String
        let text: String?
    }
    private struct Segment: Codable {
        let page: Int?
        let location: Int
        let length: Int
    }
    private struct Metadata: Codable {
        let source: String
        let fingerprint: String
        let bodyHash: String
        let state: String
        let detail: String
        let method: String
        let segments: [Segment]
    }
    private struct Companion {
        let metadata: Metadata
        let pages: [SearchPage]
        let contents: String
    }
    private struct Extraction {
        let pages: [SearchPage]
        let state: SearchReadiness
        let detail: String
        let method: String
    }

    public init(vault: Vault) { self.vault = vault }

    public func scan() throws -> SearchSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try scanLocked()
    }

    private func scanLocked() throws -> SearchSnapshot {
        let files = try vault.sourceFiles()
        let pinnedPaths = vault.pinnedRelativePaths()
        let paths = Set(files.map(\.path))
        cache = cache.filter { paths.contains($0.key) }
        companionCache = companionCache.filter { paths.contains($0.key) }
        var entries: [SearchEntry] = []
        for url in files {
            // Generated companions are not originals, even if their source was deleted.
            if Vault.isExtractedCompanion(url, root: vault.root) { continue }
            let relative = relativePath(url)
            let kind = sourceKind(url)
            let isPinned = kind == .note && pinnedPaths.contains(relative)
            if kind == .unsupported {
                entries.append(entry(url, kind: kind, state: .unsupported, detail: "Content extraction is not supported for this format. Filename search is available."))
                continue
            }
            do {
                let bytes = try fingerprint(url, keepText: kind == .note || kind == .text)
                if kind == .note || kind == .text {
                    if let text = bytes.text {
                        entries.append(entry(url, kind: kind, state: .ready, detail: "UTF-8 original", pages: [SearchPage(number: nil, text: text)], isPinned: isPinned))
                    } else {
                        entries.append(entry(url, kind: kind, state: .unreadable, detail: "Not valid UTF-8. Save a UTF-8 text copy to search its contents.", isPinned: isPinned))
                    }
                } else {
                    let companionURL = companionURL(for: relative)
                    if FileManager.default.fileExists(atPath: companionURL.path) {
                        do {
                            let companion = try readCompanion(companionURL, source: relative)
                            if companion.metadata.fingerprint == bytes.fingerprint {
                                let state = SearchReadiness(rawValue: companion.metadata.state) ?? .unreadable
                                entries.append(entry(url, kind: kind, state: state, detail: companion.metadata.detail, pages: companion.pages))
                            } else {
                                entries.append(entry(url, kind: kind, state: .pending, detail: "Original changed. Make searchable to replace the outdated extraction."))
                            }
                        } catch {
                            entries.append(entry(url, kind: kind, state: .unreadable, detail: "Companion is damaged, edited, or occupied. Preserve or move it out of Extracted Text, then Make searchable. \(error.localizedDescription)"))
                        }
                    } else {
                        entries.append(entry(url, kind: kind, state: .pending, detail: "Choose Make searchable to extract local text."))
                    }
                }
            } catch {
                entries.append(entry(url, kind: kind, state: .unreadable, detail: error.localizedDescription, isPinned: isPinned))
            }
        }
        return SearchSnapshot(entries: entries)
    }

    public func makeSearchable(progress: (Int, Int, String) -> Void, cancelled: () -> Bool) throws -> SearchSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try makeSearchableLocked(progress: progress, cancelled: cancelled)
    }

    private func makeSearchableLocked(progress: (Int, Int, String) -> Void, cancelled: () -> Bool) throws -> SearchSnapshot {
        let snapshot = try scanLocked()
        let candidates = snapshot.sources.filter { ($0.kind == .pdf || $0.kind == .image) && ($0.state == .pending || $0.state == .unreadable) }
        var failures: [String: String] = [:]
        for (index, source) in candidates.enumerated() {
            if cancelled() { break }
            progress(index, candidates.count, source.relativePath)
            do {
                let target = companionURL(for: source.relativePath)
                var expected: String?
                // An existing unrecognized or edited file is never replaced, even by manual extraction.
                if FileManager.default.fileExists(atPath: target.path) {
                    expected = try readCompanion(target, source: source.relativePath).contents
                }
                let before = try fingerprint(source.url, keepText: false, force: true).fingerprint
                let extraction = try extract(source.url, kind: source.kind, cancelled: cancelled)
                if cancelled() { break }
                let after = try fingerprint(source.url, keepText: false, force: true).fingerprint
                guard before == after else { throw EngineError.message("Original changed during extraction. Retry Make searchable.") }
                let contents = try render(extraction, source: source.relativePath, fingerprint: after)
                try vault.writeExtractedCompanion(contents, to: target, expectedContent: expected, cancelled: cancelled)
                cache.removeValue(forKey: target.path)
            } catch {
                if cancelled() { break }
                failures[source.url.path] = error.localizedDescription
            }
            progress(index + 1, candidates.count, source.relativePath)
        }
        let result = try scanLocked()
        guard !failures.isEmpty else { return result }
        return SearchSnapshot(entries: result.entries.map { item in
            guard let failure = failures[item.source.url.path] else { return item }
            return entry(item.source.url, kind: item.source.kind, state: .unreadable, detail: failure)
        })
    }

    private func entry(_ url: URL, kind: SearchSourceKind, state: SearchReadiness, detail: String, pages: [SearchPage] = [], isPinned: Bool = false) -> SearchEntry {
        var title = url.deletingPathExtension().lastPathComponent
        if kind == .note, let text = pages.first?.text {
            text.enumerateLines { line, stop in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                title = Vault.title(from: String(line.prefix(160)))
                stop = true
            }
        }
        return SearchEntry(source: SearchSource(url: url, relativePath: relativePath(url), title: title, kind: kind, state: state, detail: detail, isPinned: isPinned), pages: pages)
    }

    private func relativePath(_ url: URL) -> String { String(url.path.dropFirst(vault.root.path.count + 1)) }
    private func sourceKind(_ url: URL) -> SearchSourceKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .note
        case "txt": return .text
        case "pdf": return .pdf
        default: return Self.imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .unsupported
        }
    }
    private func companionURL(for path: String) -> URL {
        vault.root.appendingPathComponent("Extracted Text", isDirectory: true).appendingPathComponent(Self.hash(Data(path.utf8)) + ".md")
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func stamp(_ url: URL) throws -> Stamp {
        try vault.validateSource(url)
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                     changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
    private func fingerprint(_ url: URL, keepText: Bool, force: Bool = false) throws -> CachedBytes {
        let before = try stamp(url)
        if !force, let cached = cache[url.path], cached.stamp == before { return cached }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = Darwin.stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == before.device, opened.st_ino == before.inode,
              opened.st_mode & S_IFMT == S_IFREG else {
            throw EngineError.message("Original was replaced while opening. Refresh to retry.")
        }
        var digest = SHA256()
        var textData = Data()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
            if keepText { textData.append(chunk) }
        }
        guard try stamp(url) == before else { throw EngineError.message("File changed while reading. Refresh to retry.") }
        let result = CachedBytes(stamp: before, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined(), text: keepText ? String(data: textData, encoding: .utf8) : nil)
        cache[url.path] = result
        return result
    }

    private func readCompanion(_ url: URL, source: String) throws -> Companion {
        try vault.validateSource(url)
        let cached = try fingerprint(url, keepText: true)
        if let parsed = companionCache[url.path], parsed.stamp == cached.stamp,
           parsed.value.metadata.source == source { return parsed.value }
        guard let contents = cached.text, let newline = contents.firstIndex(of: "\n") else { throw EngineError.message("Unrecognized companion file.") }
        let header = String(contents[..<newline])
        guard header.hasPrefix(Self.marker), header.hasSuffix(" -->"),
              let data = Data(base64Encoded: String(header.dropFirst(Self.marker.count).dropLast(4))),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.source == source, SearchReadiness(rawValue: metadata.state) != nil else {
            throw EngineError.message("Unrecognized companion metadata.")
        }
        let body = String(contents[contents.index(after: newline)...])
        guard Self.hash(Data(body.utf8)) == metadata.bodyHash else { throw EngineError.message("Companion was edited externally; it will not be overwritten.") }
        let ns = body as NSString
        var pages: [SearchPage] = []
        for segment in metadata.segments {
            guard segment.location >= 0, segment.length >= 0, segment.location <= ns.length,
                  segment.length <= ns.length - segment.location else { throw EngineError.message("Invalid companion text ranges.") }
            let range = NSRange(location: segment.location, length: segment.length)
            guard Range(range, in: body) != nil else { throw EngineError.message("Invalid companion Unicode ranges.") }
            pages.append(SearchPage(number: segment.page, text: ns.substring(with: range)))
        }
        let companion = Companion(metadata: metadata, pages: pages, contents: contents)
        companionCache[url.path] = (cached.stamp, companion)
        return companion
    }

    private func render(_ extraction: Extraction, source: String, fingerprint: String) throws -> String {
        let encodedPath = source.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))! }.joined(separator: "/")
        var body = "# Extracted text\n\nSource: [Original](../\(encodedPath))\n\nMethod: \(extraction.method)\n\nStatus: \(extraction.state.rawValue) — \(extraction.detail)\n"
        var segments: [Segment] = []
        for page in extraction.pages {
            body += "\n## \(page.number.map { "Page \($0)" } ?? "Image text")\n\n"
            let location = (body as NSString).length
            body += page.text
            segments.append(Segment(page: page.number, location: location, length: (page.text as NSString).length))
            body += "\n"
        }
        let metadata = Metadata(source: source, fingerprint: fingerprint, bodyHash: Self.hash(Data(body.utf8)), state: extraction.state.rawValue, detail: extraction.detail, method: extraction.method, segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.marker + (try encoder.encode(metadata)).base64EncodedString() + " -->\n" + body
    }

    private func extract(_ url: URL, kind: SearchSourceKind, cancelled: () -> Bool) throws -> Extraction {
        try vault.validateSource(url)
        if kind == .pdf { return extractPDF(url, cancelled: cancelled) }
        do {
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(image) > 0,
                  let pixels = CGImageSourceCreateImageAtIndex(image, 0, nil) else {
                return Extraction(pages: [], state: .unreadable, detail: "Image cannot be decoded. Open or replace the original.", method: "Vision on-device OCR (English / Indonesian)")
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLanguages = ["en-US", "id-ID"]
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = false
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
            let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
            let handler = VNImageRequestHandler(cgImage: pixels, orientation: orientation, options: [:])
            if cancelled() { throw CocoaError(.userCancelled) }
            try handler.perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Extraction(pages: empty ? [] : [SearchPage(number: nil, text: text)], state: empty ? .unreadable : .ready,
                              detail: empty ? "No readable text found. Use a clearer image or add a text note." : "On-device OCR; check the original for recognition mistakes.", method: "Vision revision 3, English / Indonesian, no language correction")
        } catch {
            if cancelled() { throw error }
            return Extraction(pages: [], state: .unreadable, detail: "OCR failed: \(error.localizedDescription). Open or replace the original.", method: "Vision on-device OCR")
        }
    }

    private func extractPDF(_ url: URL, cancelled: () -> Bool) -> Extraction {
        let method = "PDFKit selectable text (no PDF OCR)"
        guard let document = PDFDocument(url: url) else {
            return Extraction(pages: [], state: .unreadable, detail: "PDF cannot be opened. It may be corrupt; open or replace the original.", method: method)
        }
        guard !document.isLocked, !document.isEncrypted else {
            return Extraction(pages: [], state: .unreadable, detail: "Encrypted PDF. Save an unlocked copy to extract selectable text.", method: method)
        }
        var pages: [SearchPage] = []
        var missing: [Int] = []
        for index in 0..<document.pageCount {
            if cancelled() { break }
            let text = document.page(at: index)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(index + 1) }
            else { pages.append(SearchPage(number: index + 1, text: text)) }
        }
        if pages.isEmpty {
            return Extraction(pages: [], state: .unreadable, detail: "No selectable text in this PDF (\(document.pageCount) pages). Scanned PDFs need an externally OCRed text copy.", method: method)
        }
        let detail = missing.isEmpty ? "Selectable text from all \(document.pageCount) pages." : "No selectable text on pages \(missing.map(String.init).joined(separator: ", ")). Those pages are not searchable; PDF OCR is not supported."
        return Extraction(pages: pages, state: missing.isEmpty ? .ready : .partial, detail: detail, method: method)
    }
}

private enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
