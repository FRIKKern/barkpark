// font-pin.test.mjs — the capture-then-report race, and its bounded retry,
// proven without Chrome.
//
// WHAT THIS FILE IS FOR
// ─────────────────────
// Wave 66 closed the pin's capture-then-report race and proved it with a
// throwaway harness — a server delaying /app.css 600ms plus a pin fired at the
// navigation-commit instant, refusing 4/4 pre-fix and passing 4/4 post-fix.
// That harness was a scratch file and is gone. Without this test the fix is
// guarded by nothing: delete the retry loop from font-pin.mjs tomorrow and
// every other committed check still passes byte-identically, because the race
// only appears under a delayed stylesheet that no instrument creates. Three
// instruments (overflow-guard.mjs, breakpoint-sweep.mjs, modal-oracle.mjs)
// would go back to refusing a healthy page roughly one run in eight, on every
// cloud PR, including PRs with no console surface at all.
//
// HOW IT RUNS THE REAL PIN, NOT A PARAPHRASE OF IT
// ───────────────────────────────────────────────
// `FONT_PIN_JS` is a source STRING the three callers hand to Runtime.evaluate,
// so it is testable exactly as shipped: `new Function("document", "return " +
// FONT_PIN_JS)` compiles the shipped characters and the only free name it
// needs is `document`. Nothing in font-pin.mjs is modified, injected or
// wrapped for this test — no seam, no test-only export, no env override, so
// the three callers get byte-identical behaviour and `git diff` over
// font-pin.mjs is empty. What is stubbed is the PAGE.
//
// The stub is a FontFaceSet whose stylesheet has not arrived yet. That is the
// whole defect: one pass of the pin reads `document.fonts` twice, either side
// of two awaits, and if the snapshot lands before the stylesheet is parsed the
// snapshot is EMPTY while `size` afterwards reads 4. `document.fonts.ready` is
// modelled per spec — it settles when font loads AND layout have settled, so
// it does NOT resolve early on a document still parsing its stylesheet, which
// is precisely why the awaits span the arrival and the recorded CI line reads
// `declared 0` beside `size 4`.
//
// THE MUTATION LEG IS INSIDE THE FILE (charter: a test with no failing
// direction is not a test). Two mutations are applied to a COPY of the shipped
// string, each asserting its anchor occurs EXACTLY ONCE and that the result
// differs — a mutation that silently did not apply is a vacuous green:
//
//   1. `RETRY_LIMIT = 20` -> `0`   = the pre-fix pin. The race stub then
//      reproduces the recorded CI refusal character for character.
//   2. the guard widened from `!pass.ok && pass.captured === 0` to `!pass.ok`
//      alone = the tempting wrong fix. It stops being a statement about the
//      pin's own timing and becomes retry-until-green over the page's fonts.
//
// If either anchor ever disappears from font-pin.mjs, those tests red on the
// anchor assertion with the reason spelled out — so the guard cannot be
// deleted quietly.

import test from "node:test";
import assert from "node:assert/strict";

import { EXPECTED_FACES, FONT_PIN_JS, fontPinRefusal } from "./font-pin.mjs";

// ── the page stub ────────────────────────────────────────────────────────────

// What ships in cloud/priv/static/fonts/: one variable Inter and three separate
// IBM Plex Mono weights. Asserted against EXPECTED_FACES below so this fixture
// cannot drift into satisfying a floor it no longer matches.
const DISK_FACES = [
  { family: "Inter", weight: "100 900" },
  { family: "IBM Plex Mono", weight: "400" },
  { family: "IBM Plex Mono", weight: "500" },
  { family: "IBM Plex Mono", weight: "600" },
];

// The recorded CI refusal, quoted from font-pin.mjs's own comment. `declared 0`
// beside `size 4` is the signature of the split this test exists to keep shut.
const RECORDED_DETAIL =
  "Inter [declared 0/1 face(s): none] · IBM Plex Mono [declared 0/3 face(s): none]";
const RECORDED_STATE = "document.fonts.status=loaded size=4";

const FACE_LOAD_MS = 5;

