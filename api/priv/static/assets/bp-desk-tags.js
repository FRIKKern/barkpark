// bp-desk-tags.js: the browser half of a tags field on the desk
// (`BarkparkWeb.Components.Fields.TagsField`), as the TanStack Studio's
// TagsInput (barkpark-studio app/src/components/ArrayInputs.tsx).
//
// ENTER. In a tags input, Enter adds what is typed: an `array_op`
// `add_tag` press with the text, trimmed, as its value, named for the
// document the page shows (`BarkparkDocMark`, bp-array-focus.js), as every
// press that writes. The field's hidden add button (`data-tags-add`) says
// which array. Each Enter is its own push through the desk's hook
// (`bpPush`, bp-desk.js): LiveView drops a click on a button whose last
// press is still unanswered, so a second Enter pressed on the button was
// lost. Without the desk the button is pressed, its value the text. The
// input is emptied at once, so the next tag can be typed while the server
// answers; pushes reach the server in the order they were made, so tags
// typed fast all land, in order.
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
    var desk = input.closest("[data-desk-tags]");
    if (desk && typeof desk.bpPush === "function" && window.BarkparkDocMark) {
      desk.bpPush(add.getAttribute("phx-click"), {
        action: add.getAttribute("phx-value-action"),
        field: add.getAttribute("phx-value-field"),
        path: add.getAttribute("phx-value-path"),
        value: text,
        _bp_doc: window.BarkparkDocMark()
      });
    } else {
      // LiveView sends a pressed button's own value as `value`.
      add.value = text;
      add.click();
      add.value = "";
    }
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
