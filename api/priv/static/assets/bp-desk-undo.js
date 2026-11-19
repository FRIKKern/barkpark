// bp-desk-undo.js: the desk document's undo and redo (F7,
// task-c25c112913859b11), as the TanStack Studio's (DocumentPane.tsx): Mod+Z
// takes back this editor's last own change, Shift+Mod+Z or Mod+Y puts it
// back, across fields, and another editor's words stay. The server keeps
// the changes and writes the undo (`BarkparkWeb.Studio.Desk.DocUndo`).
//
// THE KEY. Mod+Z in the editor form, or anywhere in the editing pane that is
// not a field of its own (its header, a label), or with nothing focused, is
// the document's. Rich text and a canvas keep their own undo: a key one of
// them took (defaultPrevented) or one pressed in a contenteditable is left
// alone, and so is a key in a dialog. The browser's own undo of a field (the
// Edit menu, `historyUndo`) is the document's too: the field would otherwise
// save the browser's undo as a new edit, and the next Mod+Z put it back.
//
// THE PUSH. Typing still in a field's delay is sent first
// (`BarkparkFormLeave`, bp-array-focus.js); the socket keeps order, so the
// undo reads it. `desk-undo` names the document the page shows
// (`BarkparkDocMark`) and goes through the desk's hook (`bpPush`, bp-desk.js).
//
// THE ANSWER. `desk:undone` names the field, its new value and the value it
// showed. The field takes the new value only while it still shows that one
// (a LiveView patch leaves the focused input alone), the caret goes to the
// end of what changed, and the focus goes into the field, as TanStack's.
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

  // Whether a key or a browser undo at `el` is the document's.
  function ours(el) {
    var f = form();
    if (!f) return false;
    if (!el || el === document.body || el === document.documentElement) return true;
    if (!el.closest || el.isContentEditable) return false;
    if (el.closest("[contenteditable], bp-paper-canvas, dialog")) return false;
    if (f.contains(el)) return true;
    var pane = el.closest("[data-pane-editing]");
    return !!pane && pane.contains(f) && !/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName);
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

  function onUndone(e) {
    var d = (e && e.detail) || {};
    var f = form();
    var el = f && typeof d.field === "string" ? f.elements.namedItem(d.field) : null;
    if (!el || !el.tagName || typeof el.focus !== "function") return;
    var text = el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && TEXT.test(el.type));
    var set = text && typeof d.value === "string" && typeof d.was === "string" && lf(el.value) === lf(d.was);
    if (set) el.value = d.value;
    if (document.activeElement !== el) el.focus();
    if (set) {
      var at = end(lf(d.was), lf(d.value));
      try {
        el.setSelectionRange(at, at);
      } catch (_) {
        // A type with no caret.
      }
    }
  }

  document.addEventListener("keydown", onKey);
  document.addEventListener("beforeinput", onBeforeInput, true);
  window.addEventListener("phx:desk:undone", onUndone);
  window.BarkparkDeskUndo = { onKey: onKey, onUndone: onUndone, ours: ours };
})();
