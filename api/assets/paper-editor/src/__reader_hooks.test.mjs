import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<main><button id="toggle" data-editing="true">View</button><div id="paper-canvas-probe-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]" data-canvas-dataset="production" data-canvas-token="writer" data-canvas-scope-prefix="/w/acme/p/books" data-canvas-picker-browse="false"><bp-paper-canvas></bp-paper-canvas></div><form class="bp-paper-edit-form" phx-change="paper-block-autosave"><input name="block_id" value="fallback-1"><textarea name="text">Before</textarea></form><footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer></main>');
const { window } = dom;
let nextRequestId = 0;
Object.defineProperty(window, 'crypto', {configurable:true, value:{
  randomUUID: () => `00000000-0000-4000-8000-${String(++nextRequestId).padStart(12, '0')}`,
}});
let now = 1_000;
class TestDate extends Date { static now() { return now; } }
let upgrade;
const context = vm.createContext({window, document: window.document, CustomEvent: window.CustomEvent,
  FormData: window.FormData, Date: TestDate,
  customElements: { whenDefined: () => new Promise(resolve => { upgrade = resolve; }) }});
vm.runInContext(readFileSync(new URL('../../../priv/static/assets/bp-paper-editor-hooks.js', import.meta.url), 'utf8'), context);
const hooks = window.BarkparkPaperEditorHooks;
const wrapper = window.document.querySelector('[phx-hook]');
const canvas = wrapper.querySelector('bp-paper-canvas');
const acknowledged = [];
canvas.acknowledgeOps = (seq, saved) => acknowledged.push({seq, saved});
const saveErrors = [];
wrapper.addEventListener('bp-error', (event) => saveErrors.push(event.detail));
const handlers = new Map();
const calls = [];
const replies = [];
const settleNext = (reply, requestId) => {
  const pending = replies.shift();
  if (
    pending.payload?.request_id && !Array.isArray(reply) && reply != null &&
    typeof reply === 'object'
  ) {
    reply = {...reply, request_id: requestId === undefined ? pending.payload.request_id : requestId};
  }
  pending.resolve(reply);
  return pending;
};
const bridge = { ...hooks.BarkparkPaperCanvas, el: wrapper,
  handleEvent: (name, handler) => handlers.set(name, handler),
  pushEvent: (name, payload) => {
    calls.push(name);
    if (name !== 'paper-ops') return Promise.resolve({});
    return new Promise((resolve, reject) => replies.push({resolve, reject, payload}));
  },
};
bridge.mounted();
assert.equal(canvas.getAttribute('data-scope-prefix'), '/w/acme/p/books');
assert.equal(canvas.getAttribute('data-picker-browse'), 'false');

// Real ordering on the reader: LiveView hook mounts before deferred WC upgrade.
handlers.get('bp:block-html')({renders: [{block_id:'chart',html:'<p>Rendered chart</p>'}]});
canvas.innerHTML = '<div data-bp-fleet-id="chart"><div data-bp-fleet-body>Loading</div></div>';
canvas.dispatchEvent(new window.CustomEvent('bp-ready', {bubbles:true}));
assert.equal(canvas.querySelector('[data-bp-fleet-body]').textContent, 'Rendered chart');
upgrade();
await Promise.resolve();
assert.equal(canvas.querySelector('[data-bp-fleet-body]').textContent, 'Rendered chart');

const toggle = { ...hooks.BarkparkPaperEditToggle, el: window.document.querySelector('#toggle'),
  pushEvent: (name) => {
    calls.push(name);
    if (name === 'paper-toggle-edit' && delayedToggle) {
      return new Promise((resolve, reject) => toggleReplies.push({resolve, reject}));
    }
    return Promise.resolve({});
  },
  pushEventTo: (_target, name, payload) => {
    calls.push(name);
    return new Promise((resolve, reject) => replies.push({resolve, reject, payload}));
  },
};
let delayedToggle = false;
const toggleReplies = [];
toggle.mounted();
let dirty = true;
let nextSeq = 0;
const flush = () => { if (!dirty) return; dirty = false; canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles: true, detail: {ops:[{op:'patch-block',id:'body',patch:{content:[]}}], seq:++nextSeq},
})); };
canvas.flushPendingChanges = flush;
const click = () => toggle.el.dispatchEvent(new window.MouseEvent('click', {bubbles:true,cancelable:true}));
const tick = () => new Promise(resolve => setTimeout(resolve, 0));
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-ops']);
assert.equal(toggle.el.disabled, true);
click();
assert.equal(replies.length, 1, 'a repeated click cannot send another save');
const firstRequestId = replies[0].payload.request_id;
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-toggle-edit']);
assert.equal(toggle.el.disabled, false);

