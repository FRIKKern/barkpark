import assert from 'node:assert/strict';
import { blockToTiptap, tiptapToBlock, tiptapInlineToPd } from '../convert.js';
import { JSDOM } from 'jsdom';
const dom = new JSDOM('<!doctype html><body></body>', { pretendToBeVisual: true, url: 'http://localhost/' });
const { window } = dom;
for (const key of ['customElements','CustomEvent','document','DOMParser','Element','Event','EventTarget','HTMLElement','KeyboardEvent','MutationObserver','Node','NodeFilter','Selection','Text']) globalThis[key] = window[key];
globalThis.window = window;
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import('../index.js');
assert.deepEqual(tiptapInlineToPd([{ type: 'hardBreak', marks: [{ type: 'bold' }, { type: 'italic' }] }]),
  [{ type: 'strong', children: [{ type: 'em', children: [{ type: 'text', value: '\n' }] }] }]);
const sources = [
  { id: 'paragraph', type: 'paragraph', content: [{ type: 'text', value: 'Before\nAfter' }] },
  { id: 'heading', type: 'heading', level: 2, text: 'Before\nAfter' },
  { id: 'list', type: 'list', ordered: false, items: [{ text: 'Before\nAfter', audit: 'retain' }] },
];
for (const source of sources) for (const tag of ['bp-paper-canvas', 'bp-paper-editor']) {
  const host = document.createElement(tag);
  const ops = [];
  if (tag === 'bp-paper-canvas') { host.blocks = [source]; host.addEventListener('bp-canvas-ops', e => ops.push(...e.detail.ops)); }
  else { host.block = source; host.addEventListener('bp-op', e => ops.push(e.detail)); }
  document.body.appendChild(host);
  try {
    const ed = host._editor;
    const original = ed.getJSON();
    const expected = tiptapToBlock(blockToTiptap(source), source.id, source.type);
    let pos;
    ed.state.doc.descendants((node, at) => { if (node.isText && node.text === 'Before\nAfter') pos = at; });
    assert.ok(Number.isInteger(pos));
    // The native DOM parser can normalize newline text to a hardBreak.
    ed.view.dispatch(ed.state.tr.replaceWith(pos + 6, pos + 7, ed.schema.nodes.hardBreak.create()));
    assert.deepEqual(tiptapToBlock(ed.getJSON(), source.id, source.type), expected, `${tag}/${source.type}: DOM normalization preserves exact carrier`);
    ed.commands.setTextSelection(pos + 1);
    ed.commands.insertContent('X');
    host.flushPendingChanges();
    assert.ok(ops.length, `${tag}/${source.type}: the edit must be saveable`);
    assert.match(JSON.stringify(ops.at(-1).patch), /BXefore/);
    assert.match(JSON.stringify(ops.at(-1).patch), /\\n/);
    ed.commands.undo();
    host.flushPendingChanges();
    assert.deepEqual(tiptapToBlock(ed.getJSON(), source.id, source.type), expected, `${tag}/${source.type}: Undo preserves exact source`);
    ed.commands.setTextSelection(pos + 2);
    ed.commands.setHardBreak();
    assert.notDeepEqual(ed.getJSON(), original, 'Shift Enter applies');
    assert.equal(host.querySelector('[data-bp-text-boundary]'), null);
    host.flushPendingChanges();
    assert.match(JSON.stringify(ops.at(-1).patch), /\\n/);
  } finally { host.remove(); }
}
window.close();
console.log('inline newline serialization, marks, normalization, saved edits and Undo passed for canvas and fields');
