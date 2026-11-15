# Cozy Notes Architecture & Storage Reference

This document covers the internal design, storage layout, extraction sidecars, conflict resolution, and verification suites for Cozy Notes. For a high-level overview and installation guide, see [README.md](../README.md).

---

## 1. Plain-File Vault Layout & Portable Extraction

```text
Your notes folder/
  Inbox/
    <UTC timestamp>-<UUID>.md
  Attachments/
    <same UUID>/
      original-name.png
  Extracted Text/
    <SHA256 of relative original path>.md
  .cozy-pins.json
```

- **Markdown Notes:** One capture produces one UTF-8 Markdown note in `Inbox/` (with a trailing newline added on macOS if needed). Existing Markdown files organized anywhere inside the vault are also indexed and editable. Attachment-only captures generate a heading from the first filename.
- **Attachments:** Attachment bytes are copied unchanged into `Attachments/<note-uuid>/`. Links appended to notes are relative and percent-encoded. Removing an attachment pill (`×`) removes the Markdown link from the note without deleting the file on disk.
- **Symlink & Repository Safety:** Internal symlinks and hidden/system files are never traversed or indexed. Dependency and build directories (`node_modules`, `Pods`, `DerivedData`, `site-packages`, `venv`, `.build`, `deps`, `_build`, `target`, `dist`, `vendor`, etc.) are automatically pruned. When opened directly on a software project repository (`Vault.isProjectRepository`), indexing outside `Inbox/`, `Attachments/`, and `Extracted Text/` is scoped to Markdown files.

### Extraction Sidecars (`Extracted Text/`)

When pending PDFs or images exist in the collection, a compact notice in the sidebar offers **Make searchable** (or **Retry** for eligible failed extractions) and disappears when no action is needed. **File → Make Searchable** is also available. Processing is manual and runs off the UI thread on macOS.

| Source | Search behavior |
| --- | --- |
| Markdown notes and UTF-8 `.txt` files | Existing text is searchable immediately. |
| Saved links | Search the saved URL and accompanying text. Webpages are not fetched. |
| PDFs | `PDFKit` extracts selectable text, retaining 1-based page references. |
| Screenshots / images | `Vision` recognizes English (`en-US`) and Indonesian (`id-ID`) text from the first image frame, with language correction disabled. EXIF orientation is respected. |
| Other formats | Filename/path search remains available; unsupported content is clearly marked. |

Images and PDFs receive separate, human-readable Markdown companions in `Extracted Text/`. Each companion contains:
1. A first-line HTML comment (`<!-- cozy-extracted-text:v1 <base64-json> -->`) storing the original's relative path, SHA-256 fingerprint, generated-body hash, and text/page ranges.
2. A relative source link, extraction method/status, and per-page extracted text in readable Markdown.

The search index exists only in memory:
- Reopening the collection rebuilds the index from originals and valid companions without rerunning OCR.
- Local caches track file identity, size, and nanosecond modification/change times (`mtime`/`ctime`) so unchanged large files are not reread on every query.
- Removing generated companions makes their originals pending; **Make searchable** regenerates them.
- Changed originals invalidate outdated extracted matches, and deleted originals leave no ghost results.
- Moving an original to a different relative path requires fresh extraction; old orphan companions are preserved on disk but not returned as duplicate sources.
- A companion edited by another tool, damaged metadata, or an occupied target filename is never silently overwritten—the source is marked as needing attention.
- **Cancel** stops between native operations and before companion commits; completed extractions remain available.

---

## 2. Workspace, Typography, and Motion Design

The macOS workspace (`Sources/CozyNotes/`) is built in pure programmatic AppKit:
- **Two-Pane Commonplace Book:** An index desk on the left (`SearchPanel`) with lifted index slips, tag filter bar (`TagFilterBar`), and multi-selection merge support, paired with an inset journal folio page on the right (`CaptureEditor`) featuring a vertical margin rule, monospace dateline header, interactive `DocumentOutlineView` rail, and a centered ~640pt reading column.
- **Three Curated Atmospheres:**
  - **Obsidian & Ivory** (`study`)
  - **Midnight Ink & Porcelain** (`botanical`)
  - **Neo-Acid & Plaster** (`neoAcid`)
- **Five Long-Form Writing Voices:**
  - **Avenir Next + New York** (`humanist`)
  - **Charter Book Serif** (`bookSerif`)
  - **Iowan Old Style** (`editorial`)
  - **SF Mono Typewriter** (`typewriter`)
  - **Unbounded + Avenir Neo-Acid Display** (`neoAcid`)
- **Live Markdown Editor (`MarkdownTextView`):**
  - Three-tier ink luminance hierarchy (luminous heading/bold ink, zero-halation body prose ink, and muted callout ink).
  - Scholarly `H1`–`H3` left-gutter badges with Org-mode subtree folding (`Tab` on a heading or click the gutter badge; `⇧Tab` cycles Overview → Headings Only → Show All) that collapses code blocks, tables, lists, and blank paragraphs to zero layout height without mutating Markdown source text.
  - Aligned Markdown pipe tables, CommonMark horizontal rules, clickable task checkboxes (`- [ ]` / `- [x]`), inline `#tag` pills with `#` autocomplete, `[[WikiLink]]` pills with floating note autocomplete, and clickable external links with a floating Copy/Open action bar.
  - Optional modal **Vim Mode** (`⌃⌘V`) with Normal, Insert, Visual, and Visual Line modes, motions, operators, text objects, atomic Insert-session undo coalescing, and dot-repeat.
