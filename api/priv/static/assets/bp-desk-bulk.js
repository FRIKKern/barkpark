// A desk list's selection in the browser (B03), after the TanStack Studio's
// ListPane and BulkBar (barkpark-studio app/src/components/Structure.tsx,
// BulkBar.tsx). The server keeps the selection and does the work
// (Desk.Bulk); this script is the part only a browser can do.
//
//   - A Cmd or Ctrl-click on a row ticks it instead of opening it; a
//     Shift-click ticks every row from the last tick to it. Both press the
//     row's own tick, so the server hears one event either way (`bulk-pick`,
//     with `range` for the Shift-click).
//   - Escape in a list that is selecting stops it: the list menu's "Stop
//     selecting" is pressed (the page's `bulk-select`).
//   - A tick shows what the server holds. A box the editor pressed keeps its
//     own state through a patch, so after each patch every box is set from
//     its `checked` attribute.
//   - The focus never falls to the page. A bar button greyed out while its
//     action runs hands it to the bar; the unpublish dialog stays open while
//     its run goes on, the focus on its Cancel; when selecting ends, the bar and the
//     ticks go, and a focus that was on one of them goes to the list's "List
//     options", which starts selecting again.
//   - The summary ("Published 2 of 3") is a toast on the page's body
//     (`desk:bulk-toast`), up 8 s as TanStack's.
//
//   - "Select documents" shows the ticks in the same click, before the
//     server has answered.
//
// Loaded by bp-desk.js from the address the page gives (`data-desk-bulk`).
(function () {
  "use strict";
  if (window.BarkparkDeskBulk) return;

  var doc = window.document;
  var TOAST_MS = 8000;
  var toastTimer = null;

  function toast(tone, title, description) {
    var el = doc.querySelector(".dk-bulk-toast");
    if (!el) {
      el = doc.createElement("div");
      el.className = "toast dk-field-toast dk-bulk-toast";
      el.setAttribute("popover", "manual");
      doc.body.appendChild(el);
    }
    el.setAttribute("data-tone", tone);
    el.setAttribute("role", tone === "critical" ? "alert" : "status");
    // Shown first, then filled: the change is what a screen reader reads.
    if (el.showPopover && !el.matches(":popover-open")) el.showPopover();
    el.textContent = "";
    var strong = doc.createElement("strong");
    strong.textContent = title;
    el.appendChild(strong);
    if (description) {
      var span = doc.createElement("span");
      span.textContent = description;
      el.appendChild(span);
    }
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      el.remove();
    }, TOAST_MS);
  }

  function boxOf(row) {
    return row ? row.querySelector(".bulk-check input") : null;
  }

  // "Select documents" shows the ticks at once, before the server's answer
  // (which draws the same): a Tab pressed right after it finds them.
  function startNow(item) {
    var pane = item.closest("[data-pane-index]");
    var list = pane && pane.querySelector(".list-rows");
    if (!list) return;
    list.setAttribute("data-selecting", "");
    var ticks = list.querySelectorAll(".bulk-check[inert]");
    for (var i = 0; i < ticks.length; i++) ticks[i].removeAttribute("inert");
  }

  // The unpublish dialog's own buttons grey out while their run goes on: the
  // focus goes to its Cancel first, as the TanStack Studio's.
  function cancelOf(el) {
    var dialog = el && el.closest ? el.closest('[data-desk-dialog="bulk-unpublish"]') : null;
    return dialog ? dialog.querySelector("[data-modal-focus]") : null;
  }

  // A modified click on a row, not on its tick: the tick is pressed for it.
  function onClick(e) {
    var start = e.target && e.target.closest ? e.target.closest('.dk-list-menu [phx-click="bulk-select"][phx-value-on="true"]') : null;
    if (start) return startNow(start);
    var go = e.target && e.target.closest ? e.target.closest('[data-desk-dialog="bulk-unpublish"] button[phx-value-confirm="true"]') : null;
    var cancel = go && !go.disabled && cancelOf(go);
    if (cancel) return cancel.focus({ preventScroll: true });
    if (!(e.metaKey || e.ctrlKey || e.shiftKey) || e.button !== 0) return;
    var target = e.target;
    var row = target && target.closest ? target.closest(".dk .bulk-row") : null;
    if (!row || target.closest(".bulk-check")) return;
    var box = boxOf(row);
    if (!box) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.shiftKey) box.setAttribute("phx-value-range", "true");
    box.click();
    box.removeAttribute("phx-value-range");
  }

  // Escape in a list that is selecting: the list menu's own "Stop selecting"
  // is pressed for it.
  function onKey(e) {
    if (e.key !== "Escape" || e.metaKey || e.ctrlKey || e.altKey) return;
    var list = e.target && e.target.closest ? e.target.closest(".dk .list-rows[data-selecting]") : null;
    var pane = list && list.closest("[data-pane-index]");
    var stop = pane && pane.querySelector('.dk-list-menu [phx-click="bulk-select"][phx-value-on="false"]');
    if (!stop) return;
    // The tick with the focus goes out of reach: its row takes the focus.
    var box = e.target.closest(".bulk-check");
    var link = box && box.parentNode.querySelector("a[href]");
    if (link) link.focus({ preventScroll: true });
    stop.click();
  }

  function sync() {
    var boxes = doc.querySelectorAll(".dk .bulk-check input");
    for (var i = 0; i < boxes.length; i++) {
      var on = boxes[i].hasAttribute("checked");
      if (boxes[i].checked !== on) boxes[i].checked = on;
    }
  }

  // An action greys the bar's buttons out, and a greyed-out button drops the
  // focus onto the page. While it runs, a focus lost goes to the unpublish
  // dialog's Cancel when the dialog is open, else to the bar. Selecting
  // ended in `pane`: a focus left on nothing, or on a tick that is out of
  // reach now, goes to the list's "List options".
  function onBulk(e) {
    var detail = e.detail || {};
    sync();
    if (!detail.pane) return;
    var at = doc.activeElement;
    var lost = !at || at === doc.body || !at.isConnected || at.disabled || (at.closest && at.closest("[inert]"));
    if (detail.running) {
      var bars = doc.querySelectorAll(".bulk-bar");
      for (var i = 0; lost && i < bars.length; i++) {
        if (bars[i].getAttribute("data-bulk-bar") !== detail.pane) continue;
        var cancel = bars[i].querySelector('[data-desk-dialog="bulk-unpublish"] [data-modal-focus]');
        (cancel || bars[i]).focus({ preventScroll: true });
      }
      return;
    }
    if (detail.active) return;
    if (!lost) return;
    var button = doc.getElementById(detail.pane + "-menu-button");
    if (button) button.focus({ preventScroll: true });
  }

  doc.addEventListener("click", onClick, true);
  doc.addEventListener("keydown", onKey, true);
  doc.addEventListener("phx:update", sync);
  window.addEventListener("phx:desk:bulk", onBulk);
  window.addEventListener("phx:desk:bulk-toast", function (e) {
    var detail = e.detail || {};
    if (detail.title) toast(detail.tone || "default", detail.title, detail.description);
  });

  window.BarkparkDeskBulk = { toast: toast, sync: sync };
})();
