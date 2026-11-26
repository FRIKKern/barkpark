// bp-desk-leave.js: the browser half of the desk's question before it
// leaves a document with a held field (`Desk.LeaveGuard`,
// task-33cbb6269c8823ad).
//
// A LINK. While the edit pane says a field is held (`data-desk-held`), a
// plain click on a link to another place on this site is held back before
// the URL moves and sent to the server (`desk-leave`, through the desk's hook,
// `bpPush`), which lets it go or asks in the desk's own dialog. On the
// document's capture, so LiveView's link handler (window) never sees it.
// Not held back:
//   - a link in the editor form, rich text above all: a click there places
//     the caret, it opens nothing (the server still asks over any patch
//     that puts the document away, `DeskLive.handle_params/3`);
//   - the dialog's own Leave (`data-desk-leave-go`): it marks the desk's
//     root as leaving, so the tab's `beforeunload` (bp-desk.js) does not
//     ask a second time;
//   - a modified click, a new tab, another site, the same page.
// A link in an open modal dialog (a search hit) closes that dialog first,
// else the question would open under it, out of the mouse's reach.
//
// STAY. The server says `bp:desk-leave-stayed` (LiveView sends a pushed
// event to window too). What the click left is put back: the search dialog
// it closed, with what was typed, or else the caret where it was in the
// form (a field's offsets, or a rich text's character offset: its nodes
// may be redrawn), and the pane's scroll.
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-leave`).
(function () {
  "use strict";

  if (window.BarkparkDeskLeave) return;

  var ROOT = "#desk-panes";
  var PANE = "[data-pane-editing]";
  // What a held-back click left: the dialog it closed, the pane's scroll.
  var left = null;
  // Where the caret was in the form.
  var field = null;

  function plainClick(e) {
    return e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey && !e.defaultPrevented;
  }

  function deskRoot(doc) {
    return doc.querySelector(ROOT);
  }

  function editable(el) {
    return !!(el.isContentEditable || el.closest('[contenteditable]:not([contenteditable="false"])'));
  }

  // The pane's scrolled boxes, with where each was.
  function scrolls(pane) {
    var out = [];
    if (!pane) return out;
    [pane].concat(Array.prototype.slice.call(pane.querySelectorAll("*"))).forEach(function (el) {
      if (el.scrollTop || el.scrollLeft) out.push([el, el.scrollTop, el.scrollLeft]);
    });
    return out;
  }

  function onClick(e) {
    var link = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!link || !plainClick(e) || link.target === "_blank") return;
    var root = deskRoot(link.ownerDocument);
    if (!root) return;
    if (link.hasAttribute("data-desk-leave-go")) {
      root.bpLeaving = true;
      return;
    }
    if (editable(link) || link.closest("#editor-form")) return;
    var pane = root.querySelector(PANE + "[data-desk-held]");
    if (!pane || !root.bpPush) return;
    var to = new URL(link.href, window.location.href), at = window.location;
    if (to.origin !== at.origin || (to.pathname === at.pathname && to.search === at.search)) return;
    // A "//" path is not one the server takes as this site's
    // (`LeaveGuard.local?/1`): the browser follows it (task-5455fd7fe69eb386).
    if (to.pathname.slice(0, 2) === "//") return;
    e.preventDefault();
    e.stopImmediatePropagation();
    var dialog = link.closest("dialog[open]");
    left = { dialog: dialog, scroll: scrolls(pane) };
    if (dialog && dialog.close) dialog.close();
    root.bpPush("desk-leave", { href: to.pathname + to.search + to.hash, kind: link.getAttribute("data-phx-link") || "" });
  }

  function noteField(e) {
    var doc = e.target && e.target.ownerDocument ? e.target.ownerDocument : document;
    var el = e.type === "focusout" ? e.target : doc.activeElement;
    var root = deskRoot(doc);
    if (!root || !el || !el.closest || !root.contains(el) || !el.closest(PANE + " #editor-form")) return;
    if (!editable(el)) {
      field = { el: el, start: el.selectionStart, end: el.selectionEnd };
      return;
    }
    var sel = doc.getSelection ? doc.getSelection() : null;
    if (!sel || !sel.rangeCount || !el.contains(sel.anchorNode)) return;
    var r = sel.getRangeAt(0).cloneRange();
    r.setStart(el, 0);
    field = { el: el, at: r.toString().length };
  }

  function caret(doc) {
    var f = field, el = f && (f.el.isConnected ? f.el : f.el.id && doc.getElementById(f.el.id));
    if (!el) return;
    el.focus({ preventScroll: true });
    if (f.at == null) {
      if (el.setSelectionRange && typeof f.start === "number") el.setSelectionRange(f.start, f.end);
      return;
    }
    var w = doc.createTreeWalker(el, 4), n, rest = f.at; // 4: text nodes
    while ((n = w.nextNode()) && rest > n.length) rest -= n.length;
    if (n) doc.getSelection().collapse(n, rest);
  }

  function stayed() {
    var was = left, doc = document;
    left = null;
    window.requestAnimationFrame(function () {
      if (was) {
        was.scroll.forEach(function (s) {
          if (!s[0].isConnected) return;
          s[0].scrollTop = s[1];
          s[0].scrollLeft = s[2];
        });
      }
      var dialog = was && was.dialog;
      if (dialog && dialog.isConnected && !dialog.open && dialog.showModal) {
        dialog.showModal();
        var box = dialog.querySelector("input");
        if (box) box.focus();
        return;
      }
      caret(doc);
    });
  }

  document.addEventListener("click", onClick, true);
  document.addEventListener("focusout", noteField, true);
  document.addEventListener("selectionchange", noteField);
  window.addEventListener("phx:bp:desk-leave-stayed", stayed);

  window.BarkparkDeskLeave = { onClick: onClick, stayed: stayed };
})();
