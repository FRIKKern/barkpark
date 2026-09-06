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
      <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
    </main>
  `, { url: "http://localhost/", virtualConsole });
  const { window } = dom;
  const clientErrors = [];
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
    customElements: { whenDefined: () => Promise.resolve() },
    console: { error: (...args) => clientErrors.push(args) },
  }));

  const calls = [];
  const replies = [];
  const toggleCalls = [];
  const hook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
    el: window.document.querySelector("#toggle"),
    pushEvent: (event, payload) => {
      toggleCalls.push({ event, payload });
      return Promise.resolve({});
    },
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
    toggleCalls,
    clientErrors,
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

// A canvas acknowledgement can repaint a sibling fallback form between its
// input event and debounce. The autosave must use the captured newer draft,
// after the acknowledged revision is adopted, rather than the repainted DOM.
{
  const env = mountedForm(`
    <form id="tabs-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="25" data-test-id="paper-tabs-editor">
      <input type="hidden" name="block_id" value="tabs">
      <input type="hidden" name="panel-count" value="1">
      <input type="hidden" name="panel-0-id" value="row:one">
      <input name="panel-0-label" value="Compatibility checks">
    </form>
  `);
  const canvas = env.window.document.createElement("div");
  env.window.document.querySelector("main").append(canvas);
  let canvasPayload;
  let settleCanvas;
  const canvasSave = env.hook._exitCoordinator.mutate(canvas, {
    payload: { ops: [{ op: "patch-block", id: "body", patch: { content: [] } }] },
    send: (payload) => {
      canvasPayload = payload;
      return new Promise((resolve) => { settleCanvas = resolve; });
    },
  }).promise;
  await tick();

  const label = env.form.elements.namedItem("panel-0-label");
  label.value = "Public and Studio";
  label.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await new Promise((resolve) => setTimeout(resolve, 35));
  assert.equal(env.calls.length, 0, "the fallback draft waits for the prior canvas write");
  label.value = "Compatibility checks";
  env.window.document.querySelector("main").dataset.paperRev = "8";
  settleCanvas({ saved: true, request_id: canvasPayload.request_id, rev: 8 });
  assert.equal(await canvasSave, true);

  await new Promise((resolve) => setTimeout(resolve, 35));
  assert.equal(env.calls.length, 1, "the newer fallback draft saves after the canvas ack settles");
  assert.equal(env.calls[0].payload.if_rev, 8, "the deferred draft advances onto the own ack base");
  assert.equal(env.calls[0].payload["panel-0-label"], "Public and Studio",
    "the canvas repaint cannot replace the captured fallback draft");
  env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 9 });
  await tick();
  env.close();
}

// A Figure's singular child is a nested canvas while its caption remains a
// sibling fallback form. If the child save is active when the caption changes,
// the own echo must advance and send that retained caption exactly once.
{
  const env = mountedForm(`
    <div id="figure-carrier" data-paper-doc-key="production:paper:validation" data-paper-rev="7">
      <div id="paper-canvas-figure-run" phx-hook="BarkparkPaperCanvas"
           data-paper-doc-key="production:paper:validation" data-paper-rev="7"
           data-paper-container-kind="figure" data-paper-container-id="figure-a"
           data-paper-container-run="0" data-canvas-blocks="[]">
        <bp-paper-canvas></bp-paper-canvas>
      </div>
      <form id="figure-form-figure-a" class="bp-paper-edit-form"
            phx-submit="paper-edit-block" phx-change="paper-block-autosave"
            phx-debounce="10" data-test-id="paper-figure-caption-editor">
        <input type="hidden" name="block_id" value="figure-a">
        <input id="figure-caption-figure-a" name="caption" value="">
      </form>
    </div>
  `);
  const wrapper = env.window.document.querySelector("#paper-canvas-figure-run");
  const canvas = wrapper.querySelector("bp-paper-canvas");
  let acknowledgements = 0;
  canvas.acknowledgeOps = () => {
    acknowledgements += 1;
    if (acknowledgements === 1) {
      throw new Error("simulated canvas acknowledgement adapter failure");
    }
  };
  const echoReceipts = [];
  canvas.applyServerBlocks = (_blocks, receipt) => echoReceipts.push(receipt);
  const canvasCalls = [];
  const canvasReplies = [];
  const adapterErrors = [];
  wrapper.addEventListener("bp-error", (event) => adapterErrors.push(event.detail));
  const handlers = new Map();
  const bridge = {
    ...env.window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
    el: wrapper,
    handleEvent: (name, handler) => handlers.set(name, handler),
    pushEvent: (event, payload) => {
      assert.equal(event, "paper-ops");
      canvasCalls.push(payload);
      return new Promise((resolve) => canvasReplies.push(resolve));
    },
  };
  bridge.mounted();
  canvas.blocks = [{ id: "child-a" }];

  const caption = env.form.elements.namedItem("caption");
  caption.value = "Caption retained behind child";
  caption.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  wrapper.dispatchEvent(new env.window.CustomEvent("bp-canvas-ops", {
    bubbles: true,
    detail: {
      ops: [{ op: "patch-block", id: "child-a", patch: { text: "Saved child" } }],
      seq: 1,
    },
  }));
  assert.equal(canvasCalls.length, 1, "the nested child save starts before caption debounce");
  wrapper.dispatchEvent(new env.window.CustomEvent("bp-canvas-ops", {
    bubbles: true,
    detail: {
      ops: [{ op: "patch-block", id: "child-a", patch: { text: "Saved child twice" } }],
      seq: 2,
    },
  }));
  assert.equal(canvasCalls.length, 1, "the second child batch remains behind its immutable head");

  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(env.calls.length, 0, "the caption cannot overtake its child save");

  const requestId = canvasCalls[0].request_id;
  env.window.document.querySelector("#figure-carrier").dataset.paperRev = "8";
  wrapper.dataset.paperRev = "8";
  handlers.get("bp:canvas-update")({
    rev: 8,
    request_id: requestId,
    runs: [{ run_id: "figure-run", blocks: [{ id: "child-a", text: "Saved child" }] }],
  });
  canvasReplies.shift()({ saved: true, request_id: requestId, rev: 8 });
  await tick();

  assert.equal(canvasCalls.length, 2, "adapter failure cannot strand the second child batch");
  assert.deepEqual(canvasCalls[1].ops, [
    { op: "patch-block", id: "child-a", patch: { text: "Saved child twice" } },
  ]);
  assert.equal(canvasCalls[1].if_rev, 8);
  assert.equal(env.calls.length, 0, "the caption remains behind both child batches");
  env.clickView();
  assert.equal(env.toggleCalls.length, 0, "View waits for both overlapping Figure edits");

  const secondRequestId = canvasCalls[1].request_id;
  env.window.document.querySelector("#figure-carrier").dataset.paperRev = "9";
  wrapper.dataset.paperRev = "9";
  handlers.get("bp:canvas-update")({
    rev: 9,
    request_id: secondRequestId,
    runs: [{ run_id: "figure-run", blocks: [{ id: "child-a", text: "Saved child twice" }] }],
  });
  canvasReplies.shift()({ saved: true, request_id: secondRequestId, rev: 9 });
  await new Promise((resolve) => setTimeout(resolve, 15));

  handlers.get("bp:canvas-update")({
    rev: 8,
    request_id: requestId,
    runs: [{ run_id: "figure-run", blocks: [{ id: "child-a", text: "Saved child" }] }],
  });
  assert.deepEqual(
    JSON.parse(JSON.stringify(echoReceipts)),
    [
      { mode: "own", requestId },
      { mode: "own", requestId: secondRequestId },
      { mode: "own-stale", requestId },
    ],
    "coordinator-classified modes retain their exact request identities",
  );

  assert.equal(env.calls.length, 1, "the retained Figure caption sends after the child ack");
  assert.equal(env.calls[0].payload.caption, "Caption retained behind child");
  assert.equal(env.calls[0].payload.if_rev, 9);
  assert.equal(adapterErrors.length, 1);
  assert.equal(adapterErrors[0].code, "paper_mutation_result_callback_failed");
  assert.equal(
    adapterErrors[0].error,
    "Mutation result could not be applied by its local editor adapter.",
  );
  assert.equal(env.clientErrors.length, 1, "the adapter failure remains observable in browser logs");
  env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 10 });
  await tick();
  assert.equal(env.toggleCalls.length, 1, "View resumes after the retained caption is durable");
  assert.equal(env.toggleCalls[0].event, "paper-toggle-edit");
  bridge.destroyed();
  env.close();
}

// A document-wide own revision can repaint every run, but only the canvas whose
// exact request produced that revision may treat the non-exact echo as its own.
// Preserve the coordinator's request identity through both the outbound seq
// binding and the inbound apply receipt so sibling canvas B cannot consume A's.
{
  const env = mountedForm(`
    <form></form>
    <div id="paper-canvas-cross-a" phx-hook="BarkparkPaperCanvas"
         data-paper-doc-key="production:paper:validation" data-paper-rev="7"
         data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
    <div id="paper-canvas-cross-b" phx-hook="BarkparkPaperCanvas"
         data-paper-doc-key="production:paper:validation" data-paper-rev="7"
         data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
  `);
  const bridges = ["a", "b"].map((suffix) => {
    const wrapper = env.window.document.querySelector(`#paper-canvas-cross-${suffix}`);
    const canvas = wrapper.querySelector("bp-paper-canvas");
    const handlers = new Map();
    const calls = [];
    const replies = [];
    const receipts = [];
    canvas.blocks = [{ id: `child-${suffix}` }];
    canvas.acknowledgeOps = () => {};
    canvas.identifyOpsRequest = (seq, requestId) => {
      canvas.identified = { seq, requestId };
    };
    canvas.applyServerBlocks = (_blocks, receipt) => {
      receipts.push({
        ...receipt,
        trustedOwn: receipt?.mode === "own" &&
          receipt?.requestId === canvas.identified?.requestId,
      });
    };
    const bridge = {
      ...env.window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
      el: wrapper,
      handleEvent: (name, handler) => handlers.set(name, handler),
      pushEvent: (_event, payload) => {
        calls.push(payload);
        return new Promise((resolve) => replies.push(resolve));
      },
    };
    bridge.mounted();
    return { bridge, wrapper, canvas, handlers, calls, replies, receipts };
  });

  bridges.forEach(({ wrapper }, index) => wrapper.dispatchEvent(
    new env.window.CustomEvent("bp-canvas-ops", {
      bubbles: true,
      detail: {
        seq: index + 1,
        ops: [{ op: "patch-block", id: `child-${index}`, patch: { text: "local" } }],
      },
    }),
  ));
  const requestA = bridges[0].canvas.identified.requestId;
  const requestB = bridges[1].canvas.identified.requestId;
  assert.notEqual(requestA, requestB);
  assert.equal(bridges[0].calls.length, 1);
  assert.equal(bridges[1].calls.length, 0, "canvas B waits behind A's document mutation");

  bridges.forEach(({ handlers }, index) => handlers.get("bp:canvas-update")({
    rev: 8,
    request_id: requestA,
    mode: "external",
    runs: [{
      run_id: `cross-${index === 0 ? "a" : "b"}`,
      blocks: [{ id: `child-${index === 0 ? "a" : "b"}`, text: "server" }],
    }],
  }));
  bridges[0].replies.shift()({ saved: true, request_id: requestA, rev: 8 });
  await tick();

  assert.deepEqual(
    bridges[0].receipts,
    [{ mode: "own", requestId: requestA, trustedOwn: true }],
  );
  assert.deepEqual(
    bridges[1].receipts,
    [{ mode: "own", requestId: requestA, trustedOwn: false }],
    "A's own document echo does not satisfy canvas B's exact inflight identity",
  );
  assert.equal(bridges[1].calls.length, 1);
  assert.equal(bridges[1].calls[0].request_id, requestB);
  bridges[1].replies.shift()({ saved: true, request_id: requestB, rev: 9 });
  await tick();
  bridges.forEach(({ bridge }) => bridge.destroyed());
  env.close();
}

