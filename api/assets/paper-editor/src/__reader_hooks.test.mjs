import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<main data-paper-doc-key="production:paper:probe" data-paper-rev="7"><button id="toggle" data-editing="true">View</button><div id="paper-canvas-probe-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]" data-canvas-dataset="production" data-canvas-token="writer" data-canvas-scope-prefix="/w/acme/p/books" data-canvas-picker-browse="false"><bp-paper-canvas></bp-paper-canvas></div><form class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="0"><input name="block_id" value="fallback-1"><textarea name="text">Before</textarea></form><footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer></main>');
const { window } = dom;
let nextRequestId = 0;
Object.defineProperty(window, 'crypto', {configurable:true, value:{
  randomUUID: () => `00000000-0000-4000-8000-${String(++nextRequestId).padStart(12, '0')}`,
}});
let now = 1_000;
class TestDate extends Date { static now() { return now; } }
let upgrade;
const context = vm.createContext({window, document: window.document, CustomEvent: window.CustomEvent,
  FormData: window.FormData, Date: TestDate, setTimeout, clearTimeout,
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
  if (Array.isArray(reply) && pending.payload?.request_id) {
    reply = reply.map((result) => result?.value?.reply ? {
      ...result,
      value: { ...result.value, reply: {
        ...result.value.reply,
        request_id: requestId === undefined ? pending.payload.request_id : requestId,
        ...(pending.payload.if_rev != null && result.value.reply.saved === true &&
          result.value.reply.rev == null
          ? {rev: Number(pending.payload.if_rev) + 1}
          : {}),
      } },
    } : result);
  }
  if (
    pending.payload?.request_id && !Array.isArray(reply) && reply != null &&
    typeof reply === 'object'
  ) {
    reply = {
      ...reply,
      request_id: requestId === undefined ? pending.payload.request_id : requestId,
      ...(pending.payload.if_rev != null && reply.saved === true && reply.rev == null
        ? {rev: Number(pending.payload.if_rev) + 1}
        : {}),
    };
  }
  pending.resolve(reply);
  return pending;
};
const bridge = { ...hooks.BarkparkPaperCanvas, el: wrapper,
  handleEvent: (name, handler) => handlers.set(name, handler),
  pushEvent: (name, payload) => {
    calls.push(name);
    if (name !== 'paper-ops' && name !== 'paper-edit-block') return Promise.resolve({});
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

// Drag/drop and the keyboard-equivalent context menu use the same barrier as
// toolbar structural actions, so unsaved text lands before move/delete.
const structuralEditor = window.document.createElement('div');
structuralEditor.className = 'bp-paper-editor';
structuralEditor.innerHTML = '<div data-edit-block-id="a"><span data-drag-grip draggable="true">A</span></div><div data-edit-block-id="b"><span data-drag-grip draggable="true">B</span></div><div id="ctx-host"></div>';
window.document.querySelector('main').append(structuralEditor);
const structuralCalls = [];
const sortable = {...hooks.BarkparkPaperSortable, el:structuralEditor,
  pushEvent: (name, payload) => { structuralCalls.push({name, payload}); return Promise.resolve({saved:true,request_id:payload.request_id,rev:payload.if_rev + 1}); },
};
sortable.mounted();
const contextMenu = {...hooks.BarkparkPaperContextMenu, el:structuralEditor.querySelector('#ctx-host'),
  pushEvent: (name, payload) => { structuralCalls.push({name, payload}); return Promise.resolve({saved:true,request_id:payload.request_id,rev:payload.if_rev + 1}); },
};
contextMenu.mounted();

calls.length = 0;
canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles:true,
  detail:{ops:[{op:'patch-block',id:'before-drop',patch:{content:[]}}], seq:++nextSeq},
}));
const grip = structuralEditor.querySelector('[data-drag-grip]');
const dragStart = new window.Event('dragstart', {bubbles:true,cancelable:true});
Object.defineProperty(dragStart, 'dataTransfer', {value:{setData:()=>{}, effectAllowed:''}});
grip.dispatchEvent(dragStart);
const drop = new window.MouseEvent('drop', {bubbles:true,cancelable:true,clientY:0});
Object.defineProperty(drop, 'dataTransfer', {value:{dropEffect:''}});
structuralEditor.dispatchEvent(drop);
assert.deepEqual(structuralCalls, [], 'drop does not move before the content acknowledgement');
settleNext({saved:true});
await tick();
assert.equal(structuralCalls[0].name, 'paper-move-block-to');

