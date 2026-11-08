// __canvas_endstate_boundary.test.mjs — final canvas ownership and topology lock.
// Run: node src/canvas/__canvas_endstate_boundary.test.mjs

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const here = dirname(fileURLToPath(import.meta.url));
const sha = (text) => createHash("sha256").update(text).digest("hex");
const DEFINITIONS = [
  {"key":"static:field:CONTRACT_VERSION","owner":"index.js","exportSymbol":null,"static":true,"kind":"field","name":"CONTRACT_VERSION","async":false,"runtimeLength":null,"header":"static CONTRACT_VERSION = CONTRACT_VERSION;","bodySha256":null,"wrapper":null,"wrapperSha256":null},
  {"key":"static:field:EDITOR_VERSION","owner":"index.js","exportSymbol":null,"static":true,"kind":"field","name":"EDITOR_VERSION","async":false,"runtimeLength":null,"header":"static EDITOR_VERSION = EDITOR_VERSION;","bodySha256":null,"wrapper":null,"wrapperSha256":null},
  {"key":"static:field:BUILD_SHA","owner":"index.js","exportSymbol":null,"static":true,"kind":"field","name":"BUILD_SHA","async":false,"runtimeLength":null,"header":"static BUILD_SHA = BUILD_SHA;","bodySha256":null,"wrapper":null,"wrapperSha256":null},
  {"key":"static:get:observedAttributes","owner":"canvas-lifecycle.js","exportSymbol":"getObservedAttributes","static":true,"kind":"get","name":"observedAttributes","async":false,"runtimeLength":0,"header":"static get observedAttributes() ","bodySha256":"b77e5fa141bd13efdc340fb4dc85de84dac68fc55844bb590fa1c8f6c92aadfd","wrapper":"  static get observedAttributes() { return lifecycleMethods.getObservedAttributes.call(this, ...arguments); }","wrapperSha256":"1cfc6eb3f1b2cc79e19dffe227dda20745a468115a2d7196090a1f0b42e7f80f"},
  {"key":"instance:constructor:constructor","owner":"canvas-lifecycle.js","exportSymbol":"initialize","static":false,"kind":"constructor","name":"constructor","async":false,"runtimeLength":0,"header":"constructor() ","bodySha256":"c81674392099bf0760847106dd5803799e7b52171c30f93fdb13db617ee65647","wrapper":"  constructor() { super(); lifecycleMethods.initialize.call(this); }","wrapperSha256":"c91b6b54ac8c0b3bcc000a891cb9cc62037b61520b9ce31c2b69c0a8ae332871"},
  {"key":"instance:method:connectedCallback","owner":"canvas-mount.js","exportSymbol":"connectedCallback","static":false,"kind":"method","name":"connectedCallback","async":false,"runtimeLength":0,"header":"connectedCallback() ","bodySha256":"5d078e837c3d62ebbfdb34cb222f63c83471f8032085800037048227f11e02fb","wrapper":"  connectedCallback() { return mountMethods.connectedCallback.call(this, ...arguments); }","wrapperSha256":"698854014c0d1c62e190f62fec92920e9f123f50a7758fb64d63bd2927c65c25"},
  {"key":"instance:method:attributeChangedCallback","owner":"canvas-lifecycle.js","exportSymbol":"attributeChangedCallback","static":false,"kind":"method","name":"attributeChangedCallback","async":false,"runtimeLength":3,"header":"attributeChangedCallback(name, _old, val) ","bodySha256":"c3420a5edf2c1efdeef9b279ba7308acef53e3ef52073a81d6d17abd7d09fd7c","wrapper":"  attributeChangedCallback(name, _old, val) {\n    return lifecycleMethods.attributeChangedCallback.call(this, ...arguments);\n  }","wrapperSha256":"db7c9288e77a230b8137fb507dc841442063ddaba61fe36928cd9082cfaad19b"},
  {"key":"instance:method:disconnectedCallback","owner":"canvas-lifecycle.js","exportSymbol":"disconnectedCallback","static":false,"kind":"method","name":"disconnectedCallback","async":false,"runtimeLength":0,"header":"disconnectedCallback() ","bodySha256":"234907123ad417d868d93ee9d0109bd7b7e9b38b93f96fabd739c62d343c0b2e","wrapper":"  disconnectedCallback() { return lifecycleMethods.disconnectedCallback.call(this, ...arguments); }","wrapperSha256":"6019c5c71fe15b67c8850eaa63f57d8ae9c4af6fb1ad1be8392a6e7bed1d600c"},
  {"key":"instance:method:captureResumeFocus","owner":"canvas-focus.js","exportSymbol":"captureResumeFocus","static":false,"kind":"method","name":"captureResumeFocus","async":false,"runtimeLength":0,"header":"captureResumeFocus() ","bodySha256":"0fe6b7439898339147e3c1c873246bcd5b360c7f5e0d48d8c4f67e6a7efcf9f1","wrapper":"  captureResumeFocus() { return focusMethods.captureResumeFocus.call(this, ...arguments); }","wrapperSha256":"8caa1de9c209ab83771678f66c4aeabbb0929df99e2a2a56444f4bf59b3b414c"},
  {"key":"instance:method:restoreResumeFocus","owner":"canvas-focus.js","exportSymbol":"restoreResumeFocus","static":false,"kind":"method","name":"restoreResumeFocus","async":false,"runtimeLength":0,"header":"restoreResumeFocus() ","bodySha256":"470c9a84a0043c803c8f93b6a75cb9463ec217c10b343bc19d498f3768c7f0b4","wrapper":"  restoreResumeFocus() { return focusMethods.restoreResumeFocus.call(this, ...arguments); }","wrapperSha256":"8ebbcbf06288bfae4fc453f886a78399f071af3ee98c6f219d1daa062682f3ff"},
  {"key":"instance:method:_cancelResumeFocus","owner":"canvas-focus.js","exportSymbol":"_cancelResumeFocus","static":false,"kind":"method","name":"_cancelResumeFocus","async":false,"runtimeLength":0,"header":"_cancelResumeFocus() ","bodySha256":"cbb1a9f509c8e7b5e8d385363e88d64cd33e0a95cb3d929cf6d5989cfb2fa26e","wrapper":"  _cancelResumeFocus() { return focusMethods._cancelResumeFocus.call(this, ...arguments); }","wrapperSha256":"a52c045dfd9d5baf9e73d5b0c63b83a9fa73dfb0428eacbb0842ad598b3425a5"},
  {"key":"instance:method:_clearResumeFocusIntent","owner":"canvas-focus.js","exportSymbol":"_clearResumeFocusIntent","static":false,"kind":"method","name":"_clearResumeFocusIntent","async":false,"runtimeLength":0,"header":"_clearResumeFocusIntent() ","bodySha256":"aecd510a052e1320055ac62fe25da3d267b9b230764b74202aeaa2dfca54233e","wrapper":"  _clearResumeFocusIntent() { return focusMethods._clearResumeFocusIntent.call(this, ...arguments); }","wrapperSha256":"423ae30ecdc96cae086a4f18204bea8821daa535e3ae9cb949b946f391997374"},
  {"key":"instance:method:_teardownDisconnected","owner":"canvas-lifecycle.js","exportSymbol":"_teardownDisconnected","static":false,"kind":"method","name":"_teardownDisconnected","async":false,"runtimeLength":0,"header":"_teardownDisconnected() ","bodySha256":"1fd6beccb446936d6dcab159c5dc22d88afbb18bbdd3f694510e4ced986199be","wrapper":"  _teardownDisconnected() { return lifecycleMethods._teardownDisconnected.call(this, ...arguments); }","wrapperSha256":"74e085c3f069c6598ba3b51b8a0bebcdea134c0b6a8b8ce5f1606e45f1c58f23"},
  {"key":"instance:method:flushPendingChanges","owner":"canvas-ops.js","exportSymbol":"flushPendingChanges","static":false,"kind":"method","name":"flushPendingChanges","async":false,"runtimeLength":0,"header":"flushPendingChanges() ","bodySha256":"cba99fbcaa8a82faad6e96de0d0d629e6aa322b4ab4ab1660736868f759ef13c","wrapper":"  flushPendingChanges() { return opsMethods.flushPendingChanges.call(this, ...arguments); }","wrapperSha256":"21ab1291fc9f34dc4f0302cda6064ab07e5a5ae39c505ee6fa61cfe05ca055b9"},
  {"key":"instance:method:setRemoteSelections","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"setRemoteSelections","async":false,"runtimeLength":1,"header":"setRemoteSelections(list) ","bodySha256":"e8c78a82fa4711130cef006e93599d67b8516dda46c79c81366a2757ed0cfc06","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:setCommentRanges","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"setCommentRanges","async":false,"runtimeLength":1,"header":"setCommentRanges(list) ","bodySha256":"1999727af5121a4b75644a6c9d4949e13bd706a6427e8ff7c70ae3022ec71b53","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:commentRanges","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"commentRanges","async":false,"runtimeLength":0,"header":"commentRanges() ","bodySha256":"8cc58433df1ca0de7b6f389b6bd6aacf1efaba0de864c983aa2a08079fda2e9a","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:commentsInSelection","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"commentsInSelection","async":false,"runtimeLength":0,"header":"commentsInSelection() ","bodySha256":"d8910a4d9c9e976e93fa76c693e33b2ec4de7263cf6fa08be580e411ec398ff0","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_scheduleCommentRangesEmit","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_scheduleCommentRangesEmit","async":false,"runtimeLength":0,"header":"_scheduleCommentRangesEmit() ","bodySha256":"bc431ad76f91a5f19b246cb797a40f040f122d18696ecf6bb626454882e041a4","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_scheduleSelectionEmit","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_scheduleSelectionEmit","async":false,"runtimeLength":0,"header":"_scheduleSelectionEmit() ","bodySha256":"d3f198d56e3e17f1350a8dd395ceec98e78cd7a0d4273e18b3e2194186cd3545","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_wantsBubble","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_wantsBubble","async":false,"runtimeLength":0,"header":"_wantsBubble() ","bodySha256":"137a677f9342a2af6d3000e9c750860a6302f944f7dcdef562e81af94221a199","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_requestHostLink","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_requestHostLink","async":false,"runtimeLength":0,"header":"_requestHostLink() ","bodySha256":"079a0eec72159947153ccbca451eb59191b43b8cbf64215089e8e5df3bdc907e","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_readDomTyping","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_readDomTyping","async":false,"runtimeLength":0,"header":"_readDomTyping() ","bodySha256":"1a8eaa7e9380eaa51e2736532b560310373a8b0e4414416f53f9fcc37df3cb54","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_escapeForHost","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_escapeForHost","async":false,"runtimeLength":2,"header":"_escapeForHost(view, event) ","bodySha256":"ce4931123ffd745e66847b1f257d39c8209c2088a132a016efe265fbc36ea1d8","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_modEnterForHost","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_modEnterForHost","async":false,"runtimeLength":2,"header":"_modEnterForHost(view, event) ","bodySha256":"18750f4af3669ca4e6154b7b4c96d21e07efec1559b77d1ae8fb553a12c1adb1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_swallowModEnter","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_swallowModEnter","async":false,"runtimeLength":1,"header":"_swallowModEnter(event) ","bodySha256":"b1d5d24be2c3252fadb7bd8fef0c4a74a69b3c7bea275d46ba51e2b5ad8cafb7","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_wikilinkClicked","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_wikilinkClicked","async":false,"runtimeLength":1,"header":"_wikilinkClicked(event) ","bodySha256":"9cd2a74623b43b7c055b55c20bb8b53c41031c89a9a1546ef644c66839a9c971","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_flushDomSelection","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_flushDomSelection","async":false,"runtimeLength":0,"header":"_flushDomSelection() ","bodySha256":"6dd1ef10f5083767a80428e92d5daac7711a87034b6994fcc0db91e4accba1dc","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:run","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"run","async":false,"runtimeLength":1,"header":"run(command, args = {}) ","bodySha256":"489a79f6cade8d87e7a5ac8d29e8c89b6319c45a154a0bcffbdadefe2d17673c","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:toggleMark","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"toggleMark","async":false,"runtimeLength":2,"header":"toggleMark(mark, attrs) ","bodySha256":"62a3aca8e4086e447b12a614dcae96384ad636b96191d5dcd3a72b051af410f6","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:setBlockStyle","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"setBlockStyle","async":false,"runtimeLength":1,"header":"setBlockStyle(style) ","bodySha256":"38d3d0b144492a40520d33fc163ffe2147d3cfb0403cd9a370b95a2164c8e157","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:toggleList","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"toggleList","async":false,"runtimeLength":1,"header":"toggleList(kind) ","bodySha256":"09b42ddf08f9ec6ddf98979efa6744cde254b937a5a52f43b0c8509fe51f58ee","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:insertBlock","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"insertBlock","async":false,"runtimeLength":2,"header":"insertBlock(type, attrs) ","bodySha256":"a591f546ef1d0d27aa9f3665188a8f726e658b65fc5fda30dad9e352d9fc5ecc","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:insertInline","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"insertInline","async":false,"runtimeLength":1,"header":"insertInline(type) ","bodySha256":"6e0b44b8af3044d0f307cea754ff353b2f7845deb227d5b4bc1137ae35d1efd8","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:undo","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"undo","async":false,"runtimeLength":0,"header":"undo() ","bodySha256":"5aaba4c04dcee00d2726d7cfc6a695611a96e781fb9754d3f5a607fedaccc241","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:redo","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"redo","async":false,"runtimeLength":0,"header":"redo() ","bodySha256":"90bfb18c6a68abca29cf1ee758a75f343206e827567b2327ef91e7a9b29bfb4f","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:can","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"can","async":false,"runtimeLength":1,"header":"can(command, args = {}) ","bodySha256":"22f92faf299a15479aceff87d17e321315c775ffb820a394c51a015d3dd10901","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:state","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"state","async":false,"runtimeLength":0,"header":"state() ","bodySha256":"981869537a77411c4c28a3262effa35e623d5327889fcd5a010810ed4f0007f4","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_toolbarVocabulary","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_toolbarVocabulary","async":false,"runtimeLength":0,"header":"_toolbarVocabulary() ","bodySha256":"27ff440e2cf15bc3bc5f0807a162e6a0ab978d2bd45a807554128beac900134d","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_toolbarInsertItem","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_toolbarInsertItem","async":false,"runtimeLength":1,"header":"_toolbarInsertItem(type) ","bodySha256":"6976e5c418afa5f5f8b4e9ba0860a6fa4144e105ea55a62a550b21a7f71fc939","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_canInsertInline","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_canInsertInline","async":false,"runtimeLength":2,"header":"_canInsertInline(type, vocab) ","bodySha256":"ff9483f0bd0219e80564b2aaa972e6f349e38f31ffbcb34d81878c635118b58f","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_insertToolbarInline","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_insertToolbarInline","async":false,"runtimeLength":1,"header":"_insertToolbarInline(type) ","bodySha256":"44c980f5ba0010d7275891e19599b416e9a459555a78cc5b75fdd4ed182018c1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_insertToolbarBlock","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_insertToolbarBlock","async":false,"runtimeLength":2,"header":"_insertToolbarBlock(type, attrs) ","bodySha256":"fb29256c4536577f05a270ef8de90eecc22dec8a1469bab90de1db60a8ee3a31","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_emitHistory","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_emitHistory","async":false,"runtimeLength":1,"header":"_emitHistory(transaction) ","bodySha256":"09b9db2b6ec7eafcc06830b66a2028e30c65f00313626ad8ac6227a9a282e55a","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_scheduleToolbarState","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_scheduleToolbarState","async":false,"runtimeLength":0,"header":"_scheduleToolbarState() ","bodySha256":"e3a6d9381c022d9676f1bf2514ee99c3e6cf07cab3888e7d69c66b784c40456c","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:findSet","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"findSet","async":false,"runtimeLength":2,"header":"findSet(query, opts) ","bodySha256":"109d98bc322d9c586ddd61d7643b3371ffe71c69152ad1dba86b229dd2e3a8c5","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:findNext","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"findNext","async":false,"runtimeLength":0,"header":"findNext() ","bodySha256":"e3e1f062bb0f548452f919b3cabd96002687bcd5a67046b8152b5c574998d7d8","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:findPrev","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"findPrev","async":false,"runtimeLength":0,"header":"findPrev() ","bodySha256":"8672b8ea57c885c0d7503efda7b83dc56f323bca56504cdbe16e131d88830b06","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:findClear","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"findClear","async":false,"runtimeLength":0,"header":"findClear() ","bodySha256":"cce5fd485b861a94e8174b50e3c42caa53d323877a62ee965cbd34633bbb7909","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:findState","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"findState","async":false,"runtimeLength":0,"header":"findState() ","bodySha256":"8c1ff09785403b4f53a1578ef9ece7b28006221f1f7d2a81dd1ed7c1761f8135","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:replaceCurrent","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"replaceCurrent","async":false,"runtimeLength":1,"header":"replaceCurrent(text) ","bodySha256":"73db1204edcd37c5687cf6cef43a41a66c60b5d1662ba9913f04ae59fec89dc9","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:replaceAll","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"replaceAll","async":false,"runtimeLength":1,"header":"replaceAll(text) ","bodySha256":"25b1d3c8ca5fffa19702580a9012207284aa55c97b3ace0ef39b0275142a058f","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:hasPendingChanges","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"hasPendingChanges","async":false,"runtimeLength":0,"header":"hasPendingChanges() ","bodySha256":"858a896f341fae2142eb18dfda2585ef7c04a43e43639dbb2993796960625dab","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:recoverySnapshot","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"recoverySnapshot","async":false,"runtimeLength":0,"header":"recoverySnapshot() ","bodySha256":"096e6d87294b8ebb0bc9cf6a155c53b95b4af9a182bffd85202216decefb2846","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:resolveConflictWithServerBlocks","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"resolveConflictWithServerBlocks","async":false,"runtimeLength":1,"header":"resolveConflictWithServerBlocks(blocks) ","bodySha256":"634124da83cd5e3446f39dcd06a979551a65e1790be8c77f465612b893b27867","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_scheduleEmit","owner":"canvas-ops.js","exportSymbol":"_scheduleEmit","static":false,"kind":"method","name":"_scheduleEmit","async":false,"runtimeLength":0,"header":"_scheduleEmit() ","bodySha256":"993083bff8f884e5ef465bbcc60e19646ee7d68a79083c40c780ccd78de2483f","wrapper":"  _scheduleEmit() { return opsMethods._scheduleEmit.call(this, ...arguments); }","wrapperSha256":"c1c83c03a187de84c1b20ca629983d0cc5ec6cfa50da03f3cb3332fa56d38821"},
  {"key":"instance:method:_armComposeEndEmit","owner":"canvas-ops.js","exportSymbol":"_armComposeEndEmit","static":false,"kind":"method","name":"_armComposeEndEmit","async":false,"runtimeLength":0,"header":"_armComposeEndEmit() ","bodySha256":"078a1e48aceb8cd61a5a2913a7d3a9d3108d4087c33f2a609cbf8a56c6dcfff1","wrapper":"  _armComposeEndEmit() { return opsMethods._armComposeEndEmit.call(this, ...arguments); }","wrapperSha256":"5f497de7855b940e685e77d8673a97193fe61c9ec78379ac94912a3d8ec12f4f"},
  {"key":"instance:method:_normalizedDoc","owner":"canvas-document.js","exportSymbol":"_normalizedDoc","static":false,"kind":"method","name":"_normalizedDoc","async":false,"runtimeLength":1,"header":"_normalizedDoc(doc) ","bodySha256":"d2dfa4f3f6cd745d4bdeec3df327e3651c3aa0a56777628923a3f357aafca09a","wrapper":"  _normalizedDoc(doc) { return documentMethods._normalizedDoc.call(this, ...arguments); }","wrapperSha256":"452267403e543a7f99f38239c911fcf7b477bbd24e78f550f15fe7d3f1ae7743"},
  {"key":"instance:method:_emitOps","owner":"canvas-ops.js","exportSymbol":"_emitOps","static":false,"kind":"method","name":"_emitOps","async":false,"runtimeLength":0,"header":"_emitOps() ","bodySha256":"66a9be8c5bdb4264cb346a6cdba123497103645c4e14dc28f0b09f17349077dc","wrapper":"  _emitOps() { return opsMethods._emitOps.call(this, ...arguments); }","wrapperSha256":"3de0b974b862792bd17f3f561eb383d3819fc547389552d4ccbe342abbdd87b9"},
  {"key":"instance:method:_committedDoc","owner":"canvas-ops.js","exportSymbol":"_committedDoc","static":false,"kind":"method","name":"_committedDoc","async":false,"runtimeLength":0,"header":"_committedDoc() ","bodySha256":"d0102069621a3c0093a68784aaba992616d2356dab3da3318e3d174af2bda03f","wrapper":"  _committedDoc() { return opsMethods._committedDoc.call(this, ...arguments); }","wrapperSha256":"efd1d841b03166b52769b20028c9d717e22b2381ed1b703e143153a63fa8df7c"},
  {"key":"instance:method:_afterComposition","owner":"canvas-ops.js","exportSymbol":"_afterComposition","static":false,"kind":"method","name":"_afterComposition","async":false,"runtimeLength":0,"header":"_afterComposition() ","bodySha256":"e8ad363a4dac7a1262f7ad79bd02d23985ddcf5ffb837102acc707d695961071","wrapper":"  _afterComposition() { return opsMethods._afterComposition.call(this, ...arguments); }","wrapperSha256":"11957fb013cf3fdebd3f8ea95b8b02d1103c79e924970c4677921cb6049df7a4"},
  {"key":"instance:method:_rememberEmit","owner":"canvas-ops.js","exportSymbol":"_rememberEmit","static":false,"kind":"method","name":"_rememberEmit","async":false,"runtimeLength":4,"header":"_rememberEmit(liveTop, nextDoc, nextBlocks, stableDoc) ","bodySha256":"7e0214cc7f6084d8f01691eb17f2a815733ba9896e93332c2799b50b9a065073","wrapper":"  _rememberEmit(liveTop, nextDoc, nextBlocks, stableDoc) { return opsMethods._rememberEmit.call(this, ...arguments); }","wrapperSha256":"a586c9ecd1a3a35de8481aad22543c226c71c47f0fcfb7dd6fca623ec72c46ed"},
  {"key":"instance:method:_emitReuse","owner":"canvas-ops.js","exportSymbol":"_emitReuse","static":false,"kind":"method","name":"_emitReuse","async":false,"runtimeLength":1,"header":"_emitReuse(diffBaseline) ","bodySha256":"6bc3f6f0438af42754596a0dcfa33a2566771b6c887cba7d7827041f0bc75e9c","wrapper":"  _emitReuse(diffBaseline) { return opsMethods._emitReuse.call(this, ...arguments); }","wrapperSha256":"5c7d7300ec7c41b6fc1858fca37b3d039dd4b51da3bd77fa3dc73981a5e16696"},
  {"key":"instance:method:_dispatchOps","owner":"canvas-ops.js","exportSymbol":"_dispatchOps","static":false,"kind":"method","name":"_dispatchOps","async":false,"runtimeLength":1,"header":"_dispatchOps(ops, nextBlocks = null, diffBaseline = this._blocks) ","bodySha256":"0edba458949b8ccd354027970c95a11a3965e2893fd98d93006c9753f635dd5f","wrapper":"  _dispatchOps(ops, nextBlocks = null, diffBaseline = this._blocks) {\n    return opsMethods._dispatchOps.call(this, ...arguments);\n  }","wrapperSha256":"18ee442fc49c938ad5a200e04d5521f89f5a325c18053ec01076408469488513"},
  {"key":"instance:method:identifyOpsRequest","owner":"canvas-ops.js","exportSymbol":"identifyOpsRequest","static":false,"kind":"method","name":"identifyOpsRequest","async":false,"runtimeLength":2,"header":"identifyOpsRequest(seq, requestId, previousRequestId = null) ","bodySha256":"140977196a49bf2e8ad51a0ebbb03d28dedadcd631f87c87ebad3545e318039a","wrapper":"  identifyOpsRequest(seq, requestId, previousRequestId = null) {\n    return opsMethods.identifyOpsRequest.call(this, ...arguments);\n  }","wrapperSha256":"d05f18262cbcc580a68face421e2ef2529c537346a26a3eace6eda2e78d7378d"},
  {"key":"instance:method:rebaseSafe","owner":"canvas-ops.js","exportSymbol":"rebaseSafe","static":false,"kind":"method","name":"rebaseSafe","async":false,"runtimeLength":2,"header":"rebaseSafe(seq, serverBlocks) ","bodySha256":"1baec9843abbb709385e287f232924aaee5c66e1d13dcc41df8db50fb993fd3b","wrapper":"  rebaseSafe(seq, serverBlocks) { return opsMethods.rebaseSafe.call(this, ...arguments); }","wrapperSha256":"98d4f8e9244d6cb6aca236eb3a373ac547b5241156b4e9c1947678fd7b0dbe4c"},
  {"key":"instance:method:localEditsRebaseSafe","owner":"canvas-ops.js","exportSymbol":"localEditsRebaseSafe","static":false,"kind":"method","name":"localEditsRebaseSafe","async":false,"runtimeLength":1,"header":"localEditsRebaseSafe(serverBlocks) ","bodySha256":"8c144634c482fff58d9e4c9a931c959e4c13f730d816b45513a0b8e0029c1735","wrapper":"  localEditsRebaseSafe(serverBlocks) { return opsMethods.localEditsRebaseSafe.call(this, ...arguments); }","wrapperSha256":"2a4e40e9e92269e6995f62d592b0079b2f4e816bc4e27ea5d76a724d24de2812"},
  {"key":"instance:method:acknowledgeOps","owner":"canvas-ops.js","exportSymbol":"acknowledgeOps","static":false,"kind":"method","name":"acknowledgeOps","async":false,"runtimeLength":2,"header":"acknowledgeOps(seq, saved) ","bodySha256":"a1047e8cdbedf145d18acba98e28ca21ccd185b73b14d5627f13bb14bdf088a1","wrapper":"  acknowledgeOps(seq, saved) { return opsMethods.acknowledgeOps.call(this, ...arguments); }","wrapperSha256":"d8c74c0157431edb1261914c80a79f1cbcc9cf399eb018a940c44ace4742d229"},
  {"key":"instance:method:discardInflightOps","owner":"canvas-ops.js","exportSymbol":"discardInflightOps","static":false,"kind":"method","name":"discardInflightOps","async":false,"runtimeLength":2,"header":"discardInflightOps(seq, refusal) ","bodySha256":"129bf1fa2328ff6caddc83ba45c6e45a6a3003728480b97c31793f6f474b2f73","wrapper":"  discardInflightOps(seq, refusal) { return opsMethods.discardInflightOps.call(this, ...arguments); }","wrapperSha256":"9a91eb3364dc11b2e4082e1558c6a134cdce4d091ebe68ad22957ac85a926c67"},
  {"key":"instance:method:_objectOverrides","owner":"canvas-document.js","exportSymbol":"_objectOverrides","static":false,"kind":"method","name":"_objectOverrides","async":false,"runtimeLength":0,"header":"_objectOverrides() ","bodySha256":"857f5b04d2dbdbed8caf544c95e50a73542613bf33b6ce44abd1083fbd534316","wrapper":"  _objectOverrides() { return documentMethods._objectOverrides.call(this, ...arguments); }","wrapperSha256":"2e926c289c3cc73d7bab2229cf1e6a895215fe0b9d3f9d77cd13cc733c91e052"},
  {"key":"instance:method:_rt","owner":"canvas-document.js","exportSymbol":"_rt","static":false,"kind":"method","name":"_rt","async":false,"runtimeLength":1,"header":"_rt(blocks) ","bodySha256":"76d32c16e8f173cbc71feece2f094e75f0b58f56cd8ec6de61b84e20585ddeec","wrapper":"  _rt(blocks) { return documentMethods._rt.call(this, ...arguments); }","wrapperSha256":"a7021890cca55dbc2dbaa3015585355caa19ed533bcb47ec8eccce574b1e4ef3"},
  {"key":"instance:method:_ro","owner":"canvas-document.js","exportSymbol":"_ro","static":false,"kind":"method","name":"_ro","async":false,"runtimeLength":0,"header":"_ro(...args) ","bodySha256":"e8195d6ccc1c54721a0621baeacf49d00fbb19a6a655a58ce72542d0f23e9a13","wrapper":"  _ro(...args) { return documentMethods._ro.call(this, ...arguments); }","wrapperSha256":"77215b1ffba1b151104f01c1efbcc1913d7a2df6d908f84cf82ccbb14842088e"},
  {"key":"instance:method:_re","owner":"canvas-document.js","exportSymbol":"_re","static":false,"kind":"method","name":"_re","async":false,"runtimeLength":0,"header":"_re(...args) ","bodySha256":"36a807aaeca784c045d12b05aee3cc4ac61b443a678fccfa9fb16b5a34538be8","wrapper":"  _re(...args) { return documentMethods._re.call(this, ...arguments); }","wrapperSha256":"0623e1e89b9a09ae0cac16c0333102f27ee662af4eabc873591d5304fc218dce"},
  {"key":"instance:method:_inlineObjectVocabulary","owner":"canvas-document.js","exportSymbol":"_inlineObjectVocabulary","static":false,"kind":"method","name":"_inlineObjectVocabulary","async":false,"runtimeLength":0,"header":"_inlineObjectVocabulary() ","bodySha256":"ff0c89f2bdf41290317f33ed60c4521116a2d409d997696eee697906a70cfcb6","wrapper":"  _inlineObjectVocabulary() { return documentMethods._inlineObjectVocabulary.call(this, ...arguments); }","wrapperSha256":"8c061f167307d5cee7bbf487579badb07ce90715041b0d27b9c14b879d9a3850"},
  {"key":"instance:method:_inlineObjectDialog","owner":"canvas-document.js","exportSymbol":"_inlineObjectDialog","static":false,"kind":"method","name":"_inlineObjectDialog","async":false,"runtimeLength":0,"header":"_inlineObjectDialog() ","bodySha256":"83c54650eed16e909874bc367bc4744d51aec78e1e3be52c6a6ebf32f967f22f","wrapper":"  _inlineObjectDialog() { return documentMethods._inlineObjectDialog.call(this, ...arguments); }","wrapperSha256":"f65a7242170a46e2a9647c0330eacb89ba7f17ec2b708e9b992ac0af53d7de23"},
  {"key":"instance:set:editBlockObject","owner":"canvas-document.js","exportSymbol":"setEditBlockObject","static":false,"kind":"set","name":"editBlockObject","async":false,"runtimeLength":1,"header":"set editBlockObject(fn) ","bodySha256":"0a4b664e4a736b3be464ed0b1f871f8ce996f535afdcdcf202f6db65de0928fd","wrapper":"  set editBlockObject(fn) { return documentMethods.setEditBlockObject.call(this, ...arguments); }","wrapperSha256":"440983e41ef79908123302fc331fc9cd8fe74d0c31a2a9d8e41e68e8048887e4"},
  {"key":"instance:get:editBlockObject","owner":"canvas-document.js","exportSymbol":"getEditBlockObject","static":false,"kind":"get","name":"editBlockObject","async":false,"runtimeLength":0,"header":"get editBlockObject() ","bodySha256":"3b863a58043f34047784e3e57166c2cc30dbb51ca601cbcb889344faab2c06e3","wrapper":"  get editBlockObject() { return documentMethods.getEditBlockObject.call(this, ...arguments); }","wrapperSha256":"79f729fcd33311fd9d60e35bb4c2fa92a9f147a86e1c556acc3be9e6f36b638b"},
  {"key":"instance:method:_objectEditorOpen","owner":"canvas-document.js","exportSymbol":"_objectEditorOpen","static":false,"kind":"method","name":"_objectEditorOpen","async":false,"runtimeLength":0,"header":"_objectEditorOpen() ","bodySha256":"97f0e72ceb3c503b7ba304b6bc05455efa222b250afa00238558a09120918018","wrapper":"  _objectEditorOpen() { return documentMethods._objectEditorOpen.call(this, ...arguments); }","wrapperSha256":"cc48890f39dac2d5708155b018cfcf06aad0b631ac347ffcd23b04de195ccb6e"},
  {"key":"instance:method:_noteInlineObjectSave","owner":"canvas-document.js","exportSymbol":"_noteInlineObjectSave","static":false,"kind":"method","name":"_noteInlineObjectSave","async":false,"runtimeLength":1,"header":"_noteInlineObjectSave(values) ","bodySha256":"6b602e8659d109b067d3ee02fa5e6ff1dab464ffb80cbc08cbb6bd9e95251fb5","wrapper":"  _noteInlineObjectSave(values) { return documentMethods._noteInlineObjectSave.call(this, ...arguments); }","wrapperSha256":"45e9eec62db82039016e4bc9640484de207967e292236e7fcc80b0c703ccb984"},
  {"key":"instance:method:_reopenRefusedInlineObject","owner":"canvas-document.js","exportSymbol":"_reopenRefusedInlineObject","static":false,"kind":"method","name":"_reopenRefusedInlineObject","async":false,"runtimeLength":1,"header":"_reopenRefusedInlineObject(refusal) ","bodySha256":"5757102f848e9ae283bf6881a6bb2390857a92e24d918709e339228b8a4ea1de","wrapper":"  _reopenRefusedInlineObject(refusal) { return documentMethods._reopenRefusedInlineObject.call(this, ...arguments); }","wrapperSha256":"83284cf73de4b69f3d7203c09e3fad9bfe7f92c258f755288a2dd684c333fe74"},
  {"key":"instance:method:resendPendingOps","owner":"canvas-ops.js","exportSymbol":"resendPendingOps","static":false,"kind":"method","name":"resendPendingOps","async":false,"runtimeLength":0,"header":"resendPendingOps() ","bodySha256":"aa2269db310d2275afdd1c0706375e14f831abc85470dbd6d488e6b4cca52921","wrapper":"  resendPendingOps() { return opsMethods.resendPendingOps.call(this, ...arguments); }","wrapperSha256":"ee4ffd050af3f801f4e81fd795d2d03475677f26f64dc8c4ccc477575e970008"},
  {"key":"instance:method:_onKeyDown","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_onKeyDown","async":false,"runtimeLength":1,"header":"_onKeyDown(event) ","bodySha256":"e5c55fe63d79855c7eb557575c48918f39e4103f483105c00d9e9add90b70700","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_onPaste","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_onPaste","async":false,"runtimeLength":3,"header":"_onPaste(view, _event, slice) ","bodySha256":"bfa7b9e3e9e06c8c302d36ffc9de0633a871ae3e947fe227c97ed2d1ba81b69e","wrapper":null,"wrapperSha256":null},
  {"key":"static:method:_imageFiles","owner":"index.js","exportSymbol":null,"static":true,"kind":"method","name":"_imageFiles","async":false,"runtimeLength":1,"header":"static _imageFiles(list) ","bodySha256":"ade83368d107255a36e00833cce4cf1701734e13b3ef6fa66ffab417350d49db","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_pasteImageFiles","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_pasteImageFiles","async":false,"runtimeLength":2,"header":"_pasteImageFiles(view, event, imageAlt = null) ","bodySha256":"03b73cffc5eb28fccb98f576e0f34896de703cad8dece5c5132a79cbb2222354","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_onDrop","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_onDrop","async":false,"runtimeLength":3,"header":"_onDrop(view, event, moved) ","bodySha256":"95a3ed827abaa98e58138de827f8b9d746cab67be6e833591acce938d9b9e6ac","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_insertImageFiles","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_insertImageFiles","async":false,"runtimeLength":3,"header":"_insertImageFiles(view, files, atPos, imageAlt = null) ","bodySha256":"3a1cd621af50e0eb7bb923bfd1c08d220973f634457e16784e827c0199262df2","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_findUploadNode","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_findUploadNode","async":false,"runtimeLength":1,"header":"_findUploadNode(key) ","bodySha256":"67758133b1c67f7f0b889615e3e27288fde7a979378952ea72fa89ef7d29d9f2","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_patchUploadNode","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_patchUploadNode","async":false,"runtimeLength":2,"header":"_patchUploadNode(key, receipt) ","bodySha256":"fbf05cf0f8c99c54e6147988123db22306456346412d95534fd4395b95842448","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_restoreUploadResults","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_restoreUploadResults","async":false,"runtimeLength":0,"header":"_restoreUploadResults() ","bodySha256":"1f98e49eb54cbf950cdc57285ed2db5f74a73a9ce5701c709807ef3be128bc60","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_uploadImage","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_uploadImage","async":true,"runtimeLength":3,"header":"async _uploadImage(key, file, previewUrl) ","bodySha256":"600f54b51aa2f1175e86d5014d19bd89d8f5d71b215d63e8dc58df2af110fc04","wrapper":null,"wrapperSha256":null},
  {"key":"instance:set:mediaUploader","owner":"index.js","exportSymbol":null,"static":false,"kind":"set","name":"mediaUploader","async":false,"runtimeLength":1,"header":"set mediaUploader(fn) ","bodySha256":"a41e58bae4b58151217234a9c5618bc14ce3c5df453989e2a2f31500cb2ca43c","wrapper":null,"wrapperSha256":null},
  {"key":"instance:set:mediaPicker","owner":"index.js","exportSymbol":null,"static":false,"kind":"set","name":"mediaPicker","async":false,"runtimeLength":1,"header":"set mediaPicker(fn) ","bodySha256":"9cf75f3f1b8a9586246f9d1e638da197f3cb67768bc56e5e0e3b042a209be06f","wrapper":null,"wrapperSha256":null},
  {"key":"instance:get:mediaPicker","owner":"index.js","exportSymbol":null,"static":false,"kind":"get","name":"mediaPicker","async":false,"runtimeLength":0,"header":"get mediaPicker() ","bodySha256":"9de7d719adb239cdffdc69aa03e8fd31a480ead5ab3a528bed95ef07e7cd4518","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_pickImageAt","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_pickImageAt","async":true,"runtimeLength":1,"header":"async _pickImageAt(pos) ","bodySha256":"e54c37484e049ed8c3fdea147cee0f5afb37a60a81c39043fa3624f317a1a458","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_pickInsertedImage","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_pickInsertedImage","async":false,"runtimeLength":0,"header":"_pickInsertedImage() ","bodySha256":"23bb44a81d0405c597f6941aa2d9914e32f86f7ab15da7dda219dd9b2285ae58","wrapper":null,"wrapperSha256":null},
  {"key":"instance:get:mediaUploader","owner":"index.js","exportSymbol":null,"static":false,"kind":"get","name":"mediaUploader","async":false,"runtimeLength":0,"header":"get mediaUploader() ","bodySha256":"d43e3791fef9e4761bea3a6b68b18d54fdbfd7b66a27199bec965971e056bfaa","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_pasteHTMLTables","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_pasteHTMLTables","async":false,"runtimeLength":2,"header":"_pasteHTMLTables(view, event) ","bodySha256":"814867493f96740549feb51535d5cd207328afe45635b80cdee80f1f86542ba1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_pasteMarkdown","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_pasteMarkdown","async":false,"runtimeLength":2,"header":"_pasteMarkdown(view, event) ","bodySha256":"3d2ef21f267f77d6ad9ecf483a57fd84b397864b2a2d650232d79298dddf5f02","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_pastePlainText","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_pastePlainText","async":false,"runtimeLength":2,"header":"_pastePlainText(view, event, force = false) ","bodySha256":"e549e2aa5c050bd364fde118058b81a7698604f62f0d52f830711f54e3484501","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_noteDropMoves","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_noteDropMoves","async":false,"runtimeLength":2,"header":"_noteDropMoves(view, event) ","bodySha256":"a98096dc2b8183c7a2a9ae4e0ff281ec50e94fa7311178e74a22557947b0257e","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_fitPastedSlice","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_fitPastedSlice","async":false,"runtimeLength":1,"header":"_fitPastedSlice(slice) ","bodySha256":"e248ced10aab35cd938be691e3d94debe0d1b7368c48f2ef434a056764600905","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_fitPastedNodes","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_fitPastedNodes","async":false,"runtimeLength":1,"header":"_fitPastedNodes(fragment, imagesLeftOut = 0) ","bodySha256":"c476fd559fce11bcbf79c2d92240797bd399b3ebf104c39ad796d9c4d7423c3c","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_noticeLeftOut","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_noticeLeftOut","async":false,"runtimeLength":1,"header":"_noticeLeftOut(dropped) ","bodySha256":"abfbc5d7db0dd497533491e45488b4d9e26af6a8cdbd61bfa51297d3aad47516","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_showHTMLPasteNotice","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_showHTMLPasteNotice","async":false,"runtimeLength":1,"header":"_showHTMLPasteNotice(message) ","bodySha256":"8ce0b90c4737463392615b8b666340a3f9784d957653795d805299c3bf45af92","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_clearHTMLPasteNotice","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_clearHTMLPasteNotice","async":false,"runtimeLength":0,"header":"_clearHTMLPasteNotice() ","bodySha256":"741cedf1e801658b2e3583301d2a2088bda6946c441de6075536bf10731b42cf","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_showFigureConstraint","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_showFigureConstraint","async":false,"runtimeLength":0,"header":"_showFigureConstraint(message = \"A Figure keeps one content block. Enter cannot split or remove it.\") ","bodySha256":"53f7ff5cfda4bbcd523e81d529ad73767c166aeef8fb8d484f71d1e06452d0a3","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_clearFigureConstraint","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_clearFigureConstraint","async":false,"runtimeLength":0,"header":"_clearFigureConstraint(transaction = null) ","bodySha256":"31d83a847564a51014a902690f45110b9b43fa60fec57ebffb6afa6943aa9228","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_caretRect","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_caretRect","async":false,"runtimeLength":0,"header":"_caretRect() ","bodySha256":"98cb5b4f83ab273397ddb3b4f82aa3bad8d06dafbecd1c425d2315b4c86e05b6","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_maybeWikilink","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_maybeWikilink","async":false,"runtimeLength":0,"header":"_maybeWikilink() ","bodySha256":"27b05f8998d12d62643f5cb1379db8d8dae8d6b087b0733d9ec55dc86284ea19","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_openWikilink","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_openWikilink","async":false,"runtimeLength":1,"header":"_openWikilink(rect, query = \"\") ","bodySha256":"b1eb83ccf4083a926d3b53a789342137c260c84063f240eb8a55dc690c0d5e1e","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_closeWikilink","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_closeWikilink","async":false,"runtimeLength":0,"header":"_closeWikilink() ","bodySha256":"9174f80f7234584972133392c6720af22be1a8e4030ad6b8232a8ed4efc181a3","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_chooseWikilink","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_chooseWikilink","async":false,"runtimeLength":1,"header":"_chooseWikilink(candidate) ","bodySha256":"0eb9ca0f3d1a7fb7a0795904399e75d51ceee716e972a49fd2d247a7070def88","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_dismissWikilink","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_dismissWikilink","async":false,"runtimeLength":0,"header":"_dismissWikilink() ","bodySha256":"960f9be0ec67704ec0641e9b93b3009c198e0d32bb73d96f5b70ddc3a5af3b99","wrapper":null,"wrapperSha256":null},
  {"key":"instance:set:wikilinkSource","owner":"index.js","exportSymbol":null,"static":false,"kind":"set","name":"wikilinkSource","async":false,"runtimeLength":1,"header":"set wikilinkSource(fn) ","bodySha256":"cb6b4d26701029a46fa76d0d95c62082efe40d1f5e4be6293d09c539919139e1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:get:wikilinkSource","owner":"index.js","exportSymbol":null,"static":false,"kind":"get","name":"wikilinkSource","async":false,"runtimeLength":0,"header":"get wikilinkSource() ","bodySha256":"9ab8267a65bad4c70108716fdd392c6b329abb519899fdf6b61dfb4bf0fabac9","wrapper":null,"wrapperSha256":null},
  {"key":"instance:set:linkPreviewSource","owner":"index.js","exportSymbol":null,"static":false,"kind":"set","name":"linkPreviewSource","async":false,"runtimeLength":1,"header":"set linkPreviewSource(fn) ","bodySha256":"f948d9a4ecca14d8c78e7a9335c0942845935fb0ccb0638325b4c751f4512f7f","wrapper":null,"wrapperSha256":null},
  {"key":"instance:get:linkPreviewSource","owner":"index.js","exportSymbol":null,"static":false,"kind":"get","name":"linkPreviewSource","async":false,"runtimeLength":0,"header":"get linkPreviewSource() ","bodySha256":"63304d588100cadfe60b081604467a83efa7b8d5107c501af0a23608f9de5f98","wrapper":null,"wrapperSha256":null},
  {"key":"instance:set:wikilinkResolve","owner":"index.js","exportSymbol":null,"static":false,"kind":"set","name":"wikilinkResolve","async":false,"runtimeLength":1,"header":"set wikilinkResolve(fn) ","bodySha256":"a52ddd8820d2dccfaadd560e2a09ad84fd55dda70d92b2401295c9ccdfabf566","wrapper":null,"wrapperSha256":null},
  {"key":"instance:get:wikilinkResolve","owner":"index.js","exportSymbol":null,"static":false,"kind":"get","name":"wikilinkResolve","async":false,"runtimeLength":0,"header":"get wikilinkResolve() ","bodySha256":"9f71f1d480a7742ff0c5e81b861b5625e395dbb3eea12875fea7769fcbc731f0","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:refreshWikilinks","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"refreshWikilinks","async":false,"runtimeLength":0,"header":"refreshWikilinks() ","bodySha256":"23cdb3c945286ade232184447898210544dc4df7fee4899825a6cd3014be4638","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_maybeTag","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_maybeTag","async":false,"runtimeLength":0,"header":"_maybeTag() ","bodySha256":"23cfeb0f4810c7d05970b6712905ceafe73a134d73134c8c7fa1910183cddcd5","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_maybeEmoji","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_maybeEmoji","async":false,"runtimeLength":0,"header":"_maybeEmoji() ","bodySha256":"66c92ce87912e070a84e5ec71ca66ab55ef526890a9ee732f9337e38b1852ee1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_openEmoji","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_openEmoji","async":false,"runtimeLength":1,"header":"_openEmoji(rect, query = \"\") ","bodySha256":"8d2caf0260aabcc4565da416d65eaacfc1da72511e6c9a273cb6c725052ae573","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_closeEmoji","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_closeEmoji","async":false,"runtimeLength":0,"header":"_closeEmoji() ","bodySha256":"3689b5f37d96ea740bf372f351cd382e2582ea932ce4924d6197ba3bf3315d23","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_chooseEmoji","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_chooseEmoji","async":false,"runtimeLength":1,"header":"_chooseEmoji(candidate) ","bodySha256":"d6e62018d3014e20f3caa5df3aba83567d9b2fa383012373a1662465d029f6da","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_dismissEmoji","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_dismissEmoji","async":false,"runtimeLength":0,"header":"_dismissEmoji() ","bodySha256":"0165de7ab65d53f34b1d34f2793d338f8a0c5f648fe21fbb006e564828802404","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_openTag","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_openTag","async":false,"runtimeLength":1,"header":"_openTag(rect, query = \"\") ","bodySha256":"ca4ecfd7f5cb3d2cc4c211c2b1088a5516a5c059cd8ebc0493da93f5654c7c6d","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_closeTag","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_closeTag","async":false,"runtimeLength":0,"header":"_closeTag() ","bodySha256":"c4f385828da2a8cc179f828f909907b6b53e1761bab3c777f52f337fe8719249","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_chooseTag","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_chooseTag","async":false,"runtimeLength":1,"header":"_chooseTag(candidate) ","bodySha256":"a0c316ba0899c8bd76641b97111e69e41ad5548af6c7272d4bab40282bdc904a","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_dismissTag","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_dismissTag","async":false,"runtimeLength":0,"header":"_dismissTag() ","bodySha256":"c75f5f332aea96505dec39363bfdd235e12cccd924c2bbfcd80048d6e1064b37","wrapper":null,"wrapperSha256":null},
  {"key":"instance:set:tagSource","owner":"index.js","exportSymbol":null,"static":false,"kind":"set","name":"tagSource","async":false,"runtimeLength":1,"header":"set tagSource(fn) ","bodySha256":"9b30622174a90ef4879e889d8bedee913697353dc706417a2b474171702f906e","wrapper":null,"wrapperSha256":null},
  {"key":"instance:get:tagSource","owner":"index.js","exportSymbol":null,"static":false,"kind":"get","name":"tagSource","async":false,"runtimeLength":0,"header":"get tagSource() ","bodySha256":"ae7b8a4816c943da66b381c096f8e0e24bf52c4b4544baeb5185a5f84bc43dc4","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_maybeSlash","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_maybeSlash","async":false,"runtimeLength":0,"header":"_maybeSlash() ","bodySha256":"e8bfc4d9e64e1f10c7cdfd5b4cdef91cf1557350c50b87f0cb5e61e412e4192e","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_replaceTopBlockWithQuote","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_replaceTopBlockWithQuote","async":false,"runtimeLength":1,"header":"_replaceTopBlockWithQuote(type) ","bodySha256":"83d041a18a9f298f9d618f0455ed8a34374f9bde04b7928f0c00c38f6a3f5c47","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_maybeBlockShorthand","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_maybeBlockShorthand","async":false,"runtimeLength":0,"header":"_maybeBlockShorthand() ","bodySha256":"0b4bf77a3f5f243ffc656c0aba93fd08bfd1e9173fb7e724bd4cd82c6fa84a27","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_maybeCalloutShorthand","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_maybeCalloutShorthand","async":false,"runtimeLength":0,"header":"_maybeCalloutShorthand() ","bodySha256":"ee611d10e28cc7a9eead988443930686547aed2b8cb4e76a47adff0d5726e6bd","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_openSlash","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_openSlash","async":false,"runtimeLength":0,"header":"_openSlash(query = \"\") ","bodySha256":"096f21ccf44305e862d4aae57856dc5d60c232bbeb60b2636b5b4bf71489945e","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_closeSlash","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_closeSlash","async":false,"runtimeLength":0,"header":"_closeSlash() ","bodySha256":"62b1e110e94ed8ebfe341790375575e10417f96fb2277e588a91fa0b404f5e5c","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_slashInListItem","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_slashInListItem","async":false,"runtimeLength":1,"header":"_slashInListItem($from) ","bodySha256":"045f6e80a2661849aa87865c6839d4eb4757be93be83d2f0cf4c5fcff912e875","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_chooseSlash","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_chooseSlash","async":false,"runtimeLength":1,"header":"_chooseSlash(item) ","bodySha256":"96d963b424b47a70f51a1bc4bc728ce340336e33a70bc968bd8fa8ba0ebd506b","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_insertObjectBlock","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_insertObjectBlock","async":false,"runtimeLength":2,"header":"_insertObjectBlock(type, bpBlock, opts = {}) ","bodySha256":"21ace1f95ed0c6269ec24c43d0c20725fb5720067d8bf84dbd66d153eafecdd0","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_insertDeclaredObject","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_insertDeclaredObject","async":false,"runtimeLength":1,"header":"_insertDeclaredObject(type) ","bodySha256":"5146880c3824fe3cb043bb935ef31b1b2b6309b653e3d3bc63caf94b3acf76b5","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_mastersRoot","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_mastersRoot","async":false,"runtimeLength":0,"header":"_mastersRoot() ","bodySha256":"44bbccb496ef18a2d8b371ce4bec166615081df996ea20506c2f1da1cd42e1b9","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_canSaveMaster","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_canSaveMaster","async":false,"runtimeLength":1,"header":"_canSaveMaster(node) ","bodySha256":"7b0872d644861045a7e67bbd4faaa56b2314f65072ccdae6fd2e50f5e9b47805","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_saveMaster","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_saveMaster","async":false,"runtimeLength":1,"header":"_saveMaster(node) ","bodySha256":"23d15eeabb7336da8af5de8483ac377352c007caecf665785b8a859271acc95e","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_insertMaster","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_insertMaster","async":false,"runtimeLength":1,"header":"_insertMaster(masterId, mode = null) ","bodySha256":"6767c743f0adab311b230c27dc3c2a2c453af1ef7db3cb14d2e74e435d512d97","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_hostBuildsInserts","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_hostBuildsInserts","async":false,"runtimeLength":0,"header":"_hostBuildsInserts() ","bodySha256":"28f296da8580dcf9073afdba9f8bdf3fdc90db00b8f05616852acb0c57773aa2","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_insertViaServer","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_insertViaServer","async":false,"runtimeLength":1,"header":"_insertViaServer(type, { replaceSlashLine = false } = {}) ","bodySha256":"0ec58ade05159bb2b1e9ccae8e00df91a57680c0d1a61f3633631a9ff320dabe","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_dismissSlash","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_dismissSlash","async":false,"runtimeLength":0,"header":"_dismissSlash() ","bodySha256":"cac943e961f8ff4dc0fa6a87b66d21131d69d116af4172a056d04d4ff81553ca","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_openPalette","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_openPalette","async":false,"runtimeLength":0,"header":"_openPalette() ","bodySha256":"ca6bc3c071cc54ce3eb1556e3b80068f3374ab13455dc1bab91847578e2f27a6","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_closePalette","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_closePalette","async":false,"runtimeLength":0,"header":"_closePalette() ","bodySha256":"1dedf4e7346d9a64bf9f463a7921a959fc1ef4c825d8d65d92c2eaf6d5db894f","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_choosePaletteCommand","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_choosePaletteCommand","async":false,"runtimeLength":1,"header":"_choosePaletteCommand(cmd) ","bodySha256":"5aa71def4f373250d1df879d14d2088f0b666aefdb3a2bdb6bc5de56f7768fe1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_dismissPalette","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_dismissPalette","async":false,"runtimeLength":0,"header":"_dismissPalette() ","bodySha256":"ed73027cd1bae606aeb57ce02a7ffdd2a975e06ea31d1b3de7d9c14ef864d3e1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:toggleSourceMode","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"toggleSourceMode","async":false,"runtimeLength":0,"header":"toggleSourceMode() ","bodySha256":"6c99c0b72d37e41ec835f07fd7e2ef765438d5d30c11973d99a806e5f1fbc3bb","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_enterSourceMode","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_enterSourceMode","async":false,"runtimeLength":0,"header":"_enterSourceMode() ","bodySha256":"f3c762b5576f7f0c40864cb963a39914f5c2a47c161e715866b22fc751de17f1","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_exitSourceMode","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_exitSourceMode","async":false,"runtimeLength":0,"header":"_exitSourceMode() ","bodySha256":"031f4619b689dceb1fc9f2d333be8af642144fab3a51cdccdf1ddbf549a102d7","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_commitSource","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_commitSource","async":false,"runtimeLength":1,"header":"_commitSource(md) ","bodySha256":"b47851a02cdb76b9a1546f4abda4a128d3e75187d596b5784cecc3babcdf0d1f","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_syncSourceText","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_syncSourceText","async":false,"runtimeLength":0,"header":"_syncSourceText() ","bodySha256":"85ec47cdbbe9d028681739f90788b22686b2d85d170233d6238ada39541e4616","wrapper":null,"wrapperSha256":null},
  {"key":"instance:get:sourceMode","owner":"index.js","exportSymbol":null,"static":false,"kind":"get","name":"sourceMode","async":false,"runtimeLength":0,"header":"get sourceMode() ","bodySha256":"82883b78df8b222cb51a589e13409797fd8f113275d0981e5540f0c18e43ba85","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_sizeSourceTextarea","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_sizeSourceTextarea","async":false,"runtimeLength":0,"header":"_sizeSourceTextarea() ","bodySha256":"6f4699af44cae54f1cbb63b881b5db22f1bcdfe0baaa94ae04fe403f269e881a","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:_teardownSourceEl","owner":"index.js","exportSymbol":null,"static":false,"kind":"method","name":"_teardownSourceEl","async":false,"runtimeLength":0,"header":"_teardownSourceEl() ","bodySha256":"c56c77f4664fae69330ff65ff79c789f0ac9fdc70a6867fd4dbfb8da156aa41b","wrapper":null,"wrapperSha256":null},
  {"key":"instance:method:applyServerBlocksIfIdle","owner":"canvas-server.js","exportSymbol":"applyServerBlocksIfIdle","static":false,"kind":"method","name":"applyServerBlocksIfIdle","async":false,"runtimeLength":1,"header":"applyServerBlocksIfIdle(blocks) ","bodySha256":"3b370888ce3d1d1699a9a1007f6a86f6fdfb59a765f60662520aa5c945c8645f","wrapper":"  applyServerBlocksIfIdle(blocks) { return serverMethods.applyServerBlocksIfIdle.call(this, ...arguments); }","wrapperSha256":"f7ebe29c451573d509e111fa9a2630d19ff388bea335e7955b7fa0ea05c37b93"},
  {"key":"instance:method:applyServerBlocks","owner":"canvas-server.js","exportSymbol":"applyServerBlocks","static":false,"kind":"method","name":"applyServerBlocks","async":false,"runtimeLength":1,"header":"applyServerBlocks(blocks, echoMeta = null) ","bodySha256":"0f97d3857cd754bce507c72f9c3ea2f862d3678faa6ee2c537211cb1859fdcfc","wrapper":"  applyServerBlocks(blocks, echoMeta = null) { return serverMethods.applyServerBlocks.call(this, ...arguments); }","wrapperSha256":"bb33b08625189229a8e1b548d92004b93ce2dd2035fe88418a95a4158027101d"},
  {"key":"instance:method:_stampOwnEchoIds","owner":"canvas-server.js","exportSymbol":"_stampOwnEchoIds","static":false,"kind":"method","name":"_stampOwnEchoIds","async":false,"runtimeLength":2,"header":"_stampOwnEchoIds(idWrites, serverBlocks) ","bodySha256":"fb366a96e4dd8197997c94ca1e85f8093c9d1d8a1b55503798712d265194a4f4","wrapper":"  _stampOwnEchoIds(idWrites, serverBlocks) { return serverMethods._stampOwnEchoIds.call(this, ...arguments); }","wrapperSha256":"af328dd3ee6303ae6d7bf264c37929bb622357f0f6fb333f8b6df142fd82d779"},
  {"key":"instance:method:_stampMaterializedIds","owner":"canvas-server.js","exportSymbol":"_stampMaterializedIds","static":false,"kind":"method","name":"_stampMaterializedIds","async":false,"runtimeLength":2,"header":"_stampMaterializedIds(stableDoc, nextDoc, { dryRun = false } = {}) ","bodySha256":"b8436805fd32bb4fe9c0f6089c41d994b07c768882e939aa180d088b0eaf5e46","wrapper":"  _stampMaterializedIds(stableDoc, nextDoc, { dryRun = false } = {}) {\n    return serverMethods._stampMaterializedIds.call(this, ...arguments);\n  }","wrapperSha256":"10333542a6661252c3abfea99bc2c74443030e9633ea675a9d7813c33c1140c5"},
  {"key":"instance:method:_isEditingNow","owner":"canvas-server.js","exportSymbol":"_isEditingNow","static":false,"kind":"method","name":"_isEditingNow","async":false,"runtimeLength":0,"header":"_isEditingNow() ","bodySha256":"e909d692d10442a5c611cd6fb24045157aa01dbbdbdea9353bb1ce8ebfde52d3","wrapper":"  _isEditingNow() { return serverMethods._isEditingNow.call(this, ...arguments); }","wrapperSha256":"d3510dd4747afc6e30edcef86fa734fd4ed74bb4264bb6a0df58c79f5d3e0779"},
  {"key":"instance:method:_applyExternalContent","owner":"canvas-server.js","exportSymbol":"_applyExternalContent","static":false,"kind":"method","name":"_applyExternalContent","async":false,"runtimeLength":1,"header":"_applyExternalContent(blocks) ","bodySha256":"24e00914b4c67c4ae98af6eccafa1c04dd29b29722e9f48ebe00213ec67f9438","wrapper":"  _applyExternalContent(blocks) { return serverMethods._applyExternalContent.call(this, ...arguments); }","wrapperSha256":"a02ef9acc359db9b6f2cd35229e60e7d4893ba375711a33306274c407230a712"},
  {"key":"instance:method:_captureCaret","owner":"canvas-focus.js","exportSymbol":"_captureCaret","static":false,"kind":"method","name":"_captureCaret","async":false,"runtimeLength":0,"header":"_captureCaret() ","bodySha256":"8dbbc21eed8abe28c8c25445664e2fc8877a3542c66e1e2b4e879f4b64e4b417","wrapper":"  _captureCaret() { return focusMethods._captureCaret.call(this, ...arguments); }","wrapperSha256":"e5ceeeba30eb13adec9dc16396c4f5768dc8214d4e075f12f90642e8e4418125"},
  {"key":"instance:method:_restoreCaret","owner":"canvas-focus.js","exportSymbol":"_restoreCaret","static":false,"kind":"method","name":"_restoreCaret","async":false,"runtimeLength":1,"header":"_restoreCaret(caret) ","bodySha256":"a110b677a2e2a551f8a4e6315b102823e89f4d26c48d0b077fd35f6cf0a5750f","wrapper":"  _restoreCaret(caret) { return focusMethods._restoreCaret.call(this, ...arguments); }","wrapperSha256":"e47cc8c70782a6786ac30f6a268c9d4e4d782f731e326bc8de5b46213ff880f0"},
  {"key":"instance:method:_restSelectionOffAtom","owner":"canvas-focus.js","exportSymbol":"_restSelectionOffAtom","static":false,"kind":"method","name":"_restSelectionOffAtom","async":false,"runtimeLength":0,"header":"_restSelectionOffAtom() ","bodySha256":"df5c6eb692e002ab7101fb50c5c352ae9a0a14a49904c281cec7a962e270041d","wrapper":"  _restSelectionOffAtom() { return focusMethods._restSelectionOffAtom.call(this, ...arguments); }","wrapperSha256":"20ad0204bf1dbc0d88a9c71d3115aacf07c4d4c45081c41da5bb8ad591ce1940"},
  {"key":"instance:method:focusBlock","owner":"canvas-focus.js","exportSymbol":"focusBlock","static":false,"kind":"method","name":"focusBlock","async":false,"runtimeLength":1,"header":"focusBlock(id) ","bodySha256":"4786a31c22d80432fe196bd4af73f65403352ada6e44ee4619f557a76956342d","wrapper":"  focusBlock(id) { return focusMethods.focusBlock.call(this, ...arguments); }","wrapperSha256":"8e5c931062e7440a4af0e84075a29e659a4b23183faa1d944d68ae7eb6ba6013"},
  {"key":"instance:method:selectBlock","owner":"canvas-focus.js","exportSymbol":"selectBlock","static":false,"kind":"method","name":"selectBlock","async":false,"runtimeLength":1,"header":"selectBlock(id) ","bodySha256":"747c076c59b75585c8e555acc1de3cf426fe40cd3cac152b230ddf66f8d07a53","wrapper":"  selectBlock(id) { return focusMethods.selectBlock.call(this, ...arguments); }","wrapperSha256":"ea9c95d397c1990ff0e2c9a980aa4e35cdb74e3221e4992360fb9b67dd5e4003"},
  {"key":"instance:method:_enterFromLockedTitle","owner":"canvas-focus.js","exportSymbol":"_enterFromLockedTitle","static":false,"kind":"method","name":"_enterFromLockedTitle","async":false,"runtimeLength":0,"header":"_enterFromLockedTitle() ","bodySha256":"906225173be3009564644b8e3925af17dd86eda94ef61ea4ba60de597951f31b","wrapper":"  _enterFromLockedTitle() { return focusMethods._enterFromLockedTitle.call(this, ...arguments); }","wrapperSha256":"195a8957e0e06ebb490f0cdaad03397b73e961afa0ef296da41ba7adfd4fdb78"},
  {"key":"instance:method:_focusBodyFrom","owner":"canvas-focus.js","exportSymbol":"_focusBodyFrom","static":false,"kind":"method","name":"_focusBodyFrom","async":false,"runtimeLength":0,"header":"_focusBodyFrom(startIndex = 0) ","bodySha256":"4bb72e9c566ba1c8670f2abd218a8b10511c154eca9fbda1fc92fc1a80112de5","wrapper":"  _focusBodyFrom(startIndex = 0) { return focusMethods._focusBodyFrom.call(this, ...arguments); }","wrapperSha256":"af19cbf7c4e2def526ac8067c40aafed93d718bba7e395f02a395ce785271165"},
  {"key":"instance:method:focusSelection","owner":"canvas-focus.js","exportSymbol":"focusSelection","static":false,"kind":"method","name":"focusSelection","async":false,"runtimeLength":0,"header":"focusSelection() ","bodySha256":"7a4ef50504ecaca3b0cbdd0a958a54f3cecd54bad886369095df5d1354569859","wrapper":"  focusSelection() { return focusMethods.focusSelection.call(this, ...arguments); }","wrapperSha256":"113304c05d36008e828781ad1f98cf1539397b704279a13be1fe6897b654c30f"},
  {"key":"instance:method:focusFirstBodyBlock","owner":"canvas-focus.js","exportSymbol":"focusFirstBodyBlock","static":false,"kind":"method","name":"focusFirstBodyBlock","async":false,"runtimeLength":0,"header":"focusFirstBodyBlock() ","bodySha256":"407b2bb5b6577b3882167db46ac14c50a926e1dd7e7037941b9774a1bf694864","wrapper":"  focusFirstBodyBlock() { return focusMethods.focusFirstBodyBlock.call(this, ...arguments); }","wrapperSha256":"43a371999da7f70954a512e249aabd6b4c8a22989623aaec6f0fab57ec643d7d"},
  {"key":"instance:method:_focusBodyAfterRun","owner":"canvas-focus.js","exportSymbol":"_focusBodyAfterRun","static":false,"kind":"method","name":"_focusBodyAfterRun","async":false,"runtimeLength":0,"header":"_focusBodyAfterRun() ","bodySha256":"791d34e10b7e800fec61c49bc0d7a6abeb1af8e7023b67088931c11bbe915246","wrapper":"  _focusBodyAfterRun() { return focusMethods._focusBodyAfterRun.call(this, ...arguments); }","wrapperSha256":"d32b57e764afa10d28a3ebc0b9b5740e6f0381510069b47ec19542a0c713298c"},
  {"key":"instance:method:_topLevelPos","owner":"canvas-focus.js","exportSymbol":"_topLevelPos","static":false,"kind":"method","name":"_topLevelPos","async":false,"runtimeLength":1,"header":"_topLevelPos(id) ","bodySha256":"07c66e7c1ef86dc54066afca34de070dc827a0b358fe4f962294ff9b3f46ee06","wrapper":"  _topLevelPos(id) { return focusMethods._topLevelPos.call(this, ...arguments); }","wrapperSha256":"a5c465c070f1d2b7210e7070e52f8d7e5d2b677be2023e4eaeeada3eefd93ad6"},
  {"key":"instance:method:_consumePendingFocus","owner":"canvas-focus.js","exportSymbol":"_consumePendingFocus","static":false,"kind":"method","name":"_consumePendingFocus","async":false,"runtimeLength":0,"header":"_consumePendingFocus() ","bodySha256":"c1b84e3ce897ca95bf8d146131e449eb84858169d3095197515824ac2aa8c3a5","wrapper":"  _consumePendingFocus() { return focusMethods._consumePendingFocus.call(this, ...arguments); }","wrapperSha256":"24e7b690b0044057a0826e21105e13975b9262f964e2a4b43b91a7c3a78433d5"},
  {"key":"instance:method:_takeServerBlocks","owner":"canvas-server.js","exportSymbol":"_takeServerBlocks","static":false,"kind":"method","name":"_takeServerBlocks","async":false,"runtimeLength":1,"header":"_takeServerBlocks(remote) ","bodySha256":"14cf59fc32d9e88cc8efcf20bf7263985ad9f53a2a41e2a803dd8cc50d292e6e","wrapper":"  _takeServerBlocks(remote) { return serverMethods._takeServerBlocks.call(this, ...arguments); }","wrapperSha256":"e006943b2ee733382d9561ec0b62061cd0ed149b7ebd18dd1b0aa64525c9e108"},
  {"key":"instance:method:_mergePendingServerBlocks","owner":"canvas-server.js","exportSymbol":"_mergePendingServerBlocks","static":false,"kind":"method","name":"_mergePendingServerBlocks","async":false,"runtimeLength":0,"header":"_mergePendingServerBlocks() ","bodySha256":"efc70e1e302da9f876041849412e0b1900491546a0af3b20ac215aeb8251f41b","wrapper":"  _mergePendingServerBlocks() { return serverMethods._mergePendingServerBlocks.call(this, ...arguments); }","wrapperSha256":"fcdf15130c477873a64adf813f3996251b011db79a1635a201a883290efcfc17"},
  {"key":"instance:method:_canMergeRemote","owner":"canvas-server.js","exportSymbol":"_canMergeRemote","static":false,"kind":"method","name":"_canMergeRemote","async":false,"runtimeLength":0,"header":"_canMergeRemote() ","bodySha256":"1083c76499fe221964876de4107cf1b5a0c6cc9cec3f3f83b7e064a3f5b97e5e","wrapper":"  _canMergeRemote() { return serverMethods._canMergeRemote.call(this, ...arguments); }","wrapperSha256":"d496ddb652c19e5e606fc2f101ee7d3f299d666014fa42c8746148a154af3e86"},
  {"key":"instance:method:_mergeRemote","owner":"canvas-server.js","exportSymbol":"_mergeRemote","static":false,"kind":"method","name":"_mergeRemote","async":false,"runtimeLength":1,"header":"_mergeRemote(remote) ","bodySha256":"e36470dd997545037bb86553212faeadc2597044150a9fa12ae092cf7eb74d9a","wrapper":"  _mergeRemote(remote) { return serverMethods._mergeRemote.call(this, ...arguments); }","wrapperSha256":"94f016df3e8e4506ce8e806ea1948b397826dcb307a9410ef4a0d2b82c144f0f"},
  {"key":"instance:method:_applyWholeSnapshot","owner":"canvas-server.js","exportSymbol":"_applyWholeSnapshot","static":false,"kind":"method","name":"_applyWholeSnapshot","async":false,"runtimeLength":1,"header":"_applyWholeSnapshot(remote) ","bodySha256":"4fb5aa92472e6da9e80e47f3d6c402dc3fb6badc9c6d68b0829dac236fa551b1","wrapper":"  _applyWholeSnapshot(remote) { return serverMethods._applyWholeSnapshot.call(this, ...arguments); }","wrapperSha256":"01a729aec11dd207309940bbca368dfb570a95717bd4b394147b2202db46cbf0"},
  {"key":"instance:method:_caretBlockIndexes","owner":"canvas-server.js","exportSymbol":"_caretBlockIndexes","static":false,"kind":"method","name":"_caretBlockIndexes","async":false,"runtimeLength":0,"header":"_caretBlockIndexes() ","bodySha256":"2239aa41aa1ca6a75b7ac185e0fdcec046a25f4bbf021962a1decaff8d0191ad","wrapper":"  _caretBlockIndexes() { return serverMethods._caretBlockIndexes.call(this, ...arguments); }","wrapperSha256":"859dad9bcc95a420e3a47562517620ee445e1061ee61e6a510f5b3c100e0363c"},
  {"key":"instance:method:_reportHeld","owner":"canvas-server.js","exportSymbol":"_reportHeld","static":false,"kind":"method","name":"_reportHeld","async":false,"runtimeLength":1,"header":"_reportHeld(held) ","bodySha256":"de9c71b1020ebb97edee36bf8ab875c6ef9b8e1a9bc9ffa90116c63a181aad5d","wrapper":"  _reportHeld(held) { return serverMethods._reportHeld.call(this, ...arguments); }","wrapperSha256":"d0c1234cd6d91bb45a63bc30f676be3506b48284dc8179a7d5646660f58c07c7"},
  {"key":"instance:method:_queueServerBlocks","owner":"canvas-server.js","exportSymbol":"_queueServerBlocks","static":false,"kind":"method","name":"_queueServerBlocks","async":false,"runtimeLength":1,"header":"_queueServerBlocks(blocks) ","bodySha256":"4b718298158a020bad844f28b5b5cb9d1e9a7a201fe2811105161583819406a8","wrapper":"  _queueServerBlocks(blocks) { return serverMethods._queueServerBlocks.call(this, ...arguments); }","wrapperSha256":"824c2e8fe1d3b81ee7644041fcd05b94d2fd6ebd21256a611a16bb33a17c812e"},
  {"key":"instance:method:_flushPendingServerBlocks","owner":"canvas-server.js","exportSymbol":"_flushPendingServerBlocks","static":false,"kind":"method","name":"_flushPendingServerBlocks","async":false,"runtimeLength":0,"header":"_flushPendingServerBlocks() ","bodySha256":"71c49269a64abee87e488f7f8135a9f2d1d14a6ed9b74113f64f8fe9a9343195","wrapper":"  _flushPendingServerBlocks() { return serverMethods._flushPendingServerBlocks.call(this, ...arguments); }","wrapperSha256":"7adbb8f696d8c93d06c9992c1f9d2d471ef45d0c60022cfaceabe764a26e1b9d"},
  {"key":"instance:method:_clearPendingServerBlocks","owner":"canvas-server.js","exportSymbol":"_clearPendingServerBlocks","static":false,"kind":"method","name":"_clearPendingServerBlocks","async":false,"runtimeLength":0,"header":"_clearPendingServerBlocks() ","bodySha256":"2a03c4e9a38090431fc24c046afa02c2cfb824aaaab308b59726b5a92ae3d092","wrapper":"  _clearPendingServerBlocks() { return serverMethods._clearPendingServerBlocks.call(this, ...arguments); }","wrapperSha256":"b51d6ead407d47ce11f639438d02dcb7368c00e490ebc0c641e1eb815a466023"},
  {"key":"instance:method:_upgradeProperty","owner":"canvas-lifecycle.js","exportSymbol":"_upgradeProperty","static":false,"kind":"method","name":"_upgradeProperty","async":false,"runtimeLength":1,"header":"_upgradeProperty(name) ","bodySha256":"53f95797fd38ffb28545ed62c83b0ee7cb9bafa0399117610c15e4faad606aa6","wrapper":"  _upgradeProperty(name) { return lifecycleMethods._upgradeProperty.call(this, ...arguments); }","wrapperSha256":"1879576a8add395c62754685e726910b5b877efb406ee71bb22fcd6aa8610c61"},
  {"key":"instance:set:blocks","owner":"canvas-lifecycle.js","exportSymbol":"setBlocks","static":false,"kind":"set","name":"blocks","async":false,"runtimeLength":1,"header":"set blocks(value) ","bodySha256":"66156814631626289d27b46e61491d19277b98b3103e9617d766d0ec28ccb494","wrapper":"  set blocks(value) { return lifecycleMethods.setBlocks.call(this, ...arguments); }","wrapperSha256":"80e756ed004ad133872b9721d9dbb03b646945ccaa0fff6bf6a910c54b5c8702"},
  {"key":"instance:method:_createEditorSafely","owner":"canvas-lifecycle.js","exportSymbol":"_createEditorSafely","static":false,"kind":"method","name":"_createEditorSafely","async":false,"runtimeLength":1,"header":"_createEditorSafely(factory) ","bodySha256":"d85f0631f06057c4b51c3b367277d4fe7b88a0f40d9b44c12156142230891a1b","wrapper":"  _createEditorSafely(factory) { return lifecycleMethods._createEditorSafely.call(this, ...arguments); }","wrapperSha256":"a409cb1e9a99907097a6982cf82d38319402dacf7ec907f9bf2b3e6eb8de6c6b"},
  {"key":"instance:method:_verifyPainted","owner":"canvas-lifecycle.js","exportSymbol":"_verifyPainted","static":false,"kind":"method","name":"_verifyPainted","async":false,"runtimeLength":1,"header":"_verifyPainted(stage) ","bodySha256":"79d03b6d2dd5e2383c0edb3b8d74f70c7ba539380ba6f2c4cc029a14ebb790eb","wrapper":"  _verifyPainted(stage) { return lifecycleMethods._verifyPainted.call(this, ...arguments); }","wrapperSha256":"287fb542154015f1e5a2132c782081152bdc4792a55c8c8756edaf4ba17af232"},
  {"key":"instance:method:_failMount","owner":"canvas-lifecycle.js","exportSymbol":"_failMount","static":false,"kind":"method","name":"_failMount","async":false,"runtimeLength":2,"header":"_failMount(stage, error) ","bodySha256":"169a7f2395efdb5d4c8516785aedad482c4c5a79ccadead4f6b642310fd8aedd","wrapper":"  _failMount(stage, error) { return lifecycleMethods._failMount.call(this, ...arguments); }","wrapperSha256":"4fc307b88fffaf3bb3a86babcd0edf452a04ac50c09d7275c74eb68ba3dc9550"},
  {"key":"instance:get:blocks","owner":"canvas-lifecycle.js","exportSymbol":"getBlocks","static":false,"kind":"get","name":"blocks","async":false,"runtimeLength":0,"header":"get blocks() ","bodySha256":"187d861788614314d386b1261dd9f06bd3f762d46ac42cda5d67c7eaadeeba9f","wrapper":"  get blocks() { return lifecycleMethods.getBlocks.call(this, ...arguments); }","wrapperSha256":"3475abe6041d859679811daa3d265dd27efde7cd9268f9ddc63123d98c76358f"},
  {"key":"instance:set:acknowledgedSaves","owner":"canvas-lifecycle.js","exportSymbol":"setAcknowledgedSaves","static":false,"kind":"set","name":"acknowledgedSaves","async":false,"runtimeLength":1,"header":"set acknowledgedSaves(value) ","bodySha256":"73f7853bba3feb5b9eb307b578b4fd809e184681e37d5be29ac85fe721bd0aed","wrapper":"  set acknowledgedSaves(value) { return lifecycleMethods.setAcknowledgedSaves.call(this, ...arguments); }","wrapperSha256":"d393bc76db66f14912eb5111a8effe48bebde45bf7eda2cc40f9c0dc70e8fd1f"},
  {"key":"instance:set:liveRemote","owner":"canvas-lifecycle.js","exportSymbol":"setLiveRemote","static":false,"kind":"set","name":"liveRemote","async":false,"runtimeLength":1,"header":"set liveRemote(value) ","bodySha256":"e6d77f1637ba37d29a0e751f480c914729a565c02871cbf43b320f9b8b4639e7","wrapper":"  set liveRemote(value) { return lifecycleMethods.setLiveRemote.call(this, ...arguments); }","wrapperSha256":"353c6a8d09bf987c8d16193a777e42e5a3a58dfe39024069c0ead8c395975d94"},
  {"key":"instance:get:liveRemote","owner":"canvas-lifecycle.js","exportSymbol":"getLiveRemote","static":false,"kind":"get","name":"liveRemote","async":false,"runtimeLength":0,"header":"get liveRemote() ","bodySha256":"e5b80c9adcd19f86e64abdfb71604df496153da079bbb0ea1577ff402669a612","wrapper":"  get liveRemote() { return lifecycleMethods.getLiveRemote.call(this, ...arguments); }","wrapperSha256":"c7047ebf5c0eca18607540dde8fc4be20e25b8f90a9bf81f13b4cc5647ae635a"},
  {"key":"instance:set:flushKeepsSource","owner":"canvas-lifecycle.js","exportSymbol":"setFlushKeepsSource","static":false,"kind":"set","name":"flushKeepsSource","async":false,"runtimeLength":1,"header":"set flushKeepsSource(value) ","bodySha256":"33b28932f961452bdf532158adaf15b427af8672bfa6d4a336b3ea2d61330fe9","wrapper":"  set flushKeepsSource(value) { return lifecycleMethods.setFlushKeepsSource.call(this, ...arguments); }","wrapperSha256":"f7ff3bbc0deb2b67631fa205ccac64bbadca209c2332518c5e7587bff1ff814a"},
  {"key":"instance:get:flushKeepsSource","owner":"canvas-lifecycle.js","exportSymbol":"getFlushKeepsSource","static":false,"kind":"get","name":"flushKeepsSource","async":false,"runtimeLength":0,"header":"get flushKeepsSource() ","bodySha256":"e41404002d4382ab4cb8c304f4f573780e478182e681d183b796f7a7cae58736","wrapper":"  get flushKeepsSource() { return lifecycleMethods.getFlushKeepsSource.call(this, ...arguments); }","wrapperSha256":"0255a17c8ccfa5e681f39ab30f2738e75b4a6fb2a0314a11c1329025019671d1"},
  {"key":"instance:get:acknowledgedSaves","owner":"canvas-lifecycle.js","exportSymbol":"getAcknowledgedSaves","static":false,"kind":"get","name":"acknowledgedSaves","async":false,"runtimeLength":0,"header":"get acknowledgedSaves() ","bodySha256":"c00f5ed824c320bd72bb29bba1b07bf970a5e7d3ca7be816b8e3bb665582b062","wrapper":"  get acknowledgedSaves() { return lifecycleMethods.getAcknowledgedSaves.call(this, ...arguments); }","wrapperSha256":"d127bd2ef63fea2828d74ad82a2ca5f4f9e9aee33db3c89204b466fe6a30bc4a"},
];
const IMPORTS = [
  {"consumer":"canvas-document.js","source":"./inline-object.js","kind":"named","imported":"editInlineObjectAt","local":"editInlineObjectAt"},
  {"consumer":"canvas-document.js","source":"./inline-object.js","kind":"named","imported":"editObjectBlockAt","local":"editObjectBlockAt"},
  {"consumer":"canvas-document.js","source":"./inline-object.js","kind":"named","imported":"HostObjectDialog","local":"HostObjectDialog"},
  {"consumer":"canvas-document.js","source":"./inline-object.js","kind":"named","imported":"InlineObjectDialog","local":"InlineObjectDialog"},
  {"consumer":"canvas-document.js","source":"./inline-object.js","kind":"named","imported":"refusalField","local":"refusalField"},
  {"consumer":"canvas-document.js","source":"./run-convert.js","kind":"named","imported":"blockParents","local":"blockParents"},
  {"consumer":"canvas-document.js","source":"./run-convert.js","kind":"named","imported":"holdsNodeIds","local":"holdsNodeIds"},
  {"consumer":"canvas-document.js","source":"./run-convert.js","kind":"named","imported":"reconcileServerEcho","local":"reconcileServerEcho"},
  {"consumer":"canvas-document.js","source":"./run-convert.js","kind":"named","imported":"runToOps","local":"runToOps"},
  {"consumer":"canvas-document.js","source":"./run-convert.js","kind":"named","imported":"runToTiptap","local":"runToTiptap"},
  {"consumer":"canvas-document.js","source":"./run-convert.js","kind":"named","imported":"withObjectOverrides","local":"withObjectOverrides"},
  {"consumer":"canvas-document.js","source":"./vocabulary.js","kind":"named","imported":"parseVocabulary","local":"parseVocabulary"},
  {"consumer":"canvas-document.js","source":"@tiptap/pm/model","kind":"named","imported":"Fragment","local":"Fragment"},
  {"consumer":"canvas-document.js","source":"@tiptap/pm/model","kind":"named","imported":"Mark","local":"Mark"},
  {"consumer":"canvas-editor-policy.js","source":"./figure-context.js","kind":"named","imported":"isFigureSingletonCanvas","local":"isFigureSingletonCanvas"},
  {"consumer":"canvas-editor-policy.js","source":"@tiptap/core","kind":"named","imported":"Extension","local":"Extension"},
  {"consumer":"canvas-editor-policy.js","source":"@tiptap/extension-text-align","kind":"default","imported":"default","local":"TextAlign"},
  {"consumer":"canvas-editor-policy.js","source":"@tiptap/pm/model","kind":"named","imported":"DOMParser","local":"PMDOMParser"},
  {"consumer":"canvas-editor-policy.js","source":"@tiptap/pm/state","kind":"named","imported":"Plugin","local":"Plugin"},
  {"consumer":"canvas-editor-schema.js","source":"../contract.js","kind":"named","imported":"PLACEHOLDER","local":"PLACEHOLDER"},
  {"consumer":"canvas-editor-schema.js","source":"../heading-source.js","kind":"named","imported":"HeadingSource","local":"HeadingSource"},
  {"consumer":"canvas-editor-schema.js","source":"../i18n.js","kind":"named","imported":"t","local":"t"},
  {"consumer":"canvas-editor-schema.js","source":"../link-mark.js","kind":"named","imported":"PortableLink","local":"Link"},
  {"consumer":"canvas-editor-schema.js","source":"../list-item-source.js","kind":"named","imported":"ListItemSource","local":"ListItemSource"},
  {"consumer":"canvas-editor-schema.js","source":"../marks.js","kind":"named","imported":"Blockref","local":"Blockref"},
  {"consumer":"canvas-editor-schema.js","source":"../marks.js","kind":"named","imported":"InlineOpaque","local":"InlineOpaque"},
  {"consumer":"canvas-editor-schema.js","source":"../marks.js","kind":"named","imported":"Tag","local":"Tag"},
  {"consumer":"canvas-editor-schema.js","source":"../marks.js","kind":"named","imported":"Valueref","local":"Valueref"},
  {"consumer":"canvas-editor-schema.js","source":"../marks.js","kind":"named","imported":"Wikilink","local":"Wikilink"},
  {"consumer":"canvas-editor-schema.js","source":"../opaque-mark.js","kind":"named","imported":"OpaqueMark","local":"OpaqueMark"},
  {"consumer":"canvas-editor-schema.js","source":"../paragraph-source.js","kind":"named","imported":"ParagraphSource","local":"ParagraphSource"},
  {"consumer":"canvas-editor-schema.js","source":"../portable-text-boundary.js","kind":"named","imported":"portableTextBoundary","local":"portableTextBoundary"},
  {"consumer":"canvas-editor-schema.js","source":"./action-node.js","kind":"named","imported":"Action","local":"Action"},
  {"consumer":"canvas-editor-schema.js","source":"./block-boundary.js","kind":"named","imported":"BlockBoundary","local":"BlockBoundary"},
  {"consumer":"canvas-editor-schema.js","source":"./bp-attrs.js","kind":"named","imported":"BpAttrs","local":"BpAttrs"},
  {"consumer":"canvas-editor-schema.js","source":"./callout-node.js","kind":"named","imported":"Callout","local":"Callout"},
  {"consumer":"canvas-editor-schema.js","source":"./canvas-editor-policy.js","kind":"named","imported":"ownDomReadback","local":"ownDomReadback"},
  {"consumer":"canvas-editor-schema.js","source":"./canvas-editor-policy.js","kind":"named","imported":"ReaderTextAlign","local":"ReaderTextAlign"},
  {"consumer":"canvas-editor-schema.js","source":"./canvas-editor-policy.js","kind":"named","imported":"transactionVetoesFigureSingleton","local":"transactionVetoesFigureSingleton"},
  {"consumer":"canvas-editor-schema.js","source":"./card-menu.js","kind":"named","imported":"CardKeys","local":"CardKeys"},
  {"consumer":"canvas-editor-schema.js","source":"./card-node.js","kind":"named","imported":"Card","local":"Card"},
  {"consumer":"canvas-editor-schema.js","source":"./caret-before-keys.js","kind":"named","imported":"CaretBeforeKeys","local":"CaretBeforeKeys"},
  {"consumer":"canvas-editor-schema.js","source":"./clipboard-paste-policy.js","kind":"named","imported":"stripPastedImages","local":"stripPastedImages"},
  {"consumer":"canvas-editor-schema.js","source":"./clipboard-slice.js","kind":"named","imported":"exactClipboardSerializer","local":"exactClipboardSerializer"},
  {"consumer":"canvas-editor-schema.js","source":"./clipboard-slice.js","kind":"named","imported":"sliceWithFreshIds","local":"sliceWithFreshIds"},
  {"consumer":"canvas-editor-schema.js","source":"./code-node.js","kind":"named","imported":"Code","local":"Code"},
  {"consumer":"canvas-editor-schema.js","source":"./columns-node.js","kind":"named","imported":"ColumnAtom","local":"ColumnAtom"},
  {"consumer":"canvas-editor-schema.js","source":"./columns-node.js","kind":"named","imported":"Column","local":"Column"},
  {"consumer":"canvas-editor-schema.js","source":"./columns-node.js","kind":"named","imported":"Columns","local":"Columns"},
  {"consumer":"canvas-editor-schema.js","source":"./comment-ranges.js","kind":"named","imported":"commentRanges","local":"commentRanges"},
  {"consumer":"canvas-editor-schema.js","source":"./constraints.js","kind":"named","imported":"parseConstraints","local":"parseConstraints"},
  {"consumer":"canvas-editor-schema.js","source":"./constraints.js","kind":"named","imported":"transactionVetoesConstraints","local":"transactionVetoesConstraints"},
  {"consumer":"canvas-editor-schema.js","source":"./diagram-node.js","kind":"named","imported":"Diagram","local":"Diagram"},
  {"consumer":"canvas-editor-schema.js","source":"./divider-node.js","kind":"named","imported":"Divider","local":"Divider"},
  {"consumer":"canvas-editor-schema.js","source":"./embed-node.js","kind":"named","imported":"Embed","local":"Embed"},
  {"consumer":"canvas-editor-schema.js","source":"./embed-node.js","kind":"named","imported":"Fleet","local":"Fleet"},
  {"consumer":"canvas-editor-schema.js","source":"./embed-node.js","kind":"named","imported":"Sheet","local":"Sheet"},
  {"consumer":"canvas-editor-schema.js","source":"./expandable-node.js","kind":"named","imported":"Expandable","local":"Expandable"},
  {"consumer":"canvas-editor-schema.js","source":"./field-node.js","kind":"named","imported":"Field","local":"Field"},
  {"consumer":"canvas-editor-schema.js","source":"./figure-node.js","kind":"named","imported":"Figure","local":"Figure"},
  {"consumer":"canvas-editor-schema.js","source":"./find-replace.js","kind":"named","imported":"findReplace","local":"findReplace"},
  {"consumer":"canvas-editor-schema.js","source":"./image-node.js","kind":"named","imported":"Image","local":"Image"},
  {"consumer":"canvas-editor-schema.js","source":"./inline-object.js","kind":"named","imported":"inlineObjects","local":"inlineObjects"},
  {"consumer":"canvas-editor-schema.js","source":"./island-node.js","kind":"named","imported":"Equation","local":"Equation"},
  {"consumer":"canvas-editor-schema.js","source":"./island-node.js","kind":"named","imported":"Footnote","local":"Footnote"},
  {"consumer":"canvas-editor-schema.js","source":"./island-node.js","kind":"named","imported":"Toc","local":"Toc"},
  {"consumer":"canvas-editor-schema.js","source":"./island-node.js","kind":"named","imported":"Video","local":"Video"},
  {"consumer":"canvas-editor-schema.js","source":"./locks.js","kind":"named","imported":"isLockedTitle","local":"isLockedTitle"},
  {"consumer":"canvas-editor-schema.js","source":"./locks.js","kind":"named","imported":"transactionVetoesLock","local":"transactionVetoesLock"},
  {"consumer":"canvas-editor-schema.js","source":"./note-node.js","kind":"named","imported":"Note","local":"Note"},
  {"consumer":"canvas-editor-schema.js","source":"./opaque-node.js","kind":"named","imported":"Opaque","local":"Opaque"},
  {"consumer":"canvas-editor-schema.js","source":"./paste-html.js","kind":"named","imported":"cleanPastedHTML","local":"cleanPastedHTML"},
  {"consumer":"canvas-editor-schema.js","source":"./remote-selections.js","kind":"named","imported":"remoteSelections","local":"remoteSelections"},
  {"consumer":"canvas-editor-schema.js","source":"./resting-scaffolds.js","kind":"named","imported":"restingScaffolds","local":"restingScaffolds"},
  {"consumer":"canvas-editor-schema.js","source":"./resting-selection.js","kind":"named","imported":"RestingSelection","local":"RestingSelection"},
  {"consumer":"canvas-editor-schema.js","source":"./role-nodes.js","kind":"named","imported":"Blockquote","local":"Blockquote"},
  {"consumer":"canvas-editor-schema.js","source":"./role-nodes.js","kind":"named","imported":"Byline","local":"Byline"},
  {"consumer":"canvas-editor-schema.js","source":"./role-nodes.js","kind":"named","imported":"Eyebrow","local":"Eyebrow"},
  {"consumer":"canvas-editor-schema.js","source":"./role-nodes.js","kind":"named","imported":"Ingress","local":"Ingress"},
  {"consumer":"canvas-editor-schema.js","source":"./role-nodes.js","kind":"named","imported":"Pullquote","local":"Pullquote"},
  {"consumer":"canvas-editor-schema.js","source":"./rows-node.js","kind":"named","imported":"Steps","local":"Steps"},
  {"consumer":"canvas-editor-schema.js","source":"./rows-node.js","kind":"named","imported":"Step","local":"Step"},
  {"consumer":"canvas-editor-schema.js","source":"./rows-node.js","kind":"named","imported":"Tabs","local":"Tabs"},
  {"consumer":"canvas-editor-schema.js","source":"./rows-node.js","kind":"named","imported":"Tab","local":"Tab"},
  {"consumer":"canvas-editor-schema.js","source":"./section-node.js","kind":"named","imported":"Section","local":"Section"},
  {"consumer":"canvas-editor-schema.js","source":"./stage-node.js","kind":"named","imported":"Stage","local":"Stage"},
  {"consumer":"canvas-editor-schema.js","source":"./table-node.js","kind":"named","imported":"BpTable","local":"BpTable"},
  {"consumer":"canvas-editor-schema.js","source":"./table-node.js","kind":"named","imported":"BpTableCell","local":"BpTableCell"},
  {"consumer":"canvas-editor-schema.js","source":"./table-node.js","kind":"named","imported":"BpTableHeaderCell","local":"BpTableHeaderCell"},
  {"consumer":"canvas-editor-schema.js","source":"./table-node.js","kind":"named","imported":"BpTableRow","local":"BpTableRow"},
  {"consumer":"canvas-editor-schema.js","source":"./task-list-node.js","kind":"named","imported":"TaskList","local":"TaskList"},
  {"consumer":"canvas-editor-schema.js","source":"./technical-node.js","kind":"named","imported":"Diff","local":"Diff"},
  {"consumer":"canvas-editor-schema.js","source":"./technical-node.js","kind":"named","imported":"Filetree","local":"Filetree"},
  {"consumer":"canvas-editor-schema.js","source":"./terminal-node.js","kind":"named","imported":"TerminalAtom","local":"TerminalAtom"},
  {"consumer":"canvas-editor-schema.js","source":"./terminal-node.js","kind":"named","imported":"Terminal","local":"Terminal"},
  {"consumer":"canvas-editor-schema.js","source":"./vocabulary.js","kind":"named","imported":"parseVocabulary","local":"parseVocabulary"},
  {"consumer":"canvas-editor-schema.js","source":"./vocabulary.js","kind":"named","imported":"transactionVetoesVocabulary","local":"transactionVetoesVocabulary"},
  {"consumer":"canvas-editor-schema.js","source":"./wikilink-input.js","kind":"named","imported":"wikilinkInput","local":"wikilinkInput"},
  {"consumer":"canvas-editor-schema.js","source":"./wikilink-titles.js","kind":"named","imported":"wikilinkTitles","local":"wikilinkTitles"},
  {"consumer":"canvas-editor-schema.js","source":"./word-paste.js","kind":"named","imported":"normalizeWordListHTML","local":"normalizeWordListHTML"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/core","kind":"named","imported":"Editor","local":"Editor"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/core","kind":"named","imported":"Extension","local":"Extension"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-highlight","kind":"default","imported":"default","local":"Highlight"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-placeholder","kind":"default","imported":"default","local":"Placeholder"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-subscript","kind":"default","imported":"default","local":"Subscript"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-superscript","kind":"default","imported":"default","local":"Superscript"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-task-item","kind":"default","imported":"default","local":"TaskItem"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-task-list","kind":"default","imported":"default","local":"TiptapTaskList"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-typography","kind":"default","imported":"default","local":"Typography"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/extension-underline","kind":"default","imported":"default","local":"Underline"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/pm/state","kind":"named","imported":"Plugin","local":"Plugin"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/pm/view","kind":"named","imported":"Decoration","local":"Decoration"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/pm/view","kind":"named","imported":"DecorationSet","local":"DecorationSet"},
  {"consumer":"canvas-editor-schema.js","source":"@tiptap/starter-kit","kind":"default","imported":"default","local":"StarterKit"},
  {"consumer":"canvas-focus.js","source":"./locks.js","kind":"named","imported":"isLockedTitle","local":"isLockedTitle"},
  {"consumer":"canvas-focus.js","source":"@tiptap/pm/state","kind":"named","imported":"NodeSelection","local":"NodeSelection"},
  {"consumer":"canvas-focus.js","source":"@tiptap/pm/state","kind":"named","imported":"Selection","local":"Selection"},
  {"consumer":"canvas-focus.js","source":"@tiptap/pm/state","kind":"named","imported":"TextSelection","local":"TextSelection"},
  {"consumer":"canvas-lifecycle.js","source":"../format-bubble.js","kind":"named","imported":"FormatBubble","local":"FormatBubble"},
  {"consumer":"canvas-mount.js","source":"../format-bubble.js","kind":"named","imported":"FormatBubble","local":"FormatBubble"},
  {"consumer":"canvas-mount.js","source":"../i18n.js","kind":"named","imported":"loadStringsFrom","local":"loadStringsFrom"},
  {"consumer":"canvas-mount.js","source":"../i18n.js","kind":"named","imported":"t","local":"t"},
  {"consumer":"canvas-mount.js","source":"./block-handle.js","kind":"named","imported":"BlockHandle","local":"BlockHandle"},
  {"consumer":"canvas-mount.js","source":"./canvas-editor-schema.js","kind":"namespace","imported":"*","local":"editorSchema"},
  {"consumer":"canvas-mount.js","source":"./comment-ranges.js","kind":"named","imported":"setCommentRanges","local":"crSet"},
  {"consumer":"canvas-mount.js","source":"./inline-object.js","kind":"named","imported":"canEditObjectBlock","local":"canEditObjectBlock"},
  {"consumer":"canvas-mount.js","source":"./inline-object.js","kind":"named","imported":"editObjectBlockAt","local":"editObjectBlockAt"},
  {"consumer":"canvas-mount.js","source":"./link-preview.js","kind":"named","imported":"LinkPreview","local":"LinkPreview"},
  {"consumer":"canvas-mount.js","source":"./remote-selections.js","kind":"named","imported":"setRemoteSelections","local":"rsSet"},
  {"consumer":"canvas-mount.js","source":"./wikilink-titles.js","kind":"named","imported":"setWikilinkMissing","local":"setWikilinkMissing"},
  {"consumer":"canvas-mount.js","source":"./wikilink-titles.js","kind":"named","imported":"wikilinkInfo","local":"wikilinkInfo"},
  {"consumer":"canvas-ops.js","source":"../contract.js","kind":"named","imported":"DEBOUNCE_MS","local":"DEBOUNCE_MS"},
  {"consumer":"canvas-ops.js","source":"./canvas-document.js","kind":"named","imported":"normalizeCanvasDoc","local":"normalizeCanvasDoc"},
  {"consumer":"canvas-ops.js","source":"./run-convert.js","kind":"named","imported":"docToBlocks","local":"docToBlocks"},
  {"consumer":"canvas-ops.js","source":"./run-convert.js","kind":"named","imported":"hasOverlappingOps","local":"hasOverlappingOps"},
  {"consumer":"canvas-ops.js","source":"./run-convert.js","kind":"named","imported":"opsRebaseSafe","local":"opsRebaseSafe"},
  {"consumer":"canvas-ops.js","source":"./run-convert.js","kind":"named","imported":"pendingUploadIndexes","local":"pendingUploadIndexes"},
  {"consumer":"canvas-ops.js","source":"./source-realign.js","kind":"named","imported":"deepCloneBlocks","local":"deepCloneBlocks"},
  {"consumer":"canvas-server.js","source":"./canvas-document.js","kind":"named","imported":"normalizeCanvasDoc","local":"normalizeCanvasDoc"},
  {"consumer":"canvas-server.js","source":"./canvas-document.js","kind":"named","imported":"replaceTopNode","local":"replaceTopNode"},
  {"consumer":"canvas-server.js","source":"./run-convert.js","kind":"named","imported":"nodeContentEqual","local":"nodeContentEqual"},
  {"consumer":"canvas-server.js","source":"./run-convert.js","kind":"named","imported":"withObjectOverrides","local":"withObjectOverrides"},
  {"consumer":"canvas-server.js","source":"./source-realign.js","kind":"named","imported":"deepCloneBlocks","local":"deepCloneBlocks"},
  {"consumer":"canvas-server.js","source":"@tiptap/pm/state","kind":"named","imported":"TextSelection","local":"TextSelection"},
  {"consumer":"index.js","source":"../contract.js","kind":"named","imported":"BUILD_SHA","local":"BUILD_SHA"},
  {"consumer":"index.js","source":"../contract.js","kind":"named","imported":"CONTRACT_VERSION","local":"CONTRACT_VERSION"},
  {"consumer":"index.js","source":"../contract.js","kind":"named","imported":"EDITOR_VERSION","local":"EDITOR_VERSION"},
  {"consumer":"index.js","source":"../safe-url.js","kind":"named","imported":"safeUrl","local":"safeUrl"},
  {"consumer":"index.js","source":"./canvas-document.js","kind":"namespace","imported":"*","local":"documentMethods"},
  {"consumer":"index.js","source":"./canvas-editor-policy.js","kind":"reexport","imported":"ReaderTextAlign","local":"ReaderTextAlign"},
  {"consumer":"index.js","source":"./canvas-focus.js","kind":"namespace","imported":"*","local":"focusMethods"},
  {"consumer":"index.js","source":"./canvas-lifecycle.js","kind":"namespace","imported":"*","local":"lifecycleMethods"},
  {"consumer":"index.js","source":"./canvas-methods-host-api.js","kind":"namespace","imported":"*","local":"hostApiMethods"},
  {"consumer":"index.js","source":"./canvas-methods-keyboard.js","kind":"namespace","imported":"*","local":"keyboardMethods"},
  {"consumer":"index.js","source":"./canvas-methods-paste-media.js","kind":"namespace","imported":"*","local":"pasteMediaMethods"},
  {"consumer":"index.js","source":"./canvas-methods-pickers.js","kind":"namespace","imported":"*","local":"pickerMethods"},
  {"consumer":"index.js","source":"./canvas-methods-slash-palette.js","kind":"namespace","imported":"*","local":"slashPaletteMethods"},
  {"consumer":"index.js","source":"./canvas-mount.js","kind":"namespace","imported":"*","local":"mountMethods"},
  {"consumer":"index.js","source":"./canvas-ops.js","kind":"namespace","imported":"*","local":"opsMethods"},
  {"consumer":"index.js","source":"./canvas-server.js","kind":"namespace","imported":"*","local":"serverMethods"},
  {"consumer":"index.js","source":"./figure-context.js","kind":"named","imported":"isFigureSingletonCanvas","local":"isFigureSingletonCanvas"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeActive","local":"sourceModeActive"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeCommit","local":"sourceModeCommit"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeEnter","local":"sourceModeEnter"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeExit","local":"sourceModeExit"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeSizeTextarea","local":"sourceModeSizeTextarea"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeSyncText","local":"sourceModeSyncText"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeTeardown","local":"sourceModeTeardown"},
  {"consumer":"index.js","source":"./source-mode.js","kind":"named","imported":"sourceModeToggle","local":"sourceModeToggle"},
];
const EXPORTS = [
  {"owner":"canvas-document.js","exported":"_inlineObjectDialog","local":"_inlineObjectDialog"},
  {"owner":"canvas-document.js","exported":"_inlineObjectVocabulary","local":"_inlineObjectVocabulary"},
  {"owner":"canvas-document.js","exported":"_normalizedDoc","local":"_normalizedDoc"},
  {"owner":"canvas-document.js","exported":"_noteInlineObjectSave","local":"_noteInlineObjectSave"},
  {"owner":"canvas-document.js","exported":"_objectEditorOpen","local":"_objectEditorOpen"},
  {"owner":"canvas-document.js","exported":"_objectOverrides","local":"_objectOverrides"},
  {"owner":"canvas-document.js","exported":"_re","local":"_re"},
  {"owner":"canvas-document.js","exported":"_reopenRefusedInlineObject","local":"_reopenRefusedInlineObject"},
  {"owner":"canvas-document.js","exported":"_ro","local":"_ro"},
  {"owner":"canvas-document.js","exported":"_rt","local":"_rt"},
  {"owner":"canvas-document.js","exported":"getEditBlockObject","local":"getEditBlockObject"},
  {"owner":"canvas-document.js","exported":"normalizeCanvasDoc","local":"normalizeCanvasDoc"},
  {"owner":"canvas-document.js","exported":"replaceTopNode","local":"replaceTopNode"},
  {"owner":"canvas-document.js","exported":"setEditBlockObject","local":"setEditBlockObject"},
  {"owner":"canvas-editor-policy.js","exported":"ownDomReadback","local":"ownDomReadback"},
  {"owner":"canvas-editor-policy.js","exported":"ReaderTextAlign","local":"ReaderTextAlign"},
  {"owner":"canvas-editor-policy.js","exported":"transactionVetoesFigureSingleton","local":"transactionVetoesFigureSingleton"},
  {"owner":"canvas-editor-schema.js","exported":"createCanvasEditor","local":"createCanvasEditor"},
  {"owner":"canvas-focus.js","exported":"_cancelResumeFocus","local":"_cancelResumeFocus"},
  {"owner":"canvas-focus.js","exported":"_captureCaret","local":"_captureCaret"},
  {"owner":"canvas-focus.js","exported":"_clearResumeFocusIntent","local":"_clearResumeFocusIntent"},
  {"owner":"canvas-focus.js","exported":"_consumePendingFocus","local":"_consumePendingFocus"},
  {"owner":"canvas-focus.js","exported":"_enterFromLockedTitle","local":"_enterFromLockedTitle"},
  {"owner":"canvas-focus.js","exported":"_focusBodyAfterRun","local":"_focusBodyAfterRun"},
  {"owner":"canvas-focus.js","exported":"_focusBodyFrom","local":"_focusBodyFrom"},
  {"owner":"canvas-focus.js","exported":"_restoreCaret","local":"_restoreCaret"},
  {"owner":"canvas-focus.js","exported":"_restSelectionOffAtom","local":"_restSelectionOffAtom"},
  {"owner":"canvas-focus.js","exported":"_topLevelPos","local":"_topLevelPos"},
  {"owner":"canvas-focus.js","exported":"captureResumeFocus","local":"captureResumeFocus"},
  {"owner":"canvas-focus.js","exported":"focusBlock","local":"focusBlock"},
  {"owner":"canvas-focus.js","exported":"focusFirstBodyBlock","local":"focusFirstBodyBlock"},
  {"owner":"canvas-focus.js","exported":"focusSelection","local":"focusSelection"},
  {"owner":"canvas-focus.js","exported":"restoreResumeFocus","local":"restoreResumeFocus"},
  {"owner":"canvas-focus.js","exported":"selectBlock","local":"selectBlock"},
  {"owner":"canvas-lifecycle.js","exported":"_createEditorSafely","local":"_createEditorSafely"},
  {"owner":"canvas-lifecycle.js","exported":"_failMount","local":"_failMount"},
  {"owner":"canvas-lifecycle.js","exported":"_teardownDisconnected","local":"_teardownDisconnected"},
  {"owner":"canvas-lifecycle.js","exported":"_upgradeProperty","local":"_upgradeProperty"},
  {"owner":"canvas-lifecycle.js","exported":"_verifyPainted","local":"_verifyPainted"},
  {"owner":"canvas-lifecycle.js","exported":"attributeChangedCallback","local":"attributeChangedCallback"},
  {"owner":"canvas-lifecycle.js","exported":"disconnectedCallback","local":"disconnectedCallback"},
  {"owner":"canvas-lifecycle.js","exported":"getAcknowledgedSaves","local":"getAcknowledgedSaves"},
  {"owner":"canvas-lifecycle.js","exported":"getBlocks","local":"getBlocks"},
  {"owner":"canvas-lifecycle.js","exported":"getFlushKeepsSource","local":"getFlushKeepsSource"},
  {"owner":"canvas-lifecycle.js","exported":"getLiveRemote","local":"getLiveRemote"},
  {"owner":"canvas-lifecycle.js","exported":"getObservedAttributes","local":"getObservedAttributes"},
  {"owner":"canvas-lifecycle.js","exported":"initialize","local":"initialize"},
  {"owner":"canvas-lifecycle.js","exported":"setAcknowledgedSaves","local":"setAcknowledgedSaves"},
  {"owner":"canvas-lifecycle.js","exported":"setBlocks","local":"setBlocks"},
  {"owner":"canvas-lifecycle.js","exported":"setFlushKeepsSource","local":"setFlushKeepsSource"},
  {"owner":"canvas-lifecycle.js","exported":"setLiveRemote","local":"setLiveRemote"},
  {"owner":"canvas-mount.js","exported":"connectedCallback","local":"connectedCallback"},
  {"owner":"canvas-ops.js","exported":"_afterComposition","local":"_afterComposition"},
  {"owner":"canvas-ops.js","exported":"_armComposeEndEmit","local":"_armComposeEndEmit"},
  {"owner":"canvas-ops.js","exported":"_committedDoc","local":"_committedDoc"},
  {"owner":"canvas-ops.js","exported":"_dispatchOps","local":"_dispatchOps"},
  {"owner":"canvas-ops.js","exported":"_emitOps","local":"_emitOps"},
  {"owner":"canvas-ops.js","exported":"_emitReuse","local":"_emitReuse"},
  {"owner":"canvas-ops.js","exported":"_rememberEmit","local":"_rememberEmit"},
  {"owner":"canvas-ops.js","exported":"_scheduleEmit","local":"_scheduleEmit"},
  {"owner":"canvas-ops.js","exported":"acknowledgeOps","local":"acknowledgeOps"},
  {"owner":"canvas-ops.js","exported":"discardInflightOps","local":"discardInflightOps"},
  {"owner":"canvas-ops.js","exported":"flushPendingChanges","local":"flushPendingChanges"},
  {"owner":"canvas-ops.js","exported":"identifyOpsRequest","local":"identifyOpsRequest"},
  {"owner":"canvas-ops.js","exported":"localEditsRebaseSafe","local":"localEditsRebaseSafe"},
  {"owner":"canvas-ops.js","exported":"rebaseSafe","local":"rebaseSafe"},
  {"owner":"canvas-ops.js","exported":"resendPendingOps","local":"resendPendingOps"},
  {"owner":"canvas-server.js","exported":"_applyExternalContent","local":"_applyExternalContent"},
  {"owner":"canvas-server.js","exported":"_applyWholeSnapshot","local":"_applyWholeSnapshot"},
  {"owner":"canvas-server.js","exported":"_canMergeRemote","local":"_canMergeRemote"},
  {"owner":"canvas-server.js","exported":"_caretBlockIndexes","local":"_caretBlockIndexes"},
  {"owner":"canvas-server.js","exported":"_clearPendingServerBlocks","local":"_clearPendingServerBlocks"},
  {"owner":"canvas-server.js","exported":"_flushPendingServerBlocks","local":"_flushPendingServerBlocks"},
  {"owner":"canvas-server.js","exported":"_isEditingNow","local":"_isEditingNow"},
  {"owner":"canvas-server.js","exported":"_mergePendingServerBlocks","local":"_mergePendingServerBlocks"},
  {"owner":"canvas-server.js","exported":"_mergeRemote","local":"_mergeRemote"},
  {"owner":"canvas-server.js","exported":"_queueServerBlocks","local":"_queueServerBlocks"},
  {"owner":"canvas-server.js","exported":"_reportHeld","local":"_reportHeld"},
  {"owner":"canvas-server.js","exported":"_stampMaterializedIds","local":"_stampMaterializedIds"},
  {"owner":"canvas-server.js","exported":"_stampOwnEchoIds","local":"_stampOwnEchoIds"},
  {"owner":"canvas-server.js","exported":"_takeServerBlocks","local":"_takeServerBlocks"},
  {"owner":"canvas-server.js","exported":"applyServerBlocks","local":"applyServerBlocks"},
  {"owner":"canvas-server.js","exported":"applyServerBlocksIfIdle","local":"applyServerBlocksIfIdle"},
  {"owner":"index.js","exported":"BpPaperCanvas","local":"BpPaperCanvas"},
  {"owner":"index.js","exported":"ReaderTextAlign","local":"ReaderTextAlign","source":"./canvas-editor-policy.js"},
];
const DAG_EDGES = [
  {"from":"canvas-editor-schema.js","to":"canvas-editor-policy.js","kind":"import"},
  {"from":"canvas-mount.js","to":"canvas-editor-schema.js","kind":"import"},
  {"from":"canvas-ops.js","to":"canvas-document.js","kind":"import"},
  {"from":"canvas-server.js","to":"canvas-document.js","kind":"import"},
  {"from":"index.js","to":"canvas-document.js","kind":"import"},
  {"from":"index.js","to":"canvas-editor-policy.js","kind":"reexport"},
  {"from":"index.js","to":"canvas-focus.js","kind":"import"},
  {"from":"index.js","to":"canvas-lifecycle.js","kind":"import"},
  {"from":"index.js","to":"canvas-mount.js","kind":"import"},
  {"from":"index.js","to":"canvas-ops.js","kind":"import"},
  {"from":"index.js","to":"canvas-server.js","kind":"import"},
];
const FILES = {
  "canvas-editor-schema.js": [
    764,
    "06efa7b4899fbd28bf8d8602b399619348828ae2b9a1b4bfde9831f1f5a4c43f"
  ],
  "canvas-editor-policy.js": [
    73,
    "82aa5c9aa51b0371cd566639cdf475d95b52c48a9edb6e87e12a4c0ad682b143"
  ],
  "canvas-mount.js": [
    157,
    "93b32425f68a771add0986ec9ab9ff0418d31633b0330ebc9f19acb68304ddfe"
  ],
  "canvas-lifecycle.js": [
    495,
    "84731f5dfbf9d77196c7d8192dfb77b7aa82513e67d6b22c9ad200daf255f42d"
  ],
  "canvas-focus.js": [
    333,
    "6f259c1e4410ec208a3c8190e9092a517fa1fe975d933da49ba8c0cd6c65d994"
  ],
  "canvas-ops.js": [
    479,
    "0a8a3f634bb0800882269a0a6fc19effc1c17afcba8e81ee92b3819272dc38e3"
  ],
  "canvas-document.js": [
    325,
    "5848d528e3eef157db0bbaa5079af8fb35592755ef2de1144089ab06c8d1307a"
  ],
  "canvas-server.js": [
    660,
    "8b227c2d356c8f7fe1c22080206248cb863c92957db288d19cdc0740764f7689"
  ],
  "index.js": [
    718,
    "3309eac3e085b22843486de8d98cbb2b0e1162394de864762a822090032055b7"
  ]
};
const COMMENTS = {"count":1171,"multisetSha256":"45d7399273427002f3e736807183441cf5b051e84d9787ef59f6c957ff4ff448"};
const COMMENT_OWNERS = {
  "canvas-editor-schema.js": {
    "count": 436,
    "sequenceSha256": "03910ece25ada7704dda031def32364327e2715bedd2385c3953fcb1a322e37a"
  },
  "canvas-editor-policy.js": {
    "count": 20,
    "sequenceSha256": "e9ae6edf3c7fdd7489da595ba50adaa61a75e0c97c079f21929622b279a85a5e"
  },
  "canvas-mount.js": {
    "count": 40,
    "sequenceSha256": "a48bfb8a1c21d5a25c744d04fbf6b56a4bdeacbfba03615dd21dbd948ac7043f"
  },
  "canvas-lifecycle.js": {
    "count": 153,
    "sequenceSha256": "a8a6bcc0681558101c8ce634d191caad29b632ea9f4fea9cd0d319b16394f864"
  },
  "canvas-focus.js": {
    "count": 48,
    "sequenceSha256": "d26b40173ded3f2efa960043f68a0cbf80cc084d86fb1ff0eab9e29bb2c16504"
  },
  "canvas-ops.js": {
    "count": 165,
    "sequenceSha256": "e5e3d9d20a6113693de0e01f963324d490968cd31e2077e69f5fca9c5677916c"
  },
  "canvas-document.js": {
    "count": 82,
    "sequenceSha256": "69f485e9fde00d114923c236fb37204f17864b6417a63bad7b5559dd2bc6239f"
  },
  "canvas-server.js": {
    "count": 158,
    "sequenceSha256": "b3788c7a6334f5ce09ae67e1019fb269ba4aa8bd173b97aed709cd0dce842597"
  },
  "index.js": {
    "count": 69,
    "sequenceSha256": "4b2e6dee58ddf48e06cebc9072c88a9ad00831893fa9d914bc255bbe5f5dabf9"
  }
};

assert.equal(DEFINITIONS.length, 202, "all class definitions are specified");
assert.equal(DEFINITIONS.filter((row) => row.exportSymbol).length, 77, "all newly moved definitions are specified");
assert.equal(DEFINITIONS.filter((row) => row.bodySha256).length, 199, "every non-field body is hash-locked");
assert.equal(IMPORTS.length, 169, "complete lexical import closure is specified");
assert.equal(EXPORTS.length, 85, "complete leaf export surface is specified");
assert.deepEqual(COMMENTS, { count: 1171, multisetSha256: "45d7399273427002f3e736807183441cf5b051e84d9787ef59f6c957ff4ff448" });

// The predecessor's complete historical source/runtime locks pass before the
// first final-topology requirement. The test-first commit then fails only here.
for (const name of ["__interaction_plane_boundary.test.mjs", "__source_mode_boundary.test.mjs"]) {
  execFileSync(process.execPath, [join(here, name)], { stdio: "inherit" });
}
await import("./canvas-editor-policy.js");

const texts = new Map(Object.entries(FILES).map(([name]) => [name, readFileSync(join(here, name), "utf8")]));
const { canvasSourceLeafNames, elementClassBody, sourceMembers } = await import("../../scripts/surface-package.mjs");
const commentTokens = (text) => {
  const out = [];
  for (let at = 0; at < text.length;) {
    const char = text[at];
    if (char === "\"" || char === "'") {
      const quote = char; at++;
      while (at < text.length) { if (text[at] === "\\") at += 2; else if (text[at++] === quote) break; }
    } else if (char === "\u0060") {
      at++;
      while (at < text.length) { if (text[at] === "\\") at += 2; else if (text[at++] === "\u0060") break; }
    } else if (char === "/" && text[at + 1] === "/") {
      const start = at + 2; at = text.indexOf("\n", start); if (at === -1) at = text.length;
      out.push({ type: "Line", value: text.slice(start, at) });
    } else if (char === "/" && text[at + 1] === "*") {
      const start = at + 2; at = text.indexOf("*/", start); assert.notEqual(at, -1, "closed block comment");
      out.push({ type: "Block", value: text.slice(start, at) }); at += 2;
    } else at++;
  }
  return out;
};
const comments = [...texts.values()].flatMap(commentTokens);
const commentCounts = new Map();
for (const comment of comments) { const key = comment.type + "\0" + comment.value; commentCounts.set(key, (commentCounts.get(key) || 0) + 1); }
assert.equal(comments.length, COMMENTS.count, "actual lexical comment census");
assert.equal(sha(JSON.stringify([...commentCounts].sort())), COMMENTS.multisetSha256, "actual lexical comment multiset");
for (const [name, expected] of Object.entries(COMMENT_OWNERS)) {
  const owned = commentTokens(texts.get(name));
  assert.equal(owned.length, expected.count, name + " owned comment count");
  assert.equal(sha(JSON.stringify(owned)), expected.sequenceSha256, name + " owned comment sequence");
}

const balancedBody = (text, start) => {
  let depth = 0;
  for (let at = start; at < text.length; at++) {
    const char = text[at];
    if (char === "\"" || char === "'" || char === "\u0060") {
      const quote = char; at++;
      while (at < text.length) { if (text[at] === "\\") at += 2; else if (text[at] === quote) break; else at++; }
    } else if (char === "/" && text[at + 1] === "/") {
      at = text.indexOf("\n", at + 2); if (at === -1) return null;
    } else if (char === "/" && text[at + 1] === "*") {
      at = text.indexOf("*/", at + 2); assert.notEqual(at, -1, "closed block comment in definition"); at++;
    } else if (char === "{") depth++;
    else if (char === "}" && --depth === 0) return text.slice(start, at + 1);
  }
  return null;
};
for (const row of DEFINITIONS.filter((item) => item.exportSymbol)) {
  const ownerText = texts.get(row.owner);
  const marker = "function " + row.exportSymbol + "(";
  const start = ownerText.indexOf(marker);
  assert.notEqual(start, -1, "moved declaration exists: " + row.key);
  assert.equal(ownerText.indexOf(marker, start + 1), -1, "moved declaration is unique: " + row.key);
  const signatureEnd = ownerText.indexOf(") {", start + marker.length);
  assert.notEqual(signatureEnd, -1, "moved signature closes: " + row.key);
  const bodyStart = signatureEnd + 2;
  const actualHeaderStart = row.async ? start - "async ".length : start;
  const actualLeafHeader = ownerText.slice(actualHeaderStart, bodyStart);
  const parameters = row.header.slice(row.header.indexOf("("), row.header.lastIndexOf(")") + 1);
  const expectedLeafHeader = (row.async ? "async " : "") + "function " + row.exportSymbol + parameters + " ";
  assert.equal(actualLeafHeader, expectedLeafHeader, "mapped actual leaf signature: " + row.key);
  const projectedBody = balancedBody(ownerText, bodyStart);
  assert.ok(projectedBody, "moved body is balanced: " + row.key);
  let authorityBody = projectedBody.split("\n").map((line, index) => index === 0 || line === "" ? line : "  " + line).join("\n");
  if (row.kind === "constructor") authorityBody = authorityBody.replace("{\n", "{\n    super();\n");
  if (row.name === "connectedCallback") {
    assert.equal(projectedBody.split("this._editor = this._createEditorSafely(() => editorSchema.createCanvasEditor.call(this));").length - 1, 1, "connected callback has the one reviewed factory seam");
  } else assert.equal(sha(authorityBody), row.bodySha256, "moved authority body: " + row.key);
  assert.equal(sha(row.wrapper), row.wrapperSha256, "facade wrapper manifest: " + row.key);
  assert.equal(texts.get("index.js").split(row.wrapper).length - 1, 1, "exact facade wrapper: " + row.key);
}

const parseImports = (owner, text) => {
  const rows = [];
  for (const match of text.matchAll(/import\s+\*\s+as\s+(\w+)\s+from\s+["']([^"']+)["'];/g))
    rows.push({ consumer: owner, source: match[2], kind: "namespace", imported: "*", local: match[1] });
  for (const match of text.matchAll(/import\s+([A-Za-z_$][\w$]*)\s+from\s+["']([^"']+)["'];/g))
    rows.push({ consumer: owner, source: match[2], kind: "default", imported: "default", local: match[1] });
  for (const match of text.matchAll(/import\s*\{([^}]+)\}\s*from\s*["']([^"']+)["'];/g))
    for (const part of match[1].split(",").map((value) => value.trim()).filter(Boolean)) {
      const [imported, local = imported] = part.split(/\s+as\s+/);
      rows.push({ consumer: owner, source: match[2], kind: "named", imported, local });
    }
  for (const match of text.matchAll(/export\s*\{([^};]+)\}\s*from\s*["']([^"']+)["'];/g))
    for (const part of match[1].split(",").map((value) => value.trim()).filter(Boolean)) {
      const [imported, local = imported] = part.split(/\s+as\s+/);
      rows.push({ consumer: owner, source: match[2], kind: "reexport", imported, local });
    }
  return rows;
};
const importKey = (row) => [row.consumer, row.source, row.kind, row.imported, row.local].join("\0");
const actualImports = [...texts].flatMap(([name, text]) => parseImports(name, text)).sort((a, b) => importKey(a).localeCompare(importKey(b)));
const expectedImports = [...IMPORTS].sort((a, b) => importKey(a).localeCompare(importKey(b)));
assert.deepEqual(actualImports, expectedImports, "all 169 exact imports/reexports and aliases match");

const internalNames = new Set(Object.keys(FILES));
const actualEdges = actualImports.flatMap((row) => {
  if (!row.source.startsWith("./")) return [];
  const target = row.source.slice(2);
  if (!internalNames.has(target)) return [];
  return [{ from: row.consumer, to: target, kind: row.kind === "reexport" ? "reexport" : "import" }];
}).filter((row, index, rows) => rows.findIndex((other) => JSON.stringify(other) === JSON.stringify(row)) === index)
  .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const expectedEdges = [...DAG_EDGES].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
assert.deepEqual(actualEdges, expectedEdges, "actual internal import DAG matches all 11 edges");
const visiting = new Set();
const visited = new Set();
const visit = (name) => {
  assert.ok(!visiting.has(name), "internal import graph is acyclic at " + name);
  if (visited.has(name)) return;
  visiting.add(name);
  for (const edge of actualEdges.filter((row) => row.from === name)) visit(edge.to);
  visiting.delete(name); visited.add(name);
};
for (const name of internalNames) visit(name);
const leafSources = [...texts].filter(([name]) => name !== "index.js").map(([, text]) => text).join("\n");
assert.ok(!leafSources.includes('from "./index.js"') && !leafSources.includes("from './index.js'"), "no leaf imports the facade");

const schemaSource = texts.get("canvas-editor-schema.js");
assert.ok(schemaSource.includes('import { BpAttrs } from "./bp-attrs.js";'), "schema directly owns BpAttrs");
assert.match(schemaSource, /extensions:[\s\S]*BpAttrs/, "schema installs BpAttrs");
assert.match(schemaSource, /transactionVetoesFigureSingleton/, "schema retains the figure singleton veto");
assert.ok(schemaSource.indexOf("const host = this;") < schemaSource.indexOf("return new Editor("), "Editor factory owns its lexical host");
assert.ok(texts.get("canvas-mount.js").includes("editorSchema.createCanvasEditor.call(this)"), "mount calls the bounded factory");
assert.doesNotMatch(texts.get("canvas-mount.js"), /const host = this;/, "mount does not duplicate the factory binding");
assert.ok(texts.get("index.js").includes("constructor() { super(); lifecycleMethods.initialize.call(this); }"), "facade constructor keeps super plus initialize seam");
assert.ok(texts.get("index.js").includes('export { ReaderTextAlign } from "./canvas-editor-policy.js";'), "facade directly re-exports ReaderTextAlign");

for (const [name, [expectedLines, digest]] of Object.entries(FILES)) {
  const text = texts.get(name);
  assert.equal(text.split("\n").length - 1, expectedLines, name + " exact readable line budget");
  assert.ok(expectedLines < 800, name + " stays below 800 lines");
  assert.equal(sha(text), digest, name + " exact ownership projection after semantic locks");
}

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text", "File"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const root = await import("./index.js");
const { BpPaperCanvas, ReaderTextAlign } = root;
const namespaces = new Map([["index.js", root]]);
for (const name of Object.keys(FILES).filter((name) => name !== "index.js")) namespaces.set(name, await import("./" + name));
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas, "the facade remains the registered class");
assert.equal(BpPaperCanvas.prototype.constructor, BpPaperCanvas, "the public constructor stays exact");
assert.equal(ReaderTextAlign, namespaces.get("canvas-editor-policy.js").ReaderTextAlign, "ReaderTextAlign keeps one class identity");
const staticNames = [...new Set(DEFINITIONS.filter((row) => row.static).map((row) => row.name))];
const prototypeNames = [...new Set(DEFINITIONS.filter((row) => !row.static).map((row) => row.name))];
assert.deepEqual(Object.getOwnPropertyNames(BpPaperCanvas).sort(), ["length", "name", "prototype", ...staticNames].sort(), "exact static descriptor key set");
assert.deepEqual(Object.getOwnPropertyNames(BpPaperCanvas.prototype).sort(), prototypeNames.sort(), "exact prototype descriptor key set");

for (const row of DEFINITIONS) {
  const target = row.static ? BpPaperCanvas : BpPaperCanvas.prototype;
  const descriptor = Object.getOwnPropertyDescriptor(target, row.name);
  assert.ok(descriptor, "descriptor: " + row.key);
  const sameName = DEFINITIONS.filter((other) => other.static === row.static && other.name === row.name);
  const accessor = sameName.some((other) => other.kind === "get" || other.kind === "set");
  assert.deepEqual(Object.keys(descriptor).sort(), (accessor ? ["configurable", "enumerable", "get", "set"] : ["configurable", "enumerable", "value", "writable"]).sort(), "descriptor shape: " + row.key);
  if (accessor) {
    assert.equal(typeof descriptor.get === "function", sameName.some((other) => other.kind === "get"), "getter half: " + row.key);
    assert.equal(typeof descriptor.set === "function", sameName.some((other) => other.kind === "set"), "setter half: " + row.key);
  }
  if (row.kind === "field") continue;
  const fn = row.kind === "get" ? descriptor.get : row.kind === "set" ? descriptor.set : descriptor.value;
  const expectedName = row.kind === "constructor" ? "BpPaperCanvas" : row.kind === "get" ? "get " + row.name : row.kind === "set" ? "set " + row.name : row.name;
  assert.equal(fn.name, expectedName, "runtime name: " + row.key);
  assert.equal(fn.length, row.runtimeLength, "runtime arity: " + row.key);
  assert.equal(fn.constructor.name === "AsyncFunction", row.async, "runtime async: " + row.key);
  if (row.exportSymbol) assert.equal(typeof namespaces.get(row.owner)[row.exportSymbol], "function", "leaf export: " + row.key);
}
// Node 20, which CI runs, has no Map.groupBy.
const exportsByOwner = new Map();
for (const row of EXPORTS) exportsByOwner.set(row.owner, [...(exportsByOwner.get(row.owner) ?? []), row]);
for (const [owner, rows] of exportsByOwner) {
  assert.deepEqual(Object.keys(namespaces.get(owner)).sort(), rows.map((row) => row.exported).sort(), "exact exports: " + owner);
}

const legacy = ["canvas-methods-host-api.js", "canvas-methods-keyboard.js", "canvas-methods-paste-media.js", "canvas-methods-pickers.js", "canvas-methods-slash-palette.js"];
const added = ["canvas-document.js", "canvas-editor-schema.js", "canvas-focus.js", "canvas-lifecycle.js", "canvas-mount.js", "canvas-ops.js", "canvas-server.js"];
assert.deepEqual(canvasSourceLeafNames([...legacy, ...added, "canvas-editor-policy.js", "other.js"]), [...legacy, ...added].sort());
const memberNames = [...new Set(sourceMembers([elementClassBody(texts.get("index.js")), ...canvasSourceLeafNames([...legacy, ...added]).map((name) => texts.get(name) ?? readFileSync(join(here, name), "utf8"))].join("\n")))].sort();
assert.equal(memberNames.length, 206, "final canvas source-member census");
assert.equal(sha(memberNames.join("\n") + "\n"), "805f20b09124db41e8cc38c3920042ee6247548ca827b353a23989794996b764");
dom.window.close();
console.log("canvas endstate boundary: 202 definitions, 169 imports, 85 exports, 1171 comments and 12 source leaves passed");
