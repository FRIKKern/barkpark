// design/emit/fence.mjs — the write fence's manifest and attribution helpers.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
const here = dirname(dirname(fileURLToPath(import.meta.url))); // design/

// ── the write fence: attribution by generated-region digest (charter D21) ────
// design/emit-manifest.json maps `<path>#<artifact name>` → SHA-256 of the region
// this emitter last wrote there. It is written ONLY by --write and --adopt, and it
// is the emitter's entire memory of its own output. Committed alongside the
// artifacts, exactly like the 18 generated files themselves: change tokens.json,
// run --write, commit the artifacts AND the manifest.
export const MANIFEST_PATH = "design/emit-manifest.json";
const MANIFEST_ABS = join(here, "emit-manifest.json");

// The ledger key: an artifact's IDENTITY, not its path. Two ARTIFACTS entries may
// share one file (distinct markerBegin/markerEnd), and both must own a slot — see
// the header note for why the shape is a flat `${path}#${name}` composite. A unit
// without a name (synthetic fixtures) keys by path alone, which is what it is.
export function regionKey(u) {
  return u.name ? `${u.path}#${u.name}` : u.path;
}

export function regionDigest(region) {
  return region == null ? null : createHash("sha256").update(region, "utf8").digest("hex");
}

export function readManifest() {
  let raw;
  try { raw = readFileSync(MANIFEST_ABS, "utf8"); }
  catch { return null; } // absent entirely — a first run, handled as UNKNOWN below
  try { return JSON.parse(raw).regions ?? {}; }
  catch (e) { throw new Error(`${MANIFEST_PATH} is not valid JSON (${e.message}); repair it or re-bless with: node design/emit.mjs --adopt`); }
}

// Exported so the paper-editor mirror CLI (design/paper-editor-mirror.mjs), the
// OTHER writer of a generated region, records its write in the SAME ledger —
// one manifest, one fence, no second implementation.
export function writeManifest(regions) {
  const sorted = {};
  for (const k of Object.keys(regions).sort()) sorted[k] = regions[k];
  writeFileSync(MANIFEST_ABS, JSON.stringify({
    $comment:
      "GENERATED ATTRIBUTION LEDGER — do not hand-edit. One SHA-256 per artifact, " +
      "keyed `<path>#<artifact name>` (NOT path alone: one file may carry two " +
      "generated regions, and each owns its own slot), taken " +
      "over the GENERATED REGION ONLY (the marker interior for css/html surfaces, " +
      "the whole file for go/ts/elixir). design/emit.mjs --write refuses to replace " +
      "a region whose digest does not match, because those bytes were never emitted " +
      "and replacing them destroys hand-written work (see commit 1d928b3bf). " +
      "Rewritten by `node design/emit.mjs --write`; re-bless the tree with --adopt.",
    regions: sorted,
  }, null, 2) + "\n");
}

// Attribute what is on disk RIGHT NOW against the ledger. Three outcomes:
//   "attributed"   — the region is byte-identical to what this emitter last wrote;
//                    replacing it loses nothing.
//   "unattributed" — the region holds bytes the emitter never produced. A --write
//                    would DELETE them. This is the case the fence exists for.
//   "unknown"      — no ledger entry (a brand-new artifact, or a missing manifest).
//                    Treated as unsafe: refusing a write on an unrecorded region is
//                    the milder failure, and --adopt clears it in one command.
export function attribute(r, regions) {
  if (r.error || r.currentRegion == null) return "unknown";
  const recorded = regions?.[regionKey(r)];
  if (recorded === undefined) return "unknown";
  return recorded === regionDigest(r.currentRegion) ? "attributed" : "unattributed";
}

// The lines a --write would remove from the region and NOT put back. Multiset
// difference, so a legitimate token edit (`--x: #aaa` → `--x: #bbb`) reports the
// one line it truly drops rather than the whole block, and a hand-written rule
// that exists nowhere in the new output is always reported.
export function lostLines(currentRegion, expectedRegion) {
  const keep = new Map();
  for (const l of (expectedRegion ?? "").split("\n")) keep.set(l, (keep.get(l) ?? 0) + 1);
  const lost = [];
  for (const l of (currentRegion ?? "").split("\n")) {
    const n = keep.get(l) ?? 0;
    if (n > 0) keep.set(l, n - 1);
    else if (l.trim() !== "") lost.push(l);
  }
  return lost;
}

// Report the exact bytes a --write would have destroyed. The old --write printed
// only `WROTE <name>`, which named the artifact and never the delta — the single
// property that let 33 hand-written rules disappear unnoticed.
