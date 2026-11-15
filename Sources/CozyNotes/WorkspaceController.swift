import AppKit
import CozyCore

@MainActor final class ExternalEditReviewBanner: NSView {
    let messageLabel = Theme.label("Modified on disk by external process", size: 11.5, color: Theme.ink)
    let reloadButton = QuietButton(title: "Reload Disk", symbol: "arrow.clockwise", target: nil, action: nil)
    let overwriteButton = QuietButton(title: "Overwrite Disk", symbol: "arrow.up.doc", target: nil, action: nil)
    let keepCopyButton = QuietButton(title: "Keep Copy", symbol: "doc.on.doc", target: nil, action: nil)
    var onReloadDisk: (() -> Void)?
    var onOverwriteDisk: (() -> Void)?
    var onKeepCopy: (() -> Void)?

    private let card = PaperSurface(cornerRadius: 8, color: Theme.accentSoft, bordered: true)
    private let icon = Theme.symbol("arrow.triangle.2.circlepath", size: 12, color: Theme.accent)
    private var exitOverlay: FeedbackOverlay?


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("External file change review banner")
        messageLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        reloadButton.tint = Theme.accent
        reloadButton.font = .systemFont(ofSize: 11, weight: .semibold)
        reloadButton.target = self
        reloadButton.action = #selector(reloadTapped)
        reloadButton.toolTip = "Load the new version from disk, preserve scroll position, and highlight changed lines"
        reloadButton.setAccessibilityLabel("Reload Disk")

        overwriteButton.font = .systemFont(ofSize: 11, weight: .medium)
        overwriteButton.target = self
        overwriteButton.action = #selector(overwriteTapped)
        overwriteButton.toolTip = "Overwrite the file on disk with your current editor text"
        overwriteButton.setAccessibilityLabel("Overwrite Disk")

        keepCopyButton.font = .systemFont(ofSize: 11, weight: .medium)
        keepCopyButton.target = self
        keepCopyButton.action = #selector(keepCopyTapped)
        keepCopyButton.toolTip = "Save your current editor text as a new note in Inbox"
        keepCopyButton.setAccessibilityLabel("Keep Copy")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = Theme.stack([icon, messageLabel, spacer, reloadButton, overwriteButton, keepCopyButton], spacing: 6)
        card.wantsLayer = true
        Theme.fill(card, in: self)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(hasLocalEdits: Bool) {
        if hasLocalEdits {
            messageLabel.stringValue = "Modified on disk while editing · Reload disk, overwrite disk, or keep a copy"
        } else {
            messageLabel.stringValue = "Modified on disk · Reload to view & highlight external changes"
        }
    }

    func setPresented(_ presented: Bool, editor: CaptureEditor, updateLayout: () -> Void) {
        guard isHidden == presented else { return }
        exitOverlay?.removeFromSuperview()
        exitOverlay = nil
        if presented {
            editor.preserveReadingPosition {
                isHidden = false
                updateLayout()
            }
            if window?.isVisible == true, let layer = card.layer {
                Theme.fade(layer, to: 1, duration: 0.16, from: 0)
            }
        } else {
            if window?.isVisible == true, let parent = superview {
                let overlay = FeedbackOverlay(frame: frame)
                let backing = PaperSurface(cornerRadius: 8, color: Theme.accentSoft, bordered: true)
                backing.frame = overlay.bounds
                backing.wantsLayer = true
                overlay.addSubview(backing)
                overlay.setAccessibilityElement(false)
                parent.addSubview(overlay, positioned: .above, relativeTo: self)
                exitOverlay = overlay
                if let layer = backing.layer {
                    Theme.fade(layer, to: 0, duration: 0.12) { [weak self, weak overlay] in
                        overlay?.removeFromSuperview()
                        if self?.exitOverlay === overlay { self?.exitOverlay = nil }
                    }
                }
            }
            editor.preserveReadingPosition {
                isHidden = true
                updateLayout()
            }
            card.layer?.removeAnimation(forKey: "feedback.opacity")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            exitOverlay?.removeFromSuperview()
            exitOverlay = nil
            card.layer?.removeAnimation(forKey: "feedback.opacity")
        }
    }

    @objc private func reloadTapped() { onReloadDisk?() }
    @objc private func overwriteTapped() { onOverwriteDisk?() }
    @objc private func keepCopyTapped() { onKeepCopy?() }
}

