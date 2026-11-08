# Cozy Notes

A cozy, notes-first macOS workspace and a small Android capture companion. Save text, links, files, and screenshots without choosing a title or maintaining folders. Find them later using words you remember.

Notes and attachments are ordinary local files. Syncthing handles synchronization separately. Search and extraction use no LLM, account, API key, paid service, or network request. The former terminal/agent interface and its dependencies have been removed.

## macOS

Requires macOS 14+ and Swift 5.9+ (Command Line Tools or Xcode). The Mac app has no external package dependencies. Screenshot recognition uses the English and Indonesian language models supplied by the installed macOS Vision framework; actual recognition was verified on macOS 27. Older systems without the requested language support report an OCR error rather than pretending extraction succeeded.

```sh
scripts/build-macos.sh debug
open '.build-app/Cozy Notes.app'
```

Use `scripts/build-macos.sh release` for an optimized build. The bundle is locally ad-hoc signed, not notarized for distribution. Rebuilding replaces only the generated bundle under `.build-app/`, never your notes folder.

The app initially uses `~/Documents/Cozy Notes`. The sidebar menu (`⋯`) or **File → Choose Notes Folder…** selects another collection; **Open Notes Folder** opens it in Finder. To launch with an explicit collection:

```sh
open '.build-app/Cozy Notes.app' --args --vault '/path/to/notes'
```

`COZY_VAULT` also overrides the device-local folder preference. Existing files—including legacy `AGENTS.md`—are not removed. New collections no longer generate agent instructions, and existing `AGENTS.md` files are excluded from notes/search, not from recovery snapshots.

### Workspace and Live Notes

The workspace is designed as a tactile commonplace book: an index desk on the left with lifted index slips, and an inset journal folio page on the right with a scholarly vertical margin rule, monospace dateline header, and a centered ~640pt reading column.

Two curated atmospheres (**Obsidian & Ivory** and **Midnight Ink & Porcelain**) and four long-form writing voices (**Avenir Next + New York**, **Charter Book Serif**, **Iowan Old Style**, and **SF Mono Typewriter**) are built in. The editor uses a three-tier ink luminance hierarchy (luminous heading/bold ink, zero-halation body prose ink, and muted callout ink), element-specific paragraph rhythm (airy prose leading, grouped checklists with hanging indents, and compact code blocks), scholarly `H1`–`H3` left-gutter badges, custom-drawn blockquote ink bars, and monospace reading-time telemetry.

- **Live continuous writing:** typing in the main editor writes and autosaves directly to the active note in place—your note never vanishes after saving, and there is no read-only lock on Markdown notes.
- **Command–N:** save any pending edits and start a fresh note in the editor.
- **Command–\\:** toggle the index sidebar to enter or leave distraction-free Focus Mode.
- **Command–Shift–Y (or click `Aa AVENIR` / `CHARTER` / `IOWAN` / `MONO` in the folio header):** cycle through the four writing voices.
- **Command–Plus / Command–Minus / Command–0:** scale the editor writing size up, down, or back to default.
- **Command–Shift–D:** toggle Light / Dark appearance directly inside Cozy Notes.
- **Command–Shift–T (or click `OBSIDIAN` / `MIDNIGHT` in the folio header):** switch between **Obsidian & Ivory** and **Midnight Ink & Porcelain** atmospheres.
- **Command–F (or Command–2):** reveal the sidebar and focus the search bar. **Command–1** focuses the note editor.
- **Command–S / Command–Return:** save the active note immediately (or keep the capture in Quick Capture).
- **Attachments in any note:** paste an image, drop files, or click **Attach** on either a brand-new note or an existing note. Files are copied into `Attachments/<note-uuid>/`, relative Markdown links are appended, and interactive preview pills appear at the bottom of the editor. Clicking an attachment pill opens the file; clicking `×` removes the link from the note without deleting the file on disk.
- **Conflict safety:** detected external edits are never silently overwritten; **Keep as new note** preserves local edits as a separate note.
- **Command–Shift–Space:** global floating Quick Capture, independent of the main workspace and without Accessibility permission. **Escape** tucks it away without clearing its draft; **Command–Return** saves and restores focus to the previous application.

