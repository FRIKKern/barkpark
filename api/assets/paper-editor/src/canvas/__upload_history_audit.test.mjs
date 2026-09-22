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




// Audit only: delayed host upload crosses native Undo/redo, without a server.
const seed=[{id:'seed',type:'paragraph',content:[{type:'text',value:'Human text stays.'}]}];
const outcomes=[];
for(const order of ['undo-complete-redo','complete-undo-redo']){
 const c=document.createElement('bp-paper-canvas');c.blocks=structuredClone(seed);c.acknowledgedSaves=true;document.body.append(c);
 let complete;let uploads=0;c.mediaUploader=()=>{uploads++;return new Promise(resolve=>complete=resolve);};
 const file=new window.File([new Uint8Array([137,80,78,71])],'picture.png',{type:'image/png'});
 const event=new Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(event,'clipboardData',{value:{types:['Files'],getData:()=>'',files:[file]}});
 c._editor.view.dom.dispatchEvent(event);
 const snapshot=()=>({blocks:c.recoverySnapshot().blocks,node:c._editor.state.doc.toJSON(),uploads});
 const pasted=snapshot();
 if(order==='undo-complete-redo')c._editor.commands.undo();
 complete({src:'/media/actual-upload.png'});await new Promise(resolve=>setTimeout(resolve,0));
 const completed=snapshot();
 if(order==='complete-undo-redo')c._editor.commands.undo();
 const undone=snapshot();c._editor.commands.redo();const redone=snapshot();
 outcomes.push({order,pasted,completed,undone,redone});c.remove();
}
console.log(JSON.stringify(outcomes,null,2));
dom.window.close();
const image=outcomes[0].redone.blocks.find(b=>b.type==='image');
assert.equal(image?.src,'/media/actual-upload.png','Redo after upload settles while absent must restore the acknowledged asset, not an orphaned uploading placeholder');
