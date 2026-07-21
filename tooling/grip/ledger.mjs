#!/usr/bin/env node
// ledger.mjs — the durable half of the grip layer: it stores RE-DERIVATION
// RECIPES, and never values.
//
//   import { admitRecipe, writeLedgerRun, readLedgerRuns, foldLedger } from "./ledger.mjs";
//
// THE ROW HAS NO VALUE FIELD (charter D26, amending D10):
//
//     { subject, quantity, rerun, derived_level, deps[], observed_at }
//
// and `observed_at` means "WHEN THIS RECIPE LAST RAN" — never "when this was
// true". The ratified anti-goal ("the ledger is an INDEX OF HOW TO VERIFY
// FAST, never a substitute for verification") stops being a discipline an
// author must remember and becomes a property of the schema: a store that
// contains no truth cannot be mistaken for settled truth.
//
// WHY VALUES CANNOT WORK — settled, do not re-litigate. This repo's own
// `MemAvailable` fact went false because BEAM uptime moved, and uptime is in
// the content hash of NOTHING the fact names. Content-hash invalidation
// structurally cannot catch it: the invalidation signal is not in the fact.
// That is precisely why R2 exists (a fact records its DEPENDENCIES), and why
// a stored value is a lie with a timestamp on it. A writer supplying a
// `value` key is REJECTED (`VALUE-STORED`), never silently dropped.
//
// UNKNOWN FIELDS ARE REJECTED, NOT STRIPPED. `tooling/research-coverage`'s
// `record()` silently strips unknown fields — proven by mutation, and it is
// half of D10's trap: the writer believes it stored something and the store
// disagrees, with no signal anywhere. Here the store's answer to "I do not
// understand this key" is a nonzero, named rejection.
//
// ONE IMMUTABLE FILE PER WRITE, FOLDED AT READ TIME. Every write creates
// exactly one new file under the ledger directory and NEVER opens an existing
// one for modification (`wx`, and the name is content-addressed). D10's
// lost-write class — two writers staggered inside an ~11s window, one
// contribution gone, proven — becomes IMPOSSIBLE rather than managed, and git
// merges the directory add/add clean across concurrent worktrees.
//
// RIVAL-METHOD IS THE PRODUCT, NOT A DEFECT SIGNAL — AND IT IS NOT `CONFLICT`.
// There is no write order to appeal to, so what the FOLD OBSERVES is simply
// this: two or more DISTINCT `rerun` commands exist for one (subject,
// quantity). Both are kept, both are flagged, and the flag MEANS "multiple
// checks exist for this — re-run them and compare what they answer NOW". That
// is the ledger delivering exactly what it promises (an index of how to verify
// fast, with more than one way in), not a report that something is wrong.
//
// It is deliberately NOT named CONFLICT, and does NOT import adjudicate.mjs's
// vocabulary. The two mechanisms are structurally OPPOSITE, proven by a 2x2
// probe over all four cells:
//
//   - THIS fold fires on ≥2 distinct rerun COMMAND STRINGS and has no value
//     field to compare — so it fires on `wc -l /abs/path` vs `wc -l rel/path`,
//     two commands both verified to answer `544`. Agreement, flagged.
//   - adjudicate.mjs's `detectConflicts` fires on ≥2 distinct claim VALUES and
//     never reads `rerun` — so it returned 0 on that same pair, and 2 on a
//     genuine 544-vs-999 disagreement, which THIS fold is structurally
//     incapable of seeing at all.
//
// One name for two incompatible meanings would discredit R4 on its first live
// day: a reviewer told "CONFLICT" would go looking for a disagreement that the
// firing mechanism cannot detect. (This retires the premise of the open task
// `tgw2-ledger-adjudicator-vocab`, "the shape is identical by construction" —
// it is false, and that task is cancelled separately.)
//
// THE HONESTY CHECKS ARE INJECTED, NOT IMPORTED. `admitRecipe(input, { now,
// screen })` takes its clock bound and its safety screen as ARGUMENTS. Both
// are optional and omitting them admits, so no existing caller breaks; the CLI
// is what closes the opt-in (see the `now` note at the bound itself). Injection
// is what keeps this module dependency-free and clock-free — see below.
//
// NO CLOCK, NO RANDOMNESS. `observed_at` and `run_id` are REQUIRED
// writer-supplied arguments; nothing here calls the current time or a random
// source. D19: the workflow host hard-refuses the clock and randomness
// builtins outright with "breaks resume", and the writer of these rows is one
// phase away from a workflow file. A clock-free module can be called from
// anywhere, including from a phase that has none.
//
// The names of those builtins do not appear ANYWHERE in this file — not in a
// comment, not in a message — so the check is a plain grep over the raw source
// with no comment-stripping caveat to argue about. See ledger.test.mjs.
//
// node: builtins only, no dependencies, no side effect on import.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { deriveLevel, checkCeiling, LEVELS } from "./level.mjs";

// ── the row ──────────────────────────────────────────────────────────────────

// The COMPLETE set of keys a ledger row may carry. Anything else is rejected
// (UNKNOWN-FIELD), and `value` is rejected by its own name because it is the
// doctrinal one.
export const RECIPE_FIELDS = Object.freeze([
  "subject", "quantity", "rerun", "derived_level", "deps", "observed_at",
]);

// Names a writer reaches for when it is about to store an answer instead of a
// way to get one. Each gets the VALUE-STORED rejection rather than the generic
// UNKNOWN-FIELD, because the message has to say WHY, not just "not a key".
const VALUE_SHAPED_FIELDS = Object.freeze([
  "value", "values", "observed_value", "result", "measurement", "measured", "answer",
]);

// The fold's flag for two rival ways to re-derive one key. NOT "CONFLICT" —
// see the header: this is the product ("more than one check exists, re-run and
// compare"), and adjudicate.mjs's identically-named verdict fires on the
// opposite input. One constant = one place to re-point.
export const RIVAL_METHOD = "RIVAL-METHOD";

// An instant, not a date and not prose. `observed_at` is load-bearing enough
// that "2026-07-20" or "yesterday" must not pass as one. Offset forms match
// here so that "not an instant at all" and "an instant in the wrong zone" get
// DIFFERENT rejections — see UTC_INSTANT.
const ISO_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

// Z ONLY, and this is not pedantry about formatting.
//
// Every ordering this module performs on `observed_at` — the future bound
// below, and the fold's within-entry sort — is a LEXICAL string comparison,
// which is correct ONLY for same-offset instants. `2026-07-21T02:00:00+02:00`
// sorts AFTER `2026-07-21T01:00:00Z` and is in fact one hour EARLIER. So a
// single admitted offset row makes the future bound silently wrong in one
// direction and the sort silently wrong in the other.
//
// The fix is not to normalise: normalising an offset to UTC requires the
// platform's date-parsing builtin, whose very name re-trips the clock-free
// grep this module is built around (see the NO CLOCK note in the header). So
// the offset form is REJECTED at the seam under its own name instead, and
// every string that survives is directly comparable to every other.
const UTC_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