// LiveView can paint the Figure child acknowledgement (including the new
// document revision) before the coordinator consumes the matching push reply.
// A caption authored in that window belongs after the child write and must
// advance onto its acknowledged base. The Public reader then refetches and
// emits a source-less echo at that same revision; it is a duplicate, not an
// external change that can turn the retained caption into a conflict.
{
  const env = mountedForm(`
    <div id="figure-echo-carrier" data-paper-doc-key="production:paper:validation" data-paper-rev="7">
      <div id="paper-canvas-figure-echo-run" phx-hook="BarkparkPaperCanvas"
           data-paper-doc-key="production:paper:validation" data-paper-rev="7"
           data-paper-container-kind="figure" data-paper-container-id="figure-echo"
           data-paper-container-run="0" data-canvas-blocks="[]">
        <bp-paper-canvas></bp-paper-canvas>
      </div>
      <form class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="10">
        <input type="hidden" name="block_id" value="figure-echo">
        <input name="caption" value="Old caption">
      </form>
    </div>
  `);
  const wrapper = env.window.document.querySelector("#paper-canvas-figure-echo-run");
  const canvas = wrapper.querySelector("bp-paper-canvas");
  canvas.acknowledgeOps = () => {};
  canvas.applyServerBlocks = () => {};
  const canvasCalls = [];
  const canvasReplies = [];
  const handlers = new Map();
  const bridge = {
    ...env.window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
    el: wrapper,
    handleEvent: (name, handler) => handlers.set(name, handler),
    pushEvent: (_event, payload) => {
      canvasCalls.push(payload);
      return new Promise((resolve) => canvasReplies.push(resolve));
    },
  };
  bridge.mounted();
  canvas.blocks = [{ id: "figure-echo-child" }];
  wrapper.dispatchEvent(new env.window.CustomEvent("bp-canvas-ops", {
    bubbles: true,
    detail: {
      ops: [{ op: "patch-block", id: "figure-echo-child", patch: { text: "New body" } }],
      seq: 1,
    },
  }));

  const requestId = canvasCalls[0].request_id;
  env.window.document.querySelector("#figure-echo-carrier").dataset.paperRev = "8";
  wrapper.dataset.paperRev = "8";
  handlers.get("bp:canvas-update")({
    rev: 8,
    request_id: requestId,
    runs: [{ run_id: "figure-echo-run", blocks: [{ id: "figure-echo-child", text: "New body" }] }],
  });
  const caption = env.form.elements.namedItem("caption");
  caption.value = "Caption authored after own paint";
  caption.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  canvasReplies.shift()({ saved: true, request_id: requestId, rev: 8 });
  await tick();
  handlers.get("bp:canvas-update")({
    rev: 8,
    runs: [{ run_id: "figure-echo-run", blocks: [{ id: "figure-echo-child", text: "New body" }] }],
  });
  await new Promise((resolve) => setTimeout(resolve, 15));

  assert.equal(env.window.document.querySelector("[data-bp-paper-conflict]"), null);
  assert.equal(env.calls.length, 1, "caption authored after the own paint advances and saves");
  assert.equal(env.calls[0].payload.caption, "Caption authored after own paint");
  assert.equal(env.calls[0].payload.if_rev, 8);
  env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 9 });
  await tick();
  bridge.destroyed();
  env.close();
}