calls.length = 0;
dirty = true;
click();
settleNext({saved:false});
await tick();
assert.deepEqual(calls, ['paper-ops'], 'a refused save must keep the editor mounted');
assert.equal(toggle.el.disabled, false);
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-ops'], 'the next View retries a saved:false canvas batch');
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-toggle-edit']);

// A delayed success for an older batch cannot acknowledge the current batch.
calls.length = 0;
dirty = true;
click();
const mismatchedRequestId = replies[0].payload.request_id;
const mismatchedSeq = nextSeq;
assert.notEqual(mismatchedRequestId, firstRequestId);
settleNext({saved:true}, firstRequestId);
await tick();
assert.deepEqual(calls, ['paper-ops'], 'a mismatched request ID must keep editing');
assert.deepEqual(acknowledged.at(-1), {seq:mismatchedSeq, saved:false});
calls.length = 0;
click();
assert.equal(replies[0].payload.request_id, mismatchedRequestId, 'a mismatched acknowledgement retries the same batch identity');
settleNext({saved:true});
await tick();
assert.deepEqual(acknowledged.at(-1), {seq:mismatchedSeq, saved:true}, 'only the matching acknowledgement advances its sequence');
assert.deepEqual(calls, ['paper-ops','paper-toggle-edit']);

// A transport reply without an explicit persistence result is not a save ack.
calls.length = 0;
dirty = true;
click();
settleNext({});
await tick();
assert.deepEqual(calls, ['paper-ops'], 'a missing saved field must keep editing');
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-ops'], 'an unacknowledged batch remains retryable');
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-toggle-edit']);

// A save already in flight must finish even when the immediate flush is clean.
canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {bubbles:true,detail:{ops:[]}}));
canvas.flushPendingChanges = () => {};
calls.length = 0;
click();
assert.deepEqual(calls, []);
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-toggle-edit']);

// Typing while a previous save is pending is included in the same transition.
canvas.flushPendingChanges = flush;
dirty = true;
calls.length = 0;
click();
dirty = true;
const firstTypingRequestId = replies[0].payload.request_id;
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-ops']);
assert.equal(toggle.el.disabled, true);
assert.notEqual(replies[0].payload.request_id, firstTypingRequestId, 'a later batch receives a new request ID');
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-ops','paper-toggle-edit']);

// A transport failure must settle the barrier as false. View remains editing,
// and the button is usable again instead of hanging forever in aria-busy state.
dirty = true;
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-ops']);
const disconnectedRequestId = replies[0].payload.request_id;
replies.shift().reject(new Error('disconnected'));
await tick();
assert.deepEqual(calls, ['paper-ops'], 'a rejected save must not toggle View');
assert.equal(toggle.el.disabled, false, 'a rejected save re-enables the View button');
assert.equal(toggle.el.getAttribute('aria-busy'), null);

calls.length = 0;
canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles:true,
  detail:{ops:[{op:'patch-block',id:'source-b',patch:{content:[]}}]},
}));
assert.deepEqual(calls, [], 'a later source delta waits behind the failed rich batch');
click();
assert.deepEqual(calls, ['paper-ops'], 'the next View retries the failed canvas save');
assert.equal(replies[0].payload.request_id, disconnectedRequestId, 'a lost reply retries with the original request ID');
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-ops'], 'the source delta sends only after the rich retry succeeds');
assert.equal(replies[0].payload.ops[0].id, 'source-b');
settleNext({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-ops','paper-toggle-edit']);

// Classic fallback forms have no per-form hook. The toggle tracks actual input,
// snapshots only dirty forms, and waits for their existing phx-change event.
canvas.flushPendingChanges = () => {};
const fallbackText = window.document.querySelector('.bp-paper-edit-form textarea');
fallbackText.value = 'Final fallback text';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-block-autosave']);
assert.deepEqual(JSON.parse(JSON.stringify(replies[0].payload)), {block_id:'fallback-1', text:'Final fallback text'});
settleNext([{status:'fulfilled', value:{reply:{}}}]);
await tick();
assert.deepEqual(calls, ['paper-block-autosave'], 'fallback forms require explicit save acknowledgement');
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-block-autosave'], 'a form without acknowledgement remains retryable');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.deepEqual(calls, ['paper-block-autosave','paper-toggle-edit']);

// Keep the click lock until the toggle event itself is acknowledged. Otherwise
// a fast second click can enqueue a reverse toggle before the first diff lands.
delayedToggle = true;
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-toggle-edit']);
assert.equal(toggle.el.disabled, true);
click();
assert.deepEqual(calls, ['paper-toggle-edit'], 'double click cannot enqueue a second toggle');
toggleReplies.shift().resolve({});
await tick();
assert.equal(toggle.el.disabled, false);
delayedToggle = false;

fallbackText.value = 'Fallback after disconnect';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
calls.length = 0;
click();
replies.shift().reject(new Error('form disconnected'));
await tick();
assert.deepEqual(calls, ['paper-block-autosave'], 'failed fallback form save keeps Edit open');
assert.equal(toggle.el.disabled, false);
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-block-autosave'], 'the next View retries the failed fallback form');
assert.equal(replies[0].payload.text, 'Fallback after disconnect');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.deepEqual(calls, ['paper-block-autosave','paper-toggle-edit']);

// A batch is never retried past the durable receipt window's conservative
// one-hour client ceiling. It remains queued, keeps Edit mounted, and reports
// a visible recovery message instead of silently freezing or discarding text.
calls.length = 0;
canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles:true,
  detail:{ops:[{op:'patch-block',id:'expired',patch:{content:[]}}], seq:++nextSeq},
}));
assert.deepEqual(calls, ['paper-ops']);
const expiredRequestId = replies[0].payload.request_id;
replies.shift().reject(new Error('disconnected until receipt expires'));
await tick();
now += 60 * 60 * 1000;
calls.length = 0;
click();
await tick();
assert.deepEqual(calls, [], 'an expired batch is not sent again and View remains mounted');
assert.equal(bridge._opsQueue.length, 1, 'the expired local batch is preserved');
assert.equal(bridge._opsQueue[0].requestId, expiredRequestId);
assert.equal(toggle.el.disabled, false);
assert.equal(saveErrors.at(-1).code, 'paper_ops_retry_expired');
assert.match(window.document.querySelector('[data-test-id="bp-paper-footer-save"]').textContent, /one hour/i);

