// bp-tab-keys.js — arrow keys for Studio tab strips (task-9bf415c3d78b42d6).
//
// Three strips render role=tab buttons with a roving tabindex (only the
// selected tab is a Tab stop): the document editor's group tab bar and its
// view bar (editor.ex, .bp-tab-bar / .bp-view-bar, server round-trips), and an
// object field's groups (composite_field.ex, .bp-obj-tabs, switched client-side
// by the BarkparkFieldGroups hook). The role promises arrow keys, and a round-trip LiveView button
// cannot keep that promise on its own. A document-level listener (no phx-hook,
// the bp-array-focus.js pattern) does: ArrowLeft / ArrowRight / Home / End move
// focus to a tab and select it through the tab's own click, so the server's
// select-group stays the one path and the patch moves aria-selected/tabindex.
(function () {
  "use strict";

  var STRIP = '.bp-tab-bar[role="tablist"], .bp-view-bar[role="tablist"], .bp-obj-tabs[role="tablist"]';

  function target(tabs, from, key) {
    var n = tabs.length;
    if (key === "ArrowRight") return (from + 1) % n;
    if (key === "ArrowLeft") return (from - 1 + n) % n;
    if (key === "Home") return 0;
    if (key === "End") return n - 1;
    return -1;
  }

  document.addEventListener("keydown", function (e) {
    var tab = e.target && e.target.closest ? e.target.closest('[role="tab"]') : null;
    if (!tab) return;
    var strip = tab.closest(STRIP);
    if (!strip) return;
    var tabs = Array.prototype.slice.call(strip.querySelectorAll('[role="tab"]'));
    var to = target(tabs, tabs.indexOf(tab), e.key);
    if (to < 0) return;
    e.preventDefault();
    var next = tabs[to];
    // Focus first: a patch keeps this button, so focus survives it.
    next.focus();
    if (next.getAttribute("aria-selected") !== "true") next.click();
  });

  // A desk document opened by its URL has the focus on its field groups, as
  // the TanStack Studio's and Sanity's (keyboard.spec.ts J19): the first tab,
  // All fields, whichever group is selected. Only a focus nobody holds (the
  // page's) is taken. A key, a press, or a focus placed elsewhere ends it, and
  // so do OPEN_FOCUS_MS. Until then a patch that re-draws the bar and drops
  // the focus to the page gets it placed again. A row followed inside the
  // desk keeps the focus on the row (bp-desk.js); that is not a page load.
  var OPEN_FOCUS_MS = 5000;
  var OPEN_TAB = '[data-pane-editing] .bp-tab-bar[role="tablist"] [role="tab"]:not([disabled])';

  function openFocus(doc, win) {
    var observer = null;
    var timer = null;

    function free() {
      var a = doc.activeElement;
      return !a || a === doc.body || a === doc.documentElement;
    }
    function place() {
      var tab = doc.querySelector(OPEN_TAB);
      if (tab && free()) tab.focus({ preventScroll: true });
    }
    function stop() {
      if (observer) observer.disconnect();
      if (timer) win.clearTimeout(timer);
      doc.removeEventListener("keydown", stop, true);
      doc.removeEventListener("pointerdown", stop, true);
      doc.removeEventListener("focusin", elsewhere, true);
    }
    function elsewhere(e) {
      if (!e.target || !e.target.matches || !e.target.matches(OPEN_TAB)) stop();
    }

    doc.addEventListener("keydown", stop, true);
    doc.addEventListener("pointerdown", stop, true);
    doc.addEventListener("focusin", elsewhere, true);
    if (win.MutationObserver) {
      observer = new win.MutationObserver(place);
      observer.observe(doc.documentElement, { childList: true, subtree: true });
    }
    timer = win.setTimeout(stop, OPEN_FOCUS_MS);
    place();
    return stop;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { openFocus(document, window); }, { once: true });
  } else {
    openFocus(document, window);
  }

  window.BarkparkTabKeys = { target: target, openFocus: openFocus };
})();
