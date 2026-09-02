// __palette.test.mjs — pure-Node unit harness for the Studio chat's keyboard
// navigation (api/priv/static/assets/bp-chat-palette.js).
//
// Same shape as api/assets/chat-turn-clock/__turn_clock.test.mjs: the shipped
// file is a browser IIFE assigning `window.BarkparkChatKeys` /
// `window.BarkparkChatPalette`, so we run the COMMITTED artifact verbatim in a
// node:vm sandbox with a faked `window` / `document`, then drive the hooks
// against fake elements. Zero dependencies, no lockfile — a regression in the
// shipped file reds this run.
//
// Run: node --test __palette.test.mjs   (or: npm test)

import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";

// ── vm sandbox: a fake document that records its keydown listeners ─────────

const docListeners = [];

const sandbox = {
  window: {},
  document: {
    addEventListener(type, fn) {
      if (type === "keydown") docListeners.push(fn);
    },
    removeEventListener(type, fn) {
      const i = docListeners.indexOf(fn);
      if (type === "keydown" && i !== -1) docListeners.splice(i, 1);
    }
  },
  Array,
  String,
  parseInt
};
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(new URL("../../priv/static/assets/bp-chat-palette.js", import.meta.url), "utf8"),
  sandbox
);

const Keys = sandbox.window.BarkparkChatKeys;
const Palette = sandbox.window.BarkparkChatPalette;

assert.ok(Keys, "bp-chat-palette.js must define window.BarkparkChatKeys");
assert.ok(Palette, "bp-chat-palette.js must define window.BarkparkChatPalette");

// The hooks build their return values INSIDE the vm realm, so those objects do
// not share this realm's Object.prototype and a strict deep-equal would fail on
// identity alone. Normalize through JSON before comparing — the values under
// test are plain data.
const plain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)));
const deq = (actual, expected, msg) => assert.deepEqual(plain(actual), expected, msg);

// Mount a hook the way LiveView does: it copies every callback key onto the
// ViewHook instance, so helper methods are reachable as `this._foo`.
function mount(hook, element) {
  const inst = Object.create(hook);
  inst.el = element;
  inst.pushed = [];
  inst.pushEvent = (event, payload) => inst.pushed.push([event, payload]);
  inst.mounted();
  return inst;
}

// A key event with only the surface the filter reads.
function key(k, opts = {}) {
  const e = {
    key: k,
    metaKey: !!opts.meta,
    ctrlKey: !!opts.ctrl,
    altKey: !!opts.alt,
    shiftKey: !!opts.shift,
    target: opts.target || { tagName: "BODY" },
    prevented: false,
    stopped: false,
    preventDefault() {
      this.prevented = true;
    },
    stopPropagation() {
      this.stopped = true;
    }
  };
  return e;
}

const IN_INPUT = { tagName: "INPUT" };
const IN_TEXTAREA = { tagName: "TEXTAREA" };
const IN_CONTENTEDITABLE = { tagName: "DIV", isContentEditable: true };

// ── the key filter: 1-9 mapping ───────────────────────────────────────────

test("Cmd/Ctrl+1..9 maps to the Nth session; both modifiers, either case", () => {
  for (let n = 1; n <= 9; n++) {
    deq(Keys._classify(key(String(n), { meta: true })), { kind: "jump", n });
    deq(Keys._classify(key(String(n), { ctrl: true })), { kind: "jump", n });
  }
});

test("0 is not a jump — the row names 1..9 and nothing else", () => {
  assert.equal(Keys._classify(key("0", { meta: true })), null);
});

test("a bare digit with no modifier is the page's, not ours", () => {
  assert.equal(Keys._classify(key("3")), null);
  assert.equal(Keys._classify(key("k")), null);
});

test("Alt/Shift variants belong to the browser and the OS", () => {
  assert.equal(Keys._classify(key("3", { meta: true, alt: true })), null);
  assert.equal(Keys._classify(key("k", { meta: true, shift: true })), null);
});

// ── the key filter: K opens the palette ───────────────────────────────────

test("Cmd/Ctrl+K opens the palette, upper or lower case", () => {
  deq(Keys._classify(key("k", { meta: true })), { kind: "palette" });
  deq(Keys._classify(key("K", { ctrl: true })), { kind: "palette" });
});

test("a key we do not own is left entirely alone", () => {
  assert.equal(Keys._classify(key("j", { meta: true })), null);
  assert.equal(Keys._classify(key("Escape", { meta: true })), null);
  assert.equal(Keys._classify(key("Enter", { ctrl: true })), null);
  assert.equal(Keys._classify(null), null);
});

// ── THE MUTATION TARGET: the focus-in-input guard ─────────────────────────

test("the focus-in-input guard: a chord typed in an input/textarea/contenteditable is ignored", () => {
  // Every chord the filter otherwise owns, typed into each editable surface.
  for (const target of [IN_INPUT, IN_TEXTAREA, IN_CONTENTEDITABLE]) {
    assert.equal(
      Keys._classify(key("k", { meta: true, target })),
      null,
      "Cmd+K must not be stolen from a field the user is typing in"
    );
    assert.equal(
      Keys._classify(key("1", { ctrl: true, target })),
      null,
      "Ctrl+1 must not be stolen from a field the user is typing in"
    );
    assert.equal(Keys._classify(key("9", { meta: true, target })), null);
  }

  // …and the same chord OUTSIDE an editable surface still lands, so the guard
  // is proven to be the reason above, not a dead filter.
  deq(Keys._classify(key("k", { meta: true })), { kind: "palette" });
  deq(Keys._classify(key("1", { ctrl: true })), { kind: "jump", n: 1 });
});

