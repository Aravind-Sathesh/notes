import Cocoa

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

    /// Notes whose text differs from the file they are bound to.
    var unsaved: Set<UUID> = [] { didSet { if unsaved != oldValue { needsDisplay = true } } }

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
        let trailing = notes.count > 1 || unsaved.contains(notes[index].id) ? closeSide + 8 : 10
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

        // The macOS convention: a dot where the close button is, until you
        // reach for the close button.
        if unsaved.contains(notes[index].id), !(showClose && hovered == index) {
            draw(
                glyph: "●",
                in: closeRect(index),
                color: isActive ? theme.foreground : theme.dim,
                size: 8,
                weight: .regular
            )
        } else if showClose {
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
