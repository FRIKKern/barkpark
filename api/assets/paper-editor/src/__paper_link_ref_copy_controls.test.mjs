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
    <div id="paper-editor-reference-copy" class="bp-paper-editor" data-paper-doc-key="production:paper:reference-copy" data-paper-rev="7">
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
  const oldIdentityDescription = win.document.getElementById(referenceFieldId("description"));
  input("description", "Second retained description draft");
  const callsBeforeIdentityChange = calls.length;
  const togglesBeforeIdentityChange = toggles.length;
  const editorRoot = win.document.querySelector(".bp-paper-editor");
  const authoritativeReplacement = editorRoot.cloneNode(false);
  authoritativeReplacement.innerHTML = `${fieldForm(
    "title", "Replacement authoritative title", changedIdentity,
  )}${fieldForm(
    "description", "Replacement authoritative description", changedIdentity,
  )}${editorRoot.querySelector("footer").outerHTML}`;
  let downloadedRecovery = null;
  let downloadedRecoveryName = null;
  Object.defineProperty(win, "Blob", { configurable: true, value: globalThis.Blob });
  win.URL.createObjectURL = (blob) => {
    downloadedRecovery = blob;
    return "blob:paper-reference-draft-recovery";
  };
  win.URL.revokeObjectURL = () => {};
  win.HTMLAnchorElement.prototype.click = function click() {
    downloadedRecoveryName = this.download;
  };
  morph(editorRoot, authoritativeReplacement, {
    getNodeKey: (node) => node?.id,
    onBeforeElUpdated: (fromEl, toEl) => {
      win.BarkparkPaperEditorBeforeElUpdated(fromEl, toEl);
      return true;
    },
  });
  await tick();

  const authoritativeTitle = win.document.getElementById(
    referenceFieldId("title", changedIdentity),
  );
  assert.equal(oldIdentityTitle.isConnected, false,
    "the coordinator's dirty source is disconnected when its admitted identity changes");
  assert.equal(authoritativeTitle.value, "Replacement authoritative title");
  assert.notEqual(authoritativeTitle, oldIdentityTitle);
  let recovery = win.document.querySelector("[data-bp-paper-conflict][role=alert]");
  assert.ok(recovery,
    "a never-sent draft disconnected by an identity replacement enters visible recovery");
  const retainedText = recovery.querySelector("textarea[data-reference-draft-text][readonly]");
  assert.equal(retainedText?.value, "Unsaved draft for the old identity",
    "recovery exposes the exact old field text without assigning it to the replacement");
  const responsiveReplacement = editorRoot.cloneNode(false);
  responsiveReplacement.innerHTML = `${fieldForm(
    "title", "Replacement authoritative title", changedIdentity,
  )}${fieldForm(
    "description", "Replacement authoritative description", changedIdentity,
  )}${editorRoot.querySelector("footer").outerHTML}`;
  morph(editorRoot, responsiveReplacement, {
    getNodeKey: (node) => node?.id,
    onBeforeElUpdated: (fromEl, toEl) => {
      win.BarkparkPaperEditorBeforeElUpdated(fromEl, toEl);
      return true;
    },
  });
  win.BarkparkPaperEditorHooks.BarkparkPaperSortable.updated.call({
    _exitCoordinator: hook._bpPaperExitCoordinator,
  });
  await tick();
  recovery = win.document.querySelector("[data-bp-paper-reference-draft]");
  assert.ok(recovery,
    "a matching root-only responsive morph restores the retained recovery banner");
  assert.equal(recovery.querySelector("[data-reference-draft-text]").value,
    "Unsaved draft for the old identity",
    "responsive repaint keeps the first retained draft exact without recapturing it");
  const keep = recovery.querySelector('[data-action="keep"]');
  assert.equal(keep?.disabled, true,
    "an old identity draft cannot be kept onto the replacement reference");
  const download = recovery.querySelector("button[data-reference-draft-download]");
  assert.ok(download, "the retained draft has an explicit download action");
  download.click();
  await tick();
  assert.ok(downloadedRecovery, "download creates a recovery payload without a save request");
  assert.match(downloadedRecoveryName || "", /reference-draft-recovery\.json$/);
  const recoveryPayload = JSON.parse(await downloadedRecovery.text());
  assert.equal(recoveryPayload.draft.values.find(
    ({ name }) => name === "paper-link-ref-value",
  )?.value, "Unsaved draft for the old identity");
  assert.equal(recoveryPayload.draft.values.find(
    ({ name }) => name === "paper-link-ref-guard",
  )?.value, identity, "download remains bound to the old admitted identity");
  const recoveryTextareaRule = shell.match(
    /\[data-reference-draft-text\]\s*\{([^}]*)\}/s,
  )?.[1] || "";
  for (const [property, pattern] of [
    ["border-box sizing", /box-sizing:\s*border-box/],
    ["full width", /width:\s*100%/],
    ["bounded width", /max-width:\s*100%/],
    ["readable height", /min-height:\s*6rem/],
    ["vertical resizing", /resize:\s*vertical/],
    ["foreground token", /color:\s*var\(/],
    ["background token", /background(?:-color)?:\s*var\(/],
    ["inherited Paper font", /font:\s*inherit/],
  ]) {
    assert.match(recoveryTextareaRule, pattern,
      `the retained draft textarea has ${property}`);
  }
  assert.equal(calls.length, callsBeforeIdentityChange,
    "reading and downloading recovery never submits the old payload");
  hook.el.click();
  await tick(); await tick();
  assert.equal(calls.length, callsBeforeIdentityChange,
    "the retained old-identity draft is never submitted through the new reference form");
  assert.equal(toggles.length, togglesBeforeIdentityChange,
    "View stays blocked while the disconnected old-identity draft remains unresolved");
  recovery.querySelector("button[data-reference-draft-discard]").click();
  await tick();
  assert.equal(oldIdentityTitle.isConnected, false);
  const secondRecovery = win.document.querySelector("[data-bp-paper-reference-draft]");
  assert.ok(secondRecovery, "discarding one old field surfaces the next retained draft");
  assert.equal(secondRecovery.querySelector("[data-reference-draft-text]").value,
    "Second retained description draft");
  assert.equal(oldIdentityDescription.isConnected, false);
  editorRoot.dataset.paperRev = "12";

  const replacementDraft = win.document.getElementById(
    referenceFieldId("title", changedIdentity),
  );
  replacementDraft.focus();
  replacementDraft.value = "Replacement identity remains independently editable";
  replacementDraft.dispatchEvent(new win.InputEvent("input", {
    bubbles: true, inputType: "insertText", data: replacementDraft.value,
  }));
  await new Promise(resolve => setTimeout(resolve, 510));
  const replacementCall = calls.at(-1);
  assert.equal(replacementCall.payload["paper-link-ref-guard"], changedIdentity,
    "another live draft retains its own replacement identity");
  assert.equal(replacementCall.payload["paper-link-ref-value"], replacementDraft.value);
  await acknowledge(replacementCall, 13);
  const retainedAfterAck = win.document.querySelector("[data-bp-paper-reference-draft]");
  assert.equal(retainedAfterAck.querySelector("[data-reference-draft-text]").value,
    "Second retained description draft",
    "acknowledging another source does not discard the retained old draft");
  hook._bpPaperExitCoordinator._setConflict(
    { current_rev: 14 }, oldIdentityDescription.form,
    "production:paper:reference-copy",
  );
  const cleanConflict = win.document.querySelector(
    "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
  );
  const cleanDiscard = cleanConflict.querySelector("[data-reference-draft-discard]");
  assert.ok(cleanDiscard,
    "an exact never-sent generic conflict exposes source-scoped discard");
  cleanDiscard.click();
  await tick();
  assert.equal(win.document.querySelector("[data-bp-paper-conflict]"), null,
    "clean source discard reconciles and clears the source-less conflict");
  assert.equal(calls.length, callsBeforeIdentityChange + 1,
    "clean generic discard sends no old-identity payload");
  assert.equal(replacementDraft.value, "Replacement identity remains independently editable");
  hook.el.click();
  await tick(); await tick();
  assert.equal(toggles.length, togglesBeforeIdentityChange + 1,
    "View resumes only after every retained old draft is explicitly discarded");
} finally {
  hook.destroyed?.();
  queueDom.window.close();
  morphDom.window.close();
}
console.log("related-card copy serializes same-field and sibling-field saves without broad source payloads");

async function attemptedDetachedRecovery(
  reply,
  { newerDraft = false, earlyConflict = false } = {},
) {
  const attemptedDom = new JSDOM(`<!doctype html><body>
    <main data-paper-doc-key="production:paper:attempted-recovery" data-paper-rev="30">
      <button id="attempted-view" data-editing="true">View</button>
      <div id="paper-editor-attempted-recovery" class="bp-paper-editor"
        data-paper-doc-key="production:paper:attempted-recovery" data-paper-rev="30">
        ${fieldForm("title", "Attempted original title")}
        <footer><button data-paper-history-action="undo" disabled>Undo</button>
          <button data-paper-history-action="redo" disabled>Redo</button>
          <span data-paper-history-status role="status"></span>
          <span data-test-id="bp-paper-footer-save" role="status"></span></footer>
      </div>
    </main></body>`, { runScripts: "outside-only", url: "http://localhost/" });
  const attemptedWindow = attemptedDom.window;
  const attemptedMorph = shippedMorphdom(attemptedWindow);
  let attemptedSerial = 0;
  Object.defineProperty(attemptedWindow, "crypto", { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8002-${String(++attemptedSerial).padStart(12, "0")}`,
  } });
  Object.defineProperty(attemptedWindow, "Blob", {
    configurable: true, value: globalThis.Blob,
  });
  let downloaded = null;
  attemptedWindow.URL.createObjectURL = (blob) => {
    downloaded = blob;
    return "blob:attempted-reference-recovery";
  };
  attemptedWindow.URL.revokeObjectURL = () => {};
  attemptedWindow.HTMLAnchorElement.prototype.click = () => {};
  vm.runInContext(readFileSync(new URL(
    "../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url,
  ), "utf8"), vm.createContext({
    window: attemptedWindow, document: attemptedWindow.document,
    CustomEvent: attemptedWindow.CustomEvent, FormData: attemptedWindow.FormData,
    Date, setTimeout, clearTimeout,
    customElements: { whenDefined: () => Promise.resolve() },
  }));
  const attemptedCalls = [];
  const attemptedReplies = [];
  const attemptedToggles = [];
  const attemptedHook = {
    ...attemptedWindow.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: attemptedWindow.document.getElementById("attempted-view"),
    pushEventTo(_target, event, payload) {
      attemptedCalls.push({ event, payload: structuredClone(payload) });
      return new Promise(resolve => attemptedReplies.push(value => resolve([
        { status: "fulfilled", value: { reply: value } },
      ])));
    },
    pushEvent(event, payload) {
      attemptedToggles.push({ event, payload });
      return Promise.resolve({});
    },
  };
  attemptedHook.mounted();
  try {
    const oldField = attemptedWindow.document.getElementById(referenceFieldId("title"));
    const unsafeText = "  </textarea><img onerror=alert(1)>  ";
    oldField.focus();
    oldField.value = unsafeText;
    oldField.dispatchEvent(new attemptedWindow.InputEvent("input", {
      bubbles: true, inputType: "insertText", data: unsafeText,
    }));
    await new Promise(resolve => setTimeout(resolve, 510));
    assert.equal(attemptedCalls.length, 1, "the old identity request is genuinely in flight");
    if (newerDraft) {
      oldField.value = `${unsafeText}newer`;
      oldField.dispatchEvent(new attemptedWindow.InputEvent("input", {
        bubbles: true, inputType: "insertText", data: "newer",
      }));
    }

    const root = attemptedWindow.document.querySelector(".bp-paper-editor");
    const replacement = root.cloneNode(false);
    replacement.innerHTML = `${fieldForm("title", "Attempted replacement title", changedIdentity)}
      ${root.querySelector("footer").outerHTML}`;
    attemptedMorph(root, replacement, {
      getNodeKey: (node) => node?.id,
      onBeforeElUpdated: (fromEl, toEl) => {
        attemptedWindow.BarkparkPaperEditorBeforeElUpdated(fromEl, toEl);
        return true;
      },
    });
    if (earlyConflict) {
      attemptedHook._bpPaperExitCoordinator._setConflict(
        { current_rev: 31 }, oldField.form, "production:paper:attempted-recovery",
      );
    }
    await tick();
    let recovery = earlyConflict
      ? attemptedWindow.document.querySelector(
        "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
      )
      : attemptedWindow.document.querySelector("[data-bp-paper-reference-draft]");
    assert.ok(recovery, "an attempted detached draft remains visible while its result is unknown");
    assert.equal(recovery.querySelector("[data-reference-draft-text]").value,
      newerDraft ? `${unsafeText}newer` : unsafeText,
      "HTML-like retained text is exposed literally through textarea.value");
    if (earlyConflict) {
      assert.equal(recovery.querySelector('[data-action="latest"]').disabled, true,
        "a conflict rendered before capture settles is refreshed into detached recovery");
    } else {
      assert.equal(recovery.querySelector("[data-reference-draft-discard]").disabled, true,
        "an in-flight request cannot be discarded as local-only");
    }
    recovery.querySelector("[data-reference-draft-download]").click();
    await tick();
    const exported = await downloaded.text();
    assert.match(exported, /<\/textarea><img onerror=alert\(1\)>/);
    assert.doesNotMatch(exported, /request_id|00000000-0000-4000-8002/,
      "recovery export contains no request identifiers or transport credentials");

    attemptedReplies.shift()(reply && {
      ...reply,
      request_id: attemptedCalls[0].payload.request_id,
      ...(reply.history_step ? {
        history_step: {
          ...reply.history_step,
          ref: attemptedCalls[0].payload.request_id,
        },
      } : {}),
    });
    await tick(); await tick();
    recovery = earlyConflict
      ? attemptedWindow.document.querySelector(
        "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
      )
      : attemptedWindow.document.querySelector("[data-bp-paper-reference-draft]");
    if (reply?.saved === true) {
      if (newerDraft) {
        assert.ok(recovery,
          "a newer local version remains recoverable after the older request succeeds");
        assert.equal(recovery.querySelector("[data-reference-draft-text]").value,
          `${unsafeText}newer`);
        assert.equal(recovery.querySelector("[data-reference-draft-discard]").disabled, false,
          "after exact settlement, the never-sent newer version becomes locally discardable");
        recovery.querySelector("[data-reference-draft-discard]").click();
        await tick();
        assert.equal(attemptedWindow.document.querySelector(
          "[data-bp-paper-reference-draft]",
        ), null);
      } else {
        assert.equal(recovery, null,
          "a matching late success settles the ordinary queue and removes recovery");
      }
      assert.equal(attemptedWindow.document.querySelector(
        `[data-paper-history-action="undo"]`,
      ).disabled, false, "late success records ordinary contextual history");
    } else {
      assert.ok(recovery, "a transport-uncertain result remains readable and export-only");
      attemptedHook.el.click();
      await tick(); await tick();
      assert.equal(attemptedCalls.length, 1,
        "View drain never retries a transport-uncertain detached request");
      assert.equal(attemptedToggles.length, 0,
        "View remains blocked while the detached receipt is unresolved");
      if (!earlyConflict) {
        attemptedHook._bpPaperExitCoordinator.observeRevision({
          rev: 31, source: oldField,
        });
        await tick();
      }
      const conflictBanner = attemptedWindow.document.querySelector(
        "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
      );
      assert.ok(conflictBanner, "external authority can still enter ordinary conflict review");
      const latest = conflictBanner.querySelector('[data-action="latest"]');
      assert.equal(latest.disabled, true,
        "generic Use latest cannot delete a registered attempted detached source");
      assert.equal(attemptedHook._bpPaperExitCoordinator._keepMine(), false,
        "the coordinator itself refuses Keep mine for an attempted detached source");
      assert.equal(attemptedHook._bpPaperExitCoordinator._useLatest(), false,
        "the coordinator itself refuses Use latest for an attempted detached source");
      latest.click();
      await tick();
      assert.equal(attemptedWindow.document.querySelector(
        "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
      ), conflictBanner);
      assert.equal(attemptedCalls.length, 1, "conflict review never creates a replacement request");

      const replacementField = attemptedWindow.document.getElementById(
        referenceFieldId("title", changedIdentity),
      );
      attemptedHook._bpPaperExitCoordinator._setConflict(
        { current_rev: 32 },
        replacementField,
        "production:paper:attempted-recovery",
        {
          source: replacementField,
          payload: { block_id: "replacement-probe" },
          documentKey: "production:paper:attempted-recovery",
          ifRev: 31,
        },
      );
      assert.ok(conflictBanner.querySelector("[data-reference-draft-download]"),
        "an unrelated connected conflict retains access to the unresolved draft export");
      assert.equal(conflictBanner.querySelector("[data-reference-draft-text]").value,
        unsafeText, "the unresolved detached value remains readable without retargeting");
      assert.equal(conflictBanner.querySelector('[data-action="keep"]').disabled, true);
      assert.equal(conflictBanner.querySelector('[data-action="latest"]').disabled, true,
        "an unrelated same-document conflict cannot rewrite detached receipt authority");
      assert.equal(attemptedHook._bpPaperExitCoordinator._keepMine(), false);
      assert.equal(attemptedHook._bpPaperExitCoordinator._useLatest(), false);
    }
    assert.equal(attemptedWindow.document.getElementById(
      referenceFieldId("title", changedIdentity),
    ).value, "Attempted replacement title", "late settlement never retargets the old draft");
  } finally {
    attemptedHook.destroyed?.();
    attemptedDom.window.close();
  }
}

await attemptedDetachedRecovery({
  saved: true, changed: true, rev: 31,
  history_step: { version: 1, ref: "filled-from-request", action: "undo" },
});
await attemptedDetachedRecovery({
  saved: true, changed: true, rev: 31,
  history_step: { version: 1, ref: "filled-from-request", action: "undo" },
}, { newerDraft: true });
await attemptedDetachedRecovery(null);
await attemptedDetachedRecovery(null, { earlyConflict: true });
console.log("related-card attempted detached drafts remain receipt-owned and export-only");

async function detachedRecoveryNegative({
  name, malformed = false, replacementGuard = identity,
  replacementRootId = "paper-editor-recovery-negative",
  replacementDocumentKey = "production:paper:recovery-negative",
  sourceSurvives = false,
}) {
  const negativeDom = new JSDOM(`<!doctype html><body>
    <main data-paper-doc-key="production:paper:recovery-negative" data-paper-rev="40">
      <button id="negative-view" data-editing="true">View</button>
      <div id="paper-editor-recovery-negative" class="bp-paper-editor"
        data-paper-doc-key="production:paper:recovery-negative" data-paper-rev="40">
        ${fieldForm("title", "Negative original title")}
        <span data-test-id="bp-paper-footer-save" role="status"></span>
      </div>
    </main></body>`, { runScripts: "outside-only", url: "http://localhost/" });
  const negativeWindow = negativeDom.window;
  const negativeMorph = shippedMorphdom(negativeWindow);
  let negativeSerial = 0;
  Object.defineProperty(negativeWindow, "crypto", { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8003-${String(++negativeSerial).padStart(12, "0")}`,
  } });
  vm.runInContext(readFileSync(new URL(
    "../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url,
  ), "utf8"), vm.createContext({
    window: negativeWindow, document: negativeWindow.document,
    CustomEvent: negativeWindow.CustomEvent, FormData: negativeWindow.FormData,
    Date, setTimeout, clearTimeout,
    customElements: { whenDefined: () => Promise.resolve() },
  }));
  const negativeHook = {
    ...negativeWindow.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: negativeWindow.document.getElementById("negative-view"),
    pushEvent() { return Promise.resolve({}); },
    pushEventTo() { throw new Error("negative recovery must not send"); },
  };
  negativeHook.mounted();
  try {
    const source = negativeWindow.document.getElementById(referenceFieldId("title"));
    if (malformed) {
      const extra = negativeWindow.document.createElement("input");
      extra.type = "hidden";
      extra.name = "unexpected-ref-copy-key";
      extra.value = "unsafe";
      source.form.append(extra);
    }
    source.value = "Negative retained draft";
    source.dispatchEvent(new negativeWindow.InputEvent("input", {
      bubbles: true, inputType: "insertText", data: source.value,
    }));
    const root = negativeWindow.document.querySelector(".bp-paper-editor");
    const replacement = root.cloneNode(false);
    replacement.id = replacementRootId;
    replacement.dataset.paperDocKey = replacementDocumentKey;
    replacement.innerHTML = `${fieldForm("title", "Negative replacement", replacementGuard)}
      <span data-test-id="bp-paper-footer-save" role="status"></span>`;
    negativeMorph(root, replacement, {
      getNodeKey: (node) => node?.id,
      onBeforeElUpdated: (fromEl, toEl) => {
        negativeWindow.BarkparkPaperEditorBeforeElUpdated(fromEl, toEl);
        return true;
      },
    });
    await tick();
    assert.equal(negativeWindow.document.querySelector(
      "[data-bp-paper-reference-draft]",
    ), null, name);
    assert.equal(source.isConnected, sourceSurvives, `${name}: source ownership is explicit`);
  } finally {
    negativeHook.destroyed?.();
    negativeDom.window.close();
  }
}

