import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const source = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

async function scenario({
  action = "up:1",
  saved = true,
  moveFocus = false,
  prefix = "tab",
  hookName = "BarkparkPaperEditToggle",
}) {
  const dom = new JSDOM(`<main data-paper-doc-key="production:paper:focus" data-paper-rev="1">
    <button id="toggle" data-editing="true">View</button>
    <div id="paper-editor">
      <form id="tabs" phx-submit="paper-edit-block">
        <input type="hidden" name="block_id" value="tabs">
        <input type="hidden" name="tab-count" value="2">
        <input name="tab-0-label" value="First">
        <button type="submit" name="tab-action" value="remove:0">Remove first</button>
        <input name="tab-1-label" value="Second">
        <button id="submitter" type="submit" name="tab-action" value="${action}">Act</button>
        <button type="submit" name="tab-action" value="add">Add</button>
      </form>
    </div>
    <button id="elsewhere">Another control</button>
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
    ...window.BarkparkPaperEditorHooks[hookName],
    el: window.document.getElementById(
      hookName === "BarkparkPaperSortable" ? "paper-editor" : "toggle",
    ),
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

async function stableRowScenario({
  prefix = "panel",
  action = "up:row:two",
  saved = true,
  moveFocus = false,
}) {
  const dom = new JSDOM(`<main data-paper-doc-key="production:paper:focus" data-paper-rev="1">
    <button id="toggle" data-editing="true">View</button>
    <div id="paper-editor">
      <form id="stable-rows" phx-submit="paper-edit-block">
        <input type="hidden" name="block_id" value="tabs">
        <input type="hidden" name="${prefix}-count" value="2">
        <input type="hidden" name="${prefix}-new-row-id" value="row:new:three">
        <input type="hidden" name="${prefix}-0-id" value="row:one">
        <input name="${prefix}-0-label" value="First">
        <button type="submit" name="${prefix}-action" value="remove:row:one">Remove first</button>
        <input type="hidden" name="${prefix}-1-id" value="row:two">
        <input name="${prefix}-1-label" value="Second">
        <button id="stable-submitter" type="submit" name="${prefix}-action" value="${action}">Act</button>
        <button type="submit" name="${prefix}-action" value="add">Add</button>
      </form>
    </div>
    <button id="stable-elsewhere">Another control</button>
  </main>`, { url: "http://localhost/" });
  const { window } = dom;
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
    const form = window.document.getElementById("stable-rows");
    const submitter = window.document.getElementById("stable-submitter");
    submitter.focus();
    form.dispatchEvent(new window.SubmitEvent("submit", { bubbles: true, cancelable: true, submitter }));
    await tick();
    assert.equal(send.payload[`${prefix}-action`], action);
    assert.equal(window.document.activeElement, submitter, "stable-row focus waits for acknowledgement");

    if (moveFocus) window.document.getElementById("stable-elsewhere").focus();
    if (saved && action === "up:row:two") {
      form.elements.namedItem(`${prefix}-0-id`).value = "row:two";
      form.elements.namedItem(`${prefix}-0-label`).value = "Second";
      form.elements.namedItem(`${prefix}-1-id`).value = "row:one";
      form.elements.namedItem(`${prefix}-1-label`).value = "First";
    }
    if (saved && action === "add") {
      const id = window.document.createElement("input");
      id.type = "hidden";
      id.name = `${prefix}-2-id`;
      id.value = "row:new:three";
      const label = window.document.createElement("input");
      label.name = `${prefix}-2-label`;
      form.append(id, label);
      form.elements.namedItem(`${prefix}-count`).value = "3";
    }
    if (saved && action === "remove:row:two") {
      form.elements.namedItem(`${prefix}-1-id`).remove();
      form.elements.namedItem(`${prefix}-1-label`).remove();
      submitter.remove();
      form.elements.namedItem(`${prefix}-count`).value = "1";
    }
    resolve({ saved, request_id: send.payload.request_id, ...(saved ? { rev: 2 } : {}) });
    await tick();

    if (moveFocus) {
      assert.equal(window.document.activeElement.id, "stable-elsewhere", "stable rows never steal focus");
    } else if (!saved) {
      assert.equal(window.document.activeElement, submitter, "failed stable-row save keeps current focus");
    } else {
      const expected = action === "add" ? `${prefix}-2-label` : `${prefix}-0-label`;
      assert.equal(window.document.activeElement.name, expected, "focus follows stable row identity");
    }
  } finally {
    hook.destroyed();
    window.close();
  }
}

async function stableGeneratedIdScenario({
  prefix = "panel",
  action = "add",
  saved = true,
}) {
  const dom = new JSDOM(`<main data-paper-doc-key="production:paper:focus" data-paper-rev="1">
    <button id="toggle" data-editing="true">View</button>
    <div id="paper-editor">
      <form id="stable-generated-ids" phx-submit="paper-edit-block">
        <input type="hidden" name="block_id" value="tabs">
        <input type="hidden" name="${prefix}-count" value="1">
        <input type="hidden" name="${prefix}-new-row-id" value="row:new:two">
        <input type="hidden" name="${prefix}-new-child-id" value="body:new:one">
        <input type="hidden" name="${prefix}-0-id" value="row:one">
        <input name="${prefix}-0-label" value="First">
        <button id="generated-submitter" type="submit" name="${prefix}-action" value="${action}">Act</button>
      </form>
    </div>
  </main>`, { url: "http://localhost/" });
  const { window } = dom;
  vm.runInContext(source, vm.createContext({
    window, document: window.document, CustomEvent: window.CustomEvent,
    FormData: window.FormData, setTimeout, clearTimeout,
  }));
  const sends = [];
  const resolvers = [];
  const hook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: window.document.getElementById("toggle"),
    pushEvent: (event, payload) => {
      sends.push({ event, payload });
      return new Promise(done => { resolvers.push(done); });
    },
  };
  hook.mounted();
  try {
    const main = window.document.querySelector("main");
    const form = window.document.getElementById("stable-generated-ids");
    const submitter = window.document.getElementById("generated-submitter");
    const generatedName = `${prefix}-${action === "add" ? "new-row-id" : "new-child-id"}`;
    const consumedId = form.elements.namedItem(generatedName).value;

    submitter.focus();
    form.dispatchEvent(new window.SubmitEvent("submit", { bubbles: true, cancelable: true, submitter }));
    await tick();
    assert.equal(sends[0].payload[generatedName], consumedId);

    if (saved && action === "add") {
      const id = window.document.createElement("input");
      id.type = "hidden";
      id.name = `${prefix}-1-id`;
      id.value = consumedId;
      const label = window.document.createElement("input");
      label.name = `${prefix}-1-label`;
      form.append(id, label);
      form.elements.namedItem(`${prefix}-count`).value = "2";
    }
    resolvers[0]({
      saved,
      request_id: sends[0].payload.request_id,
      ...(saved ? { rev: 2 } : {}),
    });
    await tick();

    if (!saved) {
      assert.equal(form.elements.namedItem(generatedName).value, consumedId,
        "a failed request retains the exact generated id for retry");
      return;
    }

    const replacementId = form.elements.namedItem(generatedName).value;
    assert.notEqual(replacementId, consumedId,
      "an acknowledged action rotates the generated id consumed by that write");

    main.dataset.paperRev = "2";
    submitter.focus();
    form.dispatchEvent(new window.SubmitEvent("submit", { bubbles: true, cancelable: true, submitter }));
    await tick();
    assert.equal(sends[1].payload[generatedName], replacementId);
    assert.notEqual(sends[1].payload[generatedName], sends[0].payload[generatedName],
      "the next action cannot replay a generated id already persisted in the tree");
    if (action === "add") {
      const id = window.document.createElement("input");
      id.type = "hidden";
      id.name = `${prefix}-2-id`;
      id.value = replacementId;
      const label = window.document.createElement("input");
      label.name = `${prefix}-2-label`;
      form.append(id, label);
      form.elements.namedItem(`${prefix}-count`).value = "3";
    }
    // The next LiveView patch can repaint the server-rendered original token,
    // which is different from this request's token but already exists in the tree.
    form.elements.namedItem(generatedName).value = consumedId;
    resolvers[1]({ saved: true, request_id: sends[1].payload.request_id, rev: 3 });
    await tick();

    const secondReplacementId = form.elements.namedItem(generatedName).value;
    assert.notEqual(secondReplacementId, consumedId,
      "acknowledgement cannot retain an older generated id already consumed by the tree");
    assert.notEqual(secondReplacementId, replacementId);

    main.dataset.paperRev = "3";
    submitter.focus();
    form.dispatchEvent(new window.SubmitEvent("submit", { bubbles: true, cancelable: true, submitter }));
    await tick();
    assert.equal(sends[2].payload[generatedName], secondReplacementId,
      "a third insert uses a fresh token after the server repaints an older one");
    resolvers[2]({ saved: true, request_id: sends[2].payload.request_id, rev: 4 });
    await tick();
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
for (const prefix of ["toc", "criterion", "gauge"]) {
  await scenario({ prefix });
  await scenario({ prefix, action: "add" });
  await scenario({ prefix, action: "remove:1" });
}
await scenario({ prefix: "gauge", hookName: "BarkparkPaperSortable" });
await scenario({ prefix: "gauge", saved: false });
await scenario({ prefix: "gauge", moveFocus: true });
for (const prefix of ["panel", "step"]) {
  await stableRowScenario({ prefix });
  await stableRowScenario({ prefix, action: "add" });
  await stableRowScenario({ prefix, action: "remove:row:two" });
  await stableRowScenario({ prefix, saved: false });
  await stableRowScenario({ prefix, moveFocus: true });
  await stableGeneratedIdScenario({ prefix });
  await stableGeneratedIdScenario({ prefix, action: "add-body:row:one" });
  await stableGeneratedIdScenario({ prefix, saved: false });
}
console.log("PASS collection focus: reorder, add, remove, failure, and no focus stealing");
