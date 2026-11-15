// __datetime_edit_survives_patch.test.mjs — task-2be7cd2bd845c2da: a
// date-time picker edit made just as another editor's save re-renders the
// form is posted, not dropped.
//
// The picker writes the hidden input and fires `input`; the form posts after
// the hidden input's phx-debounce (300 ms). A hidden input's value is its
// `value` attribute, so a LiveView patch in that window wrote the server's
// old value back. The focused picker kept showing the new time and the post
// carried the old one: 8 of 8 rounds in headless Chrome (review of #26382).
//
// This test runs the REAL priv/static/assets/bp-datetime-field.js in jsdom
// and patches the field with the morphdom LiveView ships, under LiveView's
// rules: a `phx-update="ignore"` element is skipped, and a hook's `updated`
// runs only when its element differs from the new render
// (phoenix_live_view.js `triggerBeforeUpdateHook`). The post is read with
// `new FormData(form)`, as LiveView serialises it when the debounce fires.
//
// Run: node ../paper-editor-host-tests/__datetime_edit_survives_patch.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "./jsdom.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ASSETS = path.join(__dirname, "../../priv/static/assets");
const IMPL_SRC = fs.readFileSync(path.join(ASSETS, "bp-datetime-field.js"), "utf8");
const PHOENIX_SRC = fs.readFileSync(path.join(ASSETS, "phoenix.js"), "utf8");
const LIVE_VIEW_SRC = fs.readFileSync(path.join(ASSETS, "phoenix_live_view.js"), "utf8");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const STORED = "2026-09-19T09:00:00Z";

// The field as FieldInputs' datetime clause renders it. `doc: null` is the
// composite subfield's wrapper, which names no document.
function field({ value = STORED, doc = "post-1" } = {}) {
  const named = doc == null ? "" : ` data-doc="${doc}"`;
  return `<div id="bp-dt-wrap-publishedAt" phx-hook="BarkparkDatetimeField" class="bp-datetime-field" data-value="${value}"${named}>
      <input type="hidden" name="doc[publishedAt]" value="${value}" data-datetime-value phx-debounce="300">
      <span id="bp-dt-pick-publishedAt" phx-update="ignore" class="bp-datetime-picker">
        <input type="datetime-local" id="publishedAt" class="form-input" aria-label="Published at">
      </span>
    </div>`;
}

function form(fieldHtml, stage = "review") {
  return `<form id="editor-form"><input type="text" id="stage" name="doc[stage]" value="${stage}">${fieldHtml}</form>`;
}