// Z ALONE IS NOT ENOUGH — same-offset is necessary but not sufficient, and
// this was found by the test that was written to prove the future bound worked.
//
//     "2026-07-21T00:00:00.001Z"  <  "2026-07-21T00:00:00Z"
//
// …lexically, because the strings diverge at the separator and "." (0x2E)
// sorts below "Z" (0x5A). A row observed a millisecond in the FUTURE therefore
// compared as PAST and was admitted, and the fold's within-entry sort put a
// sub-second row before the whole-second row it followed. Variable fractional
// precision breaks ISO ordering at exactly one character.
//
// Normalising is pure string surgery — pad the fraction to a fixed width and
// drop the Z — so it stays clock-free and dependency-free, which is why the
// answer is this rather than the platform's date parser. Input is always
// UTC_INSTANT-shaped when this is called, so the split cannot fail.
function comparableInstant(iso) {
  const seconds = iso.slice(0, 19);            // YYYY-MM-DDTHH:MM:SS, fixed width
  const dot = iso.indexOf(".", 19);
  const fraction = dot === -1 ? "" : iso.slice(dot + 1, -1);
  return `${seconds}.${fraction.padEnd(9, "0").slice(0, 9)}`;
}

// A run id names one production of rows. It goes in a filename, so it may not
// carry a separator or anything a shell or a path would reinterpret.
const RUN_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

function reject(reason, message, extra = {}) {
  return { reason, message: `${reason}: ${message}`, ...extra };
}

