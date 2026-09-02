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
// The two pure kernels load FIRST (they assign window.BarkparkSheetFormula /
// window.BarkparkSheetPointing), exactly as root.html.heex orders the <script>
// tags — so the hook's point-mode/intellisense wiring runs against the SHIPPED
// kernels, not a stub. A regression in either shipped file reds this gate too.
vm.runInContext(
  fs.readFileSync(new URL("../../priv/static/assets/bp-sheet-formula.js", import.meta.url), "utf8"),
  sandbox,
);
vm.runInContext(
  fs.readFileSync(new URL("../../priv/static/assets/bp-sheet-pointing.js", import.meta.url), "utf8"),
  sandbox,
);
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
    // Models Node.contains for the #843 grid-scope guard: a real grid keydown
    // targets the focused .sheet-grid-wrap (el) or a cell inside it; toolbar /
    // tab-strip targets are NOT contained. Grid-level fake events carry
    // `_inGrid`; the active cell / open input nodes count as inside too.
    contains(node) {
      return !!(
        node === el ||
        node === el._active ||
        node === el._input ||
        (node && node._inGrid)
      );
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

// A keydown event whose target is NOT a cell input (grid-level typing). The
// target carries `_inGrid` so el.contains() treats it as inside the grid — a
// real grid keydown fires on the focused .sheet-grid-wrap (the #843 scope
// guard lets it through; a toolbar target would be rejected).
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
    target: { closest: () => null, matches: () => false, _inGrid: true },
  };
}

// A keydown whose target is a TOOLBAR control (button / tab-strip): inside
// .sheet-editor (root) but OUTSIDE the grid el, and not a text input. The #843
// scope guard must drop these so Enter/Space/Tab keep native button behaviour
// instead of driving the grid key map.
function toolbarKey(key, opts = {}) {
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
    target: {
      matches: () => false,
      closest: (sel) => (sel === ".sheet-toolbar" ? {} : null),
    },
  };
}

// A mousedown whose target is a TOOLBAR button (drives the draft-commit seal).
// `input` makes it a text input (formula bar / name box) that must be excluded.
function toolbarMousedown({ input = false } = {}) {
  const tb = {};
  return {
    target: {
      matches: (sel) => input && /input|textarea|select/.test(sel),
      closest: (sel) => (sel === ".sheet-toolbar" ? tb : null),
    },
    preventDefault() {},
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
//
// THE DEFAULT MOUNT IS THE EDITABLE GRID (wave 43). The editable wrapper stamps
// `data-fns` (the function vocabulary) and the read-mode wrapper omits it, which
// is what the hook self-derives `_readOnly` from — so a mount with an empty
// dataset is the READ-MODE DOM shape, and every write gesture it is handed is
// dropped by the read-mode allowlist. Before wave 43 that distinction was
// invisible (the flag only gated formula chrome) and every check here mounted a
// read-mode element while asserting write pushes. Pass `{ readOnly: true }` for
// the read-mode grid; the five point-mode fail-closed cases below do exactly
// that, and the wave-43 read-mode block builds on it.
function mountHook({ readOnly = false } = {}) {
  sandbox.window._listeners = {};
  timers.length = 0;
  const pushed = [];
  const hook = Object.create(sandbox.window.BarkparkSheetGrid);
  const root = fakeEl(null); // .sheet-editor — keydown/input bind here
  hook.el = fakeEl(root); // .sheet-grid-wrap — the phx-hook element
  if (!readOnly) hook.el.dataset.fns = "SUM AVERAGE COUNT";
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

// ── Excel keyboard-nav batch: select-all / data-edge / corners / row-col ────
//
// Pre-fix the hook had NONE of these branches: Ctrl/Cmd+A fell through to the
// browser (selected the page text), Ctrl/Cmd+Arrow hit the plain NAV_KEYS map
// (single-step), Ctrl+Home/End likewise, and a modifier'd Space fell into the
// bare-Space branch (opened an editor seeded with a literal space).

check("Cmd/Ctrl+A pushes select-all {} + preventDefault (never native page select)", () => {
  const h1 = mountHook();
  const e1 = keydown("a", { metaKey: true });
  h1.el.dispatch("keydown", e1);
  assert.equal(e1.prevented, true);
  assert.deepEqual(h1._pushed, [{ event: "select-all", payload: {} }]);
  // Ctrl+A (non-mac) and uppercase A (caps layout) are the same binding.
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("A", { ctrlKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "select-all", payload: {} }]);
});

check("Cmd+Shift+A pushes nothing (Shift reserved)", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("a", { metaKey: true, shiftKey: true }));
  assert.deepEqual(h._pushed, []);
});

check("Ctrl/Cmd+Arrow pushes nav-edge {dir}; Shift extends", () => {
  const h1 = mountHook();
  const e1 = keydown("ArrowDown", { ctrlKey: true });
  h1.el.dispatch("keydown", e1);
  assert.equal(e1.prevented, true);
  assert.deepEqual(h1._pushed, [{ event: "nav-edge", payload: { dir: "down", shift: false } }]);
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("ArrowRight", { metaKey: true, shiftKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "nav-edge", payload: { dir: "right", shift: true } }]);
  const h3 = mountHook();
  h3.el.dispatch("keydown", keydown("ArrowUp", { metaKey: true }));
  h3.el.dispatch("keydown", keydown("ArrowLeft", { ctrlKey: true }));
  assert.deepEqual(h3._pushed, [
    { event: "nav-edge", payload: { dir: "up", shift: false } },
    { event: "nav-edge", payload: { dir: "left", shift: false } },
  ]);
});

check("plain arrows still single-step nav (nav-edge regression pin)", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("ArrowLeft"));
  assert.deepEqual(h._pushed, [{ event: "nav", payload: { key: "ArrowLeft", shift: false } }]);
});

check("Ctrl/Cmd+Home/End push nav-corner {corner}; Shift extends", () => {
  const h1 = mountHook();
  const e1 = keydown("Home", { ctrlKey: true });
  h1.el.dispatch("keydown", e1);
  assert.equal(e1.prevented, true);
  assert.deepEqual(h1._pushed, [{ event: "nav-corner", payload: { corner: "home", shift: false } }]);
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("End", { metaKey: true, shiftKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "nav-corner", payload: { corner: "end", shift: true } }]);
});

check("plain Home/End still push a plain nav (nav-corner regression pin)", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("Home"));
  h.el.dispatch("keydown", keydown("End"));
  assert.deepEqual(h._pushed, [
    { event: "nav", payload: { key: "Home", shift: false } },
    { event: "nav", payload: { key: "End", shift: false } },
  ]);
});

check("Shift+Space selects the active ROW via the existing head-click path", () => {
  const h = mountHook();
  h.el._active = { dataset: { ref: "B3", r: "3", c: "2" }, classList: { contains: () => false } };
  const e = keydown(" ", { shiftKey: true });
  h.el.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "row", index: 3, shift: false } },
  ]);
  // The guard: a modifier'd Space must NEVER seed a space edit.
  assert.deepEqual(h._pushed.filter((p) => p.event === "edit-start"), []);
});

check("Ctrl/Cmd+Space selects the active COLUMN via head-click", () => {
  const h1 = mountHook();
  h1.el._active = { dataset: { ref: "B3", r: "3", c: "2" }, classList: { contains: () => false } };
  h1.el.dispatch("keydown", keydown(" ", { ctrlKey: true }));
  assert.deepEqual(h1._pushed, [
    { event: "head-click", payload: { kind: "col", index: 2, shift: false } },
  ]);
  const h2 = mountHook();
  h2.el._active = { dataset: { ref: "D5", r: "5", c: "4" }, classList: { contains: () => false } };
  h2.el.dispatch("keydown", keydown(" ", { metaKey: true }));
  assert.deepEqual(h2._pushed, [
    { event: "head-click", payload: { kind: "col", index: 4, shift: false } },
  ]);
});

check("Shift+Space on a checkbox-fmt cell still row-selects (modifier wins over toggle)", () => {
  const h = mountHook();
  h.el._active = {
    dataset: { ref: "A1", r: "1", c: "1" },
    classList: { contains: (c) => c === "sheet-checkbox" },
  };
  h.el.dispatch("keydown", keydown(" ", { shiftKey: true }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "row", index: 1, shift: false } },
  ]);
});

check("modifier'd Space with no active cell pushes nothing", () => {
  const h = mountHook();
  const e = keydown(" ", { shiftKey: true });
  h.el.dispatch("keydown", e);
  assert.equal(e.prevented, true); // still never a native page scroll
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

// ── click-drag across headers → multi-col/row selection (w16-4) ─────────────
//
// The header twin of the cell drag: mousedown on a th anchors via the existing
// head-click op (shift:false), each newly-entered header of the SAME kind
// extends with shift:true, window mouseup tears down, and the trailing
// synthetic click is swallowed. Pre-fix the hook had NO header mousedown
// handler, so the anchor/extend pushes never happened.

check("col-head drag: anchor shift:false, extend shift:true, mouseup tears down, trailing click swallowed", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", headEvent({ c: "1" }, { button: 0 }));
  h.el.dispatch("mouseover", headEvent({ c: "3" }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "col", index: 1, shift: false } },
    { event: "head-click", payload: { kind: "col", index: 3, shift: true } },
  ]);
  // Re-entering the SAME header is deduped.
  h.el.dispatch("mouseover", headEvent({ c: "3" }));
  assert.equal(h._pushed.length, 2);
  dispatchWindow("mouseup", {});
  h.el.dispatch("mouseover", headEvent({ c: "5" })); // after teardown: nothing
  h.el.dispatch("click", headEvent({ c: "5" })); // trailing synthetic click → swallowed
  assert.equal(h._pushed.length, 2);
});

check("row-head drag anchors + extends {kind:row}", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", headEvent({ r: "2" }, { button: 0 }));
  h.el.dispatch("mouseover", headEvent({ r: "4" }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "row", index: 2, shift: false } },
    { event: "head-click", payload: { kind: "row", index: 4, shift: true } },
  ]);
});

check("mousedown on a .sheet-rsz child of a th pushes nothing (resize keeps its gesture)", () => {
  const h = mountHook();
  const e = headEvent(
    { c: "2" },
    { button: 0, pageX: 0, pageY: 0 },
    { rsz: { dataset: { kind: "col", px: "88", index: "2" } } },
  );
  e.stopPropagation = () => {};
  h.el.dispatch("mousedown", e);
  assert.deepEqual(h._pushed, []);
});

check("mousedown on the head menu button / open menu pushes nothing", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", headEvent({ c: "2" }, { button: 0 }, { menuBtn: {} }));
  h.el.dispatch("mousedown", headEvent({ r: "3" }, { button: 0 }, { menu: {} }));
  assert.deepEqual(h._pushed, []);
});

check("row-head mouseover during a col drag is ignored (same-kind guard)", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", headEvent({ c: "1" }, { button: 0 }));
  h.el.dispatch("mouseover", headEvent({ r: "5" })); // corner-crossing: must not flip to rows
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "col", index: 1, shift: false } },
  ]);
  // …and a same-kind header AFTER the foreign one still extends.
  h.el.dispatch("mouseover", headEvent({ c: "2" }));
  assert.deepEqual(h._pushed[1], { event: "head-click", payload: { kind: "col", index: 2, shift: true } });
});

check("head-drag anchor rides an open cell draft as commit (click-away seal)", () => {
  const h = mountHook();
  const inp = { value: "half-typed" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  h.el._input = inp;
  h.el.dispatch("mousedown", headEvent({ c: "3" }, { button: 0 }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "col", index: 3, shift: false, commit: "half-typed" } },
  ]);
});

check("regression: plain td mousedown-drag still anchors + extends cell-click", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("A1"));
  h.el.dispatch("mouseover", { target: td({ ref: "B2" }) });
  assert.deepEqual(h._pushed, [
    { event: "cell-click", payload: { ref: "A1", shift: false } },
    { event: "cell-click", payload: { ref: "B2", shift: true } },
  ]);
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

