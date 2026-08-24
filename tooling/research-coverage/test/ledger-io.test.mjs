// tooling/research-coverage/ledger-io.mjs — the ledger write path.
//
//   node --test tooling/research-coverage/test/ledger-io.test.mjs
//
// The two defects this file regression-guards were PROVEN BY MUTATION against
// the pre-fix coverage.mjs, on a hermetic 3,000-file temp repo:
//
//   * strip:   `evidenceLevel present: false`  (planted on ledger AND result)
//   * clobber: `procB present: 0 / 200`        (two disjoint writers, 0.25s apart)
//
// THE CONCURRENCY TESTS SPAWN REAL PROCESSES. A test that reasons about a race
// proves nothing about a race, so the two-writer cases below fork two `node`
// children through a wall-clock start barrier and let them collide for real.
// They are deterministic, not timing-hopeful: the barrier makes both children
// enter the critical section together, and each then HOLDS it, so the
// interleaving is forced rather than raced for.
//
// AND THE HARNESS PROVES IT CAN SEE LOSS. `naive` mode below replicates the
// exact pre-fix shape (readFileSync -> mutate -> writeFileSync) and is asserted
// to LOSE a contribution. Without that control, a green two-writer test could
// mean "the fix works" or "the harness never actually interleaved" — and those
// two look identical from the outside.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, utimesSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  foldEntry, readLedger, writeJsonAtomic, withLedger, emptyLedger,
  provenanceKeysFrom, LedgerConflictError, LedgerLockTimeoutError,
  CANONICAL_ENTRY_KEYS, DEFAULT_PROVENANCE_KEYS,
} from "../ledger-io.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const LEDGER_IO = join(HERE, "..", "ledger-io.mjs");

const tmp = () => mkdtempSync(join(tmpdir(), "bp-ledger-io-"));
const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

// ===========================================================================
// DEFECT 1 — silent field strip
// ===========================================================================

test("foldEntry preserves a ledger key this build has never heard of", () => {
  const prev = { hash: "old", tier: "agent", evidenceLevel: "L2-PROBE", someFutureKey: { deep: 1 } };
  const out = foldEntry(prev, { hash: "new", tier: "agent" }, {});
  assert.equal(out.evidenceLevel, "L2-PROBE", "a planted provenance key must survive the fold");
  assert.deepEqual(out.someFutureKey, { deep: 1 }, "an arbitrary unknown key must survive the fold");
  assert.equal(out.hash, "new", "canonical fields still win");
});

test("foldEntry takes an allowlisted provenance key OFF the incoming result", () => {
  const out = foldEntry(undefined, { hash: "h", tier: "agent" }, { path: "a.txt", evidenceLevel: "L3" });
  assert.equal(out.evidenceLevel, "L3");
});

test("foldEntry does NOT blind-spread: transport and alias keys never reach the ledger", () => {
  // The caveat recorded on the row: a bare `...r` leaked `path` and
  // `what_breaks_if_wrong` in alongside the canonical `whatBreaks`.
  const out = foldEntry(undefined,
    { hash: "h", researchedAt: "t", score: 1, role: "r", description: "d", whatBreaks: "w", tier: "agent" },
    { path: "src/a.txt", criticality: 9, what_breaks_if_wrong: "w", junk: "nope", evidenceLevel: "L1" });
  assert.equal(Object.prototype.hasOwnProperty.call(out, "path"), false, "transport key leaked");
  assert.equal(Object.prototype.hasOwnProperty.call(out, "what_breaks_if_wrong"), false, "alias key leaked");
  assert.equal(Object.prototype.hasOwnProperty.call(out, "criticality"), false, "alias key leaked");
  assert.equal(Object.prototype.hasOwnProperty.call(out, "junk"), false, "unallowlisted key leaked");
  assert.equal(out.whatBreaks, "w", "the canonical field is still populated");
  assert.equal(out.evidenceLevel, "L1");
});

test("a config cannot allowlist its way past the never-copy set", () => {
  // Otherwise `provenanceKeys: ["path"]` in config.json would reintroduce the
  // exact leak the allowlist exists to prevent.
  const keys = provenanceKeysFrom({ provenanceKeys: ["path", "what_breaks_if_wrong", "hash", "myOwnField"] });
  assert.equal(keys.includes("path"), false);
  assert.equal(keys.includes("what_breaks_if_wrong"), false);
  assert.equal(keys.includes("hash"), false);
  assert.equal(keys.includes("myOwnField"), true, "a genuinely new field must be addable without a code change");
  for (const d of DEFAULT_PROVENANCE_KEYS) assert.equal(keys.includes(d), true);
});

test("the canonical key list is exactly the seven fields record() has always written", () => {
  assert.deepEqual([...CANONICAL_ENTRY_KEYS].sort(),
    ["description", "hash", "researchedAt", "role", "score", "tier", "whatBreaks"]);
});

