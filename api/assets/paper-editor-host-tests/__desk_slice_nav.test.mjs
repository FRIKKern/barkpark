// __desk_slice_nav.test.mjs — the desk slice's click (task-d44490e885174ac5,
// /papers/desk-vertical-slice): a row click draws the pane it opens BEFORE the
// server answers, a modifier click is left to the browser, and hovering or
// focusing a row asks the server to read ahead.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom
// on panes shaped like BarkparkWeb.Studio.Desk.PaneComponent's render. The
// LiveView socket is never there: nothing below gets an answer from a server,
// which is the point.
//
// Run: node ../paper-editor-host-tests/__desk_slice_nav.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: `http://localhost${BASE}/post;post-a`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");
assert.equal(typeof window.BarkparkDesk?.mounted, "function", "bp-desk.js defines the hook");

const row = (href, title, opens, current) =>
  `<a href="${BASE}/${href}" class="pane-item${current ? " selected" : ""}"${current ? ' aria-current="true"' : ""} data-desk-row data-desk-opens="${opens}"><span class="pane-item-label">${title}</span></a>`;
const pane = (index, kind, rows) =>
  `<section class="pane-column dk-pane" id="p${index}" data-pane-index="${index}" data-pane-kind="${kind}"><div class="pane-header"></div><div class="pane-body">${rows}</div></section>`;

function mount() {
  window.document.body.innerHTML =
    `<div id="desk-panes">` +
    pane(0, "types", row("post", "Posts", "list", true) + row("author", "Authors", "list", false)) +
    pane(1, "list", row("post;post-a", "Alpha", "doc", true) + row("post;post-b", "Beta", "doc", false)) +
    pane(2, "doc", "") +
    `</div>`;
  const el = window.document.getElementById("desk-panes");
  const pushed = [];
  const hook = Object.assign(Object.create(window.BarkparkDesk), {
    el,
    pushEvent: (event, payload) => pushed.push([event, payload]),
  });
  hook.mounted();
  return { el, hook, pushed };
}

// jsdom does not navigate; keep it quiet about the attempt. On window, so it
// runs AFTER the hook's own listener on #desk-panes (as LiveView's does).
window.addEventListener("click", (e) => e.preventDefault());
const click = (el, init = {}) =>
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init }));
const q = (sel) => window.document.querySelector(sel);
const rowTo = (href) => q(`a[href="${BASE}/${href}"]`);
const shown = (el) => [...el.children].filter((p) => !p.hasAttribute("data-desk-leaving"));

// ── A click on another document: marked, framed, the old document hidden ────
{
  const { el, hook } = mount();
  click(rowTo("post;post-b"));

  assert.equal(rowTo("post;post-b").getAttribute("aria-current"), "true", "the clicked row is current at once");
  assert.ok(rowTo("post;post-b").classList.contains("selected"));
  assert.equal(rowTo("post;post-a").getAttribute("aria-current"), null, "the row it replaces is not");
  assert.ok(q("#p2").hasAttribute("data-desk-leaving"), "the pane the click closes is hidden");

  const frame = q("[data-desk-skeleton]");
  assert.ok(frame, "an empty pane frame is drawn with no server answer");
  assert.equal(frame.getAttribute("data-pane-index"), "2");
  assert.equal(frame.getAttribute("data-pane-kind"), "doc");
  assert.equal(frame.getAttribute("aria-busy"), "true");
  assert.equal(frame.querySelector(".pane-header-title").textContent, "Beta", "titled from the row");
  assert.deepEqual(shown(el).map((p) => p.getAttribute("data-pane-index")), ["0", "1", "2"]);

  // The patch lands: the server's panes are in, the URL is the row's.
  window.history.replaceState({}, "", `${BASE}/post;post-b`);
  window.dispatchEvent(new window.Event("phx:page-loading-stop"));
  assert.equal(q("[data-desk-skeleton]"), null, "the frame goes when the patch lands");
  assert.equal(q("[data-desk-leaving]"), null);
  assert.equal(rowTo("post;post-b").getAttribute("aria-current"), "true");
  window.history.replaceState({}, "", `${BASE}/post;post-a`);
  hook.destroyed();
}

// ── A click one pane up closes everything right of the pane it opens ────────
{
  const { el, hook } = mount();
  click(rowTo("author"));
  assert.ok(q("#p1").hasAttribute("data-desk-leaving") && q("#p2").hasAttribute("data-desk-leaving"));
  assert.equal(q("[data-desk-skeleton]").getAttribute("data-pane-index"), "1");
  assert.equal(q("[data-desk-skeleton]").getAttribute("data-pane-kind"), "list");
  assert.deepEqual(shown(el).map((p) => p.getAttribute("data-pane-index")), ["0", "1"]);

  // The navigation never lands (the URL did not move): everything goes back.
  window.dispatchEvent(new window.Event("phx:page-loading-stop"));
  assert.equal(q("[data-desk-skeleton]"), null);
  assert.equal(q("[data-desk-leaving]"), null);
  assert.equal(rowTo("author").getAttribute("aria-current"), null, "the row that did not open is not current");
  assert.equal(rowTo("post").getAttribute("aria-current"), "true", "the one that is open is");
  hook.destroyed();
}

