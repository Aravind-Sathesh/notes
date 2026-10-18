# Notes

A small tabbed notes app for macOS, for plain text and markdown. A native window around one web view running CodeMirror.

- Tabs that autosave as you type; Cmd+S writes a note out as a file you own
- Open `.txt` and `.md` files with Cmd+O, Open Recent, or Finder's Open With
- Click the selected tab to rename it; a note with a file renames the file
- A dot on tabs with unsaved changes; files changed by other apps are picked up when you switch back
- Markdown preview (Cmd+Option+M), and a heading outline on the right edge for `.md` files
- Find, multiple cursors, zoom, light and dark themes

## Install

Download `Notes-v1.0.0.zip` from [Releases](https://github.com/Aravind-Sathesh/notes/releases), unzip, and move `Notes.app` to Applications. It is ad-hoc signed rather than notarized, so on first launch right-click it and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Notes.app
```

## Build

Needs the Xcode command line tools and macOS 12 or later.

```bash
./build.sh
```

The editor bundle, `codemirror.js`, is committed. To rebuild it from `tools/cm-entry.js`, install the toolchain once and `build.sh` will use it:

```bash
cd tools && npm install
```

## Checks

The app drives itself through its real code paths against a throwaway store:

```bash
NOTES_STORE=$(mktemp -d) ./Notes.app/Contents/MacOS/Notes --file-check
```

The other checks are `--tabs-check`, `--find-check`, `--layout-check` and `--self-check`, and `--render-page <dir>` writes screenshots of the page.

## Layout

- `Sources/`: the app, in Swift (window, tabs, files, checks, icon)
- `notes.html`: the page; it also works on its own in a browser
- `bridge.js`, `bridge.css`: what the app adds to the page (find bar, outline, saving)
- `tools/cm-entry.js`: the editor and markdown setup bundled into `codemirror.js`

## License

MIT, see [LICENSE](LICENSE). Bundled third-party code and the JetBrains Mono font keep their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [fonts/OFL.txt](fonts/OFL.txt).
