# Repository Guidelines

## Project Overview

Cozy Notes (`local.cozy.notes`) is a local-first macOS workspace (AppKit, Swift 5.9+) paired with a lightweight Android capture companion (Kotlin, SDK 35). Users capture text, links, files, and screenshots without mandatory titles or folder hierarchies and retrieve them via lexical search.

Core invariants:
- **Plain-file storage**: Notes (`Inbox/<UTC-timestamp>-<UUID>.md`), attachments (`Attachments/<UUID>/<filename>`), and OCR/PDF extraction sidecars (`Extracted Text/<sha256-of-relative-path>.md`) are ordinary local files synced externally (e.g., via Syncthing).
- **Offline & private**: Zero network requests, zero LLMs/cloud APIs, zero persistent databases, and zero external Swift Package dependencies.
- **Legacy `AGENTS.md` handling**: `Vault` explicitly ignores `AGENTS.md` inside user note vaults during note enumeration, search indexing, and deletion (`Sources/CozyCore/Vault.swift`), while preserving it on disk and in recovery snapshots.

---

## Architecture & Data Flow

### High-Level Structure

The macOS package (`Package.swift`) splits into three strict layers, supplemented by a standalone Android capture client (`android/`):

1. **`CozyCore` (`Sources/CozyCore/Vault.swift`)**: Storage engine, path-traversal/symlink guards, atomic writes, compare-and-swap (CAS) conflict detection, `[[WikiLink]]` parsing, and device-local recovery snapshots (`~/Library/Application Support/CozyNotes/History/<vault-sha256>/`).
2. **`CozySearch` (`Sources/CozySearch/CaptureSearch.swift`)**: In-memory lexical index, `PDFKit` page text extraction (1-based pages, selectable text only), `Vision` screenshot/image OCR (`en-US` and `id-ID`, language correction disabled), and deterministic Markdown companion serialization/validation.
3. **`CozyNotes` (`Sources/CozyNotes/`)**: Programmatic AppKit UI (`WorkspaceController`, `SearchPanel`, `CaptureEditor`, `QuickCaptureController`), FSEvents file watcher (`VaultWatcher`), Carbon global hotkey (`GlobalHotKey`), and semantic theming (`Theme`).
4. **Android Companion (`android/app/src/main/java/app/cozynotes/capture/`)**: Capture-only share target and quick note writer (`CaptureActivity.kt`, `CaptureWorker.kt`, `VaultWriter.kt`) using Android's Storage Access Framework (SAF). Performs no indexing, search, or OCR.

### End-to-End Data Flow

```text
[CaptureEditor / QuickCaptureController / Android SAF Share]
        │
        ▼
Vault.capture(...) / Vault.save(..., expectedContent:)
  ├─ Copies attachments unchanged → Attachments/<UUID>/<filename>
  └─ Writes UTF-8 Markdown via atomic temp (.pending) + rename → Inbox/<timestamp>-<UUID>.md
        │
        ▼
VaultWatcher (FSEvents on macOS, 0.25s latency)
        │ (dispatches to @MainActor)
        ├──► WorkspaceController.refresh() ──► updates editor baseline or surfaces CAS conflict bar
        └──► SearchPanel.refresh()
                   │ (dispatches to serial bg queue "CozyNotes.capture-search")
                   ▼
             CaptureSearch.scan() / processPendingExtractions()
               ├─ Validates nanosecond mtime/ctime + file size + SHA256 fingerprint caches
               ├─ Reads/writes companion sidecars in Extracted Text/<sha256>.md
               └─ Emits immutable SearchSnapshot (Sendable) back to @MainActor UI
```

---

## Key Directories

