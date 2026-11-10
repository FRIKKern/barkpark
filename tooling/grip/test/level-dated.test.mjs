// Dated generated artifacts — tooling/grip/level.mjs DATED_GENERATED_ARTIFACTS.
//
//   node --test tooling/grip/test/level-dated.test.mjs
//
// api/assets/paper-surface/paper-surface.css was hand-written until 3e096b47
// (2026-11-08); sync-barkpark writes it now. A read of it observed after that
// derives L4, the same read observed before derives L3, and the four 2026-07-31
// ledger rows that read it honestly at L3 still fold unrestated. Their run file
// is immutable and is read here, never written.
import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { DATED_GENERATED_ARTIFACTS, GENERATED_ARTIFACT_PATTERNS, deriveLevel } from "../level.mjs";
import { admitRecipe, foldLedger, restateLevel, writeLedgerRun } from "../ledger.mjs";
import { admitFact } from "../record.mjs";
import { selectLeads } from "../leads.mjs";

const SURFACE = "api/assets/paper-surface/paper-surface.css";
const READ = `grep -n -- '--paper-bg:' ${SURFACE}`;
const AFTER = "2026-11-09T09:00:00Z";
const BEFORE = "2026-11-01T09:00:00Z";
const OLD_RUN = new URL("../ledger/grip-20260731T010541Z-e8469656713b08f8.json", import.meta.url);

const row = (observed_at, over = {}) => ({
  subject: SURFACE,
  quantity: `paper-bg line, read ${observed_at.slice(0, 10)}`,
  rerun: READ,
  deps: [SURFACE],
  observed_at,
  ...over,
});

test("a new read of the raw surface observed after 2026-11-08 derives L4; the same read before derives L3", () => {
  assert.equal(deriveLevel(READ, { observedAt: AFTER }), "L4");
  assert.equal(deriveLevel(READ, { observedAt: BEFORE }), "L3");
  // The edge is the commit instant itself, to the second.
  assert.equal(deriveLevel(READ, { observedAt: "2026-11-08T18:47:19Z" }), "L3");
  assert.equal(deriveLevel(READ, { observedAt: "2026-11-08T18:47:20Z" }), "L4");
  assert.equal(deriveLevel(READ, { observedAt: "2026-11-08T18:47:19.999Z" }), "L3", "a fraction never crosses since");
});

test("a read with no usable instant counts as made now, so it takes the stricter L4", () => {
  for (const observedAt of [undefined, null, "", "yesterday", "2026-07-31", "2026-07-31T03:05:41+02:00"]) {
    assert.equal(deriveLevel(READ, { observedAt }), "L4", JSON.stringify(observedAt));
  }
  assert.equal(deriveLevel(READ), "L4", "a call with no options is a read made now");
});

test("the write path admits the old read at L3 and refuses an L3 claim on the new one", () => {
  const before = admitRecipe(row(BEFORE, { derived_level: "L3" }));
  assert.equal(before.ok, true, JSON.stringify(before.rejections));
  assert.equal(before.recipe.derived_level, "L3");

  const after = admitRecipe(row(AFTER, { derived_level: "L3" }));
  assert.equal(after.ok, false);
  assert.ok(after.rejections.some((r) => r.reason === "LEVEL-SKIP" && r.derived === "L4"), JSON.stringify(after.rejections));
  assert.equal(admitRecipe(row(AFTER)).recipe.derived_level, "L4");
});

test("the fact seam levels by observed_at too", () => {
  const fact = (observed_at) => admitFact({ subject: SURFACE, claim: "the surface defines --paper-bg", rerun: READ, observed_at });
  assert.equal(fact(BEFORE).fact.level, "L3");
  assert.equal(fact(AFTER).fact.level, "L4");
});

