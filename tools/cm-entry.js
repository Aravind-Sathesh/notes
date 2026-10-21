// Bundled by build.sh into ../codemirror.js as a classic script exposing the
// global `NotesEditor`. Classic rather than an ES module so notes.html still
// opens straight from the filesystem, where module loading is blocked.

import { EditorState, EditorSelection, RangeSetBuilder, StateEffect, StateField, Transaction } from "@codemirror/state";
import { EditorView, Decoration, drawSelection, keymap, placeholder as placeholderExt, rectangularSelection } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, redo, undo } from "@codemirror/commands";
import { selectNextOccurrence } from "@codemirror/search";
import { Marked } from "marked";

// ----------------------------------------------------------- match painting
//
// Matches are a document decoration, so CodeMirror draws them inside its own
// scroller and they cannot drift out of step with the text while scrolling.

const matchMark = Decoration.mark({ class: "cm-notesMatch" });
const currentMark = Decoration.mark({ class: "cm-notesMatch cm-notesMatchCurrent" });

const setMatches = StateEffect.define();

function offsetsOf(state, query) {
  const found = [];
  if (!query) return found;
  const haystack = state.doc.toString().toLowerCase();
  const needle = query.toLowerCase();
  let at = 0;
  while ((at = haystack.indexOf(needle, at)) !== -1) {
    found.push(at);
    at += needle.length;
  }
  return found;
}

function decorate(state, query, current) {
  if (!query) return { query, current: -1, deco: Decoration.none };
  const builder = new RangeSetBuilder();
  offsetsOf(state, query).forEach((start, index) => {
    builder.add(start, start + query.length, index === current ? currentMark : matchMark);
  });
  return { query, current, deco: builder.finish() };
}

const matchField = StateField.define({
  create: () => ({ query: "", current: -1, deco: Decoration.none }),
  update(value, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setMatches)) {
        return decorate(transaction.state, effect.value.query, effect.value.current);
      }
    }
    // An edit can add or remove matches, so they are recomputed rather than
    // mapped through the change.
    if (transaction.docChanged && value.query) {
      return decorate(transaction.state, value.query, -1);
    }
    return value;
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.deco),
});

// ------------------------------------------------------------------- theme
//
// Every colour comes from the page's custom properties, so the existing
// data-theme switch restyles the editor with no involvement from here.

const theme = EditorView.theme({
  "&": {
    height: "100%",
    backgroundColor: "var(--bg)",
    color: "var(--fg)",
    fontSize: "15px",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": {
    fontFamily: "'JetBrains Mono', monospace",
    lineHeight: "1.6",
    padding: "24px 0",
    overscrollBehavior: "none",
  },
  ".cm-content": { padding: "0 24px", caretColor: "var(--fg)" },
  ".cm-line": { padding: "0" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--fg)", borderLeftWidth: "2px" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
    backgroundColor: "var(--sel)",
  },
  ".cm-placeholder": { color: "var(--dim)" },
  ".cm-notesMatch": { backgroundColor: "var(--match)", borderRadius: "2px" },
  ".cm-notesMatchCurrent": { backgroundColor: "var(--match-current)" },
});

// ------------------------------------------------------------------ tasks
//
// Tasks are stored as GFM's `- [ ] item`, so notes stay portable, but the
// `- ` is hidden on every line but the one being edited, where it would
// otherwise trip up the cursor. Typing `[ ] ` at a line's start writes it.

const taskPrefix = /^(\s*)- (?=\[[ xX]\] )/;

function taskDecorations(state) {
  const builder = new RangeSetBuilder();
  const active = new Set(state.selection.ranges.map((r) => state.doc.lineAt(r.head).number));
  // ponytail: rescans the whole note per change, fine at note sizes.
  for (let n = 1; n <= state.doc.lines; n++) {
    if (active.has(n)) continue;
    const line = state.doc.line(n);
    const match = taskPrefix.exec(line.text);
    if (match) {
      const from = line.from + match[1].length;
      builder.add(from, from + 2, Decoration.replace({}));
    }
  }
  return builder.finish();
}

const taskField = StateField.define({
  create: taskDecorations,
  update: (deco, tr) => (tr.docChanged || tr.selection ? taskDecorations(tr.state) : deco),
  provide: (field) => EditorView.decorations.from(field),
});

