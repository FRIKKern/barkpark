// Mounted regression for node-view controls whose values are held behind their
// own debounce. The canvas flush must commit those controls before diffing the run.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { closeHistory, undoDepth } from "@tiptap/pm/history";

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
const navigationEvents = new window.EventTarget();
const navigationTraversals = [];
const navigationResults = [];
let navigationIndex;
Object.defineProperty(window, "navigation", {
  configurable: true,
  value: {
    addEventListener: navigationEvents.addEventListener.bind(navigationEvents),
    removeEventListener: navigationEvents.removeEventListener.bind(navigationEvents),
    get currentEntry() {
      return Number.isFinite(navigationIndex) ? { index: navigationIndex } : null;
    },
    traverseTo: (key) => {
      navigationTraversals.push(key);
      return navigationResults.shift() || {
        committed: Promise.resolve(),
        finished: Promise.resolve(),
      };
    },
  },
});

const { BpPaperCanvas } = await import("./index.js");
const { DEBOUNCE_MS } = await import("../contract.js");
const { slashTypeToNode } = await import("./slash-insert.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const hooksSource = readFileSync(
  new URL("../../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url),
  "utf8",
);
const seededDom = new JSDOM("<!doctype html>", { url:"http://localhost/studio/papers/seed-41" });
seededDom.window.history.replaceState(
  {position:41, type:"patch", id:"main"},
  "",
  "/studio/papers/seed-41",
);
vm.runInContext(hooksSource, vm.createContext({
  window:seededDom.window,
  document:seededDom.window.document,
  customElements:seededDom.window.customElements,
  CustomEvent:seededDom.window.CustomEvent,
  FormData:seededDom.window.FormData,
  setTimeout,
  clearTimeout,
}));
seededDom.window.history.pushState(null, "", "/studio/papers/seed-42");
assert.equal(seededDom.window.history.state.__bpPaperHistoryPosition, 42,
  "an existing Phoenix position seeds the owned counter before fallback zero");
seededDom.window.close();

const context = vm.createContext({ window, document, customElements, CustomEvent,
  FormData: window.FormData, setTimeout, clearTimeout });
assert.equal(window.history.state, null, "the browser starts with Phoenix's join sentinel");
vm.runInContext(hooksSource, context);
assert.equal(window.history.state, null,
  "loading editor hooks must not consume Phoenix's null-state initialization sentinel");
window.history.replaceState(
  {position:41, type:"patch", id:"main", foreign:"kept"},
  "",
  "/studio/papers/owned-41",
);
assert.deepEqual(
  {position:window.history.state.position, type:window.history.state.type,
    id:window.history.state.id, foreign:window.history.state.foreign,
    owned:window.history.state.__bpPaperHistoryPosition},
  {position:41, type:"patch", id:"main", foreign:"kept", owned:41},
  "Phoenix's initial replace establishes the owned counter without losing fields",
);
const foreignHistoryState = new Map([["foreign", 42]]);
window.history.replaceState(foreignHistoryState, "", "/studio/papers/foreign-state");
assert.ok(window.history.state instanceof Map,
  "non-record foreign history state remains its original structured-clone type");
assert.equal(window.history.state.get("foreign"), 42);
assert.equal(window.history.state.__bpPaperHistoryPosition, undefined,
  "non-record foreign history state remains unowned");
window.history.replaceState(
  {position:41, type:"patch", id:"main", foreign:"kept"},
  "",
  "/studio/papers/owned-41",
);
const hooks = window.BarkparkPaperEditorHooks;
const paragraph = (id, value) => ({id, type: "paragraph", content: [{type: "text", value}]});
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

async function mount({ revision, blocks = [paragraph("original", "Original")] } = {}) {
  const main = document.createElement("main");
  if (revision != null) {
    main.dataset.paperDocKey = "paper-overlap-probe";
    main.dataset.paperRev = String(revision);
  }
  main.innerHTML = `<button id="paper-edit-toggle" data-editing="true">View</button>
    <a href="/studio/papers/b" data-phx-link="patch">Paper B</a>
    <button type="button" phx-click="paper-delete-block">Delete</button>
    <button type="button" phx-click="paper-move-block">Move</button>
    <button type="button" phx-click="paper-materialize-slot">Materialize</button>
    <button type="button" phx-click="paper-unbind-property">Unbind</button>
    <button type="button" phx-click="inner-array-op">Array</button>
    <form phx-submit="paper-add-block"><select name="block-type"><option>paragraph</option></select></form>
    <div id="paper-canvas-probe-run-0" phx-hook="BarkparkPaperCanvas"><bp-paper-canvas></bp-paper-canvas></div>`;
  const wrapper = main.querySelector("[phx-hook]");
  wrapper.dataset.canvasBlocks = JSON.stringify(blocks);
  wrapper.dataset.canvasDataset = "production";
  document.body.appendChild(main);
  const canvas = wrapper.querySelector("bp-paper-canvas");
  const navigation = main.querySelector("a");
  const deleteButton = main.querySelector('[phx-click="paper-delete-block"]');
  const moveButton = main.querySelector('[phx-click="paper-move-block"]');
  const materializeButton = main.querySelector('[phx-click="paper-materialize-slot"]');
  const unbindButton = main.querySelector('[phx-click="paper-unbind-property"]');
  const arrayButton = main.querySelector('[phx-click="inner-array-op"]');
  const addForm = main.querySelector('[phx-submit="paper-add-block"]');
  let navigations = 0;
  const actions = [];
  navigation.addEventListener("click", event => { event.preventDefault(); navigations++; });
  for (const button of [deleteButton, moveButton, materializeButton, unbindButton, arrayButton]) {
    button.addEventListener("click", event => {
      event.preventDefault();
      actions.push(button.getAttribute("phx-click"));
    });
  }
  addForm.addEventListener("submit", event => {
    event.preventDefault();
    actions.push(addForm.getAttribute("phx-submit"));
  });
  const handlers = new Map();
  const requests = [];
  const hook = {...hooks.BarkparkPaperCanvas, el: wrapper,
    handleEvent: (name, fn) => handlers.set(name, fn),
    pushEvent: (name, payload) => {
      if (name === "paper-ops") {
        return new Promise((resolve, reject) => requests.push({payload, resolve, reject}));
      }
      if (name.startsWith("paper-") || name === "inner-array-op") actions.push(name);
      return Promise.resolve({saved:true, request_id:payload.request_id});
    },
  };
  hook.mounted();
  let toggles = 0;
  const toggle = {...hooks.BarkparkPaperEditToggle, el: main.querySelector("button"),
    pushEvent: () => { toggles++; return Promise.resolve({}); }};
  toggle.mounted();
  await new Promise(resolve => setTimeout(resolve, 350));
  assert.equal(requests.length, 0);
  return {canvas, requests, main, navigation, deleteButton, moveButton,
    materializeButton, unbindButton, arrayButton, addForm, actions,
    click: () => toggle.el.dispatchEvent(new window.MouseEvent("click", {bubbles:true, cancelable:true})),
    toggles: () => toggles,
    navigations: () => navigations,
    echo: (blocks, { retained_leases, retained_lease_overflow, ...meta } = {}) => handlers.get("bp:canvas-update")({
      ...meta,
      runs: [{
        run_id: "probe-run-0",
        blocks,
        ...(retained_leases === undefined ? {} : { retained_leases }),
        ...(retained_lease_overflow === undefined ? {} : { retained_lease_overflow }),
      }],
    }),
    update: () => hook.updated(),
    close: () => { toggle.destroyed(); hook.destroyed(); main.remove(); },
  };
}
function insert(canvas, value) {
  canvas._editor.commands.insertContentAt(canvas._editor.state.doc.content.size, {
    type: "paragraph", attrs: {bpId: null, bpType: "paragraph"}, content: [{type:"text",text:value}],
  });
}
function append(canvas, text) {
  canvas._editor.view.dispatch(canvas._editor.state.tr.insertText(text,
    canvas._editor.state.doc.content.size - 1));
}
function textOf(canvas) { return canvas._editor.state.doc.textContent; }
function inserted(batch) { return batch.payload.ops.find(op => op.op === "insert-after" || op.op === "append-block").block; }
function resolveSaved(request, saved) {
  request.resolve({saved, request_id: request.payload.request_id});
}
function beforeUnloadPrevented() {
  const event = new window.Event("beforeunload", {cancelable:true});
  window.dispatchEvent(event);
  return event.defaultPrevented;
}
async function waitFor(predicate, message) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  assert.fail(message);
}

