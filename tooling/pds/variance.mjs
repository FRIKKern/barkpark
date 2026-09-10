// variance.mjs — PDS-D388. VARIANCE-SKIP, NOT STRICT POLARITY.
//
// THE MEASUREMENT THAT SET THIS RULE. Of 484 real rerun commands in this repo's
// own ledgers, EIGHT (1.65%) are strictly-polarised predicates. A screen that
// demands strict polarity therefore refuses 98.3% of the repo's own honest
// work, and an honest author who is refused writes prose instead — which is the
// state wave 28 is trying to leave, reached by a stricter road.
//
// So the rule is grip's LEVEL-SKIP rotated one axis:
//
//     THE COMMAND'S VARIANCE SET IS A CEILING ON THE REASON'S CLAIM CLASS.
//
// A command's VARIANCE SET is the set of facts its EXIT CODE actually moves on.
// `git show origin/main:<path>` moves on EXISTENCE only — the content lands on
// stdout, where no rc ever reads it — so a reason claiming "line 2460 says X"
// over that command is an OVER-CLAIM (VARIANCE-SKIP), while a reason claiming
// "the file is still there" is exactly paid for.
//
// ONLY OVER-CLAIMS ARE REFUSED. Three named shapes:
//
//   VARIANCE-SKIP      the claim class is not in the command's variance set.
//   PIPE-MASKED-RC     a fetch/format tail discards the rc of the segment that
//                      touches the claim. MEASURED on this host 2026-07-31:
//                        git show origin/main:no/such/path.md            → 128
//                        git show origin/main:no/such/path.md | sed -n 1p →   0
//                      The pipeline reports success for a file that is gone.
//   UNCOMPARED-COUNT   `| wc -l` PRINTS a quantity and ASSERTS nothing; its rc
//                      is 0 for 0 rows and 0 for 4000 rows.
//
// EVERYTHING ELSE THAT DOES NOT CLASSIFY IS **DEMOTED, NEVER REJECTED** —
// truth-grip D3. An unrecognised command is not a dishonest one, and punishing
// it is how a screen teaches authors to stop authoring.
//
// Pure. Adopts grip's shipped `pipelineSegments` / `segmentHead` READ-ONLY
// rather than re-deriving a sixth pipeline parser (truth-grip D24).

import { pipelineSegments, segmentHead, segmentTokens } from "../grip/census.mjs";

// ── THE BEHAVIOUR HEADS, AND WHAT THE EXECUTOR WILL ACTUALLY RUN ─────────────
//
// TWO DIFFERENT QUESTIONS, AND CONFLATING THEM IS THE BUG THIS TABLE EXISTS TO
// STOP. This module answers *what does an exit code MEAN* — `node --test x`
// exits 1 on a failed assertion, so its rc genuinely moves on BEHAVIOUR, and a
// table that denied it would be lying about the shell. grip's caller-boundary
// screen answers a different question — *will this census RUN it* — and it
// fails closed on any head that executes an arbitrary program.
//
// So the two lists DO NOT MATCH, deliberately, and the mismatch is a STATED
// LIMIT rather than a defect to be aligned away: aligning variance's table down
// to the executor would put a false statement about the shell into the one
// table whose whole job is to be true about the shell.
//
// MEASURED 2026-09-10 by handing each probe below to grip's `screenCommand()`
// (tooling/grip/screen.mjs) — NOT copied from any prose. Seven of the nine
// heads are unreachable, by two different layers:
//
//   bash sh zsh node python3   refused at the HEAD ("runs an arbitrary script
//                              or inline program" / "executes arbitrary …")
//   npm pnpm                   HEAD admitted, but every behaviour-paying
//                              sub-verb (`test`, `run`) is off the read-only
//                              sub-verb allowlist
//   go mix                     ADMITTED — `go test`/`go vet` and `mix test`
//                              (note `go build` is refused: not a read-only verb)
//
// The list below is not a second copy of that measurement: section 10 of
// rerun-adjudicate.test.mjs RE-RUNS the probes through the live screen and reds
// if this constant, the screen, or README.md's stated-limit line ever disagree.

/** head → the canonical behaviour-paying command for that head. */
export const BEHAVIOUR_HEAD_PROBES = Object.freeze({
  go: "go test ./internal/cli -run TestSiteClaimsAreProbedWithResponseTypes",
  mix: "mix test test/barkpark/tasks_test.exs",
  npm: "npm test",
  pnpm: "pnpm test",
  bash: "bash scripts/roster-drift-check.sh",
  sh: "sh scripts/roster-drift-check.sh",
  zsh: "zsh scripts/roster-drift-check.sh",
  node: "node --test tooling/pds/rerun-adjudicate.test.mjs",
  python3: "python3 -m pytest",
});

