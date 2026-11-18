// bp-desk-array-menu.js: the browser half of an object array's items on the
// desk (`BarkparkWeb.Components.Fields.ArrayItemDialog`, `ArrayItemMenu`),
// as the TanStack Studio's (SortableRows.tsx, ObjectArrayInput.tsx).
//
// THE ITEM MENU. Each item's "…" is an HTML popover menu. Opened, it is
// placed by its button, the button says it is expanded, and the first item
// takes the focus; the arrows, Home and End move between the items, and Tab
// closes it. Escape and a click outside are the popover's own.
//
// THE ITEM DIALOG. The preview opens the item's <dialog> with showModal().
// Its fields are the form's own inputs (they sit inside the form wherever the
// dialog is drawn), so nothing here posts or saves. Tab and Shift+Tab go
// round inside it. Escape closes it, except while a list, a menu or a
// combobox inside it is open: that Escape is the inner control's. The close
// button and the field's crumb close it too. Closed, the focus goes back to
// the item's preview. The server opens a new item's dialog with the event
// `desk:item-open` (the array's input path and the item's place).
//
// THE HANDLE. Space or Enter picks the item up; the arrows move it; Space or
// Enter drops it; Escape puts it back. A pointer drag moves it too. While it
// moves only the rows' order on screen changes (`order`); the drop sends one
// `array_op` `move_row`, pressed on a button made for it, so it carries the
// document's mark as any other press (bp-array-focus.js).
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-array-menu`).
(function () {
  "use strict";

  var doc = window.document;
  var MENU = "[data-desk-item-menu]";
  var ITEM = '[role="menuitem"]:not([disabled])';
  var DIALOG = "dialog[data-desk-item-dialog]";
  var FOCUSABLE =
    'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), ' +
    'textarea:not([disabled]), [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';
  var opener = null;

  // ── The menu ──────────────────────────────────────────────────────────

  function buttonOf(menu) {
    return doc.getElementById(menu.getAttribute("aria-labelledby") || "");
  }

  doc.addEventListener(
    "toggle",
    function (e) {
      var menu = e.target;
      if (!menu || !menu.matches || !menu.matches(MENU)) return;
      var button = buttonOf(menu);
      var open = e.newState === "open";
      if (button) button.setAttribute("aria-expanded", open ? "true" : "false");
      if (!open) return;
      if (opener && opener !== button) opener.style.removeProperty("anchor-name");
      opener = button;
      if (button) button.style.setProperty("anchor-name", "--dk-item-menu");
      var first = menu.querySelector(ITEM);
      if (first) first.focus();
    },
    true
  );

  doc.addEventListener("keydown", function (e) {
    var menu = e.target && e.target.closest ? e.target.closest(MENU) : null;
    if (!menu || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "Tab") return menu.hidePopover();
    var step = { ArrowDown: 1, ArrowUp: -1, Home: -Infinity, End: Infinity }[e.key];
    if (step === undefined) return;
    var items = Array.prototype.slice.call(menu.querySelectorAll(ITEM));
    if (!items.length) return;
    e.preventDefault();
    var at = items.indexOf(doc.activeElement);
    var to = Math.abs(step) === Infinity ? (step < 0 ? 0 : items.length - 1) : (at + step + items.length) % items.length;
    items[to].focus();
  });

  // ── The dialog ────────────────────────────────────────────────────────

  function shown(el) {
    if (typeof el.checkVisibility === "function") return el.checkVisibility();
    return el.getClientRects().length > 0;
  }

  function stops(dialog) {
    return Array.prototype.filter.call(dialog.querySelectorAll(FOCUSABLE), function (el) {
      return el.tabIndex >= 0 && shown(el);
    });
  }

  function previewOf(dialog) {
    var row = dialog.closest("li");
    return row ? row.querySelector(":scope > [data-desk-item-open]") : null;
  }

  function open(dialog) {
    if (!dialog || dialog.open || !dialog.showModal) return;
    dialog.showModal();
    var first = stops(dialog)[0];
    if (first) first.focus();
  }

  function toPreview(dialog) {
    var preview = previewOf(dialog);
    if (preview && preview.isConnected) preview.focus();
  }

  // The focus goes back to the preview at once: the dialog's `close` event
  // comes a task later, after the person (or a script) may have moved on.
  function close(dialog) {
    if (!dialog || !dialog.open) return;
    dialog.close();
    toPreview(dialog);
  }

  // A dialog closed some other way: its preview takes the focus only when
  // nothing has taken it since.
  doc.addEventListener(
    "close",
    function (e) {
      var dialog = e.target;
      if (!dialog || !dialog.matches || !dialog.matches(DIALOG)) return;
      var at = doc.activeElement;
      if (at && at !== doc.body && !dialog.contains(at)) return;
      toPreview(dialog);
    },
    true
  );

  // The browser's own close on Escape is not used: the keydown below decides.
  doc.addEventListener(
    "cancel",
    function (e) {
      if (e.target && e.target.matches && e.target.matches(DIALOG)) e.preventDefault();
    },
    true
  );

  // An Escape that belongs to a control inside the dialog: an open list, menu
  // or combobox.
  function inner(el) {
    if (!el || !el.closest) return false;
    if (el.getAttribute("aria-expanded") === "true") return true;
    if (el.closest('[role="menu"], [role="listbox"], [popover]')) return true;
    var widget = el.closest("bp-reference-picker, bp-media-picker");
    return !!(widget && widget.querySelector('[aria-expanded="true"]'));
  }

  doc.addEventListener(
    "keydown",
    function (e) {
      var dialog = e.target && e.target.closest ? e.target.closest(DIALOG) : null;
      if (!dialog || !dialog.open) return;
      if (e.key === "Escape") {
        e.preventDefault();
        if (!inner(doc.activeElement)) close(dialog);
        return;
      }
      if (e.key !== "Tab") return;
      var list = stops(dialog);
      if (!list.length) return;
      var first = list[0];
      var last = list[list.length - 1];
      var at = doc.activeElement;
      if (!dialog.contains(at)) {
        e.preventDefault();
        (e.shiftKey ? last : first).focus();
      } else if (e.shiftKey && at === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && at === last) {
        e.preventDefault();
        first.focus();
      }
    },
    true
  );

  doc.addEventListener("click", function (e) {
    var t = e.target && e.target.closest ? e.target : null;
    if (!t) return;
    var opens = t.closest("[data-desk-item-open]");
    if (opens) return open(doc.getElementById(opens.getAttribute("data-desk-item-open")));
    var closes = t.closest("[data-desk-item-close]");
    if (closes) return close(closes.closest(DIALOG));
    // A press on the dimmed page round the dialog closes it.
    if (t.matches(DIALOG) && t.open) {
      var r = t.getBoundingClientRect();
      if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) close(t);
    }
  });

  function rowAt(path, index) {
    var sets = doc.querySelectorAll("fieldset[data-array-path]");
    for (var i = 0; i < sets.length; i++) {
      if (sets[i].getAttribute("data-array-path") !== path) continue;
      var rows = sets[i].querySelectorAll(":scope > ol > li[data-row-index]");
      for (var j = 0; j < rows.length; j++) {
        if (rows[j].getAttribute("data-row-index") === String(index)) return rows[j];
      }
    }
    return null;
  }

  // An object item opens its dialog; a string row (ArrayStringRow) has none,
  // and its input takes the caret, so what is typed next lands there.
  window.addEventListener("phx:desk:item-open", function (e) {
    var detail = e.detail || {};
    var row = rowAt(detail.path, detail.index);
    if (!row) return;
    var dialog = row.querySelector(":scope > " + DIALOG);
    if (dialog) return open(dialog);
    var input = row.querySelector(":scope > .dk-string-value :is(input, textarea):not([type=\"hidden\"])");
    if (input) input.focus();
  });

  // ── The handle ────────────────────────────────────────────────────────

  var moving = null;

  function rowsOf(handle) {
    var list = handle.closest("ol");
    return list ? Array.prototype.slice.call(list.querySelectorAll(":scope > li[data-row-index]")) : [];
  }

  // The rows drawn in their order with the moving one at `to`.
  function place(m) {
    var order = m.rows.map(function (_row, i) {
      return i;
    });
    order.splice(m.to, 0, order.splice(m.from, 1)[0]);
    order.forEach(function (orig, at) {
      m.rows[orig].style.order = String(at);
    });
  }

  function pickUp(handle) {
    var rows = rowsOf(handle);
    var from = rows.indexOf(handle.closest("li"));
    if (from < 0) return;
    moving = { handle: handle, rows: rows, from: from, to: from };
    handle.setAttribute("aria-pressed", "true");
    rows[from].setAttribute("data-moving", "");
  }

  function settle() {
    if (!moving) return;
    moving.rows.forEach(function (row) {
      row.style.removeProperty("order");
      row.removeAttribute("data-moving");
    });
    moving.handle.setAttribute("aria-pressed", "false");
    moving = null;
  }

  // The drop: one press of `array_op` `move_row`, then the moved item's
  // handle has the focus once the rows are drawn again.
  function drop() {
    var m = moving;
    settle();
    if (!m || m.to === m.from) return;
    var h = m.handle;
    var press = doc.createElement("button");
    press.type = "button";
    press.hidden = true;
    press.setAttribute("phx-click", h.getAttribute("data-move-event") || "array_op");
    press.setAttribute("phx-value-action", "move_row");
    press.setAttribute("phx-value-field", h.getAttribute("data-move-field") || "");
    press.setAttribute("phx-value-path", h.getAttribute("data-move-path") || "");
    press.setAttribute("phx-value-index", String(m.from));
    press.setAttribute("phx-value-to", String(m.to));
    var list = h.closest("ol");
    list.parentNode.insertBefore(press, list);
    press.click();
    press.remove();
    var path = h.getAttribute("data-move-path");
    var tries = 0;
    var refocus = function () {
      var row = rowAt(path, m.to);
      var moved = row && row.getAttribute("data-row-key") === m.rows[m.from].getAttribute("data-row-key");
      if (moved || ++tries > 60) {
        var to = row && row.querySelector(":scope > [data-desk-item-handle]");
        if (to) to.focus();
        return;
      }
      window.requestAnimationFrame(refocus);
    };
    window.requestAnimationFrame(refocus);
  }

  doc.addEventListener("keydown", function (e) {
    var handle = e.target && e.target.closest ? e.target.closest("[data-desk-item-handle]") : null;
    if (!handle || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === " " || e.key === "Enter") {
      e.preventDefault();
      if (!moving) return pickUp(handle);
      return drop();
    }
    if (!moving || moving.handle !== handle) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      moving.to = Math.max(0, Math.min(moving.rows.length - 1, moving.to + (e.key === "ArrowDown" ? 1 : -1)));
      place(moving);
      handle.scrollIntoView({ block: "nearest" });
    } else if (e.key === "Escape") {
      e.preventDefault();
      settle();
    }
  });

  // A keyboard move the focus leaves is put back.
  doc.addEventListener("focusout", function (e) {
    if (moving && !moving.pointer && e.target === moving.handle) settle();
  });

  // A pointer drag: the row takes the place given by how many other rows'
  // middles are above the pointer.
  doc.addEventListener("pointerdown", function (e) {
    var handle = e.target && e.target.closest ? e.target.closest("[data-desk-item-handle]") : null;
    if (!handle || handle.disabled || e.button !== 0) return;
    e.preventDefault();
    pickUp(handle);
    if (!moving) return;
    moving.pointer = true;
    var move = function (ev) {
      var m = moving;
      if (!m) return;
      var others = m.rows.filter(function (_row, i) {
        return i !== m.from;
      });
      var above = others.filter(function (row) {
        var r = row.getBoundingClientRect();
        return r.top + r.height / 2 < ev.clientY;
      }).length;
      if (above !== m.to) {
        m.to = above;
        place(m);
      }
    };
    var up = function () {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      drop();
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  });

  window.BarkparkDeskArrayMenu = { open: open, close: close };
})();