try {
  const cleanExit = await mount();
  assert.equal(beforeUnloadPrevented(), false, "a clean editor installs no active unload guard");
  cleanExit.navigation.click();
  assert.equal(cleanExit.navigations(), 1, "clean Studio patch navigation is not delayed");
  cleanExit.close();

  const navigation = await mount();
  append(navigation.canvas, " before navigation");
  await new Promise(resolve => setTimeout(resolve, DEBOUNCE_MS - 1));
  assert.equal(navigation.canvas.hasPendingChanges(), true,
    "the guard sees a local edit one millisecond before its debounce fires");
  assert.equal(beforeUnloadPrevented(), true, "dirty content activates beforeunload protection");
  navigation.navigation.click();
  assert.equal(navigation.navigations(), 0, "Studio A→B patch waits for persistence");
  assert.equal(navigation.requests.length, 1, "navigation synchronously flushes the debounce");
  resolveSaved(navigation.requests[0], true);
  await tick();
  assert.equal(navigation.navigations(), 1, "the original Studio patch replays once after acknowledgement");
  assert.equal(beforeUnloadPrevented(), false, "the unload guard clears after exact acknowledgement");
  navigation.close();

  const refusedNavigation = await mount();
  append(refusedNavigation.canvas, " must remain local");
  refusedNavigation.navigation.click();
  assert.equal(refusedNavigation.requests.length, 1);
  resolveSaved(refusedNavigation.requests[0], false);
  await tick();
  assert.equal(refusedNavigation.navigations(), 0, "a failed save never replays navigation");
  assert.match(textOf(refusedNavigation.canvas), /must remain local/,
    "failed navigation preserves the exact mounted editor text");
  assert.equal(refusedNavigation.canvas.isConnected, true);
  assert.equal(beforeUnloadPrevented(), true, "failed persistence keeps unload protection active");
  refusedNavigation.close();

  const structural = await mount();
  append(structural.canvas, " before delete");
  structural.deleteButton.click();
  assert.deepEqual(structural.actions, [], "delete waits behind the content save");
  assert.equal(structural.requests.length, 1);
  resolveSaved(structural.requests[0], true);
  await tick();
  assert.deepEqual(structural.actions, ["paper-delete-block"],
    "delete replays once only after the acknowledged content write");
  append(structural.canvas, " before move");
  structural.moveButton.click();
  assert.deepEqual(structural.actions, ["paper-delete-block"], "move also waits for save");
  assert.equal(structural.requests.length, 2);
  resolveSaved(structural.requests[1], true);
  await tick();
  assert.deepEqual(structural.actions, ["paper-delete-block", "paper-move-block"]);

  for (const [control, expected] of [
    [structural.materializeButton, "paper-materialize-slot"],
    [structural.unbindButton, "paper-unbind-property"],
    [structural.arrayButton, "inner-array-op"],
  ]) {
    append(structural.canvas, ` before ${expected}`);
    control.click();
    assert.equal(structural.actions.includes(expected), false,
      `${expected} waits for pending content`);
    const request = structural.requests.at(-1);
    resolveSaved(request, true);
    await tick();
    assert.equal(structural.actions.at(-1), expected,
      `${expected} replays once after acknowledgement`);
  }

  for (const submitEvent of ["paper-add-block", "paper-add-property"]) {
    structural.addForm.setAttribute("phx-submit", submitEvent);
    append(structural.canvas, ` before ${submitEvent} Enter submit`);
    structural.addForm.dispatchEvent(new window.SubmitEvent("submit", {
      bubbles:true, cancelable:true,
    }));
    assert.equal(structural.actions.includes(submitEvent), false,
      `${submitEvent} Enter submit waits for pending content`);
    resolveSaved(structural.requests.at(-1), true);
    await tick();
    assert.equal(structural.actions.at(-1), submitEvent,
      `${submitEvent} submit replays once after acknowledgement`);
    assert.equal(structural.actions.filter(action => action === submitEvent).length, 1);
  }
  structural.close();

  // The owned counter starts from Phoenix's existing 41, then remains the
  // traversal authority even when a later foreign field also says position.
  window.history.replaceState(
    {position:41, type:"patch", id:"main", foreign:"base"},
    "",
    "/studio/papers/owned-41",
  );
  window.history.pushState(null, "", "/studio/papers/owned-42");
  assert.equal(window.history.state.__bpPaperHistoryPosition, 42,
    "a null push is marked at Phoenix position + 1");
  window.history.replaceState(
    {position:999, type:"patch", id:"main", foreign:"preserved"},
    "",
    "/studio/papers/owned-42",
  );
  assert.equal(window.history.state.__bpPaperHistoryPosition, 42);
  assert.equal(window.history.state.position, 999);
  assert.equal(window.history.state.foreign, "preserved");
  const ownedBack = await mount();
  append(ownedBack.canvas, " before owned mixed-position back");
  window.history.back();
  await waitFor(() => ownedBack.requests.length === 1,
    "owned position 42 should restore exactly one step before saving Back");
  assert.equal(window.location.pathname, "/studio/papers/owned-42");
  resolveSaved(ownedBack.requests[0], true);
  await waitFor(() => window.location.pathname === "/studio/papers/owned-41",
    "owned Back should replay exactly -1 after acknowledgement");
  ownedBack.close();
  const ownedForward = await mount();
  append(ownedForward.canvas, " before owned mixed-position forward");
  window.history.forward();
  await waitFor(() => ownedForward.requests.length === 1,
    "owned position 41 should restore exactly one step before saving Forward");
  assert.equal(window.location.pathname, "/studio/papers/owned-41");
  resolveSaved(ownedForward.requests[0], true);
  await waitFor(() => window.location.pathname === "/studio/papers/owned-42",
    "owned Forward should replay exactly +1 after acknowledgement");
  ownedForward.close();

  // The Navigation API fires before a traversal commits. Cancel it while dirty,
  // then traverse to the exact destination key only after the save barrier.
  const navigationBack = await mount();
  append(navigationBack.canvas, " before Navigation API back");
  const navigationBackEvent = new window.Event("navigate", { cancelable:true });
  Object.defineProperties(navigationBackEvent, {
    navigationType: { value:"traverse" },
    destination: { value:{ key:"navigation-back", index:40 } },
  });
  navigationIndex = 41;
  navigationEvents.dispatchEvent(navigationBackEvent);
  assert.equal(navigationBackEvent.defaultPrevented, true);
  assert.equal(navigationBack.requests.length, 1);
  assert.deepEqual(navigationTraversals, [], "Navigation Back waits before delivery");
  resolveSaved(navigationBack.requests[0], true);
  await waitFor(() => navigationTraversals.at(-1) === "navigation-back",
    "acknowledged Navigation Back should traverse to its exact key");
  navigationBack.close();

  const navigationForward = await mount();
  append(navigationForward.canvas, " preserve on Navigation API forward refusal");
  const navigationForwardEvent = new window.Event("navigate", { cancelable:true });
  Object.defineProperties(navigationForwardEvent, {
    navigationType: { value:"traverse" },
    destination: { value:{ key:"navigation-forward", index:42 } },
  });
  navigationEvents.dispatchEvent(navigationForwardEvent);
  assert.equal(navigationForwardEvent.defaultPrevented, true);
  assert.equal(navigationForward.requests.length, 1);
  resolveSaved(navigationForward.requests[0], false);
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(navigationTraversals.includes("navigation-forward"), false,
    "failed Navigation Forward remains cancelled");
  assert.match(textOf(navigationForward.canvas), /preserve on Navigation API forward refusal/);
  navigationForward.close();

  const rejectedTraversal = await mount();
  append(rejectedTraversal.canvas, " before rejected traversal");
  navigationResults.push({
    committed: Promise.resolve(),
    finished: Promise.reject(new Error("traversal refused")),
  });
  const rejectedTraversalEvent = new window.Event("navigate", { cancelable:true });
  Object.defineProperties(rejectedTraversalEvent, {
    navigationType: { value:"traverse" },
    destination: { value:{ key:"navigation-retry", index:40 } },
  });
  navigationEvents.dispatchEvent(rejectedTraversalEvent);
  resolveSaved(rejectedTraversal.requests[0], true);
  await waitFor(() => navigationTraversals.at(-1) === "navigation-retry",
    "the rejected traversal should still have attempted its exact key");
  await tick();
  append(rejectedTraversal.canvas, " then retry safely");
  const retryTraversalEvent = new window.Event("navigate", { cancelable:true });
  Object.defineProperties(retryTraversalEvent, {
    navigationType: { value:"traverse" },
    destination: { value:{ key:"navigation-retry", index:40 } },
  });
  navigationEvents.dispatchEvent(retryTraversalEvent);
  assert.equal(retryTraversalEvent.defaultPrevented, true,
    "a rejected traversal clears replay state before the same destination retries");
  assert.equal(rejectedTraversal.requests.length, 2,
    "the subsequent traversal crosses a fresh save barrier");
  resolveSaved(rejectedTraversal.requests[1], true);
  await waitFor(() => navigationTraversals.filter(key => key === "navigation-retry").length === 2,
    "a successful subsequent traversal should replay normally");
  rejectedTraversal.close();
  navigationIndex = undefined;

  window.history.replaceState({position:0, type:"patch", id:"main"}, "", "/studio/papers/native-a");
  const nativeBack = await mount();
  window.history.pushState({position:1, type:"patch", id:"main"}, "", "/studio/papers/native-b");
  window.dispatchEvent(new window.CustomEvent("phx:navigate", {
    detail:{patch:true, href:window.location.href},
  }));
  append(nativeBack.canvas, " before browser back");
  let deliveredBacks = 0;
  const onDeliveredBack = () => { deliveredBacks++; };
  window.addEventListener("popstate", onDeliveredBack);
  window.history.back();
  await waitFor(() => nativeBack.requests.length === 1,
    "native Back should restore the current entry and flush its pending edit");
  assert.equal(window.location.pathname, "/studio/papers/native-b");
  assert.equal(deliveredBacks, 0, "LiveView does not receive Back before save acknowledgement");
  window.history.back();
  await waitFor(() => window.location.pathname === "/studio/papers/native-b",
    "repeated Back during the save should also restore the mounted editor entry");
  assert.equal(nativeBack.requests.length, 1, "repeated Back shares the active save barrier");
  assert.equal(deliveredBacks, 0, "repeated Back is not delivered before acknowledgement");
  resolveSaved(nativeBack.requests[0], true);
  await waitFor(() => deliveredBacks === 1,
    "acknowledgement should replay the original browser Back");
  assert.equal(window.location.pathname, "/studio/papers/native-a");
  window.removeEventListener("popstate", onDeliveredBack);
  nativeBack.close();

  window.history.replaceState({backType:"patch", id:"main"}, "", "/studio/papers/initial-a");
  window.history.pushState({position:1, type:"patch", id:"main"}, "", "/studio/papers/initial-b");
  const initialEntryBack = await mount();
  append(initialEntryBack.canvas, " before initial-entry back");
  let deliveredInitialBacks = 0;
  const onDeliveredInitialBack = () => { deliveredInitialBacks++; };
  window.addEventListener("popstate", onDeliveredInitialBack);
  window.history.back();
  await waitFor(() => initialEntryBack.requests.length === 1,
    "Back to LiveView's position-less initial entry should still flush pending edits");
  assert.equal(window.location.pathname, "/studio/papers/initial-b");
  assert.equal(deliveredInitialBacks, 0);
  resolveSaved(initialEntryBack.requests[0], true);
  await waitFor(() => deliveredInitialBacks === 1,
    "the acknowledged Back should replay to LiveView's initial position zero");
  assert.equal(window.location.pathname, "/studio/papers/initial-a");
  window.removeEventListener("popstate", onDeliveredInitialBack);
  initialEntryBack.close();

  // Entries created after the editor hooks load are owned even when callers
  // supply null state. The marker preserves exact Back/Forward direction while
  // leaving Phoenix's public position field absent.
  window.history.replaceState(null, "", "/studio/papers/null-a");
  window.history.pushState(null, "", "/studio/papers/null-b");
  assert.equal(window.history.state.position, undefined);
  const nullStateBack = await mount();
  append(nullStateBack.canvas, " before null-state back");
  let deliveredNullBacks = 0;
  const onDeliveredNullBack = () => { deliveredNullBacks++; };
  window.addEventListener("popstate", onDeliveredNullBack);
  window.history.back();
  await waitFor(() => nullStateBack.requests.length === 1,
    "owned null-state Back should restore and flush before delivery");
  assert.equal(window.location.pathname, "/studio/papers/null-b");
  assert.equal(deliveredNullBacks, 0);
  resolveSaved(nullStateBack.requests[0], true);
  await waitFor(() => deliveredNullBacks === 1,
    "owned null-state Back should replay after acknowledgement");
  assert.equal(window.location.pathname, "/studio/papers/null-a");
  window.removeEventListener("popstate", onDeliveredNullBack);
  nullStateBack.close();

  const nullStateForward = await mount();
  append(nullStateForward.canvas, " preserve on null-state forward refusal");
  let deliveredNullForwards = 0;
  const onDeliveredNullForward = () => { deliveredNullForwards++; };
  window.addEventListener("popstate", onDeliveredNullForward);
  window.history.forward();
  await waitFor(() => nullStateForward.requests.length === 1,
    "owned null-state Forward should restore and flush before delivery");
  assert.equal(window.location.pathname, "/studio/papers/null-a");
  assert.equal(deliveredNullForwards, 0);
  resolveSaved(nullStateForward.requests[0], false);
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(window.location.pathname, "/studio/papers/null-a");
  assert.equal(deliveredNullForwards, 0, "failed null-state Forward remains cancelled");
  assert.match(textOf(nullStateForward.canvas), /preserve on null-state forward refusal/);
  window.removeEventListener("popstate", onDeliveredNullForward);
  nullStateForward.close();

  window.history.replaceState({position:0, type:"patch", id:"main"}, "", "/studio/papers/refused-a");
  window.history.pushState({position:1, type:"patch", id:"main"}, "", "/studio/papers/refused-b");
  const refusedBack = await mount();
  append(refusedBack.canvas, " preserve on refused browser back");
  let refusedBackDelivered = 0;
  const onRefusedBack = () => { refusedBackDelivered++; };
  window.addEventListener("popstate", onRefusedBack);
  window.history.back();
  await waitFor(() => refusedBack.requests.length === 1,
    "refused Back should still attempt an exact save");
  resolveSaved(refusedBack.requests[0], false);
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(window.location.pathname, "/studio/papers/refused-b");
  assert.equal(refusedBackDelivered, 0, "failed save cancels browser Back");
  assert.match(textOf(refusedBack.canvas), /preserve on refused browser back/);
  window.removeEventListener("popstate", onRefusedBack);
  refusedBack.close();

  window.history.replaceState({position:0, type:"patch", id:"main"}, "", "/studio/papers/forward-a");
  window.history.pushState({position:1, type:"patch", id:"main"}, "", "/studio/papers/forward-b");
  window.history.back();
  await waitFor(() => window.location.pathname === "/studio/papers/forward-a",
    "test setup should expose a Forward entry");
  const nativeForward = await mount();
  append(nativeForward.canvas, " before browser forward");
  let deliveredForwards = 0;
  const onDeliveredForward = () => { deliveredForwards++; };
  window.addEventListener("popstate", onDeliveredForward);
  window.history.forward();
  await waitFor(() => nativeForward.requests.length === 1,
    "native Forward should restore the current entry and flush its pending edit");
  assert.equal(window.location.pathname, "/studio/papers/forward-a");
  assert.equal(deliveredForwards, 0);
  resolveSaved(nativeForward.requests[0], true);
  await waitFor(() => deliveredForwards === 1,
    "acknowledgement should replay the original browser Forward");
  assert.equal(window.location.pathname, "/studio/papers/forward-b");
  window.removeEventListener("popstate", onDeliveredForward);
  nativeForward.close();

  window.history.replaceState({position:0, type:"patch", id:"main"}, "", "/studio/papers/multi-a");
  window.history.pushState({position:1, type:"patch", id:"main"}, "", "/studio/papers/multi-b");
  window.history.pushState({position:2, type:"patch", id:"main"}, "", "/studio/papers/multi-c");
  const multiBack = await mount();
  append(multiBack.canvas, " before multi-step back");
  let deliveredMultiBack = 0;
  const onDeliveredMultiBack = () => { deliveredMultiBack++; };
  window.addEventListener("popstate", onDeliveredMultiBack);
  window.history.go(-2);
  await waitFor(() => multiBack.requests.length === 1,
    "multi-step Back should restore by the full history delta before saving");
  assert.equal(window.location.pathname, "/studio/papers/multi-c");
  resolveSaved(multiBack.requests[0], true);
  await waitFor(() => deliveredMultiBack === 1,
    "multi-step Back should replay its full history delta after saving");
  assert.equal(window.location.pathname, "/studio/papers/multi-a");
  window.removeEventListener("popstate", onDeliveredMultiBack);
  multiBack.close();

  const test = await mount();
  insert(test.canvas, "Alpha");
  test.canvas.flushPendingChanges();
  assert.equal(test.requests.length, 1);
  const first = test.requests[0];
  const block = inserted(first);
  assert.ok(block.id, "a newly inserted node has a stable wire identity");
  append(test.canvas, " beta");
  test.canvas.flushPendingChanges();
  assert.equal(test.requests.length, 1, "newer local input waits behind the in-flight save");
  test.echo([paragraph("original", "Original"), block]);
  assert.match(textOf(test.canvas), /Alpha beta/, "a delayed own echo cannot overwrite newer input");
  resolveSaved(first, true);
  await tick();
  assert.equal(test.requests.length, 2, "acknowledgement sends the newer incremental edit");
  const second = test.requests[1];
  assert.equal(second.payload.ops.filter(op => op.op === "insert-after" || op.op === "append-block").length, 0,
    "the next batch cannot reinsert the same paragraph");
  assert.ok(second.payload.ops.some(op => op.id === block.id && op.patch?.content?.[0]?.value === "Alpha beta"));
  test.echo([paragraph("original", "Original"), paragraph(block.id, "Alpha beta")]);
  resolveSaved(second, true);
  await tick();
  assert.match(textOf(test.canvas), /Alpha beta/);
  test.close();

  const retry = await mount();
  insert(retry.canvas, "Before source");
  retry.canvas.flushPendingChanges();
  const failed = retry.requests[0];
  const initialPayload = JSON.stringify(failed.payload);
  resolveSaved(failed, false);
  await tick();
  for (const value of ["First source change", "Second source change"]) {
    retry.canvas.toggleSourceMode();
    const source = retry.canvas.querySelector(".bp-canvas-source");
    source.value = "Original\n\n" + value;
    source.dispatchEvent(new Event("input", {bubbles:true}));
    retry.canvas.toggleSourceMode();
  }
  assert.equal(retry.requests.length, 1, "source edits remain local until the failed head is retried");
  retry.click();
  assert.equal(retry.requests.length, 2);
  assert.equal(JSON.stringify(retry.requests[1].payload), initialPayload, "retry preserves the original batch identity");
  const firstInsert = inserted(failed);
  retry.echo([paragraph("original", "Original"), firstInsert]);
  resolveSaved(retry.requests[1], true);
  await tick();
  assert.equal(retry.requests.length, 3, "only the final source state follows the retried head");
  const final = retry.requests[2];
  assert.equal(final.payload.ops.filter(op => op.op === "insert-after" || op.op === "append-block").length, 0);
  assert.ok(final.payload.ops.some(op => op.id === firstInsert.id && op.patch?.content?.[0]?.value === "Second source change"));
  assert.equal(retry.toggles(), 0, "View waits for the final source state");
  retry.echo([paragraph("original", "Original"), paragraph(firstInsert.id, "Second source change")]);
  resolveSaved(final, true);
  await tick();
  assert.equal(retry.toggles(), 1);
  assert.match(textOf(retry.canvas), /Second source change/);
  retry.close();
  for (const choice of ["latest", "keep"]) {
    const survivor = paragraph("survivor", "Retained paragraph");
    const deleting = await mount({ revision: 1, blocks: [paragraph("original", "Original"), survivor] });
    deleting.canvas._editor.commands.focus("start");
    await new Promise(resolve => setTimeout(resolve, 30));
    const remote = [paragraph("original", "Other author changed this paragraph"), survivor];
    deleting.echo(remote, { rev: 2 });
    deleting.canvas._editor.view.dispatch(deleting.canvas._editor.state.tr.delete(
      0, deleting.canvas._editor.state.doc.firstChild.nodeSize));
    deleting.canvas.flushPendingChanges();
    await tick();
    assert.equal(deleting.requests.length, 0,
      "deleting an unseen remotely changed paragraph requires review before sending");
    assert.equal(textOf(deleting.canvas), "Retained paragraph", "the local deletion remains visible");
    deleting.main.querySelector(`[data-action="${choice}"]`).click();
    await tick();
    if (choice === "keep") {
      assert.equal(deleting.requests.length, 1);
      const request = deleting.requests[0];
      assert.deepEqual(request.payload.ops, [{ op: "remove-block", id: "original" }]);
      assert.equal(request.payload.if_rev, 2);
      deleting.echo([survivor], { rev: 3, request_id: request.payload.request_id });
      request.resolve({ saved: true, rev: 3, request_id: request.payload.request_id });
      await tick();
    } else {
      assert.equal(deleting.requests.length, 0, "Use latest never sends the discarded deletion");
      assert.deepEqual(deleting.canvas._blocks, remote);
    }
    assert.equal(deleting.canvas.hasPendingChanges(), false);
    assert.equal(beforeUnloadPrevented(), false);
    deleting.close();
  }
  for (const choice of ["latest", "latest-newer", "keep", "keep-ack-first", "keep-typing", "keep-typing-echo-first"]) {
    const continuedTyping = choice.startsWith("keep-typing");
    const overlap = await mount({ revision: 1 });
    overlap.canvas._editor.commands.focus("end");
    await new Promise(resolve => setTimeout(resolve, 30));
    const remote = [{ ...paragraph("original", "Other author text"), audit: { author: "other" } },
      paragraph("remote-sibling", "Remote sibling")];
    overlap.echo(remote, { rev: 2 });
    assert.equal(textOf(overlap.canvas), "Original", "remote text is deferred while focused");
    append(overlap.canvas, " local draft");
    overlap.canvas.flushPendingChanges();
    await tick();
    assert.equal(overlap.requests.length, 0,
      "overlapping text must request review before sending a silent overwrite");
    assert.ok(overlap.main.querySelector("[data-bp-paper-conflict]"));
    assert.equal(beforeUnloadPrevented(), true);
    overlap.click();
    await tick();
    assert.equal(overlap.toggles(), 0, "View retains an unresolved overlapping draft");
    if (choice === "latest-newer") {
      overlap.echo([{ ...remote[0], content: paragraph("original", "Newest remote text").content }, remote[1]], { rev: 4 });
    }
    if (continuedTyping) {
      append(overlap.canvas, " continued");
      overlap.canvas.flushPendingChanges();
    }
    overlap.main.querySelector(`[data-action="${choice.startsWith("latest") ? "latest" : "keep"}"]`).click();
    await tick();
    if (choice.startsWith("latest")) {
      assert.equal(overlap.requests.length, 0, "Use latest never writes the discarded draft");
      assert.equal(overlap.canvas._editor.state.doc.firstChild.textContent,
        choice === "latest-newer" ? "Newest remote text" : "Other author text");
    } else {
      assert.equal(overlap.requests.length, 1, "Keep mine explicitly authorizes one write");
      const request = overlap.requests[0];
      assert.equal(request.payload.if_rev, 2);
      assert.equal(request.payload.reviewRequired, undefined, "review state is never server payload");
      const accepted = [{ ...remote[0], content: paragraph("original", "Original local draft").content }, remote[1]];
      if (choice !== "keep-ack-first" && choice !== "keep-typing") {
        overlap.echo(accepted, { rev: 3, request_id: request.payload.request_id });
      }
      request.resolve({ saved: true, rev: 3, request_id: request.payload.request_id });
      await tick();
      if (choice === "keep-ack-first" || choice === "keep-typing") {
        overlap.echo(accepted, { rev: 3, request_id: request.payload.request_id });
        await tick();
      }
      if (continuedTyping) {
        assert.equal(overlap.main.querySelector("[data-bp-paper-conflict]"), null,
          "continued typing must not reopen a resolved overlap against stale remote text");
        assert.equal(overlap.requests.length, 2, "the continued draft saves after the chosen snapshot");
        const continued = overlap.requests[1];
        assert.equal(continued.payload.if_rev, 3);
        overlap.echo([{ ...accepted[0], content: paragraph("original", "Original local draft continued").content }, remote[1]],
          { rev: 4, request_id: continued.payload.request_id });
        continued.resolve({ saved: true, rev: 4, request_id: continued.payload.request_id });
        await tick();
      }
      overlap.canvas._editor.commands.blur();
      await new Promise(resolve => setTimeout(resolve, 30));
      assert.equal(overlap.canvas._editor.state.doc.firstChild.textContent,
        continuedTyping ? "Original local draft continued" : "Original local draft");
    }
    assert.equal(overlap.canvas._editor.state.doc.childCount, 2, `${choice}: the remote sibling survives`);
    assert.deepEqual(overlap.canvas._blocks[0].audit, { author: "other" });
    assert.equal(overlap.canvas.hasPendingChanges(), false, `${choice}: the canvas settles`);
    assert.equal(beforeUnloadPrevented(), false, `${choice}: unload protection releases only after resolution`);
    overlap.close();
  }

  // The server pins a slash-inserted boundary to its originating run for the
  // current editing session. A full-run acknowledgement must therefore be a
  // history-neutral echo: the ignored canvas remains the sole mounted owner and
  // native undo still removes only the insertion.
  for (const type of ["table", "section"]) {
    const handoff = await mount({ revision: 1 });
    handoff.canvas._editor.view.dispatch(
      handoff.canvas._editor.state.tr.insertText(" kept", 9),
    );
    handoff.canvas._editor.view.dispatch(closeHistory(handoff.canvas._editor.state.tr));
    handoff.canvas._editor.commands.insertContentAt(
      handoff.canvas._editor.state.doc.content.size,
      slashTypeToNode(type),
    );
    handoff.canvas.flushPendingChanges();
    assert.equal(handoff.requests.length, 1, `${type}: slash boundary saves once`);
    const request = handoff.requests[0];
    const boundary = inserted(request);
    handoff.canvas._editor.commands.setTextSelection(2);
    handoff.canvas._editor.commands.focus();
    const selectionBefore = handoff.canvas._editor.state.selection.from;
    const historyBefore = undoDepth(handoff.canvas._editor.state);

    const acknowledgedRun = [paragraph("original", "Original kept"), boundary];
    handoff.echo(acknowledgedRun, {
      rev: 2,
      request_id: request.payload.request_id,
    });
    request.resolve({ saved: true, rev: 2, request_id: request.payload.request_id });
    await tick();

    const pinnedNodes = handoff.canvas._editor.getJSON().content.filter(
      node => node.attrs?.bpId === boundary.id,
    );
    assert.equal(pinnedNodes.length, 1,
      `${type}: acknowledged boundary has exactly one node in its pinned canvas`);
    let pinnedDom = null;
    handoff.canvas._editor.state.doc.forEach((node, offset) => {
      if (node.attrs?.bpId === boundary.id) pinnedDom = handoff.canvas._editor.view.nodeDOM(offset);
    });
    assert.ok(pinnedDom && !pinnedDom.hidden,
      `${type}: the pinned originating owner remains visibly mounted`);
    assert.equal(handoff.canvas._editor.state.selection.from, selectionBefore,
      `${type}: a prose selection survives the ownership handoff`);
    assert.equal(undoDepth(handoff.canvas._editor.state), historyBefore,
      `${type}: a full-run acknowledgement neither consumes nor adds canvas history`);
    assert.equal(handoff.canvas._editor.commands.undo(), true,
      `${type}: native undo remains available after acknowledgement`);
    assert.equal(
      handoff.canvas._editor.getJSON().content.some(node => node.attrs?.bpId === boundary.id),
      false,
      `${type}: native undo removes the acknowledged insertion`,
    );
    assert.equal(handoff.canvas._editor.state.doc.firstChild.textContent, "Original kept",
      `${type}: undo preserves the unrelated earlier prose history step`);
    handoff.canvas.flushPendingChanges();
    assert.equal(handoff.requests.length, 2,
      `${type}: undo emits one follow-up persistence request`);
    assert.deepEqual(handoff.requests[1].payload.ops, [
      { op: "remove-block", id: boundary.id },
    ], `${type}: native undo persists as removal of the retained boundary only`);
    handoff.close();
  }

  // A LiveView reconnect creates a fresh server process while the browser keeps
  // the phx-update=ignore canvas mounted. Until the new process learns which
  // accepted boundary that canvas still owns, its first render must not add a
  // second contextual owner for the same stored block.
  const reconnectOwnership = await mount({ revision: 1 });
  reconnectOwnership.main.querySelector("[phx-hook]").dataset.paperContainerKind = "document";
  reconnectOwnership.canvas._editor.view.dispatch(
    closeHistory(reconnectOwnership.canvas._editor.state.tr),
  );
  reconnectOwnership.canvas._editor.commands.insertContentAt(
    reconnectOwnership.canvas._editor.state.doc.content.size,
    slashTypeToNode("table"),
  );
  reconnectOwnership.canvas.flushPendingChanges();
  const reconnectSave = reconnectOwnership.requests[0];
  const reconnectTable = inserted(reconnectSave);
  const reconnectLease = "signed-opaque-table-lease";
  document.body.prepend(reconnectOwnership.main);
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_editing_key: "paper-overlap-probe",
      paper_canvas_lease_key: "paper-overlap-probe",
      paper_canvas_lease_pending: true,
    },
    "a join during an unacknowledged boundary insertion freezes ownership without exposing its draft",
  );
  reconnectOwnership.echo([paragraph("original", "Original"), reconnectTable], {
    rev: 2,
    request_id: reconnectSave.payload.request_id,
  });
  reconnectSave.resolve({
    saved: true,
    rev: 2,
    request_id: reconnectSave.payload.request_id,
    retained_leases: [reconnectLease],
  });
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_editing_key: "paper-overlap-probe",
      paper_canvas_lease_key: "paper-overlap-probe",
      paper_canvas_leases: [reconnectLease],
    },
    "the successful reply installs its signed lease before the save queue settles even if its echo was lost",
  );
  reconnectOwnership.echo([paragraph("original", "Original"), reconnectTable], {
    rev: 2,
    request_id: reconnectSave.payload.request_id,
    retained_leases: [reconnectLease],
  });
  await tick();
  const retainedCanvas = reconnectOwnership.canvas;
  const retainedEditor = retainedCanvas._editor;

  const reconnectParams = JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams()));
  assert.deepEqual(reconnectParams, {
    paper_editing_key: "paper-overlap-probe",
    paper_canvas_lease_key: "paper-overlap-probe",
    paper_canvas_leases: [reconnectLease],
  }, "the next join carries only the opaque lease for the current acknowledged canvas owner");

  // Model the fresh server's first render: without the lease it would partition
  // the stored Table back to its contextual editor while the ignored canvas is
  // still alive. A resumed lease keeps that second owner out of the HTML.
  if (!reconnectParams.paper_canvas_leases?.includes(reconnectLease)) {
    const freshContextualOwner = document.createElement("div");
    freshContextualOwner.dataset.testId = "paper-table-contextual-editor";
    freshContextualOwner.dataset.blockId = reconnectTable.id;
    reconnectOwnership.main.appendChild(freshContextualOwner);
  }
  assert.equal(reconnectOwnership.main.outerHTML.includes(reconnectLease), false,
    "opaque reconnect leases never enter rendered attributes or persisted source data");
  retainedEditor.view.dispatch(closeHistory(retainedEditor.state.tr));
  retainedEditor.view.dispatch(retainedEditor.state.tr.insertText(" newer", 9));
  const retainedHistory = undoDepth(retainedEditor.state);
  reconnectOwnership.update();

  assert.equal(reconnectOwnership.canvas, retainedCanvas,
    "LiveView reconnect preserves the ignored canvas element");
  assert.equal(reconnectOwnership.canvas._editor, retainedEditor,
    "LiveView reconnect preserves the ignored canvas editor and its history");
  assert.equal(retainedEditor.state.doc.firstChild.textContent, "Original newer",
    "newer prose typed after the ownership acknowledgement survives reconnect update");
  assert.equal(undoDepth(retainedEditor.state), retainedHistory,
    "reconnect update preserves insertion and newer-prose history");
  const canvasOwners = retainedEditor.getJSON().content.filter(
    node => node.attrs?.bpId === reconnectTable.id,
  ).length;
  const contextualOwners = reconnectOwnership.main.querySelectorAll(
    `[data-test-id="paper-table-contextual-editor"][data-block-id="${reconnectTable.id}"]`,
  ).length;
  assert.equal(canvasOwners + contextualOwners, 1,
    "a fresh LiveView cannot add a contextual owner while the ignored canvas retains the acknowledged Table");
  assert.equal(retainedEditor.commands.undo(), true,
    "native undo remains available for typing after reconnect");
  assert.equal(retainedEditor.state.doc.firstChild.textContent, "Original",
    "the first native undo removes only the newer prose");
  assert.equal(retainedEditor.commands.undo(), true,
    "the acknowledged insertion remains in native history after reconnect");
  assert.equal(retainedEditor.getJSON().content.some(
    node => node.attrs?.bpId === reconnectTable.id,
  ), false, "the second native undo removes the retained Table insertion");
  reconnectOwnership.close();

  const leaseControls = await mount({ revision: 8, blocks: [paragraph("private-draft", "Private draft")] });
  document.body.prepend(leaseControls.main);
  const boundedLeases = ["lease-0", "lease-0", ...Array.from(
    { length: 64 },
    (_unused, index) => `lease-${index}`,
  )];
  leaseControls.echo([paragraph("private-draft", "Private draft")], {
    rev: 8,
    retained_leases: boundedLeases,
  });
  await tick();
  const boundedParams = JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams()));
  assert.equal(boundedParams.paper_canvas_leases.length, 64,
    "reconnect lease count is strictly bounded");
  assert.equal(new Set(boundedParams.paper_canvas_leases).size, 64,
    "reconnect leases are deduplicated");
  assert.equal(boundedParams.paper_canvas_leases.some((lease) => lease.length > 2048), false,
    "oversized reconnect leases are omitted");
  assert.equal(JSON.stringify(boundedParams).includes("Private draft"), false,
    "reconnect params never contain canvas blocks or draft text");

  leaseControls.echo([paragraph("private-draft", "Private draft")], {
    rev: 8,
    retained_leases: Array.from({ length: 65 }, (_unused, index) => `overflow-${index}`),
  });
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_editing_key: "paper-overlap-probe",
      paper_canvas_lease_key: "paper-overlap-probe",
      paper_canvas_lease_overflow: true,
    },
    "a per-wrapper lease overflow halts reconnect without sending a dangerous partial owner set",
  );
  leaseControls.echo([paragraph("private-draft", "Private draft")], {
    rev: 8,
    retained_leases: boundedLeases,
  });
  await tick();
  leaseControls.echo([paragraph("private-draft", "Private draft")], {
    rev: 8,
    retained_leases: ["x".repeat(2049)],
  });
  await tick();
  assert.equal(window.BarkparkPaperEditorConnectParams().paper_canvas_lease_overflow, true,
    "an oversized opaque token halts reconnect instead of being silently omitted");
  leaseControls.echo([paragraph("private-draft", "Private draft")], {
    rev: 8,
    retained_leases: Array.from({ length: 40 }, (_unused, index) => `shared-a-${index}`),
  });
  await tick();

  const extraWrapper = document.createElement("div");
  extraWrapper.id = "paper-canvas-extra-run";
  extraWrapper.setAttribute("phx-hook", "BarkparkPaperCanvas");
  extraWrapper.dataset.canvasBlocks = JSON.stringify([paragraph("extra", "Extra")]);
  extraWrapper.innerHTML = "<bp-paper-canvas></bp-paper-canvas>";
  leaseControls.main.appendChild(extraWrapper);
  const extraHandlers = new Map();
  const extraHook = {
    ...hooks.BarkparkPaperCanvas,
    el: extraWrapper,
    handleEvent: (name, handler) => extraHandlers.set(name, handler),
    pushEvent: () => Promise.resolve({ saved: true }),
  };
  extraHook.mounted();
  extraHandlers.get("bp:canvas-update")({
    rev: 8,
    runs: [{
      run_id: "extra-run",
      blocks: [paragraph("extra", "Extra")],
      retained_leases: Array.from({ length: 30 }, (_unused, index) => `shared-b-${index}`),
    }],
  });
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_editing_key: "paper-overlap-probe",
      paper_canvas_lease_key: "paper-overlap-probe",
      paper_canvas_lease_overflow: true,
    },
    "aggregate leases across current-document wrappers are all-or-nothing when the document bound is exceeded",
  );
  extraHook.destroyed();
  extraWrapper.remove();
  leaseControls.echo([paragraph("private-draft", "Private draft")], {
    rev: 8,
    retained_leases: boundedLeases,
  });
  await tick();

  const wrongDocument = await mount({ revision: 4 });
  wrongDocument.main.dataset.paperDocKey = "production:paper:other";
  wrongDocument.echo([paragraph("original", "Original")], {
    rev: 4,
    retained_leases: ["wrong-document-lease"],
  });
  await tick();
  document.body.prepend(leaseControls.main);
  assert.equal(
    window.BarkparkPaperEditorConnectParams().paper_canvas_leases.includes("wrong-document-lease"),
    false,
    "a live wrapper belonging to another document cannot contribute a reconnect lease",
  );

  leaseControls.echo([paragraph("private-draft", "Private draft")], {
    rev: 8,
    retained_leases: [],
  });
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    { paper_editing_key: "paper-overlap-probe" },
    "an authoritative matching-run echo clears leases removed by the server",
  );
  wrongDocument.close();
  leaseControls.close();

  const replacementPending = await mount({ revision: 11 });
  replacementPending.main.querySelector("[phx-hook]").dataset.paperContainerKind = "document";
  document.body.prepend(replacementPending.main);
  replacementPending.main.querySelector("[phx-hook]").dispatchEvent(new window.CustomEvent(
    "bp-canvas-ops",
    {
      bubbles: true,
      detail: {
        seq: 1,
        ops: [{
          op: "replace-block",
          id: "original",
          block: {
            id: "replacement-section",
            type: "section",
            title: "New section",
            blocks: [paragraph("replacement-child", "")],
          },
        }],
      },
    },
  ));
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_editing_key: "paper-overlap-probe",
      paper_canvas_lease_key: "paper-overlap-probe",
      paper_canvas_lease_pending: true,
    },
    "slash replacement is lease-pending before its server acknowledgement",
  );
  replacementPending.requests[0].resolve({
    saved: true,
    rev: 12,
    request_id: replacementPending.requests[0].payload.request_id,
    retained_leases: [],
  });
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    { paper_editing_key: "paper-overlap-probe" },
    "an authoritative successful reply with no retained owner clears replacement pending state",
  );
  replacementPending.close();

  const overflowReply = await mount({ revision: 13 });
  overflowReply.main.querySelector("[phx-hook]").dataset.paperContainerKind = "document";
  document.body.prepend(overflowReply.main);
  overflowReply.canvas._editor.commands.insertContentAt(
    overflowReply.canvas._editor.state.doc.content.size,
    slashTypeToNode("table"),
  );
  overflowReply.canvas.flushPendingChanges();
  overflowReply.requests[0].resolve({
    saved: true,
    rev: 14,
    request_id: overflowReply.requests[0].payload.request_id,
    retained_leases: [],
    retained_lease_overflow: true,
  });
  await tick();
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_editing_key: "paper-overlap-probe",
      paper_canvas_lease_key: "paper-overlap-probe",
      paper_canvas_lease_overflow: true,
    },
    "a successful issuance-overflow reply cannot clear recovery with an empty lease list",
  );
  overflowReply.close();

  const queuedBoundaries = await mount({ revision: 20 });
  queuedBoundaries.main.querySelector("[phx-hook]").dataset.paperContainerKind = "document";
  document.body.prepend(queuedBoundaries.main);
  queuedBoundaries.canvas._editor.commands.insertContentAt(
    queuedBoundaries.canvas._editor.state.doc.content.size,
    slashTypeToNode("table"),
  );
  queuedBoundaries.canvas.flushPendingChanges();
  const firstBoundarySave = queuedBoundaries.requests[0];
  const firstQueuedBoundary = inserted(firstBoundarySave);
  queuedBoundaries.canvas._editor.commands.insertContentAt(
    queuedBoundaries.canvas._editor.state.doc.content.size,
    slashTypeToNode("section"),
  );
  queuedBoundaries.canvas.flushPendingChanges();
  assert.equal(queuedBoundaries.requests.length, 1,
    "the second boundary batch waits behind the active request");
  queuedBoundaries.echo([paragraph("original", "Original"), firstQueuedBoundary], {
    rev: 21,
    request_id: firstBoundarySave.payload.request_id,
    retained_leases: ["first-boundary-lease"],
  });
  firstBoundarySave.resolve({
    saved: true,
    rev: 21,
    request_id: firstBoundarySave.payload.request_id,
    retained_leases: ["first-boundary-lease"],
  });
  await tick();
  assert.equal(queuedBoundaries.requests.length, 2,
    "the queued boundary begins saving after the first acknowledgement");
  assert.deepEqual(
    JSON.parse(JSON.stringify(window.BarkparkPaperEditorConnectParams())),
    {
      paper_editing_key: "paper-overlap-probe",
      paper_canvas_lease_key: "paper-overlap-probe",
      paper_canvas_leases: ["first-boundary-lease"],
      paper_canvas_lease_pending: true,
    },
    "the first reply and echo cannot clear reconnect pending while a later boundary batch is unacknowledged",
  );
  const secondBoundarySave = queuedBoundaries.requests[1];
  secondBoundarySave.resolve({
    saved: true,
    rev: 22,
    request_id: secondBoundarySave.payload.request_id,
    retained_leases: ["first-boundary-lease", "second-boundary-lease"],
  });
  await tick();
  assert.equal(window.BarkparkPaperEditorConnectParams().paper_canvas_lease_pending, undefined,
    "pending clears only after every queued boundary receives an authoritative lease reply");
  queuedBoundaries.close();

  const slashSection = await mount({ revision: 5 });
  slashSection.canvas._editor.commands.insertContentAt(
    slashSection.canvas._editor.state.doc.content.size,
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" },
      content: [{ type: "text", text: "draft" }],
    },
  );
  slashSection.canvas._editor.commands.setTextSelection(
    slashSection.canvas._editor.state.doc.content.size - 1,
  );
  const { insertSlashTypeAtSelection } = await import("./command-palette.js");
  assert.equal(insertSlashTypeAtSelection(slashSection.canvas._editor, "section"), true);
  slashSection.canvas.flushPendingChanges();
  const slashSectionSave = slashSection.requests[0];
  const slashSectionBlock = inserted(slashSectionSave);
  assert.deepEqual(slashSectionBlock.blocks[0].content, [
    { type: "text", value: "" },
  ], "the faithful slash-section request carries the server-stored empty text leaf");
  slashSection.echo([paragraph("original", "Original"), slashSectionBlock], {
    rev: 6,
    request_id: slashSectionSave.payload.request_id,
  });
  slashSectionSave.resolve({
    saved: true,
    rev: 6,
    request_id: slashSectionSave.payload.request_id,
  });
  await tick();
  assert.equal(slashSection.canvas._editor.commands.undo(), true,
    "a real slash-section replacement remains undoable after its full-run acknowledgement");
  assert.equal(
    slashSection.canvas._editor.getJSON().content.some(
      node => node.attrs?.bpId === slashSectionBlock.id,
    ),
    false,
    "slash-section undo removes the acknowledged inserted section",
  );
  assert.equal(slashSection.canvas._editor.state.doc.lastChild.textContent, "draft",
    "slash-section undo restores the trigger paragraph as a separate history event");
  slashSection.canvas.flushPendingChanges();
  assert.deepEqual(slashSection.requests[1].payload.ops.map(op => op.op), [
    "remove-block",
    "insert-after",
  ], "slash-section undo persists the replacement reversal");
  assert.equal(slashSection.requests[1].payload.ops[0].id, slashSectionBlock.id);
  assert.deepEqual(slashSection.requests[1].payload.ops[1].block.content, [
    { type: "text", value: "draft" },
  ]);
  slashSection.close();

  const tableRedo = await mount({
    revision: 10,
    blocks: [paragraph("original", "Original"), paragraph("target", "draft")],
  });
  tableRedo.canvas._editor.commands.setTextSelection(
    tableRedo.canvas._editor.state.doc.content.size - 1,
  );
  assert.equal(insertSlashTypeAtSelection(tableRedo.canvas._editor, "table"), true);
  tableRedo.canvas.flushPendingChanges();
  const tableInsertSave = tableRedo.requests[0];
  const insertedTable = inserted(tableInsertSave);
  tableRedo.echo([paragraph("original", "Original"), insertedTable], {
    rev: 11,
    request_id: tableInsertSave.payload.request_id,
  });
  tableInsertSave.resolve({
    saved: true,
    rev: 11,
    request_id: tableInsertSave.payload.request_id,
  });
  await tick();

  assert.equal(tableRedo.canvas._editor.commands.undo(), true,
    "the acknowledged slash-table insertion can be undone");
  tableRedo.canvas.flushPendingChanges();
  const tableUndoSave = tableRedo.requests[1];
  const restoredParagraph = inserted(tableUndoSave);
  tableRedo.echo([paragraph("original", "Original"), restoredParagraph], {
    rev: 12,
    request_id: tableUndoSave.payload.request_id,
  });
  tableUndoSave.resolve({
    saved: true,
    rev: 12,
    request_id: tableUndoSave.payload.request_id,
  });
  await tick();
  assert.equal(tableRedo.canvas._inflightOps, null,
    "the undo acknowledgement releases the canvas before redo");

  assert.equal(tableRedo.canvas._editor.commands.redo(), true,
    "the table insertion remains redoable after its undo acknowledgement");
  let bodyCellPosition = null;
  tableRedo.canvas._editor.state.doc.descendants((node, pos) => {
    if (bodyCellPosition == null && node.type.name === "bpTableCell") {
      bodyCellPosition = pos + 1;
    }
  });
  assert.ok(bodyCellPosition != null, "redo restores an editable body cell");
  tableRedo.canvas._editor.commands.setTextSelection(bodyCellPosition);
  tableRedo.canvas._editor.commands.insertContent("Studio mobile");
  assert.match(tableRedo.canvas._editor.state.doc.textContent, /Studio mobile/,
    "the immediate cell edit lands in the redone PM table before Studio reparenting");
  assert.equal(tableRedo.canvas.hasPendingChanges(), true,
    "redo plus immediate cell typing arms the canvas debounce");
  const movedStudioColumn = document.createElement("section");
  tableRedo.main.parentNode.appendChild(movedStudioColumn);
  movedStudioColumn.appendChild(tableRedo.main.querySelector("[phx-hook]"));
  assert.equal(tableRedo.canvas.hasPendingChanges(), true,
    "a connected-to-connected Studio column move preserves the redone table debounce");
  await new Promise(resolve => setTimeout(resolve, DEBOUNCE_MS * 4));
  assert.equal(tableRedo.requests.length, 3,
    "redo plus immediate cell typing survives Studio reparenting and debounces one save");
  const redoneTable = inserted(tableRedo.requests[2]);
  assert.equal(redoneTable.id, insertedTable.id,
    "redo preserves the acknowledged table identity");
  assert.equal(redoneTable.rows[0][0][0].value, "Studio mobile",
    "the immediate cell draft rides the redone table persistence batch");
  movedStudioColumn.remove();
  tableRedo.close();

  const responsiveProse = await mount({ revision: 13 });
  append(responsiveProse.canvas, " responsive draft");
  const responsiveEditor = responsiveProse.canvas._editor;
  assert.equal(responsiveProse.canvas.hasPendingChanges(), true,
    "ordinary prose arms the debounce before a responsive Studio move");
  const responsiveColumn = document.createElement("section");
  responsiveProse.main.parentNode.appendChild(responsiveColumn);
  responsiveColumn.appendChild(responsiveProse.main.querySelector("[phx-hook]"));
  assert.equal(responsiveProse.canvas._editor, responsiveEditor,
    "responsive reparenting preserves the mounted editor and its history");
  assert.equal(responsiveProse.canvas.hasPendingChanges(), true,
    "responsive reparenting preserves an ordinary prose debounce");
  await new Promise(resolve => setTimeout(resolve, DEBOUNCE_MS * 4));
  assert.equal(responsiveProse.requests.length, 1,
    "ordinary prose survives Studio reparenting and reaches persistence");
  assert.equal(
    responsiveProse.requests[0].payload.ops[0].patch.content[0].value,
    "Original responsive draft",
  );
  responsiveColumn.remove();
  responsiveProse.close();

  const removedCanvas = document.createElement("bp-paper-canvas");
  removedCanvas.blocks = [paragraph("removed", "Removed")];
  document.body.appendChild(removedCanvas);
  assert.ok(removedCanvas._editor, "a genuinely connected canvas mounts its editor");
  removedCanvas.remove();
  await tick();
  assert.equal(removedCanvas._editor, null,
    "a genuine removal still destroys the editor after the reparent grace microtask");

  const newerBoundaryDraft = await mount({ revision: 20 });
  newerBoundaryDraft.canvas._editor.commands.insertContentAt(
    newerBoundaryDraft.canvas._editor.state.doc.content.size,
    slashTypeToNode("table"),
  );
  newerBoundaryDraft.canvas.flushPendingChanges();
  const firstTableSave = newerBoundaryDraft.requests[0];
  const draftedTable = inserted(firstTableSave);
  const addRow = newerBoundaryDraft.canvas.querySelector('button[title="Add row"]');
  assert.ok(addRow, "the newly inserted table exposes its native structure control");
  addRow.click();
  newerBoundaryDraft.canvas.flushPendingChanges();
  newerBoundaryDraft.echo([paragraph("original", "Original"), draftedTable], {
    rev: 21,
    request_id: firstTableSave.payload.request_id,
  });
  firstTableSave.resolve({ saved: true, rev: 21, request_id: firstTableSave.payload.request_id });
  await tick();
  assert.equal(newerBoundaryDraft.requests.length, 2,
    "a newer table draft remains in its originating canvas long enough to save");
  const currentTableNode = () => newerBoundaryDraft.canvas._editor.getJSON().content.find(
    node => node.attrs?.bpId === draftedTable.id,
  );
  assert.equal(currentTableNode()?.content?.length, 3,
    "an older full-run acknowledgement cannot discard the newer table row");
  const secondTableSave = newerBoundaryDraft.requests[1];
  assert.deepEqual(secondTableSave.payload.ops.map(op => op.id), [draftedTable.id]);
  const latestTable = { ...draftedTable, ...secondTableSave.payload.ops[0].patch };
  newerBoundaryDraft.echo([paragraph("original", "Original"), latestTable], {
    rev: 22,
    request_id: secondTableSave.payload.request_id,
  });
  secondTableSave.resolve({ saved: true, rev: 22, request_id: secondTableSave.payload.request_id });
  await tick();
  assert.equal(currentTableNode()?.content?.length, 3,
    "the newest table acknowledgement preserves the edited pinned boundary");
  assert.equal(newerBoundaryDraft.canvas.hasPendingChanges(), false,
    "the newer boundary draft settles after its exact full-run acknowledgement");
  newerBoundaryDraft.close();

  const standalone = document.createElement("bp-paper-canvas");
  standalone.blocks = [paragraph("standalone", "Legacy host")];
  document.body.appendChild(standalone);
  await new Promise(resolve => setTimeout(resolve, 350));
  const standaloneBatches = [];
  standalone.addEventListener("bp-canvas-ops", event => standaloneBatches.push(event.detail.ops));
  append(standalone, " first");
  standalone.flushPendingChanges();
  append(standalone, " second");
  standalone.flushPendingChanges();
  assert.equal(standaloneBatches.length, 2,
    "standalone hosts that have not opted into acknowledgements continue emitting edits");
  standalone.remove();
  console.log("mounted canvas acknowledgement, stable-id, and source retry regressions passed");
} finally {
  window.close();
}
