// HTML table paste must preserve cell boundaries, inline formatting and native history.
// Run: node src/canvas/__html_table_paste.test.mjs
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



const { closeHistory } = await import('@tiptap/pm/history');
function paste(canvas,html,text='Plain table text') {
 const event=new Event('paste',{bubbles:true,cancelable:true});
 Object.defineProperty(event,'clipboardData',{value:{types:['text/html','text/plain'],getData:type=>type==='text/html'?html:type==='text/plain'?text:'',files:[]}});
 assert.equal(canvas._editor.view.dom.dispatchEvent(event),false,'mounted clipboard event is handled');
}
function mount(blocks=[{id:'before',type:'paragraph',content:[]}]) {
 const canvas=document.createElement('bp-paper-canvas');canvas.blocks=blocks;canvas.acknowledgedSaves=true;document.body.append(canvas);
 const batches=[];canvas.addEventListener('bp-canvas-ops',e=>batches.push(e.detail));return {canvas,batches};
}
function text(cell){return (Array.isArray(cell)?cell:cell.content).map(n=>n.value??text(n.children||[])).join('');}
let passed=0;
function test(name,run){const {canvas,batches}=mount();try{run(canvas,batches);console.log('PASS '+name);passed++;}finally{canvas.remove();}}
try {
 test('headerless HTML multiline cell',(c)=>{
  paste(c,'<table><tr><td>First<br>Second</td></tr></table>');
  const table=c.recoverySnapshot().blocks[0];assert.equal(table.type,'table');assert.equal(table.head,undefined);assert.equal(text(table.rows[0][0]),'First\nSecond');
 });
 test('paragraph boundaries and empty lines stay inside cells with marks/links',(c)=>{
  paste(c,'<p>Before</p><table><tr><th>Heading</th></tr><tr><td><p>First paragraph</p><p><br></p><p>Second <strong>bold</strong> <a href="https://example.com">link</a></p></td></tr></table><p>After</p>');
  const blocks=c.recoverySnapshot().blocks;assert.equal(blocks.length,3);assert.equal(text(blocks[0].content),'Before');assert.equal(text(blocks[2].content),'After');
  const cell=blocks[1].rows[0][0];assert.equal(text(cell),'First paragraph\n\nSecond bold link');assert.ok(cell.some(n=>n.type==='strong'));assert.ok(cell.some(n=>n.type==='link'&&n.href==='https://example.com'));
 });
 test('HTML alignment and row headers survive without source identities',(c)=>{
  paste(c,'<table data-bp-id="foreign" data-head-col="false"><tr><th style="text-align:center">Center</th><th align="right">Right</th></tr><tr><th scope="row" style="text-align:center" data-bp-id="injected">one</th><td align="right">two</td></tr></table>');
  const t=c.recoverySnapshot().blocks[0];assert.notEqual(t.id,'foreign');assert.equal(t.headCol,true);assert.equal(t.head[0].align,'center');assert.equal(t.head[1].align,'right');assert.equal(t.rows[0][0].align,'center');assert.equal(t.rows[0][1].align,'right');assert.ok(!JSON.stringify(t).includes('injected'));
 });
 test('existing body span schema retains cells and rectangular placeholders',(c)=>{
  paste(c,'<table><tr><td rowspan="2">Origin</td><td>Top</td></tr><tr><td>Bottom</td></tr></table>');
  const t=c.recoverySnapshot().blocks[0];assert.deepEqual(t.spans,[{row:0,col:0,colspan:1,rowspan:2}]);assert.equal(t.rows.length,2);assert.deepEqual(t.rows[1][0],[]);assert.equal(text(t.rows[1][1]),'Bottom');
 });
 test('ragged ordinary rows retain every source cell with empty padding',(c)=>{
  paste(c,'<table><tr><th>A</th></tr><tr><td>B</td><td>Extra</td></tr><tr><td>C</td></tr></table>');const t=c.recoverySnapshot().blocks[0];assert.deepEqual(t.head.map(text),['A','']);assert.deepEqual(t.rows.map(row=>row.map(text)),[['B','Extra'],['C','']]);
 });
 test('selection replacement keeps surrounding text and undo restores the selection',(c)=>{
  c._editor.commands.insertContent('Before selected After');c._editor.view.dispatch(closeHistory(c._editor.state.tr));c._editor.commands.setTextSelection({from:8,to:16});
  paste(c,'<table><tr><td>Replacement</td></tr></table>');const blocks=c.recoverySnapshot().blocks;assert.deepEqual(blocks.map(b=>b.type),['paragraph','table','paragraph']);assert.equal(text(blocks[0].content),'Before ');assert.equal(text(blocks[2].content),' After');
  assert.equal(c._editor.commands.undo(),true);assert.equal(c._editor.state.doc.textContent,'Before selected After');assert.equal(c._editor.state.selection.from,8);assert.equal(c._editor.state.selection.to,16);
 });
 test('acknowledged paste Undo and redo preserve exact cells',(c,batches)=>{
  paste(c,'<table><tr><td style="text-align:right"><p>First</p><p>Second</p></td></tr></table>');c.flushPendingChanges();assert.equal(batches.length,1);const expected=c.recoverySnapshot().blocks;c.acknowledgeOps(batches[0].seq,true);c._editor.view.dispatch(closeHistory(c._editor.state.tr));
  assert.equal(c._editor.commands.undo(),true);c.flushPendingChanges();assert.equal(c.recoverySnapshot().blocks.some(b=>b.type==='table'),false);c.acknowledgeOps(batches.at(-1).seq,true);
  assert.equal(c._editor.commands.redo(),true);c.flushPendingChanges();assert.deepEqual(c.recoverySnapshot().blocks,expected);
 });
 for(const html of ['<table><tr><td rowspan="0">All rows</td><td>A</td></tr><tr><td>B</td></tr></table>','<table><tr><td rowspan="2">Origin</td><td>Top</td></tr><tr><td>B</td><td>Overflow must survive</td></tr></table>','<table><tr><td>A</td><td rowspan="2">Origin</td></tr><tr><td colspan="2">Overlap</td></tr></table>','<table><tr><td><ul><li>Nested list</li></ul></td></tr></table>','<table><tr><td><table><tr><td>Nested</td></tr></table></td></tr></table>','<table><tr><th colspan="2">Merged header</th></tr><tr><td>A</td><td>B</td></tr></table>']) {
  test('unsupported structure keeps draft/clipboard and explains plain-text fallback',(c,batches)=>{
   c._editor.commands.insertContent('Retain me');c.flushPendingChanges();c.acknowledgeOps(batches.at(-1).seq,true);const before=c.recoverySnapshot().blocks;
   paste(c,html,'Nested text retained');assert.deepEqual(c.recoverySnapshot().blocks,before);assert.match(c.querySelector('[role="status"]').textContent,/Nothing was pasted.*Ctrl\+Shift\+V/);const count=batches.length;c.flushPendingChanges();assert.equal(batches.length,count);
   c._editor.view.input.shiftKey=true;paste(c,html,'Nested text retained');c._editor.view.input.shiftKey=false;assert.ok(c._editor.state.doc.textContent.includes('Nested text retained'),'explicit plain-text fallback works');
  });
 }
 test('paste recovery notice dismisses without changing the draft',(c)=>{
  const before=c.recoverySnapshot().blocks;const html='<table><tr><td><ul><li>Nested</li></ul></td></tr></table>';
  paste(c,html);assert.ok(c.querySelector('[data-bp-paste-notice]'));document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert.equal(c.querySelector('[data-bp-paste-notice]'),null);assert.equal(c._pasteNoticeDismiss,null);assert.deepEqual(c.recoverySnapshot().blocks,before);
  paste(c,html);c.remove();assert.equal(c._pasteNoticeDismiss,null,'disconnect releases document listeners');
 });
 console.log(`${passed} HTML table paste cases passed`);
} finally {dom.window.close();}