// admitRecipe(input, { now, screen }) → { ok: true, recipe } | { ok: false, rejections }
//
// Rejections ACCUMULATE (record.mjs's convention): a writer fixing a row
// should see everything wrong with it in one pass, not one thing per attempt.
//
// EVERY CHECK BEFORE THIS SLICE WAS A SHAPE CHECK, AND A FORGERY PASSED THEM
// ALL. A run file holding two rows for commands that were never executed —
// dated 2031-12-31 and 2087-01-01 — was ADMITTED, written to disk and folded
// back as authoritative, one of them at L1 for the sole reason that the string
// began with `ssh`. (The other, at L2, does not even execute: `git show
// origin/main:tooling/grip/ledger/recipes.json` is `fatal: path … does not
// exist`.) Shape checks cannot see that, because the forgery is perfectly
// shaped. The two options below are the first checks here that ask whether a
// row could be HONEST rather than whether it is well-formed:
//
//   now    — an ISO-8601 UTC instant the caller vouches for as "no later than
//            right now". A row observed after it is rejected.
//   screen — a predicate over the `rerun` command, for refusing commands that
//            must never become recipes (a recipe is precisely a thing this
//            epic exists to make agents re-run cheaply and OFTEN).
//
// BOTH ARE INJECTED AND BOTH ARE OPTIONAL, WHICH IS A REAL LIMITATION, STATED
// PLAINLY: omitting them admits, so on its own this is an OPT-IN bound and not
// a seam a forger has to get past. Two deliberate reasons, neither of which is
// "it was easier":
//
//   - `now` is not read from a clock here because this module owns none. D19:
//     the workflow host hard-refuses the clock builtins with "breaks resume",
//     and the writer of these rows is one phase from a workflow file. It is
//     also what keeps the SUITE deterministic — a clock in this module would
//     silently make every fixture's verdict depend on what time CI ran.
//   - `screen` is injected rather than imported so that this module keeps its
//     "no dependency but level.mjs" property, and so the safety vocabulary can
//     evolve without the durable store moving. Nothing here imports
//     `screen.mjs`; the CLI is what wires the two together.
//
// THE OPT-IN IS CLOSED AT THE CLI, NOT HERE. `tgw3-write-verb` bakes `date -u`
// into the write path so every real write passes a `now`, and wires the screen
// beside it. Do not read this bound as a closed seam on its own — it is the
// mechanism; the CLI is the enforcement.
export function admitRecipe(input = {}, options = {}) {
  const rejections = [];

  // The bounds are validated BEFORE the row, because a malformed bound
  // disables the check it belongs to, and a check that silently stops
  // checking is the vacuous green this whole epic exists to abolish. A caller
  // that passes a broken `now` or a non-function `screen` is told so, loudly,
  // rather than getting an admission that looks screened and is not.
  const { now, screen } = options ?? {};
  const boundNow = typeof now === "string" ? now.trim() : now;
  const hasNow = boundNow !== undefined && boundNow !== null;
  if (hasNow && (typeof boundNow !== "string" || !UTC_INSTANT.test(boundNow))) {
    rejections.push(reject(
      "BAD-OPTION",
      `\`now\` must be an ISO-8601 UTC instant ending in Z (got ${JSON.stringify(now)}). It is compared to observed_at as a plain string, so a value in any other shape would not bound anything — and a bound that silently stops bounding is worse than no bound at all.`,
      { option: "now" },
    ));
  }
  const hasScreen = screen !== undefined && screen !== null;
  if (hasScreen && typeof screen !== "function") {
    rejections.push(reject(
      "BAD-OPTION",
      `\`screen\` must be a function (rerun) => true | false | { ok } (got ${typeof screen}). A non-function screen would admit every command while looking screened.`,
      { option: "screen" },
    ));
  }

  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    rejections.push(reject("NOT-A-ROW", "a ledger row must be a plain object"));
    return { ok: false, rejections };
  }

  // (a) NO VALUES. Checked FIRST so the doctrinal rejection is the first thing
  // a writer reads.
  for (const field of VALUE_SHAPED_FIELDS) {
    if (Object.hasOwn(input, field)) {
      rejections.push(reject(
        "VALUE-STORED",
        `the row carries ${JSON.stringify(field)} — a ledger row stores a RECIPE for re-deriving a fact, never the fact. A stored value goes stale for reasons that are not in the row (MemAvailable went false because BEAM uptime moved, and uptime is in no content hash of anything the row names), so no invalidation rule can catch it. Put the command in \`rerun\` and re-run it.`,
        { field },
      ));
    }
  }

  // (b) Unknown fields are REJECTED, never stripped — research-coverage's
  // record() strips them, and the writer never learns its data vanished.
  for (const field of Object.keys(input)) {
    if (RECIPE_FIELDS.includes(field) || VALUE_SHAPED_FIELDS.includes(field)) continue;
    rejections.push(reject(
      "UNKNOWN-FIELD",
      `${JSON.stringify(field)} is not a ledger row field (${RECIPE_FIELDS.join(", ")}). Unknown keys are rejected rather than dropped: a store that silently discards what it does not understand lets a writer believe it recorded something it did not.`,
      { field },
    ));
  }

  const { subject, quantity, rerun, derived_level, deps, observed_at } = input;

  if (typeof subject !== "string" || subject.trim() === "") {
    rejections.push(reject("MISSING-SUBJECT", "a row must name what it is about — the subject is half the conflict key"));
  }
  if (typeof quantity !== "string" || quantity.trim() === "") {
    rejections.push(reject("MISSING-QUANTITY", "a row must name WHICH property of the subject the recipe re-derives — the quantity is the other half of the conflict key"));
  }

  // (c) A recipe without a command is not a recipe.
  //
  // D3 (no rerun ⇒ DEMOTE to L6, never reject) governs FACTS, where the prose
  // still carries something and punishing honest work drives writers around
  // the gate. A LEDGER ROW is nothing but the recipe: with no command there is
  // no index entry, only an assertion with a timestamp — the thing this store
  // exists to be incapable of holding. So here it rejects. D20 sanctions
  // exactly this check at the write seam ("rerun is present and non-empty").
  if (typeof rerun !== "string" || rerun.trim() === "") {
    rejections.push(reject(
      "MISSING-RERUN",
      "a ledger row IS the re-derivation recipe — with no `rerun` command there is nothing to index, and what remains is an assertion with a timestamp, which is exactly what this store must be unable to hold",
    ));
  }

  // (d) derived_level is DERIVED — from the rerun command alone. A supplied
  // value is a claim, and the derivation is its ceiling (D2).
  let level = null;
  if (typeof rerun === "string" && rerun.trim() !== "") {
    const derived = deriveLevel(rerun);
    level = derived;
    if (derived_level !== undefined) {
      const ceiling = checkCeiling(derived_level, derived);
      if (!ceiling.ok) {
        rejections.push(ceiling);
      } else if (LEVELS[derived_level] > LEVELS[derived]) {
        level = derived_level; // an honest under-claim is kept
      }
    }
  } else if (derived_level !== undefined && LEVELS[derived_level] === undefined) {
    rejections.push(reject("UNKNOWN-LEVEL", `${JSON.stringify(derived_level)} is not on the ladder ${Object.keys(LEVELS).join(" ")}`));
  }

  // (e) deps[] — R2. May be empty (a recipe genuinely reading nothing else is
  // honest); may not be absent-by-accident-of-type or hold non-strings.
  let depList = [];
  if (deps === undefined) {
    depList = [];
  } else if (!Array.isArray(deps) || deps.some((d) => typeof d !== "string" || d.trim() === "")) {
    rejections.push(reject("BAD-DEPS", "deps must be an array of non-empty subject strings this recipe reads through (R2) — an empty array is fine, a malformed one is not"));
  } else {
    depList = deps.map((d) => d.trim());
  }

  // (f) observed_at — REQUIRED, writer-supplied. This module owns no clock.
  if (typeof observed_at !== "string" || observed_at.trim() === "") {
    rejections.push(reject(
      "MISSING-OBSERVED-AT",
      "observed_at is required and must be supplied by the writer — this module reads no clock at all (D19: the workflow host refuses the clock builtins outright, because they break resume). It records WHEN THIS RECIPE LAST RAN, never when the fact was true.",
    ));
  } else if (!ISO_INSTANT.test(observed_at.trim())) {
    rejections.push(reject(
      "BAD-OBSERVED-AT",
      `${JSON.stringify(observed_at)} is not an ISO-8601 instant (YYYY-MM-DDTHH:MM:SS[.sss](Z|±HH:MM)) — a date or a phrase cannot order two runs of the same recipe`,
    ));
  } else if (!UTC_INSTANT.test(observed_at.trim())) {
    // (g) Z-ONLY. An instant, but not one this module can order. See
    // UTC_INSTANT: every comparison here is lexical, and lexical ordering of
    // mixed offsets is wrong in both directions at once.
    rejections.push(reject(
      "OFFSET-OBSERVED-AT",
      `${JSON.stringify(observed_at)} carries a UTC offset — observed_at must be expressed in UTC and end in Z. Instants are compared as plain strings here, and lexical order is only true order at one offset: "2026-07-21T02:00:00+02:00" sorts after "2026-07-21T01:00:00Z" while being an hour EARLIER. Convert to UTC at the writer (\`date -u +%Y-%m-%dT%H:%M:%SZ\`).`,
    ));
  } else if (
    hasNow && typeof boundNow === "string" && UTC_INSTANT.test(boundNow)
    && comparableInstant(observed_at.trim()) > comparableInstant(boundNow)
  ) {
    // (h) THE FUTURE BOUND. Both sides are Z-form by the checks above and both
    // are width-normalised, so the string comparison IS the instant
    // comparison. A recipe cannot have last run later than now: a future
    // observed_at means the row was composed rather than observed, which is
    // exactly how the 2031/2087 forgery got in.
    rejections.push(reject(
      "FUTURE-OBSERVED-AT",
      `observed_at ${JSON.stringify(observed_at.trim())} is later than the supplied now (${JSON.stringify(boundNow)}). observed_at means WHEN THIS RECIPE LAST RAN, and a run cannot have happened yet — a future instant is the signature of a row that was composed rather than observed.`,
      { observed_at: observed_at.trim(), now: boundNow },
    ));
  }

  // (i) THE SAFETY SCREEN, injected. Runs only on a command that exists, so a
  // MISSING-RERUN row does not also collect a confusing screen verdict.
  //
  // A recipe is a standing invitation to re-run something, cheaply and often.
  // `systemctl stop bp-crux-parent` and `rm -rf /opt/barkpark/releases` are
  // both perfectly well-shaped recipes and were both admitted before this —
  // the store's own product would have handed an agent an outage.
  //
  // Screen contract (tolerant on purpose, so a caller may pass the simplest
  // thing that expresses a refusal):
  //     true | { ok: true }            → allowed
  //     false | { ok: false, … } | str → refused; `message`/the string is the reason
  if (hasScreen && typeof screen === "function" && typeof rerun === "string" && rerun.trim() !== "") {
    let verdict;
    let threw = null;
    try {
      verdict = screen(rerun.trim());
    } catch (err) {
      threw = err;
    }
    if (threw !== null) {
      // A screen that blew up has screened NOTHING. Admitting here would turn
      // any bug in the safety layer into an open door, silently.
      rejections.push(reject(
        "SCREEN-FAILED",
        `the injected screen threw on this command (${threw?.message ?? String(threw)}) — it therefore refused nothing and allowed nothing, so the row is not admitted. A safety check that fails open is not a safety check.`,
      ));
    } else if (verdict !== null && typeof verdict === "object" && typeof verdict.then === "function") {
      // A PROMISE IS A CONTRACT MISMATCH, NOT A REFUSAL, and it must not be
      // reported as one. `admitRecipe` is synchronous by design (it is one
      // phase from a workflow file that may not await), so an async screen can
      // never be awaited here — but a thenable is not `true` and is not
      // `{ ok: true }`, so the tolerant branch below would fail it CLOSED under
      // REFUSED-COMMAND. Fail-closed is right; the DIAGNOSIS was not. Every row
      // would be refused, and the reason string would send whoever wired the
      // CLI hunting an over-aggressive screen instead of the wrong function
      // shape. The verdict is unchanged — only the name it fails under.
      rejections.push(reject(
        "SCREEN-NOT-SYNC",
        `the injected screen returned a Promise. admitRecipe is synchronous — it cannot await a verdict — so an async screen screens NOTHING and every row would be refused. Pass a synchronous predicate; resolve any async work before calling.`,
      ));
    } else {
      const allowed = verdict === true || (verdict !== null && typeof verdict === "object" && verdict.ok === true);
      if (!allowed) {
        // `reason` IS READ, and that is a cross-slice fix, not a nicety.
        // screen.mjs — the module the CLI will actually inject next round —
        // returns `{ ok, reason }`, while this contract originally read only
        // `message`. Both slices were correct in isolation and their contract
        // silently did not meet: every refusal printed the generic fallback and
        // THREW AWAY the screen's diagnosis, which is the whole reason
        // REFUSED_HEADS carries a per-head explanation ("so the refusal log
        // reads as a diagnosis rather than a shrug"). Verified by wiring the
        // real screenCommand in: `systemctl stop bp-crux-parent` reported "the
        // injected screen refused it" instead of naming the sub-verb rule.
        // Both keys are accepted so neither module has to know the other's.
        const why = typeof verdict === "string"
          ? verdict
          : (verdict !== null && typeof verdict === "object"
            ? (typeof verdict.reason === "string" ? verdict.reason
              : typeof verdict.message === "string" ? verdict.message
                : "the injected screen refused it")
            : "the injected screen refused it");
        rejections.push(reject(
          "REFUSED-COMMAND",
          `${JSON.stringify(rerun.trim())} was refused by the injected safety screen — ${why}. A ledger row is a standing invitation to re-run this command cheaply and often, so a command that can take something down must never become one.`,
          { rerun: rerun.trim() },
        ));
      }
    }
  }

  if (rejections.length > 0) return { ok: false, rejections };

  // Key order is fixed so that the serialized bytes of an identical row are
  // identical — the file name is a digest of them.
  return {
    ok: true,
    recipe: {
      subject: subject.trim(),
      quantity: quantity.trim(),
      rerun: rerun.trim(),
      derived_level: level,
      deps: depList,
      observed_at: observed_at.trim(),
    },
  };
}

