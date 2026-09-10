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
//   UNCOMPARED-COUNT   A COUNTING STAGE PRINTS a quantity and ASSERTS nothing
//                      about it. `| wc -l` is the obvious spelling; `grep -c`,
//                      `grep -vc` and `git grep -c` are the same act wearing a
//                      matcher's clothes.
//
// THE ASYMMETRY THIS RULE EXISTS TO CLOSE (wave 29's own field report). Until
// 2026-09-10 only `| wc` and an ungraded `git rev-list --count` were named, so
// the screen REFUSED the honest author who reached for `wc` and ADMITTED the one
// who reached for `grep -c`, FOR THE SAME UNASSERTED NUMBER. MEASURED: the two
// recipes
//
//     git grep -c 'hzResDone(' origin/main -- internal/cli/hetzner_lb_cmd.go
//
// byte-identical, one claiming the true count and one claiming 9999, BOTH
// returned RE-DERIVED / PASS-ADMITTED. The `git grep` branch below returned its
// axes before any tail rule could fire, and `-c` was invisible to it.
//
// So the rule is stated on the ACT, not on the spelling: ANY stage that prints a
// count is UNCOMPARED unless the pipeline ENDS in an equality grade
// (`| grep -qx <n>`), which turns the printed number into a real predicate. The
// refusal names its own substitute rather than only saying no — a screen that
// refuses without naming the cheaper honest spelling teaches authors to write
// prose instead (truth-grip D3).
//
// A COUNT CLAIM ALSO NEEDS A BINDING, and that is binding.mjs's `quantity` term:
// a rule that only screens the COMMAND still lets a fabricated number ride in
// the CLAIM. Both halves are owed, and neither alone closes the hole.
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
  // A count that has been GRADED against a literal. `… | grep -qx 50` exits 0
  // only when the count is exactly 50 — the one shape in which a printed
  // quantity becomes something an exit code moves on.
  QUANTITY: "QUANTITY",
});

/** The claim classes a PDS recipe may declare. */
export const CLAIM_CLASS = Object.freeze({
  EXISTENCE: "existence",
  CONTENT: "content-token",
  ANCESTRY: "ancestry",
  ABSENCE: "absence",
  BEHAVIOUR: "behaviour",
  QUANTITY: "quantity",
});

export const CLAIM_CLASSES = Object.freeze(Object.values(CLAIM_CLASS));

// Tails whose exit code is a statement about the FORMATTER, not about the data
// it was handed. `sed -n 1p` over an empty stream exits 0; so does `head`, so
// does `cut`. Putting one of these last erases the rc of everything upstream.
const MASKING_TAILS = new Set([
  "sed", "head", "tail", "cut", "tr", "nl", "column", "rev", "cat", "sort", "uniq", "awk", "tee",
]);

// `grep` is NOT a masking tail — rc1 is a real no-match. Counting gets its own
// name because "printed a number" is the single most common way a rerun in this
// repo's ledgers claims something it never checked.
const MATCHER_HEADS = new Set(["grep", "rg", "egrep", "fgrep"]);

/** True for `-c`, `--count`, and any short cluster carrying a lowercase c (`-vc`). */
function carriesCountFlag(args) {
  return args.some((t) =>
    t === "--count" || (/^-[A-Za-z]+$/.test(t) && !t.startsWith("--") && t.slice(1).includes("c")));
}

/** True for `-q`/`-x` in the same shapes, so `-qx` and `-q -x` both read. */
function carriesShortFlag(args, letter) {
  return args.some((t) => /^-[A-Za-z]+$/.test(t) && !t.startsWith("--") && t.slice(1).includes(letter));
}

/**
 * countingSpelling(segment) → the NAME of the counting act, or null.
 *
 * Stated on the ACT so a fifth spelling cannot walk in the way `grep -c` did.
 * An ENUMERATION of spellings is a snapshot; this is the predicate.
 */
export function countingSpelling(segment) {
  const tokens = segmentTokens(String(segment ?? ""));
  const head = String(tokens[0] ?? "").split("/").pop();
  if (head === "wc") return "wc";
  if (MATCHER_HEADS.has(head)) return carriesCountFlag(tokens.slice(1)) ? `${head} -c` : null;
  if (head === "git") {
    const { verb, args } = gitVerb(tokens);
    if (verb === "grep" && carriesCountFlag(args)) return "git grep -c";
    if (verb === "rev-list" && args.some((t) => t === "--count" || t.startsWith("--count="))) {
      return "git rev-list --count";
    }
  }
  return null;
}

