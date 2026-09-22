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



const c=document.createElement("bp-paper-canvas");c.blocks=[{id:"seed",type:"paragraph",content:[{type:"text",value:"Before selected After"}]}];document.body.append(c);c._editor.commands.setTextSelection({from:8,to:16});
const before=c.recoverySnapshot().blocks;const event=new Event("paste",{bubbles:true,cancelable:true});Object.defineProperty(event,"clipboardData",{value:{types:["text/html","text/plain"],getData:type=>type==="text/html"?'<img src="https://example.test/diagram.png" alt="Important diagram">':"Important diagram",files:[]}});
try{c._editor.view.dom.dispatchEvent(event);assert.deepEqual(c.recoverySnapshot().blocks,before,"an unsupported HTML image must not erase selected text with an empty parsed slice");assert.match(c.textContent,/Nothing was pasted/);}finally{dom.window.close();}
