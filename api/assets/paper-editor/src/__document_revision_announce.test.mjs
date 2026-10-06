// task-904659f0c8145633: Publish moves a non-paper document to a new revision
// that no save reply carries. The server announces it with
// bp:document-revision; the exit coordinator must base the next save on it,
// or the edit is refused as stale and pauses for review.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const KEY = "production:publication:pub-1";
const dom = new JSDOM(`
  <main data-paper-doc-key="${KEY}" data-document-rev="r-draft">
    <div class="bp-paper-editor">
      <div id="paper-ed-a" phx-hook="BarkparkPaperEditor"><bp-paper-editor></bp-paper-editor></div>
      <div id="paper-ed-b" phx-hook="BarkparkPaperEditor"><bp-paper-editor></bp-paper-editor></div>
    </div>
  </main>
`);
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const Hooks = window.BarkparkPaperEditorHooks;
const calls = [];
const replies = [];
const mounts = [...window.document.querySelectorAll('[phx-hook="BarkparkPaperEditor"]')]
  .map((el) => {
    const handlers = new Map();
    const hook = {
      ...Hooks.BarkparkPaperEditor,
      el,
      handleEvent: (name, handler) => handlers.set(name, handler),
      pushEvent: (name, payload) => {
        if (name !== "paper-op") return Promise.resolve({});
        calls.push(payload);
        return new Promise((resolve) => replies.push(resolve));
      },
    };
    hook.mounted();
    return { el, handlers };
  });
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const edit = (index, text) => mounts[index].el.querySelector("bp-paper-editor").dispatchEvent(
  new window.CustomEvent("bp-op", {
    bubbles: true,
    detail: { op: "patch-block", id: `block-${index}`, patch: { text } },
  }),
);
const announce = (rev) => mounts.forEach(({ handlers }) =>
  handlers.get("bp:document-revision")?.({ rev, document_key: KEY }));

for (const { handlers } of mounts) {
  assert.equal(typeof handlers.get("bp:document-revision"), "function",
    "every editor member listens for the announced revision");
}

// Control: before any announcement the save is based on the rendered revision.
edit(0, "one");
assert.equal(calls.length, 1);
assert.equal(calls[0].if_rev, "r-draft", "the first save uses data-document-rev");
replies.shift()({ saved: true, request_id: calls[0].request_id, rev: "r-draft-2" });
await tick();

// Publish: every member hears the same push; the next save is based on it.
announce("r-published");
edit(1, "two");
assert.equal(calls.length, 2);
assert.equal(calls[1].if_rev, "r-published",
  "the save after Publish is based on the announced revision, not the old reply");
replies.shift()({ saved: true, request_id: calls[1].request_id, rev: "r-after" });
await tick();
assert.equal(window.document.querySelector("[data-bp-paper-conflict]"), null);

// A repeat of an already-announced revision is ignored, not observed again.
announce("r-published");
edit(0, "three");
assert.equal(calls[2].if_rev, "r-after", "a repeated announcement cannot roll the base back");

console.log("ok document revision announcement: adopted, deduplicated, heard by every member");
