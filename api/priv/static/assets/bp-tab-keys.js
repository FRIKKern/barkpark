// bp-tab-keys.js — arrow keys for Studio tab strips (task-9bf415c3d78b42d6).
//
// The document editor's group tab bar (editor.ex, .bp-tab-bar role=tablist)
// renders role=tab buttons with a roving tabindex: only the selected tab is a
// Tab stop. The role promises arrow keys, and a round-trip LiveView button
// cannot keep that promise on its own. A document-level listener (no phx-hook,
// the bp-array-focus.js pattern) does: ArrowLeft / ArrowRight / Home / End move
// focus to a tab and select it through the tab's own click, so the server's
// select-group stays the one path and the patch moves aria-selected/tabindex.
(function () {
  "use strict";

  var STRIP = '.bp-tab-bar[role="tablist"]';

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
    // Focus first: the patch keeps this button (same id), so focus survives it.
    next.focus();
    if (next.getAttribute("aria-selected") !== "true") next.click();
  });

  window.BarkparkTabKeys = { target: target };
})();
