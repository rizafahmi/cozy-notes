# Cozy Notes

A native, notes-first macOS workspace and a small Android capture companion. Capture text, links, files, and screenshots without choosing a title or maintaining folders. Open the tucked-away terminal to work with your installed Codex or pi. Syncthing connects the local folders; Cozy Notes has no account, database, sync server, or built-in AI service.

## macOS

Requires macOS 14+ and a Swift 6.2+ toolchain (`xcode-select --install`, or Xcode). The pinned SwiftTerm dependency requires Swift 6.2; the app uses Swift 5 language mode. SwiftPM fetches dependencies on the first build.

```sh
scripts/build-macos.sh debug
open '.build-app/Cozy Notes.app'
```

Use `scripts/build-macos.sh release` for an optimized build. Builds are locally ad-hoc signed, not notarized for distribution.

The app initially uses `~/Documents/Cozy Notes`. **Change…** selects another folder; **Open folder** opens it in Finder. To launch with an explicit collection:

```sh
open '.build-app/Cozy Notes.app' --args --vault '/path/to/notes'
```

The folder preference is device-local. `COZY_VAULT` also overrides it. No existing `AGENTS.md` is replaced.

### Capture and editing

- **Command–Shift–Space:** global quick-capture panel; no Accessibility permission required. Shortcut conflicts are reported.
- **Command–Return:** keep the current capture or save an edited note.
- **Command–N:** new capture. An existing draft is kept before switching notes.
- **Command–J:** show/hide the terminal without restarting its session.
- Paste an image, drop files, or use **Attach…** in a new capture.
- **Escape** tucks away quick capture without clearing its draft. Saving closes it and returns focus to the previous application.
- Existing Markdown notes autosave after editing. A detected external edit is never silently replaced: keep the local edits as a new capture instead.
- Incoming and reorganized notes are discovered through filesystem events. Existing-note editing is text-only; capture new attachments as new notes.

## Android

Requires Android 8+ on the device, JDK 17, Android SDK platform 35 and build-tools 35.0.0. The Gradle 8.11.1 wrapper is included with a pinned distribution checksum. Install prerequisites through Android Studio/SDK Manager, accept the SDK licenses, and set `JAVA_HOME` and `ANDROID_HOME` (or an ignored `android/local.properties` with `sdk.dir=...`).

```sh
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

For this development environment, project-local, ignored tools were downloaded into `android/.tools/`; SDK licenses were accepted with explicit permission:

```sh
cd android
export JAVA_HOME="$PWD/.tools/jdk-17.0.21+9/Contents/Home"
export ANDROID_HOME="$PWD/.tools/android-sdk"
./gradlew :app:assembleDebug
"$ANDROID_HOME/platform-tools/adb" install -r app/build/outputs/apk/debug/app-debug.apk
```

Open **Cozy Notes**, choose a writable local vault folder, and sync that folder separately using Syncthing. Android's system picker grants persisted folder access; no broad storage or network permissions are requested. Share text, a link, one screenshot, or several files from another app into Cozy Notes; optionally add context, then save. Direct text capture works by opening the app. This companion intentionally has no note browser or terminal.

Keep the app open until it reports success. Rotation retains an accepted save operation; process termination can interrupt it. If access is revoked, choose the folder again. Incomplete `.pending` files are not committed notes; failures retain your input and report cleanup problems.

## File contract and Syncthing

```text
Your notes folder/
  AGENTS.md
  Inbox/
    <UTC timestamp>-<UUID>.md
  Attachments/
    <same UUID>/
      original-name.png
```

One capture produces one UTF-8 Markdown note. Textual Markdown is preserved, with a trailing newline added on macOS if needed. Attachment-only notes get a title derived from the first filename. Original attachment bytes are copied, unsafe filename characters are sanitized, and attachment links are relative and percent-encoded. Agents may move, merge, and rewrite notes; they must update relative links when moving them. Arbitrary non-hidden Markdown subfolders remain readable by the Mac app. Internal symbolic links are not followed by storage operations.

Select the corresponding Syncthing folder on each device. There is no app-level network connection. Allow Syncthing to finish transferring attachments before housekeeping: synchronization is not a multi-file transaction. Syncthing conflict copies remain ordinary files; the agent instructions tell the agent not to overwrite or resolve them without asking.

## Agents and screenshot text

Install and authenticate **Codex** or **pi** separately. The terminal uses your login shell's PATH, a real PTY, and the vault working directory. It is not a chat mockup. Launch controls are disabled while a session runs: exit the shell/agent or use **Stop** before starting another. Hiding the terminal leaves its process alive.

**Housekeeping** starts the selected actual harness with a prompt to organize, link, merge, and rewrite notes and to inspect images and add Markdown descriptions/transcriptions. Root `AGENTS.md` provides the same portable guidance for agents launched outside the app. Image understanding depends on the selected model and the harness's image-reading tools; the app does not fake OCR or supply a model subscription. Results and file paths remain in the terminal.

**Local-first does not mean local AI.** Cloud-backed agents may send notes and images to the configured provider. Use its privacy/account settings or a local model as appropriate. Codex is launched with workspace-write sandboxing and its on-request approval policy; pi uses its installed permissions and configuration. Prompts are guidance, not a security boundary around a terminal agent.

## Recovery

Opening a terminal session, launching a harness, or pressing **Checkpoint** copies a recovery checkpoint to `~/Library/Application Support/CozyNotes/History/<vault-path-hash>/`, outside the synced folder. Recovery is device-local and tied to the collection's path; moving the collection does not migrate history automatically.

**Recovery…** restores changed/deleted original files and keeps files created after the selected checkpoint. It first checkpoints the current state. End the terminal session before recovering. This is recovery of originals, not an exact rollback of later-created files. Copies can consume disk space; history is not automatically pruned.

Checkpoints protect sessions, not every typed shell command. The app shuts down its direct PTY child when quitting or replacing a vault, but arbitrary shell commands can create detached descendants. Stop external agents and pause competing writes before recovery. Multi-file recovery is not atomic across devices; an interrupted recovery can be retried from the retained checkpoint.

## Checks

`swift test` runs storage regression tests when Xcode's XCTest framework is installed. Apple's Command Line Tools alone on the development machine do not include XCTest; the app still builds. Storage and native UI workflows were also exercised with temporary executable smoke runners, including actual shell commands and a real pi image-enrichment/retrieval session rather than model or terminal mocks.

An Android API 35 emulator exercised the real folder picker, direct text capture, link sharing, screenshot sharing with context, multi-image sharing, generic file sharing, and context/attachment retention through Activity recreation. The Mac storage layer discovered the five resulting notes and resolved their four attachment links; a real pi session enriched the phone-captured screenshot while preserving its original bytes. A denied source grant reported an error without committing an extra note. Physical-device Syncthing transport was not exercised or reconfigured; the verified boundary is the shared on-disk format.

Weekly housekeeping reminders, automatic background organization, clickable terminal results, a custom AI framework, built-in sync, and mobile note management are intentionally outside this version.
