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
  // same surface as the status bar it sits above. Styles are in bridge.css.

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
  // keeps its full width. editor.headings() decides what is a heading.

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

  var SHADES = [1, 0.72, 0.54, 0.42];
  var TICKS = [18, 13, 9, 6];
  var list = [];

  function renderOutline() {
    list = outline.hidden ? [] : editor.headings();
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
      // The outline and the preview come from the same parser, so the nth
      // heading in one is the nth in the other.
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
    return outline.hidden ? null : editor.headings().map(function (h) { return h.title; });
  };

  // ---------------------------------------------------------- save or discard
  //
  // The app asks before closing a tab with words that would otherwise be lost;
  // the answer goes back as "save", "discard" or "cancel". Return saves, Escape
  // cancels, Cmd+Delete discards — the keys a system sheet would use.

  var ask = document.createElement('div');
  ask.className = 'notes-ask';
  ask.hidden = true;
  ask.innerHTML =
    '<div class="notes-ask-card" role="alertdialog" aria-modal="true">'
    + '<div class="title"></div>'
    + '<div class="detail"></div>'
    + '<div class="buttons">'
    + '<button type="button" class="discard" data-choice="discard">Discard</button>'
    + '<span class="spacer"></span>'
    + '<button type="button" data-choice="cancel">Cancel</button>'
    + '<button type="button" class="primary" data-choice="save">Save</button>'
    + '</div></div>';
  document.body.appendChild(ask);
  var askTitle = ask.querySelector('.title');
  var askDetail = ask.querySelector('.detail');
  var askSave = ask.querySelector('[data-choice="save"]');
  var askHideTimer = null;

  function askShowing() { return ask.classList.contains('showing'); }

  function hideAsk() {
    ask.classList.remove('showing');
    clearTimeout(askHideTimer);
    askHideTimer = setTimeout(function () { if (!askShowing()) ask.hidden = true; }, 160);
    editor.focus();
  }

  function answer(choice) {
    if (!askShowing()) return;
    hideAsk();
    window.webkit.messageHandlers.closeChoice.postMessage(choice);
  }

  window.__notesAskToClose = function (title, detail) {
    askTitle.textContent = title;
    askDetail.textContent = detail;
    clearTimeout(askHideTimer);
    ask.hidden = false;
    void ask.offsetWidth;  // start the fade from the hidden state
    ask.classList.add('showing');
    askSave.focus();
  };

  // The app withdraws the question when the tab it was about stops being
  // the one in front.
  window.__notesDismissAsk = function () { if (askShowing()) hideAsk(); };
  window.__notesAskVisible = askShowing;

  ask.addEventListener('mousedown', function (event) {
    if (event.target === ask) answer('cancel');
  });
  ask.addEventListener('click', function (event) {
    var choice = event.target.getAttribute && event.target.getAttribute('data-choice');
    if (choice) answer(choice);
  });
  document.addEventListener('keydown', function (event) {
    if (!askShowing()) return;
    var choice = null;
    if (event.key === 'Escape') choice = 'cancel';
    else if (event.key === 'Backspace' && event.metaKey) choice = 'discard';
    else if (event.key === 'Enter') {
      choice = (document.activeElement && document.activeElement.getAttribute('data-choice')) || 'save';
    }
    if (!choice) return;
    event.preventDefault();
    event.stopPropagation();
    answer(choice);
  }, true);

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
