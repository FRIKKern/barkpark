import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

function shippedMorphdom(window) {
  window.eval(readFileSync(new URL(
    "../../../priv/static/assets/phoenix.js",
    import.meta.url,
  ), "utf8"));
  const source = readFileSync(new URL(
    "../../../priv/static/assets/phoenix_live_view.js",
    import.meta.url,
  ), "utf8");
  const instrumented = source.replace(
    ",rt=hn;",
    ",rt=hn;window.__bpPaperLinkRefMorphdom=rt;",
  );
  assert.notEqual(instrumented, source,
    "the shipped LiveView bundle exposes its vendored morphdom in this test");
  window.eval(instrumented);
  return window.__bpPaperLinkRefMorphdom;
}

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

// These opaque replies are client-protocol fixtures, not proof of server
// authority. ExUnit and native host checks separately exercise real receipts.
const identity = createHash("sha256").update(JSON.stringify({
  slug: "unique-destination", prefer_authored_copy: true, qa: { keep: "identity" },
})).digest("base64url");
const blockId = "related: copy/[owner]#?";
const referenceFieldId = (field, guard = identity) =>
  `paper-link-ref-${field}-${Buffer.from(blockId).toString("base64url")}-3-${
    createHash("sha256").update(guard).digest("base64url")}`;
const fieldForm = (field, value, guard = identity) => `<form id="${referenceFieldId(field, guard)}-form"
  class="bp-paper-edit-form bp-paper-link-ref-${field}-form"
  phx-submit="paper-edit-block" phx-change="paper-block-autosave" phx-debounce="500">
  <input type="hidden" name="block_id" value="${blockId}">
  <input type="hidden" name="paper-link-ref-index" value="3">
  <input type="hidden" name="paper-link-ref-slug" value="unique-destination">
  <input type="hidden" name="paper-link-ref-field" value="${field}">
  <input type="hidden" name="paper-link-ref-guard" value="${guard}">
  <textarea id="${referenceFieldId(field, guard)}" name="paper-link-ref-value">${value}</textarea>
</form>`;

const morphDom = new JSDOM(`<!doctype html><body><div id="reference-card">
  ${fieldForm("title", "Authored title")}
  ${fieldForm("description", "Authored description")}
</div></body>`, { runScripts: "outside-only" });
const morph = shippedMorphdom(morphDom.window);
const morphCard = morphDom.window.document.getElementById("reference-card");
const retainedTitle = morphDom.window.document.getElementById(referenceFieldId("title"));
retainedTitle.value = "Unsaved local title";
retainedTitle.setSelectionRange(8, 13);
retainedTitle.__nativeHistoryProbe = { undoDepth: 2 };
const copyOnlyAck = morphCard.cloneNode(false);
copyOnlyAck.innerHTML = `${fieldForm("title", "Server-authored title")}
  ${fieldForm("description", "Server-authored description")}`;
morph(morphCard, copyOnlyAck, { getNodeKey: (node) => node?.id });
assert.equal(morphDom.window.document.getElementById(referenceFieldId("title")), retainedTitle,
  "copy-only ACKs retain the exact keyed textarea and its native history owner");
assert.deepEqual(retainedTitle.__nativeHistoryProbe, { undoDepth: 2 });

const changedIdentity = createHash("sha256").update(JSON.stringify({
  slug: "unique-destination", prefer_authored_copy: true, qa: { keep: "replacement" },
})).digest("base64url");
const identityChanged = morphCard.cloneNode(false);
identityChanged.innerHTML = `${fieldForm("title", "Replacement title", changedIdentity)}
  ${fieldForm("description", "Replacement description", changedIdentity)}`;
morph(morphCard, identityChanged, { getNodeKey: (node) => node?.id });
const replacementTitle = morphDom.window.document.getElementById(
  referenceFieldId("title", changedIdentity),
);
assert.notEqual(replacementTitle, retainedTitle,
  "an identity change at the same index replaces the canonical textarea owner");
assert.equal(retainedTitle.isConnected, false);
assert.equal(replacementTitle.value, "Replacement title",
  "a retained draft cannot retarget the newly admitted reference");
