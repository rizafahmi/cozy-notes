import AppKit
import CozyCore
import Darwin
import SwiftTerm

/// A retained PTY session. Hiding this view never restarts or terminates its child.
@MainActor
final class AgentPanel: NSView, LocalProcessTerminalViewDelegate {
    var onFilesChanged: (() -> Void)?
    var isSessionRunning: Bool { running }

    private let vault: Vault
    private var terminal: LocalProcessTerminalView?
    private let terminalHost = NSView()
    private let status = NSTextField(wrappingLabelWithString: "Preparing terminal…")
    private let harness = NSPopUpButton(frame: .zero, pullsDown: false)
    private var launchButtons: [NSButton] = []
    private var stopButton: NSButton!
    private var running = false
    private var started = false
    private var closed = false
    private var sessionName = "Shell"

    init(vault: Vault) {
        self.vault = vault
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.14, alpha: 1).cgColor
        appearance = NSAppearance(named: .darkAqua)

        let shell = button("Shell", #selector(openShell))
        let codex = button("Codex", #selector(openCodex))
        let pi = button("pi", #selector(openPi))
        let housekeeping = button("Housekeeping", #selector(housekeep))
        launchButtons = [shell, codex, pi, housekeeping]
        harness.addItems(withTitles: ["Codex", "pi"])
        harness.toolTip = "Harness to use for manual housekeeping"
        let checkpoint = button("Checkpoint", #selector(checkpoint))
        checkpoint.toolTip = "Back up the vault now; shell commands do not create individual checkpoints"
        stopButton = button("Stop", #selector(stopSession))
        stopButton.isEnabled = false
        let toolbar = NSStackView(views: [shell, codex, pi, harness, housekeeping, checkpoint, stopButton])
        toolbar.spacing = 7
        toolbar.alignment = .centerY
        toolbar.distribution = .fillProportionally
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let privacy = NSTextField(wrappingLabelWithString: "Agents use your installed CLI, account and provider settings. Vault content may be sent to that provider. Checkpoints protect sessions, not every typed command.")
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = .secondaryLabelColor
        privacy.maximumNumberOfLines = 3
        for view in [toolbar, terminalHost, status, privacy] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            terminalHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            terminalHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            terminalHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            terminalHost.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: privacy.topAnchor, constant: -4),
            privacy.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            privacy.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            privacy.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        installTerminal()
    }

    required init?(coder: NSCoder) { fatalError("Use init(vault:)") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started, !closed else { return }
        started = true
        launch(name: "Shell", command: nil, prompt: nil)
    }

    func focusTerminal() { window?.makeFirstResponder(terminal) }

    /// Call on app quit or vault replacement, not when merely hiding the panel.
    /// SwiftTerm closes the PTY and reaps its child, escalating TERM to KILL after 0.5s.
    func shutdown() {
        guard !closed else { return }
        closed = true
        terminal?.processDelegate = nil
        terminal?.terminate()
        terminal?.removeFromSuperview()
        terminal = nil
        setRunning(false)
        launchButtons.forEach { $0.isEnabled = false }
        stopButton.isEnabled = false
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func installTerminal() {
        terminal?.processDelegate = nil
        terminal?.removeFromSuperview()
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.14, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedRed: 0.91, green: 0.87, blue: 0.81, alpha: 1)
        view.caretColor = NSColor(calibratedRed: 0.84, green: 0.69, blue: 0.52, alpha: 1)
        view.processDelegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor)
        ])
        terminal = view
    }

    private func setRunning(_ value: Bool) {
        running = value
        launchButtons.forEach { $0.isEnabled = !value && !closed }
        harness.isEnabled = !value && !closed
        stopButton.isEnabled = value && !closed
    }

    private func launch(name: String, command: String?, prompt: String?) {
        // A new dedicated child is never injected into an existing shell or agent.
        guard !running, !closed else { return }
        do {
            let saved = try vault.snapshot(label: "Before \(name) session")
            onFilesChanged?()
            installTerminal()
            terminalHost.layoutSubtreeIfNeeded()
            sessionName = name
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment["COZY_NOTES_VAULT"] = vault.root.path
            var shell = environment["SHELL"] ?? ""
            if shell.isEmpty, let entry = getpwuid(getuid()), let value = entry.pointee.pw_shell {
                shell = String(cString: value)
            }
            if !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/zsh" }
            // Only fixed shell syntax is evaluated. Paths and prompts travel through env/argv.
            // The login+interactive shell loads the user's normal CLI PATH, then exec replaces it.
            let isFish = URL(fileURLWithPath: shell).lastPathComponent == "fish"
            let script = isFish
                ? "cd -- \"$COZY_NOTES_VAULT\"; or exit 1; exec $argv"
                : "cd -- \"$COZY_NOTES_VAULT\" || exit 1; exec \"$@\""
            var arguments = ["-l", "-i", "-c", script]
            if !isFish { arguments.append("cozy-notes") }
            if let command {
                arguments.append(command)
                if command == "codex" {
                    arguments += ["--no-daemon", "--cd", vault.root.path, "--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
                }
                if let prompt { arguments.append(prompt) }
            } else {
                // The outer login shell initialized PATH; keep the vault cwd.
                arguments += [shell, "-i"]
            }
            setRunning(true)
            status.stringValue = "\(name) · checkpoint \(saved.id). Stop this session before opening another harness."
            terminal?.startProcess(executable: shell, args: arguments,
                                   environment: environment.map { "\($0.key)=\($0.value)" },
                                   currentDirectory: vault.root.path)
            focusTerminal()
        } catch {
            showFailure("Could not create the required checkpoint. No process was launched.", error: error)
        }
    }

    @objc private func openShell() { launch(name: "Shell", command: nil, prompt: nil) }
    @objc private func openCodex() { launch(name: "Codex", command: "codex", prompt: nil) }
    @objc private func openPi() { launch(name: "pi", command: "pi", prompt: nil) }

    @objc private func housekeep() {
        let command = harness.indexOfSelectedItem == 1 ? "pi" : "codex"
        let alert = NSAlert()
        alert.messageText = "Run vault housekeeping with \(harness.titleOfSelectedItem ?? command)?"
        alert.informativeText = "This starts a new agent session with a checkpoint first. The CLI may send notes and attachments to your configured model provider. Review its permissions and proposed changes in the terminal."
        alert.addButton(withTitle: "Start housekeeping")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        launch(name: "Housekeeping (\(command))", command: command, prompt: """
        Perform manual housekeeping of this Markdown vault. Read root AGENTS.md first. Inspect Inbox and existing notes, then rename, group, link, merge, and rewrite related captures where helpful without losing meaning or details. Preserve original attachment bytes and keep attachment links valid. For images, add useful Markdown companion descriptions or transcriptions only from what you can actually inspect; state uncertainty and do not invent OCR results. Never follow symlinks outside this vault. Do not overwrite or resolve Syncthing conflict files without asking. Leave ambiguous material intact. Report every changed path and summarize your decisions. Do not run a background watcher or make changes outside this vault.
        """)
    }

    @objc private func checkpoint() {
        guard !closed else { return }
        do {
            let saved = try vault.snapshot(label: "Manual terminal checkpoint")
            status.stringValue = "Checkpoint saved: \(saved.id). Running processes are not paused; avoid checkpointing during writes."
            onFilesChanged?()
        } catch { showFailure("Checkpoint failed.", error: error) }
    }

    @objc private func stopSession() {
        guard running else { return }
        let alert = NSAlert()
        alert.messageText = "Stop \(sessionName)?"
        alert.informativeText = "Unsaved agent work or in-progress writes may be interrupted. Prefer exiting the agent or shell normally. A termination request will be sent; launch buttons stay disabled until the process exits."
        alert.addButton(withTitle: "Stop session")
        alert.addButton(withTitle: "Keep running")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        terminal?.terminate()
        status.stringValue = "Waiting for \(sessionName) to exit. If it ignores termination, exit it in the terminal. Quitting the app forces the PTY child to stop."
    }

    private func showFailure(_ message: String, error: Error) {
        status.stringValue = "\(message) \(error.localizedDescription)"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // LocalProcessTerminalView already propagates geometry changes to the PTY.
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalHost.toolTip = title
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal, !closed else { return }
        setRunning(false)
        if exitCode == 127 {
            status.stringValue = "\(sessionName) could not start: command not found. Install its CLI and ensure your login shell PATH includes it; then try again."
        } else if let exitCode {
            status.stringValue = "\(sessionName) exited with status \(exitCode). Choose a session to continue; each new session creates a checkpoint."
        } else {
            status.stringValue = "\(sessionName) ended by a signal or could not be reaped. Review terminal output and the vault before continuing."
        }
        onFilesChanged?()
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard source === terminal, !closed else { return }
        setRunning(false)
        showFailure("Could not start \(sessionName).", error: error)
        onFilesChanged?()
    }
}