structuralCalls.length = 0;
canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
  bubbles:true,
  detail:{ops:[{op:'patch-block',id:'before-context-delete',patch:{content:[]}}], seq:++nextSeq},
}));
const blockA = structuralEditor.querySelector('[data-edit-block-id="a"]');
blockA.dispatchEvent(new window.MouseEvent('contextmenu', {
  bubbles:true,cancelable:true,clientX:10,clientY:10,
}));
window.document.querySelector('#bp-paper-context-menu [data-action="delete"]').click();
assert.deepEqual(structuralCalls, [], 'context delete waits behind unsaved content');
settleNext({saved:true});
await tick();
assert.equal(structuralCalls[0].name, 'paper-delete-block');
contextMenu.destroyed();
sortable.destroyed();
structuralEditor.remove();

// Typed reference/bar Add and Remove submits are structural mutations too.
// They must wait for pending content, preserve the clicked submitter, and use
// the revision acknowledged by that content save exactly once.
for (const [actionName, actionValue, contentRev, actionRev] of [
  ['ref-action', 'add', 40, 41],
  ['bar-action', 'remove', 42, 43],
]) {
  const form = window.document.createElement('form');
  form.setAttribute('phx-submit', 'paper-edit-block');
  form.innerHTML = `<input name="block_id" value="typed-1"><button type="submit" name="${actionName}" value="${actionValue}">Change</button>`;
  window.document.querySelector('main').append(form);
  calls.length = 0;
  canvas.dispatchEvent(new window.CustomEvent('bp-canvas-ops', {
    bubbles:true,
    detail:{ops:[{op:'patch-block',id:`before-${actionName}`,patch:{content:[]}}], seq:++nextSeq},
  }));
  form.querySelector('button').click();
  assert.deepEqual(calls, ['paper-ops'], `${actionName} must wait for pending content`);

  settleNext({saved:true, rev:contentRev});
  await tick();
  assert.deepEqual(calls, ['paper-ops', 'paper-edit-block']);
  assert.equal(replies[0].payload[actionName], actionValue);
  assert.equal(replies[0].payload.if_rev, contentRev);
  assert.equal(calls.filter((name) => name === 'paper-edit-block').length, 1);

  settleNext({saved:true, rev:actionRev});
  await tick();
  form.remove();
}

// Classic fallback forms have no per-form hook. The toggle tracks actual input,
// snapshots only dirty forms, and waits for their existing phx-change event.
canvas.flushPendingChanges = () => {};
const fallbackText = window.document.querySelector('.bp-paper-edit-form textarea');
let nativeFallbackChanges = 0;
window.addEventListener('input', () => { nativeFallbackChanges += 1; });
fallbackText.value = 'Final fallback text';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
assert.equal(nativeFallbackChanges, 0,
  'owned fallback input does not also reach LiveView\'s window-level phx-change binding');
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-block-autosave']);
assert.deepEqual(JSON.parse(JSON.stringify({
  block_id: replies[0].payload.block_id,
  text: replies[0].payload.text,
})), {block_id:'fallback-1', text:'Final fallback text'});
settleNext([{status:'fulfilled', value:{reply:{}}}]);
await tick();
assert.deepEqual(calls, ['paper-block-autosave'], 'fallback forms require explicit save acknowledgement');
calls.length = 0;
click();
assert.deepEqual(calls, ['paper-block-autosave'], 'a form without acknowledgement remains retryable');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.deepEqual(calls, ['paper-block-autosave','paper-toggle-edit']);

