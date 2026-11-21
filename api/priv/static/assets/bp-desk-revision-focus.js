// bp-desk-revision-focus.js: opening a revision, or the published version,
// while a field has the focus leaves the focus on a named control in the
// pane, never on the page (task-74c8db8d9303dc84).
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
// A focus the person moved away (a click on empty space) is forgotten, so
// nothing takes it back. The patch's own move blurs the field too, while it
// is still enabled, so that is decided once the patch is done.
//
// Loaded by the desk hook (bp-desk.js) from `data-desk-revision-focus`.
(function () {
  "use strict";
  if (window.BarkparkDeskRevisionFocus) return;

  var TABBABLE = "a[href], button, input, select, textarea, [tabindex], [contenteditable=true]";
  var last = null;

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

  function target(pane) {
    return (
      first(pane, '[data-desk-revision][aria-current="true"]') ||
      start(pane) ||
      first(pane.querySelector(".dk-edit-footer"), TABBABLE) ||
      first(pane.querySelector(".dk-title-bar"), '[role="tab"]')
    );
  }

  function locked(el) {
    return el.isConnected && el.matches(":disabled") && !!el.closest("fieldset.dk-readonly-fields:disabled");
  }

  function rescue() {
    var was = last;
    if (!was || !locked(was)) return;
    var active = document.activeElement;
    if (active && active !== document.body && active !== was) return;
    var pane = was.closest('[data-pane-kind="doc"]');
    var el = pane && target(pane);
    if (!el) return;
    last = null;
    el.focus({ preventScroll: true });
  }

  document.addEventListener("focusin", function (e) {
    var el = e.target;
    last = el && el.closest && el.closest('[data-pane-kind="doc"]') ? el : null;
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