- `Sources/CozyCore/` — Vault filesystem operations, atomic I/O, attachment staging, wiki-link resolution, and recovery checkpoints.
- `Sources/CozySearch/` — In-memory search engine, `PDFKit`/`Vision` extraction pipelines, and companion Markdown metadata parser.
- `Sources/CozyNotes/` — AppKit window/view controllers, custom `NSTextView` (`MarkdownTextView`), Carbon hotkey bridge, FSEvents watcher, and built-in performance harness.
- `Tests/CozyCoreTests/` — Unit/integration tests for vault capture, path sanitization, conflict saves, and snapshot recovery.
- `Tests/CozySearchTests/` — Search indexing, synthetic PDF/image extraction, companion tampering/invalidation, and cancellation tests.
- `Tests/CozyNotesTests/` — AppKit UI/menu tests and the Moby-Dick typing/scroll/memory benchmark suite.
- `android/app/src/main/` — Android Kotlin capture companion (`CaptureActivity.kt`, `VaultWriter.kt`, `CaptureWorker.kt`).
- `scripts/` — macOS `.app` bundle builder and ad-hoc codesigning script (`scripts/build-macos.sh`).
- `packaging/` — macOS bundle metadata (`packaging/Info.plist`).

*(Note: `Sources/CozyCLI/` is an empty directory left over from the removed CLI interface; do not add code there.)*

---

## Development Commands

### macOS (`Package.swift` / `scripts/build-macos.sh`)

```sh
# Build debug .app bundle and launch
scripts/build-macos.sh debug
open '.build-app/Cozy Notes.app'

# Build optimized release .app bundle
scripts/build-macos.sh release

# Run against an isolated test vault (CLI flag or env var)
open '.build-app/Cozy Notes.app' --args --vault '/tmp/test-vault'
COZY_VAULT='/tmp/test-vault' '.build-app/Cozy Notes.app/Contents/MacOS/CozyNotes'

# Raw SwiftPM build & test
swift build
swift test
swift test --filter CozyCoreTests
swift test --filter CozySearchTests
swift test --filter MobyDickWorkoutTests

# Run the built-in performance & typing benchmark harness directly
swift run CozyNotes --moby-dick-workout --cycles 2 --sample "Whale"
```

### Android (`android/`)

