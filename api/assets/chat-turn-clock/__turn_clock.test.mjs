// __turn_clock.test.mjs — pure-Node unit harness for the Studio chat's turn
// clock hooks (api/priv/static/assets/bp-chat-turn-clock.js).
//
// Same shape as api/assets/sheet-grid/__hook.test.mjs: the file is a browser
// IIFE assigning `window.BarkparkChatElapsed` / `window.BarkparkChatSpinWord`,
// so we run the COMMITTED artifact verbatim inside a node:vm sandbox with a
// faked `window` / `Date.now` / `setInterval`, then drive the hooks against
// fake elements. Zero dependencies, no lockfile — a regression in the shipped
// file reds this run.
//
// Run: node --test __turn_clock.test.mjs   (or: npm test)

import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";

// ── vm sandbox: controllable clock + controllable intervals ────────────────

let NOW = 1_700_000_000_000;
const intervals = [];

const sandbox = {
  window: {},
  Date: { now: () => NOW },
  setInterval(fn, ms) {
    intervals.push({ fn, ms });
    return intervals.length;
  },
  clearInterval(id) {
    if (id >= 1 && id <= intervals.length) intervals[id - 1].cleared = true;
  },
  JSON,
  Math,
  isFinite,
  parseInt
};
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(new URL("../../priv/static/assets/bp-chat-turn-clock.js", import.meta.url), "utf8"),
  sandbox
);

const Elapsed = sandbox.window.BarkparkChatElapsed;
const SpinWord = sandbox.window.BarkparkChatSpinWord;

assert.ok(Elapsed, "bp-chat-turn-clock.js must define window.BarkparkChatElapsed");
assert.ok(SpinWord, "bp-chat-turn-clock.js must define window.BarkparkChatSpinWord");

// A fake element: just the attribute bag + textContent the hooks touch.
function el(attrs) {
  return {
    _attrs: attrs || {},
    textContent: "",
    getAttribute(k) {
      return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null;
    },
    setAttribute(k, v) {
      this._attrs[k] = v;
    }
  };
}

// Mount a hook on a fake element the way LiveView would.
function mount(hook, element) {
  const inst = Object.create(hook);
  inst.el = element;
  inst.mounted();
  return inst;
}

// Fire every armed (uncleared) interval once.
function flush() {
  for (const t of intervals) if (!t.cleared) t.fn();
}

// ── the elapsed arithmetic (ms → the label the browser writes) ─────────────

test("ms → label: under a second reads as nothing at all", () => {
  assert.equal(Elapsed._fmt(0), "");
  assert.equal(Elapsed._fmt(999), "");
});

test("ms → label: seconds, then m + zero-padded s, then h + zero-padded m", () => {
  assert.equal(Elapsed._fmt(1_000), "1s");
  assert.equal(Elapsed._fmt(12_400), "12s");
  assert.equal(Elapsed._fmt(59_999), "59s");
  assert.equal(Elapsed._fmt(60_000), "1m 00s");
  // the shape the task names: 65 s reads "1m 05s", never "1m 5s"
  assert.equal(Elapsed._fmt(65_000), "1m 05s");
  assert.equal(Elapsed._fmt(11 * 60_000 + 7_000), "11m 07s");
  assert.equal(Elapsed._fmt(3_600_000), "1h 00m");
  assert.equal(Elapsed._fmt(3_600_000 + 2 * 60_000 + 3_000), "1h 02m");
});

test("ms → label: a nonsense value never renders a nonsense count", () => {
  assert.equal(Elapsed._fmt(NaN), "");
  assert.equal(Elapsed._fmt(undefined), "");
});

// ── ChatElapsed: seeds from the server stamp, ticks, clears ────────────────

test("mounted() paints from the SERVER stamp and arms a 1 s interval", () => {
  intervals.length = 0;
  NOW = 1_700_000_000_000;
  const e = el({ "data-started-at": String(NOW - 65_000) });
  const inst = mount(Elapsed, e);

  assert.equal(e.textContent, "1m 05s", "the first paint is immediate, not a second late");
  assert.equal(intervals.length, 1);
  assert.equal(intervals[0].ms, 1000);

  NOW += 1_000;
  flush();
  assert.equal(e.textContent, "1m 06s");

  inst.destroyed();
  assert.equal(intervals[0].cleared, true, "destroyed() must clear the interval");
});

test("no server stamp = no label and no timer (a turn we cannot date stays silent)", () => {
  intervals.length = 0;
  const e = el({});
  mount(Elapsed, e);
  assert.equal(e.textContent, "");
  assert.equal(intervals.length, 0);
});

test("a clock skewed BEHIND the server never runs backwards", () => {
  intervals.length = 0;
  NOW = 1_700_000_000_000;
  const e = el({ "data-started-at": String(NOW + 5_000) });
  mount(Elapsed, e);
  assert.equal(e.textContent, "", "clamped at 0 — a negative elapsed is not a label");
});

test("a re-seed (patch / remount / reconnect) re-reads the server value and re-arms once", () => {
  intervals.length = 0;
  NOW = 1_700_000_000_000;
  const e = el({ "data-started-at": String(NOW - 4_000) });
  const inst = mount(Elapsed, e);
  assert.equal(e.textContent, "4s");

  // a NEW turn's boundary arrives on the same element
  e.setAttribute("data-started-at", String(NOW - 1_000));
  inst.updated();
  assert.equal(e.textContent, "1s", "the label follows the server, never its own count");
  assert.equal(intervals[0].cleared, true, "the stale interval is cleared, never doubled");

  // the reconnect path re-seeds the same way
  e.setAttribute("data-started-at", String(NOW - 61_000));
  inst.reconnected();
  assert.equal(e.textContent, "1m 01s");

  const live = intervals.filter((t) => !t.cleared);
  assert.equal(live.length, 1, "exactly one live interval after three seeds");
  inst.destroyed();
});

// ── ChatSpinWord: the park never stands still, client-side ─────────────────

test("rotation swaps the word for a DIFFERENT one, keeping the ellipsis", () => {
  intervals.length = 0;
  const words = ["Joymaxxing", "Waggeling", "Aurafarming"];
  const e = el({ "data-words": JSON.stringify(words), "data-rotate-ms": "7000" });
  e.textContent = "Joymaxxing…";
  const inst = mount(SpinWord, e);

  assert.equal(intervals.length, 1);
  assert.equal(intervals[0].ms, 7000, "the dwell comes from the server, not a JS constant");

  for (let i = 0; i < 20; i++) {
    const before = e.textContent;
    flush();
    assert.notEqual(e.textContent, before, "a rotation the eye can see, every time");
    assert.match(e.textContent, /…$/);
    assert.ok(words.indexOf(e.textContent.replace("…", "")) !== -1);
  }

  inst.destroyed();
  assert.equal(intervals[0].cleared, true);
});

test("a one-word or malformed vocabulary arms NO timer", () => {
  intervals.length = 0;
  mount(SpinWord, el({ "data-words": '["Joymaxxing"]', "data-rotate-ms": "7000" }));
  mount(SpinWord, el({ "data-words": "not json", "data-rotate-ms": "7000" }));
  mount(SpinWord, el({ "data-rotate-ms": "7000" }));
  mount(SpinWord, el({ "data-words": '["a","b"]' }));
  assert.equal(intervals.length, 0);
});
