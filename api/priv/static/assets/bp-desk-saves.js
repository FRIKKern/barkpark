// bp-desk-saves.js — window.__savesPending(): whether an edit of this page is
// still on its way to the server.
//
// The TanStack Studio has the same function (lib/edits.ts). Its e2e rig asks
// it before it resets the fixture documents (e2e/rig/targets.ts,
// closeAndSettle and savesLanded), so a test's last save cannot land after
// the reset and leave a draft behind. It only reports: nothing here sends,
// holds or changes a save.
//
// True while
//   - a field of the document (an input named doc[...] in form#editor-form)
//     was typed in and its change is not yet sent (the field's phx-debounce
//     has not fired), or
//   - any event is sent and not yet answered: LiveView marks the element an
//     event came from (the form for an autosave, a button for a click, a
//     hook's element for its pushEvent) with data-phx-ref-loading until the
//     reply.
// A save the server refused does not count: no wait ends it.
//
// What it cannot see: a save the server starts after its reply. The image
// and reference pickers save that way (`{:autosave_form, form}`), so the
// function can turn false a moment before that write lands.
//
// A document-level listener, no phx-hook (the bp-array-focus.js pattern).
(function () {
  "use strict";

  var LOADING = "data-phx-ref-loading";
  // The form a doc[...] field was typed in, until that form sends a change.
  // A change carries the whole form, so its going out pays all that was typed.
  var typedIn = null;

  document.addEventListener("input", function (e) {
    var t = e.target;
    var form = t && t.closest ? t.closest("form#editor-form") : null;
    if (form && typeof t.name === "string" && t.name.indexOf("doc[") === 0) typedIn = form;
  }, true);

  new window.MutationObserver(function (changes) {
    changes.forEach(function (change) {
      if (change.target === typedIn && typedIn.hasAttribute(LOADING)) typedIn = null;
    });
  }).observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: [LOADING] });

  window.__savesPending = function () {
    // A form that left the page (another document opened) owes nothing here.
    if (typedIn && !typedIn.isConnected) typedIn = null;
    return !!typedIn || !!document.querySelector("[" + LOADING + "]");
  };
})();
