// research-ledger.json's ONLY safe write path.
//
// WHY THIS FILE EXISTS — two data-loss defects, both proven by mutation against
// the pre-fix coverage.mjs on a hermetic 3,000-file temp repo, not by reading:
//
//   1. SILENT FIELD STRIP. record() and seed() rebuilt every ledger entry as a
//      fresh object literal with exactly seven named keys. A provenance key
//      (`evidenceLevel: "L2-PROBE"`) planted on BOTH the existing ledger entry
//      AND the incoming result was gone after record(): `evidenceLevel present:
//      false`. Nothing warned. An older writer folding results therefore erases
//      a newer writer's fields — the file is not safe for a fleet running mixed
//      versions of this tool, which is precisely what a 20-agent fleet is.
//
//   2. LOST UPDATE. saveLedger was a bare writeFileSync of the whole object:
//      no lock, no CAS, no atomic rename. Two writers with DISJOINT results,
//      staggered 0.25s, deterministically lost one entire contribution —
//      `procB present: 0 / 200`, both processes exit 0, no error, no partial
//      state. Plain last-write-wins.
//
// THE TWO FIXES ARE NOT INTERCHANGEABLE, AND NEITHER ALONE IS SUFFICIENT:
//
//   * writeJsonAtomic (tmp-in-same-dir + rename) stops a TORN file — a reader
//     never sees half a JSON document, and a crash mid-write leaves the prior
//     ledger intact. It does NOTHING about lost updates: two writers who each
//     read the same base and then each atomically rename still leave one
//     contribution destroyed. The mutation above is exactly that shape.
//   * withLedger (lockfile mutex + re-read INSIDE the lock + rev CAS) stops the
//     LOST UPDATE, by making read-modify-write a critical section so the second
//     writer folds onto the first writer's result instead of onto a stale base.
//
// So the write path is: take the lock -> read fresh -> mutate -> verify the
// on-disk rev is still the one we read -> atomically rename into place.
//
// THE CAS IS NOT REDUNDANT WITH THE LOCK. Inside the lock the rev can only have
// moved if some writer bypassed the lock entirely (an older build of this tool,
// or a hand edit). That is the one case where silence would be worst, so it
// throws LedgerConflictError rather than overwriting. The house precedent is
// Barkpark's own task store, which refuses with a named 409 instead of
// clobbering (api/lib/barkpark/tasks/close.ex).
//
// FIELD PRESERVATION IS AN ALLOWLIST, DELIBERATELY NOT A SPREAD. A bare `...r`
// of the incoming result leaks the result's own transport keys into the ledger:
// `path` and `what_breaks_if_wrong` both end up duplicated next to the
// canonical `whatBreaks`. foldEntry therefore preserves unknown keys already on
// the LEDGER entry unconditionally (that is the forward-compatibility
// guarantee — a key this build does not understand survives a round-trip), and
// accepts NEW keys off the incoming result only from an explicit allowlist.

import { readFileSync, writeFileSync, existsSync, openSync, closeSync, unlinkSync, renameSync, statSync, readdirSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, basename, join } from "node:path";

// The seven fields record()/seed() have always written. Named here so a caller
// can tell a canonical field from a preserved one without re-reading coverage.mjs.
export const CANONICAL_ENTRY_KEYS = Object.freeze([
  "hash", "researchedAt", "score", "role", "description", "whatBreaks", "tier",
]);

// Keys accepted OFF AN INCOMING RESULT and copied onto the ledger entry. This is
// the allowlist half of the strip fix. Everything else on a result is transport
// (`path`) or a source alias already normalised into a canonical field
// (`criticality` -> score, `what_breaks_if_wrong` -> whatBreaks), and must not
// reach the ledger. Extend it via config.json's `provenanceKeys` rather than by
// widening this constant, so a fleet can add a field without a code change.
export const DEFAULT_PROVENANCE_KEYS = Object.freeze([
  "evidenceLevel", "evidenceUrl", "evidenceSource", "provenance",
  "verifiedBy", "verifiedAt", "confidence", "citations",
]);