const taskInput = EditorView.inputHandler.of((view, from, to, text) => {
  if (text !== " " || from !== to) return false;
  const line = view.state.doc.lineAt(from);
  const match = /^(\s*)\[[ xX]\]$/.exec(line.text.slice(0, from - line.from));
  if (!match) return false;
  const at = line.from + match[1].length;
  view.dispatch({
    changes: [{ from: at, insert: "- " }, { from, insert: " " }],
    selection: { anchor: from + 3 },
    userEvent: "input.type",
  });
  return true;
});

// ---------------------------------------------------------------- markdown
//
// Notes can be any text file opened from disk, and the page can message the
// app, so raw HTML is shown as text and only plain link schemes survive.

const escapeHtml = (text) =>
  text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const safeUrl = (href) => /^(https?:|mailto:|#)/i.test(href || "");

const md = new Marked({ gfm: true, breaks: true });
md.use({
  renderer: {
    html: ({ text }) => escapeHtml(text),
    link(token) {
      return safeUrl(token.href) ? false : this.parser.parseInline(token.tokens);
    },
    image: ({ href, text }) => (safeUrl(href) ? false : escapeHtml(text)),
  },
});

// The outline's headings, read by the parser the preview renders with, so the
// two agree on what is a heading and in what order — setext headings and
// headings inside lists and quotes included. A nested heading's offset is that
// of the block holding it, since marked strips the `>` and indent it sat in.
function headingsOf(text) {
  const found = [];
  const scratch = document.createElement("div");

  function visit(token, offset) {
    if (token.type === "heading") {
      scratch.innerHTML = md.parseInline(token.text);
      const title = scratch.textContent.trim();
      if (title) found.push({ level: token.depth, title, offset });
      return;
    }
    const children =
      token.type === "list" ? token.items
      : token.type === "blockquote" || token.type === "list_item" ? token.tokens
      : [];
    (children || []).forEach((child) => visit(child, offset));
  }

  let at = 0;
  for (const token of md.lexer(text)) {
    visit(token, at);
    at += token.raw.length;
  }
  return found;
}

// -------------------------------------------------------------------- API

function create(options) {
  const listeners = [];
  const preview = options.preview;
  let markdownOn = false;

  function renderPreview() {
    if (markdownOn) preview.innerHTML = md.parse(view.state.doc.toString());
  }


  // Shared by every note's state, so a state swapped in behaves identically
  // to the one swapped out.
  const extensions = [
    history(),
    drawSelection(),
    rectangularSelection(),
    EditorView.lineWrapping,
    EditorState.allowMultipleSelections.of(true),
    placeholderExt(options.placeholder || ""),
    matchField,
    taskField,
    taskInput,
    theme,
    keymap.of([...defaultKeymap, ...historyKeymap]),
    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        renderPreview();
        listeners.forEach((listener) => listener());
      }
    }),
  ];

  function makeState(doc) {
    return EditorState.create({ doc: doc || "", extensions });
  }

  const view = new EditorView({ parent: options.parent, state: makeState(options.doc) });

  // One editor, one state per note. An EditorState carries its own undo
  // history and selection, so notes stay independent without a web view each.
  // Scroll position is a view concern rather than a state one, so it is
  // snapshotted alongside.
  const notes = new Map();
  let currentId = null;

  function stash() {
    if (currentId === null) return;
    notes.set(currentId, {
      state: view.state,
      scroll: view.scrollSnapshot ? view.scrollSnapshot() : null,
    });
  }

  function currentQuery() {
    return view.state.field(matchField).query;
  }

  const api = {
    view,

    onDocChange(listener) {
      listeners.push(listener);
    },

    getText() {
      return view.state.doc.toString();
    },

    /// Replaces the whole document without making it undoable, so undo never
    /// walks back past the text the note was loaded with.
    setText(text) {
      if (view.state.doc.toString() === text) return;
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
        annotations: Transaction.addToHistory.of(false),
      });
    },

    focus() {
      view.focus();
    },

    undo() {
      return undo(view);
    },

    redo() {
      return redo(view);
    },

    selectNextOccurrence() {
      view.focus();
      return selectNextOccurrence(view);
    },

    selectAll() {
      view.dispatch({ selection: { anchor: 0, head: view.state.doc.length } });
      view.focus();
    },

    /// [{ level, title, offset }] in document order, matching the preview's
    /// rendered h1–h6 one for one.
    headings() {
      return headingsOf(view.state.doc.toString());
    },

    getSelectedText() {
      const range = view.state.selection.main;
      return view.state.sliceDoc(range.from, range.to);
    },

    cursorCount() {
      return view.state.selection.ranges.length;
    },

    stats() {
      const text = view.state.doc.toString();
      const trimmed = text.trim();
      return {
        chars: text.length,
        words: trimmed === "" ? 0 : trimmed.split(/\s+/).length,
        lines: view.state.doc.lines,
      };
    },

    /// direction: 0 searches from the caret inclusive (a new or edited query),
    /// 1 forwards, -1 backwards. All three wrap.
    find(query, direction) {
      const found = offsetsOf(view.state, query);
      if (!found.length) {
        view.dispatch({ effects: setMatches.of({ query, current: -1 }) });
        return { total: 0, index: 0 };
      }

      const caret = view.state.selection.main.from;
      let pick;
      if (direction > 0) {
        pick = found.findIndex((at) => at > caret);
        if (pick === -1) pick = 0;
      } else if (direction < 0) {
        pick = -1;
        for (let i = 0; i < found.length; i++) if (found[i] < caret) pick = i;
        if (pick === -1) pick = found.length - 1;
      } else {
        pick = found.findIndex((at) => at >= caret);
        if (pick === -1) pick = 0;
      }

      const start = found[pick];
      view.dispatch({
        selection: EditorSelection.single(start, start + query.length),
        effects: [
          setMatches.of({ query, current: pick }),
          EditorView.scrollIntoView(start, { y: "center" }),
        ],
      });
      return { total: found.length, index: pick + 1 };
    },

    clearFind() {
      if (currentQuery()) view.dispatch({ effects: setMatches.of({ query: "", current: -1 }) });
    },

    /// Shows a note, keeping whatever the outgoing one had. `text` is only
    /// used the first time a note is seen; after that its own state wins,
    /// because that state is what produced the saved text.
    switchNote(id, text) {
      if (id === currentId) return false;
      stash();
      // Set before swapping, so a save triggered by the swap is attributed to
      // the note coming in rather than the one going out.
      currentId = id;
      const stored = notes.get(id);
      if (stored) {
        view.setState(stored.state);
        if (stored.scroll) view.dispatch({ effects: stored.scroll });
      } else {
        view.setState(makeState(text));
      }
      renderPreview();
      view.focus();
      return true;
    },

    /// Forgets a closed note, so its history is not held onto forever.
    dropNote(id) {
      notes.delete(id);
      if (currentId === id) currentId = null;
    },

    /// Swaps the editor for a read-only rendering of the note, and back.
    setMarkdown(on) {
      markdownOn = !!on;
      view.dom.style.display = markdownOn ? "none" : "";
      preview.hidden = !markdownOn;
      if (markdownOn) renderPreview();
      else view.focus();
    },

    currentNote() {
      return currentId;
    },

    /// For checks: how many notes have state held here.
    heldNotes() {
      return notes.size;
    },

    scrollTop() {
      return view.scrollDOM.scrollTop;
    },

    /// Brings an offset into view, the same way find does.
    revealPosition(offset) {
      view.dispatch({
        selection: { anchor: offset },
        effects: EditorView.scrollIntoView(offset, { y: "center" }),
      });
    },

    /// Every decorated match, including those outside the rendered viewport.
    matchCount() {
      return view.state.field(matchField).deco.size;
    },

    /// For checks: how many matches are in the DOM right now, and how many are
    /// current. CodeMirror only renders the visible viewport, so this is a
    /// subset of matchCount() on a long document.
    paintedMatches() {
      const root = view.dom;
      return {
        marks: root.querySelectorAll(".cm-notesMatch").length,
        current: root.querySelectorAll(".cm-notesMatchCurrent").length,
      };
    },
  };

  return api;
}

export { create };
