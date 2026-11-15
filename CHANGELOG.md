# Changelog

All notable changes to Cozy Notes are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and [Conventional Commits](https://www.conventionalcommits.org/).

## [0.1.0] - 2026-11-15

### Added
- **Local-First Vault & Recovery (`CozyCore`):**
  - Plain-file Markdown note capture (`Inbox/<UTC-timestamp>-<UUID>.md`) and byte-preserving attachment storage (`Attachments/<UUID>/<filename>`).
  - Compare-and-swap (`expectedContent`) conflict detection and `ExternalEditReviewBanner` (Reload Disk, Overwrite Disk, or Keep Copy) so external edits are never silently overwritten.
  - Device-local checkpoint snapshots and non-destructive recovery in `~/Library/Application Support/CozyNotes/History/<vault-sha256>/`.
  - Checkpointed note deletion to Trash across the folio editor and sidebar index (`b97536d`, `e757494`).
  - Note merge engine (`32967dc`, `ad4ee02`, `ca24d2c`, `e87fafa`) with sidebar multi-selection, reorderable live preview sheet (`MergeNotesSheetController`), attachment relinking, `[[WikiLink]]` rewriting, pin inheritance, and companion window synchronization.
  - Note pinning (`1861f58`) persisted via `.cozy-pins.json`, sorting pinned notes first across the sidebar and Quick Switcher.
  - Inline `#tag` and hierarchical `#tag/subtag` parsing (`1187402`), `CaptureSearch` tag aggregation (`a835559`), horizontal `TagFilterBar` with overflow menu (`353b280`), live `#tag` pills, `#` autocomplete popover, and `⌘`-Click / `⌘Return` tag filtering (`1f083f6`).
  - `[[WikiLink]]` parsing, resolution by title or filename stem, floating `[[` autocomplete, and one-click note creation (`0947566`, `be8d7f8`, `19c078e`).
- **Offline Search & Extraction (`CozySearch`):**
  - In-memory lexical search across Markdown notes, `.txt` files, PDFs (`PDFKit` with 1-based page references), and screenshots/images (`Vision` OCR for `en-US` and `id-ID` with language correction disabled).
  - Readable, deterministic Markdown companion sidecars in `Extracted Text/<sha256>.md` with versioned base64 JSON metadata headers.
  - Title-match ranking above body and companion hits (`97fbc44`).
- **Programmatic AppKit Workspace & Editor (`CozyNotes`):**
  - Two-pane commonplace book layout (`WorkspaceController`) with collapsible index sidebar (`⌘\`), multi-folder workspace windows (`⌃⌘O`, `3a06442`), and standalone `NoteWindowController` comparison windows (`fca6477`, `c534c9f`).
  - Three curated atmospheres (**Obsidian & Ivory**, **Midnight Ink & Porcelain**, **Neo-Acid & Plaster**) and five writing voices (**Avenir Next + New York**, **Charter Book Serif**, **Iowan Old Style**, **SF Mono Typewriter**, **Unbounded + Avenir Neo-Acid Display**) (`76fc1b2`, `21e167c`).
  - Live `MarkdownTextView` editor with `H1`–`H3` gutter badges, Org-mode heading subtree folding and global outline cycling (`Tab` / `⇧Tab`, `18a3623`), interactive `DocumentOutlineView` rail (`f4f96fc`), aligned Markdown pipe tables (`71a31b3`), CommonMark horizontal rules (`a086195`), clickable task checkboxes (`33f0c97`), and clickable external links with a floating Copy/Open action bar (`2c4f9d2`).
  - Critically damped 125ms spring-physics typing caret (`bd340be`, `f89cd2b`) and 30% typewriter below-the-fold auto-scroll (`e361df8`).
  - Full modal **Vim Mode** (`⌃⌘V`) with Normal, Insert, Visual, and Visual Line modes, operators, text objects, counts, undo coalescing, dot-repeat, and Markdown fold/link/checkbox motions (`664219a`, `86aa39b`, `c6b270e`, `1ae33b5`).
  - Global floating **Quick Capture** panel (`⌘⇧Space`) and **Quick Switcher** modal palette (`⌘P` / `⇧⌘F` / `⌘O`) plus **In-Note Find** bar (`⌘F`).
- **Android Capture Companion (`android/`):**
  - Capture-only Android share target and quick note writer (`CaptureActivity`, `VaultWriter`, `CaptureWorker`) writing the same `Inbox/` + `Attachments/<UUID>/` contract via Android's Storage Access Framework (SAF) (`67095de`, `b124d4a`, `30ec468`).
- **Packaging, Performance Harness & Verification:**
  - Built-in 1.2M-character *Moby-Dick* performance benchmark (`--moby-dick-workout`) and 10-step regression suite enforcing `<150ms` initial layout, `<16ms` window resize, `<8ms` P95 typing latency, and `<5MB` memory growth per cycle (`670e432`, `6153926`).
  - Safe macOS `.app` bundle builder and installer (`scripts/build-macos.sh`), custom commonplace icon generator (`packaging/generate-icon.swift`), and release archive packager (`scripts/package-release-macos.sh`) (`3927033`).

### Changed
- Replaced the early experimental agent terminal with offline `CaptureSearch` (`efe3d02`).
- Simplified the sidebar into a chronological index with pinned notes and tag filters (`dc48bef`).
- Optimized outline folding at scale and normalized saved baselines to contiguous UTF-8 for $O(1)$ dirty checks (`e6d013d`, `430a1a0`).

### Fixed
- Pruned dependency and build directories (`node_modules`, `Pods`, `DerivedData`, `.build`, `deps`, `_build`, `target`, `dist`, `vendor`, `venv`, etc.) across vault and project repository discovery while preserving user note folders (`087aefe`, `947eb8b`, `42513c7`).
- Stabilized checklist edits, heading folds, document outline refreshes on paste/prepend, and full-viewport backing tile invalidation on scroll and edit (`66089bb`, `008762a`, `cb97c34`, `3f74fec`).
- Routed `⌘↑` / `⌘↓` to line bounds inside search field editors and forwarded unhandled `cancelOperation` (`Esc`) up the responder chain (`b69d85c`, `b26ecba`).
- Applied default prose attributes when typing plain text into a fresh note after `⌘N` (`3102d47`).
