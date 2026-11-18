// bp-desk-codelist.js: the keys of a tree codelist on the desk
// (`BarkparkWeb.Components.Fields.TreeCodelistDesk`), as the TanStack
// Studio's TreePicker (barkpark-studio app/src/components/CodelistInput.tsx),
// a WAI-ARIA tree with one row in the Tab order.
//
// In the tree: ArrowDown and ArrowUp move to the next and the previous row,
// Home and End to the first and the last. ArrowRight opens a closed branch,
// or moves into an open one; ArrowLeft closes an open branch, or moves to
// the row's parent. In a search every match is open, so Right and Left only
// move. Enter and Space pick the row's code: the row is clicked, so the pick
// is the row's own press, named for the document (bp-array-focus.js). Opening
// and closing click the row's ▶, which the server answers.
//
// In the search box: ArrowDown moves to the first row, as from a combobox.
// Enter submits nothing (the box is in the editor's form).
//
// The row that has the focus is the one in the Tab order, and stays so after
// the server redraws the tree, which puts the first row there. A redraw that
// took the focused row away gives the focus to its nearest parent still
// drawn, so it never falls to the page.
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-codelist`).
(function () {
  "use strict";

  if (window.BarkparkDeskCodelist) return;

  var FIELD = ".codelist-tree-field";
  var ROW = '[role="treeitem"]';
  // The row each tree had the focus on last, by the tree's id: its code and
  // its parents' codes. `holding`: the trees whose row has the focus now.
  var active = {};
  var holding = {};

  function rowsOf(field) {
    return Array.prototype.slice.call(field.querySelectorAll(".codelist-tree > " + ROW));
  }

  function rove(field, row) {
    rowsOf(field).forEach(function (r) {
      r.setAttribute("tabindex", r === row ? "0" : "-1");
    });
  }

  function move(field, rows, i) {
    var n = Math.max(0, Math.min(rows.length - 1, i));
    var row = rows[n];
    if (!row) return;
    rove(field, row);
    row.focus();
  }

  function toggle(row) {
    var t = row.querySelector(".codelist-toggle[phx-click]");
    if (t) t.click();
  }

  function onTreeKey(e, row, field) {
    var rows = rowsOf(field);
    var i = rows.indexOf(row);
    if (i < 0) return;
    var branch = row.hasAttribute("aria-expanded");
    var open = row.getAttribute("aria-expanded") === "true";
    var searching = field.hasAttribute("data-searching");
    switch (e.key) {
      case "ArrowDown": move(field, rows, i + 1); break;
      case "ArrowUp": move(field, rows, i - 1); break;
      case "Home": move(field, rows, 0); break;
      case "End": move(field, rows, rows.length - 1); break;
      case "ArrowRight":
        if (branch && !open && !searching) toggle(row);
        else if (branch) move(field, rows, i + 1);
        break;
      case "ArrowLeft":
        if (branch && open && !searching) {
          toggle(row);
        } else {
          var parent = row.getAttribute("data-parent");
          var at = parent ? rows.findIndex(function (r) { return r.getAttribute("data-code") === parent; }) : -1;
          if (at >= 0) move(field, rows, at);
        }
        break;
      case "Enter":
      case " ":
        if (row.hasAttribute("phx-click")) row.click();
        break;
      default:
        return;
    }
    e.preventDefault();
  }

  function onKey(e) {
    var t = e.target;
    if (!t || !t.closest || e.isComposing) return;
    var field = t.closest(FIELD);
    if (!field) return;
    if (t.matches(ROW)) return onTreeKey(e, t, field);
    if (!t.matches('.codelist-search input[type="search"]')) return;
    if (e.key === "Enter") {
      e.preventDefault();
    } else if (e.key === "ArrowDown") {
      var rows = rowsOf(field);
      if (rows.length) {
        e.preventDefault();
        move(field, rows, 0);
      }
    }
  }

  // The focused row's code, then its parents' up to the root.
  function lineOf(field, row) {
    var line = [];
    while (row) {
      var code = row.getAttribute("data-code");
      line.push(code);
      var parent = row.getAttribute("data-parent");
      row = parent ? rowsOf(field).find(function (r) { return r.getAttribute("data-code") === parent; }) : null;
    }
    return line;
  }

  function onFocus(e) {
    var t = e.target;
    if (!t || !t.matches || !t.matches(ROW)) return;
    var field = t.closest(FIELD);
    if (!field) return;
    active[field.id] = lineOf(field, t);
    holding[field.id] = true;
    rove(field, t);
  }

  // A row left for another element, or for the page by a click on nothing,
  // lets go; a row the server took away while it had the focus does not.
  function onBlur(e) {
    var t = e.target;
    if (!t || !t.matches || !t.matches(ROW)) return;
    var field = t.closest(FIELD);
    if (!field) return;
    var id = field.id;
    setTimeout(function () {
      if (t.isConnected) delete holding[id];
    }, 0);
  }

  // After a redraw the row that had the focus keeps the Tab stop. When the
  // redraw took it away and the focus fell to the page, it goes to the
  // nearest of its parents still drawn, else to the first row or the box.
  function onUpdate() {
    Object.keys(active).forEach(function (id) {
      var field = document.getElementById(id);
      if (!field) return void delete active[id];
      var rows = rowsOf(field);
      var row = null;
      active[id].some(function (code) {
        row = rows.find(function (r) { return r.getAttribute("data-code") === code; }) || null;
        return !!row;
      });
      var lost = holding[id] && (!document.activeElement || document.activeElement === document.body);
      if (row) {
        rove(field, row);
        if (lost) row.focus();
      } else if (lost) {
        var box = field.querySelector('.codelist-search input[type="search"]');
        if (rows[0]) move(field, rows, 0);
        else if (box) box.focus();
      }
    });
  }

  document.addEventListener("keydown", onKey);
  document.addEventListener("focusin", onFocus);
  document.addEventListener("focusout", onBlur);
  document.addEventListener("phx:update", onUpdate);

  window.BarkparkDeskCodelist = { rows: rowsOf };
})();
