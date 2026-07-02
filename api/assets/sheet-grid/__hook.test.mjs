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
// `parent` models the real topology: the hook binds keydown/input on
// `.sheet-editor` (an ANCESTOR of the .sheet-grid-wrap it mounts on) so the
// formula bar — a SIBLING of the grid, NOT a descendant — is covered. el's
// dispatch bubbles to the parent's listeners so grid-level keydown (dispatched
// on el) still reaches the handler on root; bar events are dispatched directly
// on root, which pins #813 (a handler bound on el would never see them).
function fakeEl(parent) {
  const listeners = {};
  const el = {
    listeners,
    _parent: parent || null,
    _active: null, // td.sheet-active
    _sel: [], // td.sheet-sel
    _scroll: null, // .sheet-scroll
    _input: null, // .sheet-cell-input
    _bar: null, // .sheet-bar-input
    dataset: {}, // data-* (data-fns feeds the autocomplete)
    focus() {},
    closest(sel) {
      return sel === ".sheet-editor" ? el._parent || el : null;
    },
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
      // simulate bubbling to the ancestor the keydown/input listeners live on
      if (el._parent) (el._parent.listeners[type] || []).slice().forEach((fn) => fn(e));
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

// A .sheet-cell-input node with just enough surface for the autocomplete
// helpers: value + caret, ARIA setters, and closest(".sheet-cell-input").
function fakeInput(value) {
  const inp = {
    value,
    selectionStart: value.length,
    attrs: {},
    matches: () => true,
    setAttribute(k, v) {
      this.attrs[k] = v;
    },
    removeAttribute(k) {
      delete this.attrs[k];
    },
    setSelectionRange(a) {
      this.selectionStart = a;
    },
    closest(sel) {
      return sel === ".sheet-cell-input" ? inp : null;
    },
  };
  return inp;
}

// A keydown event targeting a cell input (drives the in-cell dropdown).
function cellKey(key, inp, opts = {}) {
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
    target: inp,
  };
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

// A column/row header <th data-c> / <th data-r>. `guards` lets a test make
// closest() resolve one of the nested controls (menu button / resize handle /
// open menu) that live INSIDE the th, exercising the three guards that keep
// those clicks from being hijacked into a whole-row/col selection.
function headEvent({ c, r }, opts = {}, guards = {}) {
  const th = { dataset: c != null ? { c } : { r } };
  const target = {
    closest(sel) {
      if (sel === "th.sheet-colhead, th.sheet-rowhead") return th;
      if (sel === ".sheet-head-menu-btn") return guards.menuBtn || null;
      if (sel === ".sheet-rsz") return guards.rsz || null;
      if (sel === ".sheet-menu") return guards.menu || null;
      return null;
    },
  };
  return { shiftKey: false, ...opts, target, preventDefault() {} };
}

// mount a fresh hook instance with isolated listener/timer state.
function mountHook() {
  sandbox.window._listeners = {};
  timers.length = 0;
  const pushed = [];
  const hook = Object.create(sandbox.window.BarkparkSheetGrid);
  const root = fakeEl(null); // .sheet-editor — keydown/input bind here
  hook.el = fakeEl(root); // .sheet-grid-wrap — the phx-hook element
  // vm-realm objects have a foreign Object.prototype; the JSON round-trip
  // normalizes them so deepEqual against a plain object works.
  hook.pushEventTo = (_t, event, payload) =>
    pushed.push(JSON.parse(JSON.stringify({ event, payload })));
  hook._pushed = pushed;
  hook.mounted(); // sets hook.root = hook.el.closest(".sheet-editor") === root
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

// WCAG 2.1.2: without an escape hatch the grid is a keyboard trap — Tab always
// walks the selection and focus can never leave. Escape arms a one-shot so the
// next Tab falls through natively.
check("bare Tab is trapped: preventDefault + nav push (no Escape armed)", () => {
  const h = mountHook();
  const e = keydown("Tab");
  h.el.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, [{ event: "nav", payload: { key: "ArrowRight", shift: false } }]);
});

check("Escape then Tab escapes the grid: no preventDefault, no nav push", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("Escape"));
  const tab = keydown("Tab");
  h.el.dispatch("keydown", tab);
  assert.equal(tab.prevented, false); // native Tab moves focus out
  assert.deepEqual(h._pushed, []); // nothing pushed — no selection walk
});