// ── A second click before the first lands keeps its own frame ───────────────
{
  const { hook } = mount();
  click(rowTo("post;post-b"));
  click(rowTo("author"));
  assert.equal(q("[data-desk-skeleton]").getAttribute("data-pane-index"), "1");

  // The FIRST click's patch stops loading. The URL is not the second click's
  // yet, and that is no sign the second one failed: its frame stays.
  window.dispatchEvent(new window.Event("phx:page-loading-stop"));
  assert.ok(q("[data-desk-skeleton]"), "an earlier click's answer does not undo the newer click's frame");
  assert.equal(rowTo("author").getAttribute("aria-current"), "true");

  // Its own patch stops without landing: now everything goes back.
  window.dispatchEvent(new window.Event("phx:page-loading-stop"));
  assert.equal(q("[data-desk-skeleton]"), null);
  assert.equal(q("[data-desk-leaving]"), null);
  assert.equal(rowTo("author").getAttribute("aria-current"), null);
  hook.destroyed();
}

// ── The open row again: its pane stays, only what is right of it closes ─────
{
  const { hook } = mount();
  click(rowTo("post"));
  assert.equal(q("[data-desk-skeleton]"), null, "no frame: the list is already there");
  assert.ok(!q("#p1").hasAttribute("data-desk-leaving"));
  assert.ok(q("#p2").hasAttribute("data-desk-leaving"));
  hook.destroyed();
}

// ── A row that is this very page, and modifier clicks: untouched ────────────
{
  const { el, hook } = mount();
  const before = el.innerHTML;
  click(rowTo("post;post-a"));
  assert.equal(el.innerHTML, before, "a click on the page's own URL changes nothing");
  for (const mod of [{ metaKey: true }, { ctrlKey: true }, { shiftKey: true }, { altKey: true }, { button: 1 }]) {
    const event = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...mod });
    rowTo("post;post-b").dispatchEvent(event);
    assert.equal(el.innerHTML, before, `a ${JSON.stringify(mod)} click is the browser's`);
  }
  hook.destroyed();
}

// ── A reference link: the document it opens is framed like a row's ──────────
// A reference is a link inside a document pane; before this it
// waited for the server.
{
  const ref = (href, title, current) =>
    `<a href="${BASE}/${href}" class="dk-ref"${current ? ' aria-current="true"' : ""} data-desk-ref>${title}</a>`;
  const mountRefs = () => {
    window.document.body.innerHTML =
      `<div id="desk-panes">` +
      pane(0, "types", row("post", "Posts", "list", true)) +
      pane(1, "list", row("post;post-a", "Alpha", "doc", true)) +
      pane(2, "doc", ref("post;post-a;author-x", "Ada", true) + ref("post;post-a;author-y", "Grace", false)) +
      pane(3, "doc", "") +
      `</div>`;
    const el = window.document.getElementById("desk-panes");
    const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent: () => {} });
    window.history.replaceState({}, "", `${BASE}/post;post-a;author-x`);
    hook.mounted();
    return { el, hook };
  };

  const { el, hook } = mountRefs();
  click(rowTo("post;post-a;author-y"));
  const frame = q("[data-desk-skeleton]");
  assert.ok(frame, "a reference click draws its pane with no server answer");
  assert.equal(frame.getAttribute("data-pane-index"), "3");
  assert.equal(frame.getAttribute("data-pane-kind"), "doc", "a reference opens a document");
  assert.equal(frame.querySelector(".pane-header-title").textContent, "Grace");
  assert.ok(q("#p3").hasAttribute("data-desk-leaving"), "the document it replaces is hidden");
  assert.equal(rowTo("post;post-a;author-y").getAttribute("aria-current"), "true");
  assert.ok(!rowTo("post;post-a;author-y").classList.contains("selected"), "a reference is not a list row");
  assert.equal(rowTo("post;post-a;author-x").getAttribute("aria-current"), null);
  assert.deepEqual(shown(el).map((p) => p.getAttribute("data-pane-index")), ["0", "1", "2", "3"]);

  // It never lands: the reference that is open is current again.
  window.dispatchEvent(new window.Event("phx:page-loading-stop"));
  assert.equal(q("[data-desk-skeleton]"), null);
  assert.equal(q("[data-desk-leaving]"), null);
  assert.equal(rowTo("post;post-a;author-x").getAttribute("aria-current"), "true");
  assert.equal(rowTo("post;post-a;author-y").getAttribute("aria-current"), null);
  hook.destroyed();
  window.history.replaceState({}, "", `${BASE}/post;post-a`);
}