// Dropdown v2 (Decision 9): _fnMatches now routes through the pointing kernel's
// fuzzyFns — prefix hits first (vocabulary order preserved), then SUBSTRING
// ("contains") hits, capped at 8. Empty query → [] (never the whole list).
check("_fnMatches: fuzzyFns — prefix then substring, capped at 8, empty → []", () => {
  const h = mountHook();
  h._fns = ["SUM", "SUMIF", "SUMIFS", "SUMX1", "SUMX2", "SUMX3", "SUMX4", "SUMX5", "SUMX6", "IF"];
  assert.deepEqual(plain(h._fnMatches("su")).slice(0, 3), ["SUM", "SUMIF", "SUMIFS"]);
  assert.equal(h._fnMatches("SU").length, 8); // 9 prefix candidates → capped
  assert.deepEqual(plain(h._fnMatches("")), []);
  // "if" is a PREFIX of IF and a SUBSTRING of SUMIF/SUMIFS — prefix wins order.
  assert.deepEqual(plain(h._fnMatches("if")), ["IF", "SUMIF", "SUMIFS"]);
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

// ── find-in-sheet (Ctrl+F) ──────────────────────────────────────────────────

// A keydown whose target IS the find input (closest(".sheet-find-input") self).
function findKey(key, opts = {}) {
  const inp = {
    matches: () => true,
    closest(sel) {
      return sel === ".sheet-find-input" ? inp : null;
    },
  };
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

// Cmd/Ctrl+F opens the SERVER-rendered find bar (never the browser's native
// page find — a DOM find sees only the 500-row window). It preventDefaults,
// arms the focus one-shot, and pushes find-open.
check("Cmd/Ctrl+F opens find: preventDefault + find-open push + focus one-shot", () => {
  const h1 = mountHook();
  const e1 = keydown("f", { metaKey: true });
  h1.el.dispatch("keydown", e1);
  assert.equal(e1.prevented, true);
  assert.equal(h1._focusFind, true);
  assert.deepEqual(h1._pushed, [{ event: "find-open", payload: {} }]);

  // Ctrl+F (non-mac) is the same binding; uppercase F (caps/shift-layout) too.
  const h2 = mountHook();
  h2.el.dispatch("keydown", keydown("F", { ctrlKey: true }));
  assert.deepEqual(h2._pushed, [{ event: "find-open", payload: {} }]);
});

// Cmd+Shift+F must NOT hijack — it's a distinct shortcut; only plain Cmd/Ctrl+F
// opens find (guards against stealing other bindings).
check("Cmd+Shift+F does not open find", () => {
  const h = mountHook();
  h.el.dispatch("keydown", keydown("f", { metaKey: true, shiftKey: true }));
  assert.deepEqual(h._pushed, []);
});

// Escape inside the find input closes the bar (find-close) and returns — it
// never falls through to the grid's Escape (Tab-exit arming).
check("Escape in the find input pushes find-close", () => {
  const h = mountHook();
  const e = findKey("Escape");
  h.el.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, [{ event: "find-close", payload: {} }]);
});

// A non-Escape key in the find input types normally: no push, no preventDefault
// (Enter is handled by the surrounding form's phx-submit, not the hook).
check("a printable key in the find input is left to the browser/form", () => {
  const h = mountHook();
  const e = findKey("a");
  h.el.dispatch("keydown", e);
  assert.equal(e.prevented, false);
  assert.deepEqual(h._pushed, []);
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

// ── #843/#858/#862 regression seals ─────────────────────────────────────────
//
// (1) GRID-SCOPE GUARD. #843 moved the keydown listener onto .sheet-editor so
// the formula bar (a sibling of the grid) is reachable — but that ancestor also
// holds the ~15 toolbar buttons, undo/redo, and the tab strip. Without the
// scope guard, Enter/Space on a focused toolbar button opened the cell editor
// and Tab was preventDefaulted into grid nav, re-trapping the keyboard
// (WCAG 2.1.2) across the whole toolbar. These pins FAIL against the pre-fix
// hook (which pushed edit-start / nav and called preventDefault).

for (const key of ["Enter", " ", "Tab"]) {
  check(`toolbar ${key === " " ? "Space" : key} keydown pushes nothing + no preventDefault (grid-scope guard)`, () => {
    const h = mountHook();
    const e = toolbarKey(key);
    h.root.dispatch("keydown", e);
    assert.deepEqual(h._pushed, [], `${key} on a toolbar button must not drive the grid key map`);
    assert.equal(e.prevented, false, `${key} on a toolbar button must keep native behaviour`);
  });
}

// Regression guard: the SAME keys with an in-grid target still behave exactly
// as before — the scope guard only rejects out-of-grid targets.
check("grid Enter still edit-starts, Tab still navs, Space still seeds (scope-guard regression pin)", () => {
  const hE = mountHook();
  const eE = keydown("Enter");
  hE.el.dispatch("keydown", eE);
  assert.deepEqual(hE._pushed, [{ event: "edit-start", payload: {} }]);
  assert.equal(eE.prevented, true);

  const hT = mountHook();
  const eT = keydown("Tab");
  hT.el.dispatch("keydown", eT);
  assert.deepEqual(hT._pushed, [{ event: "nav", payload: { key: "ArrowRight", shift: false } }]);
  assert.equal(eT.prevented, true);

  const hS = mountHook();
  hS.el._active = { dataset: { ref: "A1" }, classList: { contains: () => false } };
  hS.el.dispatch("keydown", keydown(" "));
  assert.deepEqual(hS._pushed, [{ event: "edit-start", payload: { seed: " " } }]);
});

// (2) TOOLBAR DRAFT-COMMIT SEAL. The format/style/align/bg/undo/redo buttons
// route through apply_meta_to_selection WITHOUT committing an open cell draft,
// so clicking one while a cell editor holds a typed draft silently reverted it.
// A .sheet-toolbar mousedown now rides the click-away `commit` protocol first.
// This pin FAILS against the pre-fix hook (no toolbar mousedown listener → the
// draft is dropped by the following patch).
check("toolbar-button mousedown with an open cell draft rides one cell-click commit", () => {
  const h = mountHook();
  h.el._active = { dataset: { ref: "B2" } };
  h.el._input = { value: "half-typed" };
  h.root.dispatch("mousedown", toolbarMousedown());
  assert.deepEqual(h._pushed, [
    { event: "cell-click", payload: { ref: "B2", shift: false, commit: "half-typed" } },
  ]);
});

check("toolbar-button mousedown with NO open editor pushes nothing", () => {
  const h = mountHook();
  h.el._active = { dataset: { ref: "B2" } };
  h.root.dispatch("mousedown", toolbarMousedown());
  assert.deepEqual(h._pushed, []);
});

// Mousedown into a toolbar TEXT INPUT (formula bar / name box) must NOT seal —
// that is the input's own focus/takeover flow (#813).
check("mousedown into a toolbar text input does NOT commit-and-close the editor", () => {
  const h = mountHook();
  h.el._active = { dataset: { ref: "B2" } };
  h.el._input = { value: "half-typed" };
  h.root.dispatch("mousedown", toolbarMousedown({ input: true }));
  assert.deepEqual(h._pushed, []);
});

// ── quote-aware TSV clipboard (both directions) + paste preflight ────────────
//
// Excel/Sheets encode a field containing a tab, newline, or double-quote as a
// double-quoted CSV/TSV field with doubled inner quotes. The pre-fix hook split
// paste on \n/\t with ZERO quote handling, so a multi-line Excel cell shattered
// into phantom rows and shifted everything below; copy joined raw values, so a
// cell with a tab/newline emitted corrupt TSV. These pins FAIL against the
// pre-fix hook (no _tsvEncode/_tsvParse; _selectionTsv joined raw; _onPaste
// pushed {tsv}).

// A paste event carrying clipboard text, with a non-input target.
function pasteEvent(text) {
  return {
    target: { matches: () => false },
    clipboardData: { getData: () => text },
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
}

check("_tsvEncode quotes tab/newline/quote fields and doubles inner quotes", () => {
  const h = mountHook();
  assert.equal(h._tsvEncode([["a", "b"]]), "a\tb");
  assert.equal(h._tsvEncode([["a\tb", "c"]]), '"a\tb"\tc');
  assert.equal(h._tsvEncode([["a\nb", "c"]]), '"a\nb"\tc');
  assert.equal(h._tsvEncode([['he said "hi"', "x"]]), '"he said ""hi"""\tx');
  // A plain field is never wrapped; null/number coerce to a string field.
  assert.equal(h._tsvEncode([["plain", 9, null]]), "plain\t9\t");
});

check("_tsvParse keeps a quoted multi-line cell as ONE cell; the row below is intact", () => {
  const h = mountHook();
  // B-column has an embedded newline; a naive \n split would shatter it.
  const rows = h._tsvParse('a\t"line1\nline2"\nc\td\n');
  assert.deepEqual(plain(rows), [
    ["a", "line1\nline2"],
    ["c", "d"],
  ]);
});

check("_tsvParse handles CRLF, tab-in-cell, doubled quotes, trailing newline", () => {
  const h = mountHook();
  assert.deepEqual(plain(h._tsvParse("a\tb\r\nc\td\r\n")), [
    ["a", "b"],
    ["c", "d"],
  ]);
  assert.deepEqual(plain(h._tsvParse('"a\tb"\tc')), [["a\tb", "c"]]);
  assert.deepEqual(plain(h._tsvParse('"he said ""hi"""')), [['he said "hi"']]);
  // A lone value with no separators is a single cell.
  assert.deepEqual(plain(h._tsvParse("solo")), [["solo"]]);
});

check("_tsvParse(_tsvEncode(x)) round-trips a grid with tricky fields", () => {
  const h = mountHook();
  const x = [
    ["a\nb", "c\td", 'q"q'],
    ["plain", "", "z"],
  ];
  assert.deepEqual(plain(h._tsvParse(h._tsvEncode(x))), x);
});

check("_selectionTsv quotes a cell whose value holds a newline (copy is safe)", () => {
  const h = mountHook();
  h.el._sel = [
    td({ r: "1", c: "1", v: "a\nb" }),
    td({ r: "1", c: "2", v: "c" }),
  ];
  // Pre-fix this emitted `a\nb\tc` (a phantom row on re-paste); now it's quoted.
  assert.equal(h._selectionTsv(), '"a\nb"\tc');
});

check("_onPaste parses client-side and pushes a structured {rows} grid, NOT {tsv}", () => {
  const h = mountHook();
  const e = pasteEvent('a\t"x\ny"\nc\td\n');
  h.el.dispatch("paste", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["a", "x\ny"], ["c", "d"]] } },
  ]);
});

check("_onPaste over the cell cap pushes paste-too-large and never paste", () => {
  const h = mountHook();
  h._pasteCellCap = 4; // shrink the bound for the test
  // 2x3 = 6 cells > 4.
  h.el.dispatch("paste", pasteEvent("a\tb\tc\nd\te\tf"));
  assert.deepEqual(h._pushed, [{ event: "paste-too-large", payload: { cells: 6 } }]);
  assert.equal(h._pushed.filter((p) => p.event === "paste").length, 0);
});

check("_onPaste at exactly the cap still pastes (boundary is strictly over)", () => {
  const h = mountHook();
  h._pasteCellCap = 4;
  h.el.dispatch("paste", pasteEvent("a\tb\nc\td")); // 4 cells == cap
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["a", "b"], ["c", "d"]] } },
  ]);
});

// ── fill handle + autofit (the mouse-trio slice) ────────────────────────────
//
// (1) The fill NUB (.sheet-fillnub, rendered at the selection rect's bottom-
// right corner) starts a FILL drag on mousedown: the hook tracks the hovered
// cell and pushes ONE fill-range {to} on mouseup — the server extends the fill
// from its authoritative selection rect. Pre-fix the nub had no handler, so
// the mousedown fell into _onCellMousedown and anchored a plain cell-click
// (collapsing the selection instead of filling).
// (2) DOUBLE-CLICK a header resize handle (.sheet-rsz) autofits that col/row:
// _onDblclick must branch on the handle BEFORE the td lookup. Pre-fix the td
// lookup returned null and nothing was pushed.
// (3) DOUBLE-CLICK the nub fills to the data extent (fill-extent {}). Pre-fix
// the dblclick resolved the corner td and pushed edit-start.

// A mousedown/dblclick whose target is the fill nub. The nub nests INSIDE the
// selection-corner td, so closest("td[data-ref]") resolves that td — which is
// exactly how the pre-fix cell handler hijacked the gesture.
function nubEvent(cornerRef, opts = {}) {
  const nub = {};
  const corner = td({ ref: cornerRef });
  return {
    button: 0,
    shiftKey: false,
    ...opts,
    target: {
      matches: () => false,
      closest(sel) {
        if (sel === ".sheet-fillnub") return nub;
        if (sel === "td[data-ref]") return corner;
        return null;
      },
    },
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
}

// A dblclick whose target is a header resize handle (.sheet-rsz).
function rszDblclick(kind, index) {
  const handle = { dataset: { kind, index } };
  return {
    target: {
      matches: () => false,
      closest(sel) {
        if (sel === ".sheet-rsz") return handle;
        return null;
      },
    },
    preventDefault() {},
  };
}

check("nub mousedown + mouseover + mouseup pushes ONE fill-range {to} and NO cell-click", () => {
  const h = mountHook();
  const e = nubEvent("B2");
  h.el.dispatch("mousedown", e);
  assert.equal(e.prevented, true);
  // The drag itself pushes nothing yet…
  assert.deepEqual(h._pushed, []);
  h.el.dispatch("mouseover", { target: td({ ref: "B5" }) });
  h.el.dispatch("mouseover", { target: td({ ref: "B5" }) }); // dedupe-safe
  dispatchWindow("mouseup", {});
  // …mouseup ships exactly one fill-range; the cell handler never anchored.
  assert.deepEqual(h._pushed, [{ event: "fill-range", payload: { to: "B5" } }]);
});

check("nub mousedown + mouseup with no hovered cell pushes nothing", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", nubEvent("B2"));
  dispatchWindow("mouseup", {});
  assert.deepEqual(h._pushed, []);
});