check("Escape then Shift+Tab escapes backward (bare Shift keydown does not re-arm)", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("Escape"));
  h.el.dispatch("keydown", keydown("Shift", { shiftKey: true })); // must NOT clear
  const tab = keydown("Tab", { shiftKey: true });
  h.el.dispatch("keydown", tab);
  assert.equal(tab.prevented, false); // native Shift+Tab moves focus out backward
  assert.deepEqual(h._pushed, []);
});

check("Escape, ArrowDown, Tab re-arms the trap (any other key clears the one-shot)", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("Escape"));
  h.el.dispatch("keydown", keydown("ArrowDown")); // clears the one-shot
  const tab = keydown("Tab");
  h.el.dispatch("keydown", tab);
  assert.equal(tab.prevented, true); // trapped again
  assert.deepEqual(h._pushed, [
    { event: "nav", payload: { key: "ArrowDown", shift: false } },
    { event: "nav", payload: { key: "ArrowRight", shift: false } },
  ]);
});

check("Cmd+Z undoes, Cmd+Shift+Z redoes", () => {
  const h1 = mountHook();
  h1.el.dispatch("keydown", keydown("z", { metaKey: true }));
  assert.deepEqual(h1._pushed, [{ event: "undo", payload: {} }]);
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("z", { metaKey: true, shiftKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "redo", payload: {} }]);
});

// apply-UI slice: Cmd/Ctrl+B / Cmd/Ctrl+I push a style-toggle with the right key.
check("Cmd+B toggles bold, Cmd+I toggles italic", () => {
  const h1 = mountHook();
  h1.el.dispatch("keydown", keydown("b", { metaKey: true }));
  assert.deepEqual(h1._pushed, [{ event: "toggle-style", payload: { k: "b" } }]);
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("i", { ctrlKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "toggle-style", payload: { k: "i" } }]);
});

check("Cmd+Shift+B does NOT toggle style (Shift reserved)", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("b", { metaKey: true, shiftKey: true }));
  assert.deepEqual(h._pushed.filter((p) => p.event === "toggle-style"), []);
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

// structural slice 2: Cmd/Ctrl+Alt+= inserts, Cmd/Ctrl+Alt+- deletes;
// Shift targets columns. Matched on e.code (Shift turns "=" into "+").
check("Cmd+Alt+= inserts rows, Shift inserts cols", () => {
  const h1 = mountHook();
  h1.el.dispatch("keydown", keydown("=", { code: "Equal", ctrlKey: true, altKey: true }));
  assert.deepEqual(h1._pushed, [
    { event: "rowcol-key", payload: { kind: "row", action: "insert" } },
  ]);
  const h2 = mountHook();
  h2.el.dispatch(
    "keydown",
    keydown("+", { code: "Equal", metaKey: true, altKey: true, shiftKey: true })
  );
  assert.deepEqual(h2._pushed, [
    { event: "rowcol-key", payload: { kind: "col", action: "insert" } },
  ]);
});

check("Cmd+Alt+- deletes rows, Shift deletes cols", () => {
  const h1 = mountHook();
  h1.el.dispatch("keydown", keydown("-", { code: "Minus", ctrlKey: true, altKey: true }));
  assert.deepEqual(h1._pushed, [
    { event: "rowcol-key", payload: { kind: "row", action: "delete" } },
  ]);
  const h2 = mountHook();
  h2.el.dispatch(
    "keydown",
    keydown("-", { code: "Minus", metaKey: true, altKey: true, shiftKey: true })
  );
  assert.deepEqual(h2._pushed, [
    { event: "rowcol-key", payload: { kind: "col", action: "delete" } },
  ]);
});

check("Ctrl+= without Alt does not push a structural op", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("=", { code: "Equal", ctrlKey: true }));
  assert.deepEqual(h._pushed, []);
});

check("printable key starts an edit with the seed", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("a"));
  assert.deepEqual(h._pushed, [{ event: "edit-start", payload: { seed: "a" } }]);
});