// Use latest replaces one conflicted canvas source with authoritative server
// state. Later local batches for that same canvas have not entered the global
// queue yet, so discarding the chosen source must clear its whole local queue.
{
  const env = mountedForm(`
    <div id="discard-carrier" data-paper-doc-key="production:paper:validation" data-paper-rev="7">
      <div id="paper-canvas-discard-run" phx-hook="BarkparkPaperCanvas"
           data-paper-doc-key="production:paper:validation" data-paper-rev="7"
           data-paper-container-kind="figure" data-paper-container-id="figure-discard"
           data-paper-container-run="0" data-canvas-blocks="[]">
        <bp-paper-canvas></bp-paper-canvas>
      </div>
      <form class="bp-paper-edit-form" phx-change="paper-block-autosave">
        <input type="hidden" name="block_id" value="figure-discard">
        <input name="caption" value="Server caption">
      </form>
    </div>
  `);
  const wrapper = env.window.document.querySelector("#paper-canvas-discard-run");
  const canvas = wrapper.querySelector("bp-paper-canvas");
  canvas.acknowledgeOps = () => {};
  canvas.applyServerBlocks = () => {};
  canvas.hasPendingChanges = () => false;
  const calls = [];
  const replies = [];
  const bridge = {
    ...env.window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
    el: wrapper,
    handleEvent: () => {},
    pushEvent: (_event, payload) => {
      calls.push(payload);
      return new Promise((resolve) => replies.push(resolve));
    },
  };
  bridge.mounted();
  canvas.blocks = [{ id: "child-discard" }];

  for (const [text, seq] of [["First local", 1], ["Second local", 2]]) {
    wrapper.dispatchEvent(new env.window.CustomEvent("bp-canvas-ops", {
      bubbles: true,
      detail: {
        ops: [{ op: "patch-block", id: "child-discard", patch: { text } }],
        seq,
      },
    }));
  }
  assert.equal(calls.length, 1, "only the conflicted head enters the global queue");
  replies.shift()({
    saved: false,
    request_id: calls[0].request_id,
    conflict: true,
    current_rev: 8,
  });
  await tick();

  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner);
  banner.querySelector('[data-action="latest"]').click();
  await tick();

  assert.equal(calls.length, 1, "Use latest never sends the superseded second local batch");
  assert.equal(bridge._opsQueue.length, 0, "Use latest clears all local work for its chosen canvas");
  env.clickView();
  await tick();
  assert.equal(env.toggleCalls.length, 1, "discarded local canvas work cannot strand View");
  bridge.destroyed();
  env.close();
}

// An ambiguous canvas failure keeps its immutable request at the queue head.
// A sibling form draft must neither overtake it nor be discarded; after an
// exact successful retry, that draft advances and autosaves once.
{
  const env = mountedForm(`
    <form id="retry-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0">
      <input type="hidden" name="block_id" value="paragraph">
      <input name="text" value="Before">
    </form>
  `);
  const canvas = env.window.document.createElement("div");
  env.window.document.querySelector("main").append(canvas);
  const canvasCalls = [];
  const canvasReplies = [];
  const mutation = env.hook._exitCoordinator.mutate(canvas, {
    payload: { ops: [{ op: "patch-block", id: "body", patch: { content: [] } }] },
    send: (payload) => {
      canvasCalls.push(JSON.parse(JSON.stringify(payload)));
      return new Promise((resolve) => canvasReplies.push(resolve));
    },
  });
  await tick();

  const text = env.form.elements.namedItem("text");
  text.value = "Newest draft";
  text.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  canvasReplies.shift()({ saved: false, request_id: canvasCalls[0].request_id });
  assert.equal(await mutation.promise, false);
  await tick();
  assert.equal(env.calls.length, 0, "a sibling draft never overtakes the failed canvas write");

  const retry = env.hook._exitCoordinator.retryMutation(mutation.entry);
  await tick();
  assert.deepEqual(canvasCalls[1], canvasCalls[0], "the canvas failure retries its exact wire payload");
  text.value = "Before";
  env.window.document.querySelector("main").dataset.paperRev = "8";
  canvasReplies.shift()({ saved: true, request_id: canvasCalls[1].request_id, rev: 8 });
  assert.equal(await retry, true);
  await tick();
  assert.equal(env.calls.length, 1, "the deferred form resumes only after the prior retry succeeds");
  assert.equal(env.calls[0].payload.text, "Newest draft");
  assert.equal(env.calls[0].payload.if_rev, 8);
  env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 9 });
  await tick();
  env.close();
}

