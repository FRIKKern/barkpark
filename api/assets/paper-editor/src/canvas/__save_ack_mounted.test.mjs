// Mounted regression for node-view controls whose values are held behind their
// own debounce. The canvas flush must commit those controls before diffing the run.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import vm from "node:vm";

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

const { BpPaperCanvas, DEBOUNCE_MS } = await import("./index.js");
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

async function mount() {
  const main = document.createElement("main");
  main.innerHTML = `<button data-editing="true">View</button>
    <a href="/studio/papers/b" data-phx-link="patch">Paper B</a>
    <button type="button" phx-click="paper-delete-block">Delete</button>
    <button type="button" phx-click="paper-move-block">Move</button>
    <button type="button" phx-click="paper-materialize-slot">Materialize</button>
    <button type="button" phx-click="paper-unbind-property">Unbind</button>
    <button type="button" phx-click="inner-array-op">Array</button>
    <form phx-submit="paper-add-block"><select name="block-type"><option>paragraph</option></select></form>
    <div id="paper-canvas-probe-run-0" phx-hook="BarkparkPaperCanvas"><bp-paper-canvas></bp-paper-canvas></div>`;
  const wrapper = main.querySelector("[phx-hook]");
  wrapper.dataset.canvasBlocks = JSON.stringify([paragraph("original", "Original")]);
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
    echo: blocks => handlers.get("bp:canvas-update")({runs:[{run_id:"probe-run-0", blocks}]}),
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
