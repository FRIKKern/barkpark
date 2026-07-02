// __hook.test.mjs — pure-Node unit harness for the Studio sheet-grid client
// hook (api/priv/static/assets/bp-sheet-grid.js).
//
// The hook is a browser IIFE that assigns `window.BarkparkSheetGrid`. It is
// DOM-coupled (no exported pure helpers to import like paper-editor's
// wikilink-trigger), so we run the committed file verbatim inside a node:vm
// sandbox that fakes just enough of `window` / `document` / `setTimeout`, then
// exercise the hook object against fake DOM elements. Zero dependencies, no
// lockfile — this file loads the SHIPPED artifact, so a regression in the
// committed bundle reds the gate.
//
// Run: node __hook.test.mjs   (or: npm test)
//
// CARVE-OUT: real focus/scroll geometry, clipboard, and morphdom re-render are
// browser-only and covered in the live Studio. This harness pins the pure
// event-routing + selection-string logic.

import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";

// ── vm sandbox: the minimal browser surface the IIFE touches ────────────────

const timers = [];
const sandbox = {
  window: {
    _listeners: {},
    addEventListener(type, fn) {
      (this._listeners[type] ||= []).push(fn);
    },
    removeEventListener(type, fn) {
      const a = this._listeners[type];
      if (!a) return;
      const i = a.indexOf(fn);
      if (i >= 0) a.splice(i, 1);
    },
  },
  document: { activeElement: null },
  // Controllable timers make the 100ms presence throttle deterministic:
  // scheduling pushes the callback, the test flushes it by hand.
  setTimeout(fn) {
    timers.push(fn);
    return timers.length;
  },
  clearTimeout() {},
};
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(new URL("../../priv/static/assets/bp-sheet-grid.js", import.meta.url), "utf8"),
  sandbox,
);

function dispatchWindow(type, e) {
  (sandbox.window._listeners[type] || []).slice().forEach((fn) => fn(e));
}

// ── fake DOM ────────────────────────────────────────────────────────────────

// listeners are a Map of ARRAYS (not last-write-wins): the drag slice registers
// a SECOND "mousedown" listener next to the resize handler, and dispatch must
// call both.
function fakeEl() {
  const listeners = {};
  const el = {
    listeners,
    _active: null, // td.sheet-active
    _sel: [], // td.sheet-sel
    _scroll: null, // .sheet-scroll
    _input: null, // .sheet-cell-input
    focus() {},
    addEventListener(type, fn) {
      (listeners[type] ||= []).push(fn);
    },
    removeEventListener(type, fn) {
      const a = listeners[type];
      if (!a) return;
      const i = a.indexOf(fn);
      if (i >= 0) a.splice(i, 1);
    },
    dispatch(type, e) {
      (listeners[type] || []).slice().forEach((fn) => fn(e));
    },
    querySelector(sel) {
      if (sel === "td.sheet-active") return el._active;
      if (sel === ".sheet-scroll") return el._scroll;
      if (sel === ".sheet-cell-input") return el._input;
      if (sel === ".sheet-bar-input") return el._bar;
      return null;
    },
    querySelectorAll(sel) {
      if (sel === "td.sheet-sel") return el._sel;
      return [];
    },
  };
  return el;
}

// A grid cell <td data-ref data-r data-c data-v>.
function td({ ref, r, c, v }) {
  const cell = { dataset: { ref, r, c, v }, textContent: "", matches: () => false };
  cell.closest = (sel) => (sel === "td[data-ref]" ? cell : null);
  return cell;
}

// A keydown event whose target is NOT a cell input (grid-level typing).
function keydown(key, opts = {}) {
  return {
    key,
    shiftKey: false,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    ...opts,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
    target: { closest: () => null, matches: () => false },
  };
}

