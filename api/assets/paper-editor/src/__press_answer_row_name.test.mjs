// A desk row's press answer names the document, not its whole row label
// (task-7271a3724e34f2ee).
//
// Found dogfooding (run7 lane-studio, 2026-10-05): opening a document from the
// desk said "Opened “Why Headless CMS Changes Everything, published, Updated
// 3m …”." — the row's aria-label carries status and age for the row itself, and
// the 60-character cap cut it mid-word. The row now names itself for the answer
// with `data-press-name`.
//
// `_paName` is EXTRACTED from the layout (the harness of
// __press_answer_flash_word.test.mjs), and the row is rendered by the real
// `pane_doc_item` markup's attribute set, read from panes.ex.
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const layout = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);
const panes = readFileSync(
  new URL("../../../lib/barkpark_web/components/studio_components/panes.ex", import.meta.url),
  "utf8",
);

const m = layout.match(/\n      _paName\(el\) \{([\s\S]*?)\n      \},/);
assert.ok(m, "_paName(el) must be locatable in root.html.heex");
const paName = new Function("el", m[1]);

const { document } = new JSDOM("").window;
function button(attrs) {
  const b = document.createElement("button");
  for (const [k, v] of Object.entries(attrs)) b.setAttribute(k, v);
  return b;
}

test("the desk row button hands its title to the press answer", () => {
  const row = panes.match(/class="bp-doc-row-body"[\s\S]*?>/);
  assert.ok(row, "the desk row button must be locatable in panes.ex");
  assert.match(row[0], /data-press-name=\{@title\}/);
});

test("a row is named by its title, not by its status-bearing aria-label", () => {
  const title = "Why Headless CMS Changes Everything";
  const el = button({ "data-press-name": title, "aria-label": `${title}, published, Updated 3m ago` });
  assert.equal(paName(el), title);
});

test("a control without a press name keeps its aria-label", () => {
  assert.equal(paName(button({ "aria-label": "Unpublish" })), "Unpublish");
});