// Never restore a positional draft when an acknowledgement remounts or
// reorders its row identities. The dirty guard remains, but no stale payload
// is synthesized or sent from the repainted form.
{
  const env = mountedForm(`
    <form id="changed-rows" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0" data-test-id="paper-tabs-editor">
      <input type="hidden" name="block_id" value="tabs">
      <input type="hidden" name="panel-count" value="2">
      <input type="hidden" name="panel-0-id" value="row:one">
      <input name="panel-0-label" value="First">
      <input type="hidden" name="panel-1-id" value="row:two">
      <input name="panel-1-label" value="Second">
    </form>
  `);
  const canvas = env.window.document.createElement("div");
  env.window.document.querySelector("main").append(canvas);
  let canvasPayload;
  let settleCanvas;
  const canvasSave = env.hook._exitCoordinator.mutate(canvas, {
    payload: { ops: [{ op: "move-block", id: "body", to: 0 }] },
    send: (payload) => {
      canvasPayload = payload;
      return new Promise((resolve) => { settleCanvas = resolve; });
    },
  }).promise;
  await tick();

  const first = env.form.elements.namedItem("panel-0-label");
  first.value = "Draft for first";
  first.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  env.form.elements.namedItem("panel-0-id").value = "row:two";
  first.value = "Second";
  env.form.elements.namedItem("panel-1-id").value = "row:one";
  env.form.elements.namedItem("panel-1-label").value = "First";
  env.window.document.querySelector("main").dataset.paperRev = "8";
  settleCanvas({ saved: true, request_id: canvasPayload.request_id, rev: 8 });
  assert.equal(await canvasSave, true);
  await tick();
  env.clickView();
  await tick();
  assert.equal(env.calls.length, 0, "changed row identities fail closed without an autosave");
  assert.equal(first.value, "Second", "the old positional snapshot is not restored onto the moved row");
  env.close();
}

// Option rows have no stable identity. A same-length option move can leave the
// question identity/count fences unchanged, so a newer same-form draft must
// enter review instead of restoring old positional option values over the ack.
{
  const env = mountedForm(`
    <form id="question-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0" data-test-id="paper-form-editor">
      <input type="hidden" name="block_id" value="questions">
      <input type="hidden" name="question-count" value="1">
      <input type="hidden" name="question-0-original-id" value="answer:one">
      <input name="question-0-id" value="answer:one">
      <input name="question-0-prompt" value="Original prompt">
      <input type="hidden" name="question-0-option-count" value="2">
      <input name="question-0-option-0" value="First">
      <input name="question-0-option-1" value="Second">
    </form>
  `);
  let actionPayload;
  let settleAction;
  const action = env.hook._exitCoordinator.mutate(env.form, {
    payload: { block_id: "questions", "option-action": "up:answer:one:1" },
    send: (payload) => {
      actionPayload = payload;
      return new Promise((resolve) => { settleAction = resolve; });
    },
  }).promise;
  await tick();

  const prompt = env.form.elements.namedItem("question-0-prompt");
  prompt.value = "Newest prompt";
  prompt.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  env.form.elements.namedItem("question-0-option-0").value = "Second";
  env.form.elements.namedItem("question-0-option-1").value = "First";
  env.window.document.querySelector("main").dataset.paperRev = "8";
  settleAction({ saved: true, request_id: actionPayload.request_id, rev: 8 });
  assert.equal(await action, true);
  await tick();

  assert.equal(env.calls.length, 0, "the old option order is never autosaved over its acknowledgement");
  assert.equal(env.form.elements.namedItem("question-0-option-0").value, "Second");
  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the preserved newer draft enters explicit review");
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true);
  prompt.value = "Edited during review";
  prompt.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  await tick();
  assert.equal(env.calls.length, 0, "editing the retained draft cannot bypass conflict review");
  banner.querySelector('[data-action="review"]').click();
  const review = JSON.parse(banner.querySelector("[data-conflict-draft]").textContent);
  const values = (draft) => Object.fromEntries(
    draft.values.map((field) => [field.name, field.value]),
  );
  assert.equal(
    values(review.retainedDraftBeforeAcknowledgement)["question-0-prompt"],
    "Newest prompt",
    "Review preserves the prompt captured before the acknowledgement",
  );
  assert.deepEqual(
    [
      values(review.retainedDraftBeforeAcknowledgement)["question-0-option-0"],
      values(review.retainedDraftBeforeAcknowledgement)["question-0-option-1"],
    ],
    ["First", "Second"],
    "Review preserves the pre-ack positional option order without remapping",
  );
  assert.equal(
    values(review.currentDraftDuringReview)["question-0-prompt"],
    "Edited during review",
    "Review also exposes input authored after the conflict was shown",
  );
  assert.deepEqual(
    [
      values(review.currentDraftDuringReview)["question-0-option-0"],
      values(review.currentDraftDuringReview)["question-0-option-1"],
    ],
    ["Second", "First"],
    "the current review draft records the acknowledged server row order separately",
  );
  env.close();
}

// The same fail-closed rule covers positional collection actions without row
// identities. A gauge move must not let a newer title draft replay old rows.
{
  const env = mountedForm(`
    <form id="gauge-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0" data-test-id="paper-gauge-list-editor">
      <input type="hidden" name="block_id" value="gauges">
      <input name="title" value="Original title">
      <input type="hidden" name="gauge-count" value="2">
      <input name="gauge-0-label" value="First">
      <input name="gauge-0-value" value="1">
      <input name="gauge-1-label" value="Second">
      <input name="gauge-1-value" value="2">
    </form>
  `);
  let actionPayload;
  let settleAction;
  const action = env.hook._exitCoordinator.mutate(env.form, {
    payload: { block_id: "gauges", "gauge-action": "up:1" },
    send: (payload) => {
      actionPayload = payload;
      return new Promise((resolve) => { settleAction = resolve; });
    },
  }).promise;
  await tick();

  const title = env.form.elements.namedItem("title");
  title.value = "Newest title";
  title.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  env.form.elements.namedItem("gauge-0-label").value = "Second";
  env.form.elements.namedItem("gauge-0-value").value = "2";
  env.form.elements.namedItem("gauge-1-label").value = "First";
  env.form.elements.namedItem("gauge-1-value").value = "1";
  env.window.document.querySelector("main").dataset.paperRev = "8";
  settleAction({ saved: true, request_id: actionPayload.request_id, rev: 8 });
  assert.equal(await action, true);
  await tick();

  assert.equal(env.calls.length, 0, "the old gauge positions are never autosaved over the move");
  assert.equal(env.form.elements.namedItem("gauge-0-label").value, "Second");
  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the newer title draft remains available for explicit review");
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true);
  banner.querySelector('[data-action="review"]').click();
  assert.match(banner.querySelector("[data-conflict-draft]").textContent, /Newest title/);
  env.close();
}