await detachedRecoveryNegative({
  name: "a guard-stable keyed form is not registered as detached",
  sourceSurvives: true,
});
await detachedRecoveryNegative({
  name: "a malformed extra-key form cannot enter reference draft recovery",
  malformed: true, replacementGuard: changedIdentity,
});
await detachedRecoveryNegative({
  name: "a document-key change cannot transfer a retained reference draft",
  replacementGuard: changedIdentity,
  replacementDocumentKey: "production:paper:another-document",
});
await detachedRecoveryNegative({
  name: "a root-id change cannot transfer a retained reference draft",
  replacementGuard: changedIdentity,
  replacementRootId: "paper-editor-another-root",
});
console.log("related-card recovery ignores connected, malformed, and cross-scope sources");

{
  const fenceDom = new JSDOM(`<!doctype html><body>
    <main data-paper-doc-key="production:paper:recovery-fence" data-paper-rev="50">
      <button id="fence-view" data-editing="true">View</button>
      <div id="paper-editor-recovery-fence" class="bp-paper-editor"
        data-paper-doc-key="production:paper:recovery-fence" data-paper-rev="50">
        ${fieldForm("title", "Fence original")}
        ${fieldForm("description", "Fence original description")}
        <span data-test-id="bp-paper-footer-save" role="status"></span>
      </div>
    </main></body>`, { runScripts: "outside-only", url: "http://localhost/" });
  const fenceWindow = fenceDom.window;
  const fenceMorph = shippedMorphdom(fenceWindow);
  let fenceSerial = 0;
  Object.defineProperty(fenceWindow, "crypto", { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8004-${String(++fenceSerial).padStart(12, "0")}`,
  } });
  vm.runInContext(readFileSync(new URL(
    "../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url,
  ), "utf8"), vm.createContext({
    window: fenceWindow, document: fenceWindow.document,
    CustomEvent: fenceWindow.CustomEvent, FormData: fenceWindow.FormData,
    Date, setTimeout, clearTimeout,
    customElements: { whenDefined: () => Promise.resolve() },
  }));
  const fenceCalls = [];
  const fenceHook = {
    ...fenceWindow.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: fenceWindow.document.getElementById("fence-view"),
    pushEvent() { return Promise.resolve({}); },
    pushEventTo(_target, event, payload) {
      fenceCalls.push({ event, payload: structuredClone(payload) });
      return new Promise(() => {});
    },
  };
  fenceHook.mounted();
  try {
    const oldField = fenceWindow.document.getElementById(referenceFieldId("title"));
    oldField.value = "Never-sent fenced draft";
    oldField.dispatchEvent(new fenceWindow.InputEvent("input", { bubbles: true }));
    const oldDescription = fenceWindow.document.getElementById(referenceFieldId("description"));
    oldDescription.value = "Second never-sent fenced draft";
    oldDescription.dispatchEvent(new fenceWindow.InputEvent("input", { bubbles: true }));
    const root = fenceWindow.document.querySelector(".bp-paper-editor");
    const replacement = root.cloneNode(false);
    replacement.innerHTML = `${fieldForm("title", "Replacement", changedIdentity)}
      ${fieldForm("description", "Replacement description", changedIdentity)}
      <span data-test-id="bp-paper-footer-save" role="status"></span>`;
    fenceMorph(root, replacement, {
      getNodeKey: (node) => node?.id,
      onBeforeElUpdated: (fromEl, toEl) => {
        fenceWindow.BarkparkPaperEditorBeforeElUpdated(fromEl, toEl);
        return true;
      },
    });
    await tick();
    assert.ok(fenceWindow.document.querySelector("[data-bp-paper-reference-draft]"));
    const replacementField = fenceWindow.document.getElementById(
      referenceFieldId("title", changedIdentity),
    );
    replacementField.value = "Independent queued draft";
    replacementField.dispatchEvent(new fenceWindow.InputEvent("input", { bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 510));
    assert.equal(fenceCalls.length, 1);
    assert.ok(fenceWindow.document.querySelector("[data-bp-paper-reference-draft]"),
      "the local-only recovery remains registered while another field sends");
    const queuedRequestId = fenceCalls[0].payload.request_id;
    fenceHook._bpPaperExitCoordinator._setConflict(
      { current_rev: 51 }, oldField.form, "production:paper:recovery-fence",
      { source: oldField.form, documentKey: "production:paper:recovery-fence", ifRev: 50 },
    );
    assert.ok(fenceHook._bpPaperExitCoordinator._conflictDetachedReferenceDraft(),
      "the chosen local-only detached source is recognized as a conflict fence");
    assert.equal(fenceHook._bpPaperExitCoordinator._keepMine(), false,
      "Keep mine cannot rewrite another queue entry for a chosen local-only detached draft");
    assert.equal(fenceHook._bpPaperExitCoordinator._useLatest(), false,
      "Use latest cannot discard a chosen local-only detached draft");
    assert.equal(fenceCalls[0].payload.request_id, queuedRequestId,
      "the unrelated queued receipt identity remains unchanged");
    const genericRecovery = fenceWindow.document.querySelector(
      "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
    );
    const discard = genericRecovery.querySelector("[data-reference-draft-discard]");
    assert.ok(discard, "the exact local-only source remains explicitly discardable");
    discard.click();
    await tick();
    assert.equal(fenceCalls.length, 1,
      "discard does not resend or replace unrelated in-flight authority");
    assert.equal(fenceCalls[0].payload.request_id, queuedRequestId);
    let reanchored = fenceWindow.document.querySelector(
      "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
    );
    assert.equal(reanchored.querySelector("[data-reference-draft-label]").textContent,
      "Retained description draft",
      "reanchoring a shared banner updates the retained field label");
    assert.equal(reanchored.querySelector("[data-reference-draft-text]").value,
      "Second never-sent fenced draft");
    reanchored.querySelector("[data-reference-draft-discard]").click();
    await tick();
    assert.equal(fenceCalls.length, 1);
    assert.equal(fenceCalls[0].payload.request_id, queuedRequestId);
    assert.equal(fenceWindow.document.querySelector("[data-bp-paper-reference-draft]"), null);
    reanchored = fenceWindow.document.querySelector(
      "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
    );
    assert.ok(reanchored, "the conflict remains anchored to the unrelated in-flight source");
    assert.equal(reanchored.querySelector("[data-reference-draft-text]"), null,
      "old local recovery text is removed after exact source discard");
    assert.equal(replacementField.value, "Independent queued draft");
  } finally {
    fenceHook.destroyed?.();
    fenceDom.window.close();
  }
}
console.log("related-card local-only recovery fences direct conflict actions");

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