/** Every head whose exit code pays for a BEHAVIOUR claim. */
export const BEHAVIOUR_HEADS = Object.freeze(Object.keys(BEHAVIOUR_HEAD_PROBES));

/**
 * The STATED LIMIT: behaviour heads this table advertises that grip's screen
 * refuses, so a recipe using one is reported REFUSED and counted, never run.
 * Mirrored in README.md's `pds-stated-limit:` line and locked by the test.
 */
export const EXECUTOR_UNREACHABLE_BEHAVIOUR_HEADS = Object.freeze(
  ["bash", "node", "npm", "pnpm", "python3", "sh", "zsh"],
);

/** The axes an exit code can move on. */
export const AXIS = Object.freeze({
  EXISTENCE: "EXISTENCE",
  CONTENT: "CONTENT",
  ANCESTRY: "ANCESTRY",
  BEHAVIOUR: "BEHAVIOUR",
});

/** The claim classes a PDS recipe may declare. */
export const CLAIM_CLASS = Object.freeze({
  EXISTENCE: "existence",
  CONTENT: "content-token",
  ANCESTRY: "ancestry",
  ABSENCE: "absence",
  BEHAVIOUR: "behaviour",
});

export const CLAIM_CLASSES = Object.freeze(Object.values(CLAIM_CLASS));

// Tails whose exit code is a statement about the FORMATTER, not about the data
// it was handed. `sed -n 1p` over an empty stream exits 0; so does `head`, so
// does `cut`. Putting one of these last erases the rc of everything upstream.
const MASKING_TAILS = new Set([
  "sed", "head", "tail", "cut", "tr", "nl", "column", "rev", "cat", "sort", "uniq", "awk", "tee",
]);

// `grep` is NOT a masking tail — rc1 is a real no-match — and `wc` gets its own
// name because "printed a number" is the single most common way a rerun in this
// repo's ledgers claims something it never checked.
const COUNTING_TAILS = new Set(["wc"]);

/**
 * The git VERB and its arguments, skipping the global flags that take a value.
 * EXPORTED because binding.mjs's `deriveTerms` needs the same split to find a
 * git read's SUBJECT, and a second copy of this loop is how the two would drift.
 */
export function gitVerb(tokens) {
  for (let i = 1; i < tokens.length; i++) {
    const t = tokens[i];
    if (!t.startsWith("-")) return { verb: t, args: tokens.slice(i + 1) };
    if (t === "-C" || t === "-c") i++;
  }
  return { verb: "", args: [] };
}

/**
 * varianceSet(command) → { axes: string[], masked: null|"PIPE-MASKED-RC"|"UNCOMPARED-COUNT", why }
 *
 * `axes: []` with `masked: null` means UNKNOWN — the caller DEMOTES, it does
 * not refuse.
 */
