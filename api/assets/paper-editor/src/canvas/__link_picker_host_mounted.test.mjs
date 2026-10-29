// __link_picker_host_mounted.test.mjs — contract 1.16.0: the host owns the link picker.
//
//   1. `mention-trigger="off"` keeps `@` as plain text on a canvas that has a
//      wikilinkSource: `Ping @team about the plan`, Enter, `next line` is two lines.
//      Without it `@` still opens, and a space does not close it (multi-word titles).
//   2. Enter on a picker with no match closes it and splits the line, for `[[`, `@`
//      and `#`. Enter while results are still coming stays with the picker.
//   3. `--paper-picker-*` custom properties theme the picker, today's colours as
//      fallbacks; `data-strings` renames its eyebrow and empty row.
//
// Run: node src/canvas/__link_picker_host_mounted.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Element.prototype.scrollIntoView ||= () => {};
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = () => new Promise((resolve) => setTimeout(resolve, 350));

async function mount({ attrs = {}, source = async () => [], tags = async () => [] } = {}) {
  const queries = [];
  const canvas = document.createElement("bp-paper-canvas");
  for (const [name, value] of Object.entries(attrs)) canvas.setAttribute(name, value);
  canvas.blocks = [{ id: "body", type: "paragraph", content: [{ type: "text", value: "" }] }];
  canvas.wikilinkSource = (query) => {
    queries.push(query);
    return source(query);
  };
  canvas.tagSource = tags;
  document.body.appendChild(canvas);
  await settle();
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real canvas editor is mounted");
  editor.commands.setTextSelection(1);
  return { canvas, editor, queries };
}

const typed = async (editor, text) => {
  for (const char of text) {
    editor.commands.insertContent(char);
    await tick();
  }
};

const pressKey = (editor, key, mods = {}) => {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...mods });
  editor.view.dom.dispatchEvent(event);
  return event.defaultPrevented;
};

const shape = (editor) => {
  const out = [];
  editor.state.doc.descendants((node) => {
    if (!node.isTextblock) return true;
    let line = "";
    node.forEach((child) => {
      if (child.type.name === "hardBreak") line += "⏎";
      else if (child.marks.some((mark) => mark.type.name === "wikilink")) line += `{${child.text}}`;
      else line += child.text || "";
    });
    out.push(line);
    return false;
  });
  return out;
};

const pressEnter = (editor) => {
  const event = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
  editor.view.dom.dispatchEvent(event);
  return event.defaultPrevented;
};

const lines = (editor) => {
  const out = [];
  editor.state.doc.descendants((node) => {
    if (node.isTextblock) out.push(node.textContent);
  });
  return out;
};

const hasWikilink = (editor) => {
  let found = false;
  editor.state.doc.descendants((node) => {
    if (node.marks?.some((mark) => mark.type.name === "wikilink")) found = true;
  });
  return found;
};

const openMenu = () =>
  [...document.querySelectorAll(".bp-wikilink-menu")].find((menu) => menu.style.display === "block") || null;

const everything = async (query) => [{ title: `Page ${query}`, id: "page-1", type: "paper" }];

const cases = [];
const test = (name, fn) => cases.push([name, fn]);

test("mention-trigger=off: @ stays text, Enter splits, no link", async () => {
  const { canvas, editor, queries } = await mount({ attrs: { "mention-trigger": "off" }, source: everything });
  await typed(editor, "Ping @team about the plan");
  assert.equal(openMenu(), null, "no picker for @");
  pressEnter(editor);
  await typed(editor, "next line");
  assert.deepEqual(lines(editor), ["Ping @team about the plan", "next line"]);
  assert.equal(hasWikilink(editor), false);
  assert.deepEqual(queries, [], "the source is never asked for an @ query");
  canvas.remove();
});

test("mention-trigger=off still opens [[", async () => {
  const { canvas, editor, queries } = await mount({ attrs: { "mention-trigger": "off" }, source: everything });
  await typed(editor, "See [[Road");
  assert.ok(openMenu(), "[[ still opens");
  assert.equal(queries.at(-1), "Road");
  pressEnter(editor);
  assert.equal(hasWikilink(editor), true);
  canvas.remove();
});

test("mention-trigger set after mount turns @ off at once", async () => {
  const { canvas, editor, queries } = await mount({ source: everything });
  canvas.setAttribute("mention-trigger", "off");
  await typed(editor, "@team");
  assert.equal(openMenu(), null);
  assert.deepEqual(queries, []);
  canvas.remove();
});