// A mousedown/click event whose target resolves to a cell td.
function cellEvent(ref, opts = {}) {
  const t = td({ ref });
  return {
    button: 0,
    shiftKey: false,
    ...opts,
    target: t,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
}

// mount a fresh hook instance with isolated listener/timer state.
function mountHook() {
  sandbox.window._listeners = {};
  timers.length = 0;
  const pushed = [];
  const hook = Object.create(sandbox.window.BarkparkSheetGrid);
  hook.el = fakeEl();
  // vm-realm objects have a foreign Object.prototype; the JSON round-trip
  // normalizes them so deepEqual against a plain object works.
  hook.pushEventTo = (_t, event, payload) =>
    pushed.push(JSON.parse(JSON.stringify({ event, payload })));
  hook._pushed = pushed;
  hook.mounted();
  return hook;
}

// ── runner ───────────────────────────────────────────────────────────────────

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// ── keyboard routing ──────────────────────────────────────────────────────────

check("NAV_KEYS push a nav event + preventDefault", () => {
  const h = mountHook();
  const e = keydown("ArrowDown");
  h.el.dispatch("keydown", e);
  assert.deepEqual(h._pushed, [{ event: "nav", payload: { key: "ArrowDown", shift: false } }]);
  assert.equal(e.prevented, true);
});

check("Shift flag rides the nav payload", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("ArrowRight", { shiftKey: true }));
  assert.deepEqual(h._pushed, [{ event: "nav", payload: { key: "ArrowRight", shift: true } }]);
});

check("Tab remaps to ArrowRight, Shift+Tab to ArrowLeft (shift:false)", () => {
  const h1 = mountHook();
  h1.el.dispatch("keydown", keydown("Tab"));
  assert.deepEqual(h1._pushed, [{ event: "nav", payload: { key: "ArrowRight", shift: false } }]);
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("Tab", { shiftKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "nav", payload: { key: "ArrowLeft", shift: false } }]);
});

check("Cmd+Z undoes, Cmd+Shift+Z redoes", () => {
  const h1 = mountHook();
  h1.el.dispatch("keydown", keydown("z", { metaKey: true }));
  assert.deepEqual(h1._pushed, [{ event: "undo", payload: {} }]);
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("z", { metaKey: true, shiftKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "redo", payload: {} }]);
});

// wave-2 merged: Cmd/Ctrl+D fill-down, Cmd/Ctrl+R fill-right.
check("Cmd+D fills down, Cmd+R fills right", () => {
  const h1 = mountHook();
  h1.el.dispatch("keydown", keydown("d", { metaKey: true }));
  assert.deepEqual(h1._pushed, [{ event: "fill", payload: { dir: "down" } }]);
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("r", { ctrlKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "fill", payload: { dir: "right" } }]);
});

check("printable key starts an edit with the seed", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("a"));
  assert.deepEqual(h._pushed, [{ event: "edit-start", payload: { seed: "a" } }]);
});

check("in-cell Enter commits with value + move:down", () => {
  const h = mountHook();
  const inp = { value: "hi", matches: () => true };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  const e = {
    key: "Enter",
    shiftKey: false,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
    target: inp,
  };
  h.el.dispatch("keydown", e);
  assert.deepEqual(h._pushed, [{ event: "edit-commit", payload: { value: "hi", move: "down" } }]);
  assert.equal(e.prevented, true);
});

// ── selection string helpers ───────────────────────────────────────────────

check("_selectionTsv is 2x2 row-major from data-v", () => {
  const h = mountHook();
  h.el._sel = [
    td({ r: "1", c: "1", v: "a" }),
    td({ r: "1", c: "2", v: "b" }),
    td({ r: "2", c: "1", v: "c" }),
    td({ r: "2", c: "2", v: "d" }),
  ];
  assert.equal(h._selectionTsv(), "a\tb\nc\td");
});

check("_selectionTsv is null when nothing is selected", () => {
  const h = mountHook();
  h.el._sel = [];
  assert.equal(h._selectionTsv(), null);
});

check("_colLetters covers A/Z/AA/ZZ/AAA boundaries", () => {
  const h = mountHook();
  assert.equal(h._colLetters(1), "A");
  assert.equal(h._colLetters(26), "Z");
  assert.equal(h._colLetters(27), "AA");
  assert.equal(h._colLetters(702), "ZZ");
  assert.equal(h._colLetters(703), "AAA");
});

check("_presencePayload derives the A1:B2 rect + active ref", () => {
  const h = mountHook();
  h.el._active = { dataset: { ref: "B2" } };
  h.el._sel = [
    { dataset: { r: "1", c: "1" } },
    { dataset: { r: "1", c: "2" } },
    { dataset: { r: "2", c: "1" } },
    { dataset: { r: "2", c: "2" } },
  ];
  // _presencePayload builds its object in the vm realm (foreign prototype);
  // round-trip through JSON so strict deepEqual compares by value.
  assert.deepEqual(JSON.parse(JSON.stringify(h._presencePayload())), {
    active: "B2",
    selection: "A1:B2",
  });
});

