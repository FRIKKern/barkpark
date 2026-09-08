import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM('<main><button id="paper-edit-toggle" data-editing="false">Edit</button><div data-paper-doc-key="production:paper:example"></div></main>');
const { window } = dom;
vm.runInContext(readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"), vm.createContext({ window, document: window.document, console, setTimeout, clearTimeout }));
try {
  assert.equal(typeof window.BarkparkPaperEditorConnectParams, "function");
  assert.deepEqual(JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())), {});
  window.document.querySelector("button").dataset.editing = "true";
  assert.deepEqual(JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())), { paper_editing_key: "production:paper:example" });
  window.document.querySelector("[data-paper-doc-key]").remove();
  assert.deepEqual(JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())), {}, "an unbound toggle cannot resume a different document");
  console.log("reconnect mode hint is live, document-bound, and contains no draft data");
} finally { window.close(); }