@MainActor final class WorkspaceController: NSWindowController, NSWindowDelegate {
    let vault: Vault
    let editor = CaptureEditor(frame: .zero)
    let searchPanel: SearchPanel
    let quickSwitcher = QuickSwitcherOverlay(frame: .zero)
    private let sidebarContainer = NSView()
    private let folioSurface = FolioPageSurface()
    private let collapsedControls = NSStackView()
    private let sealDot = PaperSurface(cornerRadius: 3.5, color: Theme.sage, bordered: false)
    private let contextLabel = Theme.label("", size: 10.5, color: Theme.muted)
    private let voiceButton = QuietButton(title: "AVENIR", symbol: "textformat", target: nil, action: nil)
    private let atmosphereButton = QuietButton(title: "OBSIDIAN", symbol: "sparkles", target: nil, action: nil)
    let pinButton = QuietButton(symbol: "pin", target: nil, action: nil)
    let outlineButton = QuietButton(symbol: "list.bullet.indent", target: nil, action: nil)
    let openInNewWindowButton = QuietButton(symbol: "rectangle.on.rectangle", target: nil, action: nil)
    let revealButton = QuietButton(symbol: "doc.viewfinder", target: nil, action: nil)
    let deleteButton = QuietButton(symbol: "trash", target: nil, action: nil)
    private let conflictSaveButton = PrimaryButton()
    let reviewBanner = ExternalEditReviewBanner(frame: .zero)
    private let headerRule = HairlineView()
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var folioLeadingConstraint: NSLayoutConstraint?
    private var folioTopConstraint: NSLayoutConstraint?
    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var ruleLeadingConstraint: NSLayoutConstraint?
    private var ruleTrailingConstraint: NSLayoutConstraint?
    private var bannerLeadingConstraint: NSLayoutConstraint?
    private var bannerTrailingConstraint: NSLayoutConstraint?
    private var bannerTopConstraint: NSLayoutConstraint?
    private var bannerHeightConstraint: NSLayoutConstraint?
    private(set) var isSidebarCollapsed = false
    private(set) var noteURL: URL? {
        didSet {
            if noteURL != oldValue {
                cachedNoteStamp = nil
                cachedNotePinned = nil
            }
        }
    }
    private var noteBaseline = "" {
        didSet {
            if !noteBaseline.isContiguousUTF8 {
                noteBaseline.makeContiguousUTF8()
            }
            let ns = noteBaseline as NSString
            noteBaselineUTF16Length = ns.length
            noteBaselineSig = CaptureEditor.sampleSignature(of: ns)
        }
    }
    private var noteBaselineUTF16Length = 0
    private var noteBaselineSig = 0
    private var cachedNoteStamp: String?
    private var cachedNotePinned: Bool?
    private(set) var noteDirty = false
    private(set) var noteConflicted = false
    private(set) var hasExternalDiskChange = false
    private var pendingExternalDiskText: String?
    private var noteAvailable = true
    private var autosave: Timer?
    private var watcher: VaultWatcher?
    private(set) var noteWindows: [NoteWindowController] = []
    private(set) var activeMergeSheet: MergeNotesSheetController?
    private(set) var activeDeleteAlert: NSAlert?
    var deleteAlertMovesToTrash = true
    var activeNoteWindowController: NoteWindowController? {
        noteWindows.first { $0.window === NSApp.keyWindow }
    }
    var onChooseFolder: (() -> Void)?
    var onOpenFolderInNewWindow: (() -> Void)?
    var onDidBecomeActive: ((WorkspaceController) -> Void)?
    var onRequestCloseWorkspace: ((WorkspaceController) -> Bool)?
    var onDidChangeTheme: ((NSAppearance?) -> Void)?

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, MMM d, yyyy · HH:mm")
        return f
    }()
    init(vault: Vault) {
        self.vault = vault
        self.searchPanel = SearchPanel(vault: vault)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cozy Notes — \(vault.root.lastPathComponent)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.representedURL = vault.root
        window.minSize = NSSize(width: 720, height: 500)
        window.backgroundColor = Theme.canvas
        if let savedAppearance = UserDefaults.standard.string(forKey: "cozyAppearance") {
            window.appearance = NSAppearance(named: savedAppearance == "dark" ? .darkAqua : .aqua)
        } else {
            window.appearance = nil
        }
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireCallbacks()
        editor.allowsVimMode = true
        editor.syncVimModePreference()
        watcher = VaultWatcher(root: vault.root) { [weak self] in self?.refresh() }
        searchPanel.refresh()
        updateEditorChrome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        let desk = PaperSurface(cornerRadius: 0, color: Theme.canvas, bordered: false)
        window?.contentView = desk
        let content = desk
        Theme.fill(searchPanel, in: sidebarContainer)

        let expandSidebar = QuietButton(symbol: "sidebar.left", target: self, action: #selector(toggleSidebar))
        expandSidebar.toolTip = "Show index sidebar (⌘\\)"
        expandSidebar.setAccessibilityLabel("Show sidebar")

        let quickNew = QuietButton(symbol: "square.and.pencil", target: self, action: #selector(newCapture))
        quickNew.tint = Theme.accent
        quickNew.toolTip = "New folio note (⌘N)"
        quickNew.setAccessibilityLabel("New note")

        collapsedControls.orientation = .horizontal
        collapsedControls.alignment = .centerY
        collapsedControls.spacing = 4
        collapsedControls.addArrangedSubview(expandSidebar)
        collapsedControls.addArrangedSubview(quickNew)
        collapsedControls.isHidden = true

        sealDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        sealDot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        contextLabel.font = Theme.monoFont(10.5, weight: .medium)
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        voiceButton.target = self
        voiceButton.action = #selector(cycleVoice)
        voiceButton.font = Theme.monoFont(10, weight: .semibold)
        voiceButton.toolTip = "Cycle writing typeface (Avenir / Charter / Iowan / Mono / Unbounded)"

        atmosphereButton.target = self
        atmosphereButton.action = #selector(cycleAtmosphere)
        atmosphereButton.font = Theme.monoFont(10, weight: .semibold)
        atmosphereButton.toolTip = "Switch journal atmosphere (Obsidian / Midnight / Neo-Acid)"
        pinButton.target = self
        pinButton.action = #selector(togglePinCurrentNote)
        pinButton.toolTip = "Pin note to top (⇧⌘P)"
        pinButton.setAccessibilityLabel("Pin note")
        outlineButton.target = self
        outlineButton.action = #selector(toggleOutline)
        outlineButton.toolTip = "Toggle Document Outline (⌥⌘\\)"
        outlineButton.setAccessibilityLabel("Toggle Document Outline")
        openInNewWindowButton.target = self
        openInNewWindowButton.action = #selector(openCurrentNoteInNewWindow)
        openInNewWindowButton.toolTip = "Open note in new window (⌥⌘O)"
        openInNewWindowButton.setAccessibilityLabel("Open note in new window")
        revealButton.target = self
        revealButton.action = #selector(revealCurrentNote)
        revealButton.toolTip = "Reveal this note in Finder"
        revealButton.setAccessibilityLabel("Reveal note in Finder")
        deleteButton.target = self
        deleteButton.action = #selector(deleteCurrentNote)
        deleteButton.toolTip = "Delete this note (⌘⌫)"
        deleteButton.setAccessibilityLabel("Delete note")

        conflictSaveButton.title = "Keep as new note"
        conflictSaveButton.target = self
        conflictSaveButton.action = #selector(resolveConflictAsNewNote)
        conflictSaveButton.isHidden = true

        reviewBanner.isHidden = true
        reviewBanner.onReloadDisk = { [weak self] in self?.reloadFromDisk() }
        reviewBanner.onOverwriteDisk = { [weak self] in self?.overwriteDiskWithCurrent() }
        reviewBanner.onKeepCopy = { [weak self] in self?.resolveConflictAsNewNote() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let editorHeader = Theme.stack([collapsedControls, sealDot, contextLabel, spacer, conflictSaveButton, voiceButton, atmosphereButton, pinButton, outlineButton, openInNewWindowButton, revealButton, deleteButton], spacing: 6)

        for view in [editorHeader, headerRule, reviewBanner, editor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            folioSurface.addSubview(view)
        }
        let headerLead = editorHeader.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let headerTrail = editorHeader.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let ruleLead = headerRule.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let ruleTrail = headerRule.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let bannerLead = reviewBanner.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let bannerTrail = reviewBanner.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let bannerTop = reviewBanner.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 0)
        let bannerHeight = reviewBanner.heightAnchor.constraint(equalToConstant: 0)
        headerLeadingConstraint = headerLead
        headerTrailingConstraint = headerTrail
        ruleLeadingConstraint = ruleLead
        ruleTrailingConstraint = ruleTrail
        bannerLeadingConstraint = bannerLead
        bannerTrailingConstraint = bannerTrail
        bannerTopConstraint = bannerTop
        bannerHeightConstraint = bannerHeight

        NSLayoutConstraint.activate([
            headerLead,
            headerTrail,
            editorHeader.topAnchor.constraint(equalTo: folioSurface.topAnchor, constant: 14),
            editorHeader.heightAnchor.constraint(equalToConstant: 30),
            ruleLead,
            ruleTrail,
            headerRule.topAnchor.constraint(equalTo: editorHeader.bottomAnchor, constant: 8),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            bannerLead,
            bannerTrail,
            bannerTop,
            bannerHeight,
            editor.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 2),
            editor.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -4),
            editor.topAnchor.constraint(equalTo: reviewBanner.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: folioSurface.bottomAnchor, constant: -2)
        ])

        quickSwitcher.isHidden = true
        for view in [sidebarContainer, folioSurface, quickSwitcher] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let widthConstraint = sidebarContainer.widthAnchor.constraint(equalToConstant: 284)
        let folioLead = folioSurface.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: 8)
        let folioTop = folioSurface.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
        sidebarWidthConstraint = widthConstraint
        folioLeadingConstraint = folioLead
        folioTopConstraint = folioTop

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            widthConstraint,
            folioLead,
            folioTop,
            folioSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            folioSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            quickSwitcher.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            quickSwitcher.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            quickSwitcher.topAnchor.constraint(equalTo: content.topAnchor),
            quickSwitcher.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func wireCallbacks() {
        editor.onChange = { [weak self] in self?.editorDidChange() }
        editor.onAttachFiles = { [weak self] urls in self?.attachFilesToCurrentNote(urls) }
        editor.onRemoveLinkedAttachment = { [weak self] item in self?.removeLinkedAttachment(item) }
        editor.onHorizontalInsetChange = { [weak self] inset in self?.syncFolioMargins(inset) }
        editor.noteRecordsProvider = { [weak self] in
            guard let self else { return [] }
            return self.searchPanel.cachedNoteRecords() ?? (try? self.vault.notes()) ?? []
        }
        editor.currentNoteURLProvider = { [weak self] in self?.noteURL }
        editor.onOpenWikiLink = { [weak self] link in self?.openWikiLink(link) }
        editor.onOpenWikiLinkInNewWindow = { [weak self] link in _ = self?.openWikiLinkInNewWindow(link) }
        editor.onClickTag = { [weak self] tag in
            guard let self else { return }
            if self.isSidebarCollapsed {
                self.toggleSidebar()
            }
            if self.searchPanel.activeTagFilter == tag {
                self.searchPanel.setTagFilter(nil)
                self.editor.status.stringValue = "Cleared #\(tag) filter."
            } else {
                self.searchPanel.setTagFilter(tag)
                self.editor.status.stringValue = "Filtered sidebar by #\(tag)."
            }
        }
        editor.onOpenCurrentNoteInNewWindow = { [weak self] in self?.openCurrentNoteInNewWindow() }
        editor.onTogglePinCurrentNote = { [weak self] in self?.togglePinCurrentNote() }
        editor.onQuickSwitcher = { [weak self] in self?.toggleQuickSwitcher() }
        editor.onOutlineVisibilityChange = { [weak self] _ in self?.updateEditorChrome() }
        quickSwitcher.onOpenNote = { [weak self] url in self?.openNote(url) }
        quickSwitcher.onOpenNoteWithQuery = { [weak self] url, query in
            self?.openNoteFromQuickSwitcher(url, query: query, inNewWindow: false)
        }
        quickSwitcher.onOpenNoteInNewWindow = { [weak self] url in _ = self?.openNoteInNewWindow(url) }
        quickSwitcher.onOpenNoteInNewWindowWithQuery = { [weak self] url, query in
            self?.openNoteFromQuickSwitcher(url, query: query, inNewWindow: true)
        }
        quickSwitcher.onTogglePinNote = { [weak self] url in self?.togglePinNoteReturningPaths(url) }
        quickSwitcher.onOpenExternal = { [weak self] url in
            if !NSWorkspace.shared.open(url) {
                self?.editor.status.stringValue = "No viewer could open \(url.lastPathComponent)."
            }
            self?.editor.focus()
        }
        quickSwitcher.onOpenAttachmentHit = { [weak self] url, query, inNewWindow, forceExternal in
            self?.openAttachmentFromQuickSwitcher(url, query: query, inNewWindow: inNewWindow, forceExternal: forceExternal)
        }
        quickSwitcher.onDismiss = { [weak self] in self?.editor.focus() }
        quickSwitcher.onShowSidebarSearch = { [weak self] in self?.showInNoteFind() }
        searchPanel.onOpenNote = { [weak self] url in self?.openNote(url) }
        searchPanel.onOpenNoteInNewWindow = { [weak self] url in _ = self?.openNoteInNewWindow(url) }
        searchPanel.onTogglePinNote = { [weak self] url in self?.togglePinNote(url) }
        searchPanel.onMergeNotes = { [weak self] urls in _ = self?.presentMergeNotesSheet(for: urls) }
        searchPanel.onNewNote = { [weak self] in self?.newCapture() }
        searchPanel.onDeleteNote = { [weak self] url in self?.confirmAndDeleteNote(url) }
        searchPanel.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        searchPanel.onToggleAppearance = { [weak self] in self?.toggleAppearance() }
        searchPanel.onSwitchAtmosphere = { [weak self] preset in self?.switchAtmosphere(preset) }
        searchPanel.onRevealFolder = { [weak self] in self?.revealFolder() }
        searchPanel.onChooseFolder = { [weak self] in self?.chooseFolder() }
        searchPanel.onOpenFolderInNewWindow = { [weak self] in self?.openFolderInNewWindow() }
        searchPanel.onShowRecovery = { [weak self] in self?.showRecovery() }
        searchPanel.onShowGlobalSearch = { [weak self] in self?.showQuickSwitcher() }
    }

    private func syncFolioMargins(_ inset: CGFloat) {
        folioSurface.marginX = max(24, inset - 22)
        let lead = inset
        if headerLeadingConstraint?.constant != lead {
            headerLeadingConstraint?.constant = lead
            headerTrailingConstraint?.constant = -inset
            ruleLeadingConstraint?.constant = inset
            ruleTrailingConstraint?.constant = -inset
            bannerLeadingConstraint?.constant = inset
            bannerTrailingConstraint?.constant = -inset
        }
    }

    @objc func toggleOutline() {
        editor.toggleOutline()
        updateEditorChrome()
    }

    @objc func toggleAppearance() {
        guard let window else { return }
        let isCurrentlyDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let nextDark = !isCurrentlyDark
        window.appearance = NSAppearance(named: nextDark ? .darkAqua : .aqua)
        UserDefaults.standard.set(nextDark ? "dark" : "light", forKey: "cozyAppearance")
        for win in noteWindows {
            win.window?.appearance = window.appearance
        }
        refreshThemeSurfaces()
        onDidChangeTheme?(window.appearance)
    }

    @objc func cycleVoice() {
        let cases = Theme.Voice.allCases
        let idx = cases.firstIndex(of: Theme.voice) ?? 0
        switchVoice(cases[(idx + 1) % cases.count])
    }

    func switchVoice(_ next: Theme.Voice) {
        Theme.voice = next
        editor.refreshTypography()
        updateEditorChrome()
        for win in noteWindows { win.refreshTypography() }
        onDidChangeTheme?(window?.appearance)
    }

    @objc func increaseFontSize() {
        Theme.fontScale += 1
        editor.refreshTypography()
        for win in noteWindows { win.refreshTypography() }
        onDidChangeTheme?(window?.appearance)
    }

    @objc func decreaseFontSize() {
        Theme.fontScale -= 1
        editor.refreshTypography()
        for win in noteWindows { win.refreshTypography() }
        onDidChangeTheme?(window?.appearance)
    }

    @objc func resetFontSize() {
        Theme.fontScale = 0
        editor.refreshTypography()
        for win in noteWindows { win.refreshTypography() }
        onDidChangeTheme?(window?.appearance)
    }

    @objc func cycleAtmosphere() {
        let cases = Theme.Atmosphere.allCases
        let idx = cases.firstIndex(of: Theme.atmosphere) ?? 0
        switchAtmosphere(cases[(idx + 1) % cases.count])
    }

    func switchAtmosphere(_ preset: Theme.Atmosphere) {
        Theme.atmosphere = preset
        refreshThemeSurfaces()
        onDidChangeTheme?(window?.appearance)
    }

    func applySharedTheme(appearance: NSAppearance?) {
        if let appearance {
            window?.appearance = appearance
            for win in noteWindows { win.window?.appearance = appearance }
        }
        refreshThemeSurfaces()
    }

    func refreshThemeSurfaces() {
        window?.backgroundColor = Theme.canvas
        editor.refreshTypography()
        updateEditorChrome()
        window?.contentView?.needsDisplay = true
        quickSwitcher.needsDisplay = true
        folioSurface.needsDisplay = true
        searchPanel.needsDisplay = true
        searchPanel.refresh()
        for win in noteWindows { win.refreshThemeSurfaces() }
    }

    @objc func toggleSidebar() {
        setSidebarCollapsed(!isSidebarCollapsed)
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        isSidebarCollapsed = collapsed
        sidebarContainer.isHidden = collapsed
        sidebarWidthConstraint?.constant = collapsed ? 0 : 284
        folioLeadingConstraint?.constant = collapsed ? 18 : 8
        folioTopConstraint?.constant = collapsed ? 32 : 16
        collapsedControls.isHidden = !collapsed
        window?.contentView?.layoutSubtreeIfNeeded()
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        if collapsed {
            editor.focus()
        }
    }
    @objc func showCapture() {
        editor.focus()
    }

    var isQuickSwitcherVisible: Bool {
        !quickSwitcher.isHidden
    }

    @objc func toggleQuickSwitcher() {
        if isQuickSwitcherVisible {
            dismissQuickSwitcher()
        } else {
            showQuickSwitcher()
        }
    }

    @objc func showQuickSwitcher() {
        _ = persistCurrent()
        editor.hideWikiAutocomplete()
        let (snap, dates) = searchPanel.freshSnapshotAndModifiedDates()
        quickSwitcher.present(snapshot: snap, modifiedDates: dates)
    }

    func dismissQuickSwitcher() {
        guard !quickSwitcher.isHidden else { return }
        quickSwitcher.dismiss()
    }

    @objc func showFind() {
        dismissQuickSwitcher()
        if isSidebarCollapsed { setSidebarCollapsed(false) }
        searchPanel.focusSidebar()
    }

    @objc func showInNoteFind() {
        dismissQuickSwitcher()
        editor.showInNoteFind()
    }

    @objc func findNextInNote() {
        editor.findNextInNote()
    }

    @objc func findPreviousInNote() {
        editor.findPreviousInNote()
    }

    func showAndFocus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focus()
    }

    func refresh() {
        cachedNotePinned = nil
        if noteURL != nil {
            refreshNoteIfClean()
        } else {
            updateEditorChrome()
        }
        searchPanel.refresh()
        editor.invalidateNoteRecordsCache()
        for win in noteWindows {
            win.invalidatePinnedState()
            win.refreshNoteIfClean()
            win.editor.invalidateNoteRecordsCache()
        }
    }

    private func editorDidChange() {
        autosave?.invalidate()
        if let noteURL {
            let ns = editor.nsText
            if ns.length != noteBaselineUTF16Length {
                noteDirty = true
            } else if CaptureEditor.sampleSignature(of: ns) != noteBaselineSig {
                noteDirty = true
            } else if ns.length > 4096 && ns.length == editor.textView.cachedFullTextLength && noteBaselineSig == editor.textView.cachedFullTextSig && editor.textView.cachedFullText == noteBaseline {
                noteDirty = false
            } else {
                noteDirty = (ns as String) != noteBaseline
            }
            if editor.hasPotentialLinks || !editor.linkedAttachments.isEmpty {
                editor.linkedAttachments = vault.linkedAttachments(inNSString: ns, relativeTo: noteURL)
            }
        } else {
            noteDirty = editor.hasContent
        }
        updateEditorChrome()
        guard noteDirty, !noteConflicted, !hasExternalDiskChange else { return }
        if editor.status.stringValue != "Editing…" {
            editor.status.stringValue = "Editing…"
        }
        autosave = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.persistCurrent() }
        }
    }

    private func attachFilesToCurrentNote(_ urls: [URL]) {
        autosave?.invalidate()
        guard !noteConflicted else {
            editor.status.stringValue = "Keep conflicted edits as a new note before attaching files."
            return
        }
        do {
            if let existingURL = noteURL {
                let updated = try vault.attach(urls, to: existingURL, text: editor.text, expectedContent: noteBaseline)
                noteBaseline = updated
                noteDirty = false
                noteAvailable = true
                cachedNoteStamp = nil
                editor.text = updated
                editor.linkedAttachments = vault.linkedAttachments(in: updated, relativeTo: existingURL)
                editor.status.stringValue = "Saved"
                syncSavedNoteToCompanions(existingURL, content: updated)
            } else {
                let record = try vault.capture(text: editor.text, attachments: urls)
                let saved = try vault.read(record.url)
                noteURL = record.url
                noteBaseline = saved
                noteDirty = false
                noteConflicted = false
                noteAvailable = true
                editor.clearPendingAttachments()
                editor.text = saved
                editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: record.url)
                editor.status.stringValue = "Saved"
                searchPanel.selectNote(record.url)
            }
            updateEditorChrome()
            searchPanel.refresh()
            editor.focus()
        } catch {
            if let existingURL = noteURL, case VaultError.conflict = error {
                noteConflicted = true
                hasExternalDiskChange = true
                pendingExternalDiskText = try? vault.read(existingURL)
                editor.status.stringValue = "Changed externally · Review banner above to Reload, Overwrite, or Keep Copy."
                updateEditorChrome()
            }
            showError(error, in: window)
        }
    }

    private func removeLinkedAttachment(_ item: LinkedAttachment) {
        guard !noteConflicted else { return }
        let current = editor.text as NSString
        guard NSMaxRange(item.markdownRange) <= current.length else { return }
        var removeRange = item.markdownRange
        if removeRange.location > 0, current.character(at: removeRange.location - 1) == 10 {
            removeRange = NSRange(location: removeRange.location - 1, length: removeRange.length + 1)
        }
        editor.text = current.replacingCharacters(in: removeRange, with: "")
        if let noteURL {
            editor.linkedAttachments = vault.linkedAttachments(in: editor.text, relativeTo: noteURL)
        }
        noteDirty = editor.text != noteBaseline
        _ = persistCurrent()
    }

    @discardableResult func persistCurrent() -> Bool {
        autosave?.invalidate()
        if let existingURL = noteURL {
            guard noteDirty else { return true }
            guard !noteConflicted, !hasExternalDiskChange else { return false }
            do {
                var savedText = editor.text
                savedText.makeContiguousUTF8()
                try vault.save(savedText, to: existingURL, expectedContent: noteBaseline)
                noteBaseline = savedText
                editor.cacheFullText(savedText)
                noteDirty = false
                cachedNoteStamp = nil
                editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: existingURL)
                editor.status.stringValue = "Saved"
                syncSavedNoteToCompanions(existingURL, content: noteBaseline)
                updateEditorChrome()
                searchPanel.refresh()
                return true
            } catch {
                noteConflicted = true
                hasExternalDiskChange = true
                pendingExternalDiskText = try? vault.read(existingURL)
                editor.status.stringValue = "Changed externally · Review banner above to Reload, Overwrite, or Keep Copy."
                updateEditorChrome()
                return false
            }
        } else {
            guard editor.hasContent else { return true }
            let pending = editor.attachments
            do {
                let record = try vault.capture(text: editor.text, attachments: pending)
                let saved = try vault.read(record.url)
                noteURL = record.url
                noteBaseline = saved
                noteDirty = false
                noteConflicted = false
                hasExternalDiskChange = false
                pendingExternalDiskText = nil
                noteAvailable = true
                editor.clearPendingAttachments()
                if !pending.isEmpty {
                    editor.text = saved
                }
                editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: record.url)
                editor.status.stringValue = "Saved"
                updateEditorChrome()
                searchPanel.selectNote(record.url)
                searchPanel.refresh()
                return true
            } catch {
                showError(error, in: window)
                return false
            }
        }
    }

    @objc func saveCurrent() {
        if noteConflicted {
            resolveConflictAsNewNote()
        } else {
            _ = persistCurrent()
            editor.focus()
        }
    }

    @objc func reloadFromDisk() {
        autosave?.invalidate()
        guard let existingURL = noteURL else { return }
        do {
            let diskText = try vault.read(existingURL)
            let previousBaseline = noteBaseline
            let changedCount = editor.applyExternalReload(diskText, previousText: previousBaseline, highlightChanges: true)
            noteBaseline = diskText
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            cachedNoteStamp = nil
            editor.linkedAttachments = vault.linkedAttachments(in: diskText, relativeTo: existingURL)
            editor.status.stringValue = changedCount > 0
                ? "Reloaded from disk · \(changedCount) changed \(changedCount == 1 ? "section" : "sections") highlighted"
                : "Reloaded from disk"
            syncSavedNoteToCompanions(existingURL, content: diskText)
            updateEditorChrome()
            searchPanel.refresh()
            editor.focus()
        } catch {
            showError(error, in: window)
        }
    }

    @objc func overwriteDiskWithCurrent() {
        autosave?.invalidate()
        guard let existingURL = noteURL else { return }
        do {
            var savedText = editor.text
            savedText.makeContiguousUTF8()
            let expected = pendingExternalDiskText ?? noteBaseline
            try vault.save(savedText, to: existingURL, expectedContent: expected)
            noteBaseline = savedText
            editor.cacheFullText(savedText)
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            cachedNoteStamp = nil
            editor.clearExternalChangeHighlights()
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: existingURL)
            editor.status.stringValue = "Overwrote disk with current editor version"
            syncSavedNoteToCompanions(existingURL, content: savedText)
            updateEditorChrome()
            searchPanel.refresh()
            editor.focus()
        } catch VaultError.conflict {
            pendingExternalDiskText = try? vault.read(existingURL)
            hasExternalDiskChange = true
            noteConflicted = true
            editor.status.stringValue = "Disk changed again since banner appeared · Review updated file before overwriting."
            updateEditorChrome()
        } catch {
            showError(error, in: window)
        }
    }

    @objc func resolveConflictAsNewNote() {
        autosave?.invalidate()
        do {
            let note = try vault.capture(text: editor.text, attachments: editor.attachments)
            let saved = try vault.read(note.url)
            noteURL = note.url
            noteBaseline = saved
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            editor.clearPendingAttachments()
            editor.clearExternalChangeHighlights()
            editor.text = saved
            editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: note.url)
            editor.status.stringValue = "Kept as a new note"
            updateEditorChrome()
            searchPanel.selectNote(note.url)
            searchPanel.refresh()
            editor.focus()
        } catch { showError(error, in: window) }
    }

    @objc func newCapture() {
        guard persistCurrent() else { return }
        noteURL = nil
        noteBaseline = ""
        noteDirty = false
        noteConflicted = false
        hasExternalDiskChange = false
        pendingExternalDiskText = nil
        noteAvailable = true
        editor.reset()
        searchPanel.selectNote(nil)
        updateEditorChrome()
        editor.focus()
    }

    @objc func focusSearch() {
        showInNoteFind()
    }

    @objc func makeSearchable() {
        if isSidebarCollapsed { setSidebarCollapsed(false) }
        searchPanel.makeSearchable()
    }

    func openWikiLink(_ link: WikiLink) {
        openWikiLink(target: link.target)
    }

    func openWikiLink(target: String) {
        guard persistCurrent() else {
            searchPanel.selectNote(noteURL)
            return
        }
        do {
            let (record, created) = try vault.openOrCreateNote(matching: target)
            editor.invalidateNoteRecordsCache()
            openNote(record.url)
            if created {
                let end = editor.nsText.length
                editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                editor.enterVimInsertMode()
                editor.status.stringValue = "Created “\(record.title)”"
                searchPanel.refresh()
            }
        } catch {
            showError(error, in: window)
        }
    }

    @discardableResult
    func openWikiLinkInNewWindow(_ link: WikiLink) -> NoteWindowController? {
        openWikiLinkInNewWindow(target: link.target)
    }

    @discardableResult
    func openWikiLinkInNewWindow(target: String) -> NoteWindowController? {
        guard persistCurrent() else {
            searchPanel.selectNote(noteURL)
            return nil
        }
        do {
            let (record, created) = try vault.openOrCreateNote(matching: target)
            editor.invalidateNoteRecordsCache()
            for win in noteWindows { win.editor.invalidateNoteRecordsCache() }
            let controller = openNoteInNewWindow(record.url)
            if created, let controller {
                let end = controller.editor.nsText.length
                controller.editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                controller.editor.enterVimInsertMode()
                controller.editor.status.stringValue = "Created “\(record.title)”"
                searchPanel.refresh()
            }
            return controller
        } catch {
            showError(error, in: window)
            return nil
        }
    }

    var canOpenInNewWindow: Bool {
        noteURL != nil || searchPanel.selectedNoteURL != nil || editor.hasContent
    }

    var canPinNote: Bool {
        if isQuickSwitcherVisible {
            let row = quickSwitcher.selectedIndex >= 0 ? quickSwitcher.selectedIndex : 0
            return quickSwitcher.hits.indices.contains(row) && quickSwitcher.hits[row].source.kind == .note
        }
        return noteURL != nil || searchPanel.selectedNoteURL != nil || editor.hasContent
    }

    var targetNoteIsPinned: Bool {
        if isQuickSwitcherVisible {
            let row = quickSwitcher.selectedIndex >= 0 ? quickSwitcher.selectedIndex : 0
            guard quickSwitcher.hits.indices.contains(row), quickSwitcher.hits[row].source.kind == .note else {
                return false
            }
            return quickSwitcher.hits[row].source.isPinned
        }
        let targetURL = (searchPanel.isSidebarFocused ? searchPanel.selectedNoteURL : nil)
            ?? noteURL
            ?? searchPanel.selectedNoteURL
        guard let targetURL else { return false }
        if targetURL == noteURL, let cached = cachedNotePinned {
            return cached
        }
        return vault.isPinned(targetURL)
    }

    @objc func togglePinCurrentNote() {
        if isQuickSwitcherVisible {
            _ = quickSwitcher.togglePinSelectedNote()
            return
        }
        if noteURL == nil && editor.hasContent {
            guard persistCurrent() else { return }
        }
        let targetURL = (searchPanel.isSidebarFocused ? searchPanel.selectedNoteURL : nil)
            ?? noteURL
            ?? searchPanel.selectedNoteURL
        guard let targetURL else { return }
        _ = togglePinNote(targetURL)
    }

    @discardableResult
    func togglePinNote(_ url: URL) -> Bool {
        togglePinNoteReturningPaths(url) != nil
    }

    @discardableResult
    func togglePinNoteReturningPaths(_ url: URL) -> Set<String>? {
        do {
            let nowPinned = try vault.togglePinned(for: url)
            if noteURL == url {
                cachedNotePinned = nowPinned
                editor.status.stringValue = nowPinned ? "Pinned to top" : "Unpinned"
            } else {
                cachedNotePinned = nil
            }
            updateEditorChrome()
            for win in noteWindows {
                win.invalidatePinnedState(statusIfMatching: url, nowPinned: nowPinned)
                win.editor.invalidateNoteRecordsCache()
            }
            editor.invalidateNoteRecordsCache()
            let paths = vault.pinnedRelativePaths()
            searchPanel.applyPinnedPaths(paths)
            return paths
        } catch {
            showError(error, in: window)
            return nil
        }
    }

    @objc func openCurrentNoteInNewWindow() {
        if noteURL == nil && editor.hasContent {
            guard persistCurrent() else { return }
        }
        guard let targetURL = noteURL ?? searchPanel.selectedNoteURL else { return }
        _ = openNoteInNewWindow(targetURL)
    }

    @discardableResult
    func openNoteInNewWindow(_ url: URL) -> NoteWindowController? {
        if noteURL == url {
            guard persistCurrent() else { return nil }
        }
        if let existing = noteWindows.first(where: { $0.noteURL == url }) {
            _ = existing.persistCurrent()
            existing.showAndFocus()
            return existing
        }
        let controller = NoteWindowController(vault: vault, appearance: window?.appearance)
        controller.editor.noteRecordsProvider = { [weak self] in
            guard let self else { return [] }
            return self.searchPanel.cachedNoteRecords() ?? (try? self.vault.notes()) ?? []
        }
        if let anchor = (noteWindows.last?.window ?? window), let win = controller.window {
            let anchorFrame = anchor.frame
            let nextOrigin = NSPoint(x: anchorFrame.minX + 36, y: anchorFrame.maxY - win.frame.height - 28)
            win.setFrameOrigin(nextOrigin)
        }
        controller.onDidSaveNote = { [weak self, weak controller] savedURL, content in
            self?.handleCompanionNoteSaved(savedURL, content: content, from: controller)
        }
        controller.onOpenInMainWorkspace = { [weak self] targetURL in
            self?.openNote(targetURL)
            self?.showAndFocus()
        }
        controller.onOpenWikiLinkInNewWindow = { [weak self] link in
            _ = self?.openWikiLinkInNewWindow(link)
        }
        controller.onTogglePinNote = { [weak self] targetURL in
            _ = self?.togglePinNote(targetURL)
        }
        controller.onQuickSwitcher = { [weak self] in
            self?.showAndFocus()
            self?.showQuickSwitcher()
        }
        controller.onRequestDeleteNote = { [weak self] targetURL, hostWindow in
            self?.confirmAndDeleteNote(targetURL, in: hostWindow)
        }
        controller.onWillClose = { [weak self] closed in
            self?.noteWindows.removeAll { $0 === closed }
        }
        noteWindows.append(controller)
        if noteURL == url && !noteConflicted {
            controller.openNote(url, initialText: noteBaseline, initialLinkedAttachments: editor.linkedAttachments)
        } else {
            controller.openNote(url)
        }
        controller.showAndFocus()
        return controller
    }

    private func openNoteFromQuickSwitcher(_ url: URL, query: String, inNewWindow: Bool) {
        if inNewWindow {
            guard let controller = openNoteInNewWindow(url) else { return }
            if !query.isEmpty {
                controller.editor.revealSearchQuery(query)
            }
        } else {
            openNote(url)
            if noteURL == url, !query.isEmpty {
                editor.revealSearchQuery(query)
            }
        }
    }

    private func openAttachmentFromQuickSwitcher(_ attachmentURL: URL, query: String, inNewWindow: Bool, forceExternal: Bool) {
        if !forceExternal, let parentNoteURL = findReferencingNoteURL(for: attachmentURL) {
            if inNewWindow {
                guard let controller = openNoteInNewWindow(parentNoteURL) else { return }
                if !query.isEmpty {
                    _ = controller.editor.revealSearchQuery(query)
                }
                _ = controller.editor.revealLinkedAttachment(attachmentURL)
            } else {
                openNote(parentNoteURL)
                guard noteURL == parentNoteURL else { return }
                if !query.isEmpty {
                    _ = editor.revealSearchQuery(query)
                }
                _ = editor.revealLinkedAttachment(attachmentURL)
            }
            return
        }
        if !NSWorkspace.shared.open(attachmentURL) {
            editor.status.stringValue = "No viewer could open \(attachmentURL.lastPathComponent)."
        }
        editor.focus()
    }

    private func findReferencingNoteURL(for attachmentURL: URL) -> URL? {
        let targetStandardized = attachmentURL.standardizedFileURL
        if let activeURL = noteURL,
           editor.linkedAttachments.contains(where: { $0.url.standardizedFileURL == targetStandardized }) {
            return activeURL
        }
        let candidateURLs: [URL]
        if let cached = searchPanel.cachedNoteRecords() {
            candidateURLs = cached.map(\.url)
        } else if let notes = try? vault.notes() {
            candidateURLs = notes.map(\.url)
        } else {
            return nil
        }
        for candidateURL in candidateURLs {
            guard let text = try? vault.read(candidateURL) else { continue }
            let attachments = vault.linkedAttachments(in: text, relativeTo: candidateURL)
            if attachments.contains(where: { $0.url.standardizedFileURL == targetStandardized }) {
                return candidateURL
            }
        }
        return nil
    }

    private func syncSavedNoteToCompanions(_ url: URL, content: String) {
        for win in noteWindows where win.noteURL == url {
            win.applyExternalSave(url: url, content: content)
        }
    }

    private func handleCompanionNoteSaved(_ url: URL, content: String, from sender: NoteWindowController?) {
        if noteURL == url && !noteDirty && !noteConflicted && content != noteBaseline {
            noteBaseline = content
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            cachedNoteStamp = nil
            editor.text = content
            editor.linkedAttachments = vault.linkedAttachments(in: content, relativeTo: url)
            updateEditorChrome()
        }
        for win in noteWindows where win !== sender && win.noteURL == url {
            win.applyExternalSave(url: url, content: content)
        }
        editor.invalidateNoteRecordsCache()
        for win in noteWindows { win.editor.invalidateNoteRecordsCache() }
        searchPanel.refresh()
    }

    @discardableResult
    func persistAllWindows() -> Bool {
        guard persistCurrent() else { return false }
        for win in noteWindows {
            guard win.persistCurrent() else { return false }
        }
        return true
    }

    func openNote(_ url: URL) {
        if noteURL == url && !noteConflicted {
            editor.focus()
            return
        }
        guard persistCurrent() else {
            searchPanel.selectNote(noteURL)
            return
        }
        do {
            let text = try vault.read(url)
            noteURL = url
            noteBaseline = text
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            cachedNoteStamp = nil
            editor.clearPendingAttachments()
            editor.text = text
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: url)
            editor.status.stringValue = ""
            searchPanel.selectNote(url)
            updateEditorChrome()
            editor.focus()
        } catch { showError(error, in: window) }
    }

    func refreshNoteIfClean() {
        guard let noteURL else { return }
        do {
            let text = try vault.read(noteURL)
            if text != noteBaseline {
                if editor.text == text {
                    noteBaseline = text
                    noteDirty = false
                    noteConflicted = false
                    hasExternalDiskChange = false
                    pendingExternalDiskText = nil
                    cachedNoteStamp = nil
                } else {
                    autosave?.invalidate()
                    pendingExternalDiskText = text
                    hasExternalDiskChange = true
                    if noteDirty {
                        noteConflicted = true
                        editor.status.stringValue = "Changed externally while editing · Review banner above to Reload, Overwrite, or Keep Copy."
                    } else {
                        editor.status.stringValue = "Changed externally on disk · Click 'Reload Disk' to load & highlight changes."
                    }
                }
            } else if hasExternalDiskChange && !noteConflicted {
                hasExternalDiskChange = false
                pendingExternalDiskText = nil
            }
            if !noteAvailable { editor.status.stringValue = "" }
            noteAvailable = true
        } catch {
            noteAvailable = false
            editor.status.stringValue = "Original unavailable · Last view preserved"
        }
        updateEditorChrome()
    }

    private func updateEditorChrome() {
        let showBanner = hasExternalDiskChange || noteConflicted
        if showBanner {
            reviewBanner.configure(hasLocalEdits: noteDirty || noteConflicted)
        }
        reviewBanner.setPresented(showBanner, editor: editor) {
            bannerTopConstraint?.constant = showBanner ? 8 : 0
            bannerHeightConstraint?.constant = showBanner ? 38 : 0
        }
        if conflictSaveButton.isHidden == noteConflicted { conflictSaveButton.isHidden = !noteConflicted }
        let desiredOutlineTint = editor.isOutlineVisible ? Theme.accent : Theme.muted
        if outlineButton.tint != desiredOutlineTint { outlineButton.tint = desiredOutlineTint }
        let hideNoteActions = noteURL == nil
        if pinButton.isHidden != hideNoteActions { pinButton.isHidden = hideNoteActions }
        if openInNewWindowButton.isHidden != hideNoteActions { openInNewWindowButton.isHidden = hideNoteActions }
        if revealButton.isHidden != hideNoteActions { revealButton.isHidden = hideNoteActions }
        if deleteButton.isHidden != hideNoteActions { deleteButton.isHidden = hideNoteActions }
        let voiceBadge = Theme.voice.shortBadge
        if voiceButton.title != voiceBadge { voiceButton.title = voiceBadge }
        let atmoBadge = Theme.atmosphere.shortBadge
        if atmosphereButton.title != atmoBadge { atmosphereButton.title = atmoBadge }
        if let noteURL {
            let isPinned: Bool
            if let cached = cachedNotePinned {
                isPinned = cached
            } else {
                let resolved = vault.isPinned(noteURL)
                cachedNotePinned = resolved
                isPinned = resolved
            }
            let desiredPinSymbol = isPinned ? "pin.fill" : "pin"
            if pinButton.symbolName != desiredPinSymbol {
                pinButton.setSymbol(desiredPinSymbol)
                pinButton.toolTip = isPinned ? "Unpin note (⇧⌘P)" : "Pin note to top (⇧⌘P)"
                pinButton.setAccessibilityLabel(isPinned ? "Unpin note" : "Pin note")
            }
            let desiredPinTint = isPinned ? Theme.accent : Theme.muted
            if pinButton.tint != desiredPinTint { pinButton.tint = desiredPinTint }
            let relPath = String(noteURL.path.dropFirst(vault.root.path.count + 1))
            let stamp: String
            if let cached = cachedNoteStamp {
                stamp = cached
            } else {
                let modified = (try? noteURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let formatted = Self.headerDateFormatter.string(from: modified).uppercased()
                cachedNoteStamp = formatted
                stamp = formatted
                contextLabel.toolTip = relPath
            }
            let prefix = !relPath.hasPrefix("Inbox/") ? "\(relPath.uppercased())  ·  " : ""
            let stateSuffix: String
            if hasExternalDiskChange {
                stateSuffix = "  ·  DISK UPDATED"
            } else if noteDirty {
                stateSuffix = "  ·  UNSAVED"
            } else {
                stateSuffix = ""
            }
            let nextContext = "\(prefix)\(stamp)\(stateSuffix)"
            if contextLabel.stringValue != nextContext { contextLabel.stringValue = nextContext }
        } else {
            let stamp = Self.headerDateFormatter.string(from: Date()).uppercased()
            let nextContext = "NEW FOLIO  ·  \(stamp)"
            if contextLabel.stringValue != nextContext { contextLabel.stringValue = nextContext }
            contextLabel.toolTip = vault.root.path
        }
    }

    @objc private func revealCurrentNote() {
        guard let noteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([noteURL])
    }

    var canDeleteNote: Bool {
        noteURL != nil || searchPanel.selectedNoteURL != nil
    }

    @objc func deleteCurrentNote() {
        guard let targetURL = noteURL ?? searchPanel.selectedNoteURL else { return }
        confirmAndDeleteNote(targetURL)
    }

    func confirmAndDeleteNote(_ url: URL, in hostWindow: NSWindow? = nil, moveToTrash: Bool? = nil) {
        let alertHost = hostWindow ?? window
        let shouldMoveToTrash = moveToTrash ?? deleteAlertMovesToTrash
        guard alertHost?.attachedSheet == nil else { return }
        guard !searchPanel.isExtracting else {
            showError(NSError(domain: "CozyNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wait for extraction to finish or cancel it before deleting notes."
            ]), in: alertHost)
            return
        }
        let title: String
        if noteURL == url {
            title = Vault.extractedTitle(from: editor.text, fallbackURL: url)
        } else if let cached = searchPanel.cachedNoteRecords()?.first(where: { $0.url == url })?.title {
            title = cached
        } else if let text = try? vault.read(url) {
            title = Vault.extractedTitle(from: text, fallbackURL: url)
        } else {
            title = url.deletingPathExtension().lastPathComponent
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "This note and its attachments will be moved to the Trash. A recovery checkpoint is saved first so you can also restore it from Recovery."
        let trashBtn = alert.addButton(withTitle: "Move to Trash")
        trashBtn.hasDestructiveAction = true
        let cancelBtn = alert.addButton(withTitle: "Cancel")
        guard let alertHost else {
            _ = performDeleteNote(url, moveToTrash: shouldMoveToTrash)
            return
        }
        activeDeleteAlert = alert
        alert.beginSheetModal(for: alertHost) { [weak self, weak alert] response in
            guard let self else { return }
            if self.activeDeleteAlert === alert {
                self.activeDeleteAlert = nil
            }
            guard response == .alertFirstButtonReturn else { return }
            _ = self.performDeleteNote(url, moveToTrash: shouldMoveToTrash)
        }
        configureDeleteConfirmationAlert(alert, confirmButton: trashBtn, cancelButton: cancelBtn)
    }

    private func configureDeleteConfirmationAlert(
        _ alert: NSAlert,
        confirmButton: NSButton,
        cancelButton: NSButton
    ) {
        let applyDefaultButtonState = { [weak alert, weak confirmButton, weak cancelButton] in
            guard let alert, let confirmButton else { return }
            confirmButton.keyEquivalent = "\r"
            confirmButton.keyEquivalentModifierMask = []
            cancelButton?.keyEquivalent = "\u{1B}"
            cancelButton?.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = confirmButton.cell as? NSButtonCell
            alert.window.enableKeyEquivalentForDefaultButtonCell()
            alert.window.initialFirstResponder = confirmButton
            if alert.window.firstResponder == nil
                || alert.window.firstResponder === alert.window
                || alert.window.firstResponder === cancelButton {
                _ = alert.window.makeFirstResponder(confirmButton)
            }
        }
        applyDefaultButtonState()
        if let contentView = alert.window.contentView,
           !contentView.subviews.contains(where: { $0 is DeleteAlertShortcutView }) {
            let shortcutView = DeleteAlertShortcutView(frame: .zero)
            shortcutView.confirmButton = confirmButton
            shortcutView.cancelButton = cancelButton
            contentView.addSubview(shortcutView)
        }
        DispatchQueue.main.async {
            applyDefaultButtonState()
        }
    }

    @discardableResult
    func performDeleteNote(_ url: URL, moveToTrash: Bool = true) -> Bool {
        guard !searchPanel.isExtracting else { return false }
        let deletingActiveNote = (noteURL == url)
        if deletingActiveNote {
            autosave?.invalidate()
        }
        do {
            _ = try vault.delete(url, moveToTrash: moveToTrash)
            if deletingActiveNote {
                noteURL = nil
                noteBaseline = ""
                noteDirty = false
                noteConflicted = false
                hasExternalDiskChange = false
                pendingExternalDiskText = nil
                noteAvailable = true
                editor.reset()
                editor.status.stringValue = "Moved to Trash"
                searchPanel.selectNote(nil)
                updateEditorChrome()
                editor.focus()
            }
            let matchingCompanions = noteWindows.filter { $0.noteURL == url }
            for win in matchingCompanions {
                win.closeAfterDeletion()
                noteWindows.removeAll { $0 === win }
            }
            for win in noteWindows {
                win.editor.invalidateNoteRecordsCache()
            }
            editor.invalidateNoteRecordsCache()
            searchPanel.refresh()
            return true
        } catch {
            showError(error, in: window)
            return false
        }
    }
    var selectedNotesForMerge: [URL] {
        searchPanel.selectedNoteURLs
    }

    var canMergeNotes: Bool {
        !searchPanel.isExtracting && selectedNotesForMerge.count >= 2
    }

    @objc func mergeSelectedNotes() {
        _ = presentMergeNotesSheet(for: selectedNotesForMerge)
    }

    @discardableResult
    func presentMergeNotesSheet(
        for urls: [URL],
        in hostWindow: NSWindow? = nil,
        moveToTrash: Bool = true
    ) -> MergeNotesSheetController? {
        let alertHost = hostWindow ?? window
        guard persistAllWindows() else { return nil }
        guard !searchPanel.isExtracting else {
            showError(NSError(domain: "CozyNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wait for extraction to finish or cancel it before merging notes."
            ]), in: alertHost)
            return nil
        }
        var canonicalURLs: [URL] = []
        for url in urls where url.isFileURL {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if !canonicalURLs.contains(canonical) {
                canonicalURLs.append(canonical)
            }
        }
        guard canonicalURLs.count >= 2 else { return nil }

        var expectedContents: [URL: String] = [:]
        do {
            for url in canonicalURLs {
                expectedContents[url] = try vault.read(url)
            }
            _ = try vault.previewMerge(canonicalURLs)
        } catch {
            showError(error, in: alertHost)
            return nil
        }

        activeMergeSheet?.dismissSheet()
        let sheet = MergeNotesSheetController(
            vault: vault,
            noteURLs: canonicalURLs,
            appearance: alertHost?.appearance
        )
        sheet.onConfirmMerge = { [weak self, weak sheet] orderedURLs in
            guard let self else { return }
            if self.activeMergeSheet === sheet {
                self.activeMergeSheet = nil
            }
            _ = self.performMergeNotes(orderedURLs, expectedContents: expectedContents, moveToTrash: moveToTrash)
        }
        sheet.onCancel = { [weak self, weak sheet] in
            guard let self else { return }
            if self.activeMergeSheet === sheet {
                self.activeMergeSheet = nil
            }
        }
        activeMergeSheet = sheet
        sheet.present(in: alertHost)
        return sheet
    }

    @discardableResult
    func performMergeNotes(
        _ noteURLs: [URL],
        expectedContents: [URL: String] = [:],
        moveToTrash: Bool = true
    ) -> MergeResult? {
        guard persistAllWindows() else { return nil }
        guard !searchPanel.isExtracting else {
            showError(NSError(domain: "CozyNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wait for extraction to finish or cancel it before merging notes."
            ]), in: window)
            return nil
        }
        autosave?.invalidate()
        do {
            let result = try vault.merge(
                noteURLs,
                expectedContents: expectedContents,
                moveToTrash: moveToTrash
            )
            let removedSet = Set(result.removedNoteURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
            let removedCompanions = noteWindows.filter { win in
                guard let winURL = win.noteURL?.standardizedFileURL.resolvingSymlinksInPath() else { return false }
                return removedSet.contains(winURL)
            }
            for win in removedCompanions {
                win.closeAfterDeletion()
                noteWindows.removeAll { $0 === win }
            }

            let targetCanonical = result.targetRecord.url.standardizedFileURL.resolvingSymlinksInPath()
            let rewrittenSet = Set(result.rewrittenNoteURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
            for win in noteWindows {
                win.invalidatePinnedState()
                win.editor.invalidateNoteRecordsCache()
                guard let winURL = win.noteURL else { continue }
                let canonical = winURL.standardizedFileURL.resolvingSymlinksInPath()
                if canonical == targetCanonical {
                    win.applyExternalSave(url: winURL, content: result.mergedContent)
                } else if rewrittenSet.contains(canonical), let updatedText = try? vault.read(winURL) {
                    win.applyExternalSave(url: winURL, content: updatedText)
                }
            }

            noteURL = result.targetRecord.url
            noteBaseline = result.mergedContent
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            cachedNoteStamp = nil
            cachedNotePinned = result.targetRecord.isPinned
            editor.clearPendingAttachments()
            editor.clearExternalChangeHighlights()
            editor.text = result.mergedContent
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: result.targetRecord.url)
            editor.invalidateNoteRecordsCache()
            let mergedCount = result.removedNoteURLs.count + 1
            editor.status.stringValue = "Merged \(mergedCount) notes"
            searchPanel.applyPinnedPaths(vault.pinnedRelativePaths())
            searchPanel.selectNote(result.targetRecord.url)
            updateEditorChrome()
            searchPanel.refresh()
            editor.focus()
            return result
        } catch {
            refresh()
            showError(error, in: window)
            return nil
        }
    }

    @objc private func revealFolder() { NSWorkspace.shared.open(vault.root) }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc private func openFolderInNewWindow() { onOpenFolderInNewWindow?() }

    @objc func showRecovery() {
        guard persistAllWindows() else { return }
        guard !searchPanel.isExtracting else {
            showError(NSError(domain: "CozyNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wait for extraction to finish or cancel it before recovering files."
            ]), in: window)
            return
        }
        do {
            let snapshots = try vault.snapshots()
            let alert = NSAlert()
            alert.messageText = "Recover an earlier version"
            alert.informativeText = "Restore saved files from a checkpoint. New files and any uncommitted draft are kept. A fresh checkpoint is made before recovery."
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for snapshot in snapshots { picker.addItem(withTitle: "\(formatter.string(from: snapshot.createdAt)) — \(snapshot.label)") }
            alert.accessoryView = picker
            alert.addButton(withTitle: snapshots.isEmpty ? "No checkpoints yet" : "Restore checkpoint")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Create checkpoint")
            alert.buttons.first?.isEnabled = !snapshots.isEmpty
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn || response == .alertThirdButtonReturn else { return }
                do {
                    guard !self.searchPanel.isExtracting else {
                        throw NSError(domain: "CozyNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wait for extraction to finish before recovering files."])
                    }
                    if response == .alertThirdButtonReturn {
                        _ = try self.vault.snapshot(label: "Manual checkpoint")
                        return
                    }
                    guard snapshots.indices.contains(picker.indexOfSelectedItem) else { return }
                    try self.vault.restore(snapshotID: snapshots[picker.indexOfSelectedItem].id)
                    self.cachedNotePinned = nil
                    if let activeURL = self.noteURL, let reloaded = try? self.vault.read(activeURL) {
                        self.noteBaseline = reloaded
                        self.noteDirty = false
                        self.noteConflicted = false
                        self.hasExternalDiskChange = false
                        self.pendingExternalDiskText = nil
                        self.noteAvailable = true
                        self.editor.text = reloaded
                        self.editor.linkedAttachments = self.vault.linkedAttachments(in: reloaded, relativeTo: activeURL)
                    }
                    self.editor.invalidateNoteRecordsCache()
                    self.updateEditorChrome()
                    for win in self.noteWindows {
                        win.reloadAfterVaultRestore()
                        win.editor.invalidateNoteRecordsCache()
                    }
                    self.searchPanel.applyPinnedPaths(self.vault.pinnedRelativePaths())
                    self.searchPanel.refresh()
                    self.editor.focus()
                } catch { showError(error, in: self.window) }
            }
        } catch { showError(error, in: window) }
    }

    func shutdown() {
        autosave?.invalidate()
        if let alertWindow = activeDeleteAlert?.window {
            alertWindow.sheetParent?.endSheet(alertWindow, returnCode: .alertSecondButtonReturn)
            alertWindow.orderOut(nil)
        }
        activeDeleteAlert = nil
        activeMergeSheet?.dismissSheet()
        activeMergeSheet = nil
        for win in noteWindows {
            win.shutdown()
            win.window?.orderOut(nil)
        }
        noteWindows.removeAll()
        searchPanel.shutdown()
    }

    func syncVimModePreference() {
        editor.syncVimModePreference()
        for win in noteWindows {
            win.syncVimModePreference()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        onDidBecomeActive?(self)
    }
    func windowDidResignKey(_ notification: Notification) {
        _ = persistCurrent()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard persistAllWindows() else { return false }
        if onRequestCloseWorkspace?(self) == true {
            return true
        }
        sender.orderOut(nil)
        return false
    }
}