check("Space on a checkbox-fmt active cell toggles it (no edit-start)", () => {
  const h = mountHook();
  h.el._active = {
    dataset: { ref: "A1" },
    classList: { contains: (c) => c === "sheet-checkbox" },
  };
  const e = keydown(" ");
  h.el.dispatch("keydown", e);
  assert.ok(e.prevented);
  assert.deepEqual(h._pushed, [{ event: "cell-toggle", payload: { ref: "A1" } }]);
});

check("Space on a NON-checkbox cell still seeds an edit with a space", () => {
  const h = mountHook();
  h.el._active = {
    dataset: { ref: "A1" },
    classList: { contains: () => false },
  };
  h.el.dispatch("keydown", keydown(" "));
  assert.deepEqual(h._pushed, [{ event: "edit-start", payload: { seed: " " } }]);
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

// ── header click → whole row/col selection ──────────────────────────────────

check("click on a column header pushes head-click {kind:col,index}", () => {
  const h = mountHook();
  h.el.dispatch("click", headEvent({ c: "3" }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "col", index: 3, shift: false } },
  ]);
});

check("click on a row header pushes head-click {kind:row,index}", () => {
  const h = mountHook();
  h.el.dispatch("click", headEvent({ r: "5" }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "row", index: 5, shift: false } },
  ]);
});

check("shift rides the head-click payload", () => {
  const h = mountHook();
  h.el.dispatch("click", headEvent({ c: "2" }, { shiftKey: true }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "col", index: 2, shift: true } },
  ]);
});

check("click on the menu button nested in a th does NOT push head-click", () => {
  const h = mountHook();
  h.el.dispatch("click", headEvent({ c: "3" }, {}, { menuBtn: {} }));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "head-click"),
    [],
  );
});

check("click on the resize handle nested in a th does NOT push head-click", () => {
  const h = mountHook();
  h.el.dispatch("click", headEvent({ c: "3" }, {}, { rsz: {} }));
  assert.equal(h._pushed.length, 0);
});

check("click inside an open header menu does NOT push head-click", () => {
  const h = mountHook();
  h.el.dispatch("click", headEvent({ r: "4" }, {}, { menu: {} }));
  assert.equal(h._pushed.length, 0);
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

// loop-fix9: the two remaining silent draft-loss paths. (a) A HEADER click
// while a cell editor is open must ride the draft as `commit` — the pre-fix
// head-click pushed no commit and the server assigned editing:nil, dropping the
// draft. (b) A dirty, focused FORMULA BAR must ride `bar_commit` on any
// click-away — the pre-fix mousedown looked only at .sheet-cell-input, so the
// next patch reverted the bar to Cells.bar_value and the draft vanished.
check("header click while a cell editor is open rides the draft as commit", () => {
  const h = mountHook();
  const inp = { value: "half-typed" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  h.el._input = inp;
  h.el.dispatch("click", headEvent({ c: "3" }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "col", index: 3, shift: false, commit: "half-typed" } },
  ]);
});

check("a dirty, focused formula bar rides bar_commit on a cell mousedown", () => {
  const h = mountHook();
  const bar = { value: "=SUM(A1:A9)", dataset: { raw: "=SUM(A1:A2)" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  h.root._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("mousedown", cellEvent("D4"));
  sandbox.document.activeElement = null;
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "D4", shift: false, bar_commit: "=SUM(A1:A9)" } }],
  );
});

check("a dirty, focused formula bar rides bar_commit on a header click too", () => {
  const h = mountHook();
  const bar = { value: "42", dataset: { raw: "" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  h.root._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("click", headEvent({ r: "6" }));
  sandbox.document.activeElement = null;
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "row", index: 6, shift: false, bar_commit: "42" } },
  ]);
});

check("a pristine formula bar (value == data-raw) rides NO bar_commit", () => {
  const h = mountHook();
  const bar = { value: "=SUM(A1:A2)", dataset: { raw: "=SUM(A1:A2)" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  h.root._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("mousedown", cellEvent("E5"));
  sandbox.document.activeElement = null;
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "E5", shift: false } }],
  );
});