// Section and Columns children are addressed by their current position in the
// form even though their actions carry stable child IDs. An acknowledged move
// must therefore retain a newer metadata draft for explicit discard instead of
// restoring the pre-ack ordering and rebasing it onto the new revision.
for (const scenario of [
  {
    name: "Section",
    testId: "paper-section-structure-editor",
    actionName: "section-action",
    actionValue: "up:child:two",
    controls: `
      <input type="hidden" name="section-child-count" value="2">
      <input type="hidden" name="section-child-0-id" value="child:one">
      <input type="hidden" name="section-child-1-id" value="child:two">
    `,
    repaint(form) {
      form.elements.namedItem("section-child-0-id").value = "child:two";
      form.elements.namedItem("section-child-1-id").value = "child:one";
    },
    firstChild(form) {
      return form.elements.namedItem("section-child-0-id").value;
    },
  },
  {
    name: "Columns",
    testId: "paper-columns-structure-editor",
    actionName: "column-action",
    actionValue: "up:0:child:two",
    controls: `
      <input type="hidden" name="column-count" value="1">
      <input type="hidden" name="column-0-child-count" value="2">
      <input type="hidden" name="column-0-child-0-id" value="child:one">
      <input type="hidden" name="column-0-child-1-id" value="child:two">
    `,
    repaint(form) {
      form.elements.namedItem("column-0-child-0-id").value = "child:two";
      form.elements.namedItem("column-0-child-1-id").value = "child:one";
    },
    firstChild(form) {
      return form.elements.namedItem("column-0-child-0-id").value;
    },
  },
]) {
  const env = mountedForm(`
    <form id="${scenario.name.toLowerCase()}-form" class="bp-paper-edit-form"
          phx-change="paper-block-autosave" phx-debounce="0"
          data-test-id="${scenario.testId}">
      <input type="hidden" name="block_id" value="container">
      <input name="title" value="Original title">
      ${scenario.controls}
    </form>
  `);
  let actionPayload;
  let settleAction;
  const action = env.hook._exitCoordinator.mutate(env.form, {
    payload: {
      block_id: "container",
      [scenario.actionName]: scenario.actionValue,
    },
    send: (payload) => {
      actionPayload = payload;
      return new Promise((resolve) => { settleAction = resolve; });
    },
  }).promise;
  await tick();

  const title = env.form.elements.namedItem("title");
  title.value = `${scenario.name} retained draft`;
  title.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  scenario.repaint(env.form);
  env.window.document.querySelector("main").dataset.paperRev = "8";
  settleAction({ saved: true, request_id: actionPayload.request_id, rev: 8 });
  assert.equal(await action, true);
  await tick();

  assert.equal(env.calls.length, 0, `${scenario.name} does not rebase the pre-ack child order`);
  assert.equal(scenario.firstChild(env.form), "child:two");
  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, `${scenario.name} retains the newer draft for review`);
  const keep = banner.querySelector('[data-action="keep"]');
  assert.equal(keep.disabled, true, `${scenario.name} Keep mine is unavailable`);
  banner.querySelector('[data-action="review"]').click();
  const review = JSON.parse(banner.querySelector("[data-conflict-draft]").textContent);
  const originalValues = Object.fromEntries(
    review.values.map((field) => [field.name, field.value]),
  );
  assert.equal(originalValues.title, `${scenario.name} retained draft`);
  title.value = `${scenario.name} latest review draft`;
  title.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  banner.querySelector('[data-action="review"]').click();
  const latest = JSON.parse(banner.querySelector("[data-conflict-draft]").textContent);
  const retainedValues = Object.fromEntries(
    latest.retainedDraftBeforeAcknowledgement.values.map((field) => [field.name, field.value]),
  );
  const latestValues = Object.fromEntries(
    latest.currentDraftDuringReview.values.map((field) => [field.name, field.value]),
  );
  assert.equal(retainedValues.title, `${scenario.name} retained draft`);
  assert.equal(latestValues.title, `${scenario.name} latest review draft`);
  assert.equal(retainedValues[scenario.actionName], scenario.actionValue);
  assert.equal(latestValues[scenario.actionName], scenario.actionValue);
  const firstChildName = scenario.name === "Section"
    ? "section-child-0-id"
    : "column-0-child-0-id";
  assert.equal(retainedValues[firstChildName], "child:one");
  assert.equal(latestValues[firstChildName], "child:two");
  keep.click();
  await tick();
  assert.equal(env.calls.length, 0, `${scenario.name} cannot retry an unsafe positional draft`);
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  assert.equal(env.window.document.querySelector("[data-bp-paper-conflict]"), null);
  assert.equal(env.calls.length, 0, `${scenario.name} Use latest explicitly discards the draft`);
  env.close();
}

// A direct server conflict reaches _setConflict without the successful-ack
// fallback advance above. Structural child actions must still be classified as
// positional so Keep mine cannot rewrite and resend them at the server revision.
for (const [actionName, actionValue] of [
  ["section-action", "up:child:two"],
  ["column-action", "up:0:child:two"],
]) {
  const env = mountedForm(`
    <form id="direct-${actionName}" class="bp-paper-edit-form"
          phx-change="paper-block-autosave" phx-debounce="0">
      <input type="hidden" name="block_id" value="container">
      <input name="title" value="Retained title">
    </form>
  `);
  let sent = 0;
  const mutation = env.hook._exitCoordinator.mutate(env.form, {
    payload: { block_id: "container", [actionName]: actionValue },
    send: (payload) => {
      sent += 1;
      return Promise.resolve({
        saved: false,
        request_id: payload.request_id,
        conflict: true,
        current_rev: 8,
      });
    },
  });
  assert.equal(await mutation.promise, false);
  await tick();
  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner);
  const keep = banner.querySelector('[data-action="keep"]');
  assert.equal(keep.disabled, true, `${actionName} direct conflict disables Keep mine`);
  keep.click();
  await tick();
  assert.equal(sent, 1, `${actionName} cannot be resent on the conflicting revision`);
  banner.querySelector('[data-action="review"]').click();
  assert.match(
    banner.querySelector("[data-conflict-message]").textContent,
    /positional collections/i,
  );
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  assert.equal(env.window.document.querySelector("[data-bp-paper-conflict]"), null);
  env.close();
}

