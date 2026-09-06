import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM, VirtualConsole } from "jsdom";

const source = readFileSync(
  new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url),
  "utf8",
);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function mountedForm(formHtml) {
  const virtualConsole = new VirtualConsole();
  virtualConsole.on("jsdomError", (error) => {
    if (!/navigation \(except hash changes\)/i.test(error.message)) throw error;
  });
  const dom = new JSDOM(`
    <main data-paper-doc-key="production:paper:validation" data-paper-rev="7">
      <button id="toggle" data-editing="true">View</button>
      <div class="bp-paper-editor">${formHtml}</div>
    </main>
  `, { url: "http://localhost/", virtualConsole });
  const { window } = dom;
  let uuid = 0;
  Object.defineProperty(window, "crypto", { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
  } });
  vm.runInContext(source, vm.createContext({
    window,
    document: window.document,
    CustomEvent: window.CustomEvent,
    FormData: window.FormData,
    Date,
    setTimeout,
    clearTimeout,
  }));

  const calls = [];
  const replies = [];
  const hook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: window.document.querySelector("#toggle"),
    pushEvent: () => Promise.resolve({}),
    pushEventTo: (_target, event, payload) => {
      calls.push({ event, payload });
      return new Promise((resolve, reject) => replies.push({ resolve, reject, payload }));
    },
  };
  hook.mounted();

  return {
    dom,
    window,
    hook,
    calls,
    replies,
    form: window.document.querySelector("form"),
    clickView() {
      hook.el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
    },
    settle(reply) {
      const pending = replies.shift();
      pending.resolve([{ status: "fulfilled", value: { reply } }]);
    },
    close() {
      hook.destroyed();
      dom.window.close();
    },
  };
}

const tocMarkup = `
  <form id="toc-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
        phx-debounce="0" data-test-id="paper-toc-editor">
    <input type="hidden" name="block_id" value="toc">
    <input type="hidden" name="toc-count" value="1">
    <input name="depth" value="2">
    <input name="toc-0-level" value="3">
  </form>
`;

for (const [name, value, valid] of [
  ["max", "0", false], ["max", "-1", false], ["max", "invalid", false],
  ["max", "", true], ["max", "120", true],
  ["gauge-0-value", "invalid", false], ["gauge-0-value", "", false],
  ["gauge-0-value", "2.5", true],
]) {
  const env = mountedForm(`
    <form id="gauges" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0" data-test-id="paper-gauge-list-editor">
      <input type="hidden" name="block_id" value="gauges">
      <input type="hidden" name="gauge-count" value="1">
      <input name="max" value="100">
      <input name="gauge-0-value" value="70">
    </form>
  `);
  const field = env.form.elements.namedItem(name);
  field.value = value;
  field.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(env.calls.length, valid ? 1 : 0, `${name}=${JSON.stringify(value)} has matching numeric validation`);
  if (valid) {
    env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 8 });
    await tick();
  } else {
    assert.ok(field.validationMessage, "invalid gauges explain the field constraint");
    assert.equal(field.value, value, "invalid local input remains available for correction");
  }
  env.close();
}

// A matching validation refusal restores the latest local snapshot after a
// same-form LiveView repaint, then retires only that rejected request.
{
  const env = mountedForm(tocMarkup);
  const level = env.form.elements.namedItem("toc-0-level");
  level.value = "first-invalid";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(env.calls.length, 0, "native numeric validation blocks the known invalid draft");

  // Exercise server validation recovery with a syntactically valid snapshot,
  // then author a newer value while that request is in flight.
  level.value = "4";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  const rejected = env.calls[0].payload;
  level.value = "5";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  level.value = "3";
  env.settle({
    saved: false,
    request_id: rejected.request_id,
    rejected: "validation",
    current_rev: rejected.if_rev,
  });
  await tick();
  assert.equal(level.value, "5", "the newest in-flight draft survives a server repaint");
  await tick();
  assert.equal(env.calls.length, 2, "a newer in-flight snapshot schedules after rejection");
  assert.notEqual(env.calls[1].payload.request_id, rejected.request_id);
  assert.equal(env.calls[1].payload.if_rev, rejected.if_rev);
  assert.equal(env.calls[1].payload["toc-0-level"], "5");
  env.settle({
    saved: true,
    request_id: env.calls[1].payload.request_id,
    rev: rejected.if_rev + 1,
  });
  await tick();
  env.close();
}

