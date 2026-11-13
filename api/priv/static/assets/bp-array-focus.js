// bp-array-focus.js — keyboard focus for Studio array fields, and the focused
// field after another editor's save (bp:form-remote-values, at the end)
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
//
// An array of several member types adds through a type menu: a <details>
// whose buttons name the type. The patch closes the menu and the pressed
// button is hidden, so focus fell to <body> (task-bc277388a704d276). Those
// buttons count as Add, and the menu's summary is the field's Add control.
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

  var PRESSABLE = "button.bp-array-btn, button.bp-array-add-member";

  var FIELD =
    'input:not([type="hidden"]):not([disabled]), textarea:not([disabled]), select:not([disabled]), ' +
    '[contenteditable="true"]';

  function addButton(fieldset) {
    for (var i = 0; i < fieldset.children.length; i++) {
      var el = fieldset.children[i];
      if (el.matches && el.matches("button.bp-array-btn-add")) return el;
      if (el.matches && el.matches("details.bp-array-add-menu")) {
        var summary = el.querySelector("summary");
        if (summary) return summary;
      }
    }
    return null;
  }

  function first(li) {
    return li ? li.querySelector(FOCUSABLE) : null;
  }

  // A new row of an object type is drawn open: its first field, where the
  // person types next, not the row's own summary. A field inside a closed
  // row cannot take focus.
  function firstField(li) {
    if (!li) return null;
    var all = li.querySelectorAll(FIELD);
    for (var i = 0; i < all.length; i++) {
      if (shown(all[i], li)) return all[i];
    }
    return null;
  }

  // Every <details> between `el` and `li` is open.
  function shown(el, li) {
    for (var d = el.closest("details"); d && li.contains(d); d = d.parentElement && d.parentElement.closest("details")) {
      if (!d.open) return false;
    }
    return true;
  }

  function usable(el) {
    return el && !el.disabled ? el : null;
  }

  // Where focus belongs once the rows reflect `intent`. Exported for tests.
  function target(fieldset, intent) {
    var all = rows(fieldset);
    switch (intent.action) {
      case "add_row":
        return firstField(all[all.length - 1]) || first(all[all.length - 1]) || addButton(fieldset);
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
    var button = e.target && e.target.closest ? e.target.closest(PRESSABLE) : null;
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

// bp:form-remote-values (task-e6ef964ac2e41d5a): another editor's save reached
// this document's form while it had nothing unsaved. A LiveView patch leaves
// the FOCUSED input as it is, so the field the person rests in kept the old
// text, and their next keystroke posted it back over the other's words. The
// server names each changed text field with its new value and the one it
// showed before (`RemoteValues.push/3`). The focused input takes the
// new value only while it still shows exactly the old one: anything else is
// typing not yet sent, and stays. Focus stays; the caret keeps its place in
// the text around the other's change.
(function () {
  "use strict";

  var TEXT = /^(text|search|url|tel)$/;

  // Where `pos` in `was` lands in `now`, given one changed stretch between them.
  function shift(pos, was, now) {
    var p = 0;
    while (p < was.length && p < now.length && was[p] === now[p]) p++;
    var s = 0;
    while (s < was.length - p && s < now.length - p && was[was.length - 1 - s] === now[now.length - 1 - s]) s++;
    if (pos <= p) return pos;
    if (pos >= was.length - s) return pos + now.length - was.length;
    return now.length - s;
  }

  function takeFocused(values) {
    var el = document.activeElement;
    if (!el || !el.name || !el.form || el.form.id !== "editor-form") return;
    if (!(el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && TEXT.test(el.type)))) return;
    if (!Object.prototype.hasOwnProperty.call(values, el.name)) return;
    var change = values[el.name];
    if (!change || typeof change.value !== "string" || el.value !== change.was) return;
    var start = shift(el.selectionStart, change.was, change.value);
    var end = shift(el.selectionEnd, change.was, change.value);
    el.value = change.value;
    el.setSelectionRange(start, end);
  }

  // task-35956a566dd2c862: per free-text field, the number of the value this
  // page shows (`seqs`: [number of was, number of value]). A field showing the
  // new value reports its number; one that did not take it (typing not yet
  // sent) keeps reporting the value it was typed from. The post carries the
  // map in the hidden `_bp_seen` input, and the server merges the post onto
  // the stored text from that value (`RemoteValues.put_bases/3`).
  function lf(text) {
    return String(text).replace(/\r\n?/g, "\n");
  }

  function recordSeen(values, seqs) {
    var form = document.getElementById("editor-form");
    var input = form && form.querySelector('input[name="_bp_seen"]');
    if (!input) return;
    var seen;
    try {
      seen = JSON.parse(input.value || "{}");
    } catch (_) {
      seen = {};
    }
    if (!seen || typeof seen !== "object") seen = {};
    Object.keys(seqs).forEach(function (name) {
      var pair = seqs[name];
      var change = values[name];
      var field = form.elements.namedItem(name);
      if (!Array.isArray(pair) || !change || !field || typeof field.value !== "string") return;
      // A textarea's value has its line breaks as "\n" only.
      if (lf(field.value) === lf(change.value)) seen[name] = pair[1];
      else if (!Object.prototype.hasOwnProperty.call(seen, name)) seen[name] = pair[0];
    });
    input.value = JSON.stringify(seen);
  }

  function onRemoteValues(e) {
    var detail = (e && e.detail) || {};
    var values = detail.values || {};
    takeFocused(values);
    if (detail.seqs) recordSeen(values, detail.seqs);
  }

  window.addEventListener("phx:bp:form-remote-values", onRemoteValues);
  window.BarkparkFormRemoteValues = onRemoteValues;
})();
