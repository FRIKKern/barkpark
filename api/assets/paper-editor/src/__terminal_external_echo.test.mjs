import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM, VirtualConsole } from "jsdom";

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function environment(html) {
  const navigationErrors = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on("jsdomError", (error) => navigationErrors.push(error));
  const dom = new JSDOM(html, {
    runScripts: "outside-only",
    url: "http://localhost/studio/terminal",
    virtualConsole,
  });
  const { window } = dom;
  let nextRequest = 0;
  Object.defineProperty(window, "crypto", { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8000-${String(++nextRequest).padStart(12, "0")}`,
  } });
  const context = vm.createContext({
    window,
    document: window.document,
    CustomEvent: window.CustomEvent,
    Event: window.Event,
    FormData: window.FormData,
    setTimeout,
    clearTimeout,
    console,
    customElements: window.customElements,
  });
  vm.runInContext(
    readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
    context,
  );
  return { dom, window, hooks: window.BarkparkPaperEditorHooks, navigationErrors };
}

function shippedMorphdom(window) {
  window.eval(readFileSync(new URL("../../../priv/static/assets/phoenix.js", import.meta.url), "utf8"));
  const source = readFileSync(
    new URL("../../../priv/static/assets/phoenix_live_view.js", import.meta.url),
    "utf8",
  );
  const instrumented = source.replace(
    ",rt=hn;",
    ",rt=hn;window.__bpShippedMorphdom=rt;",
  );
  assert.notEqual(instrumented, source, "the shipped LiveView bundle exposes its vendored morphdom in this test");
  window.eval(instrumented);
  assert.equal(typeof window.__bpShippedMorphdom, "function");
  return window.__bpShippedMorphdom;
}

function liveViewMorph(window, from, to) {
  const morphdom = shippedMorphdom(window);
  return morphdom(from, to, {
    getNodeKey: (node) => node?.getAttribute?.("id") || node?.id,
    onBeforeElUpdated: (fromEl, toEl) => {
      const ignored = fromEl.getAttribute("phx-update") === "ignore";
      window.BarkparkPaperEditorBeforeElUpdated(fromEl, toEl);
      if (ignored) return false;
    },
  });
}

{
  const { window, hooks, navigationErrors } = environment(`
    <main data-paper-doc-key="production:document:terminal" data-document-rev="7">
      <div id="paper-terminal-boundary-terminal" phx-hook="BarkparkTerminalBoundary"
           data-paper-terminal-boundary data-paper-terminal-id="terminal"
           data-paper-terminal-rev="7" data-paper-rev="7"
           data-paper-terminal-supported="true">
        <div class="bp-term">
          <div id="paper-ed-child" phx-update="ignore" phx-hook="BarkparkPaperEditor">
            <bp-paper-editor><div contenteditable="true">Local draft</div></bp-paper-editor>
          </div>
          <div id="paper-ed-child-two" phx-update="ignore" phx-hook="BarkparkPaperEditor">
            <bp-paper-editor><div contenteditable="true">Second local draft</div></bp-paper-editor>
          </div>
        </div>
      </div>
      <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
    </main>
  `);
  const boundary = window.document.querySelector("[data-paper-terminal-boundary]");
  const childWrapper = window.document.querySelector("#paper-ed-child");
  const childEditor = childWrapper.querySelector("bp-paper-editor");
  const secondChildWrapper = window.document.querySelector("#paper-ed-child-two");
  const secondChildEditor = secondChildWrapper.querySelector("bp-paper-editor");
  const handlers = new Map();
  const terminalHook = {
    ...hooks.BarkparkTerminalBoundary,
    el: boundary,
    handleEvent: (name, handler) => handlers.set(name, handler),
    pushEvent: () => Promise.resolve({}),
    pushEventTo: () => Promise.resolve([]),
  };
  terminalHook.mounted();
  const childHook = {
    ...hooks.BarkparkPaperEditor,
    el: childWrapper,
    handleEvent: () => {},
    pushEvent: () => Promise.resolve({}),
    pushEventTo: () => Promise.resolve([]),
  };
  childHook.mounted();
  const secondChildHook = {
    ...hooks.BarkparkPaperEditor,
    el: secondChildWrapper,
    handleEvent: () => {},
    pushEvent: () => Promise.resolve({}),
    pushEventTo: () => Promise.resolve([]),
  };
  secondChildHook.mounted();

  childEditor.querySelector("[contenteditable]").dispatchEvent(
    new window.Event("input", { bubbles: true }),
  );
  childEditor.pending = true;
  childEditor.hasPendingChanges = () => childEditor.pending;
  childEditor.resolveConflictWithServerBlock = () => { childEditor.pending = false; };
  childEditor.draftSentinel = "retained";
  secondChildEditor.querySelector("[contenteditable]").dispatchEvent(
    new window.Event("input", { bubbles: true }),
  );
  secondChildEditor.pending = true;
  secondChildEditor.hasPendingChanges = () => secondChildEditor.pending;
  secondChildEditor.resolveConflictWithServerBlock = () => { secondChildEditor.pending = false; };
  secondChildEditor.draftSentinel = "second-retained";

  const incoming = window.document.createElement("div");
  incoming.id = boundary.id;
  incoming.setAttribute("phx-hook", "BarkparkTerminalBoundary");
  incoming.setAttribute("data-paper-terminal-boundary", "");
  incoming.setAttribute("data-paper-terminal-id", "terminal");
  incoming.setAttribute("data-paper-terminal-rev", "8");
  incoming.setAttribute("data-paper-rev", "8");
  incoming.setAttribute("data-paper-terminal-supported", "false");
  incoming.innerHTML = '<div data-test-id="paper-terminal-readonly">Authoritative dual body</div>';

  liveViewMorph(window, boundary, incoming);
  assert.equal(window.document.querySelector("#paper-ed-child"), childWrapper,
    "the shipped morphdom keeps the keyed ignored child wrapper");
  assert.equal(childEditor.draftSentinel, "retained", "the mounted child editor and draft survive");
  assert.equal(window.document.querySelector("#paper-ed-child-two"), secondChildWrapper);
  assert.equal(secondChildEditor.draftSentinel, "second-retained");
  assert.equal(boundary.dataset.paperTerminalSupported, "false");
  assert.equal(boundary.dataset.paperTerminalGuarded, "true");
  terminalHook.updated();
  const banner = window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the withheld external revision becomes an explicit conflict");
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true,
    "an unsupported topology cannot be positionally rebased with Keep mine");
  banner.querySelector('[data-action="review"]').click();

  const repeated = incoming.cloneNode(true);
  repeated.dataset.paperTerminalRev = "9";
  repeated.dataset.paperRev = "9";
  repeated.innerHTML = '<div data-test-id="paper-terminal-readonly">Newer malformed body</div>';
  liveViewMorph(window, boundary, repeated);
  assert.equal(window.document.querySelector("#paper-ed-child"), childWrapper,
    "the guarded marker protects repeated unsupported echoes");
  assert.equal(window.document.querySelector("#paper-ed-child-two"), secondChildWrapper,
    "a repeated echo preserves every dirty descendant, not only the first source");
  terminalHook.updated();
  assert.match(banner.querySelector("[data-conflict-message]").textContent, /9/,
    "an open Review panel refreshes without another synthetic click");

  const supportedEmpty = boundary.cloneNode(false);
  supportedEmpty.dataset.paperTerminalSupported = "true";
  supportedEmpty.dataset.paperTerminalRev = "10";
  supportedEmpty.dataset.paperRev = "10";
  supportedEmpty.innerHTML = '<div class="bp-term"><div class="bp-term__body"></div></div>';
  liveViewMorph(window, boundary, supportedEmpty);
  terminalHook.updated();
  assert.equal(window.document.querySelector("#paper-ed-child"), childWrapper,
    "a later supported empty body cannot bypass an unresolved guard");
  assert.equal(window.document.querySelector("#paper-ed-child-two"), secondChildWrapper);
  assert.equal(childEditor.pending, true);
  assert.equal(secondChildEditor.pending, true);
  assert.ok(window.document.querySelector("[data-bp-paper-conflict]"),
    "the explicit resolution remains required after the supported echo");
  assert.match(
    window.document.querySelector("[data-conflict-message]").textContent,
    /10/,
    "the guarded conflict advances to the newest authoritative revision",
  );
  assert.equal(banner.querySelector("[data-conflict-detail]").hidden, false);

  banner.querySelector('[data-action="latest"]').dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );
  assert.ok(window.document.querySelector("[data-bp-paper-conflict]"),
    "the second source receives its own review instead of being discarded by reload");
  assert.equal(childEditor.pending, false, "Use latest explicitly discards only the chosen draft");
  assert.equal(secondChildEditor.pending, true, "the second editor remains protected for review");
  assert.equal(window.document.querySelector("#paper-ed-child"), childWrapper,
    "Use latest defers its reload while another source remains dirty");
  assert.equal(window.document.querySelector("#paper-ed-child-two"), secondChildWrapper,
    "Use latest retains the other dirty descendant until its own review is resolved");
  assert.equal(navigationErrors.length, 0, "no direct reload discards the second source");
  window.document.querySelector('[data-bp-paper-conflict] [data-action="latest"]').dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );
  assert.equal(secondChildEditor.pending, false);
  assert.equal(window.document.querySelector("[data-bp-paper-conflict]"), null);
  assert.equal(navigationErrors.length, 1, "one reload follows explicit discard of every draft");

  childHook.destroyed();
  secondChildHook.destroyed();
  terminalHook.destroyed();
}

{
  const { window, hooks, navigationErrors } = environment(`
    <main data-paper-doc-key="production:paper:terminal-active" data-paper-rev="7">
      <div id="paper-terminal-boundary-active" phx-hook="BarkparkTerminalBoundary"
           data-paper-terminal-boundary data-paper-terminal-id="terminal-active"
           data-paper-terminal-rev="7" data-paper-rev="7"
           data-paper-terminal-supported="true">
        <form id="terminal-active-form" class="bp-paper-edit-form"
              phx-change="paper-block-autosave" phx-debounce="0">
          <input name="block_id" value="terminal-active">
          <input name="title" value="Before">
        </form>
      </div>
      <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
    </main>
  `);
  const boundary = window.document.querySelector("[data-paper-terminal-boundary]");
  const form = window.document.querySelector("#terminal-active-form");
  const handlers = new Map();
  const sends = [];
  let settle;
  const terminalHook = {
    ...hooks.BarkparkTerminalBoundary,
    el: boundary,
    handleEvent: (name, handler) => handlers.set(name, handler),
    pushEvent: () => Promise.resolve({}),
    pushEventTo: (_target, event, payload) => {
      if (event !== "paper-block-autosave") return Promise.resolve({});
      sends.push(payload);
      return new Promise((resolve) => { settle = resolve; });
    },
  };
  terminalHook.mounted();

  const title = form.elements.namedItem("title");
  title.value = "Saving draft";
  title.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(sends.length, 1, "the form save is active before the incompatible echo");

  const incoming = boundary.cloneNode(false);
  incoming.dataset.paperTerminalSupported = "false";
  incoming.dataset.paperTerminalRev = "8";
  incoming.dataset.paperRev = "8";
  incoming.innerHTML = '<div data-test-id="paper-terminal-readonly">Unsupported</div>';
  liveViewMorph(window, boundary, incoming);
  terminalHook.updated();
  assert.equal(window.document.querySelector("[data-bp-paper-conflict]"), null,
    "the external revision waits until the active mutation settles");

  title.value = "Newer draft while saving";
  title.dispatchEvent(new window.Event("input", { bubbles: true }));
  settle({ saved: true, request_id: sends[0].request_id, rev: 8 });
  await tick();
  await tick();

  const banner = window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the deferred unsupported echo becomes a conflict after settlement");
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true);
  assert.equal(sends.length, 1, "the newer draft is not retried against unsupported topology");
  assert.equal(title.value, "Newer draft while saving");
  assert.equal(navigationErrors.length, 0, "settlement does not directly reload the dirty draft");
  terminalHook.destroyed();
}

{
  const { window, hooks, navigationErrors } = environment(`
    <main data-paper-doc-key="production:paper:two-terminals" data-paper-rev="20">
      <div id="paper-terminal-boundary-a" phx-hook="BarkparkTerminalBoundary"
           data-paper-terminal-boundary data-paper-terminal-id="terminal-a"
           data-paper-terminal-rev="20" data-paper-rev="20"
           data-paper-terminal-supported="true">
        <div id="paper-ed-terminal-a" phx-update="ignore" phx-hook="BarkparkPaperEditor">
          <bp-paper-editor><div contenteditable="true">Draft A</div></bp-paper-editor>
        </div>
      </div>
      <div id="paper-terminal-boundary-b" phx-hook="BarkparkTerminalBoundary"
           data-paper-terminal-boundary data-paper-terminal-id="terminal-b"
           data-paper-terminal-rev="20" data-paper-rev="20"
           data-paper-terminal-supported="true">
        <div id="paper-ed-terminal-b" phx-update="ignore" phx-hook="BarkparkPaperEditor">
          <bp-paper-editor><div contenteditable="true">Draft B</div></bp-paper-editor>
        </div>
      </div>
      <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
    </main>
  `);
  const hookFor = (boundary) => {
    const hook = {
      ...hooks.BarkparkTerminalBoundary,
      el: boundary,
      handleEvent: () => {},
      pushEvent: () => Promise.resolve({}),
      pushEventTo: () => Promise.resolve([]),
    };
    hook.mounted();
    return hook;
  };
  const boundaryA = window.document.querySelector("#paper-terminal-boundary-a");
  const boundaryB = window.document.querySelector("#paper-terminal-boundary-b");
  const hookA = hookFor(boundaryA);
  const hookB = hookFor(boundaryB);
  const editorA = boundaryA.querySelector("bp-paper-editor");
  const editorB = boundaryB.querySelector("bp-paper-editor");
  editorA.pending = true;
  editorA.hasPendingChanges = () => editorA.pending;
  editorA.resolveConflictWithServerBlock = () => { editorA.pending = false; };
  editorB.pending = true;
  editorB.hasPendingChanges = () => editorB.pending;
  editorB.resolveConflictWithServerBlock = () => { editorB.pending = false; };
  editorA.querySelector("[contenteditable]").dispatchEvent(
    new window.Event("input", { bubbles: true }),
  );

  for (const [boundary, hook, revision] of [
    [boundaryA, hookA, "21"],
    [boundaryB, hookB, "22"],
  ]) {
    const incoming = boundary.cloneNode(false);
    incoming.dataset.paperTerminalSupported = "false";
    incoming.dataset.paperTerminalRev = revision;
    incoming.dataset.paperRev = revision;
    incoming.innerHTML = '<div data-test-id="paper-terminal-readonly">Unsupported</div>';
    liveViewMorph(window, boundary, incoming);
    hook.updated();
  }

  let banner = window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner);
  banner.querySelector('[data-action="latest"]').click();
  assert.equal(editorA.pending, false);
  assert.equal(editorB.pending, true, "the second boundary pending state is not globally cleared");
  assert.equal(navigationErrors.length, 0);
  banner = window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the second guarded Terminal receives its own explicit choice");
  banner.querySelector('[data-action="review"]').click();
  assert.match(banner.querySelector("[data-conflict-message]").textContent, /22/);
  banner.querySelector('[data-action="latest"]').click();
  assert.equal(editorB.pending, false);
  assert.equal(window.document.querySelector("[data-bp-paper-conflict]"), null);
  assert.equal(navigationErrors.length, 1, "two boundaries settle before one final reload");

  hookA.destroyed();
  hookB.destroyed();
}

for (const type of ["terminal", "stage"]) {
  const { window, hooks } = environment(`
    <main data-paper-doc-key="production:paper:terminal" data-paper-rev="11">
      <div id="legacy-terminal-run" phx-hook="BarkparkPaperCanvas"
           data-canvas-blocks='[{"id":"child","type":"paragraph","content":[]}]'>
        <bp-paper-canvas></bp-paper-canvas>
      </div>
      <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
    </main>
  `);
  const wrapper = window.document.querySelector("#legacy-terminal-run");
  const canvas = wrapper.querySelector("bp-paper-canvas");
  canvas.acknowledgeOps = () => {};
  canvas.identifyOpsRequest = () => {};
  const calls = [];
  const bridge = {
    ...hooks.BarkparkPaperCanvas,
    el: wrapper,
    handleEvent: () => {},
    pushEvent: (name, payload) => {
      if (name !== "paper-ops") return Promise.resolve({});
      calls.push(payload);
      return Promise.resolve({
        saved: false,
        request_id: payload.request_id,
        rejected: `outdated_${type}_canvas`,
        current_rev: 11,
        error: "Reload the Paper editor before editing this Terminal. Your draft has not been saved.",
      });
    },
  };
  bridge.mounted();
  canvas.dispatchEvent(new window.CustomEvent("bp-canvas-ops", { bubbles: true, detail: {
    ops: [{ op: "patch-block", id: "child", patch: { content: [] } }],
    seq: 1,
  } }));
  await tick();
  await tick();

  assert.equal(calls.length, 1, "the outdated Terminal canvas payload is not auto-retried");
  const banner = window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the retained coarse-canvas draft gets an explicit recovery choice");
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true);
  assert.match(window.document.querySelector('[role="status"]').textContent, /paused/i);
  assert.equal(bridge._opsQueue.length, 1, "the refused draft remains available until Use latest");
  bridge.destroyed();
}

{
  const { window } = environment(`
    <main>
      <div id="paper-editor-reconnect" class="bp-paper-editor" data-paper-doc-key="production:paper:reconnect">
        <div id="paper-canvas-reconnect-run-0" phx-update="ignore" phx-hook="BarkparkPaperCanvas"
             data-paper-doc-key="production:paper:reconnect">
          <bp-paper-canvas><div id="live-caret" contenteditable="true">Local canvas draft</div></bp-paper-canvas>
        </div>
        <form id="live-form"><input id="live-field" value="Server baseline"></form>
      </div>
    </main>
  `);
  const root = window.document.querySelector("#paper-editor-reconnect");
  const wrapper = window.document.querySelector("#paper-canvas-reconnect-run-0");
  const editor = wrapper.querySelector("bp-paper-canvas");
  const editable = editor.querySelector("#live-caret");
  const form = window.document.querySelector("#live-form");
  const field = window.document.querySelector("#live-field");
  editor.historySentinel = { undoDepth: 3 };
  editor.pendingSentinel = { requestId: "local-only-request" };
  field.value = "Unsaved native form value";
  editable.focus();
  const range = window.document.createRange();
  range.setStart(editable.firstChild, 6);
  range.collapse(true);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);

  const halted = window.document.createElement("div");
  halted.id = root.id;
  halted.className = root.className;
  halted.dataset.paperDocKey = root.dataset.paperDocKey;
  halted.dataset.paperCanvasResumeHalt = "true";
  halted.dataset.paperCanvasResumeState = "pending";
  halted.innerHTML = '<div data-test-id="paper-table-contextual-editor">Server owner</div>';

  liveViewMorph(window, root, halted);
  assert.equal(window.document.querySelector("#paper-canvas-reconnect-run-0"), wrapper,
    "the first halt morph preserves the live ignored canvas wrapper");
  assert.equal(wrapper.querySelector("bp-paper-canvas"), editor,
    "the first halt morph preserves the mounted editor instance");
  assert.deepEqual(editor.historySentinel, { undoDepth: 3 },
    "the frozen editor retains native history state");
  assert.deepEqual(editor.pendingSentinel, { requestId: "local-only-request" },
    "the frozen editor retains its pending save state");
  assert.equal(window.document.querySelector("#live-form"), form,
    "a keyed native form remains the live form instance");
  assert.equal(window.document.querySelector("#live-field"), field);
  assert.equal(field.value, "Unsaved native form value",
    "the first halt morph preserves unsaved native form values");
  assert.equal(window.document.activeElement, editable,
    "the frozen editor retains its focused editing surface");
  assert.equal(window.getSelection().anchorNode, editable.firstChild);
  assert.equal(window.getSelection().anchorOffset, 6,
    "the frozen editor retains its exact caret");
  assert.equal(window.document.querySelector('[data-test-id="paper-table-contextual-editor"]'), null,
    "the halt patch cannot introduce a second contextual owner");
  assert.equal(root.dataset.paperCanvasResumeHalt, "true");

  const repeatedHalt = halted.cloneNode(false);
  repeatedHalt.innerHTML = '<div data-test-id="paper-section-editor">Newer server owner</div>';
  liveViewMorph(window, root, repeatedHalt);
  assert.equal(window.document.querySelector("#paper-canvas-reconnect-run-0"), wrapper,
    "every repeated halt patch preserves the same live canvas wrapper");
  assert.equal(wrapper.querySelector("bp-paper-canvas"), editor);
  assert.equal(window.document.querySelector('[data-test-id="paper-section-editor"]'), null,
    "a repeated halt cannot introduce another contextual owner");
  assert.equal(field.value, "Unsaved native form value");

  const resumed = window.document.createElement("div");
  resumed.id = root.id;
  resumed.className = root.className;
  resumed.dataset.paperDocKey = root.dataset.paperDocKey;
  resumed.innerHTML = `
    <div id="paper-canvas-reconnect-run-0" phx-update="ignore" phx-hook="BarkparkPaperCanvas">
      <bp-paper-canvas><div id="live-caret" contenteditable="true">Server acknowledgement</div></bp-paper-canvas>
    </div>
    <form id="live-form"><input id="live-field" value="Server baseline"></form>
  `;
  liveViewMorph(window, root, resumed);
  assert.equal(window.document.querySelector("#paper-canvas-reconnect-run-0"), wrapper,
    "a successful retry unhalts onto the matching retained server run without remounting it");
  assert.equal(wrapper.querySelector("bp-paper-canvas"), editor);
  assert.deepEqual(editor.historySentinel, { undoDepth: 3 });
  assert.deepEqual(editor.pendingSentinel, { requestId: "local-only-request" });

  const discarded = window.document.createElement("div");
  discarded.id = root.id;
  discarded.className = root.className;
  discarded.dataset.paperDocKey = root.dataset.paperDocKey;
  discarded.innerHTML = '<div id="authoritative-unhalted-child">Authoritative server editor</div>';
  liveViewMorph(window, root, discarded);
  assert.equal(wrapper.isConnected, false,
    "an explicit discard patch resumes morphing instead of leaving a sticky frozen root");
  assert.ok(window.document.querySelector("#authoritative-unhalted-child"));
}

{
  const { window } = environment(`
    <main><div id="paper-editor-reconnect" class="bp-paper-editor" data-paper-doc-key="production:paper:first">
      <div id="old-paper-child">First paper</div>
    </div></main>
  `);
  const root = window.document.querySelector("#paper-editor-reconnect");
  const oldChild = window.document.querySelector("#old-paper-child");
  const wrongDocument = window.document.createElement("div");
  wrongDocument.id = root.id;
  wrongDocument.className = root.className;
  wrongDocument.dataset.paperDocKey = "production:paper:second";
  wrongDocument.dataset.paperCanvasResumeHalt = "true";
  wrongDocument.dataset.paperCanvasResumeState = "pending";
  wrongDocument.innerHTML = '<div id="second-paper-child">Second paper</div>';
  liveViewMorph(window, root, wrongDocument);
  assert.equal(oldChild.isConnected, false,
    "a halt marker for another document cannot freeze the previous paper DOM");
  assert.ok(window.document.querySelector("#second-paper-child"));
}

{
  const { window } = environment(`
    <main><div id="paper-editor-blocked" class="bp-paper-editor" data-paper-doc-key="production:paper:blocked">
      <div id="paper-canvas-blocked-run-0" phx-update="ignore" phx-hook="BarkparkPaperCanvas"
           data-paper-doc-key="production:paper:blocked">
        <bp-paper-canvas><div contenteditable="true">Recoverable local text</div></bp-paper-canvas>
      </div>
    </div></main>
  `);
  const root = window.document.querySelector("#paper-editor-blocked");
  const wrapper = window.document.querySelector("#paper-canvas-blocked-run-0");
  const blocked = window.document.createElement("div");
  blocked.id = root.id;
  blocked.className = root.className;
  blocked.dataset.paperDocKey = root.dataset.paperDocKey;
  blocked.dataset.paperCanvasResumeHalt = "true";
  blocked.dataset.paperCanvasResumeState = "blocked";
  blocked.innerHTML = '<div data-test-id="paper-table-contextual-editor">Unsafe duplicate</div>';
  liveViewMorph(window, root, blocked);
  assert.equal(window.document.querySelector("#paper-canvas-blocked-run-0"), wrapper);
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_canvas_lease_key: "production:paper:blocked",
      paper_canvas_lease_overflow: true,
    },
    "a blocked halt persists a scoped recovery attempt without exposing partial leases",
  );
}

console.log("terminal external echo boundary: ok");
