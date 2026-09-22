// Unsupported rich clipboard content must not delete the selected human text.
// Run: node src/canvas/__rich_clipboard_preservation.test.mjs
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



let passed=0;
const seed=[{id:"seed",type:"paragraph",content:[{type:"text",value:"Before selected After"}]}];
const table='<table><tr><td>Table text</td></tr></table>';
const image='<img src="https://example.test/diagram.png" alt="Important diagram">';
function paste(c,{html='',text='',files=[],plain=false,insert=false}={}) {
 const event=new Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(event,'clipboardData',{value:{types:['text/html','text/plain'],getData:type=>type==='text/html'?html:type==='text/plain'?text:'',files}});
 c._editor.view.input.shiftKey=plain;c._editor.view.input.lastKeyCode=insert?45:86;c._editor.view.dom.dispatchEvent(event);c._editor.view.input.shiftKey=false;return event;
}
async function test(name,run) {
 const c=document.createElement('bp-paper-canvas');c.blocks=structuredClone(seed);c.acknowledgedSaves=true;document.body.append(c);c._editor.commands.setTextSelection({from:8,to:16});const batches=[];c.addEventListener('bp-canvas-ops',e=>batches.push(e.detail));let uploads=0;c.mediaUploader=async()=>{uploads++;return{src:'/media/uploaded.png'};};
 try{await run(c,batches,()=>uploads);console.log('PASS '+name);passed++;}finally{c.remove();}
}
const file=()=>new window.File([new Uint8Array([137,80,78,71])],'clipboard.png',{type:'image/png'});
try {
 for(const html of [image,table+image,'<p>Lead</p>'+image+'<p>Tail</p>','<table><tr><td>'+image+'</td></tr></table>','<object data="unknown.bin"></object>','<span></span>']) await test('unsupported or empty rich paste preserves selection and emits no mutation',c=>{
  const before=c.recoverySnapshot().blocks;const selection=c._editor.state.selection.toJSON();paste(c,{html,text:'Fallback text'});assert.deepEqual(c.recoverySnapshot().blocks,before);assert.deepEqual(c._editor.state.selection.toJSON(),selection);assert.match(c.textContent,/Nothing was pasted/);assert.equal(c.hasPendingChanges(),false);
 });
 for(const html of [table,image,'<p>Text beside file</p>']) await test('mixed clipboard files and rich content are explicit no-op',async(c,batches,uploads)=>{
  paste(c,{html,text:'Clipboard text',files:[file()]});assert.deepEqual(c.recoverySnapshot().blocks,seed);c.flushPendingChanges();assert.equal(batches.length,0);assert.equal(uploads(),0);assert.match(c.textContent,/both image files/);
 });
 await test('explicit plain paste wins over images and supports native Undo',(c,batches,uploads)=>{
  paste(c,{html:table+image,text:'Plain text',files:[file()],plain:true});assert.equal(c._editor.state.doc.textContent,'Before Plain text After');assert.equal(c.recoverySnapshot().blocks.some(b=>b.type==='image'),false);assert.equal(uploads(),0);assert.equal(c._editor.commands.undo(),true);assert.deepEqual(c.recoverySnapshot().blocks,seed);
 });
 await test('plain paste without text preserves draft and does not upload',(c,batches,uploads)=>{
  paste(c,{files:[file()],plain:true});assert.deepEqual(c.recoverySnapshot().blocks,seed);assert.equal(uploads(),0);assert.match(c.textContent,/no plain text/);
 });
 await test('file-only paste retains the host upload path',async(c,batches,uploads)=>{
  paste(c,{files:[file()]});await new Promise(resolve=>setTimeout(resolve,0));assert.equal(uploads(),1);const blocks=c.recoverySnapshot().blocks;assert.equal(blocks[0].content[0].value,seed[0].content[0].value);assert.equal(blocks[1].type,'image');assert.equal(blocks[1].src,'/media/uploaded.png');
 });
 await test('native image wrapper remains a represented image',c=>{
  paste(c,{html:'<figure data-bp-type="image" data-src="/media/existing.png" data-alt="Existing"><img src="/media/existing.png" alt="Existing"></figure>'});const b=c.recoverySnapshot().blocks.find(b=>b.type==='image');assert.equal(b.src,'/media/existing.png');assert.equal(b.alt,'Existing');
 });
 await test('Shift Insert keeps ordinary rich table paste',c=>{
  paste(c,{html:table,text:'Table text',plain:true,insert:true});assert.ok(c.recoverySnapshot().blocks.some(b=>b.type==='table'));assert.equal(c.querySelector('[data-bp-paste-notice]'),null);
 });
 console.log(`${passed} rich clipboard preservation cases passed`);
}finally{dom.window.close();}