### Make searchable

When pending PDFs or images exist in the collection, a compact notice in the sidebar offers **Make searchable** (or **Retry** for eligible failed extractions) and disappears when no action is needed. **File → Make Searchable** is also available. Processing is manual and runs off the UI thread on the Mac.

| Source | Search behavior |
| --- | --- |
| Markdown notes and UTF-8 `.txt` files | Existing text is searchable immediately. |
| Saved links | Search the saved URL and accompanying text. Webpages are not fetched. |
| PDFs | PDFKit extracts selectable text, retaining 1-based page references. |
| Screenshots/images | Vision recognizes English/Indonesian text from the first image frame, with language correction disabled. EXIF orientation is respected. |
| Other formats | Filename/path search remains available; unsupported content is clearly marked. |

Search is case-insensitive and uses the original language. Whitespace-separated terms must all occur in the same text document or PDF page; partial words are allowed. Filename/path matching is a fallback. There is no translation, semantic search, or generated answer pretending to be a match.

Results show title, highlighted snippet (or clean body preview when browsing), relative date/readiness badge, and PDF page where relevant. Clicking a Markdown note in the sidebar opens it immediately in the editor; double-clicking, pressing Return, or clicking **Open ↗** opens PDFs, images, and text files in the system's default viewer. PDF page references are displayed, but the viewer is not guaranteed to jump to that page.

Pending, partial, unreadable, and unsupported sources remain visible when browsing. A no-match message explains pending extraction. Scanned PDFs are not OCRed; mixed PDFs retain searchable selectable-text pages and identify missing pages. Encrypted/corrupt PDFs, blank or damaged images, and non-UTF-8 text receive explicit statuses. Native OCR can misrecognize text; use the original to verify it.

**Cancel** stops between native operations and before companion commits; a native OCR call may finish before cancellation takes effect. Completed extractions remain available. Shutting down the workspace cancels work and suppresses obsolete UI callbacks.

### Portable extraction and rebuilding

```text
Your notes folder/
  Inbox/
    <UTC timestamp>-<UUID>.md
  Attachments/
    <same UUID>/
      original-name.png
  Extracted Text/
    <SHA256 of relative original path>.md
```

One capture produces one UTF-8 Markdown note. Textual Markdown is preserved (with a trailing newline added on Mac if needed). Attachment-only captures get a heading from the first filename. Attachment bytes are copied unchanged; links are relative and percent-encoded. Internal symlinks and hidden/system files are not indexed.

Images and PDFs get separate, readable Markdown companions in **Extracted Text**. Each contains a relative source link, method/status, and per-page extracted text. A first-line HTML comment holds versioned base64-encoded JSON describing the original's relative path and SHA256 fingerprint, generated-body hash, and text/page ranges. It is metadata, not a proprietary store: the useful extraction remains readable Markdown.

The search index exists only in memory. Reopening the collection rebuilds it from originals and valid companions without rerunning OCR. Removing generated companions makes their originals pending; **Make searchable** regenerates them. Changed originals invalidate outdated extracted matches, and deleted originals do not leave ghost results. Moving an original to a different relative path requires fresh extraction; old orphan companions are preserved but not returned as duplicate sources.

A companion edited by another tool, damaged metadata, or an occupied target filename is never silently overwritten. The source is marked as needing attention. Preserve any manual corrections in your own note, move the conflicting file out of **Extracted Text**, then run **Make searchable**. Ordinary user notes without generated metadata remain searchable even inside that folder.

Original notes, images, and PDFs are never rewritten by extraction. Atomic companion commits reject collisions or intervening edits; original fingerprints are checked before/after extraction. Local caches track file identity, size, and nanosecond modification/change times so unchanged large files are not reread on every query.

## Android

Requires Android 8+ on the device, JDK 17, Android SDK platform 35 and build-tools 35.0.0. The Gradle 8.11.1 wrapper is included with a pinned distribution checksum. Install prerequisites through Android Studio/SDK Manager, accept licenses, and set `JAVA_HOME` and `ANDROID_HOME` (or an ignored `android/local.properties` containing `sdk.dir=...`).