```sh
cd android
# Optional: use project-local toolchain if installed under android/.tools
export JAVA_HOME="$PWD/.tools/jdk-17.0.21+9/Contents/Home"
export ANDROID_HOME="$PWD/.tools/android-sdk"

./gradlew :app:assembleDebug
./gradlew :app:assembleRelease
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

---

## Code Conventions & Common Patterns

- **Programmatic AppKit Only**: No SwiftUI, XIBs, or Storyboards. Construct views in code using Auto Layout and layout helpers in `Sources/CozyNotes/Theme.swift` (`Theme.fill(_:in:inset:)`, `Theme.stack(_:axis:spacing:alignment:)`).
- **Dynamic Semantic Theming**: Never hardcode raw RGB values in view controllers. Use `Theme` tokens (`Theme.canvasBackground`, `Theme.inkPrimary`, `Theme.accent`, `Theme.font(...)`), which use `NSColor(name:) { appearance in ... }` to adapt live to Light/Dark mode, atmospheres (`Obsidian & Ivory`, `Midnight Ink & Porcelain`), and typography voices (`humanist`, `bookSerif`, `editorial`, `typewriter`).
- **Concurrency & Thread Isolation**:
  - Decorate all UI controllers, views, and `AppDelegate` with `@MainActor`.
  - Domain engines (`Vault`, `CaptureSearch`) are `@unchecked Sendable` guarded internally by `NSRecursiveLock` / `NSLock`.
  - Run file scanning and `Vision`/`PDFKit` extraction off the main thread on `CaptureSearch`'s serial background queue; pass immutable `Sendable` structs (`SearchSnapshot`, `NoteRecord`, `SearchHit`) back to `@MainActor`.
- **Dependency Injection & Wiring**:
  - Pass `Vault` explicitly via constructor injection (`WorkspaceController(vault:)`, `SearchPanel(vault:)`, `QuickCaptureController(vault:)`).
  - Coordinate across controllers with `[weak self]` closure callbacks (`onCapture`, `onOpenNote`, `onChooseFolder`, `onOpenWikiLink`) rather than `NotificationCenter` or singletons.
- **Error Handling & Non-Destructive I/O**:
  - Throw typed domain errors conforming to `LocalizedError` (`VaultError.unsafePath`, `.conflict`, `.invalidSnapshot`, `.invalidAttachment`).
  - Edits to existing notes use compare-and-swap via `Vault.save(_:to:expectedContent:)`. External edits throw `VaultError.conflict`, prompting the user to keep their draft as a new note rather than overwriting external changes.
  - All file writes use atomic temporary files (`.pending-*` on Android, `.atomic` / replacement directory on macOS) and verify symlink containment via `resolvingSymlinksInPath()`.
- **Formatting & Naming**:
  - Swift: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, single-file module cohesion where practical (`Vault.swift`, `CaptureSearch.swift`).
  - Kotlin: Official Kotlin style (`kotlin.code.style=official` in `android/gradle.properties`), JDK 17 target.

---

## Important Files

- `Package.swift` — SwiftPM manifest (macOS 14+, Swift 5.9) with automatic Xcode Command Line Tools `Testing`/`XCTest` framework flag detection.
- `Sources/CozyCore/Vault.swift` — Canonical implementation of vault layout, atomic note/attachment writing, conflict detection, and local history snapshots.
- `Sources/CozySearch/CaptureSearch.swift` — Extraction companion format (first-line HTML comment with base64 JSON metadata + readable Markdown body), OCR/PDF indexing, and lexical query evaluation.
- `Sources/CozyNotes/main.swift` — `AppDelegate`, menu bar construction, CLI flag parsing (`--vault`, `--moby-dick-workout`), and lifecycle coordination.
- `Sources/CozyNotes/WorkspaceController.swift` — Two-pane split workspace, autosave debounce (`0.8s`), conflict recovery banner, and mode/theme switching.
- `Sources/CozyNotes/CaptureEditor.swift` — `MarkdownTextView` with live Markdown styling, `H1`–`H3` gutter badges, checklist toggling, `[[WikiLink]]` autocomplete, and spring-physics caret.
- `Sources/CozyNotes/Theme.swift` — Atmosphere palettes, four writing voices, and reusable AppKit controls (`ActionButton`, `SurfaceView`).
- `android/app/src/main/java/app/cozynotes/capture/VaultWriter.kt` — Android SAF implementation of the exact same `Inbox/` + `Attachments/<UUID>/` file contract.

---

## Runtime & Tooling Preferences

- **macOS Toolchain**: macOS 14+ and Swift 5.9+ via Xcode or Command Line Tools (`swift build`, `swift test`, `scripts/build-macos.sh`). Do not introduce external Swift packages, CocoaPods, or Xcode `.xcodeproj` files.
- **Android Toolchain**: JDK 17, Android SDK Platform 35 / Build-Tools 35.0.0, Gradle 8.11.1 wrapper (`./gradlew`). Minimal dependencies only (`androidx.activity`, `androidx.lifecycle:lifecycle-viewmodel`, `androidx.core`).
- **No JS/Node/Rust/Python build steps**: There is no `package.json`, bundler, or external linter config in this repository.

---

## Testing & QA

- **Dual Test Runner Compatibility**: Test files in `Tests/` include `#if canImport(XCTest)` and `#else import Testing` shims so suites compile under both full Xcode (`XCTest`) and standalone Command Line Tools (`swift-testing`). Preserve this compatibility pattern when adding new test files.
- **Isolated Temporary Fixtures**: Every test constructs a private `Fixture` in `FileManager.default.temporaryDirectory.resolvingSymlinksInPath()` with a separate `Vault` root and `LocalHistory` directory, cleaned up via `defer { fixture.cleanup() }`.
- **Synthetic Test Media**: Generate test PDFs (`CGContext`/`CTLineDraw`) and test images (`NSImage`/` NSBitmapImageRep`) programmatically in-memory or inside the temp fixture rather than committing binary fixtures.
- **Performance Budgets (`Tests/CozyNotesTests/MobyDickWorkoutTests.swift`)**: Editor changes must keep the 1.2M-character Moby-Dick stress workout within enforced thresholds:
  - Initial layout CPU time: `< 150 ms`
  - Window resize average latency: `< 16 ms` (60 fps)
  - Typing P95 keystroke latency: `< 8 ms`
  - Memory growth per cycle: `< 5 MB`
