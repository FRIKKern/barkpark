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
//
// On the desk an item's Remove is in its "…" menu (ArrayItemMenu), a popover
// item, not a row button: the row and its menu went with the press, and
// focus fell to <body>. Its menu items count as row buttons, and the desk's
// "Add item..." menu button is the field's Add control.
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

  var PRESSABLE = 'button.bp-array-btn, button.bp-array-add-member, [role="menuitem"][phx-value-action]';

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
      if (el.matches && el.matches(".dk-add-item")) {
        var add = el.querySelector(":scope > button");
        if (add) return add;
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
// the text around the other's change. A focused select is set the same way
// (task-165052f4fad43c1e): the desk's undo leaves the focus in the select it
// put back, so another editor's later pick stayed out of sight there until
// the person's next action.
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

  // The stretch of `now` that differs from `was`: [start, end).
  function changed(was, now) {
    var p = 0;
    while (p < was.length && p < now.length && was[p] === now[p]) p++;
    var s = 0;
    while (s < was.length - p && s < now.length - p && was[was.length - 1 - s] === now[now.length - 1 - s]) s++;
    return [p, now.length - s];
  }

  function hasOption(select, value) {
    for (var i = 0; i < select.options.length; i++) if (select.options[i].value === value) return true;
    return false;
  }

  // task-f75673bec30873e6: the input an IME is composing in. A value drawn
  // into it mid-composition made the composition commit again (かかき). It
  // is left as it is, as typing not yet sent: its post, at compositionend,
  // carries the number of the value it was typed from, and the server merges
  // it (as rich text waits, task #28732).
  var composing = null;

  document.addEventListener(
    "compositionstart",
    function (e) {
      composing = e.target;
    },
    true,
  );

  document.addEventListener(
    "compositionend",
    function () {
      composing = null;
    },
    true,
  );

  function takeFocused(values) {
    var el = document.activeElement;
    if (!el || !el.name || !el.form || el.form.id !== "editor-form") return;
    if (el === composing) return;
    var select = el.tagName === "SELECT" && !el.multiple;
    if (!(select || el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && TEXT.test(el.type)))) return;
    if (!Object.prototype.hasOwnProperty.call(values, el.name)) return;
    var change = values[el.name];
    if (!change || typeof change.value !== "string" || el.value !== change.was) return;
    // A choice has no caret; one the select does not offer is left to the
    // patch, once the focus leaves it.
    if (select) {
      if (hasOption(el, change.value)) el.value = change.value;
      return;
    }
    var start = shift(el.selectionStart, change.was, change.value);
    var end = shift(el.selectionEnd, change.was, change.value);
    // task-e070cb99b86100be: a selection that would span letters the other
    // editor put in is not carried onto them: B's next key replaced them and
    // the post read as B's own edit. The caret goes after the other's change.
    var added = changed(change.was, change.value);
    if (start !== end && added[1] > added[0] && start < added[1] && end > added[0]) start = end = added[1];
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

  function readSeen(input) {
    var seen;
    try {
      seen = JSON.parse(input.value || "{}");
    } catch (_) {
      seen = {};
    }
    return seen && typeof seen === "object" ? seen : {};
  }

  // task-f18af43e26e46ff4: `v` says this page numbers every value it shows,
  // a field not drawn included, so a post with no number for a field left
  // before that field's push arrived and the server may merge it. A tab still
  // running an older copy of this file never writes it, and its posts are
  // not merged without a number. Written by this file only, never drawn.
  var SEEN_VERSION = 2;

  function markSeen(form) {
    var input = form && form.querySelector('input[name="_bp_seen"]');
    if (!input) return;
    var seen = readSeen(input);
    if (seen.v === SEEN_VERSION) return;
    seen.v = SEEN_VERSION;
    input.value = JSON.stringify(seen);
  }

  // Before LiveView reads the form for the post (capture, on window).
  window.addEventListener(
    "input",
    function (e) {
      var form = e.target && e.target.form;
      if (form && form.id === "editor-form") markSeen(form);
    },
    true,
  );

  function recordSeen(values, seqs) {
    var form = document.getElementById("editor-form");
    var input = form && form.querySelector('input[name="_bp_seen"]');
    if (!input) return;
    var seen = readSeen(input);
    seen.v = SEEN_VERSION;
    Object.keys(seqs).forEach(function (name) {
      var pair = seqs[name];
      var change = values[name];
      var field = form.elements.namedItem(name);
      if (!Array.isArray(pair) || !change) return;
      // A field not drawn now (another group tab, hidden by visibleWhen) is
      // drawn later from the server's form, which holds the new value.
      // task-f18af43e26e46ff4: left unnumbered, its next post was merged
      // from an older value than the one the person saw.
      if (!field) {
        seen[name] = pair[1];
        return;
      }
      if (typeof field.value !== "string") return;
      // A textarea's value has its line breaks as "\n" only.
      if (lf(field.value) === lf(change.value)) seen[name] = pair[1];
      else if (!Object.prototype.hasOwnProperty.call(seen, name)) seen[name] = pair[0];
    });
    input.value = JSON.stringify(seen);
  }

  // task-727f65fc259d0c7b: a value marked `draw` is set in an input that
  // is not focused too, while it still shows exactly `was`. The server put a
  // stale field back to the store without changing its form, so no patch
  // redraws it, and the input kept showing the old text.
  function drawShown(values) {
    var form = document.getElementById("editor-form");
    if (!form) return;
    Object.keys(values).forEach(function (name) {
      var change = values[name];
      var el = form.elements.namedItem(name);
      if (!change || !change.draw || typeof change.value !== "string") return;
      if (!el || el === document.activeElement || typeof el.value !== "string") return;
      if (el.tagName === "INPUT" ? !TEXT.test(el.type) : el.tagName !== "TEXTAREA") return;
      if (lf(el.value) === lf(change.was)) el.value = change.value;
    });
  }

  function onRemoteValues(e) {
    var detail = (e && e.detail) || {};
    var values = detail.values || {};
    takeFocused(values);
    drawShown(values);
    if (detail.seqs) recordSeen(values, detail.seqs);
  }

  // task-4fc7383b936f606a: a connected mount sends each free-text field its
  // stored value with a number (`RemoteValues.born/1`). A page that rejoins
  // a new socket keeps this input, the old socket's numbers. A field showing
  // the value takes the number. One that does not (typed while away) keeps
  // its number, or reports 0, a number no socket sends: the server holds its
  // post rather than write it over a save it never showed. Nothing is drawn.
  function onBorn(e) {
    var detail = (e && e.detail) || {};
    var values = detail.values || {};
    var seqs = detail.seqs || {};
    var form = document.getElementById("editor-form");
    var input = form && form.querySelector('input[name="_bp_seen"]');
    if (!input) return;
    var seen = readSeen(input);
    seen.v = SEEN_VERSION;
    Object.keys(seqs).forEach(function (name) {
      var value = values[name];
      var field = form.elements.namedItem(name);
      if (typeof value !== "string" || typeof seqs[name] !== "number") return;
      // A field not drawn now is drawn later from the server's form.
      if (!field || (typeof field.value === "string" && lf(field.value) === lf(value))) seen[name] = seqs[name];
      else if (!Object.prototype.hasOwnProperty.call(seen, name)) seen[name] = 0;
    });
    input.value = JSON.stringify(seen);
  }

  window.addEventListener("phx:bp:form-remote-values", onRemoteValues);
  window.addEventListener("phx:bp:form-born", onBorn);
  window.BarkparkFormRemoteValues = onRemoteValues;
})();

