# Security Policy

Cozy Notes is a local-first application that reads and writes user files directly on disk (`Inbox/`, `Attachments/`, `Extracted Text/`, and `~/Library/Application Support/CozyNotes/History/`). Protecting user data integrity and filesystem boundaries is a top priority.

## Security Model & Guarantees

- **Zero Network Surface:** Cozy Notes makes no outbound or inbound network connections, embeds no webviews, and does not fetch remote URLs or images referenced in Markdown notes.
- **Path Traversal & Symlink Containment:**
  - `CozyCore.Vault` canonicalizes all paths with `resolvingSymlinksInPath()` and rejects any read, write, attachment copy, or snapshot operation that escapes the vault root or history root (`VaultError.unsafePath`).
  - Internal symlinks and hidden/system files are never traversed during indexing, OCR/PDF extraction, or checkpoint creation/restoration.
- **Non-Destructive Writes & Conflict Detection:**
  - Notes and extraction companions are written atomically via temporary files and atomic rename/replacement.
  - Edits to existing notes use compare-and-swap (`expectedContent`) so external changes (e.g., from Syncthing or another editor) are never silently overwritten.
  - Generated companions in `Extracted Text/` verify a cryptographic SHA-256 content signature (`<!-- cozy-extracted-text:v1 ... -->`) before updating and refuse to overwrite user-edited files or filename collisions.
  - Note deletion and note merging create a device-local recovery checkpoint before removing or moving files to Trash.
- **Untrusted Media & Document Parsing:**
  - PDF text extraction (`PDFKit`) and image OCR (`Vision`) run on a background queue using macOS system frameworks without executing embedded scripts or opening network resources.
  - Clickable links in the editor only allow safe external schemes (`http`, `https`, `mailto`) and never execute `javascript:`, `file:`, or custom shell handlers.

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security or data-loss vulnerability—such as:
- A path-traversal or symlink-escape bypass in `Vault`, `CaptureSearch`, or Android's `VaultWriter`,
- A race condition or compare-and-swap flaw that silently truncates or overwrites user files,
- Unsafe URL scheme execution or arbitrary code execution via crafted Markdown, PDF, or image files,

**Please do not open a public GitHub issue right away.** Instead:

1. Report it privately via [GitHub Private Vulnerability Reporting](https://github.com/rizafahmi/cozy-notes/security/advisories/new) on this repository, or
2. Contact the maintainer directly via the email listed on [@rizafahmi's GitHub profile](https://github.com/rizafahmi).

Include minimal reproduction steps (or a self-contained test case for `VaultTests` / `CaptureSearchTests`). We aim to acknowledge reports within 72 hours and ship a verified fix with regression coverage as quickly as possible.
