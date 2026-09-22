// Splitting a mounted Paper must materialize one stable identity before saving.
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { closeHistory } from '@tiptap/pm/history';
const dom = new JSDOM('<!doctype html><body></body>', {pretendToBeVisual:true,url:'http://localhost/'});
const {window}=dom;
for(const name of ['customElements','CustomEvent','document','DOMParser','Element','Event','EventTarget','HTMLElement','KeyboardEvent','MutationObserver','Node','NodeFilter','Selection','Text'])globalThis[name]=window[name];
globalThis.window=window;
Object.defineProperty(globalThis,'navigator',{configurable:true,value:window.navigator});
globalThis.getComputedStyle=window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame=window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame=window.cancelAnimationFrame.bind(window);
globalThis.CSS||={escape:String};window.BP_PAPER_EDITOR_NO_INJECT=true;
await import('./index.js');
const seed=[{id:'origin',type:'paragraph',content:[{type:'text',value:'Before after'}]},{id:'reference',type:'paragraph',content:[{type:'link',href:'https://example.org/#origin',children:[{type:'text',value:'Reference stays'}]}]}];
const c=document.createElement('bp-paper-canvas');c.blocks=structuredClone(seed);c.acknowledgedSaves=true;document.body.append(c);
const batches=[];c.addEventListener('bp-canvas-ops',e=>batches.push(e.detail));
const save=()=>{c.flushPendingChanges();const b=batches.at(-1);assert.ok(b);c.acknowledgeOps(b.seq,true);return structuredClone(c.blocks);};
try{
 c._editor.commands.setTextSelection(8);assert.equal(c._editor.commands.splitBlock(),true);
 assert.equal(c._editor.state.doc.child(0).attrs.bpId,'origin');assert.equal(c._editor.state.doc.child(1).attrs.bpId,'origin','native split inherits the original stamp');
 const selection=c._editor.state.selection.toJSON();const saved=save();
 assert.notEqual(saved[1].id,'origin');assert.equal(saved[0].id,'origin');assert.deepEqual(saved[2],seed[1]);
 assert.equal(c._editor.state.doc.child(1).attrs.bpId,saved[1].id,'live split must carry its exact acknowledged identity');
 assert.deepEqual(c.recoverySnapshot().blocks,saved,'recovery snapshot must match acknowledged blocks including IDs');
 assert.deepEqual(c.recoverySnapshot().blocks,saved,'repeated reads must not mint new IDs');
 assert.deepEqual(c._editor.state.selection.toJSON(),selection,'identity stamping keeps the caret');
 c._editor.view.dispatch(closeHistory(c._editor.state.tr));c._editor.commands.insertContent('Human ');const next=save();
 assert.deepEqual(next.map(b=>b.id),saved.map(b=>b.id));assert.deepEqual(next[2],seed[1]);
 assert.ok(!batches.at(-1).ops.some(op=>op.op==='remove-block'||op.op==='insert-after'),'later text edit is an incremental patch');
 c._editor.commands.undo();const undone=save();assert.deepEqual(undone,saved,'Undo removes only later human typing');
 c._editor.commands.redo();assert.deepEqual(save(),next,'Redo restores content under the same identity');
 console.log('PASS split IDs, complete recovery equality, repeated edits, caret, references and Undo/Redo');
}finally{c.remove();window.close();}