// task-7f47b7ad78b08048: an array row's open state is the person's. The row
// keeps the browser's `open` across patches (`JS.ignore_attributes`), so a
// save no longer closes the row someone is typing in. The server only ever
// opens a row: one that comes to carry a finding gets `data-row-finding`,
// and this opens it. A row drawn new comes with its `open` already.
(function () {
  "use strict";

  var ROW = "details.bp-array-item";

  function onFindings(records) {
    for (var i = 0; i < records.length; i++) {
      var el = records[i].target;
      if (el && el.matches && el.matches(ROW) && el.hasAttribute("data-row-finding") && !el.open) {
        el.open = true;
      }
    }
  }

  new MutationObserver(onFindings).observe(document.documentElement, {
    subtree: true,
    attributes: true,
    attributeFilter: ["data-row-finding"]
  });
})();

// task-8908b6e031268f77: an edit not yet posted leaves before the pane does.
// The editor form's inputs post after a delay (phx-debounce), and the server
// writes a post only into the document it was built for (`PostIdentity`). A
// post that left after the pane asked for another document is refused, so
// the edit would be lost. LiveView posts a waiting input at once when it
// blurs. A hidden input (date-time, colour, reference) never blurs, and
// neither does a text input when the pane changes with the focus still in
// it (browser Back, a row opened by a script). So each input of the form
// that changed is remembered for as long as its delay, and gets that `blur`
// when the page is about to leave the document: a LiveView navigation, or a
// press outside the form (a row or a button that asks the server to open
// another document).
(function () {
  "use strict";

  // input -> the timer that forgets it once its own delay has posted it.
  var waiting = new Map();

  function field(el) {
    var form = el && el.form;
    return form && form.id === "editor-form" && el.hasAttribute("phx-debounce") ? el : null;
  }

  function delay(el) {
    var ms = parseInt(el.getAttribute("phx-debounce"), 10);
    return (isNaN(ms) ? 300 : ms) + 200;
  }

  function note(e) {
    var el = field(e.target);
    if (!el) return;
    clearTimeout(waiting.get(el));
    waiting.set(
      el,
      setTimeout(function () {
        waiting.delete(el);
      }, delay(el))
    );
  }

  function flush() {
    var inputs = Array.from(waiting.keys());
    waiting.forEach(function (timer) {
      clearTimeout(timer);
    });
    waiting.clear();
    inputs.forEach(function (el) {
      if (el.isConnected) el.dispatchEvent(new Event("blur"));
    });
  }

  function press(e) {
    if (!waiting.size) return;
    var form = document.getElementById("editor-form");
    if (!form || !e.target || !form.contains(e.target)) flush();
  }

  document.addEventListener("input", note, true);
  document.addEventListener("change", note, true);
  // On window, in the capture phase: before LiveView's own click listener
  // pushes the event or the patch, and before any other listener redraws.
  window.addEventListener("click", press, true);
  // A navigation that takes the form away takes the focus in it too (the old
  // Studio draws the next document's form new, and Back can mount the page
  // again, which may take seconds). Once the focused input has left the page
  // the document header is asked to take the focus, as after a search hit:
  // the root layout's `bp:focus-doc-header` focuses it only while focus is
  // on <body>. An input that stays, or a key or press meanwhile, ends it.
  function leave() {
    var form = document.getElementById("editor-form");
    var active = document.activeElement;
    flush();
    if (!form || !active || !form.contains(active)) return;
    var moved = false;
    var move = function () {
      moved = true;
    };
    document.addEventListener("keydown", move, { capture: true, once: true });
    document.addEventListener("pointerdown", move, { capture: true, once: true });
    var until = Date.now() + 10000;
    var wait = function () {
      if (moved) return;
      if (!active.isConnected) {
        window.dispatchEvent(new CustomEvent("phx:bp:focus-doc-header"));
      } else if (Date.now() < until) {
        setTimeout(wait, 50);
        return;
      }
      document.removeEventListener("keydown", move, { capture: true });
      document.removeEventListener("pointerdown", move, { capture: true });
    };
    wait();
  }

  window.addEventListener("phx:page-loading-start", leave);
  window.addEventListener("phx:navigate", leave);
  window.BarkparkFormLeave = flush;
})();

