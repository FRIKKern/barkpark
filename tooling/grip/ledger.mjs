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
// THE FOLD RE-DERIVES ITS OWN KEY, so it needs the minter's grammar. Static,
// and it creates NO cycle: mint.mjs imports nothing at all (verified — the file
// has zero `import` lines), which is exactly why it can be depended on from the
// durable half without moving this module's "depends on level.mjs and nothing
// else" property into a lie. Read the fold's header for WHY the key is
// re-derived rather than trusted.
import { quantityPhrase } from "./mint.mjs";

// The SELF-PROVENANCE banner (D78). Static and side-effect-free on import: it
// only prints when a verb calls it, on STDERR, so every verb — leads, fold,
// prescreen, write — inherits one honest "here is which tree answered you"
// line without any of them re-deriving it. Read provenance.mjs for why the
// banner is stderr-only: stdout is the verb's answer and a banner in it would
// corrupt a `| JSON.parse` the moment a caller piped the fold.
import { emitProvenance } from "./provenance.mjs";

// THE FOLD'S DEFAULT SCREEN. Static, and it creates NO cycle: screen.mjs
// imports only `node:path` and `node:url` and nothing from grip (verified), and
// its CLI arm is behind the same `process.argv[1]` main-guard this module uses,
// so importing it runs nothing. It is here so that `foldLedger` can DEFAULT the
// screen bound on — see the fold's ARMING header for the measured reason a
// library read that was silently unscreened is a defect and not a convenience.
import { screenCommand } from "./screen.mjs";

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
//     "depends only on PURE grammar modules" property, and so the safety
//     vocabulary can evolve without the durable store moving. Nothing here
//     imports `screen.mjs`; the CLI is what wires the two together. (The
//     property is "level.mjs and mint.mjs, both of which import nothing, read
//     no clock and touch no filesystem" — screen.mjs is a POLICY module whose
//     vocabulary is meant to move, which is the whole reason it is injected.)
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

// ── the key is RE-DERIVED, never read from storage ───────────────────────────
//
// THE MEASURED DEFECT. `quantity` is minted from the rerun command by
// mint.mjs's `quantityPhrase`, and that grammar MOVED: before its defect 8 was
// fixed, `git show P | wc -l` and `git show P | grep -c x` both minted
// `git:show`. 57 of the 62 committed rows (91.9%) still carry a quantity the
// merged mint no longer produces — and because a row on disk is IMMUTABLE by
// construction (wx/O_EXCL, no update verb, no delete verb, and an appended
// correction becomes a RIVAL rather than a supersession), not one of those
// bytes can be corrected in place.
//
// Folding on the stored value therefore made the shipping product lie: the
// fold announced 4 RIVAL-METHOD keys, and `census --ledger` printed "9 recipes
// for git:show of .claude/workflows/bp-epic-cycle.workflow.js" — nine
// unrelated questions rendered as nine rival ways to answer ONE. `leads
// tasks_next_cmd` handed an agent a LINE COUNT and a MATCH COUNT under "run
// both and compare".
//
// THE FIX IS THE LAW THIS EPIC ALREADY LIVES BY, ONE LAYER UP. leads.mjs
// re-derives the LEVEL from the command at render time and never trusts
// `recipe.derived_level`; this does the same for the KEY. Nothing on disk
// moves, no field is added to any row, `admitRecipe` still REQUIRES a stored
// quantity — the stored value simply stops being the key and becomes a DRIFT
// SIGNAL (`stored_quantity` + `quantity_restated`, the exact pair leads uses
// for `stored_level` / `level_restated`).
//
// THE FALLBACK IS MARKED, NEVER SILENT. If `quantityPhrase` cannot mint from a
// row's command the stored value is used — and the row carries
// `quantity_fallback` naming why, with `stats.quantity_fallbacks` counting it.
// A silent fallback is the silent-strip defect (research-coverage's `record()`
// dropping unknown fields, half of D10's trap) wearing a different hat: the
// fold would key on one thing while its output implied the other, with no
// signal anywhere.
//
// This does NOT narrow RIVAL-METHOD out of existence — it narrows it to REAL
// rivals. Two genuinely distinct commands that mint the SAME quantity
// (`wc -l F` and `cat F | wc -l` — mint.mjs's own stated control) still collide
// and still flag; the tests below hold that control, because a fix that made
// the flag unfireable would have broken it rather than fixed it.