class StubFace {
  // `failures` is how many load attempts reject before one succeeds. 0 = a
  // healthy woff2; Infinity = the file is off disk and no amount of asking
  // brings it back.
  constructor(spec, set) {
    this.family = spec.family;
    this.weight = spec.weight;
    this.style = "normal";
    this.status = "unloaded";
    this._set = set;
    this._failures = spec.failures === undefined ? 0 : spec.failures;
    this._attempts = 0;
  }

  load() {
    this._attempts += 1;
    const willFail = this._attempts <= this._failures;
    this.status = "loading";
    this._set._pending += 1;
    return new Promise((resolve, reject) => {
      setTimeout(() => {
        this._set._pending -= 1;
        if (willFail) {
          this.status = "error";
          this._set._settle();
          reject(new Error(`woff2 unavailable: ${this.family} ${this.weight}`));
        } else {
          this.status = "loaded";
          this._set._settle();
          resolve(this);
        }
      }, FACE_LOAD_MS);
    });
  }
}

function coversWeight(faceWeight, wanted) {
  const nums = String(faceWeight).match(/-?\d+(\.\d+)?/g) || ["400"];
  const lo = Number(nums[0]);
  const hi = nums.length > 1 ? Number(nums[1]) : lo;
  return wanted >= lo && wanted <= hi;
}

class StubFontFaceSet {
  constructor() {
    this._faces = [];
    this._arrived = false;
    this._pending = 0;
    this._waiters = [];
  }

  // The stylesheet is parsed: the @font-face block registers its faces and the
  // PAGE starts loading them of its own accord (this is what makes `size` read
  // 4 and `status` read "loaded" while the pin's own snapshot holds nothing).
  arrive(specs) {
    if (this._arrived) return;
    this._arrived = true;
    for (const spec of specs) {
      const face = new StubFace(spec, this);
      this._faces.push(face);
      face.load().catch(() => {});
    }
    this._settle();
  }

  _settle() {
    if (!this._arrived || this._pending > 0) return;
    const waiters = this._waiters;
    this._waiters = [];
    for (const w of waiters) w(this);
  }

  // Per spec, `ready` settles when font loads AND layout operations have
  // settled — NOT immediately on an empty set of a document still parsing.
  get ready() {
    if (this._arrived && this._pending === 0) return Promise.resolve(this);
    return new Promise((resolve) => this._waiters.push(resolve));
  }

  get size() {
    return this._faces.length;
  }

  get status() {
    return this._arrived && this._pending === 0 ? "loaded" : "loading";
  }

  [Symbol.iterator]() {
    return this._faces.slice()[Symbol.iterator]();
  }

  check(spec) {
    const m = String(spec).match(/^(-?\d+(?:\.\d+)?)\s+16px\s+"(.+)"$/);
    if (!m) return false;
    const wanted = Number(m[1]);
    const family = m[2];
    return this._faces.some(
      (f) => f.family === family && f.status === "loaded" && coversWeight(f.weight, wanted),
    );
  }
}

// A page whose stylesheet lands `delayMs` after the pin is fired. delayMs 0 =
// the stylesheet is already parsed at navigation; `never: true` = a page with
// no @font-face block at all.
function stubDocument({ delayMs = 0, faces = DISK_FACES, never = false } = {}) {
  const fonts = new StubFontFaceSet();
  if (never) fonts.arrive([]);
  else if (delayMs === 0) fonts.arrive(faces);
  else setTimeout(() => fonts.arrive(faces), delayMs);
  return { fonts };
}

// ── running the shipped string, and mutating a copy of it ────────────────────

function runPin(src, doc) {
  // eslint-disable-next-line no-new-func
  const compiled = new Function("document", `return ${src};`);
  return compiled(doc);
}

// A mutation that did not apply is not a catch: the anchor must appear exactly
// once and the result must actually differ.
function mutate(src, anchor, replacement, why) {
  const hits = src.split(anchor).length - 1;
  assert.equal(
    hits,
    1,
    `the mutation anchor must appear EXACTLY once in FONT_PIN_JS (found ${hits}). ` +
      `Anchor: ${JSON.stringify(anchor)}. ${why}`,
  );
  const out = src.split(anchor).join(replacement);
  assert.notEqual(out, src, "the mutation produced no diff — the leg would be vacuous");
  return out;
}