check("the click trailing a nub drag is swallowed", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", nubEvent("B2"));
  h.el.dispatch("mouseover", { target: td({ ref: "B4" }) });
  dispatchWindow("mouseup", {});
  h.el.dispatch("click", cellEvent("B4")); // synthetic post-drag click
  assert.deepEqual(h._pushed, [{ event: "fill-range", payload: { to: "B4" } }]);
});

check("dblclick on a col resize handle pushes autofit {kind:col,index}", () => {
  const h = mountHook();
  h.el.dispatch("dblclick", rszDblclick("col", "3"));
  assert.deepEqual(h._pushed, [{ event: "autofit", payload: { kind: "col", index: 3 } }]);
});

check("dblclick on a row resize handle pushes autofit {kind:row,index}", () => {
  const h = mountHook();
  h.el.dispatch("dblclick", rszDblclick("row", "7"));
  assert.deepEqual(h._pushed, [{ event: "autofit", payload: { kind: "row", index: 7 } }]);
});

check("dblclick on the fill nub pushes fill-extent {} (never edit-start)", () => {
  const h = mountHook();
  h.el.dispatch("dblclick", nubEvent("B2"));
  assert.deepEqual(h._pushed, [{ event: "fill-extent", payload: {} }]);
});

check("regression: plain td dblclick still starts an edit", () => {
  const h = mountHook();
  h.el.dispatch("dblclick", cellEvent("C3"));
  assert.deepEqual(h._pushed, [{ event: "edit-start", payload: {} }]);
});

// ── formula point-mode + intellisense wiring (S6+S7, the flagship) ──────────
//
// Every grammar decision routes through the two pure kernels
// (window.BarkparkSheetFormula / window.BarkparkSheetPointing), loaded into the
// sandbox above alongside the hook. These cases pin the WIRING: which gesture
// points vs commits, the drag/arrow/F4 mutations, the ghost accept-and-commit,
// the Escape ladder, read-only fail-closed, and commit normalization. Pixel
// painting (rainbow boxes, popover geometry, SR live region) stays a live-Studio
// carve-out — the node sandbox has no document.createElement, so every render
// method bails and these assertions hit the pure routing/commit logic.

// An editable hook: point-mode is client-owned, so we just flip the flags the
// server would have stamped (data-fns present → not read-only) + seed the fn
// vocabulary, exactly as the other autocomplete cases seed `_fns` post-mount.
function editable(fns) {
  const h = mountHook();
  h._readOnly = false;
  h._fns = fns || ["SUM", "AVERAGE", "COUNT", "COUNTA", "MIN", "MAX", "MEDIAN", "IF"];
  return h;
}
// Open a cell editor holding `value` with the caret at its end (a fakeInput
// carries value + selectionStart + setSelectionRange + closest).
function openEditor(h, value) {
  const inp = fakeInput(value);
  h.el._input = inp;
  return inp;
}

// THE WISH — type `=sum(`, drag B3:B5, hit Enter → `=SUM(B3:B5)` and a 6. The
// mousedown POINTS (never commits) because the caret sits right after `(`; the
// drag extends via the kernel's extendRef; Enter commits the normalized formula.
check("WISH: =sum( + mousedown B3 + drag to B5 + Enter → exactly {value:'=SUM(B3:B5)', move:'down'}", () => {
  const h = editable();
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("mousedown", cellEvent("B3")); // point-insert B3 (no server push)
  assert.equal(inp.value, "=sum(B3");
  h.el.dispatch("mouseover", { target: td({ ref: "B4" }) }); // drag extends…
  h.el.dispatch("mouseover", { target: td({ ref: "B5" }) });
  assert.equal(inp.value, "=sum(B3:B5");
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.deepEqual(h._pushed, [
    { event: "edit-commit", payload: { value: "=SUM(B3:B5)", move: "down" } },
  ]);
});

// THE GHOST PATH — `=sum(` with a contiguous numeric block above the active
// cell offers a `B3:B5` ghost; Enter accepts AND commits in ONE keystroke to the
// same payload. The ghost is render-only: it never enters input.value until the
// accept, and even then only the committed (normalized) value carries it.
check("GHOST: =sum( over B3:B5 numerics + Enter → same payload; ghost never in input.value pre-accept", () => {
  const h = editable();
  h.el._active = { dataset: { ref: "B6" } };
  h._getCell = () => (c, r) => (c === 2 && r >= 3 && r <= 5 ? { t: "n" } : null);
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("input", { target: inp }); // offers the ghost
  assert.equal(h._ghost.offered, "B3:B5");
  assert.equal(inp.value, "=sum("); // render-only — untouched
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.deepEqual(h._pushed, [
    { event: "edit-commit", payload: { value: "=SUM(B3:B5)", move: "down" } },
  ]);
  assert.equal(inp.value, "=sum("); // still untouched: the ghost rode only the commit
});

// A printable key silently dismisses a showing ghost (ghostReduce is the law) —
// the keystroke does its normal thing and Enter then commits the RAW draft.
check("ghost is dismissed by typing; a later Enter commits the raw draft (never the stale ghost)", () => {
  const h = editable();
  h.el._active = { dataset: { ref: "B6" } };
  h._getCell = () => (c, r) => (c === 2 && r >= 3 && r <= 5 ? { t: "n" } : null);
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("input", { target: inp });
  assert.equal(h._ghost.offered, "B3:B5");
  // user types a digit → the arg is no longer empty, ghost clears.
  inp.value = "=sum(9";
  inp.selectionStart = 6;
  h.el.dispatch("input", { target: inp });
  assert.equal(h._ghost.offered, null);
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.deepEqual(h._pushed, [
    { event: "edit-commit", payload: { value: "=SUM(9)", move: "down" } },
  ]);
});

// Operator-then-click: the caret after `+` expects a reference, so a cell click
// POINTS (inserts the ref) and pushes nothing.
check("operator-then-click inserts a ref at the caret (points, never commits)", () => {
  const h = editable();
  const inp = openEditor(h, "=A1+");
  h.el.dispatch("mousedown", cellEvent("C3"));
  assert.equal(inp.value, "=A1+C3");
  assert.deepEqual(h._pushed, []);
});

// A same-session drag over a header inserts a whole-column ref and extends it.
check("header point: click col-B header inserts B:B, drag to col-D → B:D", () => {
  const h = editable();
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("mousedown", headEvent({ c: "2" }, { button: 0 }));
  assert.equal(inp.value, "=sum(B:B");
  h.el.dispatch("mouseover", headEvent({ c: "4" }));
  assert.equal(inp.value, "=sum(B:D");
  assert.deepEqual(h._pushed, []); // pointed the whole time — no head-click op
});

// The row-header twin of the whole-column case (Decision 10 whole-row two-state):
// a ROW-header click inserts a whole-row ref "3:3" and a drag extends it to "3:6".
// Same _pointHeadMousedown path, kind="row" via rowRefText — proves both axes.
check("header point: click row-3 header inserts 3:3, drag to row-6 → 3:6", () => {
  const h = editable();
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("mousedown", headEvent({ r: "3" }, { button: 0 }));
  assert.equal(inp.value, "=sum(3:3");
  h.el.dispatch("mouseover", headEvent({ r: "6" }));
  assert.equal(inp.value, "=sum(3:6");
  assert.deepEqual(h._pushed, []); // pointed the whole time — no head-click op
});

// THE MOVED WALL ROW (licensed by charter §Decisions.4): a formula draft whose
// caret expects a reference now POINTS on a click instead of committing. This is
// the new pin for `row-formula-draft-clickaway-commits-TODAY`.
check("row-formula-draft-clickaway-POINTS-NOW ('=SUM(B3:B5' + caret-in-ref → click POINTS, no commit)", () => {
  const h = editable();
  const inp = openEditor(h, "=SUM(B3:B5"); // caret at end, inside/adjacent the ref
  h.el.dispatch("mousedown", cellEvent("D4"));
  // The click replaced the hot ref rather than committing — no cell-click op,
  // no edit-commit; the editor stayed open and its value changed.
  assert.deepEqual(h._pushed, []);
  assert.equal(inp.value, "=SUM(D4"); // point-replace of the B3:B5 tail
});

// THE COMMIT-PATH TWIN: the SAME click gesture with a NON-ref-expecting caret
// (after the closing paren) still commits BYTE-IDENTICAL to today (#813), riding
// the draft as `commit` on cell-click — unnormalized, since click-away commit is
// NOT one of the two normalized push sites (Decision 11).
check("commit-path twin: caret after ')' → click COMMITS byte-identical (rides commit, unnormalized)", () => {
  const h = editable();
  const inp = openEditor(h, "=SUM(B3:B5)"); // caret after ')'
  h.el.dispatch("mousedown", cellEvent("D4"));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "D4", shift: false, commit: "=SUM(B3:B5)" } }],
  );
  assert.equal(inp.value, "=SUM(B3:B5)"); // never mutated — it committed, did not point
});

// The twin above uses an already-canonical draft, so it cannot DISTINGUISH a
// verbatim ride from a normalized one. This lowercase draft makes "unnormalized"
// falsifiable (Decision 11: the click-away commit is NOT a normalize site — only
// the Enter/Tab edit-commit and bar-commit are): a lowercase, complete formula
// must ride the cell-click `commit` byte-for-byte, still lowercase.
check("commit-path twin: lowercase draft rides click-away commit VERBATIM (not normalized)", () => {
  const h = editable();
  const inp = openEditor(h, "=sum(b3:b5)"); // complete, lowercase, caret after ')'
  h.el.dispatch("mousedown", cellEvent("D4"));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "D4", shift: false, commit: "=sum(b3:b5)" } }],
  );
});

// F4 cycles the $-anchoring of the ref at the caret (A1 → $A$1 → A$1 → …); it
// never commits.
check("F4 cycles the ref $-anchoring at the caret (no commit)", () => {
  const h = editable();
  const inp = openEditor(h, "=A1");
  h.el.dispatch("keydown", cellKey("F4", inp));
  assert.equal(inp.value, "=$A$1");
  h.el.dispatch("keydown", cellKey("F4", inp));
  assert.equal(inp.value, "=A$1");
  assert.deepEqual(h._pushed, []);
});

// Enter-mode vs Edit-mode governs the arrows (Decision 5). Edits begun by typing
// start in Enter-mode: an arrow in ref-context drives the phantom ref cursor
// seeded at the active cell. F2 toggles to Edit-mode, where the arrow is native
// caret movement (no ref, no push). Enter ALWAYS commits (proven elsewhere).
check("Enter-mode arrow points a phantom ref (seeded at the active cell); F2 → Edit-mode arrow does not", () => {
  const h = editable();
  h.el._active = { dataset: { ref: "C5" } };
  const inp = openEditor(h, "=A1+");
  h.el.dispatch("keydown", cellKey("ArrowUp", inp)); // Enter-mode: phantom C5 → C4
  assert.equal(inp.value, "=A1+C4");
  assert.deepEqual(h._pushed, []);

  const h2 = editable();
  h2.el._active = { dataset: { ref: "C5" } };
  const inp2 = openEditor(h2, "=A1+");
  h2.el.dispatch("keydown", cellKey("F2", inp2)); // → Edit-mode
  h2.el.dispatch("keydown", cellKey("ArrowUp", inp2));
  assert.equal(inp2.value, "=A1+"); // native caret move — text untouched
  assert.deepEqual(h2._pushed, []);
});

// Shift extends the phantom range instead of moving it (Enter-mode).
check("Enter-mode Shift+Arrow extends the phantom range from the active cell", () => {
  const h = editable();
  h.el._active = { dataset: { ref: "B3" } };
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("keydown", cellKey("ArrowDown", inp)); // B3 → B4 (single)
  assert.equal(inp.value, "=sum(B4");
  h.el.dispatch("keydown", cellKey("ArrowDown", inp, { shiftKey: true })); // extend → B4:B5
  assert.equal(inp.value, "=sum(B4:B5");
  assert.deepEqual(h._pushed, []);
});

// The Escape ladder, strictly ordered (Decision 12): dropdown → ghost → pending
// point session → cancel edit, one rung per press, only the last rung pushes.
check("Escape ladder order: dropdown → ghost → point session → cancel", () => {
  const h = editable();
  h.el._active = { dataset: { ref: "B6" } };
  h._getCell = () => (c, r) => (c === 2 && r >= 3 && r <= 5 ? { t: "n" } : null);
  const inp = openEditor(h, "=SU");
  // (1) dropdown open → Escape closes the menu, nothing pushed.
  h.el.dispatch("input", { target: inp });
  assert.equal(!!h._fn, true);
  h.el.dispatch("keydown", cellKey("Escape", inp));
  assert.equal(!!h._fn, false);
  assert.deepEqual(h._pushed, []);
  // (2) ghost offered → Escape dismisses it, nothing pushed.
  inp.value = "=sum(";
  inp.selectionStart = 5;
  h.el.dispatch("input", { target: inp });
  assert.equal(h._ghost.offered, "B3:B5");
  h.el.dispatch("keydown", cellKey("Escape", inp));
  assert.equal(h._ghost.offered, null);
  assert.deepEqual(h._pushed, []);
  // (3) a pending point session → Escape reverts it to the pre-point text.
  h.el.dispatch("mousedown", cellEvent("B3"));
  assert.equal(inp.value, "=sum(B3");
  h.el.dispatch("keydown", cellKey("Escape", inp));
  assert.equal(inp.value, "=sum("); // reverted
  assert.deepEqual(h._pushed, []);
  // (4) nothing pending → Escape cancels the edit (the only rung that pushes).
  h.el.dispatch("keydown", cellKey("Escape", inp));
  assert.deepEqual(h._pushed, [{ event: "edit-cancel", payload: {} }]);
});

