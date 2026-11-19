// bp-desk-select.js: a radio list's Clear on the desk
// (`BarkparkWeb.Components.Fields.DeskSelect`), as the TanStack Studio's
// SelectInput (barkpark-studio app/src/components/fields.tsx), whose reset
// button unsets the field.
//
// Unchecked radios post nothing, so the list carries a hidden input of the
// field's name that is off (`disabled`). Clear turns it on and fires its
// input: the form posts "" for the field (the hidden input is last, so it
// wins over a checked radio), and the save unsets it. It is turned off again
// at once, and the server's redraw draws it off too. The button goes with
// the redraw, so the focus moves to the first option first and never falls
// to the page.
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-select`).
(function () {
  "use strict";

  if (window.BarkparkDeskSelect) return;

  function clear(button) {
    var box = button.closest(".radio-box");
    var hidden = box && box.querySelector("input[data-radio-cleared]");
    if (!hidden) return false;
    var first = box.querySelector('input[type="radio"]');
    if (first) first.focus();
    hidden.disabled = false;
    hidden.dispatchEvent(new Event("input", { bubbles: true }));
    hidden.disabled = true;
    return true;
  }

  document.addEventListener("click", function (e) {
    var button = e.target && e.target.closest ? e.target.closest("button[data-radio-clear]") : null;
    if (button && clear(button)) e.preventDefault();
  });

  window.BarkparkDeskSelect = { clear: clear };
})();