// ── the conflict key ─────────────────────────────────────────────────────────

// (subject, quantity). NUL-joined because neither field may contain it, so no
// pair of distinct rows can collide by concatenation.
//
// Defensive about types on purpose: admitRecipe guarantees strings on the WRITE
// path, but the fold reads bytes off disk that nothing re-admits, so a
// hand-edited or truncated file can present a number here. See usableRow.
export function recipeKey(recipe) {
  const part = (v) => (typeof v === "string" ? v.trim() : "");
  return `${part(recipe?.subject)}\u0000${part(recipe?.quantity)}`;
}

// Is this on-disk row usable by the fold?
//
// THE WRITE PATH IS NOT THE READ PATH. admitRecipe gates everything this module
// WRITES, but the fold reads whatever is in the directory — a hand edit, a
// truncated write, a row from a future schema. Two failure modes were live and
// both are defects this module exists to make impossible, committed inside it:
//
//   - a non-string subject/quantity threw out of recipeKey, so ONE bad row took
//     down the WHOLE fold. D6 calls a fold that reports a smaller, cleaner,
//     wrong world a defect; a fold that reports NO world because a single byte
//     rotted is worse, and it fails fatally in the one module that promises to
//     fail informatively (`unreadable[]`).
//   - a null row, a bare string, or a row with no subject silently keyed to the
//     empty pair and merged every malformed row into one bogus entry — garbage
//     accepted as a subject, the mirror defect.
//
// Both now land in `unreadable[]`, named, with file and index. Reported, never
// skipped, never fatal.
function usableRow(row) {
  if (row === null || typeof row !== "object" || Array.isArray(row)) return "a row must be a plain object";
  if (typeof row.subject !== "string" || row.subject.trim() === "") return "subject must be a non-empty string";
  if (typeof row.quantity !== "string" || row.quantity.trim() === "") return "quantity must be a non-empty string";
  if (typeof row.rerun !== "string" || row.rerun.trim() === "") return "rerun must be a non-empty string — the row IS the recipe";
  return null;
}

export function digest(text) {
  return createHash("sha256").update(text).digest("hex").slice(0, 16);
}

// ── writing: one new immutable file, never an existing one ───────────────────

// The default store. NOT gitignored — verified, and deliberately unlike
// tooling/research-coverage/research-ledger.json, which is (D10's trap).
export const DEFAULT_LEDGER_DIR = fileURLToPath(new URL("./ledger/", import.meta.url));

function serialize(runFile) {
  return `${JSON.stringify(runFile, null, 2)}\n`;
}

// writeLedgerRun({ run_id, recipes, dir, now, screen }) → one new file, or a
// named rejection.
//
// `now` and `screen` are forwarded to admitRecipe for every row. They are
// carried here rather than only on admitRecipe because THIS is the seam a
// forged row has to cross to become durable — a bound reachable only from the
// pure admission function would leave the write path exactly as forgeable as
// it was, which is the defect this slice exists to close.
//
// The file NAME is `<run_id>-<key>.json` where key is a digest of the admitted
// rows (D26's `<run>-<key>` shape). Content-addressing does two jobs: two
// writers sharing a run_id but writing different rows cannot collide, and a
// path collision therefore means the bytes are already identical, so the
// idempotent answer is "already recorded" rather than a write.
export function writeLedgerRun({ run_id, recipes, dir = DEFAULT_LEDGER_DIR, now, screen } = {}) {
  if (typeof run_id !== "string" || !RUN_ID.test(run_id)) {
    return { ok: false, rejections: [reject("BAD-RUN-ID", `run_id must match ${RUN_ID} — it is part of a filename, and it is supplied by the caller because this module has no clock and no random source to invent one`)] };
  }
  if (!Array.isArray(recipes) || recipes.length === 0) {
    return { ok: false, rejections: [reject("EMPTY-RUN", "a run file must carry at least one recipe — an empty file is a NULL-READ waiting to be folded as an absence")] };
  }

  const admitted = [];
  const rejections = [];
  recipes.forEach((row, index) => {
    const verdict = admitRecipe(row, { now, screen });
    if (verdict.ok) admitted.push(verdict.recipe);
    else rejections.push(...verdict.rejections.map((r) => ({ ...r, index })));
  });

  // All-or-nothing: a run file that quietly held the rows that happened to
  // pass would be the silent-strip defect at file granularity.
  if (rejections.length > 0) return { ok: false, rejections };

  const body = { run_id, recipes: admitted };
  const bytes = serialize(body);
  const key = digest(bytes);
  const path = join(dir, `${run_id}-${key}.json`);

  mkdirSync(dir, { recursive: true });

  if (existsSync(path)) {
    // Content-addressed, so this is the same bytes by construction. Verify
    // rather than assume, and NEVER open it for writing either way.
    const existing = readFileSync(path, "utf8");
    if (existing === bytes) return { ok: true, path, written: false, reason: "ALREADY-RECORDED", recipes: admitted };
    return { ok: false, rejections: [reject("IMMUTABLE-COLLISION", `${basename(path)} exists with different bytes — ledger files are never modified; nothing was written`)], path };
  }

  try {
    // "wx" — the immutability is enforced by the syscall, not by the check
    // above, which is racy on its own.
    writeFileSync(path, bytes, { encoding: "utf8", flag: "wx" });
  } catch (err) {
    if (err?.code === "EEXIST") {
      const existing = readFileSync(path, "utf8");
      if (existing === bytes) return { ok: true, path, written: false, reason: "ALREADY-RECORDED", recipes: admitted };
      return { ok: false, rejections: [reject("IMMUTABLE-COLLISION", `${basename(path)} appeared with different bytes during the write; nothing was modified`)], path };
    }
    return { ok: false, rejections: [reject("WRITE-FAILED", `${err?.message ?? String(err)}`)], path };
  }

  return { ok: true, path, written: true, recipes: admitted };
}