// Result keys that are transport or a canonical alias — never copied verbatim,
// even if someone lists them in provenanceKeys. This is what keeps the fix from
// regressing into the blind spread it replaces.
const NEVER_COPY = new Set([
  "path", "criticality", "what_breaks_if_wrong", ...CANONICAL_ENTRY_KEYS,
]);

export class LedgerConflictError extends Error {
  constructor(msg) { super(msg); this.name = "LedgerConflictError"; }
}
export class LedgerLockTimeoutError extends Error {
  constructor(msg) { super(msg); this.name = "LedgerLockTimeoutError"; }
}

const now = () => new Date().toISOString();
const newRev = () => randomBytes(8).toString("hex");

// Synchronous sleep. The whole tool is synchronous (execFileSync, readFileSync,
// top-level command dispatch), so the lock wait has to be too — an async wait
// here would mean rewriting every caller for no gain.
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// rev is null, NOT a fresh one: an unpersisted ledger has no on-disk rev, and
// withLedger CASes the value it read against the value on disk. Stamping a rev
// here made the very FIRST write of a new ledger conflict with itself — caught
// by the two-writer probe, which reported exit 1 from both writers and no file.
export function emptyLedger() {
  return { meta: { lastFullResearch: null, createdAt: now(), schema: 1, rev: null }, files: {} };
}

// Read the ledger. Unknown top-level keys and unknown meta keys are returned
// untouched — nothing here rebuilds the object, so the round-trip is lossless
// above the entry level as well as inside it.
export function readLedger(ledgerPath) {
  if (!existsSync(ledgerPath)) return emptyLedger();
  const l = JSON.parse(readFileSync(ledgerPath, "utf8"));
  if (!l.meta || typeof l.meta !== "object") l.meta = {};
  if (!l.files || typeof l.files !== "object") l.files = {};
  return l;
}

// The rev of what is CURRENTLY on disk. Returns null when the file is absent.
function diskRev(ledgerPath) {
  if (!existsSync(ledgerPath)) return null;
  try { return readLedger(ledgerPath).meta?.rev ?? null; } catch { return null; }
}

// Write via a temp file in the SAME directory, then rename. Same-directory
// matters: rename is only atomic within one filesystem, and a tmp elsewhere
// (/tmp, say) degrades silently into a copy on a cross-device move.
export function writeJsonAtomic(ledgerPath, ledger) {
  const tmp = join(dirname(ledgerPath), `.${basename(ledgerPath)}.tmp.${process.pid}.${randomBytes(4).toString("hex")}`);
  try {
    writeFileSync(tmp, JSON.stringify(ledger, null, 2));
    renameSync(tmp, ledgerPath);
  } catch (e) {
    try { if (existsSync(tmp)) unlinkSync(tmp); } catch { /* best effort */ }
    throw e;
  }
  return ledger;
}

// Sweep temp files a crashed writer left behind. Only ours-shaped names, only
// old ones — a live writer's tmp is younger than staleMs by construction.
function sweepStaleTmp(ledgerPath, staleMs) {
  const dir = dirname(ledgerPath), prefix = `.${basename(ledgerPath)}.tmp.`;
  let names;
  try { names = readdirSync(dir); } catch { return; }
  for (const n of names) {
    if (!n.startsWith(prefix)) continue;
    try { if (Date.now() - statSync(join(dir, n)).mtimeMs > staleMs) unlinkSync(join(dir, n)); } catch { /* raced */ }
  }
}

