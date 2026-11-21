// bp-desk-revision-focus.js: opening a revision, or the published version,
// while a field has the focus, and going Back from one, leave the focus on a
// named control in the pane, never on the page (task-74c8db8d9303dc84,
// task-8fe9bc3aa4437be6).
//
// The read-only form keeps the live form's ids, so LiveView's morphdom moves
// the focused input into the read-only fields' disabled fieldset
// (`ReadonlyFields`). A disabled input cannot hold the focus: Chrome drops
// it to the page, and LiveView's own restore after the patch cannot focus it
// again. A browser Forward or Back onto a revision, or any patch that draws
// one while a field is focused, did this. A click on a History entry does
// not: the entry keeps the focus.
//
// After each LiveView patch (`phx:update`, sent once LiveView has restored
// the focus), a field that had the focus and now sits disabled in that
// fieldset, with the focus on the page or still on it (a fieldset disabled
// in place lets go of it only at the next rendering), hands the focus to
// its pane, in this order:
//   1. the History panel's current entry, where a click on it leaves the focus;
//   2. where opening a document puts the focus (`formStart`, bp-tab-keys.js,
//      the TanStack Studio's `focusIntoForm`): the field groups' first tab,
//      All fields, which still switches;
//   3. the footer's first control: Revert to revision on a revision (it
//      only opens its confirm);
//   4. the pane's Editor tab.
// A patch can also remove the focused control: Back from a revision or the
// published view to the live document drops Revert to revision or Unpublish,
// and Back onto another document's revision drops that document's fields.
// The focus then falls to the page. After that patch the pane the control
// was in, or the one drawn in its place, takes the focus where the TanStack
// Studio's `focusIntoForm` puts it as a document opens: `formStart`, then the
// footer's first control, then the pane's Editor tab
// (task-8fe9bc3aa4437be6).
//
// A focus the person moved away (a click on empty space) is forgotten, so
// nothing takes it back. The patch's own move blurs the field too, while it
// is still enabled, so that is decided once the patch is done.
//
// Loaded by the desk hook (bp-desk.js) from `data-desk-revision-focus`.
(function () {
  "use strict";
  if (window.BarkparkDeskRevisionFocus) return;

  var TABBABLE = "a[href], button, input, select, textarea, [tabindex], [contenteditable=true]";
  var PANE = '[data-pane-kind="doc"]';
  var last = null;
  var lastPane = null;
  var lastAt = { key: null, index: null };

  // Drawn and seen: the shell's own header controls are kept in the desk's
  // form but hidden.
  function shown(el) {
    if (el.closest("[hidden], [inert]")) return false;
    if (el.checkVisibility) return el.checkVisibility({ visibilityProperty: true });
    return el.getClientRects().length > 0;
  }

  function takes(el) {
    return !el.matches(":disabled") && el.tabIndex >= 0 && shown(el);
  }

  function first(scope, selector) {
    if (!scope) return null;
    var found = scope.querySelectorAll(selector);
    for (var i = 0; i < found.length; i++) if (takes(found[i])) return found[i];
    return null;
  }

  function start(pane) {
    var keys = window.BarkparkTabKeys;
    var el = keys && keys.formStart ? keys.formStart(pane) : null;
    return el && takes(el) ? el : null;
  }

  // Where opening a document puts the focus, as `focusIntoForm`.
  function opening(pane) {
    return (
      start(pane) ||
      first(pane.querySelector(".dk-edit-footer"), TABBABLE) ||
      first(pane.querySelector(".dk-title-bar"), '[role="tab"]')
    );
  }

  function target(pane) {
    return first(pane, '[data-desk-revision][aria-current="true"]') || opening(pane);
  }

  function locked(el) {
    return el.isConnected && el.matches(":disabled") && !!el.closest("fieldset.dk-readonly-fields:disabled");
  }

  // The pane the removed control was in, or the one drawn in its place: the
  // same document's, else the one at the same place in the row of panes.
  function paneNow() {
    if (lastPane && lastPane.isConnected && lastPane.getAttribute("data-pane") === lastAt.key) return lastPane;
    var panes = Array.prototype.slice.call(document.querySelectorAll(PANE));
    var same = function (name, value) {
      return panes.filter(function (p) {
        return value !== null && p.getAttribute(name) === value;
      })[0];
    };
    return same("data-pane", lastAt.key) || same("data-pane-index", lastAt.index) || null;
  }

  function rescue() {
    var was = last;
    if (!was) return;
    var active = document.activeElement;
    var free = !active || active === document.body;
    var pane, el;
    if (locked(was)) {
      if (!free && active !== was) return;
      pane = was.closest(PANE);
      el = pane && target(pane);
    } else if (!was.isConnected) {
      if (!free) return;
      pane = paneNow();
      el = pane && opening(pane);
    } else return;
    if (!el) return;
    last = null;
    el.focus({ preventScroll: true });
  }

  document.addEventListener("focusin", function (e) {
    var el = e.target;
    var pane = el && el.closest ? el.closest(PANE) : null;
    last = pane ? el : null;
    lastPane = pane;
    lastAt = pane ? { key: pane.getAttribute("data-pane"), index: pane.getAttribute("data-pane-index") } : { key: null, index: null };
  });
  document.addEventListener("focusout", function (e) {
    // Moved away by the person: once this task is done, the field is still
    // in the page, enabled, and not focused again.
    var el = e.target;
    if (el !== last || e.relatedTarget) return;
    setTimeout(function () {
      if (last === el && el.isConnected && !el.matches(":disabled") && document.activeElement !== el) last = null;
    }, 0);
  });
  document.addEventListener("phx:update", rescue);

  window.BarkparkDeskRevisionFocus = { rescue: rescue, target: target };
})();
