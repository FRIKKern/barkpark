// __desk_locked_value.test.mjs — task-2cad4946448ba07b: a field the desk
// draws read-only shows the value the server drew, even when it had the focus.
//
// Typing in the draft's Excerpt and then opening an old revision drew the
// revision's form with the typed value in its read-only Excerpt (a value a
// refused save held, too), not the revision's own (review of #27801, headless
// Chrome). The revision is drawn in a new form box, but the form and its
// inputs keep their ids, so morphdom moves the focused input into the new box
// and patches it there, and LiveView leaves a focused input's value as the
// browser holds it.
//
// This test patches a desk form with the morphdom LiveView ships, under
// LiveView's rule for the input that had the focus when the patch began
// (phoenix_live_view.js `DOMPatch`: the page's `onBeforeElUpdated` runs,
// then the focused input keeps its value and takes every other attribute and
// `readonly`). The page's callback is the one in root.html.heex, and the
// field code is the REAL priv/static/assets/bp-desk-locked-value.js.
//
// Run: node ../paper-editor-host-tests/__desk_locked_value.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "./jsdom.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const API = path.join(__dirname, "../..");
const ASSETS = path.join(API, "priv/static/assets");
const read = (...p) => fs.readFileSync(path.join(...p), "utf8");
const LIVE_VIEW_SRC = read(ASSETS, "phoenix_live_view.js");
const PHOENIX_SRC = read(ASSETS, "phoenix.js");
const ROOT = read(API, "lib/barkpark_web/layouts/root.html.heex");

// The page's morph callback, as root.html.heex hands it to the LiveSocket.
const cbStart = ROOT.indexOf("onBeforeElUpdated: (fromEl, toEl) => {");
assert.ok(cbStart > 0, "root.html.heex passes an onBeforeElUpdated to the LiveSocket");
const cbEnd = ROOT.indexOf("\n        },", cbStart);
const CALLBACK = ROOT.slice(cbStart + "onBeforeElUpdated: ".length, cbEnd + "\n        }".length);

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

// The pane's form holder: the box is keyed by what it draws (`form_key/1`),
// the form and the input are not.
const holder = (box, { value, readonly }) =>
  `<fieldset id="pane-form-holder"><div id="pane-form-box${box}" data-desk-form-box>` +
  `<form id="editor-form"><input type="text" id="excerpt" name="doc[excerpt]" value="${value}"${readonly ? " readonly" : ""}></form>` +
  `</div></fieldset>`;

function page(first, { field = true } = {}) {
  const dom = new JSDOM(`<!doctype html><html><body>${first}</body></html>`, {
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
  window.BarkparkPreviewDay = { day() {} };
  if (field) window.eval(read(ASSETS, "bp-desk-locked-value.js"));
  const onBeforeElUpdated = window.eval(`(${CALLBACK})`);

  const input = () => document.getElementById("excerpt");
  const patch = (next) => {
    const focused = document.activeElement;
    const to = document.createElement("div");
    to.innerHTML = next;
    morphdom(document.getElementById("pane-form-holder"), to.firstChild, {
      getNodeKey: (node) => node.id,
      onBeforeElUpdated: (fromEl, toEl) => {
        onBeforeElUpdated(fromEl, toEl);
        const formInput = /^(INPUT|TEXTAREA|SELECT)$/.test(fromEl.tagName);
        if (focused && fromEl.isSameNode(focused) && formInput && fromEl.type !== "hidden") {
          for (const { name, value } of [...toEl.attributes]) if (name !== "value") fromEl.setAttribute(name, value);
          for (const { name } of [...fromEl.attributes]) if (name !== "value" && !toEl.hasAttribute(name)) fromEl.removeAttribute(name);
          if (toEl.readOnly) fromEl.setAttribute("readonly", true);
          else fromEl.removeAttribute("readonly");
          return false;
        }
        return true;
      },
    });
  };
  const type = (text) => {
    input().focus();
    input().value = text;
  };
  return { window, document, input, patch, type };
}

check("the instrument: under LiveView's rule alone, the focused input keeps its typed value in the revision", () => {
  const { input, patch, type } = page(holder("", { value: "Draft" }), { field: false });
  type("NewHACK");
  patch(holder("-revision", { value: "Old", readonly: true }));
  assert.equal(input().readOnly, true, "the input is the revision's, read-only");
  assert.equal(input().value, "NewHACK", "the defect: the typed value is drawn over the revision's");
});

check("typing in the draft, then opening a revision: the read-only field shows the revision's value", () => {
  const { input, patch, type } = page(holder("", { value: "Draft" }));
  type("NewHACK");
  patch(holder("-revision", { value: "Old", readonly: true }));
  assert.equal(input().readOnly, true);
  assert.equal(input().value, "Old");
});

check("the published version, the same", () => {
  const { input, patch, type } = page(holder("", { value: "Draft" }));
  type("NewHACK");
  patch(holder("-published", { value: "Published", readonly: true }));
  assert.equal(input().value, "Published");
});

check("one revision to another with the field focused: the second revision's value", () => {
  const { document, input, patch } = page(holder("-revision", { value: "Old", readonly: true }));
  input().focus();
  assert.equal(document.activeElement, input());
  patch(holder("-revision", { value: "Older", readonly: true }));
  assert.equal(input().value, "Older");
});

check("back to the draft with the read-only field focused: the draft's value, editable", () => {
  const { input, patch } = page(holder("-revision", { value: "Old", readonly: true }));
  input().focus();
  patch(holder("", { value: "NewHACK" }));
  assert.equal(input().readOnly, false);
  assert.equal(input().value, "NewHACK");
});

check("the draft redrawn while typing: the typed value stays, as LiveView keeps it", () => {
  const { input, patch, type } = page(holder("", { value: "Draft" }));
  type("Draft and more");
  patch(holder("", { value: "Draft" }));
  assert.equal(input().value, "Draft and more");
});

check("the desk loads the field code, as it loads its other scripts", () => {
  const desk = read(API, "lib/barkpark_web/live/studio/desk_live.ex");
  const deskJs = read(ASSETS, "bp-desk.js");
  assert.match(desk, /data-desk-locked-value=\{BarkparkWeb\.StaticAssets\.path\("bp-desk-locked-value\.js"\)\}/);
  assert.match(deskJs, /deskScript\("data-desk-locked-value", window\.BarkparkDeskLockedValue\)/);
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("ok desk locked value: a read-only field shows the server's value, focused too");