bridge.destroyed();
toggle.destroyed();

// Plain-HTTP readers may expose getRandomValues without randomUUID. Build a
// standards-shaped UUIDv4 from that cryptographic source and save normally.
Object.defineProperty(window, 'crypto', {configurable:true, value:{
  getRandomValues: (bytes) => {
    bytes.forEach((_, index) => { bytes[index] = index; });
    return bytes;
  },
}});
const fallbackUuidWrapper = window.document.createElement('div');
fallbackUuidWrapper.id = 'paper-canvas-fallback-uuid-run-0';
fallbackUuidWrapper.setAttribute('data-canvas-blocks', '[]');
fallbackUuidWrapper.innerHTML = '<bp-paper-canvas></bp-paper-canvas>';
window.document.querySelector('main').append(fallbackUuidWrapper);
const fallbackUuidPushes = [];
const fallbackUuidBridge = {...hooks.BarkparkPaperCanvas, el:fallbackUuidWrapper,
  handleEvent: () => {},
  pushEvent: (name, payload) => {
    if (name !== 'paper-ops') return Promise.resolve({});
    fallbackUuidPushes.push(payload);
    return Promise.resolve({saved:true, request_id:payload.request_id});
  },
};
fallbackUuidBridge.mounted();
fallbackUuidWrapper.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles:true,
  detail:{ops:[{op:'patch-block',id:'fallback-uuid',patch:{content:[]}}], seq:1},
}));
assert.equal(fallbackUuidPushes[0].request_id, '00010203-0405-4607-8809-0a0b0c0d0e0f');
await tick();
assert.equal(fallbackUuidBridge._opsQueue.length, 0);
fallbackUuidBridge.destroyed();

// Secure request identity is mandatory. If the browser cannot mint one, keep
// the batch local, make no ambiguous write, and explain how to preserve it.
Object.defineProperty(window, 'crypto', {configurable:true, value:{}});
const noUuidWrapper = window.document.createElement('div');
noUuidWrapper.id = 'paper-canvas-no-uuid-run-0';
noUuidWrapper.setAttribute('data-canvas-blocks', '[]');
noUuidWrapper.innerHTML = '<bp-paper-canvas></bp-paper-canvas>';
window.document.querySelector('main').append(noUuidWrapper);
const noUuidCalls = [];
const noUuidBridge = {...hooks.BarkparkPaperCanvas, el:noUuidWrapper,
  handleEvent: () => {},
  pushEvent: (name) => { noUuidCalls.push(name); return Promise.resolve({}); },
};
noUuidBridge.mounted();
noUuidCalls.length = 0;
noUuidWrapper.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles:true,
  detail:{ops:[{op:'patch-block',id:'no-uuid',patch:{content:[]}}], seq:1},
}));
assert.deepEqual(noUuidCalls, [], 'a batch without a secure request ID is never sent');
assert.equal(noUuidBridge._opsQueue.length, 1, 'the unsent batch remains recoverable in the mounted editor');
assert.match(window.document.querySelector('[data-test-id="bp-paper-footer-save"]').textContent, /edits are still here/i);
noUuidBridge.destroyed();
dom.window.close();
console.log('PASS reader canvas: late paint, flush-before-view, save reply, refusal, in-flight save, teardown');
