// bp-desk-undo.js: the desk document's undo and redo (F7,
// task-c25c112913859b11), as the TanStack Studio's (DocumentPane.tsx): Mod+Z
// takes back this editor's last own change, Shift+Mod+Z or Mod+Y puts it
// back, across fields, and another editor's words stay. The server keeps
// the changes and writes the undo (`BarkparkWeb.Studio.Desk.DocUndo`).
//
// THE KEY. Mod+Z in a field the server keeps an undo for (the form's
// `data-desk-undo-keys`: free text, a slug, a select, a list, an object,
// and the text inputs and selects nested in them), anywhere else in the
// editing pane that is not an input (its header, a label, a button), or with
// nothing focused, is the document's. Every other input (a url, a number, a
// widget's own box) keeps the browser's own undo: taking the key there
// would undo another field and leave this one's typing with no undo at all.
// Rich text and a canvas keep their own undo: a key one of them took
// (defaultPrevented) or one pressed in a contenteditable is left alone, and
// so is a key in a dialog. The browser's own undo of a kept field (the Edit
// menu, `historyUndo`) is the document's too: the field would otherwise save
// the browser's undo as a new edit, and the next Mod+Z put it back. None of
// it while the editor form is not drawn (its pane folded to a strip, or
// hidden by focus mode or the narrow layout), or while a modal is open: the
// key stays the browser's.
// With nothing focused the key is the document's, as the TanStack Studio's
// Edit-menu undo is: the browser's own undo has nothing to give there once a
// script has set a field's value.
//
// THE PUSH. Typing still in a field's delay is sent first
// (`BarkparkFormLeave`, bp-array-focus.js); the socket keeps order, so the
// undo reads it. `desk-undo` names the document the page shows
// (`BarkparkDocMark`) and goes through the desk's hook (`bpPush`, bp-desk.js).
//
// THE ANSWER. `desk:undone` names the field (a list or an object: its first
// input), its new value and the value it showed (none for a list: the
// server's render draws it). The field takes the new value only while it still shows that one
// (a LiveView patch leaves the focused input alone), the caret goes to the
// end of what changed, and the focus goes into the field, as TanStack's. A
// field on a group tab that was not shown arrives drawn, on its tab, with the
// new value (the server switched the tab first). A field in a folded fieldset
// or object (folded by the schema, or by the user) has its folds opened first.
// A field whose pane was folded to a strip while the undo was on its way has
// the strip opened first, as a click on it does.
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-undo`).
(function () {
  "use strict";

  if (window.BarkparkDeskUndo) return;

  var TEXT = /^(text|search|url|tel|password)$/;

  function form() {
    var f = document.getElementById("editor-form");
    var desk = document.getElementById("desk-panes");
    return f && desk && desk.contains(f) ? f : null;
  }

  var FIELD = /^(INPUT|TEXTAREA|SELECT)$/;

  // Whether `el` is a field of one the server keeps an undo for (its own
  // input, or one nested in it: an object's, a list item's), and one the
  // user can write in now (a read-only one is the browser's).
  function kept(f, el) {
    if (el.readOnly || el.disabled) return false;
    var keys = (f.getAttribute("data-desk-undo-keys") || "").split(/\s+/);
    var top = /^doc\[[^\]]+\]/.exec(el.name || "");
    return valued(el) && !!top && keys.indexOf(top[0]) !== -1;
  }

  // A field whose value the user types or picks: a text input, a textarea,
  // a select.
  function valued(el) {
    return el.tagName === "TEXTAREA" || el.tagName === "SELECT" || (el.tagName === "INPUT" && TEXT.test(el.type));
  }

  // Whether `el` is drawn where the user can see it: not in a pane folded to
  // a strip (`data-pane-collapsed`), not under a hidden pane or panel, not in
  // a shut fold, and not under anything else display:none.
  function drawn(el) {
    if (!el || !el.closest || el.closest("[data-pane-collapsed], [hidden]")) return false;
    if (folds(el).length) return false;
    return typeof el.checkVisibility !== "function" || el.checkVisibility();
  }

  // Whether a modal is open anywhere in the page (Delete, Unpublish: a
  // `role=dialog aria-modal=true`, or a <dialog> opened with showModal): the
  // page under it is not the user's to change, so the key stays the browser's.
  function modal() {
    var all = document.querySelectorAll('[role=dialog][aria-modal=true], dialog[open]');
    for (var i = 0; i < all.length; i++) {
      var m = all[i];
      if (m.closest("[hidden]")) continue;
      if (m.tagName === "DIALOG" && m.getAttribute("aria-modal") !== "true" && !isModal(m)) continue;
      if (typeof m.checkVisibility === "function" && !m.checkVisibility()) continue;
      return true;
    }
    return false;
  }

  function isModal(dialog) {
    try {
      return dialog.matches(":modal");
    } catch (_) {
      return false;
    }
  }

  // Whether a key or a browser undo at `el` is the document's. Never while the
  // editor form is not drawn (its pane a strip, or hidden): the change would
  // land out of sight, and the browser keeps the key, as with no desk undo.
  function ours(el) {
    var f = form();
    if (!f || !drawn(f) || modal()) return false;
    if (!el || el === document.body || el === document.documentElement) return true;
    if (!el.closest || el.isContentEditable) return false;
    if (el.closest("[contenteditable], bp-paper-canvas, dialog")) return false;
    if (FIELD.test(el.tagName)) return f.contains(el) && kept(f, el);
    if (f.contains(el)) return true;
    var pane = el.closest("[data-pane-editing]");
    return !!pane && pane.contains(f);
  }

  function run(redo) {
    var desk = document.getElementById("desk-panes");
    if (!desk || typeof desk.bpPush !== "function") return;
    if (typeof window.BarkparkFormLeave === "function") window.BarkparkFormLeave();
    var mark = typeof window.BarkparkDocMark === "function" ? window.BarkparkDocMark() : "";
    desk.bpPush("desk-undo", { redo: redo, _bp_doc: mark });
  }

  function onKey(e) {
    if (e.defaultPrevented || e.altKey || e.isComposing || !(e.metaKey || e.ctrlKey)) return;
    var key = String(e.key).toLowerCase();
    if (key !== "z" && key !== "y") return;
    if (!ours(e.target)) return;
    e.preventDefault();
    run(key === "y" || e.shiftKey);
  }

  function onBeforeInput(e) {
    if (e.inputType !== "historyUndo" && e.inputType !== "historyRedo") return;
    var f = form();
    if (!f || !e.target || !f.contains(e.target) || !ours(e.target)) return;
    e.preventDefault();
    run(e.inputType === "historyRedo");
  }

  function lf(text) {
    return String(text).replace(/\r\n?/g, "\n");
  }

  // Where the change between `was` and `now` ends in `now`.
  function end(was, now) {
    var p = 0;
    while (p < was.length && p < now.length && was[p] === now[p]) p++;
    var s = 0;
    while (s < was.length - p && s < now.length - p && was[was.length - 1 - s] === now[now.length - 1 - s]) s++;
    return now.length - s;
  }

  // The title button of a fold (a fieldset, or an object, folded by it).
  function toggleOf(fold) {
    for (var c = fold.firstElementChild; c; c = c.nextElementSibling) {
      if (c.tagName !== "LEGEND") continue;
      for (var b = c.firstElementChild; b; b = b.nextElementSibling) {
        if (b.classList && b.classList.contains("object-toggle")) return b;
      }
    }
    return null;
  }

  // The shut folds around `el`, outermost first: a fieldset or an object
  // folded by its title button (`Desk.Fieldsets`: the state is the button's
  // `aria-expanded`, kept in the page), and a closed <details>.
  function folds(el) {
    var shut = [];
    for (var n = el.parentElement; n && n !== document.body; n = n.parentElement) {
      if (n.tagName === "DETAILS" && !n.open) shut.unshift(n);
      if (n.tagName === "FIELDSET" && n.hasAttribute("data-collapsible")) {
        var t = toggleOf(n);
        if (t && t.getAttribute("aria-expanded") === "false") shut.unshift(t);
      }
    }
    return shut;
  }

  // A strip is 52 px drawn (bp-desk.js `STRIP_DRAWN`); a pane this narrow or
  // narrower is one, whatever its attributes say yet.
  var STRIP_MAX = 60;

  // Opens the pane around `el` when it is folded to a strip (it may have
  // folded while the undo was on its way), as a click on the strip does
  // (bp-desk.js `_openStrip`, which opens only a pane marked a strip). The
  // patch that brings the answer drops that mark until the desk lays the
  // panes out again, so a pane drawn a strip wide is marked again first.
  function unstrip(el) {
    var pane = el.closest("#desk-panes > [data-pane-index]");
    if (!pane) return;
    var wide = pane.getBoundingClientRect().width;
    if (wide > 0 && wide <= STRIP_MAX) pane.setAttribute("data-pane-collapsed", "");
    if (pane.hasAttribute("data-pane-collapsed")) pane.click();
  }

  // Opens every fold around `el`, a fold by its own button, so LiveView's fold
  // command runs as on a click.
  function unfold(el) {
    folds(el).forEach(function (f) {
      if (f.tagName === "DETAILS") f.open = true;
      else f.click();
    });
  }

  // The input the answer names; for a list, or an object with no input of
  // its own, the first input inside it.
  function named(f, field) {
    var el = f.elements.namedItem(field);
    if (el && el.tagName) return el;
    return f.querySelector('[name^="' + field.replace(/"/g, '\\"') + '["]');
  }

  function onUndone(e) {
    var d = (e && e.detail) || {};
    var f = form();
    var el = f && typeof d.field === "string" ? named(f, d.field) : null;
    if (!el || !el.tagName || typeof el.focus !== "function") return;
    var text = valued(el);
    var set = text && typeof d.value === "string" && typeof d.was === "string" && lf(el.value) === lf(d.was);
    if (set) el.value = d.value;
    unstrip(el);
    unfold(el);
    if (document.activeElement !== el) el.focus();
    // Drawn with the new value already (the undo switched to its tab): the
    // caret still goes to the change.
    if (set || (text && typeof d.value === "string" && typeof d.was === "string" && lf(el.value) === lf(d.value))) {
      var at = end(lf(d.was), lf(d.value));
      if (typeof el.setSelectionRange === "function") {
        try {
          el.setSelectionRange(at, at);
        } catch (_) {
          // A type with no caret.
        }
      }
    }
  }

  document.addEventListener("keydown", onKey);
  document.addEventListener("beforeinput", onBeforeInput, true);
  window.addEventListener("phx:desk:undone", onUndone);
  window.BarkparkDeskUndo = { onKey: onKey, onUndone: onUndone, ours: ours, unfold: unfold, drawn: drawn, unstrip: unstrip };
})();
