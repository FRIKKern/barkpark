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
 c._editor.view.dispatch(closeHistory(c._editor.state.tr));
 c._editor.commands.setTextSelection(8);c._editor.commands.splitBlock();c.flushPendingChanges();
 const pending=c._inflightOps;assert.ok(pending);const pendingIds=pending.afterBlocks.map(b=>b.id);
 assert.equal(new Set(pendingIds).size,pendingIds.length,'repeated splits produce unique IDs');
 assert.equal(pendingIds[0],'origin');assert.equal(pendingIds.at(-1),'reference');
 c._editor.commands.insertContent('Before acknowledgement');c.flushPendingChanges();
 assert.deepEqual(c.recoverySnapshot().blocks.map(b=>b.id),pendingIds,'typing while a split save is in flight keeps its identity');
 c.acknowledgeOps(pending.seq,true);const following=c._inflightOps;assert.ok(following);c.acknowledgeOps(following.seq,true);
 const settled=structuredClone(c.blocks);assert.deepEqual(c.recoverySnapshot().blocks,settled);
 assert.deepEqual(settled.map(b=>b.id),pendingIds);assert.deepEqual(settled.at(-1),seed[1]);
 c.applyServerBlocks(pending.afterBlocks,{mode:'own-stale'});
 assert.deepEqual(c.recoverySnapshot().blocks,settled,'delayed first receipt cannot revert current text or IDs');
 console.log('PASS split IDs, complete recovery equality, repeated edits, caret, references and Undo/Redo');
}finally{c.remove();}
for(const mutation of ['split','reorder','delete']){
 const canvas=document.createElement('bp-paper-canvas');canvas.blocks=structuredClone(seed);canvas.acknowledgedSaves=true;document.body.append(canvas);
 try{
  const e=canvas._editor;e.commands.setTextSelection(8);e.commands.splitBlock();canvas.flushPendingChanges();
  const first=canvas._inflightOps;assert.ok(first);const childId=first.afterBlocks[1].id;
  if(mutation==='split'){e.commands.setTextSelection(e.state.doc.child(0).nodeSize+3);e.commands.splitBlock();}
  if(mutation==='delete'){const start=e.state.doc.child(0).nodeSize;e.view.dispatch(e.state.tr.delete(start,start+e.state.doc.child(1).nodeSize));}
  if(mutation==='reorder'){const start=e.state.doc.child(0).nodeSize,n=e.state.doc.child(1);e.view.dispatch(e.state.tr.delete(start,start+n.nodeSize).insert(0,n));}
  canvas.flushPendingChanges();const intended=canvas.recoverySnapshot().blocks;
  assert.equal(new Set(intended.map(b=>b.id)).size,intended.length);
  canvas.acknowledgeOps(first.seq,true);const second=canvas._inflightOps;assert.ok(second);
  assert.deepEqual(canvas.recoverySnapshot().blocks,intended,'first receipt cannot stamp an obsolete position after '+mutation);
  assert.deepEqual(second.afterBlocks,intended,'next posted snapshot matches live identities after '+mutation);
  canvas.acknowledgeOps(second.seq,true);assert.deepEqual(canvas.blocks,intended);assert.deepEqual(canvas.recoverySnapshot().blocks,intended);
  assert.deepEqual(intended.find(b=>b.id==='reference'),seed[1]);assert.ok(intended.find(b=>b.id==='origin'));
  if(mutation==='delete')assert.ok(!intended.find(b=>b.id===childId));
  if(mutation==='reorder')assert.equal(intended[0].id,childId);
  canvas.applyServerBlocks(first.afterBlocks,{mode:'own-stale'});assert.deepEqual(canvas.recoverySnapshot().blocks,intended);
  console.log('PASS in-flight '+mutation+' preserves posted identities and rejects stale positional stamping');
 }finally{canvas.remove();}
}
{
 const canvas=document.createElement('bp-paper-canvas');canvas.blocks=structuredClone(seed);canvas.acknowledgedSaves=true;document.body.append(canvas);
 try{
  const e=canvas._editor;e.commands.setTextSelection(2);assert.equal(e.commands.toggleTaskList(),true);canvas.flushPendingChanges();
  const first=canvas._inflightOps;assert.ok(first);const listId=first.afterBlocks[0].id;
  assert.equal(e.state.doc.child(0).type.name,'taskList');
  assert.equal(e.state.doc.child(0).attrs.bpId,listId,'task list schema must retain its materialized identity');
  canvas.acknowledgeOps(first.seq,true);assert.deepEqual(canvas.recoverySnapshot().blocks,canvas.blocks);
  e.commands.insertContent('typed');canvas.flushPendingChanges();const second=canvas._inflightOps;assert.ok(second);
  assert.equal(second.afterBlocks[0].id,listId);assert.ok(second.ops.every(op=>op.op!=='remove-block'&&op.op!=='insert-after'),'checklist edit must patch its existing identity');
  canvas.acknowledgeOps(second.seq,true);const saved=structuredClone(canvas.blocks);
  canvas.applyServerBlocks(saved);assert.deepEqual(canvas.recoverySnapshot().blocks,saved);assert.deepEqual(saved[1],seed[1]);
  e.view.dispatch(closeHistory(e.state.tr));canvas.querySelector('input[type="checkbox"]').click();canvas.flushPendingChanges();
  const checked=canvas._inflightOps;assert.ok(checked);assert.equal(checked.afterBlocks[0].id,listId);assert.equal(checked.afterBlocks[0].items[0].checked,true);canvas.acknowledgeOps(checked.seq,true);
  e.commands.undo();canvas.flushPendingChanges();const undo=canvas._inflightOps;assert.ok(undo);canvas.acknowledgeOps(undo.seq,true);assert.deepEqual(canvas.blocks,saved,'checkbox Undo preserves all content and identities');
  e.commands.redo();canvas.flushPendingChanges();const redo=canvas._inflightOps;assert.ok(redo);canvas.acknowledgeOps(redo.seq,true);assert.deepEqual(canvas.blocks,checked.afterBlocks);
  const reopened=document.createElement('bp-paper-canvas');reopened.blocks=saved;document.body.append(reopened);
  try{assert.deepEqual(reopened.recoverySnapshot().blocks,saved,'reloaded checklist retains its stored ID');}finally{reopened.remove();}
  console.log('PASS checklist conversion, incremental acknowledgement and reload retain exact identity');
 }finally{canvas.remove();}
}
{
 const canvas=document.createElement('bp-paper-canvas');canvas.blocks=[...structuredClone(seed),{id:'empty',type:'paragraph',content:[]}];canvas.acknowledgedSaves=true;document.body.append(canvas);
 try{
  const e=canvas._editor,before=canvas.recoverySnapshot().blocks;e.commands.setTextSelection(e.state.doc.content.size-1);
  const paste=new Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(paste,'clipboardData',{value:{types:['text/html','text/plain'],files:[],getData:type=>type==='text/html'?'<ul><li>html one</li><li>html two</li></ul>':type==='text/plain'?'a b':''}});e.view.dom.dispatchEvent(paste);
  assert.equal(e.state.doc.lastChild.type.name,'bulletList');canvas.flushPendingChanges();const batch=canvas._inflightOps;assert.ok(batch);canvas.acknowledgeOps(batch.seq,true);const saved=structuredClone(canvas.blocks);canvas.applyServerBlocks(saved);
  assert.deepEqual(canvas.recoverySnapshot().blocks,saved);assert.equal(e.commands.undo(),true);assert.deepEqual(canvas.recoverySnapshot().blocks,before,'acknowledged HTML paste must undo to the exact original empty paragraph');
  e.commands.redo();assert.deepEqual(canvas.recoverySnapshot().blocks,saved,'Redo restores the acknowledged HTML list and identity');
  console.log('PASS acknowledged HTML list paste preserves complete Undo/Redo history');
 }finally{canvas.remove();}
}
window.close();