// Read-only fail-closed (Decision 12): a hook with no data-fns never enters
// point-mode — a click falls through to today's click-away SELECTION path.
// Wave 43 amends the payload, not the route: the click still selects B3, but the
// `commit` ride is stripped (a read-mode grid can hold no cell editor — the
// template gates .sheet-cell-input on @editable and edit-start is denied — so
// the ride is defence against a shape that cannot occur, kept fail-closed).
check("read-only sheet never points: a click selects, commit ride stripped (fail closed)", () => {
  const h = mountHook({ readOnly: true }); // no data-fns → _readOnly true
  assert.equal(h._readOnly, true);
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("mousedown", cellEvent("B3"));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "cell-click"),
    [{ event: "cell-click", payload: { ref: "B3", shift: false } }],
  );
  assert.equal(inp.value, "=sum("); // never mutated by a point insert
});

// Read-only fails closed on the KEYBOARD point entries too, not just the click
// (charter Decision 12: "read-only sheets fail closed on EVERY point entry:
// cell/header mousedown, arrows, F4, ghost"). We force an editor onto a
// read-only hook (same tactic as the click case) and prove F4 / the phantom
// arrow / the ghost predictor each stay inert — a keystroke never point-mutates.
check("read-only sheet never points: F4 is inert, no $-anchoring cycle (fail closed)", () => {
  const h = mountHook({ readOnly: true }); // _readOnly true
  const inp = openEditor(h, "=A1");
  h.el.dispatch("keydown", cellKey("F4", inp));
  assert.equal(inp.value, "=A1"); // no cycleDollar mutation
  assert.deepEqual(h._pushed, []);
});

check("read-only sheet never points: an arrow drives no phantom ref (fail closed)", () => {
  const h = mountHook({ readOnly: true }); // _readOnly true
  h.el._active = { dataset: { ref: "C5" } };
  const inp = openEditor(h, "=A1+");
  h.el.dispatch("keydown", cellKey("ArrowUp", inp));
  assert.equal(inp.value, "=A1+"); // no phantom ref inserted
  assert.deepEqual(h._pushed, []);
});

check("read-only sheet never points: the ghost is never offered (fail closed)", () => {
  const h = mountHook({ readOnly: true }); // _readOnly true
  h.el._active = { dataset: { ref: "B6" } };
  h._getCell = () => (c, r) => (c === 2 && r >= 3 && r <= 5 ? { t: "n" } : null);
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("input", { target: inp });
  assert.equal(h._ghost.offered, null); // never offered on a read-only sheet
  // …and since wave 43 the following Enter pushes NOTHING AT ALL: `edit-commit`
  // is outside the read-mode allowlist, so the commit never leaves the client
  // (the server's write_capable:false clause dropped it before too — this is the
  // client half declining to ask). The ghost inertness is what the case pins;
  // the raw draft it WOULD have committed is "=SUM()" (see the editable twin).
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.deepEqual(h._pushed, []);
});

// A printable typed after a point insert LOCKS the hot ref: a subsequent click
// then INSERTS a fresh ref (not replace) — the locked ref is now ordinary text.
check("a typed character locks the hot ref; the next click inserts a new ref", () => {
  const h = editable();
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("mousedown", cellEvent("B3")); // point-insert B3 (hot)
  assert.equal(inp.value, "=sum(B3");
  // user types '+' → input event fires, locking the hot ref.
  inp.value = "=sum(B3+";
  inp.selectionStart = 8;
  h.el.dispatch("input", { target: inp });
  assert.equal(h._hot, null); // locked
  h.el.dispatch("mousedown", cellEvent("C4")); // caret after '+' → point-INSERT
  assert.equal(inp.value, "=sum(B3+C4");
  assert.deepEqual(h._pushed, []);
});

// bar-commit normalization (Decision 11): the Tab bar-commit push is canonicalized
// (uppercased fns/refs, balanced parens) — the server write path stays untouched.
check("bar-commit (Tab) normalizes the pushed formula", () => {
  const h = editable();
  const bar = { value: "=sum(a1:a2", dataset: { raw: "" } };
  bar.closest = (sel) => (sel === ".sheet-bar-input" ? bar : null);
  const e = keydown("Tab");
  e.target = bar;
  h.root.dispatch("keydown", e);
  assert.deepEqual(h._pushed, [
    { event: "bar-commit", payload: { value: "=SUM(A1:A2)", move: "right" } },
  ]);
});

// edit-commit normalization: a plain Enter commit lowercases-in, canonical-out.
check("edit-commit (Enter) normalizes the pushed formula", () => {
  const h = editable();
  const inp = openEditor(h, "=sum(a1:a2");
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.deepEqual(h._pushed, [
    { event: "edit-commit", payload: { value: "=SUM(A1:A2)", move: "down" } },
  ]);
});

// A non-formula commit is returned verbatim by normalizeFormula (a plain literal
// is never touched) — the pre-wave commit behavior is preserved.
check("edit-commit of a plain literal is unchanged by normalization", () => {
  const h = editable();
  const inp = openEditor(h, "hello");
  h.el.dispatch("keydown", cellKey("Enter", inp));
  assert.deepEqual(h._pushed, [
    { event: "edit-commit", payload: { value: "hello", move: "down" } },
  ]);
});

// ── volatile-state lifetime (perfecter hardening) ────────────────────────────
//
// Commits that BYPASS _commitEditor (the #858 toolbar seal, click-away rides,
// bar commits) end an edit without touching the hook's volatile point/ghost
// state. Each case below pins that the state dies WITH the edit — without the
// fixes, a stale _ghost.offered splices into the next editor's first Enter,
// and a stale _hot span lets the hot rule point-replace arbitrary text whose
// caret lands on the dead span's end offset.

// Toolbar-seal commit with a ghost showing → server patch closes the editor →
// the NEXT edit's Enter must commit ITS OWN value, never splice the old ghost.
check("stale ghost dies with the editor: toolbar commit + patch → next Enter commits its own value", () => {
  const h = editable();
  h.el._active = { dataset: { ref: "B6" } };
  h._getCell = () => (c, r) => (c === 2 && r >= 3 && r <= 5 ? { t: "n" } : null);
  const inp = openEditor(h, "=sum(");
  h.el.dispatch("input", { target: inp });
  assert.equal(h._ghost.offered, "B3:B5");
  // Bold-button mousedown (the #858 seal): rides commit, bypasses _commitEditor.
  h.root.dispatch("mousedown", toolbarMousedown());
  // The server closes the editor; the patch lands with no cell input on screen.
  h.el._input = null;
  h.updated();
  assert.equal(h._ghost.offered, null); // volatile state died with the edit
  const inp2 = openEditor(h, "hello");
  h.el.dispatch("keydown", cellKey("Enter", inp2));
  assert.deepEqual(
    h._pushed.filter((p) => p.event === "edit-commit"),
    [{ event: "edit-commit", payload: { value: "hello", move: "down" } }],
  );
});

// A focused-DIRTY bar is a LIVE edit with no cell editor on screen — a mid-
// session patch (remote collaborator delta) must NOT kill its point session.
check("updated() preserves a LIVE bar point session (focused dirty bar, no cell editor)", () => {
  const h = editable();
  const bar = {
    value: "=", dataset: { raw: "" }, selectionStart: 1,
    setSelectionRange(a) { this.selectionStart = a; },
    closest: (sel) => (sel === ".sheet-bar-input" ? bar : null),
    matches: () => false,
  };
  h.root._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("mousedown", cellEvent("B3")); // bar point session: hot = B3
  assert.equal(bar.value, "=B3");
  h.updated(); // a remote-delta patch mid-session
  assert.equal(h._hot && h._hot.start, 1); // session survives the patch
  sandbox.document.activeElement = null;
});

// Bar Tab-commit ends the bar edit: the hot span (offsets into the BAR's text)
// must die there, or a fresh cell editor whose caret happens to land on the
// stale span's end offset gets point-REPLACED across 1..6 ("=D4") instead of
// the correct adjacent-ref replace ("=A1+D4").
check("stale hot dies with the bar Tab-commit: next editor's click replaces ITS ref, not the dead span", () => {
  const h = editable();
  const bar = {
    value: "=", dataset: { raw: "" }, selectionStart: 1,
    setSelectionRange(a) { this.selectionStart = a; },
    closest: (sel) => (sel === ".sheet-bar-input" ? bar : null),
    matches: () => false,
  };
  h.root._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("mousedown", cellEvent("B3"));
  h.el.dispatch("mouseover", { target: td({ ref: "B5" }) }); // drag → B3:B5
  assert.equal(bar.value, "=B3:B5");
  assert.equal(h._hot.start, 1);
  assert.equal(h._hot.end, 6);
  const e = keydown("Tab");
  e.target = bar;
  h.root.dispatch("keydown", e); // bar-commit push + volatile state cleared
  assert.equal(h._hot, null);
  assert.equal(h._pointSession, false);
  sandbox.document.activeElement = null;
  const inp = openEditor(h, "=A1+B2"); // caret 6 == the dead span's end offset
  h.el.dispatch("mousedown", cellEvent("D4"));
  assert.equal(inp.value, "=A1+D4"); // adjacent-ref replace, NOT "=D4"
});

// Bar Escape ends the bar edit with NO server round-trip (nothing pushed, no
// patch will ever clean up) — the volatile state must be dropped by hand.
check("bar Escape clears the volatile point state (no patch will do it)", () => {
  const h = editable();
  const bar = {
    value: "=", dataset: { raw: "=OLD" }, selectionStart: 1,
    setSelectionRange(a) { this.selectionStart = a; },
    closest: (sel) => (sel === ".sheet-bar-input" ? bar : null),
    matches: () => false,
  };
  h.root._bar = bar;
  sandbox.document.activeElement = bar;
  h.el.dispatch("mousedown", cellEvent("B3")); // bar point session
  assert.equal(bar.value, "=B3");
  const e = keydown("Escape");
  e.target = bar;
  h.root.dispatch("keydown", e);
  assert.equal(bar.value, "=OLD"); // reverted to data-raw (pre-existing behavior)
  assert.equal(h._hot, null);
  assert.equal(h._pointSession, false);
  assert.deepEqual(h._pushed, []); // Escape pushes nothing, exactly as before
  sandbox.document.activeElement = null;
});

// Bar ENTER commits via the surrounding form (phx-submit "bar-commit") — the
// third commit surface. Decision 11's canonicalization must not depend on
// WHICH key committed the bar: the submit listener normalizes INTO the input
// before LiveView serializes the form, so Enter and Tab commit the same bytes.
check("bar Enter (form submit) normalizes the bar value before LiveView serializes it", () => {
  const h = editable();
  const bar = { value: "=sum(a1:a2", dataset: { raw: "" } };
  const form = {
    closest: (sel) => (sel === ".sheet-bar-form" ? form : null),
    querySelector: (sel) => (sel === ".sheet-bar-input" ? bar : null),
  };
  h.root.dispatch("submit", { target: form });
  assert.equal(bar.value, "=SUM(A1:A2)");
});

// Read-only twin: the server drops a read-only bar-commit, so the client must
// never rewrite a value that cannot commit (fail closed, Decision 12).
check("read-only sheet: bar submit never rewrites the value (fail closed)", () => {
  const h = mountHook({ readOnly: true }); // no data-fns → _readOnly true
  const bar = { value: "=sum(a1", dataset: { raw: "" } };
  const form = {
    closest: (sel) => (sel === ".sheet-bar-form" ? form : null),
    querySelector: (sel) => (sel === ".sheet-bar-input" ? bar : null),
  };
  h.root.dispatch("submit", { target: form });
  assert.equal(bar.value, "=sum(a1"); // untouched
});