// restateQuantity(row) → { quantity, stored_quantity, quantity_restated, quantity_fallback }
//
// `quantity` is what the fold KEYS ON. `quantity_fallback` is null on a normal
// row and a reason string when the re-derivation could not answer.
export function restateQuantity(row) {
  const stored = typeof row?.quantity === "string" ? row.quantity.trim() : "";
  let minted = null;
  let fallback = null;
  try {
    const phrase = quantityPhrase(row?.rerun);
    if (typeof phrase === "string" && phrase.trim() !== "") minted = phrase.trim();
    else fallback = `the mint could not derive a quantity from this command (quantityPhrase returned ${JSON.stringify(phrase)}) — the STORED quantity is the key for this row instead`;
  } catch (err) {
    fallback = `the mint THREW on this command (${err?.message ?? String(err)}) — the STORED quantity is the key for this row instead`;
  }
  if (minted === null) {
    return { quantity: stored, stored_quantity: stored, quantity_restated: false, quantity_fallback: fallback };
  }
  return { quantity: minted, stored_quantity: stored, quantity_restated: stored !== minted, quantity_fallback: null };
}

// restateLevel(row) → { derived_level, stored_level, level_restated, level_fallback }
//
// CLOSES `tgw2-fold-reread-derived-level`. The fold trusted the stored
// `derived_level`, which is a claim made by whichever version of level.mjs was
// loaded on the day of the write — the same staleness class as the quantity,
// one field over. leads.mjs already refused to inherit it and re-derived at
// RENDER time; the fold now does it once at the SEAM, so every consumer gets
// the re-derived value and the stored one survives as `stored_level`.
export function restateLevel(row) {
  const stored = row?.derived_level ?? null;
  let derived = null;
  let fallback = null;
  try {
    const level = deriveLevel(row?.rerun);
    if (typeof level === "string" && level.trim() !== "") derived = level.trim();
    else fallback = `deriveLevel returned ${JSON.stringify(level)} for this command — the STORED level is being reported instead`;
  } catch (err) {
    fallback = `deriveLevel THREW on this command (${err?.message ?? String(err)}) — the STORED level is being reported instead`;
  }
  if (derived === null) {
    return { derived_level: stored, stored_level: stored, level_restated: false, level_fallback: fallback };
  }
  return { derived_level: derived, stored_level: stored, level_restated: stored !== null && stored !== derived, level_fallback: null };
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

// THE THREE SHAPES IN THE COMMONS, AND THE ONE THAT IS NOT A DEFECT.
//
// `tooling/grip/ledger/` is a SHARED APPEND-ONLY commons (D118): four epics
// write into it and none of them may delete another's rows. Measured over the
// committed store, it holds three shapes and only one of them is grip's:
//
//   NOT-A-RUN   a well-formed JSON document that is not a run file at all —
//               no `recipes[]`. Foreign verifier notes, wave digests, spec
//               dumps. These are NOT corrupt; they were never run files. They
//               used to be reported as MALFORMED-RUN, which read as "grip's
//               store is rotting" when the true statement is "another epic
//               parked a note here."
//   MALFORMED-RUN  a document that claims the run shape and fails it — null,
//               an array, a scalar, or `recipes` present but not an array.
//               THIS one is a defect report.
//   a run       `recipes[]` present. `run_id` present as a string makes it
//               grip-OWNED; absent makes it a FOREIGN `{claim, rerun}` row set
//               written by an epic that borrowed the directory.
//
// Splitting the first two is a RENAME PLUS A SPLIT, not a repair: it moves 11
// of 422 unreadable entries out of the defect class and into a named,
// separately-counted one. Both counts stay in the fold's own output
// (`stats.not_a_run` / `stats.malformed_run`) — a class that is invisible on
// pass is a class that gets quietly emptied.
//
// THE RULING ON THE TWO RECIPE-SHAPED-BUT-UNWRAPPED FILES. Two of the eleven
// NOT-A-RUN files (grip-20260723T000000Z-v-premise-smoke-canonical-lines.json,
// grip-20260723T000100Z-v-premise-smoke-block-count.json) carry a SINGLE
// recipe's fields at top level — subject/quantity/rerun/derived_level/deps/
// observed_at — with no wrapper and no `run_id`. They stay NOT-A-RUN, and the
// choice is deliberate: a fold that infers the wrapper invents the one thing
// the row does not have, its chain of custody. R1 says a fact records the
// level it was READ at; a run_id this module synthesises at READ time is an
// L6 claim wearing an L2 uniform. The append-only-legal repair is to RE-RECORD
// those two rows through `writeLedgerRun` (a new file, nothing deleted), which
// is filed as `tgw11-bl-unwrapped-recipe-rows-unread`. Naming the class is what
// makes them findable instead of lost inside a corruption count.
const RUN_SHAPES = Object.freeze(["all", "owned", "attested"]);

// isAttestedRun(file, parsed) → boolean
//
// THE WRITE PATH SIGNS ITS OWN OUTPUT, and the signature is the FILENAME.
// `writeLedgerRun` names every file it writes `<run_id>-<digest of the exact
// serialised body>.json`, so a file whose name reproduces the digest of its own
// bytes DEMONSTRABLY came out of `writeLedgerRun` — which means every one of
// its rows crossed `admitRecipe` at write time. A hand-authored run file cannot
// accidentally have that name.
//
// This is the discriminator the three folding tests scope by, and it is a SHAPE
// check computed from the file's own bytes — never a pinned list of filenames.
// A pin goes stale silently and green; this grows with the store by
// construction, because every new honestly-written run attests automatically.
export function isAttestedRun(file, parsed) {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return false;
  if (typeof parsed.run_id !== "string" || !Array.isArray(parsed.recipes)) return false;
  const keys = Object.keys(parsed).sort();
  if (keys.length !== 2 || keys[0] !== "recipes" || keys[1] !== "run_id") return false;
  return file === `${parsed.run_id}-${digest(serialize({ run_id: parsed.run_id, recipes: parsed.recipes }))}.json`;
}

// readLedgerRuns(dir) → { runs, unreadable, shape }
//
// A file that will not parse is REPORTED, never skipped. D6: an empty or
// failed read may not become an admissible negative claim, and a fold that
// silently drops a corrupt file is a fold that reports a smaller, cleaner,
// wrong world.
//
// Every run carries its own provenance flags — `owned` (grip wrote a run_id)
// and `attested` (the write path signed the filename) — so a caller can scope
// by SHAPE without re-reading the directory or hardcoding a file list.
export function readLedgerRuns(dir = DEFAULT_LEDGER_DIR) {
  const runs = [];
  const unreadable = [];
  const shape = { files: 0, runs: 0, owned: 0, attested: 0, foreign: 0, not_a_run: 0, malformed_run: 0, unparseable: 0 };
  if (!existsSync(dir)) return { runs, unreadable, shape };

  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort(); // deterministic: never readdir order

  for (const file of files) {
    shape.files += 1;
    const path = join(dir, file);
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(path, "utf8"));
    } catch (err) {
      shape.unparseable += 1;
      unreadable.push({ file, reason: "UNPARSEABLE", scope: "file", message: `UNPARSEABLE: ${file} — ${err?.message ?? String(err)}` });
      continue;
    }
    const isObject = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
    // CLAIMS the run shape = carries `run_id` or `recipes` at all. A document
    // carrying NEITHER never claimed to be a run and is not a defect report.
    const claimsRun = isObject && ("run_id" in parsed || "recipes" in parsed);
    if (!isObject || claimsRun) {
      if (!isObject || !Array.isArray(parsed.recipes)) {
        shape.malformed_run += 1;
        unreadable.push({ file, reason: "MALFORMED-RUN", scope: "file", message: `MALFORMED-RUN: ${file} claims the run shape and fails it — recipes must be an array` });
        continue;
      }
    } else {
      shape.not_a_run += 1;
      unreadable.push({ file, reason: "NOT-A-RUN", scope: "file", message: `NOT-A-RUN: ${file} has no recipes[] and no run_id — it never claimed to be a run. A foreign document in the shared commons, REPORTED so it stays findable, and not folded` });
      continue;
    }
    const owned = typeof parsed.run_id === "string";
    const attested = isAttestedRun(file, parsed);
    shape.runs += 1;
    if (owned) shape.owned += 1; else shape.foreign += 1;
    if (attested) shape.attested += 1;
    runs.push({ file, run_id: owned ? parsed.run_id : null, owned, attested, recipes: parsed.recipes });
  }
  return { runs, unreadable, shape };
}