// The coordinator owns the legacy debounce. Its actual acknowledged autosave
// clears dirty state, so a later exit does not send a duplicate block revision.
calls.length = 0;
fallbackText.value = 'Naturally autosaved fallback';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
assert.deepEqual(calls, ['paper-block-autosave']);
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
calls.length = 0;
click();
await tick();
assert.deepEqual(calls, ['paper-toggle-edit'],
  'an acknowledged fallback autosave is not duplicated at exit');

// Native validation must keep invalid authoring input local and block exit.
const numericForm = window.document.createElement('form');
numericForm.className = 'bp-paper-edit-form';
numericForm.setAttribute('phx-change', 'paper-block-autosave');
numericForm.setAttribute('phx-debounce', '0');
numericForm.innerHTML = '<input name="block_id" value="number-1"><input type="number" name="value" min="2" value="3">';
window.document.querySelector('main').append(numericForm);
let validityReports = 0;
numericForm.reportValidity = () => { validityReports += 1; return numericForm.checkValidity(); };
const numericInput = numericForm.querySelector('[name=value]');
numericInput.value = '1';
calls.length = 0;
numericInput.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
click();
await tick();
assert.deepEqual(calls, [], 'invalid numeric input must neither save nor exit');
assert.ok(validityReports > 0, 'invalid input receives visible validity feedback');
numericInput.value = '4';
numericInput.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
assert.deepEqual(calls, ['paper-block-autosave']);
assert.equal(replies[0].payload.value, '4');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
numericForm.remove();

// Numeric configuration has an authored range, not stale stored min/max attrs.
const rangeForm = window.document.createElement('form');
rangeForm.className = 'bp-paper-edit-form';
rangeForm.setAttribute('phx-change', 'paper-edit-block');
rangeForm.setAttribute('phx-debounce', '0');
rangeForm.setAttribute('data-test-id', 'paper-field-number-editor');
rangeForm.innerHTML = '<input name="block_id" value="range-1"><input type="number" name="value" value="12"><input type="number" name="min" value="1"><input type="number" name="max" value="9"><input type="number" name="step" value="1">';
window.document.querySelector('main').append(rangeForm);
const rangeValue = rangeForm.querySelector('[name=value]');
calls.length = 0;
rangeValue.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
click();
await tick();
assert.deepEqual(calls, [], 'out-of-range draft never reaches server repaint or exits');
assert.equal(rangeValue.value, '12', 'invalid authored value remains available to correct');
assert.equal(rangeForm.querySelector('[name=max]').value, '9');
assert.match(rangeValue.validationMessage, /at most 9/);
rangeForm.querySelector('[name=max]').value = '15';
rangeForm.querySelector('[name=max]').dispatchEvent(new window.Event('input', {bubbles:true}));
assert.equal(rangeValue.validationMessage, '', 'correcting the range clears custom validity before native submit validation');
await tick();
assert.deepEqual(calls, ['paper-edit-block'], 'coherent newly authored range can save');
assert.equal(replies[0].payload.value, '12');
assert.equal(replies[0].payload.max, '15');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
rangeForm.remove();

// Text-backed TOC and criteria numerics validate before a fallback save. An
// invalid draft stays in the DOM through debounce and an immediate View click.
const tocForm = window.document.createElement('form');
tocForm.className = 'bp-paper-edit-form';
tocForm.setAttribute('phx-change', 'paper-block-autosave');
tocForm.setAttribute('phx-debounce', '0');
tocForm.setAttribute('data-test-id', 'paper-toc-editor');
tocForm.innerHTML = '<input name="block_id" value="toc-1"><input name="depth" value="2"><input name="toc-0-level" value="3">';
window.document.querySelector('main').append(tocForm);
const tocLevel = tocForm.querySelector('[name="toc-0-level"]');
const footerSaveStatus = window.document.querySelector('[data-test-id="bp-paper-footer-save"]');
footerSaveStatus.textContent = '✓ Auto-saved';
tocLevel.value = 'not-a-number';
calls.length = 0;
tocLevel.dispatchEvent(new window.Event('input', {bubbles:true}));
click();
await tick();
assert.deepEqual(calls, [], 'invalid TOC level is blocked before debounced autosave');
assert.doesNotMatch(footerSaveStatus.textContent, /Auto-saved/,
  'a newly invalid local draft cannot leave the previous saved claim visible');
