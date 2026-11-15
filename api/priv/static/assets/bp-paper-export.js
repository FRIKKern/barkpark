// bp-paper-export.js — take a paper out of the Studio paper editor
// (task-a5ba0a62b64635ac).
//
// The paper header's Export button (PaperExport.export_button/1) opens a menu:
// Download Markdown, Copy as Markdown, Print / Save as PDF. This file is that
// menu. It reads and never writes: no op, no flush, no request of its own, so
// it works the same for a viewer who cannot edit.
//
//   .bp-paper-editor
//     .bp-paper-edit-canvas  ─► canvas.toMarkdown()             the run on screen,
//     .bp-paper-edit-block   ─► toMarkdown({ blocks: [block] })  unsaved typing included
//     .bp-paper-edit-canvas  ─► canvas.toMarkdown()
//
// A paper is one canvas per run of prose, split by the blocks that keep their
// own editor (a table, steps, tabs, a figure). The canvas converts its own run
// (EMBED-CONTRACT.md, "Markdown export"). The blocks between runs are not in
// any canvas, so the button carries them as saved, in order, and the same
// converter takes each. Canvases nested inside such a block are skipped: the
// block already holds what they show.
//
// Print opens the paper's reader page, which has the print styles and none of
// the Studio's chrome, and prints it. The reader shows the published version,
// so the menu says so for a draft, and the item is off for a paper that was
// never published.
(function () {
  "use strict";
  if (typeof document === "undefined" || typeof window === "undefined") return;

  var COPIED_MS = 1800;
  var PRINT_SETTLE_MS = 700; // the reader draws its diagrams after load
  var PRINT_GIVE_UP_MS = 20000;
  var menu = null; // the open menu: { el, source, button, strings, items, copy, copied }

  var CSS =
    ".bp-paper-export{display:inline-flex}" +
    ".bp-export-menu{position:fixed;z-index:40;box-sizing:border-box;width:min(280px,calc(100vw - 16px));padding:4px;display:grid;gap:2px;" +
    "background:var(--surface-raised,var(--surface));color:var(--fg);border:1px solid var(--border);border-radius:var(--radius);" +
    "box-shadow:0 6px 24px hsl(0 0% 0% / 0.18);font-size:var(--text-sm);line-height:var(--text-sm-lh)}" +
    ".bp-export-menu__item{display:block;width:100%;min-height:32px;padding:6px 8px;border:0;border-radius:var(--radius-sm);" +
    "background:transparent;color:inherit;font:inherit;text-align:left;cursor:pointer}" +
    ".bp-export-menu__item:hover:not([aria-disabled=\"true\"]){background:var(--bg-accent)}" +
    ".bp-export-menu__item:focus-visible{outline:2px solid var(--ring);outline-offset:-2px}" +
    ".bp-export-menu__item[aria-disabled=\"true\"]{color:var(--fg-muted);cursor:default}" +
    ".bp-export-menu__note{margin:0;padding:6px 8px 4px;border-top:1px solid var(--border);color:var(--fg-muted);font-size:var(--text-xs,12px);line-height:1.4}" +
    ".bp-export-menu__note[data-export-note=\"status\"]{position:absolute;width:1px;height:1px;padding:0;border:0;overflow:hidden;clip-path:inset(50%)}" +
    ".bp-export-menu__note[data-export-note=\"error\"]:empty{display:none}" +
    ".bp-export-menu__note[data-export-note=\"error\"]{color:var(--danger,inherit)}";

  function installCss() {
    if (document.getElementById("bp-export-menu-css")) return;
    var style = document.createElement("style");
    style.id = "bp-export-menu-css";
    style.textContent = CSS;
    (document.head || document.documentElement).appendChild(style);
  }

  // ── the paper ──────────────────────────────────────────────────────────────

  function editorOf(source) {
    return document.getElementById(source.getAttribute("data-paper-export-editor") || "");
  }

  function readJson(el, name, fallback) {
    try { return JSON.parse((el && el.getAttribute(name)) || "") || fallback; } catch (_) { return fallback; }
  }

  function t(text, strings) {
    return strings && typeof strings[text] === "string" ? strings[text] : text;
  }

  function converts(canvas) {
    return !!canvas && typeof canvas.toMarkdown === "function";
  }

  // The paper's own parts in document order: each run's canvas wrapper and each
  // block between runs. A part inside a block between runs belongs to it.
  function parts(root) {
    return Array.prototype.filter.call(root.querySelectorAll(".bp-paper-edit-canvas, .bp-paper-edit-block"), function (el) {
      var outer = el.parentElement && el.parentElement.closest(".bp-paper-edit-block");
      return !outer || !root.contains(outer);
    });
  }

  // The saved block for a block between runs: by id, else the next one of its
  // type that no element has taken.
  function takeBlock(el, kept) {
    var id = el.getAttribute("data-edit-block-id");
    var type = el.getAttribute("data-block-type");
    var at = -1;
    kept.forEach(function (entry, i) {
      if (at === -1 && !entry.taken && id && entry.block.id === id) at = i;
    });
    kept.forEach(function (entry, i) {
      if (at === -1 && !entry.taken && !entry.block.id && entry.block.type === type) at = i;
    });
    if (at === -1) return { type: type || "block" };
    kept[at].taken = true;
    return kept[at].block;
  }

  // The whole paper as Markdown, or null while no canvas can convert (the
  // editor bundle has not loaded, or the paper is not open in the editor).
  function markdown(source, strings) {
    var root = editorOf(source);
    if (!root) return null;
    var list = parts(root);
    var converter = Array.prototype.filter.call(root.querySelectorAll("bp-paper-canvas"), converts)[0];
    if (!converter) {
      var spare = document.createElement("bp-paper-canvas");
      if (!converts(spare)) return null;
      converter = spare;
    }
    var options = { baseUrl: document.baseURI, placeholder: t("%{block}: not included in Markdown export", strings) };
    var convert = function (blocks) {
      return converter.toMarkdown({ blocks: blocks, baseUrl: options.baseUrl, placeholder: options.placeholder });
    };
    var kept = readJson(source, "data-paper-export-blocks", []).map(function (block) { return { block: block, taken: false }; });
    var out = [];
    list.forEach(function (el) {
      var text;
      if (el.classList.contains("bp-paper-edit-canvas")) {
        var canvas = el.querySelector("bp-paper-canvas");
        text = converts(canvas) ? canvas.toMarkdown(options) : convert(readJson(el, "data-canvas-blocks", []));
      } else {
        text = convert([takeBlock(el, kept)]);
      }
      if (typeof text === "string" && text.trim() !== "") out.push(text.replace(/\s+$/, ""));
    });
    var title = (source.getAttribute("data-paper-export-title") || "").trim();
    if (title && !/^# /.test(out[0] || "")) out.unshift(convert([{ type: "heading", level: 1, text: title }]));
    return out.join("\n\n") + "\n";
  }

  function fileName(source) {
    var name = (source.getAttribute("data-paper-export-file") || "").replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[-.]+|[-.]+$/g, "");
    return (name || "paper") + ".md";
  }

  // ── the three actions ──────────────────────────────────────────────────────

  function download(source, text) {
    var url = window.URL.createObjectURL(new window.Blob([text], { type: "text/markdown;charset=utf-8" }));
    var link = document.createElement("a");
    link.href = url;
    link.download = fileName(source);
    link.hidden = true;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(function () { window.URL.revokeObjectURL(url); }, 10000);
  }

  function copy(text) {
    var clip = window.navigator && window.navigator.clipboard;
    if (clip && typeof clip.writeText === "function") return clip.writeText(text);
    return new Promise(function (resolve, reject) {
      var area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.cssText = "position:fixed;top:0;left:-9999px";
      document.body.appendChild(area);
      area.select();
      var done = false;
      try { done = document.execCommand("copy"); } catch (_) { done = false; }
      area.remove();
      done ? resolve() : reject(new Error("copy refused"));
    });
  }

  // Open the reader page and print it once it has loaded and drawn.
  function print(href) {
    var page = window.open(href, "_blank");
    if (!page) return false;
    var started = Date.now();
    var poll = window.setInterval(function () {
      var ready = false;
      try { ready = page.closed || (page.location.href !== "about:blank" && page.document.readyState === "complete"); } catch (_) { ready = true; }
      if (!ready && Date.now() - started < PRINT_GIVE_UP_MS) return;
      window.clearInterval(poll);
      if (!ready || page.closed) return;
      window.setTimeout(function () {
        try { page.focus(); page.print(); } catch (_) { /* the reader is open; the writer can print it */ }
      }, PRINT_SETTLE_MS);
    }, 150);
    return true;
  }

  // ── the menu ───────────────────────────────────────────────────────────────

  function make(tag, cls, attrs) {
    var el = document.createElement(tag);
    el.className = cls;
    for (var name in attrs || {}) el.setAttribute(name, attrs[name]);
    return el;
  }

  function item(label, action, off) {
    var el = make("button", "bp-export-menu__item", { type: "button", role: "menuitem", tabindex: "-1", "data-export": action });
    el.textContent = label;
    if (off) el.setAttribute("aria-disabled", "true");
    return el;
  }

  function note(text, kind) {
    var el = make("p", "bp-export-menu__note", { "data-export-note": kind });
    el.textContent = text;
    return el;
  }

  // What Print will print, said before it prints.
  function printNote(source, strings) {
    var state = source.getAttribute("data-paper-export-print-state");
    if (!source.getAttribute("data-paper-export-print")) return t("Publish this paper to print it.", strings);
    if (state === "draft") return t("Print uses the published version. Changes in this draft are not in it.", strings);
    return t("Print opens the published page in a new tab.", strings);
  }

  function place() {
    if (!menu) return;
    var box = menu.button.getBoundingClientRect();
    var width = menu.el.offsetWidth || 280;
    var left = Math.min(Math.max(box.right - width, 8), Math.max((window.innerWidth || 0) - width - 8, 8));
    menu.el.style.top = box.bottom + 4 + "px";
    menu.el.style.left = left + "px";
  }

  // The menu's live line: read out, and shown when it is an error.
  function say(held, kind, text) {
    held.status.setAttribute("data-export-note", kind);
    held.status.textContent = text;
  }

  function open(source, focusFirst) {
    close(false);
    var button = source.querySelector("[data-paper-export-toggle]");
    if (!button) return;
    var strings = readJson(editorOf(source), "data-paper-strings", {});
    installCss();
    var el = make("div", "bp-export-menu", { role: "menu", "aria-label": t("Export", strings), "data-test-id": "paper-export-menu" });
    var canPrint = !!source.getAttribute("data-paper-export-print");
    var copyItem = item(t("Copy as Markdown", strings), "copy", false);
    var status = make("p", "bp-export-menu__note", { role: "status", "aria-live": "polite", "data-export-note": "status" });
    [
      item(t("Download Markdown", strings), "download", false),
      copyItem,
      item(t("Print / Save as PDF", strings), "print", !canPrint),
      note(t("Markdown is text first. A block it cannot hold becomes a one-line note.", strings), "markdown"),
      note(printNote(source, strings), "print"),
      status,
    ].forEach(function (child) { el.appendChild(child); });
    menu = { el: el, source: source, button: button, strings: strings, copy: copyItem, status: status, copied: 0 };
    el.addEventListener("click", onMenuClick);
    el.addEventListener("keydown", onMenuKeydown);
    document.body.appendChild(el);
    button.setAttribute("aria-expanded", "true");
    place();
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    if (focusFirst) el.querySelector("[role=menuitem]").focus();
  }

  function close(refocus) {
    if (!menu) return;
    var was = menu;
    menu = null;
    window.clearTimeout(was.copied);
    window.removeEventListener("resize", place);
    window.removeEventListener("scroll", place, true);
    was.el.remove();
    was.button.setAttribute("aria-expanded", "false");
    if (refocus && was.button.isConnected) was.button.focus();
  }

  function fail() {
    if (menu) say(menu, "error", t("The paper is still loading. Try again in a moment.", menu.strings));
  }

  function run(action) {
    if (!menu) return;
    var source = menu.source;
    if (action === "print") {
      var href = source.getAttribute("data-paper-export-print");
      if (!href) return;
      close(true);
      print(href);
      return;
    }
    var text = markdown(source, menu.strings);
    if (text === null) return fail();
    if (action === "download") {
      download(source, text);
      close(true);
    } else if (action === "copy") {
      var held = menu;
      copy(text).then(function () {
        if (menu !== held) return;
        held.copy.textContent = t("Copied", held.strings);
        say(held, "status", t("Copied", held.strings));
        window.clearTimeout(held.copied);
        held.copied = window.setTimeout(function () {
          if (menu === held) held.copy.textContent = t("Copy as Markdown", held.strings);
        }, COPIED_MS);
      }, function () {
        if (menu !== held) return;
        say(held, "error", t("The browser did not allow the copy. Download the file instead.", held.strings));
      });
    }
  }

  function onMenuClick(event) {
    var el = event.target && event.target.closest ? event.target.closest("[data-export]") : null;
    if (!el || el.getAttribute("aria-disabled") === "true") return;
    run(el.getAttribute("data-export"));
  }

  function onMenuKeydown(event) {
    if (!menu) return;
    var items = Array.prototype.slice.call(menu.el.querySelectorAll("[role=menuitem]"));
    var at = items.indexOf(document.activeElement);
    var to = -1;
    if (event.key === "Tab") return close(false);
    if (event.key === "ArrowDown") to = (at + 1) % items.length;
    else if (event.key === "ArrowUp") to = (at - 1 + items.length) % items.length;
    else if (event.key === "Home") to = 0;
    else if (event.key === "End") to = items.length - 1;
    if (to === -1) return;
    event.preventDefault();
    items[to].focus();
  }

  function toggleOf(node) {
    var el = node && node.nodeType === 1 ? node : node && node.parentElement;
    return el && typeof el.closest === "function" ? el.closest("[data-paper-export-toggle]") : null;
  }

  // A click on the button opens or closes; a click anywhere else closes. The
  // keyboard's own click (Enter, Space) has no pointer, so it lands in the menu.
  document.addEventListener("click", function (event) {
    var button = toggleOf(event.target);
    if (button) {
      var source = button.closest("[data-paper-export]");
      if (!source) return;
      if (menu && menu.source === source) close(true);
      else open(source, event.detail === 0);
    } else if (menu && !menu.el.contains(event.target)) {
      close(false);
    }
  }, true);

  document.addEventListener("keydown", function (event) {
    var button = toggleOf(event.target);
    if (button && (event.key === "ArrowDown" || event.key === "ArrowUp") && !menu) {
      var source = button.closest("[data-paper-export]");
      if (!source) return;
      event.preventDefault();
      open(source, true);
    } else if (menu && event.key === "Escape") {
      // Before the Studio's own Escape, which would leave the pane.
      event.preventDefault();
      event.stopPropagation();
      close(true);
    }
  }, true);

  window.BarkparkPaperExport = {
    markdown: function (source) { return markdown(source, readJson(editorOf(source), "data-paper-strings", {})); },
    open: function (source) { open(source, true); },
    close: function () { close(true); },
  };
})();