test("the fold re-derives each planted row at its own instant and restates neither", () => {
  const dir = mkdtempSync(join(tmpdir(), "grip-dated-"));
  try {
    const now = "2026-11-10T00:00:00Z";
    const written = writeLedgerRun({ run_id: "dated-sinks", recipes: [row(BEFORE), row(AFTER)], dir, now });
    assert.equal(written.ok, true, JSON.stringify(written.rejections));
    const fold = foldLedger(dir, { now });
    const levels = fold.entries.flatMap((e) => e.recipes ?? [e]).map((r) => [r.observed_at, r.derived_level]).sort();
    assert.deepEqual(levels, [[BEFORE, "L3"], [AFTER, "L4"]]);
    assert.deepEqual([fold.level_restatements.up.length, fold.level_restatements.down.length], [0, 0]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the four 2026-07-31 ledger rows still pass unrestated, read from their immutable run file", () => {
  const rows = JSON.parse(readFileSync(OLD_RUN, "utf8")).recipes.slice(0, 4);
  assert.equal(rows.length, 4);
  for (const [i, stored] of rows.entries()) {
    assert.equal(stored.subject, SURFACE, `row ${i}`);
    assert.equal(stored.observed_at, "2026-07-31T01:05:41Z", `row ${i}`);
    const restated = restateLevel(stored);
    assert.deepEqual([restated.derived_level, restated.level_restated], ["L3", false], `row ${i}: ${stored.rerun}`);
    // And without the date, the same command would be read as made now.
    assert.equal(deriveLevel(stored.rerun), "L4", `row ${i} undated`);
  }
});

test("leads shows the four 2026-07-31 rows at L3, unrestated, through the real fold", () => {
  const dir = mkdtempSync(join(tmpdir(), "grip-dated-leads-"));
  try {
    copyFileSync(OLD_RUN, join(dir, "grip-20260731T010541Z-e8469656713b08f8.json"));
    const leads = selectLeads(foldLedger(dir, { now: "2026-11-10T00:00:00Z" }), SURFACE);
    const rows = leads.rows.filter((r) => r.subject === SURFACE);
    assert.equal(rows.length, 4);
    for (const r of rows) {
      assert.deepEqual([r.derived_level, r.stored_level, r.level_restated], ["L3", "L3", false], r.rerun);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// Each sink's since is its commit's UTC committer time. Pinned here, with no git
// call, so moving any since (or commit) turns this red. Checked against git when
// written (2026-11-10), with, for each commit:
//   TZ=UTC git show -s --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ <commit>
const SINCE_TABLE = [
  ["api/assets/paper-surface/paper-surface.css", "2026-11-08T18:47:20Z", "3e096b476c79"],
  ["api/assets/paper-surface/code-tokens.css", "2026-11-08T18:47:20Z", "3e096b476c79"],
  ["api/priv/static/assets/bp-paper-editor-shell.css", "2026-11-08T18:47:20Z", "3e096b476c79"],
  ["api/priv/static/assets/bp-paper-mermaid.js", "2026-11-08T18:47:20Z", "3e096b476c79"],
  ["api/priv/static/assets/bp-paper-editor.bundle.js", "2026-05-24T10:59:22Z", "215b05ee6e2d"],
  ["api/priv/static/assets/bp-paper-editor.css", "2026-06-23T22:30:20Z", "e60f8546c337"],
  ["web/public/bp-paper-editor.bundle.js", "2026-06-23T23:07:05Z", "c06033f5bf10"],
  ["web/public/assets/bp-paper-editor.css", "2026-06-23T23:07:05Z", "c06033f5bf10"],
  ["api/priv/static/assets/bp-paper-code.js", "2026-09-21T00:16:51Z", "03ecdcd5505d"],
  ["api/priv/static/assets/bp-paper-surface.css", "2026-10-09T18:31:22Z", "52137dada0da"],
  ["api/assets/paper-editor/host-profile/surface.json", "2026-11-02T17:51:07Z", "770113f04c5c"],
];

test("each dated sink keeps the since and commit git gave it", () => {
  assert.equal(DATED_GENERATED_ARTIFACTS.length, SINCE_TABLE.length);
  for (const [sink, since, commit] of SINCE_TABLE) {
    const hits = DATED_GENERATED_ARTIFACTS.filter((e) => e.pattern.test(sink));
    assert.equal(hits.length, 1, sink);
    assert.deepEqual([hits[0].since, hits[0].commit], [since, commit], sink);
  }
});

test("every sync-barkpark sink has a dated entry, and no dated path is also on the flat list", () => {
  const source = readFileSync(new URL("../../../api/assets/paper-editor/scripts/sync-barkpark.mjs", import.meta.url), "utf8");
  const sinks = [...source.matchAll(/"((?:api|web)\/[^"]+\.(?:css|js|json))"/g)].map((m) => m[1]);
  assert.equal(new Set(sinks).size, 11, `sync-barkpark names 11 sinks: ${sinks.join(" ")}`);
  for (const sink of sinks) {
    const hits = DATED_GENERATED_ARTIFACTS.filter((e) => e.pattern.test(sink));
    assert.equal(hits.length, 1, `${sink} needs exactly one dated entry`);
    assert.equal(GENERATED_ARTIFACT_PATTERNS.some((re) => re.test(sink)), false, `${sink} must not also be flat`);
  }
  for (const entry of DATED_GENERATED_ARTIFACTS) {
    assert.match(entry.since, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    assert.match(entry.commit, /^[0-9a-f]{12}$/);
  }
});

test("sources stay L3: the fragments sync-barkpark assembles the surface from are not artifacts", () => {
  const fragment = "api/assets/paper-editor/src/paper-surface/00-foundation-type.css";
  assert.equal(deriveLevel(`cat ${fragment}`, { observedAt: AFTER }), "L3");
});
