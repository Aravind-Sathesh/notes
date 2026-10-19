import Cocoa
import WebKit

// MARK: - Checks on the real delegate
//
// Run with NOTES_STORE set, so they keep off the real library, window frame
// and recent files.

extension AppDelegate {
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
        let expected = saveDirectory.appendingPathComponent("Peer Evaluation.md")
        print("after first save: \(filesInSaveDirectory())")
        if !manager.fileExists(atPath: expected.path) {
            problems.append("did not write Peer Evaluation.md")
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

        // 4a. A file-bound note knows when it differs from its file, and an
        // untouched one follows its file when another app changes it.
        let finder = library.active
        let finderID = library.notes[finder].id
        if tabBar.unsaved.contains(finderID) { problems.append("a note just opened shows as unsaved") }
        try? "changed elsewhere".write(to: external, atomically: true, encoding: .utf8)
        checkFilesOnDisk()
        wait(until: { false }, seconds: 0.4)
        let followed = evaluate("window.notesEditor.getText()") as? String
        print("after another app changed the file: \(library.notes[finder].text.debugDescription), page \(followed.debugDescription)")
        if library.notes[finder].text != "changed elsewhere" || followed != "changed elsewhere" {
            problems.append("an untouched note did not follow its file")
        }
        library.notes[finder].text = "opened from disk\nsecond line"
        refreshTabs()
        print("unsaved after an edit: \(tabBar.unsaved.contains(finderID))")
        if !tabBar.unsaved.contains(finderID) { problems.append("an edited note does not show as unsaved") }
        saveNote()
        print("unsaved after saving: \(tabBar.unsaved.contains(finderID))")
        if tabBar.unsaved.contains(finderID) { problems.append("saving did not clear the unsaved mark") }

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
        library.notes.append(Note(text: "x", filePath: library.notes[docIndex].filePath))
        renameTab(at: library.notes.count - 1, to: "Peer Evaluation")
        let clobber = library.notes.last?.filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        print("renamed onto an existing file: \(clobber ?? "nil")")
        if clobber != "Peer Evaluation 2.md" { problems.append("a rename overwrote an existing file") }
        if (try? String(contentsOf: expected, encoding: .utf8)) != edited {
            problems.append("a rename clobbered the file whose name it wanted")
        }
        // Put it back: later steps expect From Finder.md and a free "Peer Evaluation 2".
        renameTab(at: library.notes.count - 1, to: "From Finder")
        library.notes.removeLast()

        // 4d. Save on the close question writes a never-saved note out, then
        // closes it; an empty note closes without asking.
        library.notes.append(Note(text: "Keep me\nbody"))
        refreshTabs()
        closeTab(at: library.notes.count - 1)
        wait(until: { false }, seconds: 0.3)
        answerClose("save")
        let keptFile = saveDirectory.appendingPathComponent("Keep me.md")
        print("saved from the close question: \(manager.fileExists(atPath: keptFile.path)), notes \(library.notes.count)")
        if !manager.fileExists(atPath: keptFile.path) { problems.append("save on close did not write the note") }
        if library.notes.contains(where: { $0.text == "Keep me\nbody" }) { problems.append("save on close left the tab open") }
        library.notes.append(Note(text: "  \n"))
        refreshTabs()
        closeTab(at: library.notes.count - 1)
        if library.notes.contains(where: { $0.text == "  \n" }) { problems.append("an empty note asked before closing") }
        try? manager.removeItem(at: keptFile)

        // 5. A note with nothing to name it still saves.
        library.notes.append(Note(text: "   \n\n"))
        library.active = library.notes.count - 1
        saveNote()
        wait(until: { false }, seconds: 0.4)
        if !manager.fileExists(atPath: saveDirectory.appendingPathComponent("Untitled.md").path) {
            problems.append("an untitled note did not save as Untitled.md")
        }

        // 6. A name already taken gets a suffix rather than clobbering.
        library.notes.append(Note(text: original))
        library.active = library.notes.count - 1
        saveNote()
        wait(until: { false }, seconds: 0.4)
        print("final directory: \(filesInSaveDirectory())")
        if !manager.fileExists(atPath: saveDirectory.appendingPathComponent("Peer Evaluation 2.md").path) {
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

        // Closing a note that was never saved asks first: cancel keeps it,
        // discard closes it. An empty one just closes.
        closeTab(at: 1)
        wait(until: { false }, seconds: 0.3)
        let asked = evaluate("window.__notesAskVisible()") as? Bool == true
        print("asked before closing an unsaved note: \(asked), active \(library.active)")
        if !asked || library.notes.count != 2 { problems.append("closing an unsaved note did not ask first") }
        if library.active != 1 { problems.append("the note being asked about was not brought to the front") }
        closeTab(at: 1)
        if library.notes.count != 2 { problems.append("a second close slipped past the open question") }
        answerClose("cancel")
        if library.notes.count != 2 { problems.append("cancel closed the note anyway") }
        closeTab(at: 1)
        wait(until: { false }, seconds: 0.3)
        answerClose("discard")
        wait(until: { false }, seconds: 0.3)
        if library.notes.count != 1 { problems.append("discard did not close the note") }
        if evaluate("window.__notesAskVisible()") as? Bool == true { problems.append("the question stayed up after closing") }
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
            run("window.__notesFlash('saved to ~/Documents/Notes/Peer Evaluation.md')")
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

        // The close question, in both themes.
        run("document.head.insertAdjacentHTML('beforeend', '<style>.notes-ask, .notes-ask-card"
            + " { transition: none !important; }</style>');"
            + " window.__notesAskToClose('Save changes to “A Mid-Semester Project Report”?',"
            + " 'Closing discards the edits not saved to Report.md.')")
        wait(seconds: 0.3) { false }
        snapshot(named: "page-ask-dark")
        run("document.documentElement.setAttribute('data-theme', 'light')")
        wait(seconds: 0.3) { false }
        snapshot(named: "page-ask-light")

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
