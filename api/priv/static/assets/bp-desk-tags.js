// bp-desk-tags.js: the browser half of a tags field on the desk
// (`BarkparkWeb.Components.Fields.TagsField`), as the TanStack Studio's
// TagsInput (barkpark-studio app/src/components/ArrayInputs.tsx).
//
// ENTER. In a tags input, Enter adds what is typed. The text, trimmed, is
// put on the field's add button (`data-tags-add`) as its value and the
// button is pressed, so the add is an `array_op` press that carries the
// document's mark like any other (bp-array-focus.js names it in the capture
// phase, before LiveView reads the button). The input is emptied at once,
// so the next tag can be typed while the server answers; presses reach the
// server in the order they were made, so tags typed fast all land, in order.
//
// The Enter that commits an IME's word (Japanese, Chinese, Korean) is the
// IME's, not ours: it adds nothing, and the word stays in the input until
// a plain Enter. Safari says keyCode 229 for it. An empty input adds
// nothing. Enter never submits the editor form: the input belongs to no
// form.
//
// A CLICK anywhere in the box puts the caret in its input, as TanStack's
// (a × too, so the keyboard stays in the field after a remove).
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-tags`).
(function () {
  "use strict";

  if (window.BarkparkDeskTags) return;

  var INPUT = "input.tags-input";
  var BOX = "[data-tags-box]";

  function onKey(e) {
    var input = e.target;
    if (!input || !input.matches || !input.matches(INPUT)) return;
    if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;
    e.preventDefault();
    var text = input.value.trim();
    if (!text || input.readOnly) return;
    var box = input.closest(BOX);
    var add = box && box.querySelector("button[data-tags-add]");
    if (!add) return;
    add.setAttribute("phx-value-value", text);
    add.click();
    input.value = "";
  }

  function onClick(e) {
    var from = e.target && e.target.nodeType === 1 ? e.target : e.target && e.target.parentElement;
    var box = from && from.closest ? from.closest(BOX) : null;
    if (!box) return;
    var input = box.querySelector(INPUT);
    if (input && document.activeElement !== input) input.focus();
  }

  document.addEventListener("keydown", onKey, true);
  document.addEventListener("click", onClick);
  window.BarkparkDeskTags = { onKey: onKey };
})();