// With no newer input, the rejected snapshot is restored but never loops. A
// later correction resumes with a fresh request on the unchanged base.
{
  const env = mountedForm(tocMarkup);
  const level = env.form.elements.namedItem("toc-0-level");
  level.value = "4";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  const rejected = env.calls[0].payload;
  level.value = "3";
  env.settle({
    saved: false,
    request_id: rejected.request_id,
    rejected: "validation",
    current_rev: rejected.if_rev,
  });
  await tick();
  assert.equal(level.value, "4");
  assert.equal(env.calls.length, 1, "an unchanged rejected snapshot does not auto-loop");

  level.value = "6";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(env.calls.length, 2, "a correction creates one new mutation");
  assert.notEqual(env.calls[1].payload.request_id, rejected.request_id, "correction gets a fresh UUID");
  assert.equal(env.calls[1].payload.if_rev, rejected.if_rev, "validation refusal does not advance revision");
  assert.equal(env.calls[1].payload["toc-0-level"], "6");
  env.settle({
    saved: true,
    request_id: env.calls[1].payload.request_id,
    rev: rejected.if_rev + 1,
  });
  await tick();
  env.close();
}

// Ordinary failures retain the exact immutable request for explicit retry.
for (const kind of ["false", "null", "mismatched", "disconnect"]) {
  const env = mountedForm(`
    <form id="text-form" class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="0">
      <input type="hidden" name="block_id" value="paragraph">
      <input name="text" value="Before">
    </form>
  `);
  const input = env.form.elements.namedItem("text");
  input.value = `Draft ${kind}`;
  input.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  const original = JSON.parse(JSON.stringify(env.calls[0].payload));
  if (kind === "disconnect") {
    env.replies.shift().reject(new Error("disconnected"));
  } else if (kind === "null") {
    env.settle(null);
  } else {
    env.settle({
      saved: false,
      request_id: kind === "mismatched" ? "another-request" : original.request_id,
    });
  }
  await tick();
  env.clickView();
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(env.calls[1].payload)),
    original,
    `${kind} response retries the same payload, UUID, and revision`,
  );
  env.settle({ saved: true, request_id: original.request_id, rev: original.if_rev + 1 });
  await tick();
  env.close();
}

async function unsafeValidationScenario(change, currentRev = 7) {
  const env = mountedForm(tocMarkup);
  const level = env.form.elements.namedItem("toc-0-level");
  level.value = "4";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  const rejected = env.calls[0].payload;
  level.value = "5";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  level.value = "3";
  change(env);
  env.settle({
    saved: false,
    request_id: rejected.request_id,
    rejected: "validation",
    current_rev: currentRev,
  });
  await tick();
  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "unsafe validation recovery enters explicit conflict review");
  const keep = banner.querySelector('[data-action="keep"]');
  assert.equal(keep.disabled, true, "positional collection Keep mine is disabled");
  banner.querySelector('[data-action="review"]').click();
  const detail = banner.querySelector("[data-conflict-detail]").textContent;
  assert.match(detail, /row positions may have changed/i);
  assert.match(detail, /toc-0-level/);
  assert.match(detail, /"value": "5"/, "Review exposes the latest retained draft");
  keep.click();
  await tick();
  assert.equal(env.calls.length, 1, "disabled Keep mine cannot rebase positional rows");
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  assert.equal(
    env.window.document.querySelector("[data-bp-paper-conflict]"),
    null,
    "Use latest is the explicit positional-draft discard path",
  );
  assert.equal(env.calls.length, 1);
  env.close();
}

await unsafeValidationScenario((env) => {
  const replacement = env.form.cloneNode(true);
  env.form.replaceWith(replacement);
});