// task-8908b6e031268f77: a press that writes the open document names it.
// A list's Add, Remove and Move, Generate on a slug, a tree codelist's
// pick and Remove, and a field's Revert are events
// of their own, not posts of the editor form. The server writes one only
// into the document it was pressed in (`PostIdentity`), so the pressed
// control is given the form's own mark,
// read at the press, and LiveView sends it with the event as a
// `phx-value-`. A press with no editor form on the page gets an empty mark
// and is not written.
//
// task-176bd529276ff8b3: the document's actions are such presses too
// (Publish, Unpublish, Delete, Discard draft, Duplicate, Restore, and the
// confirm of each one's dialog). Their controls are outside the form, and
// a sheet or a paper has no editor form, so the page carries the open
// document's mark once more (`#bp-doc`), read when there is no form.
(function () {
  "use strict";

  var MARK = "phx-value-_bp_doc";
  var WRITES = [
    "array_op", "slug-generate",
    "publish", "unpublish", "confirm-unpublish", "delete-doc", "confirm-delete", "discard-draft",
    "confirm-discard", "duplicate-doc", "restore-revision", "paper-publish", "desk-field-revert",
    "tree_node_select", "tree_node_clear"
  ];

  // Whether a binding (an event name, or LiveView's JSON commands) sends one.
  function writes(binding) {
    if (!binding) return false;
    for (var i = 0; i < WRITES.length; i++) {
      if (binding === WRITES[i] || binding.indexOf('"event":"' + WRITES[i] + '"') !== -1) return true;
    }
    return false;
  }

  // The mark of the document the page shows now: the editor form's, else
  // the page's own copy; empty with neither.
  function mark() {
    var form = document.getElementById("editor-form");
    if (form) return form.getAttribute(MARK) || "";
    var holder = document.getElementById("bp-doc");
    return (holder && holder.getAttribute("data-bp-doc")) || "";
  }

  function name(attr) {
    return function (e) {
      var from = e.target && e.target.nodeType === 1 ? e.target : e.target && e.target.parentElement;
      var el = from && from.closest ? from.closest("[" + attr + "]") : null;
      if (!el || !writes(el.getAttribute(attr))) return;
      // Always present, empty with no document: a press with no mark at all
      // is how the server knows a page older than this script, and reloads it.
      el.setAttribute(MARK, mark());
    };
  }

  // On window, in the capture phase: before LiveView's own listener reads
  // the control's values and pushes the event.
  window.addEventListener("click", name("phx-click"), true);
  window.addEventListener("submit", name("phx-submit"), true);
  // For a press a script makes later than the key that asked for it (the
  // desk's Ctrl+Alt+P): it presses only while the page shows the same document.
  window.BarkparkDocMark = mark;
})();