```sh
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

This development environment also has ignored, project-local tools installed with explicit SDK-license consent:

```sh
cd android
export JAVA_HOME="$PWD/.tools/jdk-17.0.21+9/Contents/Home"
export ANDROID_HOME="$PWD/.tools/android-sdk"
./gradlew :app:assembleDebug
"$ANDROID_HOME/platform-tools/adb" install -r app/build/outputs/apk/debug/app-debug.apk
```

Open **Cozy Notes**, choose a writable local folder using Android's system picker, and sync the corresponding folder separately using Syncthing. Share text, links, screenshots, or files into the app; optionally add context, then save. Direct text capture is available by opening the app. Android remains capture-only: no search, OCR, terminal, or broad storage/network permission.

Wait for the save confirmation before leaving. Activity recreation retains an accepted save; process termination can interrupt it. Revoked folder access requires reselection. Incomplete `.pending` files are not committed notes; failures retain input and report cleanup problems.

## Syncthing

Select the corresponding local collection on both devices and sync the entire folder, including **Attachments** and **Extracted Text**. There is no app-level connection or sync account. Multi-file synchronization is not transactional: let attachment transfers finish before processing on the Mac. Conflict copies remain ordinary files and are not automatically resolved.

The shared file format and actual Android captures were exercised on Mac. Physical-device Syncthing transport was not reconfigured or tested in this change.

## Recovery

**Find → Recovery… → Create checkpoint** saves the collection to `~/Library/Application Support/CozyNotes/History/<vault-path-hash>/`, outside the synced folder. Recovery is also available from File. History is device-local and tied to the collection path; moving the collection does not migrate it automatically. The terminal is not needed to create or restore checkpoints.

Restoring a checkpoint first saves the current on-disk state, restores changed/deleted originals and companions, and retains files created afterward. It is recovery of originals, not an exact deletion-based rollback. Checkpoint/recovery preserves the in-memory Capture draft without committing or clearing it. Finish or cancel extraction before checkpoint/recovery and avoid competing external writes. Multi-file recovery is not atomic across devices; retained checkpoints allow retry after interruption. History consumes disk space and is not automatically pruned.

## Verification

`swift test` runs the storage and search regression suites when full Xcode supplies XCTest. This development machine has Command Line Tools only, so the XCTest suites were not executed here.

Temporary executable smoke runs exercised actual Vision OCR on English/Indonesian images; selectable/mixed/scanned/corrupt PDF handling; original-byte preservation; portable reconstruction; Unicode highlights; stale/deleted originals; companion edits; symlinks; and cancellation. Native AppKit smoke runs exercised search typing, manual processing, visible highlights/page references, opening originals and notes, autosave/reindexing, quick capture, checkpoint/recovery, and compact layout. Android API 35 capture was exercised through the real folder picker and sharing UI after the cutover.

Focused-mode native smoke runs additionally exercised deferred Find loading, recent-source ordering, capture text/attachment/undo preservation across modes, read-only note opening and explicit editing, query/scroll restoration, external-edit conflict copies, unavailable/restored originals, background extraction while capturing, checkpoint recovery with an unsaved draft, lifecycle saves without duplicate captures, and both screens at the actual 760-point minimum width.

Notebook-redesign smoke runs exercised light/dark Capture, Find, note reading, and quick capture; real OCR/PDF/text matches; attachment previews/removal/overflow scrolling; draft/undo preservation; autosave; and actual 760×540 workspace layouts. The accented action retained the native accessible button role and press action, committed one capture through that action, and preserved Command–Return activation in quick capture. This was not a full VoiceOver audit.

A separate smoke process denied all network access and still performed actual Indonesian screenshot OCR, selectable-PDF extraction, and search with the correct PDF page reference.

General agent actions, LLM services, paid AI features, automatic background extraction, scanned-PDF OCR, webpage fetching, translation/semantic search, and mobile note management are outside this iteration.