assert.match(footerSaveStatus.textContent, /unsaved/i);
assert.equal(tocLevel.value, 'not-a-number', 'invalid TOC draft remains available to correct');
assert.deepEqual(calls, [], 'immediate View cannot send or discard an invalid TOC draft');
assert.equal(tocLevel.value, 'not-a-number');
assert.match(tocLevel.validationMessage, /positive whole number/);
tocLevel.value = '4';
tocLevel.dispatchEvent(new window.Event('input', {bubbles:true}));
assert.equal(tocLevel.validationMessage, '', 'correcting a TOC number clears custom validity immediately');
assert.match(footerSaveStatus.textContent, /saving/i,
  'a corrected valid draft reports its pending save truthfully');
await tick();
assert.deepEqual(calls, ['paper-block-autosave']);
assert.equal(replies[0].payload['toc-0-level'], '4');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.match(footerSaveStatus.textContent, /Auto-saved/,
  'the matching acknowledgement restores the saved status');

// A successful older receipt can repaint the server's saved label while a
// newer local draft exists. Derive the footer from all coordinator state after
// the receipt instead of trusting that paint.
calls.length = 0;
tocLevel.value = '5';
tocLevel.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
assert.deepEqual(calls, ['paper-block-autosave']);
tocLevel.value = 'not-a-number';
tocLevel.dispatchEvent(new window.Event('input', {bubbles:true}));
footerSaveStatus.textContent = '✓ Auto-saved';
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.match(footerSaveStatus.textContent, /unsaved/i,
  'an older success repaint cannot mask a newer invalid draft');
assert.doesNotMatch(footerSaveStatus.textContent, /Auto-saved/);
tocLevel.value = '6';
tocLevel.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
assert.deepEqual(calls, ['paper-block-autosave', 'paper-block-autosave']);
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.match(footerSaveStatus.textContent, /Auto-saved/);

// A receipt for one fallback form is not a global saved claim while another
// form remains queued behind it.
const secondTocForm = tocForm.cloneNode(true);
secondTocForm.querySelector('[name="block_id"]').value = 'toc-2';
window.document.querySelector('main').append(secondTocForm);
const secondTocLevel = secondTocForm.querySelector('[name="toc-0-level"]');
calls.length = 0;
tocLevel.value = '7';
tocLevel.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
secondTocLevel.value = '8';
secondTocLevel.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
assert.deepEqual(calls, ['paper-block-autosave'], 'the second form queues behind the active save');
footerSaveStatus.textContent = '✓ Auto-saved';
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
await tick(); // deferred form starts its debounce only after the prior acknowledgement
assert.deepEqual(calls, ['paper-block-autosave', 'paper-block-autosave']);
assert.match(footerSaveStatus.textContent, /saving/i,
  'the first receipt cannot claim all forms are saved while a second save is active');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.match(footerSaveStatus.textContent, /Auto-saved/);
secondTocForm.remove();
tocForm.remove();

const criteriaForm = window.document.createElement('form');
criteriaForm.className = 'bp-paper-edit-form';
criteriaForm.setAttribute('phx-change', 'paper-block-autosave');
criteriaForm.setAttribute('phx-debounce', '0');
criteriaForm.setAttribute('data-test-id', 'paper-criteria-progress-editor');
criteriaForm.innerHTML = '<input name="block_id" value="criteria-1"><input name="criterion-0-met" value="3"><input name="criterion-0-total" value="5">';
window.document.querySelector('main').append(criteriaForm);
const criteriaMet = criteriaForm.querySelector('[name="criterion-0-met"]');
criteriaMet.value = 'not-a-number';
calls.length = 0;
criteriaMet.dispatchEvent(new window.Event('input', {bubbles:true}));
criteriaMet.dispatchEvent(new window.Event('change', {bubbles:true}));
await tick();
assert.deepEqual(calls, [], 'invalid criteria value is blocked before debounced autosave');
assert.equal(criteriaMet.value, 'not-a-number', 'invalid criteria draft is not repainted away');
criteriaMet.value = '.5';
criteriaMet.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
assert.deepEqual(calls, [], 'client decimal grammar rejects values the server parser rejects');
criteriaMet.value = '2.5';
criteriaMet.dispatchEvent(new window.Event('input', {bubbles:true}));
assert.equal(criteriaMet.validationMessage, '', 'correcting a criteria number clears custom validity immediately');
await tick();
assert.deepEqual(calls, ['paper-block-autosave']);
assert.equal(replies[0].payload['criterion-0-met'], '2.5');
assert.equal(replies[0].payload['criterion-0-total'], '5');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
criteriaForm.remove();

