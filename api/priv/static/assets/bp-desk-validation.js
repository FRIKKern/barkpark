// The desk's Validation panel: the jump to a problem's field, and where the
// focus goes when the panel closes
// (`BarkparkWeb.Studio.Desk.ValidationPanel`, the TanStack Studio's `goTo`).
//
// THE JUMP. A problem's button dispatches `desk:goto-field` with the field's
// path, and the row's index when the field sits in an array item. The same
// press may have asked the server for the field's group, so the field may
// not be drawn yet: the jump waits until it is (5 s at most, and only while
// the same document is open). Then, once: every folded fieldset, object and
// array row around it is opened, and the focus goes to it.
//
// A fold is opened by pressing its own title button, never by setting the
// attribute here: the button's LiveView command is what keeps the fold open
// across the next patch. An array row is a <details>, opened by its `open`.
//
// A field inside an array item is looked for in its row: by the path as its
// id, else by the field's name at the end of an input's id. With no such
// input the focus goes to the row's summary, and with no such row to the
// array's add button. Nothing hidden is ever asked to take the focus.
//
// UNDER 600 PX the panel covers the form, so the jump closes the panel first
// (its own close button) and then focuses the field.
//
// THE CLOSE. The close button dispatches `desk:validation-close`. Once the
// panel is gone the focus goes to the header's Validation button; that
// button is not drawn for a document with no problem, so then to the field
// last jumped to, else the "Show document actions" button, else the form's
// first field. Never the page's body.
//
// THE WORDS. The pane's status region carries what a screen reader should
// hear (`data-desk-validation-status`); they are written into it only when
// they change, so opening a document says nothing.
(function () {
  "use strict";
  if (window.BarkparkDeskValidation) return;

  var FOCUSABLE = "input:not([type=hidden]):not([disabled]), textarea:not([disabled]), select:not([disabled]), button:not([disabled]), summary, [contenteditable=true], [tabindex]:not([tabindex='-1'])";
  var WAIT_MS = 5000;
  var STEP_MS = 50;
  var jump = 0;
  var lastField = null;
  var quiet = false;

  // The pane that edits: the form's fields are in it.
  function pane() {
    return document.querySelector("[data-pane-editing]") || document;
  }

  function byId(id) {
    var found = pane().querySelectorAll("[id]");
    for (var i = 0; i < found.length; i++) if (found[i].id === id) return found[i];
    return null;
  }

  function shown(el) {
    return !!el && el.isConnected && el.getClientRects().length > 0;
  }

  // The first thing in `el` (or `el`) that is drawn and takes the focus.
  function focusable(el) {
    if (!el) return null;
    if (el.matches(FOCUSABLE) && shown(el)) return el;
    var inside = el.querySelectorAll(FOCUSABLE);
    for (var i = 0; i < inside.length; i++) if (shown(inside[i])) return inside[i];
    return null;
  }

  // Every folded fieldset or object, and every closed array row, around `el`.
  function open(el) {
    var around = [];
    for (var node = el; node; node = node.parentElement) around.unshift(node);
    around.forEach(function (node) {
      if (!node.matches) return;
      if (node.matches("details") && node !== el.closest("details[data-add-member-menu]")) node.open = true;
      if (node.matches("fieldset[data-collapsible]")) {
        var toggle = node.querySelector(":scope > legend > .object-toggle");
        if (toggle && toggle.getAttribute("aria-expanded") === "false") toggle.click();
      }
    });
  }

  // What the jump aims at, in order of preference, or null while nothing of
  // the field is drawn yet. `item`: the row's index in its array.
  function targets(path, item) {
    var exact = byId(path);
    if (exact) return [exact];
    var cut = path.indexOf("[");
    if (cut < 0) return null;
    var list = byId(path.slice(0, cut));
    if (!list) return null;
    var name = path.slice(path.lastIndexOf(".") + 1);
    var rows = list.querySelectorAll("details.bp-array-item");
    var row = null;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].getAttribute("data-row-index") === String(item)) {
        row = rows[i];
        break;
      }
    }
    var field = null;
    if (row && path.indexOf("].") > 0) {
      var inputs = row.querySelectorAll("input:not([type=hidden]), textarea, select");
      for (var j = 0; j < inputs.length; j++) {
        if (inputs[j].id.slice(-name.length - 1) === "-" + name) {
          field = inputs[j];
          break;
        }
      }
    }
    var add = (list.closest(".field") || list.parentElement || list).querySelector(".bp-array-btn-add, [data-add-member-menu] > summary, button[phx-value-op='add']");
    return [field, row && row.querySelector(":scope > summary"), add, list].filter(Boolean);
  }

  function focusOn(list) {
    for (var i = 0; i < list.length; i++) {
      open(list[i]);
      var el = focusable(list[i]);
      if (el) {
        el.focus();
        if (document.activeElement === el) {
          if (el.scrollIntoView) el.scrollIntoView({block: "nearest"});
          lastField = el;
          return true;
        }
      }
    }
    return false;
  }

  function narrow() {
    return window.matchMedia("(max-width: 599px)").matches;
  }

  function panel() {
    return document.querySelector("aside[data-desk-validation]");
  }

  // Runs `then` once `ready()` answers something, for as long as the same
  // document is in the editing pane and no later jump has started.
  function wait(ready, then) {
    var mine = ++jump;
    var doc = pane().getAttribute && pane().getAttribute("data-pane");
    var started = Date.now();
    var step = function () {
      if (mine !== jump) return;
      if ((pane().getAttribute && pane().getAttribute("data-pane")) !== doc) return;
      var got = ready();
      if (got) return then(got);
      if (Date.now() - started < WAIT_MS) setTimeout(step, STEP_MS);
    };
    step();
  }

  function goTo(path, item) {
    wait(
      function () {
        return targets(path, item);
      },
      function (found) {
        var close = narrow() && panel() && panel().querySelector("[data-desk-validation-close]");
        if (!close) return focusOn(found);
        // The panel covers the form: it closes, then the field is focused.
        quiet = true;
        close.click();
        wait(
          function () {
            return !panel();
          },
          function () {
            quiet = false;
            focusOn(targets(path, item) || found);
          }
        );
      }
    );
  }

  // The panel is closing: once it is gone, the focus is somewhere drawn.
  function closed(buttonId) {
    if (quiet) return;
    wait(
      function () {
        return !panel();
      },
      function () {
        var active = document.activeElement;
        if (active && active !== document.body && shown(active)) return;
        var root = pane();
        var places = [
          byId(buttonId),
          shown(lastField) ? lastField : null,
          root.querySelector(".pane-header [id$='-actions-button']"),
          root.querySelector("#editor-form"),
          root.querySelector(".pane-header"),
        ];
        for (var i = 0; i < places.length; i++) {
          var el = focusable(places[i]);
          if (el) {
            el.focus();
            if (document.activeElement === el) return;
          }
        }
      }
    );
  }

  window.addEventListener("desk:goto-field", function (e) {
    var detail = e.detail || {};
    if (typeof detail.path === "string" && detail.path) goTo(detail.path, detail.item);
  });

  window.addEventListener("desk:validation-close", function (e) {
    closed((e.detail && e.detail.button) || "");
  });

  // The errors changed: the pane's status region says the new words. A
  // document that opens brings a new region, which says nothing.
  new MutationObserver(function (changes) {
    changes.forEach(function (change) {
      var el = change.target;
      if (el.getAttribute("role") === "status") el.textContent = el.getAttribute("data-desk-validation-status") || "";
    });
  }).observe(document.documentElement, {subtree: true, attributes: true, attributeFilter: ["data-desk-validation-status"]});

  window.BarkparkDeskValidation = {goTo: goTo, closed: closed};
})();
