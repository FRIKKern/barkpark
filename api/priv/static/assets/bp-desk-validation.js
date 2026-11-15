// The desk's Validation panel: the jump to a problem's field
// (`BarkparkWeb.Studio.Desk.ValidationPanel`, the TanStack Studio's `goTo`).
//
// A problem's button dispatches `desk:goto-field` with the field's path. The
// same press may have asked the server for the field's group, so the field
// may not be drawn yet: the jump waits for it (5 s at most), opens every
// folded fieldset or object it sits in, and puts the focus on it.
//
// A fold is opened by pressing its own title button, never by setting the
// attribute here: the button's LiveView command is what keeps the fold open
// across the next patch.
//
// A field inside an array item that the form does not draw by that path
// falls back to what it sits in that is drawn: the item, then the array.
(function () {
  "use strict";
  if (window.BarkparkDeskValidation) return;

  var FOCUSABLE = "input:not([type=hidden]):not([disabled]), textarea:not([disabled]), select:not([disabled]), button:not([disabled]), [contenteditable=true], [tabindex]:not([tabindex='-1'])";
  var WAIT_MS = 5000;
  var STEP_MS = 50;
  var jump = 0;

  // The pane that edits: the form's fields are in it.
  function pane() {
    return document.querySelector("[data-pane-editing]") || document;
  }

  function byId(id) {
    var found = pane().querySelectorAll("[id]");
    for (var i = 0; i < found.length; i++) if (found[i].id === id) return found[i];
    return null;
  }

  // `links[_key=="l1"].url`, then `links[_key=="l1"]`, then `links`.
  function shorter(path) {
    var cut = Math.max(path.lastIndexOf("."), path.lastIndexOf("["));
    return cut > 0 ? path.slice(0, cut) : "";
  }

  // The field, or the nearest thing it sits in that the form draws by its
  // path. A field with nothing around it drawn is not drawn yet: null.
  function fieldEl(path) {
    for (var at = path; at; at = shorter(at)) {
      var el = byId(at);
      if (el) return el;
    }
    return null;
  }

  // Each folded fieldset or object around `el`, outermost first.
  function open(el) {
    var folds = [];
    for (var node = el.parentElement; node; node = node.parentElement) {
      if (node.matches && node.matches("fieldset[data-collapsible]")) folds.unshift(node);
    }
    folds.forEach(function (fold) {
      var toggle = fold.querySelector(":scope > legend > .object-toggle");
      if (toggle && toggle.getAttribute("aria-expanded") === "false") toggle.click();
    });
  }

  function focusIn(el) {
    var target = el.matches(FOCUSABLE) ? el : el.querySelector(FOCUSABLE) || el;
    if (target === el && !el.matches(FOCUSABLE) && !el.hasAttribute("tabindex")) el.setAttribute("tabindex", "-1");
    target.focus();
    if (target.scrollIntoView) target.scrollIntoView({block: "nearest"});
    return document.activeElement === target;
  }

  function goTo(path) {
    var mine = ++jump;
    var started = Date.now();
    var step = function () {
      // A later jump, or a field that never came: this one is over.
      if (mine !== jump) return;
      var el = fieldEl(path);
      if (el) {
        open(el);
        if (focusIn(el)) return;
      }
      if (Date.now() - started < WAIT_MS) setTimeout(step, STEP_MS);
    };
    step();
  }

  window.addEventListener("desk:goto-field", function (e) {
    var path = e.detail && e.detail.path;
    if (typeof path === "string" && path) goTo(path);
  });

  window.BarkparkDeskValidation = {goTo: goTo};
})();
