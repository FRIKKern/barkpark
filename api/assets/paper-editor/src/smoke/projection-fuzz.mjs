// smoke/projection-fuzz.mjs — the Phase-6 seeded property/fuzz gates over the FULL
// canvas block vocabulary: PROPERTY 1 LOAD IDENTITY (1000 random runs project→diff to
// zero ops + block round-trip) and PROPERTY 2 EDIT FOLD (1000 random stable-id
// mutations fold back exactly), plus the determinism guard.
//
// VERBATIM extraction from src/__smoke.mjs: the two FUZZ property checks + the
// determinism check, carrying their section-local consts (FUZZ_BASE_SEED, FUZZ_ITERS)
// and the delta-debug minimizers (minimizeRun / minimizeMutation) with them. The
// generator vocabulary + PRNG + canonical/normalize helpers they drive live in the
// shared harness (used by the markdown fuzz too). Iteration count is UNCHANGED: 1000 +
// 1000. The shared check()/assertFolds run through the harness so the aggregate report
// + exit code span all modules.
import assert from "node:assert/strict";
import {
  check,
  assertFolds,
  mulberry32,
  canonicalEqual,
  normalizeCanvasDoc,
  reconstructBlock,
  genRun,
  mutateRun,
} from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";

// ═══════════════════════════════════════════════════════════════════════════
// Phase-6 cutover regression gate — SEEDED PROPERTY/FUZZ over the FULL canvas
// block vocabulary. The per-class tests above pin FIXED examples; this proves
// the projection+diff engine is LOSSLESS over RANDOM stress.
//
//   PROPERTY 1 — LOAD IDENTITY: for any stored run, projecting it to the canvas
//     doc and diffing back yields ZERO ops, and every block reconstructs from
//     its projected node deep-equal to the original (canonical, key-order-safe).
//   PROPERTY 2 — EDIT FOLD: for any stored run, a random STABLE-ID mutation
//     (edit content / edit attr / remove / move — never minting a new id) emits
//     ops that, folded through applyOps, reconstruct the mutated run EXACTLY.
//
// DETERMINISTIC: a mulberry32 PRNG seeded from BASE_SEED + iteration index, so
// any failure repros from its printed seed (same seed → same run → same result).
// No Math.random in the generator. Pure Node, no DOM, no server.
// ═══════════════════════════════════════════════════════════════════════════

// ── PROPERTY 1 — LOAD IDENTITY (the core gate) ──────────────────────────────
const FUZZ_BASE_SEED = 0x5eed1; // a fixed base so the whole suite is reproducible.
const FUZZ_ITERS = 1000;

check(`FUZZ property-1 LOAD IDENTITY: ${FUZZ_ITERS} random runs project→diff to ZERO ops + block round-trip`, () => {
  for (let i = 0; i < FUZZ_ITERS; i++) {
    const seed = (FUZZ_BASE_SEED + i) >>> 0;
    const rng = mulberry32(seed);
    const run = genRun(rng);

    // (1a) The production load formula: project → normalize → diff back === [].
    let ops;
    try {
      ops = runToOps(run, normalizeCanvasDoc(runToTiptap(run)));
    } catch (e) {
      throw new Error(
        `LOAD IDENTITY THREW at seed=${seed}: ${e.message}\nrun=${JSON.stringify(run)}`,
      );
    }
    if (ops.length !== 0) {
      const min = minimizeRun(run, (r) => {
        try {
          return runToOps(r, normalizeCanvasDoc(runToTiptap(r))).length !== 0;
        } catch {
          return true;
        }
      });
      throw new Error(
        `LOAD IDENTITY FAILED (spurious ops on load) at seed=${seed}\n` +
          `  emitted ops: ${JSON.stringify(ops)}\n` +
          `  full run:    ${JSON.stringify(run)}\n` +
          `  MINIMAL run: ${JSON.stringify(min)}\n` +
          `  minimal ops: ${JSON.stringify(runToOps(min, normalizeCanvasDoc(runToTiptap(min))))}`,
      );
    }

    // (1b) Every block reconstructs from its projected node deep-equal (canonical)
    //      to the original — the project→reconstruct round-trip is the identity.
    for (const block of run) {
      const back = reconstructBlock(block);
      const { id: _id, ...origRest } = block;
      const { id: _bid, ...backRest } = back;
      if (!canonicalEqual(backRest, origRest)) {
        throw new Error(
          `BLOCK ROUND-TRIP FAILED at seed=${seed}\n` +
            `  original: ${JSON.stringify(block)}\n` +
            `  reconstructed: ${JSON.stringify(back)}`,
        );
      }
    }
  }
});