test("read -> write is lossless above the entry level too", () => {
  const d = tmp(), p = join(d, "research-ledger.json");
  const original = {
    meta: { lastFullResearch: null, createdAt: "2020-01-01T00:00:00.000Z", schema: 1, futureMeta: "keep me" },
    files: { "a.txt": { hash: "h", unknownEntryKey: 7 } },
    futureTopLevel: [1, 2, 3],
  };
  writeFileSync(p, JSON.stringify(original, null, 2));
  const back = withLedger(p, () => {});
  const onDisk = readJson(p);
  assert.equal(onDisk.meta.futureMeta, "keep me");
  assert.deepEqual(onDisk.futureTopLevel, [1, 2, 3]);
  assert.equal(onDisk.files["a.txt"].unknownEntryKey, 7);
  assert.equal(onDisk.meta.schema, 1);
  assert.notEqual(back.meta.rev, null);
  rmSync(d, { recursive: true, force: true });
});

// ===========================================================================
// atomic write
// ===========================================================================

test("writeJsonAtomic leaves no temp file behind and lands the content", () => {
  const d = tmp(), p = join(d, "research-ledger.json");
  writeJsonAtomic(p, { files: { "a.txt": { hash: "h" } } });
  assert.equal(readJson(p).files["a.txt"].hash, "h");
  assert.deepEqual(readdirSync(d), ["research-ledger.json"], "a stray .tmp survived the write");
  rmSync(d, { recursive: true, force: true });
});

test("a write that throws mid-serialise leaves the PRIOR ledger intact", () => {
  const d = tmp(), p = join(d, "research-ledger.json");
  writeJsonAtomic(p, { files: { "a.txt": { hash: "good" } } });
  const circular = { files: {} }; circular.self = circular; // JSON.stringify throws
  assert.throws(() => writeJsonAtomic(p, circular), TypeError);
  assert.equal(readJson(p).files["a.txt"].hash, "good", "the old ledger was destroyed by a failed write");
  assert.deepEqual(readdirSync(d), ["research-ledger.json"], "a failed write left its temp file behind");
  rmSync(d, { recursive: true, force: true });
});

// ===========================================================================
// DEFECT 2 — lost update, driven with real concurrent processes
// ===========================================================================

// Child writer. `safe` uses withLedger; `naive` replicates the pre-fix shape.
// Both wait for a shared wall-clock start so the two children genuinely
// interleave rather than happening to.
const WRITER = (ledgerIoPath) => `
import { withLedger } from ${JSON.stringify(ledgerIoPath)};
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const [, , mode, ledgerPath, tag, startAt, count, holdMs] = process.argv;
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
while (Date.now() < Number(startAt)) sleep(2);          // shared start barrier
const add = (l) => { for (let i = 0; i < Number(count); i++) l.files[tag + "/f" + i] = { hash: "h", tier: tag }; };
if (mode === "safe") {
  withLedger(ledgerPath, (l) => { add(l); sleep(Number(holdMs)); });
} else {
  const l = existsSync(ledgerPath) ? JSON.parse(readFileSync(ledgerPath, "utf8")) : { meta: {}, files: {} };
  sleep(Number(holdMs));                                 // the read-modify-write window
  add(l);
  writeFileSync(ledgerPath, JSON.stringify(l, null, 2));
}
`;

// Two children, one shared start barrier, one shell that backgrounds both. A
// blocking spawnSync per child would serialise them and every result below
// would be a lie about concurrency.
function runTwoWriters(mode, { count = 200, holdMs = 300 } = {}) {
  const d = tmp();
  const ledgerPath = join(d, "research-ledger.json");
  const writerPath = join(d, "writer.mjs");
  const script = join(d, "both.sh");
  writeFileSync(writerPath, WRITER(LEDGER_IO));
  writeJsonAtomic(ledgerPath, emptyLedger());           // a ledger both writers read

  const startAt = Date.now() + 500;
  writeFileSync(script,
    `"$1" "$2" ${mode} "$3" procA ${startAt} ${count} ${holdMs} & A=$!\n` +
    `"$1" "$2" ${mode} "$3" procB ${startAt} ${count} ${holdMs} & B=$!\n` +
    `wait $A; ra=$?\nwait $B; rb=$?\necho "$ra $rb"\n`);
  const out = execFileSync("sh", [script, process.execPath, writerPath, ledgerPath], { encoding: "utf8" }).trim();

  const files = readJson(ledgerPath).files;
  const survived = (tag) => Object.values(files).filter(e => e.tier === tag).length;
  return { exits: out, A: survived("procA"), B: survived("procB"), total: Object.keys(files).length, dir: d };
}