check("presence throttle defers the frame to a timer, then pushes it", () => {
  const h = mountHook();
  // mounted() scheduled the presence ping but pushed nothing yet.
  assert.equal(h._pushed.length, 0);
  assert.equal(timers.length, 1);
  timers[0]();
  assert.deepEqual(h._pushed, [
    { event: "presence-meta", payload: { active: null, selection: null } },
  ]);
});

// ── mouse drag-to-select (the new consumer) ─────────────────────────────────

check("mousedown on a cell anchors with shift:false", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("A1"));
  assert.deepEqual(h._pushed, [{ event: "cell-click", payload: { ref: "A1", shift: false } }]);
});

check("mouseover a new cell extends the rect with shift:true", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("A1"));
  const over = { target: td({ ref: "B3" }) };
  h.el.dispatch("mouseover", over);
  assert.deepEqual(h._pushed, [
    { event: "cell-click", payload: { ref: "A1", shift: false } },
    { event: "cell-click", payload: { ref: "B3", shift: true } },
  ]);
});

check("mouseover the SAME cell is deduped (no push)", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("A1"));
  h.el.dispatch("mouseover", { target: td({ ref: "B3" }) });
  h.el.dispatch("mouseover", { target: td({ ref: "B3" }) });
  assert.equal(h._pushed.length, 2);
});

check("mouseover off any cell (closest → null) pushes nothing", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("A1"));
  h.el.dispatch("mouseover", { target: { closest: () => null } });
  assert.equal(h._pushed.length, 1);
});

check("the click right after a drag is swallowed; the next click passes", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("A1"));
  dispatchWindow("mouseup", {});
  h.el.dispatch("click", cellEvent("A1")); // synthetic post-drag click → swallowed
  assert.equal(h._pushed.length, 1);
  h.el.dispatch("click", cellEvent("C4")); // a real, standalone click → anchors
  assert.deepEqual(h._pushed[1], { event: "cell-click", payload: { ref: "C4", shift: false } });
});

check("mousedown on a resize handle does NOT anchor a cell", () => {
  const h = mountHook();
  const handle = { dataset: { kind: "col", px: "88", index: "1" } };
  const target = { matches: () => false };
  target.closest = (sel) => (sel === ".sheet-rsz" ? handle : null);
  h.el.dispatch("mousedown", {
    button: 0,
    shiftKey: false,
    target,
    pageX: 0,
    pageY: 0,
    preventDefault() {},
    stopPropagation() {},
  });
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [],
  );
});

// ── click-away commit + formula bar ─────────────────────────────────────────

check("click-away mousedown carries the open editor's draft as commit", () => {
  const h = mountHook();
  const inp = { value: "half-typed" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  h.el._input = inp;
  h.el.dispatch("mousedown", cellEvent("B2"));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "B2", shift: false, commit: "half-typed" } }],
  );
});

check("mousedown with no open editor pushes a plain cell-click (no commit key)", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("C3"));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "C3", shift: false } }],
  );
});

check("formula bar Escape restores data-raw and pushes nothing", () => {
  const h = mountHook();
  const bar = { value: "=SUM(A1:A9", dataset: { raw: "=SUM(A1:A2)" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  const e = keydown("Escape");
  e.target = bar;
  h.el.dispatch("keydown", e);
  assert.equal(bar.value, "=SUM(A1:A2)");
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, []);
});

check("typing in the cell editor mirrors into the formula bar", () => {
  const h = mountHook();
  const inp = { value: "12" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  const bar = { value: "old" };
  h.el._bar = bar;
  h.el.dispatch("input", { target: inp });
  assert.equal(bar.value, "12");
});

check("the mirror leaves a FOCUSED bar alone", () => {
  const h = mountHook();
  const inp = { value: "12" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  const bar = { value: "user-owns-this" };
  h.el._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("input", { target: inp });
  assert.equal(bar.value, "user-owns-this");
  sandbox.document.activeElement = null;
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall bp-sheet-grid hook checks PASS");
