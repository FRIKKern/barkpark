import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM, VirtualConsole } from "jsdom";

const source = readFileSync(
  new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url),
  "utf8",
);
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

// Browser FormData must retain authored integer spelling. A number input
// sanitizes "+5" to an empty value before the backend can preserve the wire.
{
  const dom = new JSDOM(`<form>
    <input type="text" inputmode="numeric" pattern="[+-]?[0-9]+"
           name="question-0-scale-min" value="01">
    <input type="text" inputmode="numeric" pattern="[+-]?[0-9]+"
           name="question-0-scale-max" value="+5">
  </form>`);
  const form = dom.window.document.querySelector("form");
  assert.equal(form.checkValidity(), true);
  assert.deepEqual(
    Object.fromEntries(new dom.window.FormData(form)),
    { "question-0-scale-min": "01", "question-0-scale-max": "+5" },
  );
  dom.window.close();
}

function submitEnvironment(formHtml) {
  const dom = new JSDOM(`<main data-paper-doc-key="production:paper:form-controls" data-paper-rev="1">
    <button id="toggle" data-editing="true">View</button>
    <div id="paper-editor">${formHtml}</div>
    <button id="elsewhere">Elsewhere</button>
  </main>`, { url: "http://localhost/" });
  const { window } = dom;
  let uuid = 0;
  Object.defineProperty(window, "crypto", { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
  } });
  vm.runInContext(source, vm.createContext({
    window, document: window.document, CustomEvent: window.CustomEvent,
    FormData: window.FormData, Date, setTimeout, clearTimeout,
  }));
  const calls = [];
  const replies = [];
  const hook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: window.document.getElementById("toggle"),
    pushEvent: (event, payload) => {
      calls.push({ event, payload });
      return new Promise(resolve => replies.push(resolve));
    },
  };
  hook.mounted();
  return {
    dom, window, hook, calls, replies,
    form: window.document.querySelector("form"),
    close() { hook.destroyed(); dom.window.close(); },
  };
}

const questionMarkup = (action = "up:answer:two") => `
  <form id="questions" phx-submit="paper-edit-block" data-test-id="paper-form-editor">
    <input type="hidden" name="block_id" value="form">
    <input type="hidden" name="question-count" value="2">
    <input type="hidden" name="question-new-id" value="answer:new">
    <input type="hidden" name="question-0-original-id" value="answer:one">
    <input name="question-0-id" value="answer:one">
    <input name="question-0-prompt" value="First">
    <button type="submit" name="question-action" value="remove:answer:one">Remove first</button>
    <input type="hidden" name="question-1-original-id" value="answer:two">
    <input name="question-1-id" value="answer:two">
    <input name="question-1-prompt" value="Second">
    <button id="submitter" type="submit" name="question-action" value="${action}">Act</button>
    <button id="add-question" type="submit" name="question-action" value="add">Add question</button>
  </form>`;

// A question action addresses the stored original id, but the acknowledgement
// can both reorder the row and adopt its newly-authored answer name. Focus must
// follow the submitted answer name, not the stale original-id vector.
{
  const env = submitEnvironment(questionMarkup());
  const submitter = env.window.document.getElementById("submitter");
  const renamed = env.form.elements.namedItem("question-1-id");
  renamed.value = "answer:renamed:two";
  submitter.focus();
  env.form.dispatchEvent(new env.window.SubmitEvent("submit", {
    bubbles: true, cancelable: true, submitter,
  }));
  await tick();
  assert.equal(env.calls[0].payload["question-action"], "up:answer:two");

  env.form.elements.namedItem("question-0-original-id").value = "answer:renamed:two";
  env.form.elements.namedItem("question-0-id").value = "answer:renamed:two";
  env.form.elements.namedItem("question-0-prompt").value = "Second";
  env.form.elements.namedItem("question-1-original-id").value = "answer:one";
  env.form.elements.namedItem("question-1-id").value = "answer:one";
  env.form.elements.namedItem("question-1-prompt").value = "First";
  env.replies.shift()({ saved: true, request_id: env.calls[0].payload.request_id, rev: 2 });
  await tick();
  assert.equal(
    env.window.document.activeElement.name,
    "question-0-id",
    "focus follows a reordered question through its acknowledged answer-name rename",
  );
  env.close();
}

