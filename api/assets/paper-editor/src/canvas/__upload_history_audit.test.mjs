// Settled host uploads survive native image history without replaying requests.
// Run: node src/canvas/__upload_history_audit.test.mjs
import assert from "node:assert/strict";
import { closeHistory } from "@tiptap/pm/history";
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





// Host completion must follow native image history without replaying requests.
const seed=[{id:'seed',type:'paragraph',content:[{type:'text',value:'Human text stays.'}]}];
const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
const timers=[];const nativeTimeout=globalThis.setTimeout;
globalThis.setTimeout=(fn,ms,...args)=>{const t=nativeTimeout(fn,ms,...args);if(ms===60000)timers.push(t);return t;};
let passed=0;
function fixture(){
 const c=document.createElement('bp-paper-canvas');c.blocks=structuredClone(seed);c.acknowledgedSaves=true;document.body.append(c);
 const requests=[];c.mediaUploader=()=>new Promise((resolve,reject)=>requests.push({resolve,reject}));
 const paste=()=>{const file=new window.File([new Uint8Array([137,80,78,71])],'picture.png',{type:'image/png'});const event=new Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(event,'clipboardData',{value:{types:['Files'],getData:()=>'',files:[file]}});c._editor.view.dom.dispatchEvent(event);};
 return{c,requests,paste,blocks:()=>c.recoverySnapshot().blocks,image:()=>c._editor.state.doc.content.content.find(n=>n.type.name==='bpImage')};
}
async function test(name,run){const f=fixture();try{await run(f);console.log('PASS '+name);passed++;}finally{f.c.remove();await tick();}}
try{
 for(const order of ['undo-complete-redo','undo-redo-complete','complete-undo-redo'])await test(order+' restores one asset and one paste history action',async({c,requests,paste,blocks,image})=>{
  paste();assert.equal(requests.length,1);
  if(order.startsWith('undo'))assert.equal(c._editor.commands.undo(),true);
  if(order==='undo-redo-complete')assert.equal(c._editor.commands.redo(),true);
  // Separate completion beyond ProseMirror's grouping interval without sleeping.
  c._editor.view.dispatch(closeHistory(c._editor.state.tr));
  requests[0].resolve({src:'/media/result.png'});await tick();
  if(order==='undo-complete-redo'){assert.deepEqual(blocks(),seed);assert.equal(c._editor.commands.redo(),true);}
  assert.equal(image().attrs.src,'/media/result.png');assert.equal(image().attrs.uploading,null);
  for(let i=0;i<3;i++){assert.equal(c._editor.commands.undo(),true);assert.deepEqual(blocks(),seed);assert.equal(c._editor.commands.redo(),true);assert.equal(image().attrs.src,'/media/result.png');}
  assert.equal(requests.length,1);
 });
 await test('late rejection survives absent node and Redo as an explicit error',async({c,requests,paste,blocks,image})=>{
  paste();c._editor.commands.undo();requests[0].reject(Error('Upload unavailable'));await tick();assert.deepEqual(blocks(),seed);c._editor.commands.redo();assert.equal(image().attrs.uploadError,'Upload unavailable');assert.equal(image().attrs.uploading,null);assert.equal(requests.length,1);
 });
 await test('completion preserves later human text, caret and manual metadata',async({c,requests,paste,image})=>{
  paste();let pos;c._editor.state.doc.descendants((n,p)=>{if(n.type.name==='bpImage')pos=p;});const n=image();c._editor.view.dispatch(c._editor.state.tr.setNodeMarkup(pos,undefined,{...n.attrs,alt:'Human alt',src:'/media/human.png'}));c._editor.commands.setTextSelection(3);c._editor.commands.insertContent('typed');const selection=c._editor.state.selection.toJSON(),text=c._editor.state.doc.textContent;
  requests[0].resolve({src:'/media/result.png',alt:'Uploader alt'});await tick();assert.equal(image().attrs.src,'/media/human.png');assert.equal(image().attrs.alt,'Human alt');assert.equal(c._editor.state.doc.textContent,text);assert.deepEqual(c._editor.state.selection.toJSON(),selection);
 });
 await test('actual URL clear and alt return-to-original remain human choices',async({c,requests,paste,image})=>{
  paste();
  const edit=(selector,value)=>{const input=c.querySelector(selector);input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));};
  edit('.bp-canvas-image-src','/media/manual.png');edit('.bp-canvas-image-src','');
  edit('.bp-canvas-image-alt','Human alt');edit('.bp-canvas-image-alt','picture');
  requests[0].resolve({src:'/media/upload.png',alt:'Server alt'});await tick();
  assert.equal(image().attrs.src,null);assert.equal(image().attrs.alt,'picture');assert.equal(image().attrs.uploading,null);
 });
 await test('completion flushes uncommitted island input without serializing intent flags',async({c,requests,paste,image,blocks})=>{
  paste();const input=c.querySelector('.bp-canvas-image-alt');input.value='Still typing';input.dispatchEvent(new Event('input',{bubbles:true}));
  requests[0].resolve({src:'/media/upload.png',alt:'Server alt'});await tick();
  assert.equal(image().attrs.alt,'Still typing');assert.equal(c.querySelector('.bp-canvas-image-alt').value,'Still typing');
  assert.equal(image().attrs.src,'/media/upload.png');assert.equal(JSON.stringify(blocks()).includes('uploadAltEdited'),false);assert.equal(JSON.stringify(blocks()).includes('uploadSrcEdited'),false);
 });
 await test('deletion and another upload identity do not consume old completion',async({c,requests,paste,blocks,image})=>{
  paste();c._editor.commands.undo();c._editor.commands.insertContent('Different human edit');paste();requests[0].resolve({src:'/media/old.png'});await tick();assert.equal(image().attrs.src,null);assert.equal(image().attrs.uploading,true);requests[1].resolve({src:'/media/new.png'});await tick();assert.equal(image().attrs.src,'/media/new.png');assert.equal(blocks().filter(b=>b.type==='image').length,1);assert.equal(requests.length,2);
 });
 await test('disposal and remount reject the old editor callback',async({c,requests,paste,blocks})=>{
  paste();const oldEditor=c._editor;c.remove();await tick();c.blocks=structuredClone(seed);document.body.append(c);assert.notEqual(c._editor,oldEditor);requests[0].resolve({src:'/media/late.png'});await tick();assert.deepEqual(blocks(),seed);assert.equal(c._uploadResults.size,0);
 });
 console.log(`${passed} upload history cases passed`);
}finally{dom.window.close();for(const t of timers)clearTimeout(t);globalThis.setTimeout=nativeTimeout;}