test("default: @ opens, a space keeps it open for multi-word titles", async () => {
  const { canvas, editor, queries } = await mount({ source: everything });
  await typed(editor, "Ping @team plan");
  assert.ok(openMenu(), "@ opens by default");
  assert.equal(queries.at(-1), "team plan", "the query runs past the space");
  pressEnter(editor);
  assert.equal(hasWikilink(editor), true, "a match is picked on Enter");
  assert.deepEqual(lines(editor), ["Ping Page team plan "]);
  canvas.remove();
});

test("default @ with no match: Enter closes the picker and splits the line", async () => {
  const { canvas, editor } = await mount();
  await typed(editor, "Ping @team about the plan");
  assert.ok(openMenu(), "@ opens");
  pressEnter(editor);
  assert.equal(openMenu(), null, "the picker closed");
  await typed(editor, "next line");
  assert.deepEqual(lines(editor), ["Ping @team about the plan", "next line"]);
  canvas.remove();
});

test("[[ with no match: Enter closes the picker and splits the line", async () => {
  const { canvas, editor } = await mount();
  await typed(editor, "[[zzqx");
  assert.ok(openMenu(), "[[ opens");
  assert.equal(openMenu().querySelector(".bp-wikilink-empty")?.textContent, "No matching pages");
  const prevented = pressEnter(editor);
  assert.equal(openMenu(), null, "the picker closed");
  assert.deepEqual(lines(editor), ["[[zzqx", ""]);
  assert.equal(prevented, true, "the editor handled Enter as a line break");
  canvas.remove();
});

test("# with no match: Enter closes the picker and splits the line", async () => {
  const { canvas, editor } = await mount();
  await typed(editor, "#zzqx");
  assert.ok(openMenu(), "# opens");
  pressEnter(editor);
  assert.equal(openMenu(), null);
  assert.deepEqual(lines(editor), ["#zzqx", ""]);
  canvas.remove();
});

test("Enter while results are still coming stays with the picker", async () => {
  const { canvas, editor } = await mount({ source: () => new Promise(() => {}) });
  await typed(editor, "[[Road");
  assert.ok(openMenu());
  pressEnter(editor);
  assert.ok(openMenu(), "still open: nothing to judge yet");
  assert.deepEqual(lines(editor), ["[[Road"]);
  canvas.remove();
});

test("only the literal off turns @ off", async () => {
  for (const value of ["OFF", "false", "", "no"]) {
    const { canvas, editor, queries } = await mount({ attrs: { "mention-trigger": value }, source: everything });
    await typed(editor, "@team");
    assert.ok(openMenu(), `mention-trigger="${value}" keeps @ on`);
    assert.equal(queries.at(-1), "team");
    canvas.remove();
  }
});

test("two canvases on one page: the opt-out is per element", async () => {
  const off = await mount({ attrs: { "mention-trigger": "off" }, source: everything });
  const on = await mount({ source: everything });
  await typed(off.editor, "@team");
  assert.equal(openMenu(), null);
  on.editor.commands.focus();
  await typed(on.editor, "@team");
  assert.ok(openMenu(), "the other canvas keeps @");
  assert.deepEqual(off.queries, []);
  assert.equal(on.queries.at(-1), "team");
  off.canvas.remove();
  on.canvas.remove();
});

test("removed and appended again, the opt-out still holds", async () => {
  const { canvas, queries } = await mount({ attrs: { "mention-trigger": "off" }, source: everything });
  canvas.remove();
  document.body.appendChild(canvas);
  await settle();
  const editor = canvas._editor;
  editor.commands.setTextSelection(1);
  await typed(editor, "@team");
  assert.equal(openMenu(), null);
  assert.deepEqual(queries, []);
  pressEnter(editor);
  assert.equal(lines(editor).length, 2, "Enter still breaks the line");
  canvas.remove();
});

test("an empty batch for an older query does not let Enter close a newer one", async () => {
  const source = (query) => (query === "zzqx" ? Promise.resolve([]) : new Promise(() => {}));
  const { canvas, editor } = await mount({ source });
  await typed(editor, "[[zzqx");
  assert.ok(openMenu().querySelector(".bp-wikilink-empty")?.textContent === "No matching pages");
  await typed(editor, "y");
  pressEnter(editor);
  assert.ok(openMenu(), "the zzqxy query is still in flight");
  assert.deepEqual(lines(editor), ["[[zzqxy"]);
  canvas.remove();
});