// A bar that is NOT the focused element (activeElement) rides nothing even if
// its text differs — the mirror keeps the bar in sync with the cell editor, so
// a non-focused dirty bar is a mirror artifact, not a user draft.
check("an unfocused dirty bar rides NO bar_commit", () => {
  const h = mountHook();
  const bar = { value: "mirror-shadow", dataset: { raw: "" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  h.root._bar = bar;
  h.el.dispatch("mousedown", cellEvent("F6"));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "F6", shift: false } }],
  );
});

// #813 root-rewire: bar events are delivered to the ROOT wrapper (.sheet-editor),
// the ancestor the keydown handler now binds on — NOT to h.el (the grid). A
// handler bound on h.el (the dead pre-fix wiring) would never see these.
check("formula bar Escape restores data-raw and pushes nothing", () => {
  const h = mountHook();
  const bar = { value: "=SUM(A1:A9", dataset: { raw: "=SUM(A1:A2)" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  const e = keydown("Escape");
  e.target = bar;
  h.root.dispatch("keydown", e);
  assert.equal(bar.value, "=SUM(A1:A2)");
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, []);
});

check("formula bar Tab commits the draft + moves right", () => {
  const h = mountHook();
  const bar = { value: "=SUM(A1:A9)", dataset: { raw: "=SUM(A1:A2)" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  const e = keydown("Tab");
  e.target = bar;
  h.root.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, [
    { event: "bar-commit", payload: { value: "=SUM(A1:A9)", move: "right" } },
  ]);
});

check("formula bar Shift+Tab commits the draft + moves left", () => {
  const h = mountHook();
  const bar = { value: "9", dataset: { raw: "" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  const e = keydown("Tab", { shiftKey: true });
  e.target = bar;
  h.root.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, [
    { event: "bar-commit", payload: { value: "9", move: "left" } },
  ]);
});

// The regression pin: the keydown handler is bound on root, NOT on the grid
// element. Before the rewire the bar sat outside h.el, so the handler on h.el
// never fired for bar keys — the #813 fix was dead in a real browser.
check("#813 pin: bar keydown handled on root; the grid el carries NO keydown listener", () => {
  const h = mountHook();
  assert.equal((h.el.listeners.keydown || []).length, 0);
  const bar = { value: "42", dataset: { raw: "" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  const e = keydown("Tab");
  e.target = bar;
  h.root.dispatch("keydown", e);
  assert.deepEqual(h._pushed, [
    { event: "bar-commit", payload: { value: "42", move: "right" } },
  ]);
});

// The cell→bar mirror looks the bar up on ROOT (it's outside h.el). Dispatch on
// h.el bubbles to the input handler on root.
check("typing in the cell editor mirrors into the formula bar", () => {
  const h = mountHook();
  const inp = { value: "12" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  const bar = { value: "old" };
  h.root._bar = bar;
  h.el.dispatch("input", { target: inp });
  assert.equal(bar.value, "12");
});

check("the mirror leaves a FOCUSED bar alone", () => {
  const h = mountHook();
  const inp = { value: "12" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  const bar = { value: "user-owns-this" };
  h.root._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("input", { target: inp });
  assert.equal(bar.value, "user-owns-this");
  sandbox.document.activeElement = null;
});

// ── function autocomplete (the in-cell dropdown) ────────────────────────────

// vm-realm returns carry a foreign Object/Array prototype; JSON round-trip
// normalizes them so strict deepEqual compares by value (same trick as
// _presencePayload above).
const plain = (v) => JSON.parse(JSON.stringify(v));

check("_fnToken: '=SU'→SU, '=A1+SU'→SU, 'SU'→null, '=SUM(A1'→null (ref exclusion)", () => {
  const h = mountHook();
  assert.deepEqual(plain(h._fnToken("=SU", 3)), { token: "SU", start: 1 });
  assert.equal(h._fnToken("=A1+SU", 6).token, "SU");
  assert.equal(h._fnToken("SU", 2), null); // no leading "=" → not a formula
  assert.equal(h._fnToken("=SUM(A1", 7), null); // A1 is a cell ref, not a fn
});

check("_fnMatches: case-insensitive prefix, capped at 8, empty → []", () => {
  const h = mountHook();
  h._fns = ["SUM", "SUMIF", "SUMIFS", "SUMX1", "SUMX2", "SUMX3", "SUMX4", "SUMX5", "SUMX6", "IF"];
  assert.deepEqual(plain(h._fnMatches("su")).slice(0, 3), ["SUM", "SUMIF", "SUMIFS"]);
  assert.equal(h._fnMatches("SU").length, 8); // 9 candidates → capped
  assert.deepEqual(plain(h._fnMatches("")), []);
  assert.deepEqual(plain(h._fnMatches("if")), ["IF"]);
});

check("dropdown: open → ArrowDown → Tab inserts 'SUM(' and pushes NO edit-commit", () => {
  const h = mountHook();
  h._fns = ["SUM", "SUMIF", "SUMIFS", "IF"];
  const inp = fakeInput("=SU");
  h.el.dispatch("input", { target: inp }); // menu opens (idx -1)
  h.el.dispatch("keydown", cellKey("ArrowDown", inp)); // idx → 0 (SUM), navigated
  h.el.dispatch("keydown", cellKey("Tab", inp)); // Tab always accepts
  assert.equal(inp.value, "=SUM(");
  assert.deepEqual(h._pushed.filter((p) => p.event === "edit-commit"), []);
});

check("dropdown: Enter with no arrow falls through and commits the raw draft", () => {
  const h = mountHook();
  h._fns = ["SUM", "SUMIF", "IF"];
  const inp = fakeInput("=SU");
  h.el.dispatch("input", { target: inp });
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.deepEqual(h._pushed.filter((p) => p.event === "edit-commit"), [
    { event: "edit-commit", payload: { value: "=SU", move: "down" } },
  ]);
  assert.equal(inp.value, "=SU"); // untouched — the menu did not accept
});

check("dropdown: Enter AFTER an arrow accepts the highlighted item (no commit)", () => {
  const h = mountHook();
  h._fns = ["SUM", "SUMIF", "IF"];
  const inp = fakeInput("=SU");
  h.el.dispatch("input", { target: inp });
  h.el.dispatch("keydown", cellKey("ArrowDown", inp)); // idx 0, navigated
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.equal(inp.value, "=SUM(");
  assert.deepEqual(h._pushed.filter((p) => p.event === "edit-commit"), []);
});

check("dropdown: Escape is two-stage — first closes the menu (no push), then cancels", () => {
  const h = mountHook();
  h._fns = ["SUM", "SUMIF", "IF"];
  const inp = fakeInput("=SU");
  h.el.dispatch("input", { target: inp });
  h.el.dispatch("keydown", cellKey("Escape", inp)); // stage 1: close menu only
  assert.deepEqual(h._pushed, []);
  h.el.dispatch("keydown", cellKey("Escape", inp)); // stage 2: cancel the edit
  assert.deepEqual(h._pushed, [{ event: "edit-cancel", payload: {} }]);
});

// ── row paging: the page-flip scroll reset ──────────────────────────────────

// A row-page flip re-renders the tbody to a new window; updated() must snap the
// vertical scroll to that window's top (data-row-offset changed) rather than let
// beforeUpdate restore the stale offset. A normal patch (offset unchanged) still
// preserves the scroll, and the horizontal scroll is kept across a flip.
check("updated() resets scrollTop on a row-page flip, preserves it otherwise", () => {
  const h = mountHook();
  h.el.dataset.rowOffset = "0";
  h._rowOffset = "0";
  h.el._scroll = { scrollTop: 400, scrollLeft: 30 };
  h.scrollEl = h.el._scroll;

  // Offset unchanged → the pre-patch scroll is restored verbatim.
  h.beforeUpdate();
  h.updated();
  assert.equal(h.el._scroll.scrollTop, 400);
  assert.equal(h.el._scroll.scrollLeft, 30);

  // Offset 0 → 1: the vertical scroll snaps to the top, horizontal is kept.
  h.beforeUpdate();
  h.el.dataset.rowOffset = "1";
  h.updated();
  assert.equal(h.el._scroll.scrollTop, 0);
  assert.equal(h.el._scroll.scrollLeft, 30);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall bp-sheet-grid hook checks PASS");
