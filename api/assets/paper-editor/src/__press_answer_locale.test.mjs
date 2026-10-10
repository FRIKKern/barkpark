// THE PRESS ANSWER SPEAKS THE STUDIO'S LANGUAGE (task-24a481a493ad60d7).
//
// In an nb-NO Studio the live region announced "Opened “Innhold”." — the hook
// built its sentences from hard-coded English. The Studio bar now carries the
// words as data-press-strings (studio_topbar/1, gettext); the hook reads them
// through _paT and falls back to English when the bar has none.
//
// Bodies are EXTRACTED from the layout (same harness as the other press-answer
// tests), so this measures the hook the browser runs.
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const layout = readFileSync(new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url), "utf8");

function method(name, args) {
  const m = layout.match(new RegExp("\\n      " + name + "\\(" + args.replace(/[()]/g, "\\$&") + "\\) \\{([\\s\\S]*?)\\n      \\},"));
  assert.ok(m, `the press answer's ${name}(${args}) must be locatable in root.html.heex`);
  return new Function(...args.split(", ").filter(Boolean), m[1]);
}

const NB = {
  "Opened “%{name}”.": "Åpnet «%{name}».",
  "Opened.": "Åpnet.",
  "Selected “%{name}”.": "Valgt «%{name}».",
  "Selected.": "Valgt.",
};

function hookWith(strings) {
  const dom = new JSDOM(`<div id="studio-bar"${strings ? ` data-press-strings='${JSON.stringify(strings)}'` : ""}></div>`, {
    url: "http://localhost/w/agency/p/default/d/production/studio/content-types",
  });
  globalThis.location = dom.window.location;
  return {
    el: dom.window.document.getElementById("studio-bar"),
    _paT: method("_paT", "text, vars"),
    _paSettleWord: method("_paSettleWord", "p"),
    _paCurrentSig: () => "after",
    _paPressedChanged: () => false,
  };
}

const navigated = { url: "http://localhost/w/agency/p/default/d/production/studio", sig: "before", name: "Innhold" };

test("an nb-NO Studio bar makes a navigation answer Norwegian", () => {
  const hook = hookWith(NB);
  assert.equal(hook._paSettleWord(navigated), "Åpnet «Innhold».");
  assert.equal(hook._paSettleWord({ ...navigated, name: null }), "Åpnet.");
});

test("an nb-NO Studio bar makes a selection answer Norwegian", () => {
  const hook = hookWith(NB);
  assert.equal(hook._paSettleWord({ ...navigated, url: globalThis.location.href }), "Valgt «Innhold».");
});

test("a bar without the words (or an English Studio) keeps the English sentence", () => {
  const hook = hookWith(null);
  assert.equal(hook._paSettleWord(navigated), "Opened “Innhold”.");
  assert.equal(hookWith({})._paSettleWord(navigated), "Opened “Innhold”.");
});

test("every English sentence the hook speaks has a key the server provides", () => {
  const nav = readFileSync(new URL("../../../lib/barkpark_web/components/studio_components/nav.ex", import.meta.url), "utf8");
  const spoken = [...layout.matchAll(/this\._paT\("([^"]+)"/g)].map((m) => m[1]);
  assert.ok(spoken.length >= 7, `the hook speaks through _paT (found ${spoken.length})`);
  for (const key of new Set(spoken)) assert.ok(nav.includes(`"${key}" =>`), `nav.ex press_answer_strings/0 lacks ${JSON.stringify(key)}`);
});