// ── PROPERTY 2 — EDIT FOLD (the diff gate) ──────────────────────────────────
check(`FUZZ property-2 EDIT FOLD: ${FUZZ_ITERS} random stable-id mutations fold back EXACTLY`, () => {
  for (let i = 0; i < FUZZ_ITERS; i++) {
    // Offset the seed space from property-1 so the two properties exercise
    // DIFFERENT random runs (still fully reproducible from the printed seed).
    const seed = (FUZZ_BASE_SEED + 1000000 + i) >>> 0;
    const rng = mulberry32(seed);
    const run = genRun(rng);
    const mutated = mutateRun(rng, run);
    const mutatedDoc = normalizeCanvasDoc(runToTiptap(mutated));

    let ops, folded;
    try {
      ops = runToOps(run, mutatedDoc);
      folded = assertFolds(run, mutatedDoc, ops, `fuzz-2 seed=${seed}`);
    } catch (e) {
      const min = minimizeMutation(rng, run, mutated);
      throw new Error(
        `EDIT FOLD FAILED at seed=${seed}: ${e.message}\n` +
          `  prev run:    ${JSON.stringify(run)}\n` +
          `  mutated run: ${JSON.stringify(mutated)}\n` +
          `  MINIMAL prev:    ${JSON.stringify(min.prev)}\n` +
          `  MINIMAL mutated: ${JSON.stringify(min.next)}`,
      );
    }

    // assertFolds proves the id ORDER + survival structure. Now assert the folded
    // result is the mutated run EXACTLY (canonical, key-order-safe) — every
    // surviving block's content/attrs reconstruct to the mutated value, and the
    // sequence matches the mutated run block-for-block (minted ids aside).
    if (folded.length !== mutated.length) {
      throw new Error(
        `EDIT FOLD length mismatch at seed=${seed}: folded ${folded.length} !== mutated ${mutated.length}\n` +
          `  prev: ${JSON.stringify(run)}\n  mutated: ${JSON.stringify(mutated)}\n  ops: ${JSON.stringify(ops)}`,
      );
    }
    for (let j = 0; j < mutated.length; j++) {
      // Compare in the engine's CANONICAL stored form (id excluded). The JS
      // reference fold (applyOps) faithfully mirrors patch.ex's SHALLOW merge,
      // which keeps a patch's removal-safe EXPLICIT optionals (callout
      // collapsed:false / title:null, code lang:"" / diagram caption:"") rather
      // than dropping them the way compose.ex's maybe_put would on the server. So
      // a folded block can carry an explicit collapsed:false where the mutated
      // stored block has it absent — render-IDENTICAL, and the projector's own
      // canonical compare (stableCalloutKey/stableCodeKey) treats them EQUAL,
      // which is precisely why the NEXT load round-trips to zero ops. We
      // normalize BOTH sides through reconstructBlock (project→reconstruct), which
      // collapses every absent-when-empty optional to its canonical form on both
      // sides, then compare. This asserts the fold reconstructs the mutated run
      // EXACTLY up to the documented ""/null/absent optional normalization.
      const foldedCanon = reconstructBlock(folded[j]);
      const mutatedCanon = reconstructBlock(mutated[j]);
      const { id: _fid, ...foldedRest } = foldedCanon;
      const { id: _mid, ...mutatedRest } = mutatedCanon;
      if (!canonicalEqual(foldedRest, mutatedRest)) {
        throw new Error(
          `EDIT FOLD content mismatch at seed=${seed} slot ${j}\n` +
            `  expected (canonical): ${JSON.stringify(mutatedCanon)}\n` +
            `  folded   (canonical): ${JSON.stringify(foldedCanon)}\n` +
            `  expected (raw): ${JSON.stringify(mutated[j])}\n` +
            `  folded   (raw): ${JSON.stringify(folded[j])}\n` +
            `  prev: ${JSON.stringify(run)}\n  ops: ${JSON.stringify(ops)}`,
        );
      }
    }
  }
});

// ── delta-debug minimizers (only invoked on a real failure) ─────────────────
//
// minimizeRun — shrink a failing run to the smallest sub-list that still fails
// `predicate`. Greedy single-block removal to a fixed point. Pure, deterministic.
function minimizeRun(run, predicate) {
  let best = run.slice();
  let shrank = true;
  while (shrank && best.length > 1) {
    shrank = false;
    for (let i = 0; i < best.length; i++) {
      const candidate = best.filter((_b, idx) => idx !== i);
      if (candidate.length >= 1 && predicate(candidate)) {
        best = candidate;
        shrank = true;
        break;
      }
    }
  }
  return best;
}

// minimizeMutation — shrink a failing (prev, mutated) pair by dropping the SAME
// trailing/leading blocks from BOTH while the fold still throws. Best-effort: we
// only drop a block id present in BOTH (so the mutation relationship survives).
function minimizeMutation(_rng, prev, mutated) {
  const foldThrows = (p, m) => {
    try {
      const doc = normalizeCanvasDoc(runToTiptap(m));
      assertFolds(p, doc, runToOps(p, doc), "min");
      return false;
    } catch {
      return true;
    }
  };
  let bp = prev.slice();
  let bm = mutated.slice();
  let shrank = true;
  while (shrank) {
    shrank = false;
    // Try removing each prev id from BOTH lists (when present in both).
    for (const block of bp) {
      const id = block.id;
      const np = bp.filter((b) => b.id !== id);
      const nm = bm.filter((b) => b.id !== id);
      if (np.length >= 1 && foldThrows(np, nm)) {
        bp = np;
        bm = nm;
        shrank = true;
        break;
      }
    }
  }
  return { prev: bp, next: bm };
}

// ── determinism guard — the SAME seed yields the SAME run + SAME ops ─────────
check("FUZZ determinism: same seed → identical run, ops, and fold (reproducible)", () => {
  const seed = (FUZZ_BASE_SEED + 42) >>> 0;
  const runA = genRun(mulberry32(seed));
  const runB = genRun(mulberry32(seed));
  assert.deepEqual(runA, runB, "same seed must yield the byte-identical run");

  const opsA = runToOps(runA, normalizeCanvasDoc(runToTiptap(runA)));
  const opsB = runToOps(runB, normalizeCanvasDoc(runToTiptap(runB)));
  assert.deepEqual(opsA, opsB, "same run must yield the byte-identical ops");
  assert.equal(opsA.length, 0, "and the load-identity run emits ZERO ops");

  // A different seed must (with overwhelming probability) differ — sanity that
  // the PRNG is actually advancing per seed, not returning a constant.
  const runC = genRun(mulberry32((seed + 1) >>> 0));
  assert.notDeepEqual(runA, runC, "a different seed yields a different run");
});