// ── A search hit: one frame for each pane of its chain still to come ────────
{
  const hits = (links) => `<div class="dk-search"><div id="desk-search-hits">${links}</div></div>`;
  const hit = (href, title, type) =>
    `<a href="${BASE}/${href}" class="pane-item" data-desk-hit><span class="pane-item-label">${title}<span class="dk-row-sub">${type}</span></span></a>`;
  const mountHits = () => {
    const mounted = mount();
    window.document.body.insertAdjacentHTML(
      "afterbegin",
      hits(hit("author;author-x", "Ada", "Author") + hit("post;post-b", "Beta", "Post") + hit("post;post-a", "Alpha", "Post")),
    );
    return mounted;
  };

  // Another list's document: the list and the document are both framed.
  {
    const { el, hook } = mountHits();
    click(rowTo("author;author-x"));
    const frames = [...window.document.querySelectorAll("[data-desk-skeleton]")];
    assert.deepEqual(frames.map((f) => [f.getAttribute("data-pane-index"), f.getAttribute("data-pane-kind")]), [["1", "list"], ["2", "doc"]]);
    assert.equal(frames[1].querySelector(".pane-header-title").textContent, "Ada", "titled from the hit, without its type line");
    assert.ok(q("#p1").hasAttribute("data-desk-leaving") && q("#p2").hasAttribute("data-desk-leaving"));
    assert.deepEqual(shown(el).map((p) => p.getAttribute("data-pane-index")), ["0", "1", "2"], "in chain order");
    assert.ok(q("#desk-search-hits").hasAttribute("data-desk-leaving"), "the hits are put away with the click");

    // Never lands: the panes and the hits come back.
    window.dispatchEvent(new window.Event("phx:page-loading-stop"));
    assert.equal(q("[data-desk-skeleton]"), null);
    assert.equal(q("[data-desk-leaving]"), null);
    hook.destroyed();
  }

  // A document of the list that is open: the list stays, only the document is framed.
  {
    const { hook } = mountHits();
    click(rowTo("post;post-b"));
    const frames = [...window.document.querySelectorAll("[data-desk-skeleton]")];
    assert.deepEqual(frames.map((f) => f.getAttribute("data-pane-index")), ["2"]);
    assert.ok(!q("#p1").hasAttribute("data-desk-leaving"), "the list both chains share stays");
    assert.ok(q("#p2").hasAttribute("data-desk-leaving"));
    window.history.replaceState({}, "", `${BASE}/post;post-b`);
    window.dispatchEvent(new window.Event("phx:page-loading-stop"));
    assert.equal(q("[data-desk-skeleton]"), null);
    window.history.replaceState({}, "", `${BASE}/post;post-a`);
    hook.destroyed();
  }

  // The page's own document, and a modifier click: nothing is drawn.
  {
    const { hook } = mountHits();
    click(rowTo("post;post-a"));
    click(rowTo("author;author-x"), { metaKey: true });
    assert.equal(q("[data-desk-skeleton]"), null);
    assert.equal(q("[data-desk-leaving]"), null);
    hook.destroyed();
    // After the hook is gone, a hit click is the browser's again.
    click(rowTo("author;author-x"));
    assert.equal(q("[data-desk-skeleton]"), null, "destroyed() takes the document listener with it");
  }
}

// ── Intent: focusing a row asks the server to read ahead, once ──────────────
{
  const { hook, pushed } = mount();
  rowTo("post;post-b").focus();
  assert.deepEqual(pushed, [], "not before the pointer or focus has settled");
  await new Promise((r) => setTimeout(r, 160));
  assert.deepEqual(pushed, [["warm", { href: `${BASE}/post;post-b` }]]);

  rowTo("post").focus();
  rowTo("post;post-b").focus();
  await new Promise((r) => setTimeout(r, 160));
  assert.equal(pushed.length, 1, "the open row is never warmed, and a warmed row is not asked for twice");
  hook.destroyed();
}

// ── Intent is not sent for a row already followed, nor for a finger ─────────
{
  const { hook, pushed } = mount();
  // A quick click: the pointer arrives and the click follows before the wait is over.
  rowTo("post;post-b").focus();
  click(rowTo("post;post-b"));
  await new Promise((r) => setTimeout(r, 160));
  assert.deepEqual(pushed, [], "the click is reading that pane already: no second read");
  hook.destroyed();
}
{
  const { hook, pushed } = mount();
  const over = new window.Event("pointerover", { bubbles: true });
  over.pointerType = "touch";
  // jsdom never matches :hover: say the pointer is still on the row, so only
  // the pointer type can stop the read-ahead.
  const row = rowTo("author");
  row.matches = (q) => q === ":hover, :focus" || window.Element.prototype.matches.call(row, q);
  row.dispatchEvent(over);
  await new Promise((r) => setTimeout(r, 160));
  assert.deepEqual(pushed, [], "a touch pointerover is the tap itself, not a hover");
  hook.destroyed();
}

console.log("desk slice nav: ok");
window.close();
