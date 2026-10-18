(function () {
  var editor = window.notesEditor;
  if (!editor) return;

  // Counted so a check can prove the text is only ever assigned once, when
  // the view loads.
  window.__notesRestoreCount = 0;

  // ------------------------------------------------------------- persistence
  //
  // WebKit flushes localStorage on its own unpredictable cadence, so the app
  // keeps the authoritative copy and treats the page's own storage as a cache.

  // One web view now holds every note, so the note's identity travels with
  // the text instead of being inferred from which view sent it.
  editor.onDocChange(function () {
    window.webkit.messageHandlers.save.postMessage({
      id: editor.currentNote(),
      text: editor.getText()
    });
  });

  window.__notesSwitchNote = function (id, text) {
    return editor.switchNote(id, text);
  };

  window.__notesDropNote = function (id) {
    editor.dropNote(id);
  };

  window.__notesRestore = function (text) {
    if (editor.getText() !== text) {
      window.__notesRestoreCount++;
      // Not undoable, so undo never walks back past the loaded text.
      editor.setText(text);
    }
    editor.focus();
  };

  // ------------------------------------------------------------- theme sync

  function reportTheme() {
    var style = getComputedStyle(document.documentElement);
    var read = function (name) { return style.getPropertyValue(name).trim(); };
    window.webkit.messageHandlers.theme.postMessage({
      bg: read('--bg'), fg: read('--fg'), dim: read('--dim'), border: read('--border')
    });
  }
  new MutationObserver(reportTheme).observe(document.documentElement, {
    attributes: true, attributeFilter: ['data-theme']
  });
  reportTheme();

  // ------------------------------------------------- commands from the menu

  window.__notesUndo = function () { return editor.undo(); };
  window.__notesRedo = function () { return editor.redo(); };
  window.__notesSelectAll = function () { editor.selectAll(); };
  window.__notesSelectOccurrence = function () {
    return { added: editor.selectNextOccurrence(), cursors: editor.cursorCount() };
  };

  // Kept for the checks, which drive find without the bar.
  window.__notesFind = function (query, direction) { return editor.find(query, direction); };

  // -------------------------------------------------------------- find bar
  //
  // Injected rather than added to notes.html, so the page stays usable on its
  // own, and built from the page's own custom properties and font so it is the
  // same surface as the status bar it sits above.

  var style = document.createElement('style');
  style.textContent = [
    // Both strips live in the same slot above the status bar and share one
    // way of appearing: the outer box animates its height so the note is
    // pushed up rather than covered, while the contents slide up into it.
    '.notes-panel {',
    '  height: 0;',
    '  overflow: hidden;',
    '  transition: height 190ms cubic-bezier(0.32, 0.72, 0, 1);',
    '}',
    '.notes-panel-inner {',
    '  box-sizing: border-box;',
    '  display: flex;',
    '  align-items: center;',
    '  width: 100%;',
    '  padding: 6px 16px;',
    '  border-top: 1px solid var(--border);',
    '  font-family: inherit;',
    '  font-size: 12px;',
    '  color: var(--dim);',
    '  user-select: none;',
    '  transform: translateY(100%);',
    '  transition: transform 190ms cubic-bezier(0.32, 0.72, 0, 1);',
    '}',
    '.notes-panel.showing .notes-panel-inner { transform: translateY(0); }',

    '.notes-find.showing { height: 38px; }',
    '.notes-find .notes-panel-inner { height: 38px; gap: 12px; }',
    '.notes-find input {',
    // Sized rather than stretched, and the auto margin keeps the count and
    // buttons on the right edge, mirroring the status bar below it.
    '  flex: 0 1 320px;',
    '  margin-right: auto;',
    '  min-width: 0;',
    '  background: transparent;',
    '  border: 1px solid var(--border);',
    '  border-radius: 4px;',
    '  color: var(--fg);',
    '  font-family: inherit;',
    '  font-size: 12px;',
    '  line-height: 1.4;',
    '  padding: 3px 8px;',
    '  outline: none;',
    '  caret-color: var(--fg);',
    '}',
    '.notes-find input::placeholder { color: var(--dim); }',
    '.notes-find input:focus { border-color: var(--dim); }',
    '.notes-find .count {',
    '  min-width: 76px;',
    '  text-align: right;',
    '  font-variant-numeric: tabular-nums;',
    '}',
    '.notes-find button {',
    '  background: none;',
    '  border: none;',
    '  color: var(--dim);',
    '  font-family: inherit;',
    '  font-size: 12px;',
    '  cursor: pointer;',
    '  padding: 0 2px;',
    '}',
    '.notes-find button:hover { color: var(--fg); }',

    '.notes-flash.showing { height: 29px; }',
    '.notes-flash .notes-panel-inner {',
    '  height: 29px;',
    '  white-space: nowrap;',
    '  overflow: hidden;',
    '  text-overflow: ellipsis;',
    '}'
  ].join('\n');
  document.head.appendChild(style);

  var bar = document.createElement('div');
  bar.className = 'notes-panel notes-find';
  bar.innerHTML =
    '<div class="notes-panel-inner">'
    + '<input type="text" spellcheck="false" placeholder="find">'
    + '<span class="count"></span>'
    + '<button type="button" data-act="prev" title="Previous">&lsaquo;</button>'
    + '<button type="button" data-act="next" title="Next">&rsaquo;</button>'
    + '<button type="button" data-act="done">done</button>'
    + '</div>';

  var statusbar = document.querySelector('.statusbar');
  if (statusbar) {
    statusbar.parentNode.insertBefore(bar, statusbar);
  } else {
    document.body.appendChild(bar);
  }

  var flash = document.createElement('div');
  flash.className = 'notes-panel notes-flash';
  var flashInner = document.createElement('div');
  flashInner.className = 'notes-panel-inner';
  flash.appendChild(flashInner);
  if (statusbar) {
    statusbar.parentNode.insertBefore(flash, statusbar);
  } else {
    document.body.appendChild(flash);
  }

  var flashTimer = null;

  window.__notesFlash = function (message) {
    flashInner.textContent = message;
    flash.classList.add('showing');
    if (flashTimer) clearTimeout(flashTimer);
    flashTimer = setTimeout(function () { flash.classList.remove('showing'); }, 2600);
  };

  var input = bar.querySelector('input');
  var count = bar.querySelector('.count');

  function run(direction) {
    if (!input.value) {
      count.textContent = '';
      editor.clearFind();
      return;
    }
    var result = editor.find(input.value, direction);
    count.textContent = result.total ? result.index + ' of ' + result.total : 'no results';
  }

  // ---------------------------------------------------------------- outline
  //
  // The note's headings, shown only for markdown files. At rest it is a column
  // of ticks on the right edge, one per heading, with the section in view lit;
  // hovering anywhere down that edge opens the list as an overlay, so the note
  // keeps its full width. Headings inside fenced code are not headings.

  var outlineStyle = document.createElement('style');
  outlineStyle.textContent = [
    '#editor { position: relative; }',
    // Text and the preview stop short of the strip rather than run under it.
    '#editor.has-outline .cm-content { padding-right: 72px; }',
    '#editor.has-outline .preview { padding-right: 72px; }',
    '.notes-outline {',
    '  position: absolute;',
    '  top: 0; bottom: 0; right: 0;',
    '  width: 72px;',
    '  z-index: 5;',
    '  user-select: none;',
    '}',
    '.notes-outline[hidden] { display: none; }',
    '.notes-ticks {',
    '  position: absolute;',
    '  top: 30px; right: 16px;',
    '  max-height: calc(100% - 60px);',
    '  overflow: hidden;',
    '  display: flex;',
    '  flex-direction: column;',
    '  align-items: flex-end;',
    '  gap: 6px;',
    '  transition: opacity 160ms ease;',
    '}',
    '.notes-ticks span {',
    '  height: 2px;',
    '  border-radius: 1px;',
    '  background: var(--dim);',
    '  opacity: 0.6;',
    '}',
    '.notes-ticks span.current { background: var(--fg); opacity: 1; }',
    '.notes-card {',
    '  position: absolute;',
    // A drawer the full height of the note, its list starting where the
    // note's text does.
    '  top: 0; bottom: 0; right: 0;',
    '  width: 280px;',
    '  overflow-y: auto;',
    '  overscroll-behavior: none;',
    '  padding: 24px 0;',
    // Translucent over a blur of the note; tintCard() supplies the tint.
    '  background: var(--bg);',
    '  -webkit-backdrop-filter: blur(16px) saturate(140%);',
    '  backdrop-filter: blur(16px) saturate(140%);',
    '  border-left: 1px solid var(--border);',
    '  box-shadow: -12px 0 28px rgba(0, 0, 0, 0.22);',
    '  font-size: 12px;',
    '  line-height: 1.5;',
    // Slides in from the edge as it fades, on the find bar's curve; leaving
    // is a touch quicker than arriving.
    '  opacity: 0;',
    '  transform: translateX(18px);',
    '  visibility: hidden;',
    '  will-change: opacity, transform;',
    '  transition: opacity 160ms ease, transform 200ms cubic-bezier(0.32, 0.72, 0, 1), visibility 0s 200ms;',
    '}',
    // A short delay on the way in, so sweeping the pointer past the edge does
    // not flash the list.
    '.notes-outline:hover .notes-card {',
    '  opacity: 1;',
    '  transform: none;',
    '  visibility: visible;',
    '  transition: opacity 220ms ease 60ms, transform 280ms cubic-bezier(0.32, 0.72, 0, 1) 60ms, visibility 0s 60ms;',
    '}',
    '.notes-outline:hover .notes-ticks { opacity: 0; transition-delay: 60ms; }',
    // Levels read by indent, shade and spacing: each top-level heading opens
    // a group with room above it.
    '.notes-card div {',
    '  padding: 2px 16px;',
    '  white-space: nowrap;',
    '  overflow: hidden;',
    '  text-overflow: ellipsis;',
    '  cursor: pointer;',
    '  color: var(--fg);',
    '}',
    '.notes-card div:hover { opacity: 1 !important; }',
    '.notes-card div.level-0 { margin-top: 12px; }',
    '.notes-card div.level-1 { margin-top: 6px; }',
    '.notes-card div:first-child { margin-top: 0; }',
    '.notes-card div.current { font-weight: 600; }'
  ].join('\n');
  document.head.appendChild(outlineStyle);

  var editorBox = document.getElementById('editor');
  var outline = document.createElement('nav');
  outline.className = 'notes-outline';
  outline.hidden = true;
  var ticks = document.createElement('div');
  ticks.className = 'notes-ticks';
  var card = document.createElement('div');
  card.className = 'notes-card';
  outline.appendChild(ticks);
  outline.appendChild(card);

  // --bg is a hex colour and the macOS 12 web view has no color-mix, so the
  // translucent tint is worked out here, and again whenever the theme flips.
  function tintCard() {
    var hex = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
    var rgb = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
    card.style.backgroundColor = rgb
      ? 'rgba(' + rgb.slice(1).map(function (c) { return parseInt(c, 16); }).join(', ') + ', 0.82)'
      : '';
  }
  tintCard();
  new MutationObserver(tintCard).observe(document.documentElement, {
    attributes: true, attributeFilter: ['data-theme']
  });
  editorBox.appendChild(outline);

  // The strip sits over the editor's scroller, so the wheel is passed through
  // to the note — except over a list long enough to scroll itself.
  outline.addEventListener('wheel', function (event) {
    if (card.contains(event.target) && card.scrollHeight > card.clientHeight) return;
    var preview = document.getElementById('preview');
    var scroller = preview && !preview.hidden ? preview : editor.view.scrollDOM;
    scroller.scrollTop += event.deltaY;
    event.preventDefault();
  }, { passive: false });

  function headings(text) {
    var found = [];
    var fence = null;
    var offset = 0;
    text.split('\n').forEach(function (line) {
      var marker = /^\s{0,3}(`{3,}|~{3,})/.exec(line);
      if (marker && (!fence || marker[1][0] === fence)) {
        fence = fence ? null : marker[1][0];
      } else if (!fence) {
        var heading = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
        if (heading && heading[2]) {
          found.push({ level: heading[1].length, title: heading[2], offset: offset });
        }
      }
      offset += line.length + 1;
    });
    return found;
  }

  var SHADES = [1, 0.72, 0.54, 0.42];
  var TICKS = [18, 13, 9, 6];
  var list = [];

  function renderOutline() {
    list = outline.hidden ? [] : headings(editor.getText());
    ticks.textContent = '';
    card.textContent = '';
    editorBox.classList.toggle('has-outline', list.length > 0);
    outline.style.display = list.length ? '' : 'none';
    if (!list.length) return;

    var top = Math.min.apply(null, list.map(function (h) { return h.level; }));
    list.forEach(function (h, index) {
      var depth = Math.min(h.level - top, SHADES.length - 1);

      var tick = document.createElement('span');
      tick.style.width = TICKS[depth] + 'px';
      ticks.appendChild(tick);

      var item = document.createElement('div');
      item.textContent = h.title;
      item.title = h.title;
      item.className = 'level-' + depth;
      item.style.paddingLeft = (16 + 12 * depth) + 'px';
      // One grey per level, fading from the text colour toward --dim. Opacity
      // rather than color-mix, which the macOS 12 web view lacks.
      item.style.opacity = SHADES[depth];
      item.addEventListener('click', function () { jumpTo(h, index); });
      card.appendChild(item);
    });
    markCurrent();
  }

  /// The section in view: the last heading at or above the top of the note.
  function markCurrent() {
    if (!list.length) return;
    var current = 0;
    var preview = document.getElementById('preview');
    if (preview && !preview.hidden) {
      var line = preview.getBoundingClientRect().top + 8;
      preview.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function (el, i) {
        if (el.getBoundingClientRect().top <= line) current = i;
      });
    } else {
      var rect = editor.view.scrollDOM.getBoundingClientRect();
      var pos = editor.view.posAtCoords({ x: rect.left + 40, y: rect.top + 32 }, false);
      list.forEach(function (h, i) { if (h.offset <= pos) current = i; });
    }
    [ticks.children, card.children].forEach(function (items) {
      for (var i = 0; i < items.length; i++) items[i].classList.toggle('current', i === current);
    });
  }

  function jumpTo(heading, index) {
    var preview = document.getElementById('preview');
    if (preview && !preview.hidden) {
      // ponytail: matched by position, so a setext heading in the preview
      // throws the count off; map by source line if that ever matters.
      var rendered = preview.querySelectorAll('h1, h2, h3, h4, h5, h6')[index];
      if (rendered) rendered.scrollIntoView({ block: 'start' });
      return;
    }
    editor.revealPosition(heading.offset);
    editor.focus();
  }

  function coalesce(work) {
    var queued = false;
    return function () {
      if (outline.hidden || queued) return;
      queued = true;
      requestAnimationFrame(function () {
        queued = false;
        work();
      });
    };
  }
  editor.onDocChange(coalesce(renderOutline));
  var onScroll = coalesce(markCurrent);
  editor.view.scrollDOM.addEventListener('scroll', onScroll);
  var previewBox = document.getElementById('preview');
  if (previewBox) previewBox.addEventListener('scroll', onScroll);

  window.__notesShowOutline = function (on) {
    outline.hidden = !on;
    renderOutline();
  };
  window.__notesOutlineTitles = function () {
    return outline.hidden ? null : headings(editor.getText()).map(function (h) { return h.title; });
  };

  window.__notesFindShow = function () {
    // Seed from the selection, the way a system find bar does.
    var selected = editor.getSelectedText();
    if (selected && selected.indexOf('\n') === -1) input.value = selected;
    bar.classList.add('showing');
    input.focus();
    input.select();
    run(0);
  };

  window.__notesFindHide = function () {
    bar.classList.remove('showing');
    count.textContent = '';
    editor.clearFind();
    editor.focus();
  };

  window.__notesFindNext = function () { run(1); };
  window.__notesFindPrevious = function () { run(-1); };
  window.__notesFindVisible = function () { return bar.classList.contains('showing'); };

  input.addEventListener('input', function () { run(0); });

  input.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') {
      event.preventDefault();
      run(event.shiftKey ? -1 : 1);
    } else if (event.key === 'Escape') {
      event.preventDefault();
      window.__notesFindHide();
    }
  });

  bar.addEventListener('click', function (event) {
    var action = event.target.getAttribute && event.target.getAttribute('data-act');
    if (!action) return;
    if (action === 'next') run(1);
    else if (action === 'prev') run(-1);
    else window.__notesFindHide();
  });
})();
