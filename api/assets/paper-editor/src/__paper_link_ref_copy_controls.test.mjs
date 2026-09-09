import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const shell = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");

assert.match(shell, /\[data-paper-link-card-editable\]\s*\{[^}]*position:\s*relative[^}]*isolation:\s*isolate/s,
  "local copy and navigation share the existing card footprint");
assert.match(shell, /\[data-paper-link-open\]\s*\{[^}]*position:\s*absolute[^}]*inset:\s*0[^}]*z-index:\s*1/s,
  "the separate destination link does not add a reader-height row");
for (const field of ["title", "description"]) {
  assert.match(shell, new RegExp(`\\.bp-paper-link-ref-${field}-form:not\\(:focus-within\\)\\s*\\{[^}]*position:\\s*absolute[^}]*clip-path:\\s*inset\\(50%\\)`, "s"),
    `${field} has only one canonical, resting-clipped form`);
}

// Layout dimensions still require real Chrome. This isolated DOM contract
// checks independent semantic ownership and the production positioning rules.
const dom = new JSDOM(`<!doctype html><style>${shell}</style>
  <div data-paper-link-card data-paper-link-card-editable>
    <a data-paper-link-open href="/papers/destination" aria-label="Open paper: Local title"></a>
    <div class="bp-paper-link-ref-title-owner">
      <strong class="bp-paper-link-ref-title-heading"><button type="button" data-paper-link-ref-title-paint>Local title</button></strong>
      <form class="bp-paper-edit-form bp-paper-link-ref-title-form">
        <label class="sr-only" for="local-title">Authored reference title</label>
        <textarea id="local-title" class="bp-paper-inline-text bp-paper-link-ref-title-input">Local title</textarea>
      </form>
    </div>
  </div>`, { pretendToBeVisual: true });
const { document } = dom.window;
const link = document.querySelector("[data-paper-link-open]");
assert.equal(link.querySelector("button,input,textarea,form"), null,
  "navigation never owns interactive editing descendants");
assert.equal(dom.window.getComputedStyle(link).position, "absolute");
assert.equal(dom.window.getComputedStyle(link).zIndex, "1");
assert.equal(dom.window.getComputedStyle(document.querySelector(".bp-paper-link-ref-title-owner")).zIndex, "2",
  "the canonical editing owner sits above stretched navigation");
assert.equal(dom.window.getComputedStyle(document.querySelector("[data-paper-link-ref-title-paint]")).pointerEvents, "auto",
  "authored text receives the click rather than the underlying link");
assert.equal(document.querySelectorAll("textarea").length, 1);
dom.window.close();
console.log("related-card copy controls preserve separate editing and navigation ownership");