test("a batch that lands after Enter closed the picker is dropped", async () => {
  let release;
  const late = new Promise((resolve) => { release = resolve; });
  const source = (query) => (query === "zzqx" ? Promise.resolve([]) : late);
  const { canvas, editor } = await mount({ source });
  await typed(editor, "[[zzqx");
  pressEnter(editor);
  assert.equal(openMenu(), null);
  release([{ title: "Late", id: "late", type: "paper" }]);
  await tick();
  assert.equal(openMenu(), null, "still closed");
  assert.equal(hasWikilink(editor), false);
  assert.deepEqual(lines(editor), ["[[zzqx", ""]);
  canvas.remove();
});

test("a source that rejects reads as no match", async () => {
  const { canvas, editor } = await mount({ source: async () => { throw new Error("search down"); } });
  await typed(editor, "[[Road");
  assert.equal(openMenu().querySelector(".bp-wikilink-empty")?.textContent, "No matching pages");
  pressEnter(editor);
  assert.equal(openMenu(), null);
  assert.deepEqual(lines(editor), ["[[Road", ""]);
  canvas.remove();
});

test("a source that throws at once reads as no match and the editor keeps working", async () => {
  const { canvas, editor } = await mount({ source: () => { throw new Error("bad source"); } });
  await typed(editor, "[[Road");
  assert.deepEqual(lines(editor), ["[[Road"], "every keystroke landed");
  assert.equal(openMenu().querySelector(".bp-wikilink-empty")?.textContent, "No matching pages");
  pressEnter(editor);
  assert.deepEqual(lines(editor), ["[[Road", ""]);
  canvas.remove();
});

test("a tag source that rejects reads as no match", async () => {
  const { canvas, editor } = await mount({ tags: async () => { throw new Error("tags down"); } });
  await typed(editor, "#road");
  pressEnter(editor);
  assert.equal(openMenu(), null);
  assert.deepEqual(lines(editor), ["#road", ""]);
  canvas.remove();
});

const emptyThenHit = async (query) => (query.endsWith("zz") ? [] : [{ title: "Hit", id: "hit", type: "paper" }]);

for (const [label, trigger, opts] of [
  ["[[", "[[", { source: emptyThenHit }],
  ["@", "@", { source: emptyThenHit }],
  ["#", "#", { tags: async (query) => (query.endsWith("zz") ? [] : ["hit"]) }],
]) {
  for (const [modLabel, mods] of [["Shift+Enter", { shiftKey: true }], ["Mod+Enter", { metaKey: true }], ["Ctrl+Enter", { ctrlKey: true }], ["Alt+Enter", { altKey: true }]]) {
    test(`${label} with no match: ${modLabel} stays with the picker, as before; only a bare Enter closes it`, async () => {
      const { canvas, editor } = await mount(opts);
      await typed(editor, `${trigger}zz`);
      assert.ok(openMenu(), "opens, empty");
      pressKey(editor, "Enter", mods);
      assert.ok(openMenu(), `${modLabel} keeps the picker`);
      assert.deepEqual(shape(editor), [`${trigger}zz`], `${modLabel} inserts nothing`);
      canvas.remove();
    });
  }
  test(`${label}: Escape, Shift+Enter, typing: the break ends the trigger, nothing is lost`, async () => {
    const { canvas, editor } = await mount(opts);
    await typed(editor, `${trigger}zz`);
    pressKey(editor, "Escape");
    assert.equal(openMenu(), null);
    pressKey(editor, "Enter", { shiftKey: true });
    await typed(editor, "qr");
    assert.equal(openMenu(), null, "no picker across a line break");
    pressEnter(editor);
    assert.deepEqual(shape(editor), [`${trigger}zz⏎qr`, ""]);
    canvas.remove();
  });
}

test("data-strings renames the picker's eyebrow and empty row", async () => {
  const strings = { "Link to page": "Link to note", "No matching pages": "No matching notes" };
  const { canvas, editor } = await mount({ attrs: { "data-strings": JSON.stringify(strings) } });
  await typed(editor, "[[zzqx");
  const menu = openMenu();
  assert.equal(menu.querySelector(".bp-wikilink-menu__eyebrow").textContent, "Link to note");
  assert.equal(menu.querySelector(".bp-wikilink-empty").textContent, "No matching notes");
  assert.equal(menu.getAttribute("aria-label"), "Link to note");
  canvas.remove();
});

