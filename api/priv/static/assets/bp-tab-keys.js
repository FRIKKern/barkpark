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

  window.BarkparkTabKeys = { target: target };
})();