// Mutation 1: the pin BEFORE wave 66 — one pass, no retry.
const PRE_FIX_PIN = () =>
  mutate(
    FONT_PIN_JS,
    "var RETRY_LIMIT = 20;",
    "var RETRY_LIMIT = 0;",
    "If the bound was renamed or re-derived, re-point this leg at the new declaration — " +
      "do not delete it, or the race regression loses its only failing direction.",
  );

// Mutation 2: the tempting wrong fix — retry on any refusal at all.
const WIDENED_PIN = () =>
  mutate(
    FONT_PIN_JS,
    "!pass.ok && pass.captured === 0 &&",
    "!pass.ok &&",
    "The retry guard IS `!pass.ok && pass.captured === 0`. If that expression is gone, " +
      "the capture-then-report race is unguarded — see font-pin.mjs's own comment.",
  );

// ── the fixture is the real floor, not a shape that happens to pass ──────────

test("the fixture is the shipped disk set — it satisfies EXPECTED_FACES exactly", () => {
  for (const want of EXPECTED_FACES) {
    const mine = DISK_FACES.filter((f) => f.family === want.family);
    assert.equal(
      mine.length,
      want.min,
      `${want.family}: the stub must declare exactly the floor (${want.min}), not more and not fewer`,
    );
  }
  assert.equal(
    DISK_FACES.length,
    EXPECTED_FACES.reduce((n, x) => n + x.min, 0),
    "the stub declares no face the floor does not name",
  );
});

test("a fully-parsed page passes with NO retry — the baseline the race is measured against", async () => {
  const r = await runPin(FONT_PIN_JS, stubDocument({ delayMs: 0 }));
  assert.equal(r.ok, true, r.summary);
  assert.equal(r.retries, 0, "a healthy page must not spend the retry budget");
  assert.equal(r.captured, 4);
  assert.equal(r.size, 4);
  assert.equal(r.status, "loaded");
  assert.equal(r.summary, "Inter=true IBM Plex Mono=true");
});

// ── criterion 1: the race reproduces, and the shipped pin survives it ────────

test("THE RACE: a pin fired at navigation commit on a delayed stylesheet PASSES, with retries>=1", async () => {
  // 4 runs of 4, the count the wave-66 harness reported, so a fix that closes
  // the race only sometimes cannot hide behind a single lucky run.
  for (let i = 1; i <= 4; i += 1) {
    const r = await runPin(FONT_PIN_JS, stubDocument({ delayMs: 40 }));
    assert.equal(r.ok, true, `run ${i}: ${fontPinRefusal("https://stub/console", r)}`);
    assert.ok(r.retries >= 1, `run ${i}: the race must have been REACHED — retries was ${r.retries}`);
    assert.equal(r.captured, 4, `run ${i}: the winning pass snapshotted the real face set`);
    assert.equal(r.size, 4, `run ${i}`);
    assert.equal(r.summary, "Inter=true IBM Plex Mono=true", `run ${i}`);
    // The whole point: the recorded CI signature is now UNREACHABLE on this page.
    assert.notEqual(r.captured, 0, `run ${i}: 'declared 0' beside 'size 4' must not survive`);
  }
});

test("PRE-FIX, the same page refuses 4/4 with the recorded CI line, character for character", async () => {
  const preFix = PRE_FIX_PIN();
  for (let i = 1; i <= 4; i += 1) {
    const r = await runPin(preFix, stubDocument({ delayMs: 40 }));
    assert.equal(r.ok, false, `run ${i}: without the retry this page MUST refuse`);
    assert.equal(r.captured, 0, `run ${i}: the empty capture is the defect`);
    assert.equal(r.retries, 0, `run ${i}`);
    const refusal = fontPinRefusal("https://stub/console", r);
    assert.ok(
      refusal.includes(RECORDED_DETAIL),
      `run ${i}: expected the recorded detail. Got:\n${refusal}`,
    );
    assert.ok(
      refusal.includes(RECORDED_STATE),
      `run ${i}: 'declared 0' must sit beside 'size 4'. Got:\n${refusal}`,
    );
  }
});