// ── #813/#858 COMMIT-RIDE REGRESSION WALL ──────────────────────────────────
// (wave-2 wiring must keep every row green; rows may only change with a
//  charter-documented contract change — see bp-sheets-formula-ux-epic-charter.md
//  §Decisions.4, "the pre-existing #813/#858 harness tests are the permanent
//  regression wall".)
//
// The wall freezes TODAY's click-away commit grammar as an explicit, greppable
// table so the wave-2 point-mode builder inherits named contracts. It pins the
// pure arbiter (`_rideCommits`) and the FOUR sites that ride it — cell
// mousedown, header click, header mousedown-drag anchor, and the toolbar
// mousedown seal — plus the no-anchor guards and the drag trailing-click
// swallow. Assertions are exact deepEqual on the captured pushEventTo args.
//
// WAVE-2 CHANGE POINT (executed): `_rideCommits` still ALWAYS attaches `commit`
// when a cell editor is open — it is unchanged, a pure arbiter. The NEW
// caret-context-awareness lives one level up, in `_onCellMousedown`: point
// routing runs BEFORE `_rideCommits`, so a click while the caret expects a
// reference POINTS and never reaches the commit path at all. Accordingly the
// single licensed row `row-formula-draft-clickaway-commits-TODAY` has MOVED out
// of this pure-arbiter table (a formula draft in `_rideCommits` still returns
// commit — that unit did not change) to the "formula point-mode routing"
// section above, where it is re-pinned end-to-end as the NEW point behavior AND
// twinned with a commit-path case proving a non-ref-expecting caret still
// commits byte-identically (charter §Decisions.4 + Amendment A1). Every other
// row here is invariant.

// Setup helpers — reuse the fake-DOM factories: _rideCommits looks the cell
// draft up on `el` (.sheet-cell-input) and the bar up on `root` (.sheet-bar-
// input, sibling of the grid); the toolbar seal reads td.sheet-active on `el`.
function wallDraft(h, value) {
  h.el._input = { value };
}
function wallActive(h, ref) {
  h.el._active = { dataset: { ref } };
}
function wallBar(h, { value, raw, focused }) {
  const bar = { value, dataset: { raw } };
  h.root._bar = bar;
  if (focused) sandbox.document.activeElement = bar;
  return bar;
}

// A wall check resets the GLOBAL sandbox.document.activeElement before AND
// after (a dirty-bar row that throws must not leak focus into the next row).
function wall(name, fn) {
  check(name, () => {
    sandbox.document.activeElement = null;
    try {
      fn();
    } finally {
      sandbox.document.activeElement = null;
    }
  });
}

// (A) The pure arbiter `_rideCommits` — the one function all three riding sites
// funnel through. Table over draft/bar state → the exact augmented payload.
const RIDE_COMMITS_MATRIX = [
  {
    name: "no draft, no bar → payload untouched",
    setup: () => {},
    out: { ref: "A1", shift: false },
  },
  {
    name: "non-formula draft 'hello' → commit:'hello'",
    setup: (h) => wallDraft(h, "hello"),
    out: { ref: "A1", shift: false, commit: "hello" },
  },
  {
    // Element-truthiness, NOT value-truthiness: an OPEN-but-empty editor still
    // rides commit:'' (the server clears the cell), which is not the same as a
    // closed editor (no commit key at all).
    name: "open-but-empty draft → commit:'' (element truthiness, not value)",
    setup: (h) => wallDraft(h, ""),
    out: { ref: "A1", shift: false, commit: "" },
  },
  {
    name: "dirty focused bar (value!==raw) → bar_commit",
    setup: (h) => wallBar(h, { value: "=SUM(A1:A9)", raw: "=SUM(A1:A2)", focused: true }),
    out: { ref: "A1", shift: false, bar_commit: "=SUM(A1:A9)" },
  },
  {
    name: "clean focused bar (value===raw) → NO bar_commit",
    setup: (h) => wallBar(h, { value: "=SUM(A1:A2)", raw: "=SUM(A1:A2)", focused: true }),
    out: { ref: "A1", shift: false },
  },
  {
    // The mirror keeps the bar in sync with the cell editor, so a non-focused
    // dirty bar is a mirror artifact, not a user draft — it rides nothing.
    name: "dirty UNfocused bar → NO bar_commit",
    setup: (h) => wallBar(h, { value: "mirror-shadow", raw: "", focused: false }),
    out: { ref: "A1", shift: false },
  },
  {
    name: "cell draft AND dirty focused bar → BOTH commit and bar_commit",
    setup: (h) => {
      wallDraft(h, "x");
      wallBar(h, { value: "9", raw: "", focused: true });
    },
    out: { ref: "A1", shift: false, commit: "x", bar_commit: "9" },
  },
];
for (const row of RIDE_COMMITS_MATRIX) {
  wall(`_rideCommits — ${row.name}`, () => {
    const h = mountHook();
    row.setup(h);
    // _rideCommits mutates + returns the SAME payload object (node-realm plain
    // object, node Object.prototype) — strict deepEqual compares by value.
    assert.deepEqual(h._rideCommits({ ref: "A1", shift: false }), row.out);
  });
}

// (B) The FOUR ride sites carry the open cell draft as `commit`, end-to-end
// through the real event handlers. Exact deepEqual on the full push log.
const RIDE_SITES = [
  {
    name: "cell mousedown (_onCellMousedown)",
    run: (h) => {
      wallDraft(h, "hello");
      h.el.dispatch("mousedown", cellEvent("D4"));
    },
    expected: [{ event: "cell-click", payload: { ref: "D4", shift: false, commit: "hello" } }],
  },
  {
    name: "header click (_onClick)",
    run: (h) => {
      wallDraft(h, "hello");
      h.el.dispatch("click", headEvent({ c: "3" }));
    },
    expected: [
      { event: "head-click", payload: { kind: "col", index: 3, shift: false, commit: "hello" } },
    ],
  },
  {
    // Anchor rides the draft; the shift-EXTENDS that follow are plain (no
    // re-ride) — the draft commits exactly once, on the anchor.
    name: "header mousedown-drag anchor (_onHeadMousedown); shift-extend does NOT re-ride",
    run: (h) => {
      wallDraft(h, "hello");
      h.el.dispatch("mousedown", headEvent({ c: "3" }, { button: 0 }));
      h.el.dispatch("mouseover", headEvent({ c: "5" }));
    },
    expected: [
      { event: "head-click", payload: { kind: "col", index: 3, shift: false, commit: "hello" } },
      { event: "head-click", payload: { kind: "col", index: 5, shift: true } },
    ],
  },
  {
    // The toolbar seal builds its OWN payload (not via _rideCommits) — it rides
    // `commit` but NEVER `bar_commit`, and re-selects the still-active cell.
    name: "toolbar mousedown (_onToolbarMousedown)",
    run: (h) => {
      wallActive(h, "B2");
      wallDraft(h, "hello");
      h.root.dispatch("mousedown", toolbarMousedown());
    },
    expected: [{ event: "cell-click", payload: { ref: "B2", shift: false, commit: "hello" } }],
  },
];
for (const site of RIDE_SITES) {
  wall(`ride site rides commit — ${site.name}`, () => {
    const h = mountHook();
    site.run(h);
    assert.deepEqual(h._pushed, site.expected);
  });
}

// (B′) The bar_commit path proven end-to-end through a real site (cell
// mousedown), not just the _rideCommits unit.
wall("ride site carries bar_commit — cell mousedown with a dirty focused bar", () => {
  const h = mountHook();
  wallBar(h, { value: "=SUM(A1:A9)", raw: "=SUM(A1:A2)", focused: true });
  h.el.dispatch("mousedown", cellEvent("D4"));
  assert.deepEqual(h._pushed, [
    { event: "cell-click", payload: { ref: "D4", shift: false, bar_commit: "=SUM(A1:A9)" } },
  ]);
});

// (C) The toolbar seal's guards (#858/#862): it fires ONLY when there is
// both an open draft AND an active cell, and never when the target is a text
// input (that is the input's own #813 focus/takeover flow). It also NEVER
// rides bar_commit — the seal builds its own payload, NOT via _rideCommits
// (a dirty focused bar during a toolbar click is the bar's own flow); the
// charter fixes the seal permanently ("toolbar/outside clicks always commit
// as today, #858 seal untouched"), so a refactor that routed it through
// _rideCommits would silently change the wire grammar — the negative row
// below reds on that.
const TOOLBAR_GUARDS = [
  {
    name: "open draft + active cell → one cell-click commit",
    run: (h) => {
      wallActive(h, "B2");
      wallDraft(h, "hello");
      h.root.dispatch("mousedown", toolbarMousedown());
    },
    expected: [{ event: "cell-click", payload: { ref: "B2", shift: false, commit: "hello" } }],
  },
  {
    // deepEqual is exact-keys: a bar_commit key sneaking into the payload
    // fails this row even though commit still rides.
    name: "dirty focused bar → commit rides, bar_commit NEVER (seal ≠ _rideCommits)",
    run: (h) => {
      wallActive(h, "B2");
      wallDraft(h, "hello");
      wallBar(h, { value: "=SUM(A1:A9)", raw: "=SUM(A1:A2)", focused: true });
      h.root.dispatch("mousedown", toolbarMousedown());
    },
    expected: [{ event: "cell-click", payload: { ref: "B2", shift: false, commit: "hello" } }],
  },
  {
    name: "target is a text input/textarea/select → NO push",
    run: (h) => {
      wallActive(h, "B2");
      wallDraft(h, "hello");
      h.root.dispatch("mousedown", toolbarMousedown({ input: true }));
    },
    expected: [],
  },
  {
    name: "no open cell draft → NO push",
    run: (h) => {
      wallActive(h, "B2");
      h.root.dispatch("mousedown", toolbarMousedown());
    },
    expected: [],
  },
  {
    name: "no active cell ref → NO push",
    run: (h) => {
      wallDraft(h, "hello");
      h.root.dispatch("mousedown", toolbarMousedown());
    },
    expected: [],
  },
];
for (const g of TOOLBAR_GUARDS) {
  wall(`toolbar seal guard — ${g.name}`, () => {
    const h = mountHook();
    g.run(h);
    assert.deepEqual(h._pushed, g.expected);
  });
}

// (D) Cell mousedown NEVER anchors a cell-click when the target is a resize
// handle, the fill nub, or a text input — those gestures own their own handler.
function guardTargetMousedown(kind) {
  // The resize handle carries dataset.{kind,px,index} — the resize-drag handler
  // (_onMousedown) reads them; a bare {} would throw before the cell guard runs.
  const rsz = { dataset: { kind: "col", px: "88", index: "1" } };
  const target = {
    matches: () => kind === "input",
    closest(sel) {
      if (sel === ".sheet-rsz") return kind === "rsz" ? rsz : null;
      if (sel === ".sheet-fillnub") return kind === "fillnub" ? {} : null;
      return null; // never a td[data-ref]
    },
  };
  return {
    button: 0,
    shiftKey: false,
    target,
    pageX: 0,
    pageY: 0,
    preventDefault() {},
    stopPropagation() {},
  };
}
for (const kind of ["rsz", "fillnub", "input"]) {
  wall(`cell mousedown on a .sheet-${kind === "input" ? "input-target" : kind} pushes NO cell-click`, () => {
    const h = mountHook();
    h.el.dispatch("mousedown", guardTargetMousedown(kind));
    assert.deepEqual(
      h._pushed.filter((p) => p.event === "cell-click"),
      [],
    );
  });
}

// (E) The drag-select trailing-click suppression still swallows EXACTLY one
// click — the synthetic click that trails a mousedown/drag is dropped so it
// cannot re-anchor and collapse the just-dragged selection; the next real
// click passes through.
wall("drag trailing-click suppression swallows exactly one click, then passes", () => {
  const h = mountHook();
  h.el.dispatch("mousedown", cellEvent("A1")); // anchors + arms _suppressClick
  dispatchWindow("mouseup", {});
  h.el.dispatch("click", cellEvent("A1")); // synthetic post-drag click → swallowed
  assert.equal(h._pushed.length, 1);
  h.el.dispatch("click", cellEvent("C4")); // a fresh standalone click → anchors
  assert.deepEqual(h._pushed, [
    { event: "cell-click", payload: { ref: "A1", shift: false } },
    { event: "cell-click", payload: { ref: "C4", shift: false } },
  ]);
});

// ── QR-D critic regression locks ────────────────────────────────────────────
// Wave-6 integration-critic SAFE-verdict probe, pinned as a permanent lock.
// The click-away × drag-select cross on the CELL (td) path: a mousedown that
// COMMITS an open draft, immediately FOLLOWED by a drag-extend. Its HEADER twin
// already lives at RIDE_SITES[2] ("header mousedown-drag anchor … shift-extend
// does NOT re-ride") and the pure ride sites (RIDE_SITES[0]) cover the single
// cell mousedown commit — but the CELL drag-EXTEND with an open draft was
// unpinned: :855 drags a cell with NO draft, :867 commits with NO extend. This
// closes the gap — the anchor must ride `commit` exactly once and the extend
// must stay plain (shift:true, never a second commit). A regression that made
// the cell `onOver` re-attach `commit` (double-commit on every dragged cell)
// slips past every existing row but reds here.
//
// The draft is deliberately a NON-'='-draft on an EDITABLE hook: the caret-
// context arbiter classifies it as COMMIT (not point-mode), so this exercises
// the click-away commit path even though point-mode is fully available — the
// distinguishing twin of the :1616 formula-draft-POINTS row.
check("QR-D: cell mousedown-drag with an open non-formula draft commits ONCE on anchor; extend stays plain", () => {
  const h = editable();
  openEditor(h, "half-typed"); // non-formula → arbiter routes to COMMIT, not point
  h.el.dispatch("mousedown", cellEvent("A1")); // anchor: commits the draft
  h.el.dispatch("mouseover", { target: td({ ref: "B2" }) }); // extend: plain shift, no re-ride
  assert.deepEqual(h._pushed, [
    { event: "cell-click", payload: { ref: "A1", shift: false, commit: "half-typed" } },
    { event: "cell-click", payload: { ref: "B2", shift: true } },
  ]);
});

