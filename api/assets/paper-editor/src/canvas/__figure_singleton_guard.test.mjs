import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;

for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");

const wrapper = document.createElement("div");
wrapper.dataset.paperContainerKind = "figure";
const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [{
  id: "figure-child",
  type: "paragraph",
  content: [{ type: "text", value: "Figure body" }],
}];
wrapper.appendChild(canvas);
document.body.appendChild(wrapper);
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;
  const editor = canvas._editor;
  editor.commands.focus("end");
  const originalDoc = editor.getJSON();

  editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
  }));

  assert.equal(editor.state.doc.childCount, 1, "Figure editing must retain one direct child");
  assert.equal(editor.state.doc.firstChild.attrs.bpId, "figure-child");
  assert.deepEqual(editor.getJSON(), originalDoc, "unsupported Enter leaves content unchanged");
  assert.match(canvas.textContent, /Enter cannot split or remove it/);
  assert.equal(batches.length, 0);

  editor.commands.setNodeSelection(0);
  editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", {
    key: "Backspace",
    code: "Backspace",
    keyCode: 8,
    bubbles: true,
    cancelable: true,
  }));
  assert.deepEqual(
    editor.getJSON(),
    originalDoc,
    "Backspace cannot remove or replace the singular Figure child",
  );

  editor.commands.focus("end");
  const multiPaste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(multiPaste, "clipboardData", {
    value: {
      types: ["text/html", "text/plain"],
      files: [],
      getData: (type) => {
        if (type === "text/html") {
          return "<p><strong>Bold</strong></p><hr><p><em>Italic</em></p>";
        }
        if (type === "text/plain") return "Bold\n\n---\n\nItalic";
        return "";
      },
    },
  });
  assert.equal(editor.view.dom.dispatchEvent(multiPaste), false);
  assert.deepEqual(editor.getJSON(), originalDoc, "mixed rich/atom paste is rejected without data loss");
  assert.match(canvas.textContent, /Paste one paragraph at a time/);

  const richPaste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(richPaste, "clipboardData", {
    value: {
      types: ["text/html", "text/plain"],
      files: [],
      getData: (type) => {
        if (type === "text/html") return "<p><strong>Bold</strong> and <em>italic</em></p>";
        if (type === "text/plain") return "Bold and italic";
        return "";
      },
    },
  });
  assert.equal(editor.view.dom.dispatchEvent(richPaste), false);
  assert.equal(editor.state.doc.childCount, 1, "single-paragraph rich paste stays in the child map");
  const pasted = editor.state.doc.firstChild.content.content;
  assert.ok(pasted.some((node) => node.isText && node.marks.some((mark) => mark.type.name === "bold")));
  assert.ok(pasted.some((node) => node.isText && node.marks.some((mark) => mark.type.name === "italic")));

  await new Promise((resolve) => setTimeout(resolve, 350));
  const pastePatch = batches.at(-1)[0].patch.content;
  assert.ok(pastePatch.some((node) => node.type === "strong"));
  assert.ok(pastePatch.some((node) => node.type === "em"));
  assert.deepEqual(
    batches.at(-1).filter(({ op }) => op === "insert-after" || op === "remove-block"),
    [],
  );

  let autocompleteChosen = 0;
  canvas._slash = {
    isOpen: () => true,
    choose: () => { autocompleteChosen += 1; },
    destroy: () => {},
  };
  assert.equal(canvas._onKeyDown({ key: "Enter" }), true);
  assert.equal(autocompleteChosen, 1, "an active autocomplete owns Enter before the Figure guard");
  canvas._slash = null;

  canvas.toggleSourceMode();
  assert.equal(canvas._mode, "rich", "Figure singleton cannot enter structural source mode");
  assert.match(canvas.textContent, /Markdown source is unavailable inside a Figure/);

  const listWrapper = document.createElement("div");
  listWrapper.dataset.paperContainerKind = "figure";
  const listCanvas = document.createElement("bp-paper-canvas");
  listCanvas.blocks = [{
    id: "figure-list",
    type: "list",
    ordered: false,
    items: [[{ type: "text", value: "First item" }]],
  }];
  listWrapper.appendChild(listCanvas);
  document.body.appendChild(listWrapper);
  await new Promise((resolve) => setTimeout(resolve, 350));
  listCanvas._editor.commands.focus("end");
  listCanvas._editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
  }));
  assert.equal(listCanvas._editor.state.doc.childCount, 1);
  assert.equal(listCanvas._editor.state.doc.firstChild.attrs.bpId, "figure-list");
  assert.equal(
    listCanvas._editor.state.doc.firstChild.childCount,
    2,
    "Enter may add an item inside the singular list child",
  );
  listWrapper.remove();

  const codeWrapper = document.createElement("div");
  codeWrapper.dataset.paperContainerKind = "figure";
  const codeCanvas = document.createElement("bp-paper-canvas");
  codeCanvas.blocks = [{ id: "figure-code", type: "code", value: "first" }];
  codeWrapper.appendChild(codeCanvas);
  document.body.appendChild(codeWrapper);
  await new Promise((resolve) => setTimeout(resolve, 350));
  const codeArea = codeCanvas.querySelector(".bp-canvas-code-area");
  const codeEnter = new window.KeyboardEvent("keydown", {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
  });
  codeArea.dispatchEvent(codeEnter);
  assert.equal(codeEnter.defaultPrevented, false, "the code textarea retains native Enter");
  codeArea.value = "first\nsecond";
  codeArea.dispatchEvent(new window.Event("input", { bubbles: true }));
  codeArea.dispatchEvent(new window.CustomEvent("bp-flush-node", { bubbles: true }));
  assert.equal(codeCanvas._editor.state.doc.childCount, 1);
  assert.equal(codeCanvas._editor.state.doc.firstChild.attrs.bpId, "figure-code");
  assert.equal(codeCanvas._editor.state.doc.firstChild.attrs.value, "first\nsecond");
  codeWrapper.remove();

  const sectionWrapper = document.createElement("div");
  sectionWrapper.dataset.paperContainerKind = "section";
  const sectionCanvas = document.createElement("bp-paper-canvas");
  sectionCanvas.blocks = [{ id: "section-child", type: "paragraph", content: [] }];
  sectionWrapper.appendChild(sectionCanvas);
  document.body.appendChild(sectionWrapper);
  await new Promise((resolve) => setTimeout(resolve, 350));
  sectionCanvas._editor.commands.focus("end");
  sectionCanvas._editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
  }));
  assert.equal(
    sectionCanvas._editor.state.doc.childCount,
    2,
    "normal nested containers retain native Enter splitting",
  );
  sectionWrapper.remove();
} finally {
  wrapper.remove();
  window.close();
}

console.log("Figure singleton canvas keyboard guard passed");