// Merely sharing a structural form does not make an ordinary metadata conflict
// positional. Without an action payload, its exact retry remains available.
for (const controls of [
  `<input type="hidden" name="section-child-count" value="2">
   <input type="hidden" name="section-child-0-id" value="child:one">`,
  `<input type="hidden" name="column-count" value="1">
   <input type="hidden" name="column-0-child-count" value="2">
   <input type="hidden" name="column-0-child-0-id" value="child:one">`,
]) {
  const env = mountedForm(`
    <form class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="0">
      <input type="hidden" name="block_id" value="container">
      <input name="title" value="Retained title">
      ${controls}
    </form>
  `);
  const payload = Object.fromEntries(new env.window.FormData(env.form));
  const mutation = env.hook._exitCoordinator.mutate(env.form, {
    payload,
    send: (payload) => Promise.resolve({
      saved: false,
      request_id: payload.request_id,
      conflict: true,
      current_rev: 8,
    }),
  });
  assert.equal(await mutation.promise, false);
  await tick();
  const banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.equal(
    banner.querySelector('[data-action="keep"]').disabled,
    false,
    "a metadata-only conflict retains its exact retry",
  );
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  env.close();
}

// Section and Columns inserts consume one client-generated child ID. Rotate it
// after each exact successful acknowledgement, including a successful retry,
// but keep it stable while an ambiguous/failed attempt awaits that retry.
for (const scenario of [
  {
    name: "Section",
    actionName: "section-action",
    actionValue: "add",
    generatedName: "section-new-child-id",
  },
  {
    name: "Columns",
    actionName: "column-action",
    actionValue: "add:0",
    generatedName: "column-new-child-id",
  },
]) {
  const initialId = `b-${scenario.name.toLowerCase()}-initial`;
  const env = mountedForm(`
    <form id="insert-${scenario.name.toLowerCase()}" phx-submit="paper-edit-block"
          data-test-id="paper-${scenario.name.toLowerCase()}-structure-editor">
      <input type="hidden" name="block_id" value="container">
      <input type="hidden" name="${scenario.generatedName}" value="${initialId}">
      <button type="submit" name="${scenario.actionName}" value="${scenario.actionValue}">
        Add child
      </button>
    </form>
  `);
  const coordinator = env.hook._exitCoordinator;
  const mutate = coordinator.mutate.bind(coordinator);
  let latestEntry;
  coordinator.mutate = (...args) => {
    const mutation = mutate(...args);
    latestEntry = mutation.entry;
    return mutation;
  };
  const generated = env.form.elements.namedItem(scenario.generatedName);
  const submitter = env.form.elements.namedItem(scenario.actionName);
  const submit = () => env.form.dispatchEvent(new env.window.SubmitEvent("submit", {
    bubbles: true,
    cancelable: true,
    submitter,
  }));

  submit();
  await tick();
  assert.equal(env.calls[0].payload[scenario.generatedName], initialId);
  env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 8 });
  await tick();
  const secondId = generated.value;
  assert.notEqual(secondId, initialId, `${scenario.name} rotates its first consumed child ID`);
  assert.equal(generated.defaultValue, secondId);

  env.window.document.querySelector("main").dataset.paperRev = "8";
  submit();
  await tick();
  assert.equal(env.calls[1].payload[scenario.generatedName], secondId);
  generated.value = initialId;
  generated.defaultValue = initialId;
  env.settle({ saved: true, request_id: env.calls[1].payload.request_id, rev: 9 });
  await tick();
  const thirdId = generated.value;
  assert.notEqual(thirdId, initialId, `${scenario.name} replaces a stale server repaint`);
  assert.notEqual(thirdId, secondId);
  assert.equal(generated.defaultValue, thirdId);

  env.window.document.querySelector("main").dataset.paperRev = "9";
  submit();
  await tick();
  const failedWire = { ...env.calls[2].payload };
  assert.equal(failedWire[scenario.generatedName], thirdId);
  const failedEntry = latestEntry;
  env.settle({ saved: false, request_id: failedWire.request_id });
  await tick();
  assert.equal(generated.value, thirdId, `${scenario.name} failure retains the pending child ID`);
  assert.equal(generated.defaultValue, thirdId);

  const retry = coordinator.retryMutation(failedEntry);
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(env.calls[3].payload)),
    JSON.parse(JSON.stringify(failedWire)),
    `${scenario.name} retry is exact`,
  );
  generated.value = initialId;
  generated.defaultValue = initialId;
  env.settle({ saved: true, request_id: failedWire.request_id, rev: 10 });
  assert.equal(await retry, true);
  await tick();
  assert.notEqual(generated.value, initialId, `${scenario.name} successful retry rotates after repaint`);
  assert.notEqual(generated.value, secondId);
  assert.notEqual(generated.value, thirdId);
  assert.equal(generated.defaultValue, generated.value);
  env.close();
}

