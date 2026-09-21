// identity-seed.test.mjs — the scenario's pre-paint seed BEATS the accent axis.
//
// THE DEFECT THIS REDS ON (task-a0258bec59b256d7, found by the
// gr-backlog-accent-matrix re-review 2026-09-20)
// ────────────────────────────────────────────────────────────────────────────
// `identity-iris` exists to prove GR12 — a PERSISTED identity wins. It does
// that the only way the harness offers: `seedLocal: { bp_theme: "iris" }`.
// mock.js never read seedLocal at all (smoke.mjs's own comment called it
// "smoke-only"), and its `?accent=` block writes the SHOT's identity into that
// same key. Result: identity-iris rendered the shot's accent, so it was
// byte-identical to shell-root at every one of the five accents, and the
// 2760-shot matrix built to prove GR12 proved nothing about it.
//
// WHY THIS RUNS mock.js RATHER THAN GREPPING IT
// ────────────────────────────────────────────────────────────────────────────
// A string match for "__PREVIEW_SEED_LOCAL appears after BP_THEME_KEY" would be
// a typed fact about source order, and would pass over a block that throws, a
// block guarded by a condition that is never true, or a seed written to the
// wrong key. So the suite EXECUTES the shipped mock.js in a vm against a stub
// window/document and reads the state back — the same two observables a shot
// captures: the `data-bp-theme` attribute on the root element and the
// `bp_theme` localStorage key the identity picker mirrors.
//
// The vm run is not a simulation of the ordering; it IS the ordering. mock.js's
// dynamic import of scenarios.mjs cannot resolve in a bare vm context, which is
// harmless and asserted: it returns a rejected promise the file's own .catch
// swallows, and every statement this suite measures runs BEFORE it.
//
// THE CONTROL: `overwriteRestored()` re-runs the same mock.js source with the
// seed block deleted — i.e. the origin/main behaviour — and every ordering test
// asserts that arrangement LOSES. A suite that only ever sees the fixed file
// cannot tell a real fix from a no-op.

import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { SCENARIOS } from "./scenarios.mjs";
import { seedLocalFor, seedingScenarios, seedInjectTag, scenarioFromUrl, SEED_GLOBAL } from "./seed-inject.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MOCK_SRC = fs.readFileSync(path.join(HERE, "mock.js"), "utf8");

const ACCENTS = ["evergreen", "ember", "fjord", "charple", "iris"];

// Run mock.js's pre-paint half exactly as a browser would, and report what a
// shot of the first frame would see.
function boot({ scen, accent, seed, src = MOCK_SRC }) {
  const store = new Map();
  const attrs = new Map();
  const search =
    "?scen=" + encodeURIComponent(scen) + (accent ? "&accent=" + encodeURIComponent(accent) : "");
  const warnings = [];
  const win = {
    location: { search, href: "http://localhost/" + search, pathname: "/" },
    localStorage: {
      setItem: (k, v) => store.set(k, String(v)),
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      removeItem: (k) => store.delete(k),
    },
    sessionStorage: {
      setItem: () => {},
      getItem: () => null,
      removeItem: () => {},
    },
    addEventListener() {},
    fetch: null,
  };
  if (seed !== undefined) win[SEED_GLOBAL] = seed;
  const doc = {
    documentElement: {
      setAttribute: (k, v) => attrs.set(k, String(v)),
      getAttribute: (k) => (attrs.has(k) ? attrs.get(k) : null),
    },
    addEventListener() {},
    readyState: "loading",
    querySelector: () => null,
  };
  win.document = doc;
  const ctx = {
    window: win,
    document: doc,
    URLSearchParams,
    URL,
    Promise,
    JSON,
    Object,
    String,
    console: { warn: (...a) => warnings.push(a.join(" ")), error: () => {}, log: () => {} },
    setTimeout,
    clearTimeout,
  };
  vm.createContext(ctx);
  vm.runInContext(src, ctx, { filename: "mock.js" });
  return {
    // What CSS paints against.
    attr: doc.documentElement.getAttribute("data-bp-theme"),
    // What the identity picker reads back to mark a row active.
    stored: store.get("bp_theme") ?? null,
    warnings,
  };
}

