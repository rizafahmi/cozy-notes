# Contributing to Cozy Notes

Thank you for your interest in contributing to Cozy Notes! Cozy Notes is built around strict simplicity, privacy, and performance invariants. Please read these guidelines before opening an issue or submitting a pull request.

## Core Invariants

Every change to Cozy Notes must preserve the following architectural constraints:

1. **Zero Network Calls:** Cozy Notes is strictly offline and local-first. Never add HTTP clients, telemetry, analytics, update pings, webpage fetching, or cloud/LLM API calls on either macOS or Android.
2. **Zero External Swift Package Dependencies:** `Package.swift` must have zero external dependencies (`dependencies: []`). All macOS functionality uses native Apple frameworks (`AppKit`, `Foundation`, `PDFKit`, `Vision`, `CoreServices`, `Carbon`). Do not introduce CocoaPods, Carthage, or an `.xcodeproj` / `.xcworkspace`.
3. **Programmatic AppKit Only:** The macOS UI is constructed entirely in code using Auto Layout (`Theme.fill(_:in:inset:)`, `Theme.stack(_:orientation:spacing:)`). Do not add SwiftUI views, `.xib` files, or `.storyboard` files.
4. **Plain-File Storage Contract:**
   - Notes live in `Inbox/<UTC-timestamp>-<UUID>.md` (or user-organized Markdown files in the vault).
   - Attachments are copied byte-for-byte into `Attachments/<note-UUID>/<filename>`.
   - Extracted PDF and screenshot OCR text lives in human-readable Markdown companions inside `Extracted Text/<sha256-of-relative-path>.md` with a first-line `<!-- cozy-extracted-text:v1 ... -->` metadata comment.
   - Do not introduce SQLite, CoreData, or proprietary binary index files inside the user's vault.
5. **Non-Destructive I/O & Conflict Safety:**
   - All file writes use atomic temporary files + rename and verify symlink containment via `resolvingSymlinksInPath()`.
   - Edits to existing notes use compare-and-swap (`Vault.save(_:to:expectedContent:)`). External edits on disk must never be silently overwritten.
6. **Moby-Dick Performance Budgets:**
   - Editor and layout changes are gated by `Tests/CozyNotesTests/MobyDickWorkoutTests.swift` against a 1.2M-character *Moby-Dick* document:
     - Initial layout CPU time: `< 150 ms`
     - Window resize average latency: `< 16 ms` (60 fps)
     - Typing P95 keystroke latency: `< 8 ms`
     - Syntax & `[[WikiLink]]` P95 keystroke latency: `< 12 ms`
     - Single chapter fold / unfold: `< 25 ms`; full outline cycle: `< 100 ms`
     - Memory growth per repeat cycle: `< 5 MB`

## Prerequisites

- **macOS:** macOS 14.0 (Sonoma) or later, and Swift 5.9+ via Apple Command Line Tools (`xcode-select --install`) or Xcode.
- **Android (optional, for `android/` changes):** JDK 17, Android SDK Platform 35, and Build-Tools 35.0.0.
- **Shell scripts (optional):** `shellcheck` (`brew install shellcheck`) when editing `scripts/*.sh`.

## Building and Running on a Clean Checkout

```sh
# 1. Clone the repository
git clone https://github.com/rizafahmi/cozy-notes.git
cd cozy-notes

# 2. Build the Swift package
swift build

# 3. Run the full test suite (Vault Core, Capture Search, AppKit UI, and Moby-Dick budgets)
swift test
```

`Package.swift` automatically detects standalone Apple Command Line Tools (`Frameworks` and `plugins/testing`) as well as full Xcode, so `swift test` runs out of the box on either setup.

### Building the `.app` Bundle

To assemble, ad-hoc sign, and verify `.build-app/Cozy Notes.app` without touching `/Applications`:

```sh
scripts/build-macos.sh release --build-only
```

To install into `/Applications/Cozy Notes.app` (or `$HOME/Applications`) and launch:

```sh
scripts/build-macos.sh release
# Or to a custom directory:
scripts/build-macos.sh release --install-dir "$HOME/Applications"
```

To run against an isolated temporary vault while developing:

```sh
COZY_VAULT="/tmp/cozy-dev-vault" .build-app/Cozy\ Notes.app/Contents/MacOS/CozyNotes
```

## Testing Guidelines

- **Dual Test Runner Compatibility:** Keep `#if canImport(XCTest)` and `#if canImport(Testing)` support in test files under `Tests/`.
- **MainActor UI Serialization:** AppKit UI test suites in `Tests/CozyNotesTests/` share `NSApplication.shared` and must be nested inside `extension MobyDickWorkoutSuite` with `@Suite("...", .serialized)` so `swift-testing` executes them serially on `@MainActor`.
- **Async Observation:** When testing views that hop onto a background `DispatchQueue` and return via `DispatchQueue.main.async` (such as `SearchPanel.refresh()`), mark the test `async` and poll using `try? await Task.sleep(...)` rather than spinning `RunLoop.current` synchronously.
- **Hermetic Fixtures:** Every test must create its own temporary directory under `FileManager.default.temporaryDirectory.resolvingSymlinksInPath()` with isolated `Vault` and `LocalHistory` paths, and clean up via `defer`.

## Commit Messages & Pull Requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat(editor): ...`, `fix(core): ...`, `docs: ...`, `test(search): ...`, `perf(workspace): ...`).
- Before opening a PR, verify that:
  1. `swift build && swift test` passes cleanly.
  2. `shellcheck scripts/build-macos.sh scripts/package-release-macos.sh` exits 0 if you touched shell scripts.
  3. No external dependencies or network calls were introduced.

## License

By contributing to Cozy Notes, you agree that your contributions will be licensed under the [MIT License](LICENSE).
