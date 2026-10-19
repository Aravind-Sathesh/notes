import Cocoa
import WebKit
import UniformTypeIdentifiers

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var root: RootView!
    var tabBar: TabBarView!

    private let store = NoteStore()
    var library = Library.empty
    private var theme = Theme.dark

    /// What each file-bound note's file held when it was last opened, saved or
    /// re-read: the baseline that both "unsaved" and "changed on disk" are
    /// measured against. Not persisted; read from the files at launch.
    private var diskText: [UUID: String] = [:]

    /// The tab waiting on the save-or-discard card. Held by id, so the answer
    /// still finds it if tabs have moved in the meantime.
    private var closing: UUID?

    /// Files Finder handed over before the page could show them.
    private var pendingFiles: [URL] = []
    var pageReady = false

    /// One web view for every note. Each note's undo history and selection
    /// live in its own CodeMirror state inside the page, so they stay separate
    /// without a web view — and a web content process — per note.
    var webView: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        library = store.load()
        for note in library.notes {
            guard let path = note.filePath,
                  let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { continue }
            diskText[note.id] = text
        }
        // Coming back from another app is when a file is likeliest to have
        // been changed underneath a note.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkFilesOnDisk() }

        tabBar = TabBarView()
        tabBar.notes = library.notes
        tabBar.active = library.active
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.onClose = { [weak self] in self?.closeTab(at: $0) }
        tabBar.onNew = { [weak self] in self?.newTab() }
        tabBar.onRename = { [weak self] in self?.renameTab(at: $0, to: $1) }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            // fullSizeContentView lets the tab bar occupy the titlebar strip.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notes"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = theme.background
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: TabBarView.minimumWidth, height: TabBarView.minimumHeight)

        root = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        root.onResize = { [weak self] in self?.layoutContent() }
        root.addSubview(tabBar)
        window.contentView = root

        window.center()
        // Remembers size and position — but a check resizing its own window must
        // not rewrite the size the real app reopens at.
        if !runningACheck { window.setFrameAutosaveName("NotesWindow") }
        window.makeKeyAndOrderFront(nil)

        webView = makeWebView(handlingMessagesFor: self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        root.addSubview(webView, positioned: .below, relativeTo: tabBar)

        buildMenu()
        layoutContent()
        webView.load(URLRequest(url: pageURL))
    }

    // MARK: Layout

    private func layoutContent() {
        guard let root else { return }
        let bounds = root.bounds

        tabBar.frame = NSRect(
            x: 0,
            y: bounds.height - TabBarView.height,
            width: bounds.width,
            height: TabBarView.height
        )

        let contentTop = bounds.height - TabBarView.height
        webView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, contentTop))
        positionWindowButtons()
    }

    /// The system places the window buttons 9pt from the edge and centres them
    /// in a 28pt titlebar. Both are wrong once the titlebar is a 44pt tab strip
    /// painted the same colour as the note, so they get re-placed on every
    /// layout — the system resets them each time.
    private func positionWindowButtons() {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }

        var x = TabBarView.windowButtonLeading
        for button in buttons {
            let size = button.frame.size
            button.setFrameOrigin(NSPoint(
                x: x,
                y: container.bounds.height - (TabBarView.height - size.height) / 2 - size.height
            ))
            x += size.width + TabBarView.windowButtonGap
        }
    }

    // MARK: Notes and tabs

    func refreshTabs() {
        tabBar.notes = library.notes
        tabBar.active = library.active
        tabBar.unsaved = Set(library.notes.filter { note in
            note.filePath != nil && diskText[note.id].map { $0 != note.text } == true
        }.map(\.id))
    }

    /// Hands the active note to the page. The text is authoritative on first
    /// sight; after that the page's own state for that note takes over, which
    /// is what carries its undo history across a tab switch.
    private func showActiveNote() {
        let note = library.activeNote
        if let id = closing, id != note.id {
            closing = nil
            webView?.evaluateJavaScript("window.__notesDismissAsk()")
        }
        guard let id = jsLiteral(note.id.uuidString), let text = jsLiteral(note.text) else { return }
        let isMarkdown = ["md", "markdown"].contains(
            note.filePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        )
        webView?.evaluateJavaScript(
            "window.__notesSwitchNote(\(id), \(text)); window.__notesShowOutline(\(isMarkdown))"
        )
    }

    func select(_ index: Int) {
        guard index != library.active, library.notes.indices.contains(index) else { return }
        library.active = index
        store.save(library)
        refreshTabs()
        showActiveNote()
    }

    @objc private func newTab() {
        library.notes.append(Note())
        library.active = library.notes.count - 1
        store.save(library)
        refreshTabs()
        showActiveNote()
    }

    /// Closing is the one way to lose words here: a note never saved goes with
    /// its tab, and one bound to a file loses what was not written to it. So
    /// those ask first, in front, where you can see what is being closed.
    /// The last tab closes the window and quits, which keeps every note.
    func closeTab(at index: Int) {
        guard library.notes.indices.contains(index), closing == nil else { return }
        guard library.notes.count > 1 else {
            window.performClose(nil)
            return
        }

        let note = library.notes[index]
        let wouldLose = note.filePath == nil
            ? !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : tabBar.unsaved.contains(note.id)
        guard wouldLose, pageReady,
              let title = jsLiteral("Save changes to “\(note.title)”?"),
              let detail = jsLiteral(note.filePath.map {
                  "Closing discards the edits not saved to \(URL(fileURLWithPath: $0).lastPathComponent)."
              } ?? "This note has never been saved. Closing deletes it.") else {
            removeTab(at: index)
            return
        }
        select(index)
        closing = note.id
        webView?.evaluateJavaScript("window.__notesAskToClose(\(title), \(detail))")
    }

    func answerClose(_ choice: String) {
        guard let id = closing else { return }
        closing = nil
        webView?.evaluateJavaScript("window.__notesDismissAsk()")
        guard let index = library.notes.firstIndex(where: { $0.id == id }) else { return }
        switch choice {
        case "save":
            // Saving can fail or be cancelled; the tab stays open if it does.
            guard index == library.active, writeActiveNote() else { return }
            removeTab(at: index)
        case "discard":
            removeTab(at: index)
        default:
            break
        }
    }

    private func removeTab(at index: Int) {
        let removed = library.notes.remove(at: index)
        diskText[removed.id] = nil
        if let id = jsLiteral(removed.id.uuidString) {
            webView?.evaluateJavaScript("window.__notesDropNote(\(id))")
        }

        // Closing the active tab selects the one that slid into its place.
        if library.active > index { library.active -= 1 }
        library.repair()
        store.save(library)
        refreshTabs()
        showActiveNote()
    }

    func renameTab(at index: Int, to name: String?) {
        guard library.notes.indices.contains(index) else { return }

        // A note bound to a file is that file, so renaming it renames the file.
        // Clearing the name only changes the tab; the file keeps its name.
        if let name, let path = library.notes[index].filePath {
            let old = URL(fileURLWithPath: path)
            let new = unusedURL(
                named: name, in: old.deletingLastPathComponent(),
                extension: old.pathExtension, current: old
            )
            if new.path != old.path {
                do {
                    try FileManager.default.moveItem(at: old, to: new)
                } catch {
                    report(error, title: "Could not rename \(old.lastPathComponent)")
                    refreshTabs()
                    return
                }
                library.notes[index].filePath = new.path
                flash("renamed to \(shortPath(new))")
            }
        }

        library.notes[index].name = name
        store.save(library)
        refreshTabs()
    }

    @objc private func closeActiveTab() { closeTab(at: library.active) }

    @objc private func nextTab() { select((library.active + 1) % library.notes.count) }

    @objc private func previousTab() {
        select((library.active - 1 + library.notes.count) % library.notes.count)
    }

    // MARK: Files
    //
    // notes.json stays the live workspace — every keystroke, every open tab.
    // Cmd+S is a separate thing: it writes the note out as a plain text file
    // you own, and remembers where, so saving again overwrites that file.

    @objc func saveNote() { writeActiveNote() }

    /// True once the note is on disk.
    @discardableResult
    private func writeActiveNote() -> Bool {
        let note = library.activeNote
        let existing = note.filePath.map { URL(fileURLWithPath: $0) }

        do {
            try FileManager.default.createDirectory(
                at: saveDirectory, withIntermediateDirectories: true
            )
            if let existing, let known = diskText[note.id],
               let disk = try? String(contentsOf: existing, encoding: .utf8), disk != known {
                let alert = NSAlert()
                alert.messageText = "“\(existing.lastPathComponent)” changed on disk"
                alert.informativeText = "Saving replaces what another app wrote to it since it was opened here."
                alert.addButton(withTitle: "Overwrite")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
            let url = try existing ?? unusedSaveURL(for: note)
            try note.text.write(to: url, atomically: true, encoding: .utf8)
            diskText[note.id] = note.text
            // A check's files would otherwise land in the real app's list.
            if !runningACheck { NSDocumentController.shared.noteNewRecentDocumentURL(url) }

            library.notes[library.active].filePath = url.path
            store.save(library)
            refreshTabs()
            flash("saved to \(shortPath(url))")
            return true
        } catch {
            // Writing can fail for reasons worth seeing: no permission to the
            // Documents folder, a full disk, a file that moved.
            report(error, title: "Could not save this note")
            return false
        }
    }

    @objc private func revealSavedNote() {
        guard let path = library.activeNote.filePath else {
            flash("this note has not been saved yet")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// First non-empty line, made safe for a filename, with a numbered suffix
    /// if something is already there.
    private func unusedSaveURL(for note: Note) throws -> URL {
        let firstLine = note.name ?? note.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        return unusedURL(named: firstLine, in: saveDirectory, extension: "md")
    }

    /// `raw` made safe for a filename, with a numbered suffix if something
    /// else is already there. `current` is a file being renamed, which is
    /// never in its own way — so a case-only rename keeps its name.
    private func unusedURL(named raw: String, in directory: URL, extension ext: String, current: URL? = nil) -> URL {
        var name = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "#-*> \t"))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = "Untitled" }

        func file(_ base: String) -> URL {
            let url = directory.appendingPathComponent(base)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        func taken(_ url: URL) -> Bool {
            if let current, url.path.lowercased() == current.path.lowercased() { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }

        var candidate = file(name)
        var suffix = 2
        while taken(candidate) {
            candidate = file("\(name) \(suffix)")
            suffix += 1
        }
        return candidate
    }

    private func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }

    /// Opens a file as a note: the one already bound to it if there is one,
    /// otherwise a new tab bound to it.
    func openFile(_ url: URL) {
        if let index = library.notes.firstIndex(where: { $0.filePath == url.path }) {
            select(index)
            flash("already open: \(shortPath(url))")
            return
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let note = Note(text: text, filePath: url.path)
            library.notes.append(note)
            diskText[note.id] = text
            // A check's files would otherwise land in the real app's list.
            if !runningACheck { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            library.active = library.notes.count - 1
            store.save(library)
            refreshTabs()
            showActiveNote()
            flash("opened \(shortPath(url))")
        } catch {
            report(error, title: "Could not open \(url.lastPathComponent)")
        }
    }

    /// Re-reads every file-bound note's file. A note you have not touched
    /// follows its file; one you have edited asks, so neither side is lost.
    func checkFilesOnDisk() {
        guard pageReady else { return }
        for note in library.notes {
            guard let path = note.filePath, let known = diskText[note.id],
                  let disk = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8),
                  disk != known else { continue }
            if note.text == known {
                reload(note.id, with: disk)
                continue
            }
            let alert = NSAlert()
            alert.messageText = "“\(URL(fileURLWithPath: path).lastPathComponent)” changed on disk"
            alert.informativeText = "This note has edits that are not saved to the file."
            alert.addButton(withTitle: "Keep My Version")
            alert.addButton(withTitle: "Use the File’s Version")
            if alert.runModal() == .alertFirstButtonReturn {
                // The file's new text becomes the baseline, so this is asked
                // once, and the next save overwrites it knowingly.
                diskText[note.id] = disk
                refreshTabs()
            } else {
                reload(note.id, with: disk)
            }
        }
    }

    /// Replaces a note's text with its file's. The page's state for it is
    /// dropped rather than edited, so its undo history cannot reach back into
    /// text that is no longer there.
    private func reload(_ id: UUID, with text: String) {
        guard let index = library.notes.firstIndex(where: { $0.id == id }),
              let literal = jsLiteral(id.uuidString) else { return }
        library.notes[index].text = text
        diskText[id] = text
        webView?.evaluateJavaScript("window.__notesDropNote(\(literal))")
        if index == library.active { showActiveNote() }
        store.save(library)
        refreshTabs()
    }

    @objc private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText] + [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.directoryURL = saveDirectory
        let handle = { (response: NSApplication.ModalResponse) in
            if response == .OK { panel.urls.forEach(self.openFile) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func report(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// A save with no acknowledgement leaves you wondering whether it happened.
    private func flash(_ message: String) {
        guard let literal = jsLiteral(message) else { return }
        webView?.evaluateJavaScript("window.__notesFlash(\(literal))")
    }

    private func jsLiteral(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Find
    //
    // The bar itself lives in the page, above its status bar, so it shares the
    // page's fonts, colours and metrics. These just drive it.

    @objc private func toggleMarkdown() {
        webView?.evaluateJavaScript("document.getElementById('markdownToggle').click()")
    }

    @objc private func showFind() {
        webView?.evaluateJavaScript("window.__notesFindShow()")
    }

    @objc private func findNext() {
        webView?.evaluateJavaScript("window.__notesFindNext()")
    }

    @objc private func findPrevious() {
        webView?.evaluateJavaScript("window.__notesFindPrevious()")
    }

    @objc private func selectNextOccurrence() {
        webView?.evaluateJavaScript("window.__notesSelectOccurrence()")
    }

    @objc func selectAllText() {
        webView?.evaluateJavaScript("window.__notesSelectAll()")
    }

    // MARK: Web view

    /// Links in the markdown preview open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        showActiveNote()

        let waiting = pendingFiles
        pendingFiles = []
        waiting.forEach(openFile)
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "save":
            // The page names the note the text belongs to, rather than the app
            // assuming it is whichever tab is in front.
            guard let payload = message.body as? [String: Any],
                  let identifier = payload["id"] as? String,
                  let id = UUID(uuidString: identifier),
                  let text = payload["text"] as? String,
                  let index = library.notes.firstIndex(where: { $0.id == id }) else { return }
            library.notes[index].text = text
            store.save(library)
            refreshTabs()

        case "closeChoice":
            guard let choice = message.body as? String else { return }
            answerClose(choice)

        case "theme":
            guard let variables = message.body as? [String: String],
                  let updated = Theme(cssVariables: variables) else { return }
            theme = updated
            tabBar.theme = updated
            window.backgroundColor = updated.background
            window.appearance = NSAppearance(named: updated.isDark ? .darkAqua : .aqua)

        default:
            break
        }
    }

    /// Finder hands files over here, which can arrive before the window and
    /// page are ready, so they wait for the page to load.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard pageReady else {
            pendingFiles.append(contentsOf: urls)
            return
        }
        urls.forEach(openFile)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // The Edit menu is not decoration: without it, Cmd+C/V/A/Z do nothing in a
    // WKWebView text area.
    private func buildMenu() {
        let name = "Notes"
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Note", action: #selector(newTab), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open…", action: #selector(showOpenPanel), keyEquivalent: "o")
        let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveNote), keyEquivalent: "s")
        let reveal = fileMenu.addItem(
            withTitle: "Reveal in Finder",
            action: #selector(revealSavedNote),
            keyEquivalent: "r"
        )
        reveal.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Note", action: #selector(closeActiveTab), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // WKWebView does not implement undo:/redo:, so wiring these to the usual
        // responder-chain selectors leaves them dead and swallows Cmd+Z. These
        // drive the bridge's own per-note history instead; WebKit's native undo
        // stack is shared by every web view in the app and cannot be per tab.
        editMenu.addItem(withTitle: "Undo", action: #selector(undoEdit), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(redoEdit), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(selectAllText), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(showFind), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        let findBack = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "G")
        findBack.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(
            withTitle: "Add Selection to Next Match",
            action: #selector(selectNextOccurrence),
            keyEquivalent: "d"
        )
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let markdown = viewMenu.addItem(withTitle: "Toggle Markdown", action: #selector(toggleMarkdown), keyEquivalent: "m")
        markdown.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let next = windowMenu.addItem(withTitle: "Next Note", action: #selector(nextTab), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let previous = windowMenu.addItem(withTitle: "Previous Note", action: #selector(previousTab), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc func undoEdit() {
        webView?.evaluateJavaScript("window.__notesUndo()")
    }

    @objc func redoEdit() {
        webView?.evaluateJavaScript("window.__notesRedo()")
    }

    @objc private func actualSize() { webView?.magnification = 1 }

    @objc private func zoomIn() {
        webView.magnification = min(webView.magnification * 1.1, 3)
    }

    @objc private func zoomOut() {
        webView.magnification = max(webView.magnification / 1.1, 0.5)
    }
}

// MARK: - Open Recent
//
// The list is the system's recent documents, which also feeds the Dock menu,
// filled in each time the menu opens so it is never stale. Opening goes
// through openFile, as Finder's opens do.

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in urls {
            let item = ClosureMenuItem(url.lastPathComponent) { [weak self] in self?.openFile(url) }
            item.toolTip = url.path
            menu.addItem(item)
        }
        // An item with no action is greyed out by the menu itself.
        guard !urls.isEmpty else {
            menu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "")
            return
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) })
    }
}