// The mutation: mock.js WITHOUT its seed block — origin/main's behaviour,
// reproduced from the shipped file rather than pasted, so the control cannot
// drift away from the subject.
function overwriteRestored() {
  const marker = "var seedLocal = window." + SEED_GLOBAL + ";";
  assert.ok(MOCK_SRC.includes(marker), "the seed block's anchor moved — this control no longer removes anything");
  return MOCK_SRC.replace(marker, "var seedLocal = null;");
}

// ── the seam is not vacuous ─────────────────────────────────────────────────

test("at least one committed scenario seeds localStorage (else every assertion below is over nothing)", () => {
  const seeding = seedingScenarios();
  assert.ok(seeding.length >= 1, "no scenario in scenarios.mjs carries seedLocal");
  assert.ok(seeding.includes("identity-iris"), "identity-iris lost its seedLocal: " + seeding.join(", "));
});

test("identity-iris seeds bp_theme=iris and shell-root seeds nothing", () => {
  assert.deepEqual(seedLocalFor("identity-iris"), { bp_theme: "iris" });
  assert.equal(seedLocalFor("shell-root"), null);
  assert.equal(seedLocalFor("no-such-scenario-zzz"), null);
});

test("every seedLocal key a scenario declares is a string the browser can store", () => {
  for (const name of seedingScenarios()) {
    for (const [k, v] of Object.entries(seedLocalFor(name))) {
      assert.equal(typeof k, "string");
      assert.equal(typeof v, "string", name + "." + k + " is not stringifiable");
    }
  }
});

// ── the injected tag ────────────────────────────────────────────────────────

test("seedInjectTag emits the seed for a seeding scenario and NOTHING for the rest", () => {
  const tag = seedInjectTag("identity-iris");
  assert.match(tag, /^<script>window\.__PREVIEW_SEED_LOCAL = \{"bp_theme":"iris"\};<\/script>/);
  assert.equal(seedInjectTag("shell-root"), "");
  assert.equal(seedInjectTag(null), "");
  assert.equal(seedInjectTag("no-such-scenario-zzz"), "");
});

test("seedInjectTag escapes `<` so a seed value can never close its own script tag", () => {
  // Not hypothetical hygiene: the escape is what makes the seam safe to point
  // at any future value source. Proven on the real emitter via a stub scenario.
  const saved = SCENARIOS["__seed_escape_probe__"];
  SCENARIOS["__seed_escape_probe__"] = { seedLocal: { k: "</script><b>x" } };
  try {
    const tag = seedInjectTag("__seed_escape_probe__");
    assert.ok(!tag.includes("</script><b>"), "an unescaped `</script>` reached the injected tag: " + tag);
    assert.ok(tag.includes("\\u003c/script"), "the `<` was not escaped: " + tag);
  } finally {
    if (saved === undefined) delete SCENARIOS["__seed_escape_probe__"];
    else SCENARIOS["__seed_escape_probe__"] = saved;
  }
});

test("scenarioFromUrl reads the same ?scen= mock.js reads, and says null when there is none", () => {
  assert.equal(scenarioFromUrl("/?scen=identity-iris&accent=ember"), "identity-iris");
  assert.equal(scenarioFromUrl("/index.html?accent=ember"), null);
  assert.equal(scenarioFromUrl("/"), null);
  assert.equal(scenarioFromUrl(undefined), null);
});

// ── the ordering, at every accent, on the shipped mock.js ───────────────────