function acquireLock(lockPath, { timeoutMs, staleMs, pollMs }) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      // "wx" fails if the path exists — the atomic create-or-fail that makes
      // this a mutex rather than a suggestion.
      const fd = openSync(lockPath, "wx");
      try { writeFileSync(fd, JSON.stringify({ pid: process.pid, at: now() })); } finally { closeSync(fd); }
      return;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      // A holder that died leaves its lock forever. Break it only once it is
      // provably older than a legitimate critical section (record() folding the
      // full monorepo measured ~11s; staleMs defaults to an order above that).
      let age = 0;
      try { age = Date.now() - statSync(lockPath).mtimeMs; } catch { continue; } // holder released mid-check
      if (age > staleMs) {
        try { unlinkSync(lockPath); } catch { /* someone else broke it first */ }
        continue;
      }
      if (Date.now() >= deadline) {
        throw new LedgerLockTimeoutError(
          `research-ledger lock held for ${age}ms and still not free after ${timeoutMs}ms: ${lockPath}. ` +
          `Another writer is folding results; retry, or remove the lock if no such process exists.`);
      }
      sleepSync(pollMs);
    }
  }
}

function releaseLock(lockPath) {
  try { unlinkSync(lockPath); } catch { /* already gone */ }
}

// THE write path. `mutate(ledger)` runs inside the lock on a ledger read INSIDE
// the lock, so it folds onto whatever the previous writer committed rather than
// onto a base that went stale while it worked. Return a replacement object from
// `mutate` or mutate in place; both are honoured.
export function withLedger(ledgerPath, mutate, opts = {}) {
  const { timeoutMs = 120_000, staleMs = 120_000, pollMs = 25, lockPath = `${ledgerPath}.lock` } = opts;
  sweepStaleTmp(ledgerPath, staleMs);
  acquireLock(lockPath, { timeoutMs, staleMs, pollMs });
  try {
    const ledger = readLedger(ledgerPath);
    const baseRev = ledger.meta?.rev ?? null;
    const next = mutate(ledger) ?? ledger;
    // CAS. Inside the lock this can only trip on a writer that ignored the lock.
    // Refuse loudly instead of destroying whatever it wrote.
    const seen = diskRev(ledgerPath);
    if (seen !== baseRev) {
      throw new LedgerConflictError(
        `research-ledger changed underneath a locked read-modify-write ` +
        `(rev ${baseRev ?? "<absent>"} -> ${seen ?? "<absent>"}): a writer bypassed ${lockPath}. ` +
        `Refusing to overwrite it. Re-run the command.`);
    }
    if (!next.meta || typeof next.meta !== "object") next.meta = {};
    next.meta.rev = newRev();
    next.meta.updatedAt = now();
    writeJsonAtomic(ledgerPath, next);
    return next;
  } finally {
    releaseLock(lockPath);
  }
}

// Build the ledger entry for one path.
//   `prev`      — the existing entry, or undefined. EVERY key on it survives,
//                 including ones this build has never heard of. That is the
//                 forward-compatibility half: read -> write is lossless.
//   `canonical` — the seven fields this build computes; they always win.
//   `incoming`  — the raw agent result. Only allowlisted keys are taken.
export function foldEntry(prev, canonical, incoming, provenanceKeys = DEFAULT_PROVENANCE_KEYS) {
  const out = (prev && typeof prev === "object" && !Array.isArray(prev)) ? { ...prev } : {};
  for (const k of Object.keys(canonical)) out[k] = canonical[k];
  if (incoming && typeof incoming === "object") {
    for (const k of provenanceKeys) {
      if (NEVER_COPY.has(k)) continue;
      if (Object.prototype.hasOwnProperty.call(incoming, k)) out[k] = incoming[k];
    }
  }
  return out;
}

// The provenance allowlist for a given config.json, defaults included. A config
// may only ADD; the never-copy set above still applies.
export function provenanceKeysFrom(cfg) {
  const extra = Array.isArray(cfg?.provenanceKeys) ? cfg.provenanceKeys : [];
  return [...new Set([...DEFAULT_PROVENANCE_KEYS, ...extra])].filter(k => !NEVER_COPY.has(k));
}