// ── criterion 2: captured===0 is the ONLY gate ───────────────────────────────

test("a HIDDEN WOFF2 refuses on the pass it took — captured>0 is never retried", async () => {
  const doc = stubDocument({
    faces: DISK_FACES.map((f) =>
      f.family === "IBM Plex Mono" && f.weight === "600" ? { ...f, failures: Infinity } : f,
    ),
  });
  const r = await runPin(FONT_PIN_JS, doc);
  assert.equal(r.ok, false, "a missing woff2 is a REFUSAL");
  assert.equal(r.captured, 4, "the pin saw the whole declared set — this is not the race");
  assert.equal(
    r.retries,
    0,
    "an environment fault must be reported immediately, not waited out for 2s on every nav",
  );
  const refusal = fontPinRefusal("https://stub/console", r);
  assert.ok(refusal.includes("600=error/check:false"), refusal);
  assert.ok(refusal.includes("IBM Plex Mono=false"), refusal);
  assert.ok(!refusal.includes("re-collected"), "nothing was re-collected, so nothing may claim it was");
});

test("MUTATION: widened to `!ok` alone, a face broken only at measurement time is LAUNDERED into a pass", async () => {
  // A woff2 whose first fetches fail — the page's own load and the pin's first
  // pass both see `status: "error"`. Every pixel this harness prints is a
  // layout of the face that resolved AT MEASUREMENT TIME, so that page must be
  // refused, not waited on until it looks healthy.
  const flaky = () =>
    stubDocument({
      faces: DISK_FACES.map((f) =>
        f.family === "IBM Plex Mono" && f.weight === "600" ? { ...f, failures: 2 } : f,
      ),
    });

  const shipped = await runPin(FONT_PIN_JS, flaky());
  assert.equal(shipped.ok, false, "the shipped guard REFUSES what it actually measured");
  assert.equal(shipped.retries, 0, "and refuses on the pass it took");

  const widened = await runPin(WIDENED_PIN(), flaky());
  assert.equal(
    widened.ok,
    true,
    "THE MUTATION LEG: with `captured === 0` dropped, the same broken page now PASSES — " +
      "if this ever reads false the mutation stopped reaching the defect and this test went vacuous",
  );
  assert.ok(widened.retries >= 1, "it passed only by retrying a page it had already measured as broken");
});

test("MUTATION: widened to `!ok` alone, a permanently hidden woff2 burns the ENTIRE bound", async () => {
  const hidden = () =>
    stubDocument({
      faces: DISK_FACES.map((f) =>
        f.family === "IBM Plex Mono" && f.weight === "600" ? { ...f, failures: Infinity } : f,
      ),
    });

  const widened = await runPin(WIDENED_PIN(), hidden());
  assert.equal(widened.ok, false, "it cannot launder a file that is genuinely off disk");
  assert.equal(
    widened.retries,
    20,
    "but it spends all 20 passes on it — an instant, honest environment refusal turned into a " +
      "2-second stall on every navigation of all three instruments",
  );

  const shipped = await runPin(FONT_PIN_JS, hidden());
  assert.equal(shipped.retries, 0, "the shipped guard spends none");
});

// ── the bound itself ─────────────────────────────────────────────────────────

test("the retry is BOUNDED: an empty @font-face block refuses after exactly RETRY_LIMIT passes", async () => {
  // The floor's other job: a page that declares NO faces greens a derived-only
  // pin. Here it must refuse — and, since captured stays 0 forever, it is also
  // the only case that can prove the loop terminates rather than hanging.
  const r = await runPin(FONT_PIN_JS, stubDocument({ never: true }));
  assert.equal(r.ok, false, "an empty face set is a REFUSAL, not a pass");
  assert.equal(r.captured, 0);
  assert.equal(r.size, 0);
  assert.equal(r.retries, 20, "the bound is enforced — the pin never waits forever");
  const refusal = fontPinRefusal("https://stub/console", r);
  assert.ok(refusal.includes("re-collected 20x after an empty capture and still refused"), refusal);
});