// ── formula clipboard (S-CLIP / QL-D5): copy carries the formula, paste rebases ─
//
// On copy the OS clipboard still gets the computed VALUES (Excel interop), but
// the hook stashes an in-app formula clipboard keyed by that exact TSV. On paste
// of OUR OWN copy (clipboard text === the stashed signature) the {rows} grid is
// rebuilt from the copied formulas, rebased by the delta from the copy origin to
// the paste anchor (active cell), honoring $ anchors via the kernel's
// rebaseFormula. A FOREIGN clipboard (any other text) falls through to today's
// quote-aware VALUE paste, BYTE-IDENTICAL — the regression lock.

// A copy event with a fake clipboard that records what the hook writes.
function copyEvent() {
  const store = {};
  return {
    target: { matches: () => false },
    clipboardData: { setData: (type, val) => { store[type] = val; } },
    _data: store,
    prevented: false,
    preventDefault() { this.prevented = true; },
  };
}

// A selected cell <td .sheet-sel> carrying data-r/c/v and an optional data-f
// (the stored formula sans leading '=', S-GRID's QL-D6 stamp).
function selCell({ r, c, v, f }) {
  const cell = { dataset: { r, c, v } };
  if (f != null) cell.dataset.f = f;
  return cell;
}

// Copy `sel` (setting the active cell to `activeRef`), then return the hook so a
// follow-up paste can be dispatched. Asserts the OS clipboard got the values.
function copySelection(h, sel, activeRef) {
  h.el._sel = sel;
  if (activeRef) h.el._active = { dataset: { ref: activeRef } };
  const ce = copyEvent();
  h.el.dispatch("copy", ce);
  return ce;
}

check("copy a formula cell, paste one row down → the paste carries the REBASED formula", () => {
  const h = mountHook();
  // '=A1+1' lives at B2 (r2,c2); its computed value is 2.
  copySelection(h, [selCell({ r: "2", c: "2", v: "2", f: "A1+1" })], "B2");
  // paste anchor is B3 (r3,c2) → delta (0,+1); the OS clipboard text is "2".
  h.el._active = { dataset: { ref: "B3" } };
  h.el.dispatch("paste", pasteEvent("2"));
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["=A2+1"]] } },
  ]);
});

check("SEAM ROBUSTNESS: a data-f stamped WITH a leading '=' does not double-prefix (==A2)", () => {
  const h = mountHook();
  // The engine's canonical `f` drops the '=' but "tolerates it on read", so a
  // real stamp MAY carry one. Capture must normalize to sans-'=' so the paste
  // re-prefix yields exactly one '=' — never '==A2+1'.
  copySelection(h, [selCell({ r: "2", c: "2", v: "2", f: "=A1+1" })], "B2");
  assert.deepEqual(plain(h._formulaClip.formulas), [["A1+1"]]); // stored canonical
  h.el._active = { dataset: { ref: "B3" } };
  h.el.dispatch("paste", pasteEvent("2"));
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["=A2+1"]] } },
  ]);
});

check("$-anchored refs do NOT shift; a horizontal+vertical delta rebases relatives only", () => {
  const h = mountHook();
  copySelection(h, [selCell({ r: "2", c: "2", v: "9", f: "$A$1+A1" })], "B2");
  // paste at D5 (r5,c4) → delta (+2,+3): $A$1 pinned, A1 → C4.
  h.el._active = { dataset: { ref: "D5" } };
  h.el.dispatch("paste", pasteEvent("9"));
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["=$A$1+C4"]] } },
  ]);
});

check("a copied cell with NO formula falls back to its TSV value (mixed block)", () => {
  const h = mountHook();
  // B2 is a formula (=A1+1, value 5); C2 is a literal text 'hello'.
  copySelection(
    h,
    [
      selCell({ r: "2", c: "2", v: "5", f: "A1+1" }),
      selCell({ r: "2", c: "3", v: "hello" }),
    ],
    "B2",
  );
  const sig = h._formulaClip.sig; // "5\thello"
  h.el._active = { dataset: { ref: "B3" } }; // delta (0,+1)
  h.el.dispatch("paste", pasteEvent(sig));
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["=A2+1", "hello"]] } },
  ]);
});

check("REGRESSION LOCK: a FOREIGN clipboard (text ≠ our sig) pastes VALUES exactly as today", () => {
  const h = mountHook();
  // We DID copy (formula clip is armed)…
  copySelection(h, [selCell({ r: "2", c: "2", v: "5", f: "A1+1" })], "B2");
  h.el._active = { dataset: { ref: "B3" } };
  // …but the paste text is a foreign, quote-aware TSV block, NOT our signature.
  h.el.dispatch("paste", pasteEvent('a\t"x\ny"\nc\td\n'));
  // Byte-identical to the pre-feature quote-aware value path (the #882 wall).
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["a", "x\ny"], ["c", "d"]] } },
  ]);
});

check("with NO prior in-app copy, every paste is the plain value path (formula clip null)", () => {
  const h = mountHook();
  assert.equal(h._formulaClip, null);
  h.el.dispatch("paste", pasteEvent("p\tq\nr\ts"));
  assert.deepEqual(h._pushed, [
    { event: "paste", payload: { rows: [["p", "q"], ["r", "s"]] } },
  ]);
});

check("the formula paste path still honors the paste-too-large preflight", () => {
  const h = mountHook();
  h._pasteCellCap = 2; // 3 copied formula cells exceed the cap
  copySelection(
    h,
    [
      selCell({ r: "2", c: "2", v: "1", f: "A1" }),
      selCell({ r: "2", c: "3", v: "2", f: "B1" }),
      selCell({ r: "2", c: "4", v: "3", f: "C1" }),
    ],
    "B2",
  );
  const sig = h._formulaClip.sig; // "1\t2\t3"
  h.el._active = { dataset: { ref: "B5" } };
  h.el.dispatch("paste", pasteEvent(sig));
  assert.deepEqual(h._pushed, [{ event: "paste-too-large", payload: { cells: 3 } }]);
  assert.equal(h._pushed.filter((p) => p.event === "paste").length, 0);
});

check("_onCopy still writes computed VALUES to the OS clipboard AND arms the formula clip", () => {
  const h = mountHook();
  const ce = copySelection(
    h,
    [
      selCell({ r: "3", c: "2", v: "7", f: "A1*2" }),
      selCell({ r: "3", c: "3", v: "flat" }),
    ],
    "B3",
  );
  assert.equal(ce.prevented, true);
  assert.equal(ce._data["text/plain"], "7\tflat"); // OS clipboard = values (interop)
  // Origin is the selection's top-left; formulas grid parallels the TSV.
  assert.deepEqual(plain(h._formulaClip.origin), { col: 2, row: 3 });
  assert.deepEqual(plain(h._formulaClip.formulas), [["A1*2", null]]);
  assert.equal(h._formulaClip.sig, "7\tflat");
});

check("copy with an empty selection clears the formula clip (a later stray paste is safe)", () => {
  const h = mountHook();
  copySelection(h, [selCell({ r: "2", c: "2", v: "1", f: "A1" })], "B2"); // arm it
  assert.ok(h._formulaClip);
  h.el._sel = []; // selection cleared
  h.el.dispatch("copy", copyEvent()); // _selectionTsv null → returns before capture… but be explicit
  // _onCopy returns early on a null TSV, so the OLD clip could linger; verify a
  // paste of the STALE signature does NOT misfire as a formula paste (values only).
  h.el._active = { dataset: { ref: "B9" } };
  h.el.dispatch("paste", pasteEvent("zzz-not-our-sig"));
  assert.deepEqual(h._pushed, [{ event: "paste", payload: { rows: [["zzz-not-our-sig"]] } }]);
});

// ── right-click context menu (SF context-menu) ──────────────────────────────
//
// contextmenu on a cell suppresses the native browser menu, re-anchors the
// selection if the click landed outside it, then pushes cell-menu-open with the
// cursor's viewport coords. The menu's cut/copy/paste items ride the OS
// clipboard client-side (clear/insert/delete are phx-click server events).

