// Real mounted canvas: acknowledged external content must land before a host
// advances its revision, including when the human left an idle caret in Paper.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("../index.js");
const { runToTiptap } = await import("./run-convert.js");
const text = value => ({ type: "text", value });
const paragraph = (id, value) => ({ id, type: "paragraph", content: [text(value)] });
const failures = [];
const scenarios = [
  { name: "mark-only update preserves a selected word", blocks: [paragraph("p", "Alpha Beta Gamma")], update: blocks => { blocks[0].content = [{type:"strong",children:[text("Alpha Beta Gamma")]}]; }, selected: "Beta" },
  { name: "link-only update preserves a backwards selected word", blocks: [{id:"p",type:"paragraph",content:[{type:"link",href:"https://example.org/old",children:[text("Alpha Beta Gamma")]}]}], update: blocks => {blocks[0].content[0].href="https://example.org/new";}, selected:"Beta", backwards:true },
  { name: "partial nested marks preserve selected word", blocks: [paragraph("p", "Alpha Beta Gamma")], update: blocks => {blocks[0].content=[text("Alpha "),{type:"strong",children:[{type:"em",children:[text("Beta")]}]},text(" Gamma")];},selected:"Beta", backwards:true },
  { name: "list sibling change preserves selected item", blocks: [{id:"list",type:"list",ordered:false,items:[[text("Alpha")],[text("Beta Gamma")]]}], update: blocks=>{blocks[0].items[0]=[text("An agent expands Alpha")];}, selected:"Beta" },
  { name: "table sibling change preserves selected cell", blocks: [{id:"table",type:"table",head:["Name","Value"],rows:[["Alpha","Beta Gamma"]]}], update: blocks=>{blocks[0].rows[0][0]="An agent expands Alpha";}, selected:"Beta" },
  { name: "multiline change preserves unaffected paragraph selection", blocks:[paragraph("p","Alpha"),paragraph("q","Beta Gamma")], update:blocks=>{blocks[0].content=[text("First line"),{type:"br"},text("Second line")];},selected:"Beta" },
];
for (const scenario of scenarios) {
 const canvas=document.createElement("bp-paper-canvas");canvas.acknowledgedSaves=true;canvas.blocks=structuredClone(scenario.blocks);document.body.append(canvas);
 try {
  const editor=canvas._editor;let found;
  editor.state.doc.descendants((node,pos)=>{if(node.isText&&node.text.includes(scenario.selected))found=pos+node.text.indexOf(scenario.selected);});
  assert.notEqual(found,undefined,"fixture selection exists");
  editor.commands.setTextSelection({from:scenario.backwards?found+scenario.selected.length:found,to:scenario.backwards?found:found+scenario.selected.length});
  const before=editor.state.selection;const backwards=before.anchor>before.head;
  const next=structuredClone(scenario.blocks);scenario.update(next);
  const batches=[];canvas.addEventListener("bp-canvas-ops",event=>batches.push(event.detail));
  assert.equal(canvas.applyServerBlocksIfIdle(next),true);
  assert.ok(editor.state.doc.eq(editor.state.schema.nodeFromJSON(runToTiptap(next))), "complete rich server content applied exactly");
  const after=editor.state.selection;
  assert.equal(editor.state.doc.textBetween(after.from,after.to),scenario.selected,"selected content remains selected");
  assert.equal(after.anchor>after.head,backwards,"selection direction survives");
  assert.equal(batches.length,0,"external content does not emit saves");
  editor.view.dispatch(editor.state.tr.insertText("Human"));
  assert.match(editor.state.doc.textContent,/Human Gamma/,"typing replaces precisely the selected word");
  canvas.flushPendingChanges();assert.equal(batches.length,1,"one actual human batch emitted");
  canvas.acknowledgeOps(batches[0].seq,true);
  assert.equal(canvas.hasPendingChanges(),false,"acknowledged human draft clean");
  assert.equal(editor.commands.undo(),true,"human typing has native undo");
  assert.ok(editor.state.doc.eq(editor.state.schema.nodeFromJSON(runToTiptap(next))),"undo restores selection text without undoing the external edit");
  console.log("PASS "+scenario.name);
 } catch(error){failures.push(scenario.name+": "+error.message);console.error("FAIL "+failures.at(-1));}
 finally{canvas.remove();}
}
window.close();assert.deepEqual(failures,[]);