function page(opts) {
  const dom = new JSDOM(`<!doctype html><html><body>${form(field(opts))}</body></html>`, {
    runScripts: "outside-only",
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const { document } = window;

  window.eval(PHOENIX_SRC);
  const instrumented = LIVE_VIEW_SRC.replace(",ot=dn;", ",ot=dn;window.__bpShippedMorphdom=ot;");
  assert.notEqual(instrumented, LIVE_VIEW_SRC, "the shipped LiveView bundle exposes its vendored morphdom in this test");
  window.eval(instrumented);
  const morphdom = window.__bpShippedMorphdom;
  assert.equal(typeof morphdom, "function");

  window.eval(IMPL_SRC);
  const hook = Object.create(window.BarkparkDatetimeFieldHook);
  hook.el = document.getElementById("bp-dt-wrap-publishedAt");
  hook.mounted();

  const el = {
    form: () => document.getElementById("editor-form"),
    hidden: () => document.querySelector("input[data-datetime-value]"),
    picker: () => document.querySelector('input[type="datetime-local"]'),
    stage: () => document.getElementById("stage"),
  };

  // The editor changes the picker: the browser fires `input` on it.
  const edit = (local) => {
    el.picker().focus();
    el.picker().value = local;
    el.picker().dispatchEvent(new window.Event("input", { bubbles: true }));
  };

  // A LiveView patch of the whole form to the server's render.
  const patch = (fieldOpts, stage) => {
    const holder = document.createElement("div");
    holder.innerHTML = form(field(fieldOpts), stage);
    const updated = [];
    morphdom(el.form(), holder.firstChild, {
      getNodeKey: (node) => (node.getAttribute && node.getAttribute("id")) || node.id,
      onBeforeElUpdated: (fromEl, toEl) => {
        if (fromEl === hook.el && !fromEl.isEqualNode(toEl)) updated.push(hook);
        if (fromEl.getAttribute("phx-update") === "ignore") return false;
      },
    });
    updated.forEach((h) => h.updated());
  };

  // What the form posts when the debounce fires.
  const posted = () => new window.FormData(el.form()).get("doc[publishedAt]");
  const instant = (local) => window.BarkparkDatetime.toInstant(local);
  const local = (stored) => window.BarkparkDatetime.toLocalInput(stored);

  return { window, el, edit, patch, posted, instant, local };
}

check("another editor's save lands between the picker's write and the post: the post carries the edit", () => {
  const { el, edit, patch, posted, instant } = page();
  edit("2026-09-19T11:40");
  assert.equal(el.hidden().value, instant("2026-09-19T11:40"), "the picker wrote the hidden input");

  patch({}, "in review by B");

  assert.equal(el.stage().value, "in review by B", "the other editor's field arrived");
  assert.equal(el.picker().value, "2026-09-19T11:40", "the picker still shows the edit");
  assert.equal(posted(), instant("2026-09-19T11:40"));
});

check("the same after the editor tabbed out of the picker: the edit is posted and still shown", () => {
  const { el, edit, patch, posted, instant } = page();
  edit("2026-09-19T11:40");
  el.stage().focus();

  patch({}, "in review by B");

  assert.equal(posted(), instant("2026-09-19T11:40"));
  assert.equal(el.picker().value, "2026-09-19T11:40");
});

check("two patches in the window: the edit survives both", () => {
  const { edit, patch, posted, instant } = page();
  edit("2026-09-19T11:40");
  patch({}, "one");
  patch({}, "two");
  assert.equal(posted(), instant("2026-09-19T11:40"));
});

check("clearing the picker as a save lands posts the empty value", () => {
  const { el, edit, patch, posted } = page();
  edit("");
  assert.equal(el.hidden().value, "");
  patch({}, "in review by B");
  assert.equal(posted(), "");
});

check("once the server shows the saved edit, a later value from another editor is taken", () => {
  const { el, edit, patch, posted, instant, local } = page();
  edit("2026-09-19T11:40");
  const saved = instant("2026-09-19T11:40");
  patch({ value: saved });
  assert.equal(posted(), saved);

  el.stage().focus();
  patch({ value: "2026-12-24T17:00:00Z" });
  assert.equal(posted(), "2026-12-24T17:00:00Z");
  assert.equal(el.picker().value, local("2026-12-24T17:00:00Z"));
});

check("another editor saves the same field inside the window: the server's value is posted", () => {
  const { edit, patch, posted } = page();
  edit("2026-09-19T11:40");
  patch({ value: "2026-12-24T17:00:00Z" });
  assert.equal(posted(), "2026-12-24T17:00:00Z");
  // Later patches do not bring the dropped edit back.
  patch({ value: "2026-12-24T17:00:00Z" }, "again");
  assert.equal(posted(), "2026-12-24T17:00:00Z");
});

check("another document with the same stored value opens in the pane: the edit does not follow", () => {
  const { el, edit, patch, posted, local } = page();
  edit("2026-09-19T11:40");
  el.stage().focus();
  patch({ doc: "post-2" });
  assert.equal(posted(), STORED);
  assert.equal(el.picker().value, local(STORED));
  // Back on the first document, the edit is gone for good.
  patch({ doc: "post-1" });
  assert.equal(posted(), STORED);
});

check("a wrapper that names no document holds nothing: the patch wins", () => {
  const { edit, patch, posted } = page({ doc: null });
  edit("2026-09-19T11:40");
  patch({ doc: null }, "in review by B");
  assert.equal(posted(), STORED);
});

check("an untouched value with an offset stays byte-identical through focus and a patch", () => {
  const offset = "2026-09-19T09:00:00+02:00";
  const { el, patch, posted } = page({ value: offset });
  el.picker().focus();
  patch({ value: offset }, "in review by B");
  assert.equal(posted(), offset);
  assert.equal(el.hidden().getAttribute("value"), offset);
});

check("typing back the stored value drops the held edit", () => {
  const { edit, patch, posted, local } = page();
  edit("2026-09-19T11:40");
  edit(local(STORED));
  patch({}, "in review by B");
  assert.equal(posted(), STORED);
});

if (failures) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nall passed");
