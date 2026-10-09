// bp-array-focus.js — keyboard focus for Studio array fields
// (task-278c7992ed05a30b).
//
// An arrayOf field's row buttons (+ Add, ▲, ▼, ×) are server round-trips: the
// LiveView re-renders the rows and the pressed button is replaced or gone.
// Without help, focus stayed on Add after adding (the new row sat behind it),
// fell to <body> after removing (the keyboard user was thrown to the top of
// the page), and stayed on the button at the OLD position after moving, which
// by then belonged to the neighbour, so a second press moved the wrong item.
//
// A document-level listener remembers which row button was pressed and, once
// the rows change, focuses: the new row's first control (add); the row now at that position,
// else the last row, else Add (remove); the moved item's same button at its
// new position, else its other one (move).
(function () {
  "use strict";

  var FOCUSABLE =
    'input:not([type="hidden"]):not([disabled]), textarea:not([disabled]), select:not([disabled]), ' +
    'button:not([disabled]), summary, [tabindex]:not([tabindex="-1"])';

  function rows(fieldset) {
    var list = null;
    for (var i = 0; i < fieldset.children.length; i++) {
      if (fieldset.children[i].matches && fieldset.children[i].matches("ol.bp-array-rows")) {
        list = fieldset.children[i];
      }
    }
    if (!list) return [];
    return Array.prototype.filter.call(list.children, function (li) {
      return li.matches && li.matches("li.bp-array-row");
    });
  }

  function addButton(fieldset) {
    for (var i = 0; i < fieldset.children.length; i++) {
      var el = fieldset.children[i];
      if (el.matches && el.matches("button.bp-array-btn-add")) return el;
    }
    return null;
  }

  function first(li) {
    return li ? li.querySelector(FOCUSABLE) : null;
  }

  function usable(el) {
    return el && !el.disabled ? el : null;
  }

  // Where focus belongs once the rows reflect `intent`. Exported for tests.
  function target(fieldset, intent) {
    var all = rows(fieldset);
    switch (intent.action) {
      case "add_row":
        return first(all[all.length - 1]) || addButton(fieldset);
      case "remove_row":
        if (!all.length) return addButton(fieldset);
        return first(all[Math.min(intent.index, all.length - 1)]) || addButton(fieldset);
      case "move_up":
      case "move_down": {
        var up = intent.action === "move_up";
        var li = all[up ? intent.index - 1 : intent.index + 1];
        if (!li) return null;
        return (
          usable(li.querySelector(up ? ".bp-array-btn-up" : ".bp-array-btn-down")) ||
          usable(li.querySelector(up ? ".bp-array-btn-down" : ".bp-array-btn-up")) ||
          first(li)
        );
      }
      default:
        return null;
    }
  }

  // The rows' shape before the press: a patch that has not landed yet leaves
  // it unchanged, so focus is only moved once the change is visible.
  function signature(fieldset) {
    return rows(fieldset)
      .map(function (li) {
        var v = li.querySelector("input, textarea");
        return li.getAttribute("data-row-index") + ":" + (v ? v.value : li.textContent.length);
      })
      .join("|");
  }

  // One document-level listener, no LiveView hook: array fields stay a pure
  // server round-trip with no phx-hook (Decision 13). The fieldset carries a
  // stable id, so it is found again even if the patch replaces the node.
  var pending = null;
  var observer = null;

  function stop() {
    pending = null;
    if (observer) observer.disconnect();
    observer = null;
  }

  function settle() {
    if (!pending) return;
    if (Date.now() - pending.at > 5000) return stop();
    var fieldset = document.getElementById(pending.id);
    if (!fieldset || signature(fieldset) === pending.before) return;
    var intent = pending;
    stop();
    var el = target(fieldset, intent);
    if (el && typeof el.focus === "function") el.focus();
  }

  function onClick(e) {
    var button = e.target && e.target.closest ? e.target.closest("button.bp-array-btn") : null;
    var fieldset = button && button.closest("fieldset.bp-field-array");
    if (!fieldset || !fieldset.id || button.closest("fieldset.bp-field-array") !== fieldset) return;
    stop();
    pending = {
      id: fieldset.id,
      action: button.getAttribute("phx-value-action"),
      index: parseInt(button.getAttribute("phx-value-index") || "-1", 10),
      before: signature(fieldset),
      at: Date.now()
    };
    observer = new MutationObserver(settle);
    observer.observe(fieldset.parentNode || document.body, { childList: true, subtree: true, attributes: true });
  }

  document.addEventListener("click", onClick);

  window.BarkparkArrayRowFocusTarget = target;
})();