@MainActor final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let vault: Vault
    let editor = CaptureEditor(frame: .zero)
    private let folioSurface = FolioPageSurface()
    private let sealDot = PaperSurface(cornerRadius: 3.5, color: Theme.sage, bordered: false)
    private let contextLabel = Theme.label("", size: 10.5, color: Theme.muted)
    let pinButton = QuietButton(symbol: "pin", target: nil, action: nil)
    let outlineButton = QuietButton(symbol: "list.bullet.indent", target: nil, action: nil)
    let focusInWorkspaceButton = QuietButton(symbol: "sidebar.left", target: nil, action: nil)
    let revealButton = QuietButton(symbol: "doc.viewfinder", target: nil, action: nil)
    let deleteButton = QuietButton(symbol: "trash", target: nil, action: nil)
    private let conflictSaveButton = PrimaryButton()
    let reviewBanner = ExternalEditReviewBanner(frame: .zero)
    private let headerRule = HairlineView()
    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var ruleLeadingConstraint: NSLayoutConstraint?
    private var ruleTrailingConstraint: NSLayoutConstraint?
    private var bannerLeadingConstraint: NSLayoutConstraint?
    private var bannerTrailingConstraint: NSLayoutConstraint?
    private var bannerTopConstraint: NSLayoutConstraint?
    private var bannerHeightConstraint: NSLayoutConstraint?
    private(set) var noteURL: URL? {
        didSet {
            if noteURL != oldValue {
                cachedNoteStamp = nil
                cachedNotePinned = nil
            }
        }
    }
    private var noteBaseline = "" {
        didSet {
            if !noteBaseline.isContiguousUTF8 {
                noteBaseline.makeContiguousUTF8()
            }
            let ns = noteBaseline as NSString
            noteBaselineUTF16Length = ns.length
            noteBaselineSig = CaptureEditor.sampleSignature(of: ns)
        }
    }
    private var noteBaselineUTF16Length = 0
    private var noteBaselineSig = 0
    private var cachedNoteStamp: String?
    private var cachedNotePinned: Bool?
    private(set) var noteDirty = false
    private(set) var noteConflicted = false
    private(set) var hasExternalDiskChange = false
    private var pendingExternalDiskText: String?
    private var noteAvailable = true
    private var autosave: Timer?
    private var isClosingAfterDeletion = false

    var onDidSaveNote: ((URL, String) -> Void)?
    var onOpenInMainWorkspace: ((URL) -> Void)?
    var onOpenWikiLinkInNewWindow: ((WikiLink) -> Void)?
    var onTogglePinNote: ((URL) -> Void)?
    var onQuickSwitcher: (() -> Void)?
    var onRequestDeleteNote: ((URL, NSWindow?) -> Void)?
    var onWillClose: ((NoteWindowController) -> Void)?

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, MMM d, yyyy · HH:mm")
        return f
    }()

    init(vault: Vault, appearance: NSAppearance? = nil) {
        self.vault = vault
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cozy Notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 520, height: 420)
        window.backgroundColor = Theme.canvas
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireCallbacks()
        editor.allowsVimMode = true
        editor.syncVimModePreference()
        updateEditorChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        let desk = PaperSurface(cornerRadius: 0, color: Theme.canvas, bordered: false)
        window?.contentView = desk

        sealDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        sealDot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        contextLabel.font = Theme.monoFont(10.5, weight: .medium)
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinButton.target = self
        pinButton.action = #selector(togglePinCurrentNote)
        pinButton.toolTip = "Pin note to top (⇧⌘P)"
        pinButton.setAccessibilityLabel("Pin note")

        outlineButton.target = self
        outlineButton.action = #selector(toggleOutline)
        outlineButton.toolTip = "Toggle Document Outline (⌥⌘\\)"
        outlineButton.setAccessibilityLabel("Toggle Document Outline")

        focusInWorkspaceButton.target = self
        focusInWorkspaceButton.action = #selector(openInMainWorkspaceTapped)
        focusInWorkspaceButton.toolTip = "Focus this note in main workspace"
        focusInWorkspaceButton.setAccessibilityLabel("Focus note in main workspace")

        revealButton.target = self
        revealButton.action = #selector(revealCurrentNote)
        revealButton.toolTip = "Reveal this note in Finder"
        revealButton.setAccessibilityLabel("Reveal note in Finder")

        deleteButton.target = self
        deleteButton.action = #selector(deleteCurrentNote)
        deleteButton.toolTip = "Delete this note (⌘⌫)"
        deleteButton.setAccessibilityLabel("Delete note")

        conflictSaveButton.title = "Keep as new note"
        conflictSaveButton.target = self
        conflictSaveButton.action = #selector(resolveConflictAsNewNote)
        conflictSaveButton.isHidden = true

        reviewBanner.isHidden = true
        reviewBanner.onReloadDisk = { [weak self] in self?.reloadFromDisk() }
        reviewBanner.onOverwriteDisk = { [weak self] in self?.overwriteDiskWithCurrent() }
        reviewBanner.onKeepCopy = { [weak self] in self?.resolveConflictAsNewNote() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let editorHeader = Theme.stack([sealDot, contextLabel, spacer, conflictSaveButton, pinButton, outlineButton, focusInWorkspaceButton, revealButton, deleteButton], spacing: 6)

        for view in [editorHeader, headerRule, reviewBanner, editor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            folioSurface.addSubview(view)
        }
        let headerLead = editorHeader.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let headerTrail = editorHeader.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let ruleLead = headerRule.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let ruleTrail = headerRule.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let bannerLead = reviewBanner.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 40)
        let bannerTrail = reviewBanner.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -40)
        let bannerTop = reviewBanner.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 0)
        let bannerHeight = reviewBanner.heightAnchor.constraint(equalToConstant: 0)
        headerLeadingConstraint = headerLead
        headerTrailingConstraint = headerTrail
        ruleLeadingConstraint = ruleLead
        ruleTrailingConstraint = ruleTrail
        bannerLeadingConstraint = bannerLead
        bannerTrailingConstraint = bannerTrail
        bannerTopConstraint = bannerTop
        bannerHeightConstraint = bannerHeight

        folioSurface.translatesAutoresizingMaskIntoConstraints = false
        desk.addSubview(folioSurface)

        NSLayoutConstraint.activate([
            headerLead,
            headerTrail,
            editorHeader.topAnchor.constraint(equalTo: folioSurface.topAnchor, constant: 14),
            editorHeader.heightAnchor.constraint(equalToConstant: 30),
            ruleLead,
            ruleTrail,
            headerRule.topAnchor.constraint(equalTo: editorHeader.bottomAnchor, constant: 8),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            bannerLead,
            bannerTrail,
            bannerTop,
            bannerHeight,
            editor.leadingAnchor.constraint(equalTo: folioSurface.leadingAnchor, constant: 2),
            editor.trailingAnchor.constraint(equalTo: folioSurface.trailingAnchor, constant: -4),
            editor.topAnchor.constraint(equalTo: reviewBanner.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: folioSurface.bottomAnchor, constant: -2),
            folioSurface.leadingAnchor.constraint(equalTo: desk.leadingAnchor, constant: 18),
            folioSurface.trailingAnchor.constraint(equalTo: desk.trailingAnchor, constant: -18),
            folioSurface.topAnchor.constraint(equalTo: desk.topAnchor, constant: 32),
            folioSurface.bottomAnchor.constraint(equalTo: desk.bottomAnchor, constant: -18)
        ])
    }

    private func wireCallbacks() {
        editor.onChange = { [weak self] in self?.editorDidChange() }
        editor.onAttachFiles = { [weak self] urls in self?.attachFilesToCurrentNote(urls) }
        editor.onRemoveLinkedAttachment = { [weak self] item in self?.removeLinkedAttachment(item) }
        editor.onHorizontalInsetChange = { [weak self] inset in self?.syncFolioMargins(inset) }
        editor.noteRecordsProvider = { [weak self] in (try? self?.vault.notes()) ?? [] }
        editor.currentNoteURLProvider = { [weak self] in self?.noteURL }
        editor.onOpenWikiLink = { [weak self] link in self?.openWikiLink(link) }
        editor.onOpenWikiLinkInNewWindow = { [weak self] link in self?.onOpenWikiLinkInNewWindow?(link) }
        editor.onTogglePinCurrentNote = { [weak self] in self?.togglePinCurrentNote() }
        editor.onQuickSwitcher = { [weak self] in self?.onQuickSwitcher?() }
        editor.onOutlineVisibilityChange = { [weak self] _ in self?.updateEditorChrome() }
    }

    var isCurrentNotePinned: Bool {
        guard let noteURL else { return false }
        if let cached = cachedNotePinned { return cached }
        let pinned = vault.isPinned(noteURL)
        cachedNotePinned = pinned
        return pinned
    }

    @objc func togglePinCurrentNote() {
        guard let noteURL else { return }
        if let onTogglePinNote {
            onTogglePinNote(noteURL)
        } else {
            do {
                let nowPinned = try vault.togglePinned(for: noteURL)
                cachedNotePinned = nowPinned
                editor.status.stringValue = nowPinned ? "Pinned to top" : "Unpinned"
                editor.invalidateNoteRecordsCache()
                updateEditorChrome()
            } catch {
                showError(error, in: window)
            }
        }
    }

    func invalidatePinnedState(statusIfMatching targetURL: URL? = nil, nowPinned: Bool? = nil) {
        if let targetURL, noteURL == targetURL, let nowPinned {
            cachedNotePinned = nowPinned
            editor.status.stringValue = nowPinned ? "Pinned to top" : "Unpinned"
        } else {
            cachedNotePinned = nil
        }
        updateEditorChrome()
    }

    @objc func toggleOutline() {
        editor.toggleOutline()
        updateEditorChrome()
    }

    func syncVimModePreference() {
        editor.syncVimModePreference()
    }

    private func syncFolioMargins(_ inset: CGFloat) {
        folioSurface.marginX = max(24, inset - 22)
        let lead = inset
        if headerLeadingConstraint?.constant != lead {
            headerLeadingConstraint?.constant = lead
            headerTrailingConstraint?.constant = -inset
            ruleLeadingConstraint?.constant = inset
            ruleTrailingConstraint?.constant = -inset
            bannerLeadingConstraint?.constant = lead
            bannerTrailingConstraint?.constant = -inset
        }
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focus()
    }

    func openNote(_ url: URL, initialText: String? = nil, initialLinkedAttachments: [LinkedAttachment]? = nil) {
        if noteURL == url && !noteConflicted {
            editor.focus()
            return
        }
        guard persistCurrent() else { return }
        do {
            let text = try initialText ?? vault.read(url)
            noteURL = url
            noteBaseline = text
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            cachedNoteStamp = nil
            editor.clearPendingAttachments()
            editor.text = text
            editor.linkedAttachments = initialLinkedAttachments ?? vault.linkedAttachments(inNSString: editor.nsText, relativeTo: url)
            editor.status.stringValue = ""
            updateEditorChrome()
            editor.focus()
        } catch {
            showError(error, in: window)
        }
    }

    func openWikiLink(_ link: WikiLink) {
        openWikiLink(target: link.target)
    }

    func openWikiLink(target: String) {
        guard persistCurrent() else { return }
        do {
            let (record, created) = try vault.openOrCreateNote(matching: target)
            editor.invalidateNoteRecordsCache()
            openNote(record.url)
            if created {
                let end = editor.nsText.length
                editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                editor.enterVimInsertMode()
                editor.status.stringValue = "Created “\(record.title)”"
                onDidSaveNote?(record.url, editor.text)
            }
        } catch {
            showError(error, in: window)
        }
    }

    private func editorDidChange() {
        autosave?.invalidate()
        if let noteURL {
            let ns = editor.nsText
            if ns.length != noteBaselineUTF16Length {
                noteDirty = true
            } else if CaptureEditor.sampleSignature(of: ns) != noteBaselineSig {
                noteDirty = true
            } else if ns.length > 4096 && ns.length == editor.textView.cachedFullTextLength && noteBaselineSig == editor.textView.cachedFullTextSig && editor.textView.cachedFullText == noteBaseline {
                noteDirty = false
            } else {
                noteDirty = (ns as String) != noteBaseline
            }
            if editor.hasPotentialLinks || !editor.linkedAttachments.isEmpty {
                editor.linkedAttachments = vault.linkedAttachments(inNSString: ns, relativeTo: noteURL)
            }
        } else {
            noteDirty = editor.hasContent
        }
        updateEditorChrome()
        guard noteDirty, !noteConflicted, !hasExternalDiskChange else { return }
        if editor.status.stringValue != "Editing…" {
            editor.status.stringValue = "Editing…"
        }
        autosave = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.persistCurrent() }
        }
    }

    @discardableResult
    func persistCurrent() -> Bool {
        autosave?.invalidate()
        guard let existingURL = noteURL else { return true }
        guard noteDirty else { return true }
        guard !noteConflicted, !hasExternalDiskChange else { return false }
        do {
            var savedText = editor.text
            savedText.makeContiguousUTF8()
            try vault.save(savedText, to: existingURL, expectedContent: noteBaseline)
            noteBaseline = savedText
            editor.cacheFullText(savedText)
            noteDirty = false
            cachedNoteStamp = nil
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: existingURL)
            editor.status.stringValue = "Saved"
            updateEditorChrome()
            onDidSaveNote?(existingURL, noteBaseline)
            return true
        } catch {
            noteConflicted = true
            hasExternalDiskChange = true
            pendingExternalDiskText = try? vault.read(existingURL)
            editor.status.stringValue = "Changed externally · Review banner above to Reload, Overwrite, or Keep Copy."
            updateEditorChrome()
            return false
        }
    }

    @objc func saveCurrent() {
        if noteConflicted {
            resolveConflictAsNewNote()
        } else {
            _ = persistCurrent()
            editor.focus()
        }
    }

    @objc func reloadFromDisk() {
        autosave?.invalidate()
        guard let existingURL = noteURL else { return }
        do {
            let diskText = try vault.read(existingURL)
            let changedCount = editor.applyExternalReload(diskText, previousText: noteBaseline, highlightChanges: true)
            noteBaseline = diskText
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            cachedNoteStamp = nil
            editor.linkedAttachments = vault.linkedAttachments(in: diskText, relativeTo: existingURL)
            editor.status.stringValue = changedCount > 0
                ? "Reloaded from disk · \(changedCount) changed \(changedCount == 1 ? "section" : "sections") highlighted"
                : "Reloaded from disk"
            updateEditorChrome()
            onDidSaveNote?(existingURL, diskText)
            editor.focus()
        } catch {
            showError(error, in: window)
        }
    }

    @objc func overwriteDiskWithCurrent() {
        autosave?.invalidate()
        guard let existingURL = noteURL else { return }
        do {
            var savedText = editor.text
            savedText.makeContiguousUTF8()
            let expected = pendingExternalDiskText ?? noteBaseline
            try vault.save(savedText, to: existingURL, expectedContent: expected)
            noteBaseline = savedText
            editor.cacheFullText(savedText)
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            cachedNoteStamp = nil
            editor.clearExternalChangeHighlights()
            editor.linkedAttachments = vault.linkedAttachments(inNSString: editor.nsText, relativeTo: existingURL)
            editor.status.stringValue = "Overwrote disk with current editor version"
            updateEditorChrome()
            onDidSaveNote?(existingURL, savedText)
            editor.focus()
        } catch VaultError.conflict {
            pendingExternalDiskText = try? vault.read(existingURL)
            hasExternalDiskChange = true
            noteConflicted = true
            editor.status.stringValue = "Disk changed again since banner appeared · Review updated file before overwriting."
            updateEditorChrome()
        } catch {
            showError(error, in: window)
        }
    }

    @objc func resolveConflictAsNewNote() {
        autosave?.invalidate()
        do {
            let note = try vault.capture(text: editor.text, attachments: editor.attachments)
            let saved = try vault.read(note.url)
            noteURL = note.url
            noteBaseline = saved
            noteDirty = false
            noteConflicted = false
            hasExternalDiskChange = false
            pendingExternalDiskText = nil
            noteAvailable = true
            editor.clearPendingAttachments()
            editor.clearExternalChangeHighlights()
            editor.text = saved
            editor.linkedAttachments = vault.linkedAttachments(in: saved, relativeTo: note.url)
            editor.status.stringValue = "Kept as a new note"
            updateEditorChrome()
            onDidSaveNote?(note.url, saved)
            editor.focus()
        } catch {
            showError(error, in: window)
        }
    }

    private func attachFilesToCurrentNote(_ urls: [URL]) {
        autosave?.invalidate()
        guard !noteConflicted, let existingURL = noteURL else {
            editor.status.stringValue = "Keep conflicted edits as a new note before attaching files."
            return
        }
        do {
            let updated = try vault.attach(urls, to: existingURL, text: editor.text, expectedContent: noteBaseline)
            noteBaseline = updated
            noteDirty = false
            noteAvailable = true
            cachedNoteStamp = nil
            editor.text = updated
            editor.linkedAttachments = vault.linkedAttachments(in: updated, relativeTo: existingURL)
            editor.status.stringValue = "Saved"
            updateEditorChrome()
            onDidSaveNote?(existingURL, updated)
            editor.focus()
        } catch {
            if case VaultError.conflict = error {
                noteConflicted = true
                hasExternalDiskChange = true
                pendingExternalDiskText = try? vault.read(existingURL)
                editor.status.stringValue = "Changed externally · Review banner above to Reload, Overwrite, or Keep Copy."
                updateEditorChrome()
            }
            showError(error, in: window)
        }
    }

    private func removeLinkedAttachment(_ item: LinkedAttachment) {
        guard !noteConflicted else { return }
        let current = editor.text as NSString
        guard NSMaxRange(item.markdownRange) <= current.length else { return }
        var removeRange = item.markdownRange
        if removeRange.location > 0, current.character(at: removeRange.location - 1) == 10 {
            removeRange = NSRange(location: removeRange.location - 1, length: removeRange.length + 1)
        }
        editor.text = current.replacingCharacters(in: removeRange, with: "")
        if let noteURL {
            editor.linkedAttachments = vault.linkedAttachments(in: editor.text, relativeTo: noteURL)
        }
        noteDirty = editor.text != noteBaseline
        _ = persistCurrent()
    }

    func applyExternalSave(url: URL, content: String) {
        guard noteURL == url, !noteDirty, !noteConflicted, content != noteBaseline else { return }
        noteBaseline = content
        hasExternalDiskChange = false
        pendingExternalDiskText = nil
        cachedNoteStamp = nil
        noteAvailable = true
        editor.text = content
        editor.linkedAttachments = vault.linkedAttachments(in: content, relativeTo: url)
        updateEditorChrome()
    }

    func refreshNoteIfClean() {
        guard let noteURL else { return }
        do {
            let text = try vault.read(noteURL)
            if text != noteBaseline {
                if editor.text == text {
                    noteBaseline = text
                    noteDirty = false
                    noteConflicted = false
                    hasExternalDiskChange = false
                    pendingExternalDiskText = nil
                    cachedNoteStamp = nil
                } else {
                    autosave?.invalidate()
                    pendingExternalDiskText = text
                    hasExternalDiskChange = true
                    if noteDirty {
                        noteConflicted = true
                        editor.status.stringValue = "Changed externally while editing · Review banner above to Reload, Overwrite, or Keep Copy."
                    } else {
                        editor.status.stringValue = "Changed externally on disk · Click 'Reload Disk' to load & highlight changes."
                    }
                }
            } else if hasExternalDiskChange && !noteConflicted {
                hasExternalDiskChange = false
                pendingExternalDiskText = nil
            }
            if !noteAvailable { editor.status.stringValue = "" }
            noteAvailable = true
        } catch {
            noteAvailable = false
            editor.status.stringValue = "Original unavailable · Last view preserved"
        }
        updateEditorChrome()
    }

    func reloadAfterVaultRestore() {
        guard let activeURL = noteURL, let reloaded = try? vault.read(activeURL) else { return }
        noteBaseline = reloaded
        noteDirty = false
        noteConflicted = false
        hasExternalDiskChange = false
        pendingExternalDiskText = nil
        noteAvailable = true
        cachedNoteStamp = nil
        cachedNotePinned = nil
        editor.text = reloaded
        editor.linkedAttachments = vault.linkedAttachments(in: reloaded, relativeTo: activeURL)
        updateEditorChrome()
    }

    func refreshTypography() {
        editor.refreshTypography()
        updateEditorChrome()
    }

    func refreshThemeSurfaces() {
        window?.backgroundColor = Theme.canvas
        editor.refreshTypography()
        updateEditorChrome()
        window?.contentView?.needsDisplay = true
        folioSurface.needsDisplay = true
    }

    private func updateEditorChrome() {
        let showBanner = hasExternalDiskChange || noteConflicted
        if showBanner {
            reviewBanner.configure(hasLocalEdits: noteDirty || noteConflicted)
        }
        reviewBanner.setPresented(showBanner, editor: editor) {
            bannerTopConstraint?.constant = showBanner ? 8 : 0
            bannerHeightConstraint?.constant = showBanner ? 38 : 0
        }
        if conflictSaveButton.isHidden == noteConflicted { conflictSaveButton.isHidden = !noteConflicted }
        let desiredOutlineTint = editor.isOutlineVisible ? Theme.accent : Theme.muted
        if outlineButton.tint != desiredOutlineTint { outlineButton.tint = desiredOutlineTint }
        let hideNoteActions = noteURL == nil
        if pinButton.isHidden != hideNoteActions { pinButton.isHidden = hideNoteActions }
        if focusInWorkspaceButton.isHidden != hideNoteActions { focusInWorkspaceButton.isHidden = hideNoteActions }
        if revealButton.isHidden != hideNoteActions { revealButton.isHidden = hideNoteActions }
        if deleteButton.isHidden != hideNoteActions { deleteButton.isHidden = hideNoteActions }
        if let noteURL {
            let isPinned: Bool
            if let cached = cachedNotePinned {
                isPinned = cached
            } else {
                let resolved = vault.isPinned(noteURL)
                cachedNotePinned = resolved
                isPinned = resolved
            }
            let desiredPinSymbol = isPinned ? "pin.fill" : "pin"
            if pinButton.symbolName != desiredPinSymbol {
                pinButton.setSymbol(desiredPinSymbol)
                pinButton.toolTip = isPinned ? "Unpin note (⇧⌘P)" : "Pin note to top (⇧⌘P)"
                pinButton.setAccessibilityLabel(isPinned ? "Unpin note" : "Pin note")
            }
            let desiredPinTint = isPinned ? Theme.accent : Theme.muted
            if pinButton.tint != desiredPinTint { pinButton.tint = desiredPinTint }
            let relPath = String(noteURL.path.dropFirst(vault.root.path.count + 1))
            let stamp: String
            if let cached = cachedNoteStamp {
                stamp = cached
            } else {
                let modified = (try? noteURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let formatted = Self.headerDateFormatter.string(from: modified).uppercased()
                cachedNoteStamp = formatted
                stamp = formatted
                contextLabel.toolTip = relPath
            }
            let prefix = !relPath.hasPrefix("Inbox/") ? "\(relPath.uppercased())  ·  " : ""
            let stateSuffix: String
            if hasExternalDiskChange {
                stateSuffix = "  ·  DISK UPDATED"
            } else if noteDirty {
                stateSuffix = "  ·  UNSAVED"
            } else {
                stateSuffix = ""
            }
            let nextContext = "\(prefix)\(stamp)\(stateSuffix)"
            if contextLabel.stringValue != nextContext { contextLabel.stringValue = nextContext }
            window?.representedURL = noteURL
            let ns = editor.nsText
            let headLen = min(ns.length, 512)
            let head = headLen > 0 ? ns.substring(with: NSRange(location: 0, length: headLen)) : ""
            let title = Vault.extractedTitle(from: head, fallbackURL: noteURL)
            if window?.title != title {
                window?.title = title
            }
        } else {
            contextLabel.stringValue = "COMPARISON FOLIO"
            window?.representedURL = vault.root
            window?.title = "Cozy Notes"
        }
    }

    @objc private func openInMainWorkspaceTapped() {
        guard let noteURL, persistCurrent() else { return }
        onOpenInMainWorkspace?(noteURL)
    }

    @objc private func revealCurrentNote() {
        guard let noteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([noteURL])
    }

    @objc func deleteCurrentNote() {
        guard let noteURL else { return }
        onRequestDeleteNote?(noteURL, window)
    }

    @objc func showInNoteFind() {
        editor.showInNoteFind()
    }

    @objc func findNextInNote() {
        editor.findNextInNote()
    }

    @objc func findPreviousInNote() {
        editor.findPreviousInNote()
    }

    func closeAfterDeletion() {
        isClosingAfterDeletion = true
        autosave?.invalidate()
        window?.close()
    }

    func shutdown() {
        isClosingAfterDeletion = true
        autosave?.invalidate()
    }

    func windowDidResignKey(_ notification: Notification) {
        _ = persistCurrent()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingAfterDeletion { return true }
        return persistCurrent()
    }

    func windowWillClose(_ notification: Notification) {
        autosave?.invalidate()
        onWillClose?(self)
    }
}

@MainActor
private final class DeleteAlertShortcutView: NSView {
    weak var confirmButton: NSButton?
    weak var cancelButton: NSButton?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76) && (flags.isEmpty || flags == .command) {
            if flags.isEmpty,
               let cancelButton,
               window?.firstResponder === cancelButton,
               cancelButton.isEnabled {
                cancelButton.performClick(nil)
                return true
            }
            if let confirmButton, confirmButton.isEnabled {
                confirmButton.performClick(nil)
                return true
            }
        }
        if event.keyCode == 53 && flags.isEmpty {
            if let cancelButton, cancelButton.isEnabled {
                cancelButton.performClick(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

