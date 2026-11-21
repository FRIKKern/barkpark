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

  // A desk document takes the focus into its form as it opens, as the
  // TanStack Studio's and Sanity's do (keyboard.spec.ts J19, panes.spec.ts
  // J01 J02): the first group tab, All fields, whichever group is selected,
  // or with no groups its form's first control (the first field's actions).
  //
  // Opened by its URL (a page load): only a focus nobody holds (the page's)
  // is taken. Opened inside the desk (a list row clicked or Entered, a
  // reference followed, Forward): the pane the new URL ends on takes it from
  // a row or a link too, but a focus in that pane, in a box being typed in
  // (an input, a textarea, a select, an editable), or in a dialog, menu or
  // listbox stays. Back, a pane closed, a save, a presence change, a revision
  // or an inspector of the same document open nothing, so move nothing.
  // A key or a press ends it, and so do OPEN_FOCUS_MS. Until then a patch
  // that re-draws the form and drops the focus gets it placed again.
  var OPEN_FOCUS_MS = 5000;
  var CONTROL = 'button, a[href], input:not([type="hidden"]), select, textarea, [tabindex]:not([tabindex="-1"])';
  var KEEPS = '[role="dialog"], [role="menu"], [role="listbox"], dialog';

  // The control a document's form starts with: the bar's first enabled group
  // tab while the bar is drawn (All fields is never disabled; while History is
  // open the others wait, disabled), else the form's first control outside a
  // menu or dialog it holds.
  function formStart(pane) {
    if (!pane) return null;
    var bar = pane.querySelector('.bp-tab-bar[role="tablist"]');
    if (bar) return bar.querySelector('[role="tab"]:not([disabled])');
    var form = pane.querySelector("form#editor-form");
    if (!form) return null;
    var controls = Array.prototype.filter.call(form.querySelectorAll(CONTROL), function (el) {
      return !el.disabled && !el.closest("[hidden], [popover], " + KEEPS);
    });
    return controls[0] || null;
  }

  // `id`: the document the desk opened (its pane's `data-pane` is doc:<id>);
  // none for a page load, which takes the first edit pane's.
  function openFocus(doc, win, id) {
    var observer = null;
    var timer = null;
    var live = true;
    var opened = id !== undefined && id !== null;

    function pane() {
      var all = doc.querySelectorAll("[data-pane-editing]");
      if (!opened) return all[0] || null;
      return Array.prototype.filter.call(all, function (el) {
        return el.getAttribute("data-pane") === "doc:" + id;
      })[0] || null;
    }
    function free(a) {
      return !a || a === doc.body || a === doc.documentElement;
    }
    // A focus that stays where it is (TanStack's `stays`).
    function keeps(a, at) {
      if (free(a)) return false;
      if (!opened) return true;
      if (at && a !== at && at.contains(a)) return true;
      return !!(a.matches && a.matches("input, textarea, select")) || a.isContentEditable || !!(a.closest && a.closest(KEEPS));
    }
    function place() {
      if (!live) return;
      var at = pane();
      var start = formStart(at);
      var a = doc.activeElement;
      if (!start || a === start || keeps(a, at)) return;
      start.focus({ preventScroll: true });
    }
    function stop() {
      live = false;
      if (observer) observer.disconnect();
      if (timer) win.clearTimeout(timer);
      doc.removeEventListener("keydown", stop, true);
      doc.removeEventListener("pointerdown", stop, true);
      doc.removeEventListener("focusin", elsewhere, true);
    }
    // A focus placed elsewhere ends it, when it is one that stays. Inside the
    // desk a followed row can take the focus back (bp-desk.js) before the
    // form is in: that one does not stay.
    function elsewhere(e) {
      var at = pane();
      if (e.target === formStart(at)) return;
      if (!opened || keeps(e.target, at)) stop();
      else win.setTimeout(place, 0);
    }

    doc.addEventListener("keydown", stop, true);
    doc.addEventListener("pointerdown", stop, true);
    doc.addEventListener("focusin", elsewhere, true);
    if (win.MutationObserver) {
      observer = new win.MutationObserver(place);
      observer.observe(doc.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["disabled"] });
    }
    timer = win.setTimeout(stop, OPEN_FOCUS_MS);
    place();
    return stop;
  }

  // The document a desk URL change opened: the id its last pane names, when
  // the URL before named another (or nothing) there. A shorter URL (a pane
  // closed), the same document with other parameters (a revision, an
  // inspector) or a list open nothing.
  function openedBy(was, now) {
    var id = function (seg) {
      if (seg === undefined) return null;
      try {
        return decodeURIComponent(seg.split(",")[0]);
      } catch (_e) {
        return seg.split(",")[0];
      }
    };
    var before = String(was || "").split("/").pop().split(";");
    var after = String(now || "").split("/").pop().split(";");
    if (after.length < 2) return null;
    var last = id(after[after.length - 1]);
    return last && last !== id(before[after.length - 1]) ? last : null;
  }

  var current = null;
  var path = window.location.pathname;
  function arm(id) {
    if (current) current();
    current = openFocus(document, window, id);
  }
  window.addEventListener("phx:navigate", function (e) {
    var d = (e && e.detail) || {};
    var was = path;
    try {
      path = new URL(d.href || window.location.href, window.location.href).pathname;
    } catch (_e) {
      path = window.location.pathname;
    }
    // Back moves nothing (its own focus rule); Forward opens as a click does.
    if (d.pop && d.direction !== "forward") return;
    var id = openedBy(was, path);
    if (id) arm(id);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { arm(); }, { once: true });
  } else {
    arm();
  }

  window.BarkparkTabKeys = { target: target, openFocus: openFocus, openedBy: openedBy, formStart: formStart };
})();