// ── reading ──────────────────────────────────────────────────────────────────

// readLedgerRuns(dir) → { runs, unreadable }
//
// A file that will not parse is REPORTED, never skipped. D6: an empty or
// failed read may not become an admissible negative claim, and a fold that
// silently drops a corrupt file is a fold that reports a smaller, cleaner,
// wrong world.
export function readLedgerRuns(dir = DEFAULT_LEDGER_DIR) {
  const runs = [];
  const unreadable = [];
  if (!existsSync(dir)) return { runs, unreadable };

  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort(); // deterministic: never readdir order

  for (const file of files) {
    const path = join(dir, file);
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(path, "utf8"));
    } catch (err) {
      unreadable.push({ file, reason: "UNPARSEABLE", message: `UNPARSEABLE: ${file} — ${err?.message ?? String(err)}` });
      continue;
    }
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.recipes)) {
      unreadable.push({ file, reason: "MALFORMED-RUN", message: `MALFORMED-RUN: ${file} has no recipes[] array` });
      continue;
    }
    runs.push({ file, run_id: typeof parsed.run_id === "string" ? parsed.run_id : null, recipes: parsed.recipes });
  }
  return { runs, unreadable };
}

// ── the fold ─────────────────────────────────────────────────────────────────

// foldLedger(dirOrRuns) → { entries, rival_methods, unreadable, stats }
//
// Every entry is one (subject, quantity) with EVERY recipe ever written for
// it. Nothing is superseded, nothing is deduplicated away, and write order is
// never consulted — there is no write order to consult.
//
// RIVAL-METHOD is two or more DISTINCT `rerun` commands over one key: two ways
// to re-derive the same property, both kept and both flagged. READ IT AS THE
// PRODUCT — "this key has more than one cheap check; re-run them and compare
// what they answer NOW" — never as a report that something is broken. Rival
// methods that AGREE are the most valuable rows in the store, and this fold
// cannot tell agreement from disagreement anyway: it has no value field to
// compare, by design. (Deciding whether two answers disagree is
// adjudicate.mjs's job, over facts in flight, on a completely different input.
// See the header for why the two must not share a name.)
//
// The same command recorded twice is CORROBORATION and is not flagged —
// a flag that fires on ordinary repetition is ignored within a wave.
export function foldLedger(source = DEFAULT_LEDGER_DIR) {
  const { runs, unreadable } = Array.isArray(source)
    ? { runs: source, unreadable: [] }
    : readLedgerRuns(source);

  const byKey = new Map();
  let rowCount = 0;

  for (const run of runs) {
    run.recipes.forEach((row, index) => {
      const bad = usableRow(row);
      if (bad !== null) {
        // Reported at row granularity, with enough to find it by hand. The
        // fold continues: one rotten row must never cost the other files.
        unreadable.push({
          file: run.file,
          index,
          reason: "MALFORMED-ROW",
          message: `MALFORMED-ROW: ${run.file} row ${index} — ${bad}. The row is NOT folded; every other row is.`,
        });
        return;
      }
      rowCount += 1;
      const key = recipeKey(row);
      if (!byKey.has(key)) {
        byKey.set(key, {
          key,
          subject: (row?.subject ?? "").trim(),
          quantity: (row?.quantity ?? "").trim(),
          recipes: [],
        });
      }
      byKey.get(key).recipes.push({
        rerun: row?.rerun ?? null,
        derived_level: row?.derived_level ?? null,
        deps: Array.isArray(row?.deps) ? row.deps : [],
        observed_at: row?.observed_at ?? null,
        run_id: run.run_id,
        file: run.file,
      });
    });
  }

  const entries = [...byKey.values()].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  const rivalMethods = [];

  for (const entry of entries) {
    // Deterministic ordering INSIDE an entry too — by (observed_at, file), so
    // the fold reads the same on any machine. Presentation only: it confers no
    // precedence, and the RIVAL-METHOD flag does not consult it.
    //
    // Normalised through comparableInstant for the same reason the future
    // bound is: without it a `.001Z` row sorts BEFORE the whole-second row it
    // actually followed. Guarded, because THE WRITE PATH IS NOT THE READ PATH
    // — an off-shape observed_at that admitRecipe would reject can still be in
    // a file, and it falls back to raw string order rather than throwing.
    const sortKey = (v) => {
      const s = String(v);
      return UTC_INSTANT.test(s) ? comparableInstant(s) : s;
    };
    entry.recipes.sort((a, b) => {
      const t = sortKey(a.observed_at).localeCompare(sortKey(b.observed_at));
      return t !== 0 ? t : String(a.file).localeCompare(String(b.file));
    });

    const rivals = [...new Set(entry.recipes.map((r) => String(r.rerun).trim()))];
    entry.distinct_reruns = rivals.length;
    entry.rival_method = rivals.length > 1;

    if (entry.rival_method) {
      const flag = {
        reason: RIVAL_METHOD,
        key: entry.key,
        subject: entry.subject,
        quantity: entry.quantity,
        rivals,
        recipes: entry.recipes,
        message: `${RIVAL_METHOD}: ${rivals.length} independent recipes re-derive ${JSON.stringify(entry.quantity)} of ${JSON.stringify(entry.subject)}. This is a FEATURE of the row, not a defect report — all ${rivals.length} are kept and none wins by arrival order, because there is no write order here. Spend it: run all ${rivals.length} today and compare what they answer NOW.`,
      };
      entry.flag = flag;
      rivalMethods.push(flag);
    }
  }

  return {
    entries,
    rival_methods: rivalMethods,
    unreadable,
    stats: {
      runs: runs.length,
      rows: rowCount,
      subjects: entries.length,
      rival_methods: rivalMethods.length,
      unreadable: unreadable.length,
    },
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

// `--selftest` is the D18 obligation: a control must be shown able to FIRE,
// and a control that did NOT fire gets its own outcome class (exit 3) rather
// than being absorbed into a normal pass.
function selftest() {
  const controls = [
    ["a row carrying `value` is rejected VALUE-STORED", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "git show origin/main:README.md", observed_at: "2026-07-20T00:00:00Z", value: 42 });
      return !v.ok && v.rejections.some((r) => r.reason === "VALUE-STORED");
    }],
    ["an unknown field is rejected, not stripped", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-20T00:00:00Z", notes: "hi" });
      return !v.ok && v.rejections.some((r) => r.reason === "UNKNOWN-FIELD");
    }],
    ["a missing observed_at is rejected (the module has no clock to fill it)", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md" });
      return !v.ok && v.rejections.some((r) => r.reason === "MISSING-OBSERVED-AT");
    }],
    ["an over-claimed derived_level is rejected LEVEL-SKIP", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md", derived_level: "L1", observed_at: "2026-07-20T00:00:00Z" });
      return !v.ok && v.rejections.some((r) => r.reason === "LEVEL-SKIP");
    }],
    ["a future observed_at is rejected FUTURE-OBSERVED-AT against an injected now", () => {
      // The forgery, verbatim: an ssh-shaped command dated 2031, admitted
      // before this bound existed for the sole reason that it was well-shaped.
      const v = admitRecipe(
        { subject: "bp-crux-parent", quantity: "unit state", rerun: "ssh barkpark_indx@157.180.90.121 systemctl is-active bp-crux-parent", observed_at: "2031-12-31T23:59:59Z" },
        { now: "2026-07-21T00:00:00Z" },
      );
      return !v.ok && v.rejections.some((r) => r.reason === "FUTURE-OBSERVED-AT");
    }],
    ["the same forged row is ADMITTED with no now supplied — the bound is opt-in, and the CLI is what closes it", () => {
      const v = admitRecipe({ subject: "bp-crux-parent", quantity: "unit state", rerun: "ssh barkpark_indx@157.180.90.121 systemctl is-active bp-crux-parent", observed_at: "2031-12-31T23:59:59Z" });
      return v.ok;
    }],
    ["a row a MILLISECOND in the future is rejected too — raw lexical order puts \".001Z\" before \"Z\"", () => {
      const v = admitRecipe(
        { subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-21T00:00:00.001Z" },
        { now: "2026-07-21T00:00:00Z" },
      );
      return !v.ok && v.rejections.some((r) => r.reason === "FUTURE-OBSERVED-AT");
    }],
    ["an offset observed_at is rejected OFFSET-OBSERVED-AT (lexical order is only true order at one offset)", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-21T02:00:00+02:00" });
      return !v.ok && v.rejections.some((r) => r.reason === "OFFSET-OBSERVED-AT");
    }],
    ["an outage-capable command is rejected REFUSED-COMMAND by an injected screen", () => {
      const screen = (cmd) => (/\bsystemctl\s+(stop|restart)\b|\brm\s+-rf\b/.test(cmd) ? { ok: false, message: "it can take something down" } : true);
      const refused = ["systemctl stop bp-crux-parent", "rm -rf /opt/barkpark/releases"].every((rerun) => {
        const v = admitRecipe({ subject: "s", quantity: "q", rerun, observed_at: "2026-07-20T00:00:00Z" }, { screen });
        return !v.ok && v.rejections.some((r) => r.reason === "REFUSED-COMMAND");
      });
      // …and the SAME commands admit with no screen: the rejection is the
      // screen's doing, not some other rule that happened to fire.
      const admittedUnscreened = admitRecipe({ subject: "s", quantity: "q", rerun: "systemctl stop bp-crux-parent", observed_at: "2026-07-20T00:00:00Z" }).ok;
      return refused && admittedUnscreened;
    }],
    ["a screen that THROWS fails closed (SCREEN-FAILED), never open", () => {
      const v = admitRecipe(
        { subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-20T00:00:00Z" },
        { screen: () => { throw new Error("boom"); } },
      );
      return !v.ok && v.rejections.some((r) => r.reason === "SCREEN-FAILED");
    }],
    ["an ASYNC screen is diagnosed SCREEN-NOT-SYNC, not reported as a refusal", () => {
      // Fail-closed either way; the point is the DIAGNOSIS. Under the tolerant
      // branch a Promise is neither `true` nor `{ok:true}`, so every row would
      // have been refused REFUSED-COMMAND and whoever wired the CLI would have
      // gone hunting an over-aggressive screen rather than a wrong signature.
      const v = admitRecipe(
        { subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-20T00:00:00Z" },
        { screen: async () => true },
      );
      return !v.ok && v.rejections.some((r) => r.reason === "SCREEN-NOT-SYNC");
    }],
    ["a malformed bound is rejected BAD-OPTION rather than silently not bounding", () => {
      const badNow = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-20T00:00:00Z" }, { now: "yesterday" });
      const badScreen = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-20T00:00:00Z" }, { screen: "deny-all" });
      return !badNow.ok && badNow.rejections.some((r) => r.reason === "BAD-OPTION" && r.option === "now")
        && !badScreen.ok && badScreen.rejections.some((r) => r.reason === "BAD-OPTION" && r.option === "screen");
    }],
    ["the fold flags two rival methods over one key as RIVAL-METHOD", () => {
      const runs = [
        { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "cat a", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
        { file: "b.json", run_id: "b", recipes: [{ subject: "s", quantity: "q", rerun: "cat b", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
      ];
      const folded = foldLedger(runs);
      return folded.rival_methods.length === 1 && folded.rival_methods[0].reason === "RIVAL-METHOD";
    }],
    ["a rotten on-disk row is reported, and does not take the fold down with it", () => {
      const folded = foldLedger([
        { file: "good.json", run_id: "g", recipes: [{ subject: "s", quantity: "q", rerun: "cat a", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
        { file: "rot.json", run_id: "r", recipes: [{ subject: 42, quantity: "q", rerun: "cat a" }, null] },
      ]);
      return folded.entries.length === 1 && folded.unreadable.length === 2
        && folded.unreadable.every((u) => u.reason === "MALFORMED-ROW");
    }],
    ["an honest row is ADMITTED (the control does not just say no to everything)", () => {
      const v = admitRecipe({ subject: "api/lib/x.ex", quantity: "line count", rerun: "wc -l api/lib/x.ex", deps: [], observed_at: "2026-07-20T00:00:00Z" });
      return v.ok && !Object.hasOwn(v.recipe, "value");
    }],
    ["an honest row is STILL admitted with BOTH bounds armed — the new classes reject forgeries, not work", () => {
      const v = admitRecipe(
        { subject: "api/lib/x.ex", quantity: "line count", rerun: "wc -l api/lib/x.ex", deps: [], observed_at: "2026-07-20T00:00:00Z" },
        { now: "2026-07-21T00:00:00Z", screen: (cmd) => !/\brm\s+-rf\b/.test(cmd) },
      );
      return v.ok && v.recipe.observed_at === "2026-07-20T00:00:00Z";
    }],
  ];

  let fired = 0;
  for (const [name, fn] of controls) {
    let ok = false;
    try { ok = fn() === true; } catch { ok = false; }
    process.stdout.write(`${ok ? "fired " : "SILENT"}  ${name}\n`);
    if (ok) fired += 1;
  }
  if (fired === controls.length) {
    process.stdout.write(`\nselftest: ${fired}/${controls.length} controls fired\n`);
    return 0;
  }
  process.stdout.write(`\nCONTROL DID NOT BEHAVE AS A CONTROL — ${controls.length - fired} of ${controls.length} stayed silent\n`);
  return 3;
}

// ── the write verb ───────────────────────────────────────────────────────────

// THE CLOCK IS THE SHELL'S, AND IT IS READ HERE AND NOWHERE ELSE.
//
// This module reads no clock (D19 — the workflow host refuses the clock
// builtins outright because they break resume), and `now`/`observed_at` are
// caller-supplied by design. The CLI is the caller, so the CLI reads
// `date -u` and supplies both from ONE reading. Sourcing observed_at here
// rather than from the input JSON is what turns tgw3-ledger-honesty's opt-in
// bound into a real seam: forging a timestamp now takes editing this file,
// not editing a payload.
//
// CEILING, STATED HONESTLY (D4). A forger who controls the caller controls the
// bound. This stops accidents, staleness and sloppiness — not a determined
// forger. Authorship is out of jurisdiction.
function shellNow() {
  return execFileSync("date", ["-u", "+%Y-%m-%dT%H:%M:%SZ"], { encoding: "utf8" }).trim();
}

// RUN_ID is a filename fragment and rejects `:` — so the raw `date -u` string
// CANNOT be a run_id, and a naive `run_id: now` write fails BAD-RUN-ID. The
// sanitisation is load-bearing, and test/mint.test.mjs proves the raw form is
// refused so it cannot be quietly dropped later.
export function mintRunId(utcInstant) {
  return `grip-${String(utcInstant ?? "").trim().replace(/[-:]/g, "")}`;
}

// ONE loader for both facts-taking verbs. `prescreen` exists to tell a writer
// what `write` will do, so a second loader that disagreed on what a facts file
// IS would make the rehearsal answer a different question than the run.
function loadFacts(factsPath, usage) {
  if (!factsPath) {
    process.stderr.write(`ledger: ${usage}\n`);
    return { ok: false, code: 2 };
  }
  const resolved = resolve(factsPath);
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(resolved, "utf8"));
  } catch (err) {
    process.stderr.write(`ledger: ${resolved} is not readable JSON — ${err?.message ?? String(err)}\n`);
    return { ok: false, code: 2 };
  }
  // Both shapes, matching cli.mjs's loader exactly — a bare array or {facts}.
  const facts = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.facts) ? parsed.facts : null;
  if (facts === null) {
    process.stderr.write(`ledger: ${resolved} must be a JSON array of facts, or an object with a "facts" array\n`);
    return { ok: false, code: 2 };
  }
  return { ok: true, facts, resolved };
}

async function writeCommand(rest) {
  const [factsPath, dirArg] = rest;
  const loaded = loadFacts(factsPath, "write needs a facts file — node ledger.mjs write <facts.json> [dir]");
  if (!loaded.ok) return loaded.code;
  const facts = loaded.facts;

  const now = shellNow();
  const { mintAll } = await import("./mint.mjs");
  // Injected, never imported by the library half — the README's promise that
  // ledger.mjs itself depends on nothing in screen.mjs stays true, because the
  // dependency lives in this CLI branch alone.
  const { screenCommand: screen } = await import("./screen.mjs");

  const { recipes, skipped, yield: mintYield } = mintAll(facts, { observed_at: now });
  const dir = dirArg ? resolve(dirArg) : DEFAULT_LEDGER_DIR;

  process.stdout.write(`ledger write — now ${now} (read from \`date -u\`, never from the input)\n`);
  process.stdout.write(`  facts read           ${mintYield.facts}\n`);
  process.stdout.write(`  minted               ${mintYield.rerun_bearing}\n`);
  process.stdout.write(`  subject from PATH    ${mintYield.path_token} (${mintYield.path_token_pct}% of minted) ← the coverage number\n`);
  process.stdout.write(`  subject from cmd:    ${mintYield.fallback} (${mintYield.fallback_pct}% of minted) ← a FLOOR, not coverage; never add these together and call it yield\n`);
  process.stdout.write(`  distinct subjects    ${mintYield.distinct_subjects}\n`);
  for (const s of skipped) process.stdout.write(`  skipped[${s.index}]         ${s.reason}\n`);

  if (recipes.length === 0) {
    process.stderr.write("ledger: nothing mintable — no fact carried a rerun command\n");
    return 1;
  }

  const run_id = mintRunId(now);
  const result = writeLedgerRun({ run_id, recipes, dir, now, screen });
  if (!result.ok) {
    const byClass = new Map();
    for (const r of result.rejections) byClass.set(r.reason, (byClass.get(r.reason) ?? 0) + 1);
    process.stderr.write(`\nREJECTED — nothing was written (all-or-nothing: a file holding only the rows that happened to pass IS the silent-strip defect at file granularity)\n`);
    for (const [reason, count] of byClass) process.stderr.write(`  ${reason} x${count}\n`);
    for (const r of result.rejections.slice(0, 10)) process.stderr.write(`  row ${r.index}: ${r.message}\n`);
    return 1;
  }
  process.stdout.write(`\n${result.written ? "wrote" : "already recorded"}  ${result.path}\n`);
  process.stdout.write(`  run_id ${run_id} — sanitised from the \`date -u\` stamp; the raw form carries colons and RUN_ID rejects it\n`);
  process.stdout.write(`  ${result.recipes.length} rows admitted, 0 rejected\n`);
  return 0;
}

// ── the prescreen verb ───────────────────────────────────────────────────────

// WHY THIS EXISTS (charter D64). `write` is ALL-OR-NOTHING, and that is correct
// — a run file holding only the rows that happened to pass IS the silent-strip
// defect at file granularity. But correct is not the same as learnable: nine
// refusals discarded all 22 rows, exit 1, nothing written, and there was no
// cheap way to find out first. `prescreen` is the rehearsal. It reports a
// per-row verdict and WRITES NOTHING — no run file, no directory, no mkdir.
//
// THE VERDICT KEY IS `.ok`, NOT `.safe`. screenCommand returns
// `{ ok, reason }`. A verifier read `.safe`, got `undefined`, scored 0 of 40
// rows refused — and the carried reason string still read "admitted", so the
// mistake rendered as its own opposite: a screen reporting total refusal while
// explaining that everything was admitted. test/leads.test.mjs pins the shape.
async function prescreenCommand(rest) {
  const [factsPath] = rest;
  const loaded = loadFacts(factsPath, "prescreen needs a facts file — node ledger.mjs prescreen <facts.json>");
  if (!loaded.ok) return loaded.code;

  const { mintAll } = await import("./mint.mjs");
  const { screenCommand } = await import("./screen.mjs");

  // The clock is read for the same reason `write` reads it — so the rehearsal
  // mints exactly what the run would mint. Nothing is stored either way.
  const now = shellNow();
  const { recipes, skipped, yield: mintYield } = mintAll(loaded.facts, { observed_at: now });

  const verdicts = recipes.map((recipe, index) => {
    const screened = screenCommand(recipe.rerun);
    // `.ok` — see the note above. Never `.safe`.
    return { index, subject: recipe.subject, rerun: recipe.rerun, ok: screened.ok === true, reason: screened.reason };
  });
  const refused = verdicts.filter((v) => !v.ok);

  process.stdout.write(`ledger prescreen — ${loaded.resolved}\n`);
  process.stdout.write("  WRITES NOTHING: this is a rehearsal of `write`, not a partial write (charter D64)\n\n");
  process.stdout.write(`  facts read       ${mintYield.facts}\n`);
  process.stdout.write(`  mintable         ${mintYield.rerun_bearing}\n`);
  process.stdout.write(`  screen admits    ${verdicts.length - refused.length}\n`);
  process.stdout.write(`  screen refuses   ${refused.length}\n`);
  for (const s of skipped) process.stdout.write(`  unmintable[${s.index}]   ${s.reason} — this row never reaches the screen\n`);

  if (verdicts.length > 0) {
    process.stdout.write("\n");
    for (const v of verdicts) {
      process.stdout.write(`  ${v.ok ? "ADMIT " : "REFUSE"} [${v.index}] ${v.subject}\n`);
      process.stdout.write(`         $ ${v.rerun}\n`);
      process.stdout.write(`         ${v.reason}\n`);
    }
  }

  if (mintYield.rerun_bearing === 0) {
    process.stdout.write("\n  nothing mintable — no fact carried a rerun command, so `write` would refuse this file outright\n");
    return 1;
  }
  if (refused.length > 0) {
    process.stdout.write(`\n  \`write\` WOULD REFUSE THIS FILE and store nothing: ${refused.length} of ${verdicts.length} rows are refused,\n`);
    process.stdout.write("  and the write is all-or-nothing on purpose. Fix or drop those rows, then re-run prescreen.\n");
    return 1;
  }
  process.stdout.write(`\n  all ${verdicts.length} rows pass the screen — \`write\` would store one run file. Nothing was stored by this run.\n`);
  return 0;
}

// ── the leads verb ───────────────────────────────────────────────────────────

async function leadsCommand(rest) {
  const args = [...rest];
  const takeFlag = (name) => {
    const i = args.indexOf(name);
    if (i < 0) return null;
    const value = args[i + 1];
    args.splice(i, value === undefined ? 1 : 2);
    return value ?? null;
  };
  const asJson = args.includes("--json");
  const censusPath = takeFlag("--census");
  const dirArg = takeFlag("--dir");
  const query = args.filter((a) => !a.startsWith("--")).join(" ").trim();

  if (query === "") {
    process.stderr.write("ledger: leads needs a substring — node ledger.mjs leads <substring> [--json] [--census <report.json>] [--dir <ledger dir>]\n");
    process.stderr.write("  it matches case-insensitively over the subject and the rerun command; that filter IS the feature\n");
    return 2;
  }

  const { selectLeads, renderLeads, loadCensusIndex } = await import("./leads.mjs");

  let census = null;
  if (censusPath !== null) {
    if (!censusPath) {
      process.stderr.write("ledger: --census needs a path to a `census --json` report\n");
      return 2;
    }
    try {
      census = loadCensusIndex(resolve(censusPath));
    } catch (err) {
      process.stderr.write(`ledger: ${resolve(censusPath)} is not a readable census --json report — ${err?.message ?? String(err)}\n`);
      return 2;
    }
  }

  const folded = foldLedger(dirArg ? resolve(dirArg) : DEFAULT_LEDGER_DIR);
  const result = selectLeads(folded, query, { census });
  process.stdout.write(asJson ? `${JSON.stringify(result, null, 2)}\n` : renderLeads(result));
  // An honest empty is an ANSWER, not an error — exit 0. A nonzero here would
  // teach callers to treat "nobody has checked this yet" as a failure.
  return 0;
}

async function main(argv) {
  const [cmd = "fold", ...rest] = argv;
  if (cmd === "--selftest" || cmd === "selftest") return selftest();
  if (cmd === "write") return writeCommand(rest);
  if (cmd === "prescreen") return prescreenCommand(rest);
  if (cmd === "leads") return leadsCommand(rest);
  if (cmd === "fold") {
    const dir = rest[0] ? resolve(rest[0]) : DEFAULT_LEDGER_DIR;
    const folded = foldLedger(dir);
    process.stdout.write(`${JSON.stringify(folded, null, 2)}\n`);
    // RIVAL-METHOD is a feature of the data, not a failure: both rows are
    // legitimately stored. Exit 0 and let the caller read `rival_methods`.
    return folded.unreadable.length > 0 ? 1 : 0;
  }
  process.stderr.write("usage: node ledger.mjs [leads <substring> | prescreen <facts.json> | write <facts.json> [dir] | fold [dir] | --selftest]\n");
  process.stderr.write("  leads      look up RECIPES by case-insensitive substring over subject and rerun — never an answer\n");
  process.stderr.write("             [--json] [--census <census --json report>] [--dir <ledger dir>]\n");
  process.stderr.write("  prescreen  rehearse a write: report the per-row screen verdict and store NOTHING\n");
  process.stderr.write("  write      mint {claim,evidence,rerun} facts into recipe rows and store one immutable run file\n");
  process.stderr.write("  fold       read every run file in the store back as one index\n");
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  // `main` became async when `write` landed (it dynamically imports mint.mjs
  // and screen.mjs). An unhandled rejection is a NAMED failure here, never a
  // bare stack trace and never a silent exit: a store whose CLI dies quietly
  // is indistinguishable from a store that wrote nothing on purpose.
  main(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`ledger: crashed before any write — ${err?.stack ?? err?.message ?? String(err)}\n`);
      process.exit(2);
    });
}