// A contextmenu event whose target resolves to a cell td (no classList → the
// cell is NOT in the current selection, so the handler re-anchors).
function ctxEvent(ref, { clientX = 120, clientY = 80 } = {}) {
  const t = td({ ref });
  return {
    clientX,
    clientY,
    target: t,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
}

// A menu-action button (Cut/Copy/Paste); closest(".sheet-context-menu [data-menu-action]") self.
function menuActionEvent(action) {
  const btn = { dataset: { menuAction: action } };
  btn.closest = (sel) => (sel === ".sheet-context-menu [data-menu-action]" ? btn : null);
  return { target: btn };
}

check("right-click outside the selection re-anchors, then opens the menu at the cursor", () => {
  const h = mountHook();
  const e = ctxEvent("C3", { clientX: 210, clientY: 140 });
  h.el.dispatch("contextmenu", e);
  assert.equal(e.prevented, true); // native browser menu suppressed
  assert.deepEqual(h._pushed, [
    { event: "cell-click", payload: { ref: "C3", shift: false } },
    { event: "cell-menu-open", payload: { x: 210, y: 140 } },
  ]);
});

check("right-click INSIDE a multi-cell selection keeps it (no re-anchor)", () => {
  const h = mountHook();
  const t = td({ ref: "B2" });
  t.classList = { contains: (c) => c === "sheet-sel" };
  const e = { clientX: 40, clientY: 40, target: t, preventDefault() {} };
  h.el.dispatch("contextmenu", e);
  assert.deepEqual(h._pushed, [{ event: "cell-menu-open", payload: { x: 40, y: 40 } }]);
});

check("right-click riding an open cell draft carries it as commit (no silent loss)", () => {
  const h = mountHook();
  const inp = { value: "half-typed" };
  inp.closest = (sel) => (sel === ".sheet-cell-input" ? inp : null);
  h.el._input = inp;
  h.el.dispatch("contextmenu", ctxEvent("D4"));
  assert.deepEqual(h._pushed.filter((p) => p.event === "cell-click"), [
    { event: "cell-click", payload: { ref: "D4", shift: false, commit: "half-typed" } },
  ]);
});

check("right-click off any cell (closest → null) opens nothing", () => {
  const h = mountHook();
  h.el.dispatch("contextmenu", { target: { closest: () => null, matches: () => false }, preventDefault() {} });
  assert.deepEqual(h._pushed, []);
});

check("context-menu Copy writes nothing to the server, just closes the menu", () => {
  const h = mountHook();
  h.el._sel = [td({ r: "1", c: "1", v: "x" })];
  h.root.dispatch("click", menuActionEvent("copy"));
  assert.deepEqual(h._pushed, [{ event: "menu-close", payload: {} }]);
});

check("context-menu Cut clears the selection then closes the menu", () => {
  const h = mountHook();
  h.el._sel = [td({ r: "1", c: "1", v: "x" })];
  h.root.dispatch("click", menuActionEvent("cut"));
  assert.deepEqual(h._pushed, [
    { event: "clear-selection", payload: {} },
    { event: "menu-close", payload: {} },
  ]);
});

check("Escape inside the context menu pushes menu-close + preventDefault", () => {
  const h = mountHook();
  const menu = { querySelectorAll: () => [] };
  const item = { closest: (sel) => (sel === ".sheet-context-menu" ? menu : null) };
  const e = keydown("Escape");
  e.target = item;
  h.root.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(h._pushed, [{ event: "menu-close", payload: {} }]);
});

check("ArrowDown inside the context menu moves focus to the next item (roving)", () => {
  const h = mountHook();
  let focused = null;
  const items = [
    { getAttribute: () => "menuitem", focus() { focused = "a"; } },
    { getAttribute: () => "menuitem", focus() { focused = "b"; } },
  ];
  const menu = { querySelectorAll: (sel) => (sel === "[role='menuitem']" ? items : []) };
  const e = keydown("ArrowDown");
  e.target = Object.assign(items[0], { closest: (sel) => (sel === ".sheet-context-menu" ? menu : null) });
  h.root.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.equal(focused, "b"); // moved from item 0 → item 1
  assert.deepEqual(h._pushed, []); // focus move is client-only
});

check("a click NOT on a menu-action button pushes nothing (no interference)", () => {
  const h = mountHook();
  h.root.dispatch("click", { target: { closest: () => null } });
  assert.deepEqual(h._pushed, []);
});


// ── READ MODE (wave 43): the write-denied member navigates and copies ────────
//
// The Studio wrapper attaches this hook for EVERY `chrome == :studio` grid, so
// a write-DENIED member — and a write-capable member in View mode — finally has
// a producer for selection (cell-click / head-click / nav / nav-edge /
// nav-corner / select-all have no server-rendered phx-click anywhere). That
// grid stamps no `data-fns`, so the hook self-derives `_readOnly` and routes
// every push through `_push`, which drops anything outside READ_MODE_EVENTS.
//
// THE DENYLIST IS THE COMPLEMENT OF THE ALLOWLIST, NOT A HAND-PICKED SET. These
// cases dispatch the gestures at the hook and assert on the WHOLE push list, so
// a name that slipped through would show up as an extra entry regardless of
// whether anyone thought to name it. And the map is UX + honesty, not the
// security boundary: every one of these events already dies at Ops.send_ops/2's
// `write_capable: false` clause. The exception with real teeth is `edit-start`,
// which has no send_ops terminus — it broadcasts presence `%{editing: ref}`, so
// letting it through would tell every peer "this person is editing A1" while no
// editor renders.

check("read mode: the hook derives _readOnly from the absent data-fns", () => {
  const h = mountHook({ readOnly: true });
  assert.equal(h._readOnly, true);
  assert.equal(h._fns.length, 0);
  // The editable twin is the control: data-fns present → not read-only.
  assert.equal(mountHook()._readOnly, false);
});

// THE HARM, ENDED: copy works off the selection the hook can now move, and the
// gesture is 100% client-side — nothing is asked of the server at all.
check("read mode: copy yields the selection TSV and the push list stays EMPTY", () => {
  const h = mountHook({ readOnly: true });
  h.el._sel = [
    selCell({ r: "1", c: "1", v: "a" }),
    selCell({ r: "1", c: "2", v: "b" }),
    selCell({ r: "2", c: "1", v: "1" }),
    selCell({ r: "2", c: "2", v: "2" }),
  ];
  const ce = copyEvent();
  h.el.dispatch("copy", ce);
  assert.equal(ce._data["text/plain"], "a\tb\n1\t2");
  assert.equal(ce.prevented, true);
  assert.deepEqual(h._pushed, []); // ZERO pushes — the copy never touches the wire
});

// Values only, and correctly so: `data-f` is @editable-gated server-side, so a
// read-mode copy degrades to computed VALUES (Excel/Sheets interop intact) and
// arms no formula clipboard that a denied paste could ever consume.
check("read mode: copy carries values only (no data-f is stamped)", () => {
  const h = mountHook({ readOnly: true });
  h.el._sel = [selCell({ r: "2", c: "2", v: "3" })];
  const ce = copyEvent();
  h.el.dispatch("copy", ce);
  assert.equal(ce._data["text/plain"], "3");
  // (JSON round-trip: the clip is built in the vm realm, foreign prototype.)
  assert.deepEqual(JSON.parse(JSON.stringify(h._formulaClip.formulas)), [[null]]);
});

// The six the brief named, plus the ones the branch structure exposes that a
// gesture list would miss: fill (Cmd+D/R), rowcol-key (Cmd+Alt+=/-), the
// dblclick trio (edit-start / fill-extent / autofit), cell-menu-open
// (contextmenu), paste and edit-commit. Each row dispatches at a FRESH
// read-mode hook and asserts the entire push list is empty.
check("read mode: the derived denylist — no mutation gesture pushes anything", () => {
  const gestures = {
    // ── the six a naive attach would expose ──
    "edit-start (Enter)": (h) => h.el.dispatch("keydown", keydown("Enter")),
    "edit-start (F2)": (h) => h.el.dispatch("keydown", keydown("F2")),
    "edit-start (printable)": (h) => h.el.dispatch("keydown", keydown("x")),
    "edit-start (Space, non-checkbox)": (h) => {
      h.el._active = { dataset: { ref: "A1" }, classList: { contains: () => false } };
      h.el.dispatch("keydown", keydown(" "));
    },
    "cell-toggle (Space on a checkbox cell)": (h) => {
      h.el._active = { dataset: { ref: "A1" }, classList: { contains: () => true } };
      h.el.dispatch("keydown", keydown(" "));
    },
    "clear-selection (Delete)": (h) => h.el.dispatch("keydown", keydown("Delete")),
    "clear-selection (Backspace)": (h) => h.el.dispatch("keydown", keydown("Backspace")),
    undo: (h) => h.el.dispatch("keydown", keydown("z", { metaKey: true })),
    redo: (h) => h.el.dispatch("keydown", keydown("z", { metaKey: true, shiftKey: true })),
    "toggle-style (Cmd+B)": (h) => h.el.dispatch("keydown", keydown("b", { metaKey: true })),
    "toggle-style (Cmd+I)": (h) => h.el.dispatch("keydown", keydown("i", { metaKey: true })),
    // ── the ones a 27-gesture list does not name ──
    "fill (Cmd+D)": (h) => h.el.dispatch("keydown", keydown("d", { metaKey: true })),
    "fill (Cmd+R)": (h) => h.el.dispatch("keydown", keydown("r", { metaKey: true })),
    "rowcol-key (Cmd+Alt+=)": (h) =>
      h.el.dispatch("keydown", { ...keydown("="), code: "Equal", metaKey: true, altKey: true }),
    "rowcol-key (Cmd+Alt+-)": (h) =>
      h.el.dispatch("keydown", { ...keydown("-"), code: "Minus", metaKey: true, altKey: true }),
    "edit-start (double-click a cell)": (h) => h.el.dispatch("dblclick", cellEvent("A1")),
    "fill-extent (double-click the nub)": (h) =>
      h.el.dispatch("dblclick", {
        target: { closest: (s) => (s === ".sheet-fillnub" ? {} : null) },
      }),
    "autofit (double-click a resize handle)": (h) =>
      h.el.dispatch("dblclick", {
        target: {
          closest: (s) => (s === ".sheet-rsz" ? { dataset: { kind: "col", index: "2" } } : null),
        },
      }),
    paste: (h) =>
      h.el.dispatch("paste", {
        target: { matches: () => false },
        clipboardData: { getData: () => "1\t2" },
        preventDefault() {},
      }),
  };

  for (const [name, fire] of Object.entries(gestures)) {
    const h = mountHook({ readOnly: true });
    fire(h);
    assert.deepEqual(h._pushed, [], `${name} must push nothing in read mode`);
  }
});

// The control that makes the row above mean something: the IDENTICAL gestures
// on an editable hook DO push. Without this a broken dispatcher would show as a
// silent green.
check("editable twin: those same gestures DO push (the denylist is not vacuous)", () => {
  const cases = [
    ["Enter", {}, "edit-start"],
    ["Delete", {}, "clear-selection"],
    ["z", { metaKey: true }, "undo"],
    ["b", { metaKey: true }, "toggle-style"],
    ["d", { metaKey: true }, "fill"],
  ];
  for (const [key, opts, event] of cases) {
    const h = mountHook();
    h.el.dispatch("keydown", keydown(key, opts));
    assert.deepEqual(h._pushed.map((p) => p.event), [event]);
  }
  // Space on a checkbox cell, and the dblclick/paste routes.
  const hc = mountHook();
  hc.el._active = { dataset: { ref: "A1" }, classList: { contains: () => true } };
  hc.el.dispatch("keydown", keydown(" "));
  assert.deepEqual(hc._pushed, [{ event: "cell-toggle", payload: { ref: "A1" } }]);
  const hd = mountHook();
  hd.el.dispatch("dblclick", cellEvent("A1"));
  assert.deepEqual(hd._pushed, [{ event: "edit-start", payload: {} }]);
});

// The read half: navigation, whole-row/col selection, select-all and the find
// bar all still ride. These are the events the three server heads already
// accept for `chrome: :studio` — nothing new is reachable.
check("read mode: every allowed read gesture still pushes", () => {
  const cases = [
    ["nav", (h) => h.el.dispatch("keydown", keydown("ArrowDown"))],
    ["nav", (h) => h.el.dispatch("keydown", keydown("Tab"))],
    ["nav-edge", (h) => h.el.dispatch("keydown", keydown("ArrowDown", { metaKey: true }))],
    ["nav-corner", (h) => h.el.dispatch("keydown", keydown("Home", { metaKey: true }))],
    ["select-all", (h) => h.el.dispatch("keydown", keydown("a", { metaKey: true }))],
    ["find-open", (h) => h.el.dispatch("keydown", keydown("f", { metaKey: true }))],
    ["cell-click", (h) => h.el.dispatch("click", cellEvent("B2"))],
    ["cell-click", (h) => h.el.dispatch("mousedown", cellEvent("B2"))],
    ["head-click", (h) => h.el.dispatch("click", headEvent({ c: "3" }))],
  ];
  for (const [event, fire] of cases) {
    const h = mountHook({ readOnly: true });
    fire(h);
    assert.deepEqual(h._pushed.map((p) => p.event), [event]);
  }
});

// Shift+Space / Ctrl+Space ride the head-click path with the active cell's own
// index — whole-row / whole-col selection, read-safe, and still allowed.
check("read mode: Shift+Space selects the row, Ctrl+Space the column", () => {
  const h = mountHook({ readOnly: true });
  h.el._active = { dataset: { ref: "B2", r: "2", c: "2" }, classList: { contains: () => false } };
  h.el.dispatch("keydown", keydown(" ", { shiftKey: true }));
  h.el.dispatch("keydown", keydown(" ", { ctrlKey: true }));
  assert.deepEqual(h._pushed, [
    { event: "head-click", payload: { kind: "row", index: 2, shift: false } },
    { event: "head-click", payload: { kind: "col", index: 2, shift: false } },
  ]);
});

// An ALLOWED event can still carry a WRITE: the #813/#858 click-away ride
// (`commit` = the open cell draft, `bar_commit` = the dirty formula bar). A
// read-mode grid can hold neither node, but the payload is narrowed anyway —
// the selection move survives, the commit does not.
check("read mode: the write-ride keys are stripped from an allowed cell/head click", () => {
  const h = mountHook({ readOnly: true });
  h.el._input = fakeInput("=sum(");
  h.root._bar = { value: "=1+1", dataset: { raw: "" } };
  sandbox.document.activeElement = h.root._bar;
  h.el.dispatch("mousedown", cellEvent("B3"));
  assert.deepEqual(h._pushed, [{ event: "cell-click", payload: { ref: "B3", shift: false } }]);

  // A header click on its own hook (a cell mousedown arms _suppressClick, which
  // would swallow the very next click — the drag/click seal, unrelated here).
  const hh = mountHook({ readOnly: true });
  hh.el._input = fakeInput("=sum(");
  hh.root._bar = h.root._bar;
  hh.el.dispatch("click", headEvent({ c: "4" }));
  sandbox.document.activeElement = null;
  assert.deepEqual(hh._pushed, [
    { event: "head-click", payload: { kind: "col", index: 4, shift: false } },
  ]);
  // The editable twin proves the key was really on offer (a plain draft, so the
  // mousedown takes the click-away commit path rather than point-mode).
  const e = mountHook();
  e.el._input = fakeInput("42");
  e.el.dispatch("mousedown", cellEvent("B3"));
  assert.deepEqual(e._pushed, [
    { event: "cell-click", payload: { ref: "B3", shift: false, commit: "42" } },
  ]);
});

// PRESENCE IS THE TRAP. `presence-meta` is allowed (a peer should see where a
// reader's cursor is), but ONLY as active + selection — and `edit-start`, the
// one denied event with no send_ops terminus, must never reach the server to
// broadcast `%{editing: ref}` for an editor that does not render.
check("read mode: presence carries active + selection only, and never an editing flag", () => {
  const h = mountHook({ readOnly: true });
  h.el._active = { dataset: { ref: "B2", r: "2", c: "2" }, classList: { contains: () => false } };
  h.el._sel = [
    selCell({ r: "2", c: "2", v: "1" }),
    selCell({ r: "3", c: "3", v: "2" }),
  ];
  // A denied edit-start attempt (Enter) — the gesture that would have armed the
  // "editing A1" broadcast server-side.
  h.el.dispatch("keydown", keydown("Enter"));
  timers.forEach((t) => t());
  const frames = h._pushed.filter((p) => p.event === "presence-meta");
  assert.equal(frames.length, 1);
  assert.deepEqual(Object.keys(frames[0].payload).sort(), ["active", "selection"]);
  assert.deepEqual(frames[0].payload, { active: "B2", selection: "B2:C3" });
  // …and the edit-start itself never left the client.
  assert.deepEqual(h._pushed.filter((p) => p.event === "edit-start"), []);
});

// A hand-forged payload cannot smuggle the flag either: _push narrows
// presence-meta by CONSTRUCTION (it rebuilds the object), not by deletion.
check("read mode: a forged editing key on a presence frame is narrowed away", () => {
  const h = mountHook({ readOnly: true });
  assert.equal(h._push("presence-meta", { active: "A1", selection: null, editing: "A1" }), true);
  assert.deepEqual(h._pushed, [
    { event: "presence-meta", payload: { active: "A1", selection: null } },
  ]);
  // …and _push reports the drop for a denied name rather than failing silently.
  assert.equal(h._push("edit-start", {}), false);
  assert.equal(h._push("nav", { key: "ArrowDown", shift: false }), true);
});

// ══ PUBLIC READER: the client-only selection + copy layer ══════════════════
//
// window.BarkparkSheetReaderSelect — mounted as phx-hook="SheetReaderSelect"
// where `chrome == :reader` (sheet_grid.ex). Main's ruling, 2026-09-02 10:52Z:
//
//   "(b): client-only selection + copy layer in bp-sheet-grid.js for :reader —
//   paints its own class, pushes ZERO events, reads data-v already on reader
//   tds. An anonymous principal never round-trips selection and gains no
//   authority. Add one test that the reader socket receives no event during
//   select/copy. (a) rejected: it widens the server surface for a purely local
//   affordance."
//
// So the load-bearing assertion in this section is the NEGATIVE one, and it is
// pinned twice over: mountReaderHook stubs BOTH push functions to THROW (a
// push cannot merely be recorded — it fails the check where it happens), and a
// source-level check greps the shipped reader section for the identifiers with
// comments stripped. `_pushed` stays an ARRAY so the criterion's "empty push
// list" is a literal deepEqual against [].

const READER_SRC = fs.readFileSync(
  new URL("../../priv/static/assets/bp-sheet-grid.js", import.meta.url),
  "utf8",
);

function colLetters(c) {
  let s = "";
  let n = c;
  while (n > 0) {
    const rem = (n - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

// A reader <td id data-ref data-r data-c data-v> with an observable classList.
// This is the SHIPPED reader markup: sheet_grid.ex stamps id/data-ref/data-r/
// data-c/data-v on every cell in BOTH modes (data-v via Cells.data_v), which
// is exactly why a client-only layer needs no server change.
function readerTd({ id, ref, r, c, v }) {
  const classes = new Set(["sheet-cell"]);
  const cell = {
    id,
    dataset: { ref, r: String(r), c: String(c) },
    textContent: v == null ? "" : String(v),
    classes,
    classList: {
      add: (k) => classes.add(k),
      remove: (k) => classes.delete(k),
      contains: (k) => classes.has(k),
    },
    matches: () => false,
  };
  if (v != null) cell.dataset.v = String(v);
  cell.closest = (sel) => (sel === "td[data-ref]" ? cell : null);
  return cell;
}

// The .sheet-grid-wrap the reader hook mounts on. Only the surface the hook
// actually touches: listeners, classList, get/setAttribute, focus, and a
// querySelectorAll that answers "td[data-ref]".
function fakeReaderEl(cells) {
  const listeners = {};
  const classes = new Set(["sheet-grid-wrap"]);
  const attrs = {};
  const el = {
    listeners,
    attrs,
    classes,
    focused: false,
    classList: {
      add: (k) => classes.add(k),
      remove: (k) => classes.delete(k),
      contains: (k) => classes.has(k),
    },
    focus() {
      el.focused = true;
    },
    setAttribute(k, v) {
      attrs[k] = v;
    },
    removeAttribute(k) {
      delete attrs[k];
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
    },
    querySelector() {
      return null;
    },
    querySelectorAll(sel) {
      return sel === "td[data-ref]" ? cells : [];
    },
  };
  return el;
}

// Mount the reader hook over a rows×cols grid of value cells. `values` keys are
// "c,r"; anything unnamed gets its own A1-style ref as the value so a copied
// block is self-describing.
//
// THE PUSH STUBS THROW. "Zero events" must not depend on a list nobody reads:
// if the hook ever calls pushEvent/pushEventTo, the check that drove the
// gesture fails at that call site with the payload in the message.
function mountReaderHook({ rows = 3, cols = 3, values = {} } = {}) {
  sandbox.window._listeners = {};
  const cells = [];
  for (let r = 1; r <= rows; r++) {
    for (let c = 1; c <= cols; c++) {
      const ref = colLetters(c) + r;
      const v = Object.prototype.hasOwnProperty.call(values, `${c},${r}`)
        ? values[`${c},${r}`]
        : ref;
      cells.push(readerTd({ id: `sheet-reader-s-view-cell-${c}-${r}`, ref, r, c, v }));
    }
  }
  const hook = Object.create(sandbox.window.BarkparkSheetReaderSelect);
  hook.el = fakeReaderEl(cells);
  hook.cells = cells;
  hook._pushed = [];
  const forbid = (...args) => {
    hook._pushed.push(args);
    throw new Error(`the reader hook pushed a server event: ${JSON.stringify(args)}`);
  };
  hook.pushEvent = forbid;
  hook.pushEventTo = forbid;
  hook.mounted();
  return hook;
}

// mousedown / mouseover on a cell.
function readerMouse(hook, c, r, opts = {}) {
  const td = hook.cells.find((x) => x.dataset.c === String(c) && x.dataset.r === String(r));
  return { button: 0, shiftKey: false, ...opts, target: td, preventDefault() {} };
}

function readerKey(key, opts = {}) {
  return {
    key,
    shiftKey: false,
    metaKey: false,
    ctrlKey: false,
    ...opts,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
    target: { matches: () => false, closest: () => null },
  };
}

// A clipboard `copy` event; `written` collects what the hook put on it.
function readerCopyEvent({ input = false } = {}) {
  const written = {};
  return {
    written,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
    target: { matches: (sel) => input && /input|textarea/.test(sel) },
    clipboardData: {
      setData(kind, text) {
        written[kind] = text;
      },
    },
  };
}

function readerSelectedRefs(hook) {
  return hook.cells.filter((td) => td.classList.contains("sheet-rsel")).map((td) => td.dataset.ref);
}

check("reader: a click selects one cell, paints sheet-rsel and never sheet-sel", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 2, 2));
  assert.deepEqual(readerSelectedRefs(h), ["B2"]);
  // The Studio class must never appear — the grid harness pins td.sheet-sel.
  assert.equal(h.cells.some((td) => td.classList.contains("sheet-sel")), false);
  assert.deepEqual(h._pushed, []);
});

check("reader: a drag paints the whole rect and the copy is the TSV block", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  h.el.dispatch("mouseover", readerMouse(h, 2, 2));
  assert.deepEqual(readerSelectedRefs(h), ["A1", "B1", "A2", "B2"]);
  const e = readerCopyEvent();
  h.el.dispatch("copy", e);
  assert.equal(e.prevented, true);
  assert.equal(e.written["text/plain"], "A1\tB1\nA2\tB2");
  assert.deepEqual(h._pushed, []);
});

