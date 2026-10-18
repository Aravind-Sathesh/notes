import Cocoa
import WebKit
import UniformTypeIdentifiers
import ImageIO

// MARK: - Where things live

private func contentDirectory() -> URL {
    Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
}

private let pageURL = URL(string: "notes://local/notes.html")!




/// True when the store has been redirected, which only the checks do. They
/// then keep off the real app's remembered window frame and website data.
let runningACheck = ProcessInfo.processInfo.environment["NOTES_STORE"] != nil

private let storeDirectory: URL = {
    if let override = ProcessInfo.processInfo.environment["NOTES_STORE"] {
        let directory = URL(fileURLWithPath: override, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Notes", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}()

/// Cmd+S writes here. A check redirects it alongside its store rather than
/// scattering files through a real Documents folder.
let saveDirectory: URL = {
    if runningACheck { return storeDirectory.appendingPathComponent("Saved", isDirectory: true) }
    return FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Notes", isDirectory: true)
}()

// MARK: - Notes
//
// WebKit flushes localStorage on its own unpredictable cadence, so the app
// keeps the authoritative copy and treats the page's localStorage as a cache.

struct Note: Codable {
    var id = UUID()
    var text = ""
    /// Where Cmd+S last wrote this note, so saving again overwrites that file
    /// instead of making another one. Optional and decoded when present, so a
    /// library written before saving existed still loads.
    var filePath: String?
    /// Set by renaming the tab. Optional for the same reason as `filePath`.
    var name: String?

    /// A rename wins; otherwise the tab names itself from the first line,
    /// without the markdown markers (`# `, `- `, `> `) in front of it.
    var title: String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let bare = firstLine?.trimmingCharacters(in: CharacterSet(charactersIn: "#-*> \t"))
        guard let line = name ?? bare, !line.isEmpty else {
            return "Untitled"
        }
        return line.count > 28 ? String(line.prefix(28)) + "…" : line
    }
}

struct Library: Codable {
    var notes: [Note]
    var active: Int

    static let empty = Library(notes: [Note()], active: 0)

    /// Keeps the invariant the rest of the app relies on: at least one note,
    /// and `active` actually pointing at one.
    mutating func repair() {
        if notes.isEmpty { notes = [Note()] }
        active = min(max(active, 0), notes.count - 1)
    }

    var activeNote: Note { notes[active] }
}

/// Coalesces the keystroke-rate stream of edits into atomic writes, and can be
/// forced to land immediately when the app is going away.
final class NoteStore {
    private let fileURL = storeDirectory.appendingPathComponent("notes.json")
    private let legacyURL = storeDirectory.appendingPathComponent("notes.txt")

    private var pending: Library?
    private var timer: Timer?

    func load() -> Library {
        if let data = try? Data(contentsOf: fileURL),
           var library = try? JSONDecoder().decode(Library.self, from: data) {
            library.repair()
            return library
        }
        // Single-note store from before tabs existed.
        if let text = try? String(contentsOf: legacyURL, encoding: .utf8) {
            return Library(notes: [Note(text: text)], active: 0)
        }
        return .empty
    }

    func save(_ library: Library) {
        pending = library
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        guard let library = pending, let data = try? JSONEncoder().encode(library) else { return }
        pending = nil
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Theme
//
// Mirrors the page's CSS variables so the titlebar and tab bar are the same
// surface as the note, in either theme.

struct Theme {
    var background: NSColor
    var foreground: NSColor
    var dim: NSColor
    var border: NSColor

    static let dark = Theme(
        background: color(fromCSSHex: "#101010")!,
        foreground: color(fromCSSHex: "#ededed")!,
        dim: color(fromCSSHex: "#6b6b6b")!,
        border: color(fromCSSHex: "#262626")!
    )

    static let light = Theme(
        background: color(fromCSSHex: "#f5f5f5")!,
        foreground: color(fromCSSHex: "#141414")!,
        dim: color(fromCSSHex: "#8a8a8a")!,
        border: color(fromCSSHex: "#dcdcdc")!
    )

    var isDark: Bool {
        let srgb = background.usingColorSpace(.sRGB) ?? background
        return 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent < 0.5
    }

    /// Tint for the selected tab: lifted away from the page in dark mode,
    /// pressed into it in light mode, so it reads as raised either way.
    var activeTabFill: NSColor {
        let target: NSColor = isDark ? .white : .black
        return background.blended(withFraction: isDark ? 0.10 : 0.06, of: target) ?? background
    }

    init(background: NSColor, foreground: NSColor, dim: NSColor, border: NSColor) {
        self.background = background
        self.foreground = foreground
        self.dim = dim
        self.border = border
    }

    init?(cssVariables: [String: String]) {
        guard let bg = cssVariables["bg"].flatMap(color(fromCSSHex:)),
              let fg = cssVariables["fg"].flatMap(color(fromCSSHex:)),
              let dim = cssVariables["dim"].flatMap(color(fromCSSHex:)),
              let border = cssVariables["border"].flatMap(color(fromCSSHex:)) else { return nil }
        self.init(background: bg, foreground: fg, dim: dim, border: border)
    }
}

func color(fromCSSHex hex: String) -> NSColor? {
    var digits = hex.trimmingCharacters(in: .whitespaces)
    guard digits.hasPrefix("#") else { return nil }
    digits.removeFirst()
    if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: 1
    )
}

// MARK: - Tab bar
//
// Lives in the titlebar strip beside the window buttons, which is otherwise
// dead space. Drawn rather than assembled from controls: a tab is a rounded
// rect, a label and a close glyph, and hit testing the same rects is less code
// than keeping a tree of subviews in sync with the note list.

final class TabBarView: NSView {
    /// Height of the whole strip. Also what the window buttons are centred in.
    static let height: CGFloat = 44
    /// Left edge of the close button. The system default is 9pt, which the page
    /// makes look cramped now that the titlebar is the same colour as the note.
    static let windowButtonLeading: CGFloat = 20
    /// Native spacing between the window buttons, preserved when they move.
    static let windowButtonGap: CGFloat = 9

    /// Fixed: tabs keep their width and the strip scrolls once they overflow,
    /// rather than every tab getting narrower as notes are added.
    static let tabWidth: CGFloat = 196
    static let newTabSide: CGFloat = 26
    /// Gap between the scrolling strip and the pinned new-tab button, and that
    /// button's inset from the trailing edge.
    static let stripToNewTabGap: CGFloat = 6
    static let newTabTrailing: CGFloat = 14

    private let tabHeight: CGFloat = 30
    private let tabCorner: CGFloat = 4
    private let tabGap: CGFloat = 4
    private let closeSide: CGFloat = 18

    /// Clears the window buttons: leading inset + three 14pt buttons + gaps.
    static let tabsLeading: CGFloat =
        windowButtonLeading + 3 * 14 + 2 * windowButtonGap + 22

    /// The narrowest the window can usefully be: room to clear the window
    /// buttons, show one whole tab, and still reach the new-tab button. Built
    /// from the same constants the strip lays itself out with, so the two
    /// cannot drift apart. Tabs keep their width and scroll, so this is a
    /// floor rather than a squeeze point.
    static let minimumWidth: CGFloat =
        tabsLeading + tabWidth + stripToNewTabGap + newTabSide + newTabTrailing

    /// Tab strip, find bar, status bar and a usable amount of the note.
    static let minimumHeight: CGFloat = height + 34 + 29 + 130

    var notes: [Note] = [] {
        didSet {
            clampScroll()
            needsDisplay = true
        }
    }

    var active = 0 {
        didSet {
            revealTab(active)
            needsDisplay = true
        }
    }

    var theme = Theme.dark { didSet { needsDisplay = true } }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    /// An empty name hands the tab back to its first line.
    var onRename: ((Int, String?) -> Void)?

    private var hovered: Int?
    private var renaming: Int?
    private var renameField: NSTextField?
    private var renameSeed: String?
    private(set) var scrollOffset: CGFloat = 0

    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// The scrollable window the tabs are drawn inside: between the window
    /// buttons and the pinned new-tab button.
    var stripRegion: NSRect {
        let left = TabBarView.tabsLeading
        let right = newTabRect.minX - TabBarView.stripToNewTabGap
        return NSRect(x: left, y: 0, width: max(0, right - left), height: bounds.height)
    }

    private var contentWidth: CGFloat {
        guard !notes.isEmpty else { return 0 }
        return CGFloat(notes.count) * (TabBarView.tabWidth + tabGap) - tabGap
    }

    var maxScroll: CGFloat { max(0, contentWidth - stripRegion.width) }

    func tabRect(_ index: Int) -> NSRect {
        NSRect(
            x: stripRegion.minX + CGFloat(index) * (TabBarView.tabWidth + tabGap) - scrollOffset,
            y: (bounds.height - tabHeight) / 2,
            width: TabBarView.tabWidth,
            height: tabHeight
        )
    }

    private func labelRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        let trailing = notes.count > 1 ? closeSide + 8 : 10
        return NSRect(x: tab.minX + 10, y: tab.minY, width: tab.width - 10 - trailing, height: tab.height)
    }

    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        return NSRect(
            x: tab.maxX - closeSide - 6,
            y: tab.midY - closeSide / 2,
            width: closeSide,
            height: closeSide
        )
    }

    /// Pinned to the trailing edge so it stays reachable however many notes
    /// are open.
    private var newTabRect: NSRect {
        NSRect(
            x: bounds.width - TabBarView.newTabTrailing - TabBarView.newTabSide,
            y: (bounds.height - TabBarView.newTabSide) / 2,
            width: TabBarView.newTabSide,
            height: TabBarView.newTabSide
        )
    }

    private func clampScroll() {
        scrollOffset = min(max(0, scrollOffset), maxScroll)
    }

    func revealTab(_ index: Int) {
        // Before the strip has a width there is no viewport to reveal into,
        // and scrolling against a zero-width region would leave the strip
        // scrolled off as soon as it was sized.
        guard notes.indices.contains(index), stripRegion.width > 0 else { return }
        let left = CGFloat(index) * (TabBarView.tabWidth + tabGap)
        let right = left + TabBarView.tabWidth
        if left < scrollOffset {
            scrollOffset = left
        } else if right > scrollOffset + stripRegion.width {
            scrollOffset = right - stripRegion.width
        }
        clampScroll()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampScroll()
        // Keeps the selected tab in view across a resize, and performs the
        // first real reveal once the strip finally has a width.
        revealTab(active)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        bounds.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: stripRegion).setClip()
        for index in notes.indices where tabRect(index).intersects(stripRegion) {
            drawTab(index)
        }
        NSGraphicsContext.restoreGraphicsState()

        draw(glyph: "+", in: newTabRect, color: theme.dim, size: 15, weight: .regular)

        theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    private func drawTab(_ index: Int) {
        let rect = tabRect(index)
        let isActive = index == active

        if isActive {
            theme.activeTabFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: tabCorner, yRadius: tabCorner).fill()
        } else if hovered == index {
            theme.activeTabFill.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: rect, xRadius: tabCorner, yRadius: tabCorner).fill()
        }

        let showClose = notes.count > 1
        if index != renaming {
            draw(
                glyph: notes[index].title,
                in: labelRect(index),
                color: isActive ? theme.foreground : theme.dim,
                size: 11.5,
                weight: isActive ? .medium : .regular,
                alignment: .left
            )
        }

        if showClose {
            draw(
                glyph: "×",
                in: closeRect(index),
                color: isActive ? theme.foreground : theme.dim,
                size: 14,
                weight: .regular
            )
        }
    }

    private func draw(
        glyph: String,
        in rect: NSRect,
        color: NSColor,
        size: CGFloat,
        weight: NSFont.Weight,
        alignment: NSTextAlignment = .center
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let text = glyph as NSString
        let measured = text.size(withAttributes: attributes)
        text.draw(
            in: NSRect(x: rect.minX, y: rect.midY - measured.height / 2, width: rect.width, height: measured.height),
            withAttributes: attributes
        )
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        guard maxScroll > 0 else { return }
        // The rename field is placed for the current offset; commit before it drifts.
        if renaming != nil { window?.makeFirstResponder(nil) }
        // Horizontal swipe when there is one, wheel otherwise, so a plain mouse
        // can still reach the overflow.
        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        scrollOffset -= abs(horizontal) > abs(vertical) ? horizontal : vertical
        clampScroll()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if newTabRect.contains(point) {
            onNew?()
            return
        }

        // A click anywhere else on the strip commits a rename in progress.
        let wasRenaming = renaming != nil
        if wasRenaming { window?.makeFirstResponder(nil) }

        if stripRegion.contains(point) {
            for index in notes.indices where tabRect(index).contains(point) {
                if notes.count > 1, closeRect(index).contains(point) {
                    onClose?(index)
                } else if index == active, !wasRenaming {
                    // The way Finder renames: click what is already selected.
                    beginRename(index)
                } else {
                    onSelect?(index)
                }
                return
            }
        }

        // Empty strip behaves like a titlebar: drag to move, double click to zoom.
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = stripRegion.contains(point)
            ? notes.indices.first { tabRect($0).contains(point) }
            : nil
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard stripRegion.contains(point),
              let index = notes.indices.first(where: { tabRect($0).contains(point) }) else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename…") { [weak self] in self?.beginRename(index) })
        if notes.count > 1 {
            menu.addItem(ClosureMenuItem("Close") { [weak self] in self?.onClose?(index) })
        }
        return menu
    }

    // MARK: Renaming
    //
    // A text field laid over the tab's label for as long as the rename lasts.
    // Return or clicking away keeps the name; Escape drops it.

    func beginRename(_ index: Int) {
        guard notes.indices.contains(index) else { return }
        if renaming != nil { window?.makeFirstResponder(nil) }
        onSelect?(index)
        revealTab(index)

        let field = NSTextField(string: notes[index].name ?? notes[index].title)
        renameSeed = field.stringValue
        field.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        field.textColor = theme.foreground
        field.backgroundColor = theme.activeTabFill
        field.isBordered = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.delegate = self
        let label = labelRect(index)
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: label.minX - 2, y: label.midY - height / 2, width: label.width + 2, height: height)

        renaming = index
        renameField = field
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func finishRename(keeping: Bool) {
        guard let index = renaming, let field = renameField else { return }
        renaming = nil
        renameField = nil
        field.removeFromSuperview()
        needsDisplay = true
        // Unchanged means untouched: the seed is the truncated tab title, which
        // must not become the note's name or its file's.
        guard keeping, notes.indices.contains(index), field.stringValue != renameSeed else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onRename?(index, name.isEmpty ? nil : name)
    }
}