// Repeated question inserts must rotate the hidden client-generated id after
// every acknowledgement, including when a LiveView patch repaints an older id.
{
  const env = submitEnvironment(questionMarkup());
  const main = env.window.document.querySelector("main");
  const submitter = env.window.document.getElementById("add-question");
  const generated = env.form.elements.namedItem("question-new-id");
  const firstId = generated.value;

  submitter.focus();
  env.form.dispatchEvent(new env.window.SubmitEvent("submit", {
    bubbles: true, cancelable: true, submitter,
  }));
  await tick();
  assert.equal(env.calls[0].payload["question-new-id"], firstId);
  env.form.elements.namedItem("question-count").value = "3";
  env.form.insertAdjacentHTML("beforeend", `
    <input type="hidden" name="question-2-original-id" value="${firstId}">
    <input name="question-2-id" value="${firstId}">
    <input name="question-2-prompt" value="">`);
  env.replies.shift()({ saved: true, request_id: env.calls[0].payload.request_id, rev: 2 });
  await tick();
  const secondId = generated.value;
  assert.notEqual(secondId, firstId, "acknowledged question insert rotates its consumed id");
  assert.equal(env.window.document.activeElement.name, "question-2-id");

  main.dataset.paperRev = "2";
  submitter.focus();
  env.form.dispatchEvent(new env.window.SubmitEvent("submit", {
    bubbles: true, cancelable: true, submitter,
  }));
  await tick();
  assert.equal(env.calls[1].payload["question-new-id"], secondId);
  env.form.elements.namedItem("question-count").value = "4";
  env.form.insertAdjacentHTML("beforeend", `
    <input type="hidden" name="question-3-original-id" value="${secondId}">
    <input name="question-3-id" value="${secondId}">
    <input name="question-3-prompt" value="">`);
  generated.value = firstId;
  env.replies.shift()({ saved: true, request_id: env.calls[1].payload.request_id, rev: 3 });
  await tick();
  assert.notEqual(generated.value, firstId, "server repaint cannot reuse an already-consumed id");
  assert.notEqual(generated.value, secondId);
  env.close();
}

async function optionScenario({ action, mutate, expectedFocus, moveFocus = false, saved = true }) {
  const env = submitEnvironment(`
    <form id="options" phx-submit="paper-edit-block" data-test-id="paper-form-editor">
      <input type="hidden" name="block_id" value="form">
      <input type="hidden" name="question-count" value="1">
      <input type="hidden" name="question-new-id" value="answer:new">
      <input type="hidden" name="question-0-original-id" value="answer:with:colons">
      <input name="question-0-id" value="answer:with:colons">
      <input type="hidden" name="question-0-option-count" value="2">
      <input name="question-0-option-0" value="First">
      <input name="question-0-option-1" value="Second">
      <button id="option-submitter" type="submit" name="option-action" value="${action}">Act</button>
    </form>`);
  const submitter = env.window.document.getElementById("option-submitter");
  submitter.focus();
  env.form.dispatchEvent(new env.window.SubmitEvent("submit", {
    bubbles: true, cancelable: true, submitter,
  }));
  await tick();
  mutate?.(env.form);
  if (moveFocus) env.window.document.getElementById("elsewhere").focus();
  env.replies.shift()({
    saved,
    request_id: env.calls[0].payload.request_id,
    ...(saved ? { rev: 2 } : {}),
  });
  await tick();
  assert.equal(env.window.document.activeElement.name || env.window.document.activeElement.id, expectedFocus);
  env.close();
}