check("reader: a drag that ends off-grid stops on the window mouseup", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  dispatchWindow("mouseup", {});
  // Moving over another cell after the release must NOT keep extending.
  h.el.dispatch("mouseover", readerMouse(h, 3, 3));
  assert.deepEqual(readerSelectedRefs(h), ["A1"]);
});

check("reader: shift+arrow extends from the anchor, plain arrow re-anchors", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  h.el.dispatch("keydown", readerKey("ArrowRight", { shiftKey: true }));
  h.el.dispatch("keydown", readerKey("ArrowDown", { shiftKey: true }));
  assert.deepEqual(readerSelectedRefs(h), ["A1", "B1", "A2", "B2"]);
  // A plain arrow collapses the range onto the new cell.
  h.el.dispatch("keydown", readerKey("ArrowRight"));
  assert.deepEqual(readerSelectedRefs(h), ["C2"]);
  assert.deepEqual(h._pushed, []);
});

check("reader: shift+click extends from the existing anchor", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  h.el.dispatch("mousedown", readerMouse(h, 3, 2, { shiftKey: true }));
  assert.deepEqual(readerSelectedRefs(h), ["A1", "B1", "C1", "A2", "B2", "C2"]);
});

check("reader: ctrl/cmd+A selects the whole RENDERED grid (this row page)", () => {
  const h = mountReaderHook({ rows: 2, cols: 2 });
  const e = readerKey("a", { metaKey: true });
  h.el.dispatch("keydown", e);
  assert.equal(e.prevented, true);
  assert.deepEqual(readerSelectedRefs(h), ["A1", "B1", "A2", "B2"]);
  const c = readerCopyEvent();
  h.el.dispatch("copy", c);
  assert.equal(c.written["text/plain"], "A1\tB1\nA2\tB2");
  assert.deepEqual(h._pushed, []);
});

check("reader: arrows clamp at the rendered bounds instead of falling off", () => {
  const h = mountReaderHook({ rows: 2, cols: 2 });
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  h.el.dispatch("keydown", readerKey("ArrowUp"));
  h.el.dispatch("keydown", readerKey("ArrowLeft"));
  assert.deepEqual(readerSelectedRefs(h), ["A1"]);
  h.el.dispatch("keydown", readerKey("End"));
  h.el.dispatch("keydown", readerKey("PageDown"));
  assert.deepEqual(readerSelectedRefs(h), ["B2"]);
});

check("reader: copy quotes a tab / newline / quote — the SAME kernel as Studio", () => {
  const h = mountReaderHook({
    rows: 1,
    cols: 3,
    values: { "1,1": 'say "hi"', "2,1": "a\tb", "3,1": "x\ny" },
  });
  h.el.dispatch("keydown", readerKey("a", { ctrlKey: true }));
  const e = readerCopyEvent();
  h.el.dispatch("copy", e);
  const tsv = e.written["text/plain"];
  assert.equal(tsv, '"say ""hi"""\t"a\tb"\t"x\ny"');
  // Reused, not forked: the Studio hook's own encoder produces the same bytes,
  // and its parser round-trips them back to the three cells.
  assert.equal(sandbox.window.BarkparkSheetGrid._tsvEncode([['say "hi"', "a\tb", "x\ny"]]), tsv);
  // (JSON round-trip: the parser returns vm-realm arrays, whose foreign
  // prototype deepEqual/strict rejects — the same normalization mountHook does.)
  assert.deepEqual(JSON.parse(JSON.stringify(sandbox.window.BarkparkSheetGrid._tsvParse(tsv))), [
    ['say "hi"', "a\tb", "x\ny"],
  ]);
  assert.deepEqual(h._pushed, []);
});

check("reader: an empty-valued cell copies as an empty field, not as its text", () => {
  const h = mountReaderHook({ rows: 1, cols: 2, values: { "2,1": null } });
  h.el.dispatch("keydown", readerKey("a", { metaKey: true }));
  const e = readerCopyEvent();
  h.el.dispatch("copy", e);
  assert.equal(e.written["text/plain"], "A1\t");
});

check("reader: Escape clears the selection and copy goes back to the browser", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  h.el.dispatch("keydown", readerKey("Escape"));
  assert.deepEqual(readerSelectedRefs(h), []);
  const e = readerCopyEvent();
  h.el.dispatch("copy", e);
  assert.equal(e.prevented, false);
  assert.deepEqual(e.written, {});
});

check("reader: a copy raised from a text input is left to the browser", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  const e = readerCopyEvent({ input: true });
  h.el.dispatch("copy", e);
  assert.equal(e.prevented, false);
  assert.deepEqual(e.written, {});
});

check("reader: aria-activedescendant follows the active cell, and clears with it", () => {
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 2, 3));
  assert.equal(h.el.attrs["aria-activedescendant"], "sheet-reader-s-view-cell-2-3");
  h.el.dispatch("keydown", readerKey("ArrowUp"));
  assert.equal(h.el.attrs["aria-activedescendant"], "sheet-reader-s-view-cell-2-2");
  h.el.dispatch("keydown", readerKey("Escape"));
  assert.equal("aria-activedescendant" in h.el.attrs, false);
});

check("reader: mount marks the grid sheet-rsel-on; destroyed() unbinds everything", () => {
  const h = mountReaderHook();
  assert.equal(h.el.classList.contains("sheet-rsel-on"), true);
  h.destroyed();
  assert.deepEqual(
    Object.keys(h.el.listeners).filter((k) => h.el.listeners[k].length),
    [],
  );
  assert.deepEqual(
    Object.keys(sandbox.window._listeners).filter((k) => sandbox.window._listeners[k].length),
    [],
  );
});

// THE RULING'S OWN CHECK, at the source level. The gesture checks above prove
// no push HAPPENED; this proves none CAN — the shipped reader section contains
// no pushEvent / pushEventTo identifier for a later edit to reach for. Comments
// are stripped first (the ruling is quoted verbatim in them, and it names both).
check("reader: the shipped hook holds no pushEvent/pushEventTo code path at all", () => {
  const start = READER_SRC.indexOf("window.BarkparkSheetReaderSelect = {");
  assert.ok(start > 0, "the reader hook is missing from the shipped file");
  const code = READER_SRC.slice(start)
    .split("\n")
    .filter((line) => !/^\s*(\/\/|\/\*|\*)/.test(line))
    .join("\n");
  assert.ok(code.length > 500, "the reader section stripped to nothing — check the comment filter");
  assert.equal(/pushEvent/.test(code), false, "the reader hook must never push a server event");
  assert.equal(/pushEventTo/.test(code), false);
  // …and the empty push list the criterion asks to quote, after a full
  // select-then-copy gesture.
  const h = mountReaderHook();
  h.el.dispatch("mousedown", readerMouse(h, 1, 1));
  h.el.dispatch("mouseover", readerMouse(h, 2, 2));
  h.el.dispatch("keydown", readerKey("ArrowDown", { shiftKey: true }));
  h.el.dispatch("copy", readerCopyEvent());
  assert.deepEqual(h._pushed, []);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall bp-sheet-grid hook checks PASS");
