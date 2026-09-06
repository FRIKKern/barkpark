import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const source = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

async function scenario({ action = "up:1", saved = true, moveFocus = false, prefix = "tab" }) {
  const dom = new JSDOM(`<main data-paper-doc-key="production:paper:focus" data-paper-rev="1">
    <button id="toggle" data-editing="true">View</button>
    <form id="tabs" phx-submit="paper-edit-block">
      <input type="hidden" name="block_id" value="tabs">
      <input type="hidden" name="tab-count" value="2">
      <input name="tab-0-label" value="First">
      <button type="submit" name="tab-action" value="remove:0">Remove first</button>
      <input name="tab-1-label" value="Second">
      <button id="submitter" type="submit" name="tab-action" value="${action}">Act</button>
      <button type="submit" name="tab-action" value="add">Add</button>
    </form><button id="elsewhere">Another control</button>
  </main>`, { url: "http://localhost/" });
  const { window } = dom;
  for (const control of window.document.querySelectorAll("[name]")) {
    control.name = control.name.replace(/^tab-/, `${prefix}-`);
  }
  vm.runInContext(source, vm.createContext({
    window, document: window.document, CustomEvent: window.CustomEvent,
    FormData: window.FormData, setTimeout, clearTimeout,
  }));
  let send;
  let resolve;
  const hook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: window.document.getElementById("toggle"),
    pushEvent: (event, payload) => {
      send = { event, payload };
      return new Promise(done => { resolve = done; });
    },
  };
  hook.mounted();
  try {
    const form = window.document.getElementById("tabs");
    const submitter = window.document.getElementById("submitter");
    submitter.focus();
    form.dispatchEvent(new window.SubmitEvent("submit", { bubbles: true, cancelable: true, submitter }));
    await tick();
    assert.equal(send.event, "paper-edit-block");
    assert.equal(send.payload[`${prefix}-action`], action);
    assert.equal(window.document.activeElement, submitter, "focus waits for a save result");

    if (moveFocus) window.document.getElementById("elsewhere").focus();
    if (saved && action === "up:1") {
      // LiveView updates indexed rows in place, retaining the old-index button.
      form.elements.namedItem(`${prefix}-0-label`).value = "Second";
      form.elements.namedItem(`${prefix}-1-label`).value = "First";
    }
    if (saved && action === "add") {
      const input = window.document.createElement("input");
      input.name = `${prefix}-2-label`;
      form.append(input);
      form.elements.namedItem(`${prefix}-count`).value = "3";
    }
    if (saved && action === "remove:1") {
      form.elements.namedItem(`${prefix}-1-label`).remove();
      submitter.remove();
      form.elements.namedItem(`${prefix}-count`).value = "1";
    }
    resolve({ saved, request_id: send.payload.request_id, ...(saved ? { rev: 2 } : {}) });
    await tick();

    if (moveFocus) {
      assert.equal(window.document.activeElement.id, "elsewhere", "save completion must not steal focus back");
    } else if (!saved) {
      assert.equal(window.document.activeElement, submitter, "failed save must not pretend the row moved");
    } else {
      const expected = action === "add" ? `${prefix}-2-label` : `${prefix}-0-label`;
      assert.equal(window.document.activeElement.name, expected, "focus follows the operated row, not its old index");
    }
  } finally {
    hook.destroyed();
    window.close();
  }
}

await scenario({});
await scenario({ action: "add" });
await scenario({ action: "remove:1" });
await scenario({ saved: false });
await scenario({ moveFocus: true });
for (const prefix of ["toc", "criterion"]) {
  await scenario({ prefix });
  await scenario({ prefix, action: "add" });
  await scenario({ prefix, action: "remove:1" });
}
console.log("PASS collection focus: reorder, add, remove, failure, and no focus stealing");