/**
 * equalityGrade(segment) → the literal integer this segment tests for, or null.
 *
 * `| grep -qx 50` / `| grep -x 0`. Whole-line (`-x`) against an INTEGER literal
 * is the whole requirement: without `-x` the pattern `5` matches `15`, and a
 * grade that matches the wrong number is not a grade.
 */
export function equalityGrade(segment) {
  const tokens = segmentTokens(String(segment ?? ""));
  const head = String(tokens[0] ?? "").split("/").pop();
  if (!MATCHER_HEADS.has(head)) return null;
  const args = tokens.slice(1);
  if (!carriesShortFlag(args, "x")) return null;
  const operand = args.find((t) => !t.startsWith("-"));
  return operand !== undefined && /^\d+$/.test(operand) ? operand : null;
}

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

  // ── THE COUNTING STAGE, WHEREVER IT SITS ─────────────────────────────────
  // Before the head table, so `git grep -c` cannot be classified by its verb
  // and walk past the count rule the way it did until 2026-09-10.
  const grade = equalityGrade(last);
  const countIdx = segs.findIndex((seg) => countingSpelling(seg) !== null);
  const counting = countIdx >= 0 ? countingSpelling(segs[countIdx]) : null;
  const countGraded = counting !== null && grade !== null && countIdx < segs.length - 1;

  if (counting !== null && !countGraded) {
    const substitute = counting === "git rev-list --count"
      ? `${cmd} | grep -qx 0`
      : `${cmd} | grep -qx <the number you are claiming>`;
    return {
      axes: [],
      masked: "UNCOMPARED-COUNT",
      why:
        `\`${counting}\` PRINTS a quantity and asserts nothing about it — its exit code is the same ` +
        `for the number you claim and for any other number, so nobody has asserted the count. ` +
        `SUBSTITUTE: grade it — \`${substitute}\` — or drop the count and match the token instead`,
    };
  }
  if (countGraded) {
    const axes = counting === "git rev-list --count" ? [AXIS.ANCESTRY, AXIS.QUANTITY] : [AXIS.QUANTITY];
    return {
      axes,
      masked: null,
      why:
        `\`${counting}\` is equality-graded by \`${String(last).trim()}\`, whose exit code is 0 only when the ` +
        `count is exactly ${grade} — the printed number has become a predicate somebody asserted`,
    };
  }
  if (segs.length > 1 && MASKING_TAILS.has(lastHead)) {
    return {
      axes: [],
      masked: "PIPE-MASKED-RC",
      why: `the pipeline ends in \`${lastHead}\`, whose exit code describes the formatter and not the data — measured on this host: \`git show origin/main:no/such/path.md\` exits 128, the same command piped to \`sed -n 1p\` exits 0`,
    };
  }

  // Nothing left in the pipeline counts, so the SOURCE segment owns the axes.
  const source = segs[0];
  const tokens = segmentTokens(source);
  const head = String(tokens[0] ?? "").split("/").pop();

  if (head === "git") {
    const { verb, args } = gitVerb(tokens);
    const hasArg = (...f) => args.some((t) => f.some((x) => t === x || t.startsWith(`${x}=`)));
    if (verb === "cat-file" && hasArg("-e")) {
      return { axes: [AXIS.EXISTENCE], masked: null, why: "`git cat-file -e <ref>:<path>` exits 0 present / 1 absent — an EXISTENCE predicate and nothing more" };
    }
    if (verb === "grep") {
      return { axes: [AXIS.EXISTENCE, AXIS.CONTENT], masked: null, why: "`git grep` exits 0 on a match and 1 on a clean no-match — it moves on the TOKEN, so it pays for a content claim" };
    }
    // `git rev-list --count` — graded or not — is decided by the COUNTING STAGE
    // block above, which is the only place a count is ruled on. Reaching here
    // with one would mean two rules owned the same shape.
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
  // Only a GRADED count pays for a quantity claim. Nothing else in this table
  // moves on a number, which is exactly the hole this class was added to close.
  [CLAIM_CLASS.QUANTITY]: [AXIS.QUANTITY],
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