// Structural child focus follows the exact child identity across LiveView row
// replacement. IDs may contain colons, so Columns actions are matched against
// the captured column/child vectors rather than split on delimiters.
for (const family of ["section", "column"]) {
  const actionName = family === "section" ? "section-action" : "column-action";
  const generatedName = family === "section" ? "section-new-child-id" : "column-new-child-id";
  const wire = (kind, id) => family === "section" ? `${kind}:${id}` : `${kind}:0:${id}`;
  const addWire = family === "section" ? "add" : "add:0";
  const render = (ids, generatedId = "child:new:with:colons") => `
    <input type="hidden" name="block_id" value="container">
    ${family === "section"
      ? `<input type="hidden" name="section-child-count" value="${ids.length}">`
      : `<input type="hidden" name="column-count" value="1">
         <input type="hidden" name="column-0-child-count" value="${ids.length}">`}
    <input type="hidden" name="${generatedName}" value="${generatedId}">
    ${ids.map((id, index) => `
      <input type="hidden" name="${family === "section"
        ? `section-child-${index}-id`
        : `column-0-child-${index}-id`}" value="${id}">
      <button type="submit" name="${actionName}" value="${wire("up", id)}"
              ${index === 0 ? "disabled" : ""}>Move up</button>
      <button type="submit" name="${actionName}" value="${wire("down", id)}"
              ${index === ids.length - 1 ? "disabled" : ""}>Move down</button>
      <button type="submit" name="${actionName}" value="${wire("remove", id)}">Remove</button>
    `).join("")}
    <button type="submit" name="${actionName}" value="${addWire}">Add</button>
  `;

  for (const scenario of [
    {
      action: wire("up", "child:two"),
      after: ["child:two", "child:one"],
      expected: wire("down", "child:two"),
    },
    {
      action: wire("down", "child:one"),
      after: ["child:two", "child:one"],
      expected: wire("up", "child:one"),
    },
    {
      action: wire("remove", "child:one"),
      after: ["child:two"],
      expected: wire("remove", "child:two"),
    },
    {
      action: addWire,
      after: ["child:one", "child:two", "child:new:with:colons"],
      expected: wire("up", "child:new:with:colons"),
    },
    {
      action: wire("up", "child:two"),
      after: ["child:two", "child:one"],
      saved: false,
    },
    {
      action: wire("up", "child:two"),
      after: ["child:two", "child:one"],
      moveFocus: true,
    },
  ]) {
    const env = mountedForm(`
      <form phx-submit="paper-edit-block" data-test-id="paper-${family}-structure-editor">
        ${render(["child:one", "child:two"])}
      </form>
      <button id="structural-focus-elsewhere" type="button">Elsewhere</button>
    `);
    const submitter = [...env.form.elements].find((control) =>
      control.name === actionName && control.value === scenario.action);
    submitter.focus();
    env.form.dispatchEvent(new env.window.SubmitEvent("submit", {
      bubbles: true,
      cancelable: true,
      submitter,
    }));
    await tick();
    if (scenario.moveFocus) {
      env.window.document.getElementById("structural-focus-elsewhere").focus();
    }
    env.form.innerHTML = render(scenario.after);
    env.settle({
      saved: scenario.saved !== false,
      request_id: env.calls[0].payload.request_id,
      ...(scenario.saved === false ? {} : { rev: 8 }),
    });
    await tick();
    if (scenario.saved === false) {
      assert.notEqual(
        env.window.document.activeElement.value,
        wire("down", "child:two"),
        `${family} failure does not focus a repainted child control`,
      );
    } else if (scenario.moveFocus) {
      assert.equal(
        env.window.document.activeElement.id,
        "structural-focus-elsewhere",
        `${family} acknowledgement does not steal focus moved elsewhere`,
      );
    } else {
      assert.equal(
        env.window.document.activeElement.value,
        scenario.expected,
        `${family} ${scenario.action} restores focus to the resulting child control`,
      );
    }
    env.close();
  }
}

// A positional acknowledgement can expose a newer same-source draft while a
// second source is already queued. Review/discard must stay bound to the
// acknowledged source; the next queue head remains intact and progresses.
{
  const env = mountedForm(`
    <form id="source-a" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0" data-test-id="paper-gauge-list-editor">
      <input type="hidden" name="block_id" value="gauges">
      <input name="title" value="Original title">
      <input type="hidden" name="gauge-count" value="2">
      <input name="gauge-0-label" value="First">
      <input name="gauge-0-value" value="1">
      <input name="gauge-1-label" value="Second">
      <input name="gauge-1-value" value="2">
    </form>
  `);
  let actionPayload;
  let settleAction;
  const action = env.hook._exitCoordinator.mutate(env.form, {
    payload: { block_id: "gauges", "gauge-action": "up:1" },
    send: (payload) => {
      actionPayload = payload;
      return new Promise((resolve) => { settleAction = resolve; });
    },
  }).promise;
  await tick();
  const title = env.form.elements.namedItem("title");
  title.value = "Source A retained draft";
  title.dispatchEvent(new env.window.Event("input", { bubbles: true }));

  const sourceB = env.window.document.createElement("div");
  env.window.document.querySelector("main").append(sourceB);
  const sourceBCalls = [];
  let settleSourceB;
  const queuedB = env.hook._exitCoordinator.mutate(sourceB, {
    payload: { ops: [{ op: "patch-block", id: "body-b", patch: { text: "B" } }] },
    send: (payload) => {
      sourceBCalls.push(payload);
      return new Promise((resolve) => { settleSourceB = resolve; });
    },
  }).promise;
  assert.equal(sourceBCalls.length, 0, "source B waits behind source A");

  env.form.elements.namedItem("gauge-0-label").value = "Second";
  env.form.elements.namedItem("gauge-0-value").value = "2";
  env.form.elements.namedItem("gauge-1-label").value = "First";
  env.form.elements.namedItem("gauge-1-value").value = "1";
  env.window.document.querySelector("main").dataset.paperRev = "8";
  settleAction({ saved: true, request_id: actionPayload.request_id, rev: 8 });
  assert.equal(await action, true);
  await tick();

  let banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner);
  banner.querySelector('[data-action="review"]').click();
  assert.match(
    banner.querySelector("[data-conflict-draft]").textContent,
    /Source A retained draft/,
    "review remains bound to acknowledged source A rather than queued source B",
  );
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  assert.equal(sourceBCalls.length, 1, "discarding A lets queued source B progress");
  assert.equal(sourceBCalls[0].if_rev, 8);
  settleSourceB({ saved: true, request_id: sourceBCalls[0].request_id, rev: 9 });
  assert.equal(await queuedB, true);
  await tick();
  env.close();
}

// Discarding one conflicted source must surface a deferred sibling draft for
// its own explicit review/discard choice instead of leaving it timerless.
{
  const env = mountedForm(`
    <form id="sibling-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="0">
      <input type="hidden" name="block_id" value="paragraph">
      <input name="text" value="Before">
    </form>
  `);
  const canvas = env.window.document.createElement("div");
  env.window.document.querySelector("main").append(canvas);
  let canvasPayload;
  let settleCanvas;
  const canvasSave = env.hook._exitCoordinator.mutate(canvas, {
    payload: { ops: [{ op: "patch-block", id: "body", patch: { content: [] } }] },
    send: (payload) => {
      canvasPayload = payload;
      return new Promise((resolve) => { settleCanvas = resolve; });
    },
  }).promise;
  await tick();

  const text = env.form.elements.namedItem("text");
  text.value = "Local draft";
  text.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  env.hook._exitCoordinator.observeRevision({
    rev: 8,
    observedDocumentKey: "production:paper:validation",
    source: env.form,
    apply() {
      env.window.document.querySelector("main").dataset.paperRev = "8";
      text.value = "Server latest";
    },
  });
  settleCanvas({
    saved: false,
    request_id: canvasPayload.request_id,
    conflict: true,
    current_rev: 8,
  });
  assert.equal(await canvasSave, false);
  await tick();

  let banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the primary mutation conflict is actionable");
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the deferred sibling receives its own explicit conflict action");
  banner.querySelector('[data-action="review"]').click();
  assert.match(
    banner.querySelector("[data-conflict-draft]").textContent,
    /Local draft/,
    "the deferred sibling snapshot remains reviewable",
  );
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  assert.equal(env.window.document.querySelector("[data-bp-paper-conflict]"), null);
  assert.equal(text.value, "Server latest", "discard keeps the authoritative server paint");
  assert.equal(env.calls.length, 0, "discard never autosaves the old-base sibling draft");
  env.close();
}

