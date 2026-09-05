import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<main><button id="toggle" data-editing="true">View</button><div id="paper-canvas-probe-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]" data-canvas-dataset="production" data-canvas-token="writer" data-canvas-scope-prefix="/w/acme/p/books" data-canvas-picker-browse="false"><bp-paper-canvas></bp-paper-canvas></div><form class="bp-paper-edit-form" phx-change="paper-block-autosave"><input name="block_id" value="fallback-1"><textarea name="text">Before</textarea></form></main>');
const { window } = dom;
let upgrade;
const context = vm.createContext({window, document: window.document, CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  customElements: { whenDefined: () => new Promise(resolve => { upgrade = resolve; }) }});
vm.runInContext(readFileSync(new URL('../../../priv/static/assets/bp-paper-editor-hooks.js', import.meta.url), 'utf8'), context);
const hooks = window.BarkparkPaperEditorHooks;
const wrapper = window.document.querySelector('[phx-hook]');
const canvas = wrapper.querySelector('bp-paper-canvas');
const handlers = new Map();
const calls = [];
const replies = [];
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
const flush = () => { if (!dirty) return; dirty = false; canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles: true, detail: {ops:[{op:'patch-block',id:'body',patch:{content:[]}}]},
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
replies.shift().resolve({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-toggle-edit']);
assert.equal(toggle.el.disabled, false);

calls.length = 0;
dirty = true;
click();
replies.shift().resolve({saved:false});
await tick();
assert.deepEqual(calls, ['paper-ops'], 'a refused save must keep the editor mounted');
assert.equal(toggle.el.disabled, false);
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-ops'], 'the next View retries a saved:false canvas batch');
replies.shift().resolve({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-toggle-edit']);

// A save already in flight must finish even when the immediate flush is clean.
canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {bubbles:true,detail:{ops:[]}}));
canvas.flushPendingChanges = () => {};
calls.length = 0;
click();
assert.deepEqual(calls, []);
replies.shift().resolve({saved:true});
await tick();
assert.deepEqual(calls, ['paper-toggle-edit']);

// Typing while a previous save is pending is included in the same transition.
canvas.flushPendingChanges = flush;
dirty = true;
calls.length = 0;
click();
dirty = true;
replies.shift().resolve({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-ops']);
assert.equal(toggle.el.disabled, true);
replies.shift().resolve({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-ops','paper-toggle-edit']);

// A transport failure must settle the barrier as false. View remains editing,
// and the button is usable again instead of hanging forever in aria-busy state.
dirty = true;
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-ops']);
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
replies.shift().resolve({saved:true});
await tick();
assert.deepEqual(calls, ['paper-ops','paper-ops'], 'the source delta sends only after the rich retry succeeds');
assert.equal(replies[0].payload.ops[0].id, 'source-b');
replies.shift().resolve({saved:true});
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
replies.shift().resolve([{status:'fulfilled', value:{reply:{saved:true}}}]);
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
replies.shift().resolve([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.deepEqual(calls, ['paper-block-autosave','paper-toggle-edit']);

bridge.destroyed();
toggle.destroyed();
dom.window.close();
console.log('PASS reader canvas: late paint, flush-before-view, save reply, refusal, in-flight save, teardown');