assert.equal(replacementTitle.__nativeHistoryProbe, undefined,
  "native history state does not cross the identity boundary");
console.log("related-card copy morph ownership follows the admitted identity guard");

const queueDom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:reference-copy" data-paper-rev="7">
    <button id="view" data-editing="true">View</button>
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:reference-copy" data-paper-rev="7">
      ${fieldForm("title", "Original title")}
      ${fieldForm("description", "Original description")}
      <footer><button data-paper-history-action="undo" disabled>Undo</button>
        <button data-paper-history-action="redo" disabled>Redo</button>
        <span data-paper-history-status role="status"></span>
        <span data-test-id="bp-paper-footer-save" role="status"></span></footer>
    </div>
  </main></body>`, { url: "http://localhost/" });
const win = queueDom.window;
let serial = 0;
Object.defineProperty(win, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++serial).padStart(12, "0")}`,
} });
vm.runInContext(readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"), vm.createContext({
  window: win, document: win.document, CustomEvent: win.CustomEvent,
  FormData: win.FormData, Date, setTimeout, clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
}));
const calls = [];
const replies = [];
const toggles = [];
const hook = {
  ...win.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
  el: win.document.getElementById("view"),
  pushEvent(event, payload) {
    if (event === "paper-toggle-edit") { toggles.push(event); return Promise.resolve({}); }
    calls.push({ event, payload: structuredClone(payload) });
    return new Promise(resolve => replies.push(reply => resolve(reply)));
  },
  pushEventTo(_target, event, payload) {
    calls.push({ event, payload: structuredClone(payload) });
    return new Promise(resolve => replies.push(reply => resolve([{ status: "fulfilled", value: { reply } }])));
  },
};
const tick = () => new Promise(resolve => setTimeout(resolve, 0));
const input = (field, value) => {
  const element = win.document.getElementById(referenceFieldId(field));
  element.focus(); element.value = value;
  element.dispatchEvent(new win.InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
};
const acknowledge = async (call, rev) => {
  assert.ok(replies.length, "a real pending client request must exist before a fixture reply");
  replies.shift()({ saved: true, changed: true, request_id: call.payload.request_id, rev,
    history_step: { version: 1, ref: call.payload.request_id, action: "undo" } });
  await tick(); await tick();
};
hook.mounted();
try {
  win.document.getElementById(referenceFieldId("title")).focus();
  win.document.getElementById(referenceFieldId("title")).blur();
  hook.el.click(); await tick();
  assert.equal(calls.length, 0, "untouched canonical fields send no mutation");
  assert.equal(toggles.length, 1);
  toggles.length = 0;

  input("title", "  First title  ");
  await new Promise(resolve => setTimeout(resolve, 510));
  assert.equal(calls.length, 1);
  input("title", "  Newer title  ");
  input("description", "  New description  ");
  hook.el.click(); await tick();
  assert.equal(calls.length, 1, "newer same-field and sibling-field edits await the first ACK");
  assert.equal(toggles.length, 0, "View waits for all pending local copy");
  await acknowledge(calls[0], 8);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].payload.if_rev, 8);
  await acknowledge(calls[1], 9);
  assert.equal(calls.length, 3);
  assert.equal(calls[2].payload.if_rev, 9);
  assert.deepEqual(calls.slice(1).map(call => [call.payload["paper-link-ref-field"],
    call.payload["paper-link-ref-value"]]).sort(([a], [b]) => a.localeCompare(b)),
  [["description", "  New description  "], ["title", "  Newer title  "]],
  "both independent fields persist their exact latest values; cross-field queue order is not a source contract");
  for (const call of calls) {
    assert.equal(call.payload["paper-link-ref-guard"], identity,
      "copy edits do not change the identity guard across own ACK rebasing");
    assert.deepEqual(Object.keys(call.payload).sort(), ["block_id", "paper-link-ref-index",
      "paper-link-ref-slug", "paper-link-ref-field", "paper-link-ref-value", "paper-link-ref-guard",
      "request_id", "if_rev"].sort(), "no sibling reference or inverse source is submitted");
  }
  win.document.getElementById(referenceFieldId("title")).focus();
  await acknowledge(calls[2], 10);
  assert.equal(toggles.length, 1, "View occurs only after every exact field value is acknowledged");

  input("title", "Title save before clean sibling focus");
  await new Promise(resolve => setTimeout(resolve, 510));
  const titleBeforeSiblingFocus = calls.at(-1);
  assert.equal(titleBeforeSiblingFocus.payload.if_rev, 10);
  win.document.getElementById(referenceFieldId("description")).focus();
  await acknowledge(titleBeforeSiblingFocus, 11);
  input("description", "First description input after title ACK");
  await new Promise(resolve => setTimeout(resolve, 510));
  const descriptionAfterOwnAck = calls.at(-1);
  assert.equal(descriptionAfterOwnAck.payload.if_rev, 11,
    "a clean focused sibling adopts the disjoint reference field's own ACK revision");
  await acknowledge(descriptionAfterOwnAck, 12);

  const oldIdentityTitle = win.document.getElementById(referenceFieldId("title"));
  input("title", "Unsaved draft for the old identity");
  const callsBeforeIdentityChange = calls.length;
  const togglesBeforeIdentityChange = toggles.length;
  const editorRoot = win.document.querySelector(".bp-paper-editor");
  const authoritativeReplacement = editorRoot.cloneNode(false);
  authoritativeReplacement.innerHTML = `${fieldForm(
    "title", "Replacement authoritative title", changedIdentity,
  )}${fieldForm(
    "description", "Replacement authoritative description", changedIdentity,
  )}${editorRoot.querySelector("footer").outerHTML}`;
  morph(editorRoot, authoritativeReplacement, { getNodeKey: (node) => node?.id });

  const authoritativeTitle = win.document.getElementById(
    referenceFieldId("title", changedIdentity),
  );
  assert.equal(oldIdentityTitle.isConnected, false,
    "the coordinator's dirty source is disconnected when its admitted identity changes");
  assert.equal(authoritativeTitle.value, "Replacement authoritative title");
  assert.notEqual(authoritativeTitle, oldIdentityTitle);
  hook.el.click();
  await tick(); await tick();
  assert.equal(calls.length, callsBeforeIdentityChange,
    "the retained old-identity draft is never submitted through the new reference form");
  assert.equal(toggles.length, togglesBeforeIdentityChange,
    "View stays blocked while the disconnected old-identity draft remains unresolved");
} finally {
  hook.destroyed?.();
  queueDom.window.close();
  morphDom.window.close();
}
console.log("related-card copy serializes same-field and sibling-field saves without broad source payloads");