await optionScenario({
  action: "up:answer:with:colons:1",
  mutate(form) {
    form.elements.namedItem("question-0-option-0").value = "Second";
    form.elements.namedItem("question-0-option-1").value = "First";
  },
  expectedFocus: "question-0-option-0",
});
await optionScenario({
  action: "down:answer:with:colons:0",
  mutate(form) {
    form.elements.namedItem("question-0-option-0").value = "Second";
    form.elements.namedItem("question-0-option-1").value = "First";
  },
  expectedFocus: "question-0-option-1",
});
await optionScenario({
  action: "add:answer:with:colons",
  mutate(form) {
    form.elements.namedItem("question-0-option-count").value = "3";
    form.insertAdjacentHTML("beforeend", '<input name="question-0-option-2" value="">');
  },
  expectedFocus: "question-0-option-2",
});
await optionScenario({
  action: "remove:answer:with:colons:1",
  mutate(form) {
    form.elements.namedItem("question-0-option-1").remove();
    form.elements.namedItem("question-0-option-count").value = "1";
    form.elements.namedItem("option-action").remove();
  },
  expectedFocus: "question-0-option-0",
});
await optionScenario({
  action: "up:answer:with:colons:9",
  expectedFocus: "option-action",
});
await optionScenario({
  action: "up:answer:with:colons:1",
  expectedFocus: "option-action",
  saved: false,
});
await optionScenario({
  action: "up:answer:with:colons:1",
  expectedFocus: "elsewhere",
  moveFocus: true,
});

function fallbackEnvironment() {
  const virtualConsole = new VirtualConsole();
  virtualConsole.on("jsdomError", error => {
    if (!/navigation \(except hash changes\)/i.test(error.message)) throw error;
  });
  const dom = new JSDOM(`
    <main data-paper-doc-key="production:paper:form-snapshot" data-paper-rev="7">
      <button id="toggle" data-editing="true">View</button>
      <div class="bp-paper-editor">
        <form id="questions" phx-change="paper-block-autosave" phx-debounce="0"
              data-test-id="paper-form-editor">
          <input type="hidden" name="block_id" value="form">
          <input type="hidden" name="question-count" value="2">
          <input type="hidden" name="question-0-original-id" value="answer:one">
          <input name="question-0-id" value="answer:one">
          <input name="question-0-prompt" value="First">
          <input type="hidden" name="question-1-original-id" value="answer:two">
          <input name="question-1-id" value="answer:two">
          <input name="question-1-prompt" value="Second">
        </form>
      </div>
    </main>`, { url: "http://localhost/", virtualConsole });
  const { window } = dom;
  vm.runInContext(source, vm.createContext({
    window, document: window.document, CustomEvent: window.CustomEvent,
    FormData: window.FormData, Date, setTimeout, clearTimeout,
  }));
  const calls = [];
  const hook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: window.document.getElementById("toggle"),
    pushEvent: () => Promise.resolve({}),
    pushEventTo: (_target, event, payload) => {
      calls.push({ event, payload });
      return new Promise(() => {});
    },
  };
  hook.mounted();
  return { dom, window, hook, calls, form: window.document.querySelector("form") };
}

// A sibling acknowledgement may reorder questions while a local autosave is
// queued. The positional snapshot must not restore onto different answer rows.
{
  const env = fallbackEnvironment();
  const canvas = env.window.document.createElement("div");
  env.window.document.querySelector("main").append(canvas);
  let canvasPayload;
  let settleCanvas;
  const canvasSave = env.hook._exitCoordinator.mutate(canvas, {
    payload: { ops: [{ op: "move-block", id: "body", to: 0 }] },
    send: payload => {
      canvasPayload = payload;
      return new Promise(resolve => { settleCanvas = resolve; });
    },
  }).promise;
  await tick();

  const firstPrompt = env.form.elements.namedItem("question-0-prompt");
  firstPrompt.value = "Draft for first";
  firstPrompt.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  env.form.elements.namedItem("question-0-original-id").value = "answer:two";
  env.form.elements.namedItem("question-0-id").value = "answer:two";
  firstPrompt.value = "Second";
  env.form.elements.namedItem("question-1-original-id").value = "answer:one";
  env.form.elements.namedItem("question-1-id").value = "answer:one";
  env.form.elements.namedItem("question-1-prompt").value = "First";
  env.window.document.querySelector("main").dataset.paperRev = "8";
  settleCanvas({ saved: true, request_id: canvasPayload.request_id, rev: 8 });
  assert.equal(await canvasSave, true);
  await tick();
  env.hook.el.dispatchEvent(new env.window.MouseEvent("click", {
    bubbles: true, cancelable: true,
  }));
  await tick();
  assert.equal(env.calls.length, 0, "reordered question identities fail closed without autosave");
  assert.equal(firstPrompt.value, "Second", "stale draft is not restored onto another question");
  env.hook.destroyed();
  env.dom.window.close();
}

console.log("PASS form collections: stable question focus, fresh add ids, option guards, and snapshot safety");