export function varianceSet(command) {
  const cmd = String(command ?? "").trim();
  if (cmd === "") return { axes: [], masked: null, why: "no command" };

  const segs = pipelineSegments(cmd);
  const last = segs[segs.length - 1] ?? cmd;
  const lastHead = String(segmentHead(last) ?? "").split("/").pop();

  if (COUNTING_TAILS.has(lastHead)) {
    return {
      axes: [],
      masked: "UNCOMPARED-COUNT",
      why: `the pipeline ends in \`${lastHead}\`, which PRINTS a quantity and asserts nothing — its exit code is 0 for zero rows and 0 for every other count`,
    };
  }
  if (segs.length > 1 && MASKING_TAILS.has(lastHead)) {
    return {
      axes: [],
      masked: "PIPE-MASKED-RC",
      why: `the pipeline ends in \`${lastHead}\`, whose exit code describes the formatter and not the data — measured on this host: \`git show origin/main:no/such/path.md\` exits 128, the same command piped to \`sed -n 1p\` exits 0`,
    };
  }

  // A `grep -q`/`grep -qx <literal>` tail turns an upstream count into a real
  // predicate. Which axis it certifies is decided by the SOURCE segment.
  const source = segs[0];
  const tokens = segmentTokens(source);
  const head = String(tokens[0] ?? "").split("/").pop();
  const graded = segs.length > 1 && (lastHead === "grep" || lastHead === "rg");

  if (head === "git") {
    const { verb, args } = gitVerb(tokens);
    const hasArg = (...f) => args.some((t) => f.some((x) => t === x || t.startsWith(`${x}=`)));
    if (verb === "cat-file" && hasArg("-e")) {
      return { axes: [AXIS.EXISTENCE], masked: null, why: "`git cat-file -e <ref>:<path>` exits 0 present / 1 absent — an EXISTENCE predicate and nothing more" };
    }
    if (verb === "grep") {
      return { axes: [AXIS.EXISTENCE, AXIS.CONTENT], masked: null, why: "`git grep` exits 0 on a match and 1 on a clean no-match — it moves on the TOKEN, so it pays for a content claim" };
    }
    if (verb === "rev-list" && hasArg("--count")) {
      return graded
        ? { axes: [AXIS.ANCESTRY], masked: null, why: "`git rev-list --count <a>..<b>` graded by `grep -qx 0` is the measured-polarised ancestry predicate" }
        : { axes: [], masked: "UNCOMPARED-COUNT", why: "`git rev-list --count` prints a number and exits 0 whatever the number is — grade it with `| grep -qx 0` or it asserts nothing" };
    }
    if (verb === "show" || verb === "cat-file") {
      return { axes: [AXIS.EXISTENCE], masked: null, why: "`git show <ref>:<path>` moves its exit code on EXISTENCE only — the content goes to stdout, which no exit code reads" };
    }
    // Every other git read (log, diff, ls-tree, …) answers on the query, not on
    // a named axis this table can vouch for.
    return { axes: [], masked: null, why: `git ${verb || "(no verb)"} does not classify onto a named axis here` };
  }

  if (head === "grep" || head === "rg" || head === "egrep" || head === "fgrep") {
    return { axes: [AXIS.EXISTENCE, AXIS.CONTENT], masked: null, why: "a matcher exits 1 on a genuine no-match, so it moves on the token" };
  }

  // Toolchain runs. These EXECUTE something and answer with the exit code, so
  // they are the one class that pays for a behaviour claim. WHICH OF THEM GRIP
  // WILL ACTUALLY RUN IS A DIFFERENT QUESTION — see BEHAVIOUR_HEAD_PROBES.
  if (BEHAVIOUR_HEADS.includes(head)) {
    return { axes: [AXIS.BEHAVIOUR], masked: null, why: `\`${head}\` runs a program and answers with its exit code — the only shape that pays for a behaviour claim` };
  }

  return { axes: [], masked: null, why: `\`${head || "(empty)"}\` does not classify onto a named axis here` };
}

// WHICH AXES PAY FOR WHICH CLAIM CLASS.
//
// ABSENCE is deliberately paid for by the SAME axes as its positive twin: an
// absence claim is re-derived by the same read, read in the other direction
// (PDS-D389 / grip's admitsAbsenceClaim). It is the CLAIM that is negative, not
// the instrument.
const PAYS_FOR = Object.freeze({
  [CLAIM_CLASS.EXISTENCE]: [AXIS.EXISTENCE, AXIS.CONTENT],
  [CLAIM_CLASS.CONTENT]: [AXIS.CONTENT],
  [CLAIM_CLASS.ANCESTRY]: [AXIS.ANCESTRY],
  [CLAIM_CLASS.ABSENCE]: [AXIS.EXISTENCE, AXIS.CONTENT, AXIS.BEHAVIOUR],
  [CLAIM_CLASS.BEHAVIOUR]: [AXIS.BEHAVIOUR],
});

/**
 * overClaim(claimClass, variance) → null | { reason, message }
 *
 * null means the command's variance set covers the claim. An UNKNOWN variance
 * set (axes: [], masked: null) also returns null — the caller DEMOTES it to L6
 * with a named note; refusing it would punish honest work this table simply
 * does not recognise (truth-grip D3).
 */
export function overClaim(claimClass, variance) {
  if (variance.masked) {
    return { reason: variance.masked, message: `${variance.masked}: ${variance.why}` };
  }
  if (variance.axes.length === 0) return null; // UNKNOWN → the caller demotes
  const pays = PAYS_FOR[claimClass];
  if (!pays) {
    return { reason: "UNKNOWN-CLAIM-CLASS", message: `UNKNOWN-CLAIM-CLASS: \`${claimClass}\` is not one of ${CLAIM_CLASSES.join(", ")}` };
  }
  if (pays.some((axis) => variance.axes.includes(axis))) return null;
  return {
    reason: "VARIANCE-SKIP",
    message:
      `VARIANCE-SKIP: the reason claims \`${claimClass}\`, which is paid for by ${pays.join(" or ")}, ` +
      `but the command's exit code moves only on ${variance.axes.join(", ")} — ${variance.why}`,
  };
}

/** True when the variance set classified onto no axis and nothing was refused. */
export function isUnknownVariance(variance) {
  return variance.axes.length === 0 && variance.masked === null;
}