// An external echo is not required to name the locally dirty form. When the
// mutation queue is already empty, conflict review must still bind to each
// retained fallback source instead of showing an empty, retryable payload.
{
  const env = mountedForm(`
    <form id="number-form" class="bp-paper-edit-form" phx-change="paper-edit-block"
          phx-debounce="1000" data-test-id="paper-field-number-editor">
      <input type="hidden" name="block_id" value="number">
      <input name="label" value="Number">
      <input type="number" name="value" value="15" step="any">
      <input type="number" name="min" value="1" step="any">
      <input type="number" name="max" value="15" step="any">
      <input type="number" name="step" value="" min="0" step="any">
    </form>
    <form id="questions-form" class="bp-paper-edit-form" phx-change="paper-block-autosave"
          phx-debounce="1000" data-test-id="paper-form-editor">
      <input type="hidden" name="block_id" value="questions">
      <input type="hidden" name="question-count" value="1">
      <input type="hidden" name="question-0-original-id" value="answer:one">
      <input name="question-0-id" value="answer:one">
      <input name="question-0-prompt" value="Original prompt">
      <input type="hidden" name="question-0-option-count" value="1">
      <input name="question-0-option-0" value="Studio">
    </form>
  `);
  const numberForm = env.window.document.querySelector("#number-form");
  const questionsForm = env.window.document.querySelector("#questions-form");
  const label = numberForm.elements.namedItem("label");
  const prompt = questionsForm.elements.namedItem("question-0-prompt");
  label.value = "Public";
  label.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  prompt.value = "Latest question";
  prompt.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  assert.equal(numberForm.checkValidity(), true, "the authored number range is natively valid");

  const echoSource = env.window.document.createElement("div");
  env.window.document.querySelector("main").append(echoSource);
  env.hook._exitCoordinator.observeRevision({
    rev: 8,
    observedDocumentKey: "production:paper:validation",
    source: echoSource,
    apply() {
      env.window.document.querySelector("main").dataset.paperRev = "8";
      label.value = "Number";
      prompt.value = "Server question";
    },
  });
  let banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "an echo source without a local draft still enters explicit review");
  assert.equal(
    env.window.document.querySelector('[data-test-id="bp-paper-footer-save"]').textContent,
    "Save paused — review required.",
    "an externally introduced conflict replaces the stale Saving status",
  );
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true);
  banner.querySelector('[data-action="review"]').click();
  assert.match(
    banner.querySelector("[data-conflict-draft]").textContent,
    /Public/,
    "review binds to the first dirty form snapshot instead of an empty payload",
  );

  banner.querySelector('[data-action="latest"]').click();
  await tick();
  banner = env.window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "discarding the first draft surfaces the second dirty form");
  assert.equal(banner.querySelector('[data-action="keep"]').disabled, true);
  banner.querySelector('[data-action="review"]').click();
  assert.match(banner.querySelector("[data-conflict-draft]").textContent, /Latest question/);
  banner.querySelector('[data-action="latest"]').click();
  await tick();
  assert.equal(env.window.document.querySelector("[data-bp-paper-conflict]"), null);
  assert.equal(env.calls.length, 0, "explicit discard never saves either old-base draft");
  env.close();
}

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

// Questionnaire scale bounds use text inputs to preserve exact integer wires.
// Validate syntax and authored order before debounce, while an unchanged
// reversed legacy pair remains a valid no-op when another field changes.
{
  const env = mountedForm(`
    <form class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="0"
          data-test-id="paper-form-editor">
      <input type="hidden" name="block_id" value="questions">
      <input type="hidden" name="question-count" value="1">
      <input name="question-0-prompt" value="Prompt">
      <input name="question-0-scale-min" value="1">
      <input name="question-0-scale-max" value="5">
    </form>
  `);
  const min = env.form.elements.namedItem("question-0-scale-min");
  min.value = "not-a-number";
  min.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(env.calls.length, 0, "a non-integer scale bound never reaches the server");
  assert.match(min.validationMessage, /whole number/i);
  assert.equal(min.value, "not-a-number", "the invalid bound remains available to correct");

  min.value = "+2";
  min.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(env.calls.length, 1, "a corrected signed integer saves once");
  assert.equal(env.calls[0].payload["question-0-scale-min"], "+2");
  env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 8 });
  await tick();
  env.close();
}

{
  const env = mountedForm(`
    <form class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="0"
          data-test-id="paper-form-editor">
      <input type="hidden" name="block_id" value="questions">
      <input type="hidden" name="question-count" value="1">
      <input name="question-0-prompt" value="Prompt">
      <input name="question-0-scale-min" value="1">
      <input name="question-0-scale-max" value="5">
    </form>
  `);
  const min = env.form.elements.namedItem("question-0-scale-min");
  const max = env.form.elements.namedItem("question-0-scale-max");
  min.value = "9";
  min.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(env.calls.length, 0, "newly reversed scale bounds never reach the server");
  assert.match(max.validationMessage, /at least the minimum/i);
  assert.equal(min.value, "9", "the reversed draft remains available to correct");
  env.close();
}

{
  const env = mountedForm(`
    <form class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="0"
          data-test-id="paper-form-editor">
      <input type="hidden" name="block_id" value="questions">
      <input type="hidden" name="question-count" value="1">
      <input name="question-0-prompt" value="Legacy prompt">
      <input name="question-0-scale-min" value="09">
      <input name="question-0-scale-max" value="+5">
    </form>
  `);
  const prompt = env.form.elements.namedItem("question-0-prompt");
  prompt.value = "Updated prompt";
  prompt.dispatchEvent(new env.window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(env.calls.length, 1, "unchanged reversed legacy bounds do not block another edit");
  assert.equal(env.calls[0].payload["question-0-scale-min"], "09");
  assert.equal(env.calls[0].payload["question-0-scale-max"], "+5");
  env.settle({ saved: true, request_id: env.calls[0].payload.request_id, rev: 8 });
  await tick();
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