// The server preserves unchanged legacy numeric shapes. Inputs expose their
// original wire representation through defaultValue, so those no-op values
// must pass even when they are not valid new numbers.
const legacyTocForm = window.document.createElement('form');
legacyTocForm.className = 'bp-paper-edit-form';
legacyTocForm.setAttribute('phx-change', 'paper-block-autosave');
legacyTocForm.setAttribute('phx-debounce', '0');
legacyTocForm.setAttribute('data-test-id', 'paper-toc-editor');
legacyTocForm.innerHTML = '<input name="block_id" value="legacy-toc"><input name="depth" value=""><input name="toc-0-level" value="2x">';
window.document.querySelector('main').append(legacyTocForm);
calls.length = 0;
legacyTocForm.querySelector('[name="toc-0-level"]').dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
assert.deepEqual(calls, ['paper-block-autosave'], 'unchanged malformed and blank legacy numerics pass through');
assert.equal(replies[0].payload.depth, '');
assert.equal(replies[0].payload['toc-0-level'], '2x');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
legacyTocForm.remove();

// Typing during a form save must create a later snapshot, not disappear when
// the earlier acknowledgement arrives or when View is clicked immediately.
calls.length = 0;
fallbackText.value = 'First in-flight value';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
const earlierFormRevision = replies[0].payload.if_rev;
fallbackText.value = 'Newest in-flight value';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
click();
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
await tick();
assert.deepEqual(calls, ['paper-block-autosave', 'paper-block-autosave'],
  'View waits for the later form snapshot too');
assert.equal(replies[0].payload.text, 'Newest in-flight value');
assert.equal(replies[0].payload.if_rev, Number(earlierFormRevision) + 1);
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.deepEqual(calls, ['paper-block-autosave', 'paper-block-autosave', 'paper-toggle-edit']);

calls.length = 0;
fallbackText.value = 'Retry original snapshot';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
await tick();
const originalFormWire = JSON.parse(JSON.stringify(replies[0].payload));
fallbackText.value = 'Retained while retrying';
fallbackText.dispatchEvent(new window.Event('input', {bubbles:true}));
settleNext([{status:'fulfilled', value:{reply:{saved:false}}}]);
await tick();
await tick();
assert.equal(replies.length, 0, 'a refused older snapshot is not retried automatically');
click();
await tick();
assert.deepEqual(JSON.parse(JSON.stringify(replies[0].payload)), originalFormWire,
  'retry preserves the original request identity, revision and content');
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
await tick();
assert.equal(replies[0].payload.text, 'Retained while retrying');
assert.notEqual(replies[0].payload.request_id, originalFormWire.request_id);
assert.equal(replies[0].payload.if_rev, Number(originalFormWire.if_rev) + 1);
settleNext([{status:'fulfilled', value:{reply:{saved:true}}}]);
await tick();
assert.equal(calls.at(-1), 'paper-toggle-edit');

// Keep the click lock until the toggle event itself is acknowledged. Otherwise
// a fast second click can enqueue a reverse toggle before the first diff lands.
delayedToggle = true;
calls.length = 0;
click();
await Promise.resolve();
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
footerSaveStatus.textContent = 'Save failed';
replies.shift().reject(new Error('form disconnected'));
await tick();
assert.deepEqual(calls, ['paper-block-autosave'], 'failed fallback form save keeps Edit open');
assert.equal(footerSaveStatus.textContent, 'Save failed',
  'a generic failed receipt preserves the authoritative server failure');