for (const accent of ACCENTS) {
  test(`identity-iris renders iris at ?accent=${accent} (the scenario beats the axis)`, () => {
    const seen = boot({ scen: "identity-iris", accent, seed: seedLocalFor("identity-iris") });
    assert.equal(seen.attr, "iris", `data-bp-theme read back as ${seen.attr} under accent=${accent}`);
    assert.equal(seen.stored, "iris", `bp_theme read back as ${seen.stored} under accent=${accent}`);
  });

  test(`CONTROL: with the overwrite restored, identity-iris collapses to accent=${accent}`, () => {
    const seen = boot({
      scen: "identity-iris",
      accent,
      seed: seedLocalFor("identity-iris"),
      src: overwriteRestored(),
    });
    assert.equal(seen.attr, accent, "the control did not reproduce the defect it exists to model");
    assert.equal(seen.stored, accent);
  });
}

test("identity-iris differs from shell-root at every accent EXCEPT iris, where they legitimately agree", () => {
  const differs = [];
  const agrees = [];
  for (const accent of ACCENTS) {
    const iris = boot({ scen: "identity-iris", accent, seed: seedLocalFor("identity-iris") });
    const root = boot({ scen: "shell-root", accent, seed: seedLocalFor("shell-root") ?? undefined });
    (iris.attr === root.attr ? agrees : differs).push(accent);
  }
  // Four, not five: at ?accent=iris shell-root IS iris, so identity coincidence
  // there is the correct answer and not evidence of the overwrite.
  assert.deepEqual(differs, ["evergreen", "ember", "fjord", "charple"]);
  assert.deepEqual(agrees, ["iris"]);
});

test("CONTROL: with the overwrite restored, identity-iris matches shell-root at ALL FIVE accents", () => {
  const src = overwriteRestored();
  for (const accent of ACCENTS) {
    const iris = boot({ scen: "identity-iris", accent, seed: seedLocalFor("identity-iris"), src });
    const root = boot({ scen: "shell-root", accent, src });
    assert.equal(iris.attr, root.attr, "accent=" + accent + " should have collapsed under the control");
  }
});

// ── the seam's edges ────────────────────────────────────────────────────────

test("no injected seed leaves the accent axis exactly as it was (the seam is additive)", () => {
  for (const accent of ACCENTS) {
    const seen = boot({ scen: "shell-root", accent });
    assert.equal(seen.attr, accent);
    assert.equal(seen.stored, accent);
  }
});

test("a seed with no accent on the URL still paints, so identity-iris is right in the un-accented matrix too", () => {
  // The bare `./shoot.sh` pass sends no ?accent= at all. Before this fix that
  // pass ALSO rendered the evergreen fallback for identity-iris — the scenario
  // was wrong in the default matrix, not only under the accent axis.
  const seen = boot({ scen: "identity-iris", accent: null, seed: seedLocalFor("identity-iris") });
  assert.equal(seen.attr, "iris");
  assert.equal(seen.stored, "iris");
  const control = boot({ scen: "identity-iris", accent: null, seed: seedLocalFor("identity-iris"), src: overwriteRestored() });
  assert.equal(control.attr, null, "un-accented control should paint no identity at all");
});

test("a seed carrying an unknown identity writes the key but never paints a bogus attribute", () => {
  const seen = boot({ scen: "identity-iris", accent: "ember", seed: { bp_theme: "not-an-accent" } });
  assert.equal(seen.stored, "not-an-accent", "the key must still round-trip — app.js is the validator");
  assert.equal(seen.attr, "ember", "an unknown identity must not be painted onto the root element");
});

test("a seed of a non-bp_theme key is stored and paints nothing", () => {
  const seen = boot({ scen: "identity-iris", accent: "ember", seed: { "bp.active-team": "team-7" } });
  assert.equal(seen.attr, "ember");
});

test("a malformed seed global cannot break the boot", () => {
  for (const seed of [null, "iris", 42, []]) {
    const seen = boot({ scen: "identity-iris", accent: "ember", seed });
    assert.equal(seen.attr, "ember", "a malformed seed must be inert, not fatal");
  }
});
