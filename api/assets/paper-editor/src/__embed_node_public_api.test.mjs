import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import * as embedNode from "./canvas/embed-node.js";

const expected = [
  "BP_SHEET_NODE_NAME",
  "BP_EMBED_NODE_NAME",
  "sheetChipLabel",
  "embedChipLabel",
  "atomBlockRetargeted",
  "atomRetargetAllowed",
  "Sheet",
  "Embed",
  "BP_FLEET_NODE_NAME",
  "readerPaintClass",
  "fleetChipLabel",
  "isBlockLocked",
  "atomAriaLabel",
  "isActivateKey",
  "selectAtomNode",
  "wireAtomAccessibility",
  "datumEditorSpec",
  "datumEditorRows",
  "datumEditorSet",
  "datumEditorMove",
  "fleetKindEditable",
  "fleetEditorText",
  "fleetEditorParse",
  "Fleet",
];
const actualSorted = Object.keys(embedNode).sort();
const expectedSorted = [...expected].sort();
assert.equal(expected.length, 24, "the independent public-name inventory has 24 entries");
assert.deepEqual(actualSorted, expectedSorted, "embed-node exports exactly the stable public namespace");
assert.equal("default" in embedNode, false, "the facade has no default export");
for (const internal of ["readOnlyAtomAttributes", "FLEET_ITEM_EDITORS", "FLEET_CONFIG_EDITORS", "buildFleetEditor"]) {
  assert.equal(internal in embedNode, false, `${internal} remains internal`);
}
assert.equal(embedNode.Sheet.name, "bpSheet");
assert.equal(embedNode.Embed.name, "bpEmbed");
assert.equal(embedNode.Fleet.name, "bpFleet");

const jsdom = new JSDOM("<!doctype html><body></body>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = jsdom;
for (const name of ["CustomEvent", "document", "Event", "HTMLElement", "KeyboardEvent", "Node"])
  globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });

function mockNode(extension, attrs, type = null) {
  const nodeType = type || {
    name: extension.name,
    create(nextAttrs) { return mockNode(extension, nextAttrs, this); },
  };
  return {
    type: nodeType,
    attrs,
    eq(other) {
      return other?.type?.name === nodeType.name &&
        JSON.stringify(other.attrs) === JSON.stringify(attrs);
    },
  };
}

function mount(extension, attrs, { editable = false, append = true } = {}) {
  let current = mockNode(extension, attrs);
  const chain = {
    setNodeSelection() { return this; },
    focus() { return this; },
    command() { return this; },
    run() { return true; },
  };
  const editor = {
    isEditable: editable,
    options: { element: document.body },
    state: { doc: { nodeAt: () => current } },
    chain: () => chain,
    commands: { undo() {}, redo() {} },
    view: { dispatch() {} },
  };
  const view = extension.config.addNodeView()({ node: current, editor, getPos: () => 0 });
  view.makeNode = (nextAttrs) => mockNode(extension, nextAttrs, current.type);
  view.setCurrent = (nextNode) => { current = nextNode; };
  if (append) document.body.appendChild(view.dom);
  return view;
}

let readyEvent = null;
const onReady = (event) => { readyEvent = event; };
document.body.addEventListener("bp-ready", onReady);
const sheetBlock = { id: "sheet-ready", type: "sheet", ref: "budget", snapshot: { rows: [["42"]] } };
const sheet = mount(embedNode.Sheet, {
  bpId: sheetBlock.id,
  bpType: sheetBlock.type,
  bpBlock: sheetBlock,
}, { append: false });
assert.equal(readyEvent, null, "bp-ready is not dispatched while the atom is disconnected");
document.body.appendChild(sheet.dom);
await Promise.resolve();
assert.equal(readyEvent?.target, sheet.dom, "the queued bp-ready event arrives from the mounted atom");
assert.equal(readyEvent.target.isConnected, true, "bp-ready arrives only after connection");
document.body.removeEventListener("bp-ready", onReady);

const fleetBlock = { id: "fleet-paint", type: "route", path: "/papers/:slug" };
const fleet = mount(embedNode.Fleet, {
  bpId: fleetBlock.id,
  bpType: fleetBlock.type,
  bpBlock: fleetBlock,
});
const paintHole = fleet.dom.querySelector("[data-bp-fleet-body]");
assert.ok(paintHole, "Fleet mounts its canonical server-paint hole");
const injected = '<article data-render="server"><p>Canonical <strong>reader</strong> HTML</p></article>';
paintHole.innerHTML = injected;
assert.equal(paintHole.innerHTML, injected, "the test installs exact canonical server HTML");
const echoedBlock = { ...fleetBlock, path: "/papers/:id" };
const echoedNode = fleet.makeNode({
  bpId: echoedBlock.id,
  bpType: echoedBlock.type,
  bpBlock: echoedBlock,
});
fleet.setCurrent(echoedNode);
assert.equal(fleet.update(echoedNode), true, "a same-Fleet echo updates the existing node view");
assert.strictEqual(fleet.dom.querySelector("[data-bp-fleet-body]"), paintHole,
  "same-node echo preserves the exact paint-hole node identity");
assert.equal(paintHole.innerHTML, injected,
  "same-node echo preserves the exact injected canonical reader HTML");

sheet.destroy?.();
sheet.dom.remove();
fleet.destroy?.();
fleet.dom.remove();
window.close();
console.log("embed-node public API, queued readiness, and Fleet paint identity: ok");
