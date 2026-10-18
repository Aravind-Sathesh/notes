import Cocoa
import WebKit

// MARK: - Where things live

func contentDirectory() -> URL {
    Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
}

let pageURL = URL(string: "notes://local/notes.html")!




/// True when the store has been redirected, which only the checks do. They
/// then keep off the real app's remembered window frame and website data.
let runningACheck = ProcessInfo.processInfo.environment["NOTES_STORE"] != nil

let storeDirectory: URL = {
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
