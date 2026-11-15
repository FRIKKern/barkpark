// bp-paper-find-bar.js — find and replace in the Studio paper editor
// (task-c1bf7f10239f73bf).
//
// The canvas finds, highlights and replaces (EMBED-CONTRACT.md, "Find and
// replace"); the host draws the bar. This file is that bar. Mod+F with focus
// inside a paper editor opens it; outside one, and in an editor with no
// canvas (the per-block list), the key is left to the browser's own find.
//
// A paper is several canvases: one per run of prose, split by the blocks that
// keep their own widget. Each canvas holds its own matches, so the bar asks
// every canvas, adds the counts up in document order and steps from the last
// match of one run to the first of the next. The canvas whose match is the
// current one carries `data-find-current`; the others paint theirs as a plain
// match.
//
// The bar opens as one row, which fits above the paper's title; the replace
// row opens from its button or with Mod+Alt+F, and stays as left. A paper
// that cannot be edited gets no replace row.
//
// Replace all is one transaction per canvas, so one undo step per run of
// prose it changed (a paper that is one run undoes it in one step).
//
// The count is read back from findState() after every change to the page
// while the bar is open, so typing in the paper or another editor's save
// keeps it right.
(function () {
  "use strict";
  if (typeof document === "undefined" || typeof window === "undefined") return;

  var nav = window.navigator || {};
  var MAC = /mac|iphone|ipad/i.test((nav.userAgentData && nav.userAgentData.platform) || nav.platform || "");
  var TYPING_PAUSE_MS = 120;
  var bar = null;
  var replaceOpen = false; // the replace row, as last left in this page
  var lastQuery = ""; // what was last searched for in this page

  var CSS =
    ".bp-find-bar{position:fixed;z-index:40;display:grid;gap:6px;box-sizing:border-box;width:min(440px,calc(100vw - 16px));padding:8px;" +
    "background:var(--surface-raised,var(--surface));color:var(--fg);border:1px solid var(--border);border-radius:var(--radius);" +
    "box-shadow:0 6px 24px hsl(0 0% 0% / 0.18);font-size:var(--text-sm);line-height:var(--text-sm-lh)}" +
    ".bp-find-bar__row{display:flex;align-items:center;gap:4px}" +
    ".bp-find-bar__row[hidden],.bp-find-bar__btn[hidden]{display:none}" +
    ".bp-find-bar__input{flex:1 1 auto;min-width:0;height:28px;padding:0 8px;box-sizing:border-box;border:1px solid var(--border);" +
    "border-radius:var(--radius-sm);background:var(--bg);color:inherit;font:inherit}" +
    ".bp-find-bar__count{flex:none;min-width:5.5em;text-align:right;white-space:nowrap;color:var(--fg-muted);font-variant-numeric:tabular-nums}" +
    ".bp-find-bar__btn{flex:none;height:28px;min-width:28px;padding:0 8px;border:1px solid transparent;border-radius:var(--radius-sm);" +
    "background:transparent;color:inherit;font:inherit;cursor:pointer}" +
    ".bp-find-bar__btn:hover:not(:disabled){background:var(--bg-accent)}" +
    ".bp-find-bar__btn[aria-pressed=\"true\"]{background:var(--primary-soft);border-color:var(--ring)}" +
    ".bp-find-bar__btn:disabled{opacity:.5;cursor:default}" +
    ".bp-find-bar__input:focus-visible,.bp-find-bar__btn:focus-visible{outline:2px solid var(--ring);outline-offset:-1px}" +
    "bp-paper-canvas:not([data-find-current]) .bp-find-match--active{background:hsl(var(--warn-hsl) / 0.28);outline:none}";

  function installCss() {
    if (document.getElementById("bp-find-bar-css")) return;
    var style = document.createElement("style");
    style.id = "bp-find-bar-css";
    style.textContent = CSS;
    (document.head || document.documentElement).appendChild(style);
  }

  // ── the editor and its canvases ────────────────────────────────────────────

  function editorRoot(node) {
    var el = node && node.nodeType === 1 ? node : node && node.parentElement;
    return el && typeof el.closest === "function" ? el.closest(".bp-paper-editor") : null;
  }

  // The canvases that can find, in document order. An element the bundle has
  // not upgraded yet has no findSet and is left out.
  function canvasesIn(root) {
    return Array.prototype.filter.call(root.querySelectorAll("bp-paper-canvas"), function (canvas) {
      return typeof canvas.findSet === "function" && typeof canvas.findState === "function";
    });
  }

  function editable(canvas) {
    return canvas.getAttribute("editable") !== "false";
  }

  function stateOf(canvas) {
    var st = canvas.findState() || {};
    var count = st.count > 0 ? st.count : 0;
    return { query: st.query || "", count: count, index: count && st.index >= 0 ? st.index : -1, caseSensitive: !!st.caseSensitive };
  }

  // ── words ──────────────────────────────────────────────────────────────────

  function readStrings(root) {
    try { return JSON.parse(root.getAttribute("data-paper-strings") || "{}") || {}; } catch (_) { return {}; }
  }

  function t(text, vars) {
    var out = bar && typeof bar.strings[text] === "string" ? bar.strings[text] : text;
    return out.replace(/%\{(\w+)\}/g, function (slot, name) {
      return vars && Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : slot;
    });
  }

  // ── the bar ────────────────────────────────────────────────────────────────

  function make(tag, cls, attrs) {
    var el = document.createElement(tag);
    el.className = cls;
    for (var name in attrs || {}) el.setAttribute(name, attrs[name]);
    return el;
  }

  function button(text, label, action) {
    var el = make("button", "bp-find-bar__btn", { type: "button", "data-find": action });
    el.textContent = text;
    if (label !== text) { el.setAttribute("aria-label", label); el.title = label; }
    return el;
  }

  function build() {
    var el = make("div", "bp-find-bar", { role: "search", "aria-label": t("Find and replace"), "data-test-id": "paper-find-bar" });
    var findRow = make("div", "bp-find-bar__row");
    var replaceRow = make("div", "bp-find-bar__row", { "data-find": "replace-row" });
    bar.find = make("input", "bp-find-bar__input", {
      type: "text", "aria-label": t("Find"), placeholder: t("Find"), "data-find": "query",
      autocomplete: "off", autocapitalize: "off", spellcheck: "false", enterkeyhint: "search",
    });
    bar.count = make("span", "bp-find-bar__count", { role: "status", "aria-live": "polite", "data-find": "count" });
    bar.caseBtn = button("Aa", t("Match case"), "case");
    bar.caseBtn.setAttribute("aria-pressed", "false");
    bar.prevBtn = button("↑", t("Previous match"), "prev");
    bar.nextBtn = button("↓", t("Next match"), "next");
    bar.toggleBtn = button("⇄", t("Show replace"), "toggle");
    bar.replace = make("input", "bp-find-bar__input", {
      type: "text", "aria-label": t("Replace with"), placeholder: t("Replace with"), "data-find": "replacement",
      autocomplete: "off", autocapitalize: "off", spellcheck: "false",
    });
    bar.replaceBtn = button(t("Replace"), t("Replace"), "replace");
    bar.replaceAllBtn = button(t("Replace all"), t("Replace all"), "replace-all");
    [bar.find, bar.count, bar.caseBtn, bar.prevBtn, bar.nextBtn, bar.toggleBtn, button("×", t("Close"), "close")]
      .forEach(function (child) { findRow.appendChild(child); });
    [bar.replace, bar.replaceBtn, bar.replaceAllBtn].forEach(function (child) { replaceRow.appendChild(child); });
    el.appendChild(findRow);
    el.appendChild(replaceRow);
    bar.replaceRow = replaceRow;
    el.addEventListener("input", onInput);
    el.addEventListener("click", onClick);
    el.addEventListener("keydown", onBarKeydown);
    return el;
  }

  // Top right of the pane that scrolls the paper, so the bar stays put while
  // the paper moves under it; with no such pane, top right of the editor.
  function place() {
    if (!bar) return;
    var box = bar.root.getBoundingClientRect();
    for (var el = bar.root.parentElement; el && el !== document.body; el = el.parentElement) {
      var overflow = window.getComputedStyle(el).overflowY;
      if (overflow === "auto" || overflow === "scroll") { box = el.getBoundingClientRect(); break; }
    }
    bar.el.style.top = Math.max(box.top, 0) + 8 + "px";
    bar.el.style.right = Math.max((window.innerWidth || 0) - box.right, 0) + 8 + "px";
  }

  // ── find ───────────────────────────────────────────────────────────────────

  function withMatches(list) {
    return list.filter(function (canvas) { return stateOf(canvas).count > 0; });
  }

  // Hand the query to every canvas that does not hold it yet (a new query, or
  // a canvas mounted since), then settle which canvas holds the current match.
  function sync() {
    var query = bar.find.value;
    var caseSensitive = bar.caseBtn.getAttribute("aria-pressed") === "true";
    var list = canvasesIn(bar.root);
    list.forEach(function (canvas) {
      var st = stateOf(canvas);
      if (!query) { if (st.query) canvas.findClear(); return; }
      if (st.query !== query || st.caseSensitive !== caseSensitive) canvas.findSet(query, { caseSensitive: caseSensitive });
    });
    var holds = bar.cur && list.indexOf(bar.cur) !== -1 && stateOf(bar.cur).count > 0;
    if (!holds) {
      var from = Math.max(list.indexOf(bar.cur && bar.cur.isConnected ? bar.cur : bar.origin), 0);
      var next = withMatches(list.slice(from).concat(list.slice(0, from)))[0];
      if (next) bar.cur = next;
    }
    return list;
  }

  // Move a canvas's active match to `target` by the shorter way round.
  function seek(canvas, target) {
    var st = stateOf(canvas);
    if (!st.count) return;
    var forward = (target - st.index + st.count) % st.count;
    var back = st.count - forward;
    for (var i = Math.min(forward, back); i > 0; i--) forward <= back ? canvas.findNext() : canvas.findPrev();
  }

  function step(delta) {
    if (!bar) return;
    var matching = withMatches(sync());
    if (!matching.length) return render();
    var at = Math.max(matching.indexOf(bar.cur), 0);
    var cur = matching[at];
    var st = stateOf(cur);
    var atEdge = delta > 0 ? st.index >= st.count - 1 : st.index <= 0;
    if (!atEdge || matching.length === 1) {
      delta > 0 ? cur.findNext() : cur.findPrev();
    } else {
      cur = matching[(at + delta + matching.length) % matching.length];
      seek(cur, delta > 0 ? 0 : stateOf(cur).count - 1);
    }
    bar.cur = cur;
    bar.said = "";
    render();
    reveal();
  }

  function search() {
    if (!bar) return;
    window.clearTimeout(bar.typing);
    bar.said = "";
    sync();
    render();
    reveal();
  }

  // Bring the current match into view. The canvas scrolls only while it holds
  // the focus, and here the bar does.
  function reveal() {
    var hit = bar.cur && bar.cur.querySelector(".bp-find-match--active");
    if (!hit || typeof hit.scrollIntoView !== "function") return;
    var box = hit.getBoundingClientRect();
    var barBottom = bar.el.getBoundingClientRect().bottom;
    if (box.top < barBottom + 8 || box.bottom > (window.innerHeight || 0) - 24) hit.scrollIntoView({ block: "center", inline: "nearest" });
  }

  function render() {
    if (!bar) return;
    var held = bar.el.contains(document.activeElement) ? document.activeElement : null;
    var list = canvasesIn(bar.root);
    var total = 0, position = 0;
    list.forEach(function (canvas) {
      var st = stateOf(canvas);
      if (canvas === bar.cur && st.count) position = total + st.index + 1;
      total += st.count;
      canvas === bar.cur && st.count ? canvas.setAttribute("data-find-current", "") : canvas.removeAttribute("data-find-current");
    });
    var text = bar.said ||
      (!bar.find.value ? "" : total ? t("%{index} of %{count}", { index: position || 1, count: total }) : t("No matches"));
    if (bar.count.textContent !== text) bar.count.textContent = text;
    var canReplace = list.some(editable);
    bar.toggleBtn.hidden = !canReplace;
    bar.toggleBtn.setAttribute("aria-expanded", replaceOpen ? "true" : "false");
    bar.replaceRow.hidden = !canReplace || !replaceOpen;
    bar.prevBtn.disabled = bar.nextBtn.disabled = !total;
    bar.replaceBtn.disabled = bar.replaceAllBtn.disabled = !total || !canReplace;
    // A button that held the focus and is now off would drop it to the page.
    if (held && held.disabled) bar.find.focus();
  }

  // ── replace ────────────────────────────────────────────────────────────────

  function replaceOne() {
    var cur = withMatches(sync()).indexOf(bar.cur) === -1 ? null : bar.cur;
    if (!cur || !editable(cur)) return render();
    var before = stateOf(cur);
    cur.replaceCurrent(bar.replace.value);
    var after = stateOf(cur);
    bar.said = "";
    if (after.count >= before.count) {
      // The new text holds the query too: step past what it added.
      for (var i = Math.min(after.count - before.count + 1, 50); i > 0; i--) step(1);
    } else if (before.index === before.count - 1) {
      // That was the run's last match: on to the next run's first.
      var matching = withMatches(sync());
      var later = canvasesIn(bar.root).indexOf(cur);
      var next = matching.filter(function (canvas) { return canvasesIn(bar.root).indexOf(canvas) > later; })[0] || matching[0];
      if (next) { seek(next, 0); bar.cur = next; }
    }
    render();
    reveal();
  }

  function replaceAll() {
    var replaced = 0;
    sync().forEach(function (canvas) {
      if (!editable(canvas)) return;
      var result = canvas.replaceAll(bar.replace.value) || {};
      replaced += result.replaced > 0 ? result.replaced : 0;
    });
    bar.said = t("Replaced %{count}", { count: replaced });
    sync();
    render();
  }

  // ── open, close, keys ──────────────────────────────────────────────────────

  function selectedText(root) {
    var sel = typeof window.getSelection === "function" ? window.getSelection() : null;
    if (!sel || sel.isCollapsed || !sel.anchorNode || !root.contains(sel.anchorNode)) return "";
    var text = String(sel);
    return text && text.length <= 200 && !/[\r\n]/.test(text) ? text : "";
  }

  function open(root, from, withReplace) {
    if (bar && bar.root !== root) close(false);
    if (withReplace) replaceOpen = true;
    var picked = selectedText(root);
    if (!bar) {
      var list = canvasesIn(root);
      var origin = from && typeof from.closest === "function" ? from.closest("bp-paper-canvas") : null;
      bar = { root: root, strings: readStrings(root), origin: list.indexOf(origin) === -1 ? list[0] : origin, cur: null, said: "", typing: 0 };
      installCss();
      bar.el = build();
      document.body.appendChild(bar.el);
      bar.watch = new window.MutationObserver(onPageChange);
      bar.watch.observe(document.body, { childList: true, subtree: true, characterData: true });
      window.addEventListener("resize", place);
      window.addEventListener("scroll", place, true);
    }
    if (picked) bar.find.value = picked;
    else if (!bar.find.value) bar.find.value = lastQuery;
    place();
    bar.find.focus();
    bar.find.select();
    search();
  }

  function close(refocus) {
    if (!bar) return;
    var was = bar;
    bar = null;
    lastQuery = was.find.value;
    window.clearTimeout(was.typing);
    window.clearTimeout(was.reading);
    was.watch.disconnect();
    window.removeEventListener("resize", place);
    window.removeEventListener("scroll", place, true);
    var target = was.cur && was.cur.isConnected && stateOf(was.cur).count ? was.cur : was.origin;
    canvasesIn(was.root).forEach(function (canvas) {
      canvas.findClear();
      canvas.removeAttribute("data-find-current");
    });
    was.el.remove();
    // Back to the paper: on the match last shown, or the caret as it was.
    if (refocus && target && target.isConnected && typeof target.focusSelection === "function") target.focusSelection();
  }

  // The page changed (typing in the paper, a save from elsewhere, a canvas
  // mounted or gone): read the counts again. The bar's own changes do not count.
  function onPageChange(records) {
    if (!bar) return;
    var outside = records.some(function (record) { return !bar.el.contains(record.target); });
    if (!outside || bar.reading) return;
    bar.reading = window.setTimeout(function () {
      if (!bar) return;
      bar.reading = 0;
      if (!bar.root.isConnected) return close(false);
      sync();
      render();
      place();
    }, 0);
  }

  function onInput(event) {
    if (event.target !== bar.find) return;
    window.clearTimeout(bar.typing);
    bar.typing = window.setTimeout(search, TYPING_PAUSE_MS);
  }

  function onClick(event) {
    var el = event.target && event.target.closest ? event.target.closest("[data-find]") : null;
    var action = el && !el.disabled ? el.getAttribute("data-find") : "";
    if (action === "case") {
      el.setAttribute("aria-pressed", el.getAttribute("aria-pressed") === "true" ? "false" : "true");
      search();
    } else if (action === "next" || action === "prev") {
      search();
      step(action === "next" ? 1 : -1);
    } else if (action === "toggle") {
      replaceOpen = !replaceOpen;
      render();
      if (replaceOpen) bar.replace.focus();
    } else if (action === "replace") replaceOne();
    else if (action === "replace-all") replaceAll();
    else if (action === "close") close(true);
  }

  function onBarKeydown(event) {
    if (event.isComposing) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close(true);
    } else if (event.key === "Enter" && event.target === bar.find) {
      event.preventDefault();
      // A query typed and entered inside the typing pause is searched first.
      if (stateOf(bar.cur || bar.origin).query !== bar.find.value) search();
      else step(event.shiftKey ? -1 : 1);
    } else if (event.key === "Enter" && event.target === bar.replace) {
      event.preventDefault();
      replaceOne();
    }
  }

  function onKeydown(event) {
    if (event.isComposing) return;
    var mod = MAC ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey;
    if (!mod) return;
    // With Alt the key is the bar with its replace row open (and on a Mac
    // Alt changes the letter, so that one is read from the key's place).
    var key = event.altKey ? (event.code === "KeyF" ? "alt-f" : "") : String(event.key || "").toLowerCase();
    var inBar = !!bar && bar.el.contains(event.target);
    if ((key === "f" || key === "alt-f") && !event.shiftKey) {
      var root = inBar ? bar.root : editorRoot(event.target);
      if (!root || !canvasesIn(root).length) return; // the browser's own find
      event.preventDefault();
      event.stopPropagation();
      open(root, event.target, key === "alt-f");
    } else if (key === "g" && bar && (inBar || bar.root.contains(event.target))) {
      event.preventDefault();
      event.stopPropagation();
      search();
      step(event.shiftKey ? -1 : 1);
    }
  }

  document.addEventListener("keydown", onKeydown, true);

  window.BarkparkPaperFindBar = {
    open: function (root) { if (root && canvasesIn(root).length) open(root, document.activeElement); },
    close: function () { close(true); },
  };
})();