// inScope(run, scope) — the ONE shape predicate every scoped reader shares.
// "owned" is `Array.isArray(recipes) && typeof run_id === "string"`, already
// decided by readLedgerRuns; "attested" adds the write-path signature.
export function inScope(run, scope = "all") {
  if (!RUN_SHAPES.includes(scope)) throw new Error(`unknown ledger scope ${JSON.stringify(scope)} — one of ${RUN_SHAPES.join(", ")}`);
  if (scope === "all") return true;
  if (scope === "owned") return run?.owned === true;
  return run?.attested === true;
}

// ── the fold ─────────────────────────────────────────────────────────────────

// foldLedger(dirOrRuns) → { entries, rival_methods, unreadable, stats }
//
// Every entry is one (subject, quantity) with EVERY recipe ever written for
// it. Nothing is superseded, nothing is deduplicated away, and write order is
// never consulted — there is no write order to consult.
//
// THE QUANTITY HALF OF THAT KEY IS RE-DERIVED FROM THE COMMAND, NOT READ FROM
// THE ROW, and so is `derived_level`. Both stored values ride along as
// `stored_quantity` / `stored_level` with a `*_restated` flag, and a
// re-derivation that cannot answer falls back to the stored value under a
// NAMED `*_fallback` marker. See "the key is RE-DERIVED" above for the measured
// defect this closes — 57 of 62 committed rows carry a quantity the merged mint
// no longer produces, and the store is immutable by construction.
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
// `now` and `screen` are the SAME two bounds admitRecipe takes on the write
// path, and they are here for the same reason: without a clock the future bound
// cannot fire, and without a screen an outage-capable recipe cannot be caught.
// THE WRITE PATH IS NOW THE READ PATH for admission: the fold COMPOSES
// admitRecipe rather than re-deriving any rejection class, so a sixth hand-copy
// of the grammar — this epic's own defect — is impossible by construction.
//
// ── ARMING: THE TWO BOUNDS ARE NOT THE SAME KIND OF BOUND ────────────────────
//
// MEASURED, on this store, at this head. The same committed directory folded
// rows 360 / subjects 307 / unreadable 433 through the bare library call
// `foldLedger()`, and rows 354 / subjects 302 / unreadable 507 through
// `node ledger.mjs fold` — because the CLI injected a screen and the library
// did not. Every byte of that 6-row gap was the MISSING SCREEN, not the clock.
// A number quoted off one path and read as the other was wrong by 5 subjects,
// silently, with both paths exiting normally. That is the exact defect class
// this store exists to abolish, so it may not live in the store's own reader.
//
// The two bounds therefore behave DIFFERENTLY here, on purpose:
//
//   `screen` DEFAULTS ON. screen.mjs is pure, importable and side-effect-free,
//   so there is no reason a library read should be less screened than the CLI
//   read of the same bytes — and "less screened" is not a smaller answer, it is
//   a DIFFERENT answer wearing the same field names. A caller who genuinely
//   wants the unscreened population says so: `screen: null`.
//
//   `now` STAYS INJECTED (D19). admitRecipe reads no clock and neither does the
//   fold; a default clock would make this module read the wall time behind its
//   caller's back, which is the seam D4 keeps honest. The CLI supplies
//   `date -u`; a library caller who wants the future bound passes one.
//
// So the two paths can still differ — by the clock, never by the screen — and
// the fold therefore REPORTS WHICH BOUNDS WERE IN FORCE, top-level, in
// `arming`:
//
//   { screen: "screen.mjs" | "caller" | "none" | "invalid", now: <iso> | null }
//
// A count that names its arming cannot be mistaken for a count taken under
// different bounds. Two folds of one store with EQUAL `now` now agree on
// rows / subjects / unreadable by construction; a fold that differs carries the
// reason in a field the reader is looking at anyway.
//
// `scope` NARROWS WHICH RUNS ARE FOLDED, BY SHAPE, NEVER BY NAME. Default
// "all" — the CLI's behaviour is unchanged, and a fold that quietly stopped
// reading part of a shared commons would be exactly the defect this module
// exists to make impossible. "owned" keeps runs grip wrote a `run_id` into;
// "attested" keeps the runs the WRITE PATH signed (see isAttestedRun). What
// falls outside the scope is COUNTED in stats.out_of_scope — never dropped
// silently — and the scope itself is reported in stats.scope, so no reader can
// mistake a narrowed fold for a whole one.
export function foldLedger(source = DEFAULT_LEDGER_DIR, { now, screen, scope = "all" } = {}) {
  // THE SCREEN BOUND, RESOLVED ONCE, AT THE FOLD'S OWN BOUNDARY — never inside
  // admitRecipe, which keeps its "the caller supplies both bounds" contract
  // intact for the write path. `undefined` (the caller said nothing) means the
  // module default; `null` is the explicit opt-out and is passed through as
  // "no screen", exactly the shape admitRecipe already understands.
  const screenBound = screen === undefined ? screenCommand : screen;
  const armedScreen = screenBound === screenCommand
    ? "screen.mjs"
    : screenBound === null
      ? "none"
      // A bound that is neither the default, nor null, nor a function is a
      // CONTRACT ERROR: admitRecipe rejects every row BAD-OPTION under it. It
      // must not be reported as "none" — "none" is a population, "invalid" is a
      // broken read — and it must not be reported as a screen either.
      : typeof screenBound === "function" ? "caller" : "invalid";
  const armedNow = typeof now === "string" && now.trim() !== "" ? now.trim() : null;
  const read = Array.isArray(source)
    ? { runs: source, unreadable: [], shape: null }
    : readLedgerRuns(source);
  const allRuns = read.runs;
  const runs = allRuns.filter((run) => inScope(run, scope));
  // File-level reports (UNPARSEABLE / NOT-A-RUN / MALFORMED-RUN) belong to no
  // run, so a scoped fold cannot own them: they are counted out of scope, and
  // their per-class totals stay visible in stats below either way.
  const unreadable = scope === "all" ? read.unreadable : [];
  const outOfScopeRuns = allRuns.length - runs.length;
  const outOfScopeFiles = read.unreadable.length - unreadable.length;

  const byKey = new Map();
  let rowCount = 0;
  // Drift counters. They are STATS, not warnings: a restated key is the fold
  // working, and a FALLBACK is the one number a reader must be able to see
  // without reading every row.
  let restatedQuantities = 0;
  let quantityFallbacks = 0;
  let restatedLevels = 0;
  let levelFallbacks = 0;
  // THE DIRECTION IS THE WHOLE POINT. A restatement that moves a row UP in
  // authority (stored L4, the command re-derives L2) is a conservative author
  // being corrected by the ladder — harmless, and worth naming. A restatement
  // that moves it DOWN (stored L2, the command only supports L4) is the launder
  // this substrate exists to prevent, arriving through the READ path. Counting
  // them together as one number cannot tell those apart, which is why the
  // control asserts on the DOWN count and merely reports the UP one.
  const levelRestatementsUp = [];
  const levelRestatementsDown = [];

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
      // ── THE READ PATH RE-ADMITS WHAT THE WRITE PATH ADMITTED ──────────────
      // usableRow is only the crash-safety gate (a non-string key that would
      // throw out of recipeKey). It rejects no FORGERY: a row carrying `value`,
      // an outage-capable rerun, a future observed_at and an over-claimed
      // derived_level were all admitted by the fold and folded into clean
      // entries with exit 0 — the module's own header promised "THE WRITE PATH
      // IS NOT THE READ PATH" and left every doctrinal rejection unenforced on
      // read. admitRecipe is the write path's adjudicator; running it here
      // routes every rejection it names into the EXISTING unreadable[] channel,
      // which already drives the fold CLI's nonzero exit — a CI tripwire for
      // free. Rejections ACCUMULATE (one forged row can trip several classes);
      // the row is not folded, every other row is.
      const verdict = admitRecipe(row, { now, screen: screenBound });
      if (!verdict.ok) {
        for (const r of verdict.rejections) {
          unreadable.push({
            file: run.file,
            index,
            reason: r.reason,
            message: `${r.reason}: ${run.file} row ${index} — ${r.message} The row is NOT folded; every other row is.`,
          });
        }
        return;
      }
      rowCount += 1;
      // RE-DERIVED, EVERY TIME, FROM THE COMMAND. Never `row.quantity` and
      // never `row.derived_level` — see the restate helpers above for the
      // measured reason.
      const quantity = restateQuantity(row);
      const level = restateLevel(row);
      if (quantity.quantity_restated) restatedQuantities += 1;
      if (quantity.quantity_fallback !== null) quantityFallbacks += 1;
      if (level.level_restated) {
        restatedLevels += 1;
        const from = LEVELS[level.stored_level];
        const to = LEVELS[level.derived_level];
        const moved = { file: run.file, index, subject: row?.subject ?? null, stored_level: level.stored_level, derived_level: level.derived_level, rerun: row?.rerun ?? null };
        // LEVELS is L1:1..L6:6 with L1 the STRONGEST, so a SMALLER number is
        // stronger. An unrankable level (neither on the ladder) is reported as
        // a DOWN restatement rather than swallowed — unknown is not safe.
        if (typeof from === "number" && typeof to === "number" && to < from) levelRestatementsUp.push(moved);
        else levelRestatementsDown.push(moved);
      }
      if (level.level_fallback !== null) levelFallbacks += 1;

      const key = recipeKey({ subject: row?.subject, quantity: quantity.quantity });
      if (!byKey.has(key)) {
        byKey.set(key, {
          key,
          subject: (row?.subject ?? "").trim(),
          quantity: quantity.quantity,
          stored_quantities: [],
          quantity_restated: false,
          recipes: [],
        });
      }
      const entry = byKey.get(key);
      // The stored values that landed on this key, deduped. Two rows whose
      // stored quantities DIFFER can legitimately share a re-derived key (that
      // is the merge direction of the same drift), so the entry keeps the whole
      // set rather than the first one it saw.
      if (!entry.stored_quantities.includes(quantity.stored_quantity)) {
        entry.stored_quantities.push(quantity.stored_quantity);
      }
      if (quantity.quantity_restated) entry.quantity_restated = true;
      // THE PROJECTION IS A NAMED ALLOWLIST (D89). entries[] is rebuilt from
      // exactly the TWELVE fields named below — never `...row` — so any key the
      // row carried and this list does not, `value` first among them, is DROPPED
      // before it can reach a consumer. This is defence in depth behind the
      // admitRecipe gate above: even a `value` that somehow reached here cannot
      // leave, which is WHY leads could ship a filter over entries[] and be
      // structurally unable to hand back a stored answer. The guarantee is the
      // ALLOWLIST, not its cardinality — "six" was the stale count.
      entry.recipes.push({
        rerun: row?.rerun ?? null,
        derived_level: level.derived_level,
        stored_level: level.stored_level,
        level_restated: level.level_restated,
        level_fallback: level.level_fallback,
        stored_quantity: quantity.stored_quantity,
        quantity_restated: quantity.quantity_restated,
        quantity_fallback: quantity.quantity_fallback,
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
    // WHICH BOUNDS WERE IN FORCE. Present on every fold, pass included: an
    // arming a reader only sees on failure is an arming nobody quotes. Read it
    // as the READING PATH of every number below it — two folds of one store
    // that agree here agree on rows/subjects/unreadable, and two that disagree
    // say so in the same object the counts live in.
    arming: { screen: armedScreen, now: armedNow },
    // The rows whose stored level the re-derivation MOVED, split by direction
    // and carried whole (file, index, subject, both levels, rerun) so a reader
    // can name the row instead of counting it. Reported, never a rejection.
    level_restatements: { up: levelRestatementsUp, down: levelRestatementsDown },
    stats: {
      scope,
      runs: runs.length,
      // What the walk DECLINED, so a narrowed fold can never read as a whole
      // one. Both are 0 at the default scope.
      out_of_scope_runs: outOfScopeRuns,
      out_of_scope_files: outOfScopeFiles,
      // The shape census of the whole directory — present even when the fold
      // itself was scoped, because a class you cannot see on PASS is a class
      // that gets quietly emptied. null when folding an in-memory run array.
      files: read.shape?.files ?? null,
      owned_runs: read.shape?.owned ?? null,
      foreign_runs: read.shape?.foreign ?? null,
      attested_runs: read.shape?.attested ?? null,
      not_a_run: read.shape?.not_a_run ?? null,
      malformed_run: read.shape?.malformed_run ?? null,
      unparseable: read.shape?.unparseable ?? null,
      rows: rowCount,
      subjects: entries.length,
      rival_methods: rivalMethods.length,
      unreadable: unreadable.length,
      // Rows whose STORED key/level disagrees with what the command mints
      // today. Not a defect count — the store is immutable and the grammar
      // moves, so this is the drift the re-derivation exists to absorb.
      quantity_restated: restatedQuantities,
      level_restated: restatedLevels,
      // Split by DIRECTION: `down` is a stored level the command cannot
      // support (the launder, arriving through the read path); `up` is a
      // conservative author corrected by the ladder.
      level_restated_up: levelRestatementsUp.length,
      level_restated_down: levelRestatementsDown.length,
      // Rows where the re-derivation could NOT answer and the stored value was
      // used instead. THIS one is worth reading: it is the only way the fold
      // can be keying on a stale value, and it is never silent.
      quantity_fallbacks: quantityFallbacks,
      level_fallbacks: levelFallbacks,
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
    ["the fold flags two GENUINELY rival methods over one key as RIVAL-METHOD", () => {
      // Both commands mint `wc:-l` — mint.mjs's own stated control for "two
      // different methods, one property". The key is re-derived, so this is a
      // real collision and not two rows agreeing on a stale stored string.
      const runs = [
        { file: "a.json", run_id: "a", recipes: [{ subject: "api/x.ex", quantity: "line count", rerun: "wc -l api/x.ex", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
        { file: "b.json", run_id: "b", recipes: [{ subject: "api/x.ex", quantity: "line count", rerun: "cat api/x.ex | wc -l", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
      ];
      const folded = foldLedger(runs);
      return folded.rival_methods.length === 1 && folded.rival_methods[0].reason === "RIVAL-METHOD";
    }],
    ["…and two rows that only SHARE A STORED QUANTITY are no longer rivals — the key is re-derived", () => {
      // The shipped defect, in miniature: both rows were written when the mint
      // produced `git:show` for everything, so on disk they are one key. A line
      // count is not a rival method of a match count, and the fold must no
      // longer say it is.
      const runs = [
        { file: "a.json", run_id: "a", recipes: [{ subject: "internal/cli/tasks_next_cmd.go", quantity: "git:show", rerun: "git show origin/main:internal/cli/tasks_next_cmd.go | wc -l", derived_level: "L2", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
        { file: "b.json", run_id: "b", recipes: [{ subject: "internal/cli/tasks_next_cmd.go", quantity: "git:show", rerun: "git show origin/main:internal/cli/tasks_next_cmd.go | grep -c 'needs_worktree'", derived_level: "L2", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
      ];
      const folded = foldLedger(runs);
      return folded.rival_methods.length === 0 && folded.entries.length === 2
        && folded.stats.quantity_restated === 2 && folded.stats.quantity_fallbacks === 0;
    }],
    ["a row whose command mints NO quantity falls back to the stored one and is MARKED, never silently", () => {
      // `screen: null` — the EXPLICIT unscreened read. `&&` is not a command at
      // all, so the default screen refuses it and the row never reaches the
      // restatement this control is about. Naming the opt-out keeps the control
      // measuring the fallback rather than the admission.
      const folded = foldLedger([
        { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "hand-written quantity", rerun: "&&", derived_level: "L6", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
      ], { screen: null });
      const recipe = folded.entries[0]?.recipes?.[0];
      return folded.entries[0]?.quantity === "hand-written quantity"
        && folded.stats.quantity_fallbacks === 1
        && typeof recipe?.quantity_fallback === "string"
        && recipe.quantity_fallback.includes("STORED quantity");
    }],
    ["the fold re-derives derived_level too — a stale stored level is restated, not trusted", () => {
      // `screen: null` for the same reason as the control above: the L1 command
      // that makes this control meaningful (it reaches a running system) is
      // exactly the shape the screen's host bound refuses, so the screened read
      // would never reach the restatement.
      const folded = foldLedger([
        { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "curl -s https://api.barkpark.cloud/api/schemas", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
      ], { screen: null });
      const recipe = folded.entries[0]?.recipes?.[0];
      return recipe?.stored_level === "L3" && recipe?.derived_level === "L1" && recipe?.level_restated === true;
    }],
    // THE ARMING CONTROL (D18) for this slice: the SAME rows folded twice, once
    // by default and once through the explicit opt-out, must give DIFFERENT row
    // counts and SAY SO in `arming`. If the default screen is ever removed the
    // two folds converge and this control goes SILENT — which is the mutation
    // that reopened the CLI-vs-library split in the first place.
    ["the library fold DEFAULTS the screen on, the opt-out is explicit, and `arming` names which was in force", () => {
      const rows = [
        { file: "a.json", run_id: "a", recipes: [
          { subject: "s", quantity: "q", rerun: "wc -l tooling/grip/ledger.mjs", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" },
          { subject: "t", quantity: "q", rerun: "rm -rf /opt/barkpark/releases", derived_level: "L6", deps: [], observed_at: "2026-07-20T00:00:00Z" },
        ] },
      ];
      const screened = foldLedger(rows);
      const unscreened = foldLedger(rows, { screen: null });
      return screened.arming.screen === "screen.mjs" && screened.arming.now === null
        && unscreened.arming.screen === "none"
        && screened.stats.rows === 1 && unscreened.stats.rows === 2
        && screened.unreadable.length === 1 && screened.unreadable[0].reason === "REFUSED-COMMAND"
        && unscreened.unreadable.length === 0;
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
  // Widens the haystack from the SUBJECT to subject+rerun. A boolean flag, so
  // it needs no takeFlag; the query filter below drops it with the others.
  const withCmd = args.includes("--cmd");
  const censusPath = takeFlag("--census");
  const dirArg = takeFlag("--dir");
  const query = args.filter((a) => !a.startsWith("--")).join(" ").trim();

  if (query === "") {
    process.stderr.write("ledger: leads needs a substring — node ledger.mjs leads <substring> [--cmd] [--json] [--census <report.json>] [--dir <ledger dir>]\n");
    process.stderr.write("  it matches case-insensitively over the SUBJECT; add --cmd to search the rerun command too\n");
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

  const folded = foldLedger(dirArg ? resolve(dirArg) : DEFAULT_LEDGER_DIR, await cliBounds());
  const result = selectLeads(folded, query, { census, cmd: withCmd });
  process.stdout.write(asJson ? `${JSON.stringify(result, null, 2)}\n` : renderLeads(result));
  // An honest empty is an ANSWER, not an error — exit 0. A nonzero here would
  // teach callers to treat "nobody has checked this yet" as a failure.
  return 0;
}

// THE READ-PATH BOUNDS, read from the shell exactly as `write` reads them. The
// library owns no clock and imports no screen (D19); the CLI is the caller, so
// the CLI supplies `date -u` and screenCommand to every read that admits rows.
// One reading, shared by fold and leads, so a forged-future or outage-capable
// row cannot fold on one verb and be caught on the other.
async function cliBounds() {
  const { screenCommand } = await import("./screen.mjs");
  return { now: shellNow(), screen: screenCommand };
}

async function main(argv) {
  // D78: the self-provenance banner, once, on STDERR, BEFORE any verb runs — so
  // leads, fold, prescreen and write all inherit "here is which tree answered".
  // stderr, never stdout: stdout is the verb's answer and a banner in it would
  // corrupt a piped `| JSON.parse`. emitProvenance swallows a broken stderr.
  emitProvenance();

  const [cmd = "fold", ...rest] = argv;
  if (cmd === "--selftest" || cmd === "selftest") return selftest();
  if (cmd === "write") return writeCommand(rest);
  if (cmd === "prescreen") return prescreenCommand(rest);
  if (cmd === "leads") return leadsCommand(rest);
  if (cmd === "fold") {
    const positional = rest.filter((a) => !a.startsWith("--"));
    const scopeArg = rest.find((a) => a.startsWith("--scope="));
    const scope = scopeArg ? scopeArg.slice("--scope=".length) : "all";
    if (!RUN_SHAPES.includes(scope)) {
      process.stderr.write(`ledger: unknown --scope ${JSON.stringify(scope)} — one of ${RUN_SHAPES.join(", ")}\n`);
      return 2;
    }
    const dir = positional[0] ? resolve(positional[0]) : DEFAULT_LEDGER_DIR;
    const folded = foldLedger(dir, { ...(await cliBounds()), scope });
    process.stdout.write(`${JSON.stringify(folded, null, 2)}\n`);
    // The SHAPE CENSUS, on stderr next to the provenance banner (stdout stays
    // pure JSON). Both file classes are printed on every run, including a clean
    // one: NOT-A-RUN and MALFORMED-RUN are different facts about a shared
    // commons — "another epic parked a note here" versus "a run file is rotting"
    // — and a class only visible on failure is a class that gets quietly
    // emptied.
    const s = folded.stats;
    // THE ARMING RIDES THE SAME LINE AS THE COUNTS, because the counts are only
    // meaningful under it — a terminal reader who copies "354 rows" out of here
    // copies the reading path with it. stderr, next to the shape census: stdout
    // stays pure JSON (the `arming` object is in there too).
    process.stderr.write(
      `[grip-fold] arming: screen=${folded.arming.screen} now=${folded.arming.now ?? "none"} — ` +
        `every count below is under THOSE bounds\n`,
    );
    process.stderr.write(
      `[grip-fold] scope=${s.scope} — walked ${s.runs} run file(s) / ${s.rows} row(s); ` +
        `store holds ${s.files} file(s): ${s.owned_runs} grip-owned (${s.attested_runs} write-path attested), ` +
        `${s.foreign_runs} foreign run(s), ${s.not_a_run} NOT-A-RUN, ${s.malformed_run} MALFORMED-RUN, ${s.unparseable} UNPARSEABLE; ` +
        `declined by scope: ${s.out_of_scope_runs} run(s) + ${s.out_of_scope_files} file-level report(s)\n`,
    );
    // RIVAL-METHOD is a feature of the data, not a failure: both rows are
    // legitimately stored. Exit 0 and let the caller read `rival_methods`.
    // A row admitRecipe refuses lands in `unreadable`, so a forged store folds
    // nonzero — the CI tripwire this slice bought for free.
    return folded.unreadable.length > 0 ? 1 : 0;
  }
  process.stderr.write("usage: node ledger.mjs [leads <substring> | prescreen <facts.json> | write <facts.json> [dir] | fold [dir] | --selftest]\n");
  process.stderr.write("  leads      look up RECIPES by case-insensitive substring over the SUBJECT — never an answer\n");
  process.stderr.write("             [--cmd (search the rerun command too)] [--json] [--census <census --json report>] [--dir <ledger dir>]\n");
  process.stderr.write("  prescreen  rehearse a write: report the per-row screen verdict and store NOTHING\n");
  process.stderr.write("  write      mint {claim,evidence,rerun} facts into recipe rows and store one immutable run file\n");
  process.stderr.write("  fold       read every run file in the store back as one index\n");
  process.stderr.write(`             [--scope=${RUN_SHAPES.join("|")}] — narrow by run SHAPE (default all): "owned" = carries a run_id, "attested" = the write path signed the filename\n`);
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  // `main` became async when `write` landed (it dynamically imports mint.mjs
  // and screen.mjs). An unhandled rejection is a NAMED failure here, never a
  // bare stack trace and never a silent exit: a store whose CLI dies quietly
  // is indistinguishable from a store that wrote nothing on purpose.
  // process.exit(code) TRUNCATES a not-yet-flushed pipe. `fold` and `leads`
  // write multi-kilobyte JSON to stdout, and Node flushes a pipe
  // asynchronously — so `.then((code) => process.exit(code))` tore the output
  // at ~512 bytes the instant a caller added `| cat` or `| jq`, and a piped
  // JSON.parse threw on truncated bytes while a redirect to a file got the
  // whole thing. Set process.exitCode instead and let the event loop drain:
  // Node flushes stdout to the OS on a natural exit, never on process.exit().
  // This module opens no lingering handles (readFileSync, dynamic imports —
  // nothing that keeps the loop alive), so the natural exit is immediate.
  main(process.argv.slice(2))
    .then((code) => { process.exitCode = code; })
    .catch((err) => {
      process.stderr.write(`ledger: crashed before any write — ${err?.stack ?? err?.message ?? String(err)}\n`);
      process.exitCode = 2;
    });
}