await unsafeValidationScenario((env) => {
  env.form.elements.namedItem("toc-count").value = "2";
  const added = env.window.document.createElement("input");
  added.name = "toc-1-level";
  added.value = "2";
  env.form.append(added);
});

await unsafeValidationScenario(() => {}, 8);

// Stable-row collection snapshots must not restore positional field values when
// LiveView has reordered the same rows without changing the collection count.
// The hidden row-id vector is the structure fence for Steps and plain Tabs.
for (const prefix of ["panel", "step"]) {
  const env = mountedForm(`
    <form id="${prefix}-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0" data-test-id="paper-${prefix}-editor">
      <input type="hidden" name="block_id" value="container">
      <input type="hidden" name="${prefix}-count" value="2">
      <input type="hidden" name="${prefix}-0-id" value="row:one">
      <input name="${prefix}-0-label" value="First">
      <input type="hidden" name="${prefix}-1-id" value="row:two">
      <input name="${prefix}-1-label" value="Second">
    </form>
  `);
  const first = env.form.elements.namedItem(`${prefix}-0-label`);
  first.value = "Draft for first";
  first.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  const rejected = env.calls[0].payload;

  env.form.elements.namedItem(`${prefix}-0-id`).value = "row:two";
  env.form.elements.namedItem(`${prefix}-0-label`).value = "Second";
  env.form.elements.namedItem(`${prefix}-1-id`).value = "row:one";
  env.form.elements.namedItem(`${prefix}-1-label`).value = "First";
  env.settle({
    saved: false,
    request_id: rejected.request_id,
    rejected: "validation",
    current_rev: rejected.if_rev,
  });
  await tick();

  assert.equal(
    env.form.elements.namedItem(`${prefix}-0-label`).value,
    "Second",
    `${prefix} snapshot is not restored onto a different stable row`,
  );
  assert.equal(env.calls.length, 1, `${prefix} reordered snapshot is not resubmitted`);
  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, `${prefix} reorder enters explicit conflict review`);
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true);
  env.close();
}

// A newer input captured after the mounted carrier advances belongs to a
// different base even when the validation receipt still matches the queued
// request's old base. Never restore or resubmit it as an old-base correction.
{
  const env = mountedForm(tocMarkup);
  const level = env.form.elements.namedItem("toc-0-level");
  level.value = "4";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  const rejected = env.calls[0].payload;
  env.window.document.querySelector("main").dataset.paperRev = "8";
  level.value = "5";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  level.value = "3";
  env.settle({
    saved: false,
    request_id: rejected.request_id,
    rejected: "validation",
    current_rev: rejected.if_rev,
  });
  await tick();
  assert.equal(level.value, "3", "a snapshot from a different revision base is not restored");
  assert.equal(env.calls.length, 1, "a different-base snapshot is not resubmitted");
  assert.ok(
    env.window.document.querySelector("[data-bp-paper-conflict]"),
    "revision-base drift enters explicit conflict recovery",
  );
  env.close();
}

// A quarantined external revision is also a known base change even before a
// LiveView patch updates the carrier's data-paper-rev attribute.
{
  const env = mountedForm(tocMarkup);
  const level = env.form.elements.namedItem("toc-0-level");
  level.value = "4";
  level.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  const rejected = env.calls[0].payload;
  env.hook._exitCoordinator.observeRevision({
    rev: 8,
    observedDocumentKey: "production:paper:validation",
    source: env.form,
  });
  level.value = "3";
  env.settle({
    saved: false,
    request_id: rejected.request_id,
    rejected: "validation",
    current_rev: rejected.if_rev,
  });
  await tick();
  assert.equal(level.value, "3", "a snapshot is not restored across a known external revision");
  assert.equal(env.calls.length, 1);
  assert.ok(
    env.window.document.querySelector("[data-bp-paper-conflict]"),
    "quarantined external revision enters explicit conflict recovery",
  );
  env.close();
}

console.log("PASS fallback validation recovery: safe restore, exact retry, and positional conflict guard");