test("data-strings: the # menu shares the label, a word left out stays English, bad JSON is English", async () => {
  const strings = { "Link to page": "Link to note" };
  const slow = await mount({ attrs: { "data-strings": JSON.stringify(strings) }, tags: () => new Promise(() => {}) });
  await typed(slow.editor, "#road");
  assert.equal(openMenu().querySelector(".bp-wikilink-menu__eyebrow").textContent, "Link to note");
  assert.equal(openMenu().querySelector(".bp-wikilink-empty").textContent, "Searching…");
  slow.canvas.remove();
  const bad = await mount({ attrs: { "data-strings": "{not json" } });
  await typed(bad.editor, "[[zzqx");
  assert.equal(openMenu().querySelector(".bp-wikilink-menu__eyebrow").textContent, "Link to page");
  assert.equal(openMenu().querySelector(".bp-wikilink-empty").textContent, "No matching pages");
  bad.canvas.remove();
});

test("the picker's colours are --paper-picker-* properties with today's values", () => {
  const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");
  const block = (selector) => {
    const at = css.indexOf(`${selector} {`);
    assert.notEqual(at, -1, `${selector} exists`);
    return css.slice(at, css.indexOf("}", at));
  };
  const today = {
    light: {
      "bg": "#fbfaf6", "ink": "#1f1a14", "ink-soft": "#5b524a", "ink-faint": "#787067",
      "rule": "rgba(31, 26, 20, 0.08)", "rule-soft": "rgba(31, 26, 20, 0.04)",
      "accent": "#a23925", "accent-soft": "rgba(162, 57, 37, 0.10)",
      "chrome-bg": "#fefdf9", "chrome-border": "rgba(31, 26, 20, 0.12)",
    },
    dark: {
      "bg": "#1b1815", "ink": "#ece6dc", "ink-soft": "#b8ad9e", "ink-faint": "#908679",
      "rule": "rgba(236, 230, 220, 0.10)", "rule-soft": "rgba(236, 230, 220, 0.05)",
      "accent": "#d97a5f", "accent-soft": "rgba(217, 122, 95, 0.14)",
      "chrome-bg": "#221e1a", "chrome-border": "rgba(236, 230, 220, 0.14)",
    },
  };
  const light = block(".bp-wikilink-menu");
  const dark = block('html[data-theme="dark"] .bp-wikilink-menu');
  for (const [theme, rules] of [["light", light], ["dark", dark]]) {
    for (const [name, value] of Object.entries(today[theme])) {
      const want = `--paper-${name}: var(--paper-picker-${name}, ${value});`;
      assert.ok(rules.replace(/:\s+/g, ": ").includes(want), `${theme}: ${want}`);
    }
  }
  assert.ok(light.includes("box-shadow: var(--paper-picker-shadow, 0 4px 16px rgba(0, 0, 0, 0.08));"));

  const paints = {
    "chrome-bg": [".bp-wikilink-menu", "background"],
    "chrome-border": [".bp-wikilink-menu", "border"],
    "ink": [".bp-wikilink-item", "color"],
    "ink-soft": [".bp-wikilink-foot kbd", "color"],
    "ink-faint": [".bp-wikilink-empty", "color"],
    "accent-soft": [".bp-wikilink-item.is-active", "background"],
    "bg": [".bp-wikilink-foot kbd", "background"],
    "rule": [".bp-wikilink-foot kbd", "border"],
    "rule-soft": [".bp-wikilink-foot", "border-top"],
  };
  for (const [name, [selector, property]] of Object.entries(paints)) {
    const rules = block(selector);
    assert.match(rules, new RegExp(`${property}: [^;]*var\\(--paper-${name}\\)`), `${selector} ${property} reads --paper-${name}`);
  }
  for (const selector of [".bp-wikilink-menu__eyebrow", ".bp-wikilink-type-badge", ".bp-wikilink-foot"]) {
    assert.match(block(selector), /color: var\(--paper-ink-faint\)/, `${selector} is ink-faint`);
  }
  const pickerRules = css.slice(css.indexOf(".bp-wikilink-menu {"), css.indexOf("/* ── canvas callout node-view"));
  assert.doesNotMatch(pickerRules, /var\(--paper-accent\)/, "nothing in the picker paints --paper-accent");
});

let failed = 0;
for (const [name, fn] of cases) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    failed += 1;
    console.error(`not ok - ${name}\n${error.stack}`);
  } finally {
    for (const el of document.querySelectorAll("bp-paper-canvas")) el.remove();
    for (const el of document.querySelectorAll(".bp-wikilink-menu")) el.remove();
  }
}
window.close();
if (failed) {
  console.error(`${failed}/${cases.length} link picker host cases failed`);
  process.exit(1);
}
console.log(`link picker host: ${cases.length}/${cases.length} passed`);