extension TabBarView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        finishRename(keeping: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishRename(keeping: false)
        window?.makeFirstResponder(nil)
        return true
    }
}

/// A menu item that runs a closure, so a one-off context menu needs no target.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used from a nib") }

    @objc private func run() { handler() }
}

// MARK: - Window content
//
// Frames are set by hand rather than with autoresizing masks, because the find
// bar appears and disappears between the tab strip and the note.

final class RootView: NSView {
    var onResize: (() -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        onResize?()
    }
}

// MARK: - Bridge into the page
//
// notes.html stays untouched so it still works on its own in Safari and on
// iOS. Everything native hooks onto its existing elements and events.

// Held on a type rather than as a plain global: globals in a file with
// top-level code are initialised eagerly, which would make even --write-icon
// require the resource.
private enum Bridge {
    static let source: String = {
        guard let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            // Saving, find and theme sync all ride on this file; a bundle
            // without it is broken in a way that must not fail quietly.
            fatalError("bridge.js missing from the app bundle")
        }
        return source
    }()
}

/// Builds a web view for one note. The app and its checks share this so they
/// exercise the same loading and persistence path.
func makeWebView(
    handlingMessagesFor handler: WKScriptMessageHandler,
    isolated: Bool = false
) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(LocalContentHandler(), forURLScheme: "notes")
    // The page keeps its own localStorage copy, shared by every run of this
    // bundle. The checks must not write into the copy the real app reads.
    configuration.websiteDataStore = (isolated || runningACheck) ? .nonPersistent() : .default()
    configuration.userContentController.add(handler, name: "save")
    configuration.userContentController.add(handler, name: "theme")
    configuration.userContentController.addUserScript(
        WKUserScript(source: Bridge.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")  // no white flash before first paint
    return webView
}

// MARK: - Serving the page over a real origin
//
// Serving over a custom scheme rather than file:// gives the page a real
// security origin, so its own localStorage cache works at all.

final class LocalContentHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let root = contentDirectory().standardizedFileURL
        let requested = task.request.url?.path ?? "/"
        let file = root.appendingPathComponent(requested).standardizedFileURL

        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        // UTType has no mapping for web font types, and a font served as
        // application/octet-stream is refused.
        let webTypes = [
            "html": "text/html; charset=utf-8",
            "js": "text/javascript; charset=utf-8",
            "css": "text/css; charset=utf-8",
            "woff2": "font/woff2",
            "woff": "font/woff",
        ]
        let mime = webTypes[file.pathExtension.lowercased()]
            ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]
        )!

        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var root: RootView!
    private var tabBar: TabBarView!

    private let store = NoteStore()
    private var library = Library.empty
    private var theme = Theme.dark

    /// Files Finder handed over before the page could show them.
    private var pendingFiles: [URL] = []
    private var pageReady = false

    /// One web view for every note. Each note's undo history and selection
    /// live in its own CodeMirror state inside the page, so they stay separate
    /// without a web view — and a web content process — per note.
    private var webView: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        library = store.load()

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

    private func refreshTabs() {
        tabBar.notes = library.notes
        tabBar.active = library.active
    }

    /// Hands the active note to the page. The text is authoritative on first
    /// sight; after that the page's own state for that note takes over, which
    /// is what carries its undo history across a tab switch.
    private func showActiveNote() {
        let note = library.activeNote
        guard let id = jsLiteral(note.id.uuidString), let text = jsLiteral(note.text) else { return }
        let isMarkdown = ["md", "markdown"].contains(
            note.filePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        )
        webView?.evaluateJavaScript(
            "window.__notesSwitchNote(\(id), \(text)); window.__notesShowOutline(\(isMarkdown))"
        )
    }

    private func select(_ index: Int) {
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

    private func closeTab(at index: Int) {
        guard library.notes.indices.contains(index) else { return }
        guard library.notes.count > 1 else {
            window.performClose(nil)
            return
        }

        let removed = library.notes.remove(at: index)
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

    private func renameTab(at index: Int, to name: String?) {
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

    @objc private func saveNote() {
        let note = library.activeNote
        let existing = note.filePath.map { URL(fileURLWithPath: $0) }

        do {
            try FileManager.default.createDirectory(
                at: saveDirectory, withIntermediateDirectories: true
            )
            let url = try existing ?? unusedSaveURL(for: note)
            try note.text.write(to: url, atomically: true, encoding: .utf8)

            library.notes[library.active].filePath = url.path
            store.save(library)
            flash("saved to \(shortPath(url))")
        } catch {
            // Writing can fail for reasons worth seeing: no permission to the
            // Documents folder, a full disk, a file that moved.
            report(error, title: "Could not save this note")
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
        return unusedURL(named: firstLine, in: saveDirectory, extension: "txt")
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
            library.notes.append(Note(text: text, filePath: url.path))
            library.active = library.notes.count - 1
            store.save(library)
            refreshTabs()
            showActiveNote()
            flash("opened \(shortPath(url))")
        } catch {
            report(error, title: "Could not open \(url.lastPathComponent)")
        }
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

    @objc private func selectAllText() {
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

    @objc private func undoEdit() {
        webView?.evaluateJavaScript("window.__notesUndo()")
    }

    @objc private func redoEdit() {
        webView?.evaluateJavaScript("window.__notesRedo()")
    }

    @objc private func actualSize() { webView?.magnification = 1 }

    @objc private func zoomIn() {
        webView.magnification = min(webView.magnification * 1.1, 3)
    }

    @objc private func zoomOut() {
        webView.magnification = max(webView.magnification / 1.1, 0.5)
    }

    /// Checks drive the real delegate, and launching reloads the library from
    /// disk — so a fixture has to go through the store, not the field.
    private func seedStore(_ library: Library) {
        let store = NoteStore()
        store.save(library)
        store.flush()
    }

    // MARK: Files check
    //
    // Saving writes something the person owns and can lose, so the round trip
    // is exercised: write, overwrite in place rather than duplicating, reopen,
    // and refuse to open the same file twice.
    func reportFiles() -> Never {
        let original = "Peer Evaluation\n- first point\n- second point"
        seedStore(Library(notes: [Note(text: original)], active: 0))
        applicationDidFinishLaunching(Notification(name: Notification.Name("check")))
        wait(until: { self.pageReady }, seconds: 20)

        var problems: [String] = []
        let manager = FileManager.default

        func filesInSaveDirectory() -> [String] {
            ((try? manager.contentsOfDirectory(atPath: saveDirectory.path)) ?? []).sorted()
        }

        // 1. A first save names the file from the note's first line.
        saveNote()
        wait(until: { false }, seconds: 0.4)
        let expected = saveDirectory.appendingPathComponent("Peer Evaluation.txt")
        print("after first save: \(filesInSaveDirectory())")
        if !manager.fileExists(atPath: expected.path) {
            problems.append("did not write Peer Evaluation.txt")
        }
        let written = (try? String(contentsOf: expected, encoding: .utf8)) ?? ""
        if written != original { problems.append("saved contents do not match the note") }
        if library.notes[0].filePath != expected.path {
            problems.append("the note did not remember where it was saved")
        }

        // 2. Saving again overwrites that file rather than making another.
        let edited = original + "\n- third point"
        library.notes[0].text = edited
        saveNote()
        wait(until: { false }, seconds: 0.4)
        print("after second save: \(filesInSaveDirectory())")
        if filesInSaveDirectory().count != 1 { problems.append("saving twice left more than one file") }
        if (try? String(contentsOf: expected, encoding: .utf8)) != edited {
            problems.append("the second save did not update the file")
        }

        // 3. Opening a file adds a note bound to it.
        let external = saveDirectory.appendingPathComponent("From Finder.txt")
        try? "opened from disk\nsecond line".write(to: external, atomically: true, encoding: .utf8)
        openFile(external)
        wait(until: { false }, seconds: 0.4)
        print("notes after opening a file: \(library.notes.count), active \(library.active)")
        if library.notes.count != 2 { problems.append("opening a file did not add a note") }
        if library.activeNote.text != "opened from disk\nsecond line" {
            problems.append("the opened note does not hold the file's contents")
        }
        if library.activeNote.filePath != external.path {
            problems.append("the opened note is not bound to its file")
        }

        // 4. Opening it again selects that note instead of duplicating it.
        select(0)
        openFile(external)
        wait(until: { false }, seconds: 0.4)
        print("notes after reopening the same file: \(library.notes.count), active \(library.active)")
        if library.notes.count != 2 { problems.append("reopening a file duplicated it") }
        if library.activeNote.filePath != external.path {
            problems.append("reopening a file did not select the note already holding it")
        }

        // 4b. A markdown file gets an outline of its headings; a text file none.
        let outlineScript = "JSON.stringify(window.__notesOutlineTitles())"
        let plainOutline = evaluate(outlineScript) as? String
        print("outline for a .txt note: \(plainOutline ?? "nil")")
        if plainOutline != "null" { problems.append("a .txt note showed an outline") }
        let markdownFile = saveDirectory.appendingPathComponent("Doc.md")
        try? "# Top\ntext\n## Sub ##\n```\n# not a heading\n```\n### Deep\n\nUnder **lined**\n---\n\n> ## Quoted".write(
            to: markdownFile, atomically: true, encoding: .utf8
        )
        openFile(markdownFile)
        wait(until: { false }, seconds: 0.4)
        let markdownOutline = evaluate(outlineScript) as? String
        print("outline for a .md note: \(markdownOutline ?? "nil")")
        if markdownOutline != "[\"Top\",\"Sub\",\"Deep\",\"Under lined\",\"Quoted\"]" { problems.append("the .md outline is wrong") }
        // Every offset lands on its heading's line, so a click jumps to it.
        let landing = evaluate("JSON.stringify(window.notesEditor.headings().map(function (h) {"
            + " return window.notesEditor.getText().slice(h.offset).split('\\n')[0]; }))") as? String
        print("outline offsets land on: \(landing ?? "nil")")
        if landing != "[\"# Top\",\"## Sub ##\",\"### Deep\",\"Under **lined**\",\"> ## Quoted\"]" {
            problems.append("an outline offset does not land on its heading")
        }

        // 4c. Renaming a note bound to a file renames the file, keeps its
        // extension, survives a case-only change, and never clobbers.
        let docIndex = library.active
        renameTab(at: docIndex, to: "Spec")
        let spec = saveDirectory.appendingPathComponent("Spec.md")
        print("after renaming Doc.md: \(filesInSaveDirectory())")
        if !manager.fileExists(atPath: spec.path) || manager.fileExists(atPath: markdownFile.path) {
            problems.append("renaming a tab did not rename its file")
        }
        if library.notes[docIndex].filePath != spec.path { problems.append("the renamed note lost its file") }
        renameTab(at: docIndex, to: "spec")
        let caseOnly = library.notes[docIndex].filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        print("after a case-only rename: \(caseOnly ?? "nil")")
        if caseOnly != "spec.md" || !filesInSaveDirectory().contains("spec.md") {
            problems.append("a case-only rename did not take")
        }
        renameTab(at: docIndex, to: "From Finder")
        let clash = library.notes[docIndex].filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        print("renamed onto a taken name: \(clash ?? "nil")")
        if clash != "From Finder.md" { problems.append("a rename with a free name did not keep it") }
        library.notes.append(Note(text: "x", filePath: external.path))
        renameTab(at: library.notes.count - 1, to: "Peer Evaluation")
        let clobber = library.notes.last?.filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        print("renamed onto an existing file: \(clobber ?? "nil")")
        if clobber != "Peer Evaluation 2.txt" { problems.append("a rename overwrote an existing file") }
        if (try? String(contentsOf: expected, encoding: .utf8)) != edited {
            problems.append("a rename clobbered the file whose name it wanted")
        }
        // Put it back: later steps expect From Finder.txt and a free "Peer Evaluation 2".
        renameTab(at: library.notes.count - 1, to: "From Finder")
        library.notes.removeLast()

        // 5. A note with nothing to name it still saves.
        library.notes.append(Note(text: "   \n\n"))
        library.active = library.notes.count - 1
        saveNote()
        wait(until: { false }, seconds: 0.4)
        if !manager.fileExists(atPath: saveDirectory.appendingPathComponent("Untitled.txt").path) {
            problems.append("an untitled note did not save as Untitled.txt")
        }

        // 6. A name already taken gets a suffix rather than clobbering.
        library.notes.append(Note(text: original))
        library.active = library.notes.count - 1
        saveNote()
        wait(until: { false }, seconds: 0.4)
        print("final directory: \(filesInSaveDirectory())")
        if !manager.fileExists(atPath: saveDirectory.appendingPathComponent("Peer Evaluation 2.txt").path) {
            problems.append("a second note with the same title overwrote the first")
        }
        if (try? String(contentsOf: expected, encoding: .utf8)) != edited {
            problems.append("saving a same-named note clobbered the original file")
        }

        // 7. A library written before saving existed still loads.
        let legacy = storeDirectory.appendingPathComponent("legacy.json")
        let legacyJSON = "{\"notes\":[{\"id\":\"\(UUID().uuidString)\",\"text\":\"older note\"}],\"active\":0}"
        try? legacyJSON.write(to: legacy, atomically: true, encoding: .utf8)
        if let data = try? Data(contentsOf: legacy),
           let decoded = try? JSONDecoder().decode(Library.self, from: data) {
            print("legacy library decoded: \(decoded.notes[0].text.debugDescription), filePath \(String(describing: decoded.notes[0].filePath))")
            if decoded.notes[0].filePath != nil { problems.append("a legacy note came back with a file path") }
        } else {
            problems.append("a library saved before this feature no longer decodes")
        }

        if problems.isEmpty {
            print("files ok")
            exit(0)
        }
        problems.forEach { print("PROBLEM: \($0)") }
        exit(1)
    }

    // MARK: Tabs check
    //
    // One web view now holds every note, so what used to be guaranteed by
    // separate views has to be proved: switching tabs must preserve each
    // note's text, undo history and scroll position, and an undo in one note
    // must not reach into another.
    func reportTabs() -> Never {
        var longNote = ["first note"]
        for i in 0..<300 { longNote.append("filler line \(i) in the first note") }
        seedStore(Library(
            notes: [Note(text: longNote.joined(separator: "\n")), Note(text: "second note")],
            active: 0
        ))
        applicationDidFinishLaunching(Notification(name: Notification.Name("check")))
        NSApp.activate(ignoringOtherApps: true)

        var problems: [String] = []
        let firstID = library.notes[0].id.uuidString
        let secondID = library.notes[1].id.uuidString

        wait(until: { self.noteInPage() == firstID }, seconds: 20)
        guard noteInPage() == firstID else { print("the first note never loaded"); exit(1) }

        // The point of the change: exactly one web view for every note.
        let views = root.subviews.filter { $0 is WKWebView }.count
        print("web views for 2 notes: \(views)")
        if views != 1 { problems.append("expected 1 web view, found \(views)") }

        wait(until: { false }, seconds: 0.4)
        type("AAA")
        let editedFirst = text()
        let typingWorks = editedFirst.hasPrefix("AAA")
        if !typingWorks {
            evaluate("window.notesEditor.view.dispatch({ changes: { from: 0, insert: 'AAA' } })")
        }
        let afterEditA = text()
        print("note 1 after edit: \(afterEditA.prefix(24).debugDescription)  (real keystrokes: \(typingWorks))")
        if !afterEditA.hasPrefix("AAA") { print("PROBLEM: could not edit the first note"); exit(1) }

        // Selection lives in the state, so it is the part of "where I was" that
        // can be checked without a rendering window. CodeMirror only runs the
        // measure pass that applies a scroll when a scroll event fires, which
        // never happens here, so scroll restoration itself is not exercised.
        evaluate("window.notesEditor.revealPosition(6000)")
        let caretBefore = Int(number("window.notesEditor.view.state.selection.main.from"))
        print("note 1 caret parked at \(caretBefore)")
        if caretBefore != 6000 { problems.append("could not park the caret in the first note") }

        select(1)
        wait(until: { self.noteInPage() == secondID }, seconds: 10)
        let onSecond = text()
        print("note 2 on arrival: \(onSecond.debugDescription)")
        if onSecond != "second note" { problems.append("switching notes did not load the second note's text") }

        evaluate("window.notesEditor.view.dispatch({ changes: { from: window.notesEditor.view.state.doc.length, insert: ' BBB' } })")
        let afterEditB = text()

        select(0)
        wait(until: { self.noteInPage() == firstID }, seconds: 10)

        let backOnFirst = text()
        print("note 1 on return: \(backOnFirst.prefix(24).debugDescription)")
        if backOnFirst != afterEditA { problems.append("the first note's text did not survive a tab switch") }

        let caretAfter = Int(number("window.notesEditor.view.state.selection.main.from"))
        print("note 1 caret on return: \(caretAfter) (was \(caretBefore))")
        if caretAfter != caretBefore {
            problems.append("the caret moved across a tab switch, \(caretAfter) vs \(caretBefore)")
        }
        print("NOTE: scroll restoration is implemented with a scroll snapshot but"
              + " not exercised here — CodeMirror applies a scroll on a measure"
              + " pass that only a rendering window triggers.")

        undoEdit()
        wait(until: { false }, seconds: 0.5)
        let undone = text()
        print("note 1 after undo: \(undone.prefix(24).debugDescription)")
        if undone == afterEditA { problems.append("undo did not undo the first note's edit") }
        if undone.hasPrefix("AAA") { problems.append("undo left the first note's edit in place") }

        select(1)
        wait(until: { self.noteInPage() == secondID }, seconds: 10)
        let secondUntouched = text()
        print("note 2 after undo in note 1: \(secondUntouched.debugDescription)")
        if secondUntouched != afterEditB { problems.append("undo in one note also changed the other") }

        select(0)
        wait(until: { self.noteInPage() == firstID }, seconds: 10)
        redoEdit()
        wait(until: { false }, seconds: 0.5)
        let redone = text()
        print("note 1 after redo: \(redone.prefix(24).debugDescription)")
        if redone != afterEditA { problems.append("redo did not put the first note's edit back") }

        // Undoing past the loaded text would be undoing something nobody did.
        undoEdit()
        undoEdit()
        wait(until: { false }, seconds: 0.5)
        if text().hasPrefix("AAA") { problems.append("undo ran past the note's loaded text") }

        // Both notes have been visited, so both have state held for them.
        let held = Int(number("window.notesEditor.heldNotes()"))
        print("states held in the page: \(held)")
        if held != 2 { problems.append("expected state for 2 notes, found \(held)") }

        let heading = Note(text: "## Heading\nbody").title
        if heading != "Heading" { problems.append("a tab title kept its markdown marker: \(heading)") }

        renameTab(at: 1, to: "Renamed")
        if tabBar.notes[1].title != "Renamed" { problems.append("renaming a tab did not change its title") }
        renameTab(at: 1, to: nil)
        if tabBar.notes[1].title != library.notes[1].text { problems.append("clearing a rename did not restore the first line") }

        closeTab(at: 1)
        wait(until: { false }, seconds: 0.5)
        let afterClose = Int(number("window.notesEditor.heldNotes()"))
        print("states held after closing a note: \(afterClose)")
        if afterClose != 1 { problems.append("closing a note did not release its state, \(afterClose) held") }

        // The Edit menu's clipboard items reach the web view as selectors.
        // undo:/redo: turned out not to exist there, so the rest are checked
        // rather than assumed — but NSApp.sendAction only consults the key
        // window's responder chain, and this check cannot hold focus on a
        // machine somebody is using.
        for selector in ["copy:", "paste:"] where !webView.responds(to: Selector((selector))) {
            problems.append("the editor's web view does not implement \(selector)")
        }

        selectAllText()
        wait(until: { false }, seconds: 0.3)
        let whole = text()
        let selected = evaluate("window.notesEditor.getSelectedText()") as? String ?? ""
        print("Select All selected \(selected.count) of \(whole.count) characters")
        if selected != whole { problems.append("Edit > Select All did not select the whole note") }

        if problems.isEmpty {
            print("tabs ok")
            exit(0)
        }
        problems.forEach { print("PROBLEM: \($0)") }
        exit(1)
    }

    private func noteInPage() -> String {
        evaluate("String(window.notesEditor && window.notesEditor.currentNote())") as? String ?? ""
    }

    private func text() -> String {
        evaluate("window.notesEditor.getText()") as? String ?? ""
    }

    private func number(_ script: String) -> Double {
        (evaluate(script) as? NSNumber)?.doubleValue ?? -1
    }

    /// Types with synthesized key events. Editing through JS never reaches the
    /// undo history the same way a person's typing does.
    private func type(_ string: String) {
        for character in string {
            let key = String(character)
            for down in [true, false] {
                guard let event = NSEvent.keyEvent(
                    with: down ? .keyDown : .keyUp,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: key,
                    charactersIgnoringModifiers: key,
                    isARepeat: false,
                    keyCode: 0
                ) else { continue }
                NSApp.sendEvent(event)
            }
        }
        wait(until: { false }, seconds: 0.4)
    }

    @discardableResult
    private func evaluate(_ script: String) -> Any? {
        var result: Any?
        var finished = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            finished = true
        }
        wait(until: { finished }, seconds: 10)
        return result
    }

    private func wait(until finished: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !finished(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: Layout check
    //
    // The strip only works if it clears the window buttons, the buttons sit off
    // the edge, and tabs keep their width and scroll instead of squeezing.
    // All of that is numbers, so it is asserted rather than eyeballed.
    func reportLayout(renderingInto directory: String?) -> Never {
        seedStore(Library(notes: (0..<3).map { Note(text: "note \($0)") }, active: 0))
        applicationDidFinishLaunching(Notification(name: Notification.Name("check")))
        window.layoutIfNeeded()

        var problems: [String] = []
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard !buttons.isEmpty else { print("no window buttons"); exit(1) }
        let frames = buttons.map { $0.convert($0.bounds, to: nil) }

        for frame in frames {
            let fromTop = window.frame.height - frame.maxY
            print(String(format: "button: %.1f from left, %.1f from top", frame.minX, fromTop))
            if frame.minX < 16 { problems.append("button only \(frame.minX)pt from the left edge") }
            if fromTop < 13 { problems.append("button only \(fromTop)pt from the top edge") }
        }

        let strip = tabBar.convert(tabBar.bounds, to: nil)
        let firstTab = tabBar.convert(tabBar.tabRect(0), to: nil)
        let buttonsEnd = frames.map(\.maxX).max() ?? 0
        print(String(format: "buttons end at %.1f, first tab starts at %.1f", buttonsEnd, firstTab.minX))
        if firstTab.minX < buttonsEnd + 8 { problems.append("tabs overlap the window buttons") }

        print(String(format: "strip flush at top: %.1f vs window height %.1f", strip.maxY, window.frame.height))
        if abs(strip.maxY - window.frame.height) > 0.5 { problems.append("tab strip is not flush with the window top") }
        if abs(frames[0].midY - strip.midY) > 1.5 { problems.append("buttons are not centred in the tab strip") }

        // The window has to fit a quarter of the screen, so the floor is checked
        // against the real display rather than trusted.
        print(String(format: "minimum window size: %.0f x %.0f",
                     window.minSize.width, window.minSize.height))
        if let screen = NSScreen.main {
            let quarter = NSSize(width: screen.frame.width / 2, height: screen.frame.height / 2)
            print(String(format: "  screen %.0f x %.0f, quarter tile %.0f x %.0f, quarter width %.0f",
                         screen.frame.width, screen.frame.height,
                         quarter.width, quarter.height, screen.frame.width / 4))
            if window.minSize.width > quarter.width || window.minSize.height > quarter.height {
                problems.append("the window cannot fit a quarter of the screen")
            }
            if window.minSize.width > screen.frame.width / 4 {
                problems.append("the window cannot fit a quarter-width column")
            }
        }

        // At that floor the strip must still clear the window buttons and leave
        // a whole tab visible beside the new-tab button.
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        window.layoutIfNeeded()
        let narrowTab = tabBar.convert(tabBar.tabRect(0), to: nil)
        let narrowButtonsEnd = types.compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil).maxX }.max() ?? 0
        print(String(format: "  at the floor: buttons end %.0f, first tab %.0f..%.0f, strip region width %.0f",
                     narrowButtonsEnd, narrowTab.minX, narrowTab.maxX, tabBar.stripRegion.width))
        if narrowTab.minX < narrowButtonsEnd + 8 {
            problems.append("at the minimum width the tabs overlap the window buttons")
        }
        if tabBar.stripRegion.width < tabBar.tabRect(0).width - 0.5 {
            problems.append("at the minimum width a whole tab does not fit")
        }

        // Tabs must not squeeze: the width is the same with 3 notes and with 40,
        // and the overflow becomes scrollable instead.
        let widthWithThree = tabBar.tabRect(0).width
        library = Library(notes: (0..<40).map { Note(text: "note \($0)") }, active: 0)
        refreshTabs()
        let widthWithForty = tabBar.tabRect(0).width
        print(String(format: "tab width: %.1f with 3 notes, %.1f with 40", widthWithThree, widthWithForty))
        if abs(widthWithThree - widthWithForty) > 0.5 { problems.append("tabs squeeze as notes are added") }
        print(String(format: "max scroll with 40 notes: %.1f", tabBar.maxScroll))
        if tabBar.maxScroll <= 0 { problems.append("40 notes did not become scrollable") }

        tabBar.revealTab(39)
        let last = tabBar.tabRect(39)
        print(String(format: "after revealing the last tab: offset %.1f, tab x %.1f..%.1f, region %.1f..%.1f",
                     tabBar.scrollOffset, last.minX, last.maxX, tabBar.stripRegion.minX, tabBar.stripRegion.maxX))
        if last.minX < tabBar.stripRegion.minX - 0.5 || last.maxX > tabBar.stripRegion.maxX + 0.5 {
            problems.append("revealing the last tab did not bring it fully into view")
        }

        tabBar.revealTab(0)
        let first = tabBar.tabRect(0)
        if abs(tabBar.scrollOffset) > 0.5 || first.minX < tabBar.stripRegion.minX - 0.5 {
            problems.append("revealing the first tab did not scroll back to the start")
        }

        if let directory { renderTabBar(intoDirectory: directory) }

        if problems.isEmpty {
            print("layout ok")
            exit(0)
        }
        problems.forEach { print("PROBLEM: \($0)") }
        exit(1)
    }

    /// Draws the strip offscreen in both themes so it can be inspected without
    /// a screenshot of the running app.
    private func renderTabBar(intoDirectory directory: String) {
        let scenes: [(String, [Note], Int, Theme, CGFloat)] = [
            ("tabbar-dark", [Note(text: "Groceries\nmilk"), Note(), Note(text: "meeting notes for the quarterly review")], 0, .dark, 0),
            ("tabbar-light", [Note(text: "Groceries\nmilk"), Note(), Note(text: "meeting notes for the quarterly review")], 0, .light, 0),
            ("tabbar-overflow", (0..<12).map { Note(text: "note number \($0)") }, 7, .dark, -1),
        ]

        for (name, notes, active, candidate, scroll) in scenes {
            library = Library(notes: notes, active: active)
            refreshTabs()
            tabBar.theme = candidate
            if scroll < 0 { tabBar.revealTab(active) }
            tabBar.needsDisplay = true
            guard let rep = tabBar.bitmapImageRepForCachingDisplay(in: tabBar.bounds) else { continue }
            tabBar.cacheDisplay(in: tabBar.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("wrote \(url.path)")
        }
    }
}

// MARK: - Self check
//
// Persisting notes is the whole point of the app, so the check drives the real
// save path: run once to write through the bridge, again to prove the text
// comes back. NOTES_STORE points it at a disposable directory.

final class SelfCheck: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let sentinel = "self check note\nsecond line"
    private var webView: WKWebView!
    private let store = NoteStore()
    private var result: String?
    private var saved = false

    func run() -> Never {
        webView = makeWebView(handlingMessagesFor: self, isolated: true)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: pageURL))
        wait(until: { self.result != nil }, seconds: 20)
        store.flush()
        print(result ?? "timeout")
        exit(result == "seeded" || result == "restored" ? 0 : 1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        var library = store.load()
        library.repair()

        if library.activeNote.text == sentinel {
            result = "restored"
            return
        }

        guard let data = try? JSONEncoder().encode(sentinel),
              let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__notesRestore(\(literal))") { _, _ in
            self.wait(until: { self.saved }, seconds: 5)
            self.result = self.saved ? "seeded" : "not-saved"
        }
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "save",
              let payload = message.body as? [String: Any],
              let text = payload["text"] as? String,
              text == sentinel else { return }
        saved = true
        store.save(Library(notes: [Note(text: text)], active: 0))
    }

    private func wait(until done: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

// MARK: - Find check
//
// Find, wrapping, match painting and multi-cursor all run against a real page
// in a real window, because they depend on the editor's own layout and
// scrolling.

final class FindCheck: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var failures: [String] = []
    private var loaded = false

    func run() -> Never {
        webView = makeWebView(handlingMessagesFor: self, isolated: true)
        webView.navigationDelegate = self
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: pageURL))

        wait(seconds: 25) { self.loaded }
        guard loaded else { print("timeout loading the page"); exit(1) }

        check()

        failures.forEach { print("PROBLEM: \($0)") }
        print(failures.isEmpty ? "find ok" : "find failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
    }

    private func check() {
        // "alpha" appears three times; the third is far enough down that
        // reaching it has to scroll.
        var lines = ["alpha beta", "gamma alpha delta"]
        for i in 0..<400 { lines.append("filler line \(i) with enough words to wrap around the column") }
        lines.append("trailing alpha here")
        let text = lines.joined(separator: "\n")

        guard let literal = jsString(text) else { failures.append("could not encode the fixture"); return }
        evaluate("window.__notesRestore(\(literal))")

        let thirdOffset = (text as NSString).range(of: "trailing alpha").location + 9
        let secondOffset = ("alpha beta\n" as NSString).length + 6

        caret(0)
        expect("first match", find(0), index: 1, total: 3, caret: 0)
        expect("second match", find(1), index: 2, total: 3, caret: secondOffset)
        expect("third match", find(1), index: 3, total: 3, caret: thirdOffset)

        // CodeMirror applies a pending scroll on its next measure pass, which
        // it schedules from a scroll event. Nudging the scroller produces one;
        // CodeMirror then corrects the position to the match, so a value still
        // near the nudge means the scroll never happened.
        evaluate("window.notesEditor.view.scrollDOM.scrollTop = 1")
        wait(seconds: 5) { self.number("window.notesEditor.view.scrollDOM.scrollTop") > 1000 }
        let scrolled = number("window.notesEditor.view.scrollDOM.scrollTop")
        print("  scrollTop at the third match: \(scrolled)")
        if scrolled <= 1000 { failures.append("reaching a far match did not scroll it into view") }

        expect("wrap forwards", find(1), index: 1, total: 3, caret: 0)
        expect("wrap backwards", find(-1), index: 3, total: 3, caret: thirdOffset)

        let missing = evaluate("JSON.stringify(window.notesEditor.find('zzzznope', 0))") as? String ?? ""
        print("  missing query: \(missing)")
        if !missing.contains("\"total\":0") { failures.append("a missing query should report no matches") }

        // Every match decorated and exactly one marked current — the selection
        // alone is invisible while the find field holds focus. Only the matches
        // inside the rendered viewport reach the DOM, which is why the painted
        // count is a subset rather than the total.
        caret(0)
        _ = find(0)
        let decorated = Int(number("window.notesEditor.matchCount()"))
        let marks = Int(number("window.notesEditor.paintedMatches().marks"))
        let current = Int(number("window.notesEditor.paintedMatches().current"))
        print("  decorated: \(decorated), painted in the viewport: \(marks), current: \(current)")
        if decorated != 3 { failures.append("decorated \(decorated) matches, expected 3") }
        if marks < 1 || marks > decorated {
            failures.append("painted \(marks) highlights, expected between 1 and \(decorated)")
        }
        if current != 1 { failures.append("\(current) matches marked current, expected exactly 1") }

        evaluate("window.notesEditor.clearFind()")
        if Int(number("window.notesEditor.matchCount()")) != 0 {
            failures.append("clearing find left matches decorated")
        }
        if Int(number("window.notesEditor.paintedMatches().marks")) != 0 {
            failures.append("clearing find left highlights in the DOM")
        }

        // The reported bug: highlights drawn in a separate overlay drifted out
        // of step with the text while scrolling. Matches are now document
        // decorations, so after scrolling to an arbitrary offset the text under
        // a highlight must still be the query.
        caret(0)
        _ = evaluate("JSON.stringify(window.notesEditor.find('filler', 0))")
        evaluate("window.notesEditor.view.scrollDOM.scrollTop = 4137")
        wait(seconds: 0.4) { false }
        let underHighlight = evaluate("""
        (function () {
          var view = window.notesEditor.view;
          var mark = view.dom.querySelector('.cm-notesMatch');
          if (!mark) return 'no mark in the viewport';
          var box = mark.getBoundingClientRect();
          var at = view.posAtCoords({ x: box.left + 1, y: box.top + box.height / 2 });
          if (at == null) return 'no document position under the highlight';
          return view.state.sliceDoc(at, at + 6);
        })()
        """) as? String ?? ""
        print("  text under a highlight after scrolling to 4137: \(underHighlight.debugDescription)")
        if underHighlight.lowercased() != "filler" {
            failures.append("highlight sits over \(underHighlight.debugDescription), not the query")
        }
        evaluate("window.notesEditor.clearFind()")

        // Both strips above the status bar slide by animating height. The motion
        // itself cannot be observed in a window that is not painting, so what
        // is checked is that each declares a transition and that its settled
        // heights are right.
        evaluate("document.head.insertAdjacentHTML('beforeend',"
            + " '<style id=\"nomotion\">.notes-panel, .notes-panel-inner { transition: none !important; }</style>')")

        evaluate("window.__notesFindShow()")
        let findOpen = number("document.querySelector('.notes-find').getBoundingClientRect().height")
        evaluate("window.__notesFindHide()")
        let findShut = number("document.querySelector('.notes-find').getBoundingClientRect().height")
        evaluate("window.__notesFlash('saved to somewhere')")
        let flashOpen = number("document.querySelector('.notes-flash').getBoundingClientRect().height")
        print("  find strip: \(findOpen)pt open, \(findShut)pt shut; flash strip: \(flashOpen)pt open")
        if findOpen < 30 { failures.append("the find strip did not open, height \(findOpen)") }
        if findShut != 0 { failures.append("the find strip did not close, height \(findShut)") }
        if flashOpen < 20 { failures.append("the flash strip did not open, height \(flashOpen)") }

        evaluate("document.getElementById('nomotion').remove()")
        let declared = evaluate("""
        (function () {
          var find = getComputedStyle(document.querySelector('.notes-find')).transitionProperty;
          var flash = getComputedStyle(document.querySelector('.notes-flash')).transitionProperty;
          var inner = getComputedStyle(document.querySelector('.notes-flash .notes-panel-inner')).transitionProperty;
          return find + ' / ' + flash + ' / ' + inner;
        })()
        """) as? String ?? ""
        print("  transitions declared (find / flash / inner): \(declared)")
        if !declared.contains("height") || !declared.contains("transform") {
            failures.append("a strip is missing its slide transition: \(declared)")
        }
        evaluate("window.__notesFindHide()")

        // Cmd+D with no selection takes the word under the caret.
        let gamma = (text as NSString).range(of: "gamma").location
        caret(gamma + 2)
        evaluate("window.notesEditor.selectNextOccurrence()")
        let word = evaluate("window.notesEditor.getSelectedText()") as? String ?? ""
        print("  word under the caret: \(word.debugDescription)")
        if word != "gamma" { failures.append("Cmd+D should select the word under the caret") }

        // And again adds a cursor per further match, rather than moving one.
        // This is the whole reason for the editor swap.
        caret(2)
        evaluate("window.notesEditor.selectNextOccurrence()")
        let one = Int(number("window.notesEditor.cursorCount()"))
        evaluate("window.notesEditor.selectNextOccurrence()")
        let two = Int(number("window.notesEditor.cursorCount()"))
        evaluate("window.notesEditor.selectNextOccurrence()")
        let three = Int(number("window.notesEditor.cursorCount()"))
        print("  cursors after successive Cmd+D: \(one), \(two), \(three)")
        if one != 1 || two != 2 || three != 3 {
            failures.append("Cmd+D should add a cursor per match, got \(one), \(two), \(three)")
        }
    }

    // MARK: Helpers

    private func find(_ direction: Int) -> String {
        evaluate("JSON.stringify(window.notesEditor.find('alpha', \(direction)))") as? String ?? ""
    }

    private func caret(_ offset: Int) {
        evaluate("window.notesEditor.view.dispatch({ selection: { anchor: \(offset), head: \(offset) } })")
    }

    private func expect(_ label: String, _ json: String, index: Int, total: Int, caret expectedCaret: Int) {
        let actualCaret = Int(number("window.notesEditor.view.state.selection.main.from"))
        print("  \(label): \(json) caret=\(actualCaret)")
        if !json.contains("\"index\":\(index)") { failures.append("\(label) should be index \(index)") }
        if !json.contains("\"total\":\(total)") { failures.append("\(label) should report \(total) matches") }
        if actualCaret != expectedCaret {
            failures.append("\(label) selected offset \(actualCaret), expected \(expectedCaret)")
        }
    }

    private func jsString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func evaluate(_ script: String) -> Any? {
        var result: Any?
        var finished = false
        webView.evaluateJavaScript(script) { value, error in
            if let error { self.failures.append("script failed: \(script.prefix(60)) -> \(error)") }
            result = value
            finished = true
        }
        wait(seconds: 10) { finished }
        return result
    }

    private func number(_ script: String) -> Double {
        (evaluate(script) as? NSNumber)?.doubleValue ?? -1
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    private func wait(seconds: TimeInterval, until finished: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !finished(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

// MARK: - Page render
//
// Snapshots the real page, so in-page UI like the find bar can be looked at
// without a screen capture of the running app.

final class PageRender: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let directory: String
    private var webView: WKWebView!
    private var window: NSWindow!
    private var done = false

    init(directory: String) {
        self.directory = directory
        super.init()
    }

    func run() -> Never {
        webView = makeWebView(handlingMessagesFor: self, isolated: true)
        webView.navigationDelegate = self
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: pageURL))

        wait(seconds: 30) { self.done }
        exit(done ? 0 : 1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let sample = """
        Shipping notes

        The tab strip sits in the titlebar beside the window buttons.
        Find runs over the whole note and reports which match you are on.
        Each note keeps its own undo history.
        """
        guard let encoded = try? JSONEncoder().encode(sample),
              let literal = String(data: encoded, encoding: .utf8) else { return }

        run("window.__notesRestore(\(literal))")
        run("window.notesEditor.view.dispatch({ selection: { anchor: 0, head: 0 } })")

        // Proves the vendored font is really in use rather than silently
        // falling back to the generic monospace family.
        if let loaded = evaluate("document.fonts.check('15px \"JetBrains Mono\"')") as? Bool {
            print("JetBrains Mono available: \(loaded)")
        }
        if let families = evaluate(
            "getComputedStyle(document.querySelector('.cm-scroller')).fontFamily"
        ) as? String {
            print("editor font-family: \(families)")
        }

        let scenes: [(String, Bool, CGFloat, CGFloat)] = [
            ("page-find-dark", false, 900, 560),
            ("page-find-light", true, 900, 560),
            // The window's floor: where the find bar and status bar are tightest.
            ("page-find-narrow", false, TabBarView.minimumWidth, 420),
        ]

        run("document.head.insertAdjacentHTML('beforeend',"
            + " '<style>.notes-panel, .notes-panel-inner { transition: none !important; }</style>')")

        for (name, isLight, width, height) in scenes {
            window.setContentSize(NSSize(width: width, height: height))
            wait(seconds: 0.4) { false }
            run(isLight
                ? "document.documentElement.setAttribute('data-theme', 'light')"
                : "document.documentElement.removeAttribute('data-theme')")
            run("window.notesEditor.view.dispatch({ selection: { anchor: 0, head: 0 } })")
            run("window.__notesFindShow()")
            run("document.querySelector('.notes-find input').value = 'note';"
                + " document.querySelector('.notes-find input').dispatchEvent(new Event('input'))")
            run("window.__notesFlash('saved to ~/Documents/Notes/Peer Evaluation.txt')")
            snapshot(named: name)
        }

        // The outline at rest and opened. A snapshot cannot hover, so the open
        // state is forced with a style.
        window.setContentSize(NSSize(width: 900, height: 560))
        run("document.documentElement.removeAttribute('data-theme'); window.__notesFindHide()")
        var outlined = ["# Report", "", "## Introduction", "", "### Motivation", "", "### Previous work"]
        for section in ["Analyzer", "Builder", "Results"] {
            outlined += ["", "## \(section)", String(repeating: "Body text for \(section). ", count: 30), "", "### Detail"]
        }
        if let data = try? JSONEncoder().encode(outlined.joined(separator: "\n")),
           let text = String(data: data, encoding: .utf8) {
            run("window.__notesRestore(\(text)); window.__notesShowOutline(true)")
            wait(seconds: 0.3) { false }
            snapshot(named: "page-outline")
            run("document.head.insertAdjacentHTML('beforeend', '<style>.notes-card { opacity: 1 !important;"
                + " visibility: visible !important; transform: none !important; transition: none !important; }"
                + " .notes-ticks { opacity: 0 !important; transition: none !important; }</style>')")
            wait(seconds: 0.3) { false }
            snapshot(named: "page-outline-open")
        }

        done = true
    }

    private func run(_ script: String) {
        _ = evaluate(script)
    }

    @discardableResult
    private func evaluate(_ script: String) -> Any? {
        var result: Any?
        var finished = false
        webView.evaluateJavaScript(script) { value, error in
            if let error { print("script error: \(error)") }
            result = value
            finished = true
        }
        wait(seconds: 10) { finished }
        return result
    }

    private func snapshot(named name: String) {
        wait(seconds: 0.5) { false }  // let the page paint
        var finished = false
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        webView.takeSnapshot(with: configuration) { image, error in
            defer { finished = true }
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("snapshot failed: \(String(describing: error))")
                return
            }
            let url = URL(fileURLWithPath: self.directory).appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("wrote \(url.path)")
        }
        wait(seconds: 15) { finished }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    private func wait(seconds: TimeInterval, until finished: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !finished(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

// MARK: - Icon rendering
//
// macOS icons are not full bleed: on a 1024pt canvas the artwork body is
// 824x824 centred. Supplied artwork that already carries its own rounded
// corners is placed on that grid untouched — masking it again would round the
// corners twice. The built-in mark, having no shape of its own, gets one.

private let iconBodyRatio: CGFloat = 824.0 / 1024.0

// Measured off the system's own icons — see the shadow note in drawIcon.
private let iconShadowBlur: CGFloat = 0.024
private let iconShadowOffset: CGFloat = 0.008
private let iconShadowOpacity: CGFloat = 0.35

/// Apple's corner is a superellipse rather than an arc: the curvature eases in
/// instead of meeting the straight edge abruptly. Exponent 5 matches the
/// system's own icons to within half a percent of canvas width, measured.
private func squirclePath(in rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let halfWidth = rect.width / 2
    let halfHeight = rect.height / 2
    let steps = 720

    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = rect.midX + halfWidth * copysign(pow(abs(cosine), 2 / exponent), cosine)
        let y = rect.midY + halfHeight * copysign(pow(abs(sine), 2 / exponent), sine)
        if step == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Trims the transparent surround, so the artwork's own edges define the icon
/// body rather than whatever padding the export happened to include.
func artworkTrimmedToContent(atPath path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

    let width = image.width, height = image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return image }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return image }

    return image.cropping(to: CGRect(
        x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
    )) ?? image
}

private func drawIcon(pixels: Int, artwork: CGImage?) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let bodySide = size * iconBodyRatio
    let body = NSRect(x: (size - bodySide) / 2, y: (size - bodySide) / 2,
                      width: bodySide, height: bodySide)

    if let artwork {
        // Fills the body box. The trimmed artwork is square to within a pixel —
        // the difference is corner antialiasing, not intent — so this puts it
        // on the grid in both directions rather than leaving it short in one.
        let target = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height)

        // Every system icon bakes a drop shadow; the Dock does not add one.
        // Without it the icon reads as flatter and smaller than its neighbours.
        // These numbers come from measuring Apple's own icons: their alpha
        // reaches 0.8% of the canvas above the body and 2.4% below it, which is
        // a blur of 1.6% offset 0.8% downwards.
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.setShadow(
                offset: CGSize(width: 0, height: -size * iconShadowOffset),
                blur: size * iconShadowBlur,
                color: NSColor.black.withAlphaComponent(iconShadowOpacity).cgColor
            )
            cg.draw(artwork, in: target)
            cg.restoreGState()
        }
    } else {
        Theme.dark.background.setFill()
        squirclePath(in: body).fill()

        let glyph = ">_" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size * 0.30, weight: .bold),
            .foregroundColor: Theme.dark.foreground,
        ]
        let measured = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(x: (size - measured.width) / 2, y: (size - measured.height) / 2 + size * 0.03),
            withAttributes: attributes
        )
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Entry point

let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--write-icon" {
    var artwork: CGImage?
    if arguments.count >= 4 {
        artwork = artworkTrimmedToContent(atPath: arguments[3])
        guard let artwork else {
            print("could not read the icon artwork at \(arguments[3])")
            exit(1)
        }
        print("  artwork trimmed to \(artwork.width)x\(artwork.height)")
    }
    for pixels in [16, 32, 64, 128, 256, 512, 1024] {
        guard let png = drawIcon(pixels: pixels, artwork: artwork) else { exit(1) }
        try! png.write(to: URL(fileURLWithPath: arguments[2]).appendingPathComponent("icon_\(pixels).png"))
    }
    exit(0)
}

if arguments.count == 2, arguments[1] == "--self-check" {
    _ = NSApplication.shared
    SelfCheck().run()
}

let app = NSApplication.shared

if arguments.count == 3, arguments[1] == "--render-page" {
    app.setActivationPolicy(.accessory)
    PageRender(directory: arguments[2]).run()
}

if arguments.count == 2, arguments[1] == "--find-check" {
    app.setActivationPolicy(.accessory)
    FindCheck().run()
}

if arguments.count == 2, arguments[1] == "--file-check" {
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.reportFiles()
}

if arguments.count == 2, arguments[1] == "--tabs-check" {
    // Regular, not accessory: undo registration needs a window that can focus.
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    delegate.reportTabs()
}

if arguments.count >= 2, arguments[1] == "--layout-check" {
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.reportLayout(renderingInto: arguments.count >= 3 ? arguments[2] : nil)
}

app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