test("CONTROL: the pre-fix shape really does lose a whole writer (the harness can see loss)", () => {
  const r = runTwoWriters("naive", { count: 200, holdMs: 300 });
  assert.equal(r.exits, "0 0", "both control writers must succeed — silence is the defect");
  assert.equal(Math.min(r.A, r.B), 0,
    `expected one contribution to be destroyed by last-write-wins, got A=${r.A} B=${r.B}. ` +
    `If BOTH survived, this harness is not interleaving and every green below is vacuous.`);
  assert.equal(Math.max(r.A, r.B), 200);
  rmSync(r.dir, { recursive: true, force: true });
});

test("two concurrent withLedger writers with disjoint keys BOTH survive", () => {
  const r = runTwoWriters("safe", { count: 200, holdMs: 300 });
  assert.equal(r.exits, "0 0", "a writer failed");
  assert.equal(r.A, 200, `writer A lost ${200 - r.A} entries`);
  assert.equal(r.B, 200, `writer B lost ${200 - r.B} entries`);
  assert.equal(r.total, 400);
  rmSync(r.dir, { recursive: true, force: true });
});

// ===========================================================================
// the lock and the CAS
// ===========================================================================

test("the CAS refuses — loudly — when a writer bypasses the lock", () => {
  const d = tmp(), p = join(d, "research-ledger.json");
  writeJsonAtomic(p, { ...emptyLedger(), meta: { ...emptyLedger().meta, rev: "base" } });
  assert.throws(
    () => withLedger(p, (l) => {
      l.files["a.txt"] = { hash: "mine" };
      // Simulate an older build (or a hand edit) writing straight past the lock.
      writeJsonAtomic(p, { meta: { rev: "someone-elses-rev" }, files: { "b.txt": { hash: "theirs" } } });
    }),
    (e) => e instanceof LedgerConflictError && /bypassed/.test(e.message));
  assert.equal(readJson(p).files["b.txt"].hash, "theirs", "the bypassing writer's data was destroyed anyway");
  assert.equal(existsSync(`${p}.lock`), false, "the lock was not released after the refusal");
  rmSync(d, { recursive: true, force: true });
});

test("a held lock times out with a named error rather than corrupting", () => {
  const d = tmp(), p = join(d, "research-ledger.json");
  writeJsonAtomic(p, emptyLedger());
  writeFileSync(`${p}.lock`, JSON.stringify({ pid: 999999, at: new Date().toISOString() }));
  assert.throws(() => withLedger(p, () => {}, { timeoutMs: 150, pollMs: 10, staleMs: 60_000 }),
    (e) => e instanceof LedgerLockTimeoutError && /Another writer/.test(e.message));
  rmSync(d, { recursive: true, force: true });
});

test("a lock left by a dead writer is broken once it is provably stale", () => {
  const d = tmp(), p = join(d, "research-ledger.json");
  writeJsonAtomic(p, emptyLedger());
  const lock = `${p}.lock`;
  writeFileSync(lock, JSON.stringify({ pid: 999999, at: "1970-01-01T00:00:00.000Z" }));
  const old = (Date.now() - 600_000) / 1000;
  utimesSync(lock, old, old);
  withLedger(p, (l) => { l.files["a.txt"] = { hash: "h" }; }, { timeoutMs: 1000, pollMs: 10, staleMs: 60_000 });
  assert.equal(readJson(p).files["a.txt"].hash, "h");
  assert.equal(existsSync(lock), false);
  rmSync(d, { recursive: true, force: true });
});

test("the lock is released even when the mutate function throws", () => {
  const d = tmp(), p = join(d, "research-ledger.json");
  writeJsonAtomic(p, emptyLedger());
  assert.throws(() => withLedger(p, () => { throw new Error("boom"); }), /boom/);
  assert.equal(existsSync(`${p}.lock`), false, "a thrown mutate would deadlock every later writer");
  withLedger(p, (l) => { l.files["a.txt"] = { hash: "h" }; });
  assert.equal(readJson(p).files["a.txt"].hash, "h");
  rmSync(d, { recursive: true, force: true });
});

test("the FIRST write of a brand-new ledger does not conflict with itself", () => {
  // Regression: emptyLedger() once stamped a fresh rev, so baseRev was non-null
  // while the (absent) file's rev was null — every first write threw
  // LedgerConflictError and no ledger was ever created. Caught by the
  // two-writer probe, which reported exit 1 from both writers and no file.
  const d = tmp(), p = join(d, "research-ledger.json");
  assert.equal(existsSync(p), false);
  assert.equal(emptyLedger().meta.rev, null);
  withLedger(p, (l) => { l.files["a.txt"] = { hash: "h" }; });
  assert.equal(readJson(p).files["a.txt"].hash, "h");
  rmSync(d, { recursive: true, force: true });
});

test("readLedger on an absent file yields a usable empty ledger", () => {
  const d = tmp();
  const l = readLedger(join(d, "nope.json"));
  assert.deepEqual(l.files, {});
  assert.equal(l.meta.schema, 1);
  rmSync(d, { recursive: true, force: true });
});
