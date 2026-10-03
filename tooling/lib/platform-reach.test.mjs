// Calibration for platform-aware reach (task-403fe20b2a7f2743).
// Ground truth: Felix's verdict on magick.ex. image_backend.ex selects Vix on
// Linux/ARM prod, so Magick is unreachable there. Run: node --test tooling/lib/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseOsSelectors, edgeVerdict, platformReach, resolveProfile, scanElixir, readConfigs, DEFAULT_PROFILE,
} from "./platform-reach.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "../..");
const SELECTOR = "api/lib/barkpark/media/image_backend.ex";
const MAGICK = "Barkpark.Media.ImageBackend.Magick";
const VIX = "Barkpark.Media.ImageBackend.Vix";

// A fixture graph shaped like the real one: three callers depend on the
// selector, the selector depends on both backends, and one unguarded helper
// is depended on by everyone.
const nodes = [
  { id: "sel", path: SELECTOR, deps: ["magick", "vix", "util"] },
  { id: "magick", path: "api/lib/barkpark/media/image_backend/magick.ex", deps: ["util"] },
  { id: "vix", path: "api/lib/barkpark/media/image_backend/vix.ex", deps: ["util"] },
  { id: "util", path: "api/lib/barkpark/media/util.ex", deps: [] },
  { id: "c1", path: "api/lib/a.ex", deps: ["sel"] },
  { id: "c2", path: "api/lib/b.ex", deps: ["sel"] },
  { id: "c3", path: "api/lib/c.ex", deps: ["c1"] },
];
const moduleFile = {
  [MAGICK]: "api/lib/barkpark/media/image_backend/magick.ex",
  [VIX]: "api/lib/barkpark/media/image_backend/vix.ex",
};
// The REAL selector source, so calibration breaks if the selector changes shape.
const realSelectors = parseOsSelectors(readFileSync(join(ROOT, SELECTOR), "utf8"));
const ctx = (profile, configSrcs = []) => ({ moduleFile, selectorsByFile: { [SELECTOR]: realSelectors }, configSrcs, profile });

test("the real image_backend selector parses: win32 → Magick, default → Vix, config-overridable", () => {
  assert.equal(realSelectors.length, 1);
  const [s] = realSelectors;
  assert.equal(s.literal, true);
  assert.deepEqual(s.arms.map((a) => [a.pattern, a.modules]), [["win32", [MAGICK]], ["*", [VIX]]]);
  assert.equal(s.overridable, "barkpark.image_backend");
});

test("Linux/ARM (the declared default): magick's reach is DISCOUNTED to what does not route through the selector", () => {
  const r = platformReach(nodes, ctx("linux"));
  const m = r.files["api/lib/barkpark/media/image_backend/magick.ex"];
  assert.equal(m.raw, 4); // sel, c1, c2, c3
  assert.equal(m.reach, 0);
  assert.equal(m.discounted, true);
  const [e] = m.edges;
  assert.equal(e.state, "inactive");
  assert.match(e.why, /selected only on win32/);
  assert.match(e.why, /linux profile takes .*Vix/);
  // The edge is NOT deleted from the index: magick keeps its dependency.
  assert.ok(nodes.find((n) => n.id === "sel").deps.includes("magick"));
});

test("Windows: magick's reach is RETAINED and vix's is the one discounted", () => {
  const r = platformReach(nodes, ctx("win32"));
  assert.equal(r.files["api/lib/barkpark/media/image_backend/magick.ex"].reach, 4);
  assert.equal(r.files["api/lib/barkpark/media/image_backend/vix.ex"].reach, 0);
});

test("an UNGUARDED reachable module is unchanged on every profile", () => {
  for (const p of ["linux", "win32", "darwin"]) {
    const u = platformReach(nodes, ctx(p)).files["api/lib/barkpark/media/util.ex"];
    // util is depended on by sel, magick, vix directly, so its reach never routes
    // only through an inactive edge: every caller still reaches it.
    assert.equal(u.reach, u.raw, p);
    assert.equal(u.discounted, false, p);
  }
});

test("a DYNAMIC selector (deployed config sets the override) counts the edge and says so", () => {
  const cfg = ["import Config\nconfig :barkpark, image_backend: Barkpark.Media.ImageBackend.Magick\n"];
  const r = platformReach(nodes, ctx("linux", cfg));
  const m = r.files["api/lib/barkpark/media/image_backend/magick.ex"];
  assert.equal(m.reach, m.raw);
  assert.equal(m.edges[0].state, "dynamic");
  assert.match(m.edges[0].why, /config sets barkpark\.image_backend/);
});

test("an unreadable arm makes the selector dynamic, never 'unreachable'", () => {
  const [s] = parseOsSelectors("case :os.type() do\n  {fam, name} when fam == :win32 -> A.B\n  _ -> C.D\nend");
  assert.equal(s.literal, false);
  assert.equal(edgeVerdict(s, "A.B", "linux").state, "dynamic");
});

test("the profile is DECLARED: argument > CODY_PLATFORM > the fleet default, never the host OS", () => {
  assert.deepEqual(resolveProfile("win32", {}), { profile: "win32", source: "argument" });
  assert.equal(resolveProfile(null, { CODY_PLATFORM: "darwin" }).profile, "darwin");
  assert.equal(resolveProfile(null, {}).profile, DEFAULT_PROFILE);
  assert.equal(DEFAULT_PROFILE, "linux");
});

test("on the real tree: the scan finds the selector, and api/config does not set the override", () => {
  const { moduleFile: mf, selectorsByFile } = scanElixir(ROOT);
  assert.ok(selectorsByFile[SELECTOR], "the image_backend selector was not found by the scan");
  assert.equal(mf[MAGICK], "api/lib/barkpark/media/image_backend/magick.ex");
  const v = edgeVerdict(selectorsByFile[SELECTOR][0], MAGICK, "linux", readConfigs(ROOT));
  assert.equal(v.state, "inactive", "magick must be inactive on the deployed Linux profile today");
});

test("MUTATION: with selector awareness removed, magick's Linux reach is the inflated raw count", () => {
  // Drop the selectors (what reach was before this change) and the calibration reds.
  const blind = platformReach(nodes, { moduleFile, selectorsByFile: {}, profile: "linux" });
  const m = blind.files["api/lib/barkpark/media/image_backend/magick.ex"];
  assert.equal(m.reach, 4);
  assert.notEqual(m.reach, platformReach(nodes, ctx("linux")).files["api/lib/barkpark/media/image_backend/magick.ex"].reach);
});