async function focusedSiblingRevision({
  sourceField = "title", candidateField = "description", candidateIdentity = identity,
  candidateIndex = "3", candidateSlug = "unique-destination", candidateExtra = "",
  candidateDirty = false, candidatePreviouslySaved = false, externalRevision = false,
} = {}) {
  const scenarioForm = ({ id, field, guard = identity, index = "3", slug = "unique-destination", extra = "" }) => `
    <form id="${id}" class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="0">
      <input type="hidden" name="block_id" value="${blockId}">
      <input type="hidden" name="paper-link-ref-index" value="${index}">
      <input type="hidden" name="paper-link-ref-slug" value="${slug}">
      <input type="hidden" name="paper-link-ref-field" value="${field}">
      <input type="hidden" name="paper-link-ref-guard" value="${guard}">
      ${extra}<textarea id="${id}-field" name="paper-link-ref-value">Initial ${field}</textarea>
    </form>`;
  const scenarioDom = new JSDOM(`<!doctype html><body>
    <main data-paper-doc-key="production:paper:focused-sibling" data-paper-rev="20">
      <button id="scenario-view" data-editing="true">View</button>
      ${scenarioForm({ id: "scenario-source", field: sourceField })}
      ${scenarioForm({ id: "scenario-candidate", field: candidateField,
        guard: candidateIdentity, index: candidateIndex, slug: candidateSlug,
        extra: candidateExtra })}
      <span data-test-id="bp-paper-footer-save" role="status"></span>
    </main></body>`, { url: "http://localhost/" });
  const scenarioWindow = scenarioDom.window;
  let scenarioSerial = 0;
  Object.defineProperty(scenarioWindow, "crypto", { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8001-${String(++scenarioSerial).padStart(12, "0")}`,
  } });
  vm.runInContext(readFileSync(new URL(
    "../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url,
  ), "utf8"), vm.createContext({
    window: scenarioWindow, document: scenarioWindow.document,
    CustomEvent: scenarioWindow.CustomEvent, FormData: scenarioWindow.FormData,
    Date, setTimeout, clearTimeout, customElements: { whenDefined: () => Promise.resolve() },
  }));
  const scenarioCalls = [];
  const scenarioReplies = [];
  const scenarioHook = {
    ...scenarioWindow.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: scenarioWindow.document.getElementById("scenario-view"),
    pushEventTo(_target, event, payload) {
      scenarioCalls.push({ event, payload: structuredClone(payload) });
      return new Promise(resolve => scenarioReplies.push(reply =>
        resolve([{ status: "fulfilled", value: { reply } }])));
    },
    pushEvent() { return Promise.resolve({}); },
  };
  const scenarioInput = (element, value) => {
    element.value = value;
    element.dispatchEvent(new scenarioWindow.InputEvent("input", {
      bubbles: true, inputType: "insertText", data: value,
    }));
  };
  scenarioHook.mounted();
  try {
    const source = scenarioWindow.document.getElementById("scenario-source-field");
    const candidate = scenarioWindow.document.getElementById("scenario-candidate-field");
    let expectedSourceRev = 20;
    if (candidatePreviouslySaved) {
      candidate.focus();
      scenarioInput(candidate, "Previously acknowledged candidate mutation");
      await tick(); await tick();
      assert.equal(scenarioCalls.at(-1).payload.if_rev, 20);
      scenarioReplies.shift()({
        saved: true, changed: true, request_id: scenarioCalls.at(-1).payload.request_id, rev: 21,
        history_step: { version: 1, ref: scenarioCalls.at(-1).payload.request_id, action: "undo" },
      });
      await tick(); await tick();
      expectedSourceRev = 21;
    }
    source.focus();
    scenarioInput(source, "Source mutation");
    await tick(); await tick();
    const sourceCall = scenarioCalls.at(-1);
    assert.equal(sourceCall.payload.if_rev, expectedSourceRev);
    candidate.focus();
    if (candidateDirty) scenarioInput(candidate, "Candidate already dirty");
    if (externalRevision) {
      scenarioHook._bpPaperExitCoordinator.observeRevision({ rev: 22, source: scenarioHook.el });
    }
    scenarioReplies.shift()({
      saved: true, changed: true, request_id: sourceCall.payload.request_id,
      rev: expectedSourceRev + 1,
      history_step: { version: 1, ref: sourceCall.payload.request_id, action: "undo" },
    });
    await tick(); await tick();
    if (!candidateDirty) scenarioInput(candidate, "Candidate mutation");
    await tick(); await tick();
    return scenarioCalls.at(-1)?.payload.if_rev;
  } finally {
    scenarioHook.destroyed?.();
    scenarioDom.window.close();
  }
}

assert.equal(await focusedSiblingRevision({ sourceField: "description", candidateField: "title" }), 21,
  "the clean focused sibling exception works in the reverse field direction");
assert.equal(await focusedSiblingRevision({
  candidateIdentity: changedIdentity, candidateIndex: "4", candidateSlug: "other-destination",
}), 20, "another reference identity retains its viewed revision");
assert.equal(await focusedSiblingRevision({
  candidateExtra: '<input type="hidden" name="extra" value="forged">',
}), 20, "a form with noncanonical extra source fields retains its viewed revision");
assert.equal(await focusedSiblingRevision({ externalRevision: true }), 20,
  "a quarantined external revision retains the focused field's viewed revision");
assert.equal(await focusedSiblingRevision({ candidateDirty: true }), 21,
  "an already-dirty sibling follows the ordinary reviewed queue path");
assert.equal(await focusedSiblingRevision({ candidatePreviouslySaved: true }), 22,
  "an acknowledged clean sibling can safely adopt a later disjoint ACK revision");
console.log("related-card focused sibling rebasing stays narrow and fail-closed");
