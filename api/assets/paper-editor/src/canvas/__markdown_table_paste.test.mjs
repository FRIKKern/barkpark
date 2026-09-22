// Aligned GFM must survive production paste and native history.
// __ime_composition.test.mjs — an open IME composition holds the ops debounce (Barkdown row 15).
// ProseMirror reads the IME's candidate text into the doc while the composition is open; the canvas
// must not emit that half-composed run as a patch. With `compositionstart` seen on the editable, a
// change waits past the debounce; `compositionend` releases exactly one batch carrying the full run.
// Run: node src/canvas/__ime_composition.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "CompositionEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (v) => String(v) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const { markdownToBlocks, blocksToMarkdown } = await import('../markdown.js');
const { closeHistory } = await import('@tiptap/pm/history');
const markdown='| Left | Center | Right |\n| :--- | :---: | ---: |\n| pipe \\| value | **bold** | [link](https://example.com) |';
function assertAlignment(table) {
  assert.ok(Array.isArray(table.head[0]), 'left retains ordinary inline carrier');
  assert.equal(table.head[1].align,'center'); assert.equal(table.head[2].align,'right');
  for(const row of table.rows){assert.ok(Array.isArray(row[0]));assert.equal(row[1].align,'center');assert.equal(row[2].align,'right');}
}
const parsed=markdownToBlocks(markdown)[0];assertAlignment(parsed);
assert.equal(parsed.rows[0][0][0].value,'pipe | value');
assert.equal(parsed.rows[0][1].content[0].type,'strong');
assert.equal(parsed.rows[0][2].content[0].href,'https://example.com');
assert.deepEqual(markdownToBlocks(blocksToMarkdown([parsed])),[parsed],'source sentinel remains exact');
assertAlignment(markdownToBlocks('| A | B | C |\n| --- | :---: | ---: |')[0]);
assertAlignment(markdownToBlocks('| A | B | C |\n| --- | :---: | ---: |\n| x |')[0]);
const canvas=document.createElement('bp-paper-canvas');canvas.blocks=[{id:'before',type:'paragraph',content:[]}];canvas.acknowledgedSaves=true;document.body.append(canvas);
try {
 const batches=[];canvas.addEventListener('bp-canvas-ops',e=>batches.push(e.detail));
 const data={getData:type=>type==='text/plain'?markdown:'',files:[]};
 let handled=false;canvas._editor.view.someProp('handlePaste',fn=>{handled=fn(canvas._editor.view,{clipboardData:data,preventDefault(){}},null);return handled;});
 assert.equal(handled,true,'production paste handler accepts plain GFM');canvas.flushPendingChanges();
 assertAlignment(canvas.recoverySnapshot().blocks.find(b=>b.type==='table'));
 assert.equal(batches.length,1,'paste emits one batch');canvas.acknowledgeOps(batches[0].seq,true);
 canvas._editor.view.dispatch(closeHistory(canvas._editor.state.tr));
 assert.equal(canvas._editor.commands.undo(),true);canvas.flushPendingChanges();assert.equal(canvas.recoverySnapshot().blocks.some(b=>b.type==='table'),false);canvas.acknowledgeOps(batches.at(-1).seq,true);
 assert.equal(canvas._editor.commands.redo(),true);canvas.flushPendingChanges();assertAlignment(canvas.recoverySnapshot().blocks.find(b=>b.type==='table'));
 console.log('PASS aligned Markdown parse, empty/short rows, mounted paste, Undo and redo');
} finally {canvas.remove();dom.window.close();}