- **Restrained Motion:**
  - Ordinary typing uses a Bike-style smooth visual caret with a `0.125s` critically damped spring response while text insertion and logical selection update immediately.
  - Selection/navigation, paste, large or programmatic edits, focus/geometry changes, and macOS Reduce Motion snap the caret immediately.

---

## 3. Syncthing & Conflict Safety

Cozy Notes delegates multi-device synchronization to external file sync tools such as [Syncthing](https://syncthing.net/):
- Select the same local folder on macOS and Android and sync the entire folder, including `Inbox/`, `Attachments/`, and `Extracted Text/`.
- Edits to existing notes on macOS use compare-and-swap (`Vault.save(_:to:expectedContent:)`). If an external process modifies the active note on disk, `ExternalEditReviewBanner` offers **Reload Disk** (with changed-line highlights), **Overwrite Disk**, or **Keep Copy** (saving local edits as a new note in `Inbox/`).

---

## 4. Device-Local Recovery & Checkpoints

- **File → Recovery… → Create checkpoint** saves a snapshot of the collection to `~/Library/Application Support/CozyNotes/History/<vault-path-hash>/`, outside the synced folder.
- Note deletion and note merging automatically create a checkpoint before moving files to Trash.
- Restoring a checkpoint first saves the current on-disk state, restores changed or deleted originals and companions, and retains files created afterward. It is non-destructive recovery of originals rather than a deletion-based rollback.

---

## 5. Verification & Performance Benchmarks

All three test targets (`CozyCoreTests`, `CozySearchTests`, and `CozyNotesTests`) run unattended via `swift test` on both full Xcode (`XCTest`) and standalone Apple Command Line Tools (`swift-testing`), and execute on every push and pull request in GitHub Actions (`.github/workflows/ci.yml`).

### Automated Test Suites (`swift test`)

1. **`CozyCoreTests` (`Tests/CozyCoreTests/VaultTests.swift` — 16 tests):**
   - Attachment byte preservation, percent-encoded Markdown links, filename sanitization, case-variant preservation, and failed-capture rollback.
   - Compare-and-swap conflict rejection on external edit or deletion.
   - Symlink escape rejection across reads, writes, attachments, and snapshots.
   - Project repository build/dependency folder pruning (`node_modules`, `Pods`, `DerivedData`, `.build`, `deps`, `_build`, `target`, `dist`, `vendor`, `venv`).
   - Checkpointed note deletion, snapshot restoration, note pinning (`.cozy-pins.json`), `[[WikiLink]]` resolution/creation, note merging with attachment relinking and link rewriting, and inline `#tag` / `#tag/subtag` parsing.
2. **`CozySearchTests` (`Tests/CozySearchTests/CaptureSearchTests.swift` — 10 tests):**
   - Case-insensitive multi-term `AND` queries, original-language preservation, and Unicode grapheme-safe highlights.
   - Synthetic PDF extraction (`PDFKit` 1-based page references, mixed/scanned/corrupt statuses) and companion tampering/collision protection.
   - Companion invalidation across original edits/deletions, cancellation before commit, pinned-note sorting, and hierarchical `#tag` aggregation/filtering.
3. **`CozyNotesTests` (`Tests/CozyNotesTests/` — 40 tests in 12 serialized `@MainActor` suites):**
   - **Moby-Dick 10-Step Workout (`MobyDickWorkoutTests.swift`):** Stress-tests a 1.2M-character *Moby-Dick* document across initial layout (`< 150 ms` CPU), end/middle scroll + window resize (`< 16 ms` avg), Select All / Cut / Paste / Undo / Redo integrity, middle-of-book typing (`< 8 ms` P95), Org-mode chapter folding (`< 25 ms` single, `< 100 ms` full cycle), In-Note Find (`< 50 ms` across 1.2M chars), live syntax & `[[WikiLink]]` typing (`< 12 ms` P95), comparison window sync (`< 200 ms`), and multi-cycle memory stability (`< 5 MB` growth/cycle).
   - **Editor & Workspace UI Suites:** Checklist click & viewport stability (`ChecklistClickTests`), heading fold layout refresh (`FoldLayoutRefreshTests`), document outline paste/prepend sync (`DocumentOutlineRefreshTests`), CommonMark horizontal rules (`HorizontalRuleRenderingTests`), Markdown link click/copy/open action bar (`LinkInteractionTests`), multi-note merge preview & companion sync (`MergeNotesTests`), note pinning across sidebar/Quick Switcher/companion windows (`PinNotesTests`), sidebar & editor `#tag` workflows (`TaggingTests`), modal Vim editing (`VimModeTests`), search field `⌘↑`/`⌘↓` navigation (`CommandDownNavigationTests`), and new-note prose styling (`NewNoteTextColorTests`).