assert.equal(toggle.el.disabled, false);
calls.length = 0;
footerSaveStatus.textContent = 'Read-only';
click();
assert.deepEqual(calls, ['paper-block-autosave'], 'the next View retries the failed fallback form');
assert.equal(footerSaveStatus.textContent, 'Read-only',
  'a retry attempt cannot replace an authoritative read-only status');
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
const expiryWarning = footerSaveStatus.textContent;
const terminalWarningForm = window.document.createElement('form');
terminalWarningForm.className = 'bp-paper-edit-form';
terminalWarningForm.setAttribute('phx-change', 'paper-block-autosave');
terminalWarningForm.setAttribute('phx-debounce', '0');
terminalWarningForm.innerHTML = '<input name="block_id" value="terminal-warning"><input name="text" value="before">';
window.document.querySelector('main').append(terminalWarningForm);
terminalWarningForm.querySelector('[name="text"]').value = 'after';
terminalWarningForm.querySelector('[name="text"]').dispatchEvent(
  new window.Event('input', {bubbles:true}));
assert.equal(footerSaveStatus.textContent, expiryWarning,
  'fallback input cannot replace the terminal copy-before-reload warning');

bridge.destroyed();
toggle.destroyed();

// Conflict/paused state outranks a newly valid fallback input. Isolate it from
// the terminal warning above so each status ownership rule is proven directly.
footerSaveStatus.textContent = '';
const conflictWrapper = window.document.createElement('div');
conflictWrapper.setAttribute('phx-hook', 'BarkparkPaperCanvas');
conflictWrapper.innerHTML = '<bp-paper-canvas></bp-paper-canvas>';
window.document.querySelector('main').append(conflictWrapper);
const conflictBridge = {...hooks.BarkparkPaperCanvas, el:conflictWrapper,
  handleEvent: () => {}, pushEvent: () => Promise.resolve({})};
conflictBridge.mounted();
const conflictedForm = window.document.createElement('form');
conflictedForm.className = 'bp-paper-edit-form';
conflictedForm.setAttribute('phx-change', 'paper-block-autosave');
conflictedForm.setAttribute('phx-debounce', '0');
conflictedForm.innerHTML = '<input name="block_id" value="conflicted"><input name="text" value="before">';
window.document.querySelector('main').append(conflictedForm);
conflictBridge._bpPaperExitCoordinator._setConflict(
  {conflict:true, current_rev:99}, conflictedForm, 'production:paper:probe');
const conflictedInput = conflictedForm.querySelector('[name="text"]');
conflictedInput.value = 'after';
conflictedInput.dispatchEvent(new window.Event('input', {bubbles:true}));
assert.match(footerSaveStatus.textContent, /paused/i,
  'valid input during conflict preserves the paused status');
assert.doesNotMatch(footerSaveStatus.textContent, /saving/i);
conflictBridge.destroyed();
conflictWrapper.remove();
conflictedForm.remove();

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
    return Promise.resolve({saved:true, request_id:payload.request_id, rev:payload.if_rev + 1});
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
const unretryableWarning = footerSaveStatus.textContent;
const unretryableForm = window.document.createElement('form');
unretryableForm.className = 'bp-paper-edit-form';
unretryableForm.setAttribute('phx-change', 'paper-block-autosave');
unretryableForm.setAttribute('phx-debounce', '0');
unretryableForm.innerHTML = '<input name="block_id" value="unretryable"><input name="text" value="before">';
window.document.querySelector('main').append(unretryableForm);
unretryableForm.querySelector('[name="text"]').value = 'after';
unretryableForm.querySelector('[name="text"]').dispatchEvent(
  new window.Event('input', {bubbles:true}));
assert.equal(footerSaveStatus.textContent, unretryableWarning,
  'fallback input cannot replace an unretryable-operations warning');
noUuidBridge.destroyed();
dom.window.close();
console.log('PASS reader canvas: late paint, flush-before-view, save reply, refusal, in-flight save, teardown');
