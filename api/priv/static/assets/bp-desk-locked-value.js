// bp-desk-locked-value.js: a field the desk draws read-only shows the value
// the server drew for it (task-2cad4946448ba07b).
//
// Opening an old revision, or the published version, draws the form again
// over those values, read-only, in a new form box. The form and its inputs
// keep their ids, so LiveView's morphdom moves each input into the new box
// and patches it there. LiveView leaves the value of the input that had the
// focus as the browser holds it, so the field being typed in kept the
// draft's value (a value a refused save held, too) over the revision's own,
// and going back kept the revision's value over the draft's.
//
// The page's `onBeforeElUpdated` (root.html.heex) hands each patched element
// here before LiveView's rule runs: a text input or a text area that is
// read-only before or after the patch takes the value the server drew.
// Nothing can be typed into a read-only field, and what was typed into one
// the server now draws read-only can no longer be saved from it. An input
// that stays editable keeps the browser's value, as LiveView keeps it.
(function () {
  "use strict";

  // Inputs whose `value` is not what the person sees or types.
  var NOT_TEXT = /^(checkbox|radio|file|hidden|submit|button|reset|image|range|color)$/;

  function text(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.tagName === "TEXTAREA") return true;
    return el.tagName === "INPUT" && !NOT_TEXT.test(el.type);
  }

  function lockedValue(fromEl, toEl) {
    if (!text(fromEl) || !text(toEl) || fromEl.tagName !== toEl.tagName) return;
    if (!fromEl.readOnly && !toEl.readOnly) return;
    if (fromEl.value !== toEl.value) fromEl.value = toEl.value;
  }

  window.BarkparkDeskLockedValue = lockedValue;
})();