test("the focus-in-input guard: the LIVE document listener ignores it too", () => {
  docListeners.length = 0;
  const inst = mount(Keys, { tagName: "DIV" });
  assert.equal(docListeners.length, 1, "ChatKeys arms exactly one document keydown listener");
  const fire = docListeners[0];

  fire(key("2", { meta: true, target: IN_INPUT }));
  fire(key("k", { meta: true, target: IN_TEXTAREA }));
  fire(key("5", { ctrl: true, target: IN_CONTENTEDITABLE }));
  deq(inst.pushed, [], "no server event from a key typed into a field");

  const live = key("2", { meta: true });
  fire(live);
  deq(inst.pushed, [["chat-jump", { n: 2 }]]);
  assert.equal(live.prevented, true, "a chord we claim never also reaches the browser");

  fire(key("k", { meta: true }));
  deq(inst.pushed[1], ["chat-palette-open", {}]);

  inst.destroyed();
  assert.equal(docListeners.length, 0, "destroyed() removes the listener");
});

// ── the palette: fuzzy filter + Enter + Escape ownership ──────────────────

test("fuzzy match is a case-insensitive subsequence; blank matches everything", () => {
  assert.equal(Palette._match("", "anything"), true);
  assert.equal(Palette._match("sw", "Studio wiring"), true);
  assert.equal(Palette._match("chatp", "chat palette"), true);
  assert.equal(Palette._match("CH P", "chat palette"), true, "whitespace in the query is ignored");
  assert.equal(Palette._match("zz", "chat palette"), false);
  assert.equal(Palette._match("etap", "chat palette"), false, "order matters — not a bag of letters");
});

// A fake palette DOM: the container, its input, and the server-rendered rows.
function paletteEl(titles) {
  const rows = titles.map((t, i) => ({
    id: "chat-palette-opt-" + i,
    hidden: false,
    _attrs: { "data-palette-id": "sess-" + i, "data-palette-title": t },
    getAttribute(k) {
      return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null;
    },
    setAttribute(k, v) {
      this._attrs[k] = v;
    },
    removeAttribute(k) {
      delete this._attrs[k];
    }
  }));

  const input = {
    tagName: "INPUT",
    value: "",
    focused: false,
    _handlers: {},
    focus() {
      this.focused = true;
    },
    addEventListener(type, fn) {
      this._handlers[type] = fn;
    },
    removeEventListener(type) {
      delete this._handlers[type];
    },
    setAttribute() {},
    getAttribute() {
      return null;
    }
  };

  // The container the hook mounts on: it owns the keydown listener (so a key
  // pressed on ANY element inside the palette passes through it), the input
  // owns `input`.
  return {
    rows,
    input,
    _handlers: {},
    addEventListener(type, fn) {
      this._handlers[type] = fn;
    },
    removeEventListener(type) {
      delete this._handlers[type];
    },
    querySelector(sel) {
      return sel === "#chat-palette-input" ? input : null;
    },
    querySelectorAll() {
      return rows;
    }
  };
}

test("typing filters the server-rendered rows in the browser (no round trip)", () => {
  const el = paletteEl(["Studio wiring", "Chat palette", "Sheet grid"]);
  const inst = mount(Palette, el);

  assert.equal(el.input.focused, true, "the palette opens with its input focused");
  deq(el.rows.map((r) => r.hidden), [false, false, false]);
  deq(inst.pushed, [], "filtering costs the server nothing");

  el.input.value = "sw";
  el.input._handlers.input();
  deq(el.rows.map((r) => r.hidden), [false, true, true]);

  el.input.value = "chp";
  el.input._handlers.input();
  deq(el.rows.map((r) => r.hidden), [true, false, true]);
});

test("Arrow keys move the highlight over the VISIBLE rows; Enter activates that one", () => {
  const el = paletteEl(["Studio wiring", "Chat palette", "Sheet grid"]);
  const inst = mount(Palette, el);
  const kd = el._handlers.keydown;

  kd(key("ArrowDown"));
  kd(key("Enter"));
  deq(inst.pushed, [["chat-palette-activate", { id: "sess-1" }]]);

  // Filter down to one row: the highlight resets to it, Enter takes it.
  // ("sg" would ALSO match "Studio wirinG" — the fuzzy match is a subsequence,
  // not a prefix, so the single-row query has to be genuinely unique.)
  el.input.value = "shg";
  el.input._handlers.input();
  kd(key("Enter"));
  deq(inst.pushed[1], ["chat-palette-activate", { id: "sess-2" }]);

  // A query that matches nothing activates nothing rather than guessing.
  el.input.value = "zzzz";
  el.input._handlers.input();
  kd(key("Enter"));
  assert.equal(inst.pushed.length, 2);
});

test("Escape closes the palette and NEVER reaches the document interrupt listener", () => {
  const el = paletteEl(["Studio wiring", "Chat palette"]);
  const inst = mount(Palette, el);

  // Model the real page: bp-chat-composer.js's global Esc interrupt is a
  // document-level BUBBLE listener. An event whose propagation was stopped on
  // the input never reaches it.
  const interrupts = [];
  const documentInterruptListener = (e) => {
    if (e.key === "Escape") interrupts.push("stop_turn");
  };

  const e = key("Escape");
  el._handlers.keydown(e);
  if (!e.stopped) documentInterruptListener(e);

  deq(inst.pushed, [["chat-palette-close", {}]], "Escape closes the palette");
  assert.equal(e.stopped, true, "the palette claims Escape with stopPropagation");
  deq(interrupts, [], "the running turn is NOT interrupted by closing the palette");

  // …and with the palette gone, the same Escape reaches the interrupt exactly
  // as before — the guard is scoped to the palette, not a global mute.
  const e2 = key("Escape");
  if (!e2.stopped) documentInterruptListener(e2);
  deq(interrupts, ["stop_turn"]);
});
