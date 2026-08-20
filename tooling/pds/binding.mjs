// binding.mjs — THE FALSIFIABILITY SEAM.
//
// THE PROBLEM THIS SOLVES, STATED AS THE HOLE IT CAME FROM. Wave 27's census
// asserts that 213 disposition reasons are byte-DISTINCT and nothing more, so a
// stale, invented or partial reason passes exactly as well as a re-derived one.
// Attaching a rerun command to a reason does not by itself fix that: a command
// can pass beside a claim it has nothing to do with, and then the green is
// *about the command*, not about the claim. That is the same lie one level up,
// with a shell in it.
//
// So a rerun is only evidence for a claim when the claim and the command are
// BOUND — when the terms the claim asserts appear, LITERALLY, in the text the
// shell will run, and in the prose the reason states.
//
// A recipe therefore declares its claim STRUCTURALLY:
//
//     terms: { ref: "origin/main", path: "scripts/pds-pull-proof.sh" }
//
// and every declared term must occur literally in BOTH `command` and `claim`.
// That single rule is what makes a mutation test possible at all:
//
//     MUTATE THE CLAIM, KEEP THE COMMAND BYTE-IDENTICAL → UNBOUND-CLAIM → RED.
//
// Without it, editing a prose claim changes nothing an instrument can see, and
// "the tests pass" would be proving only that the shell still works.
//
// WHAT BINDING DOES **NOT** CERTIFY. It says the command is ABOUT the claim. It
// says nothing about whether the claim is true — that is what execution is for,
// and both are required before this instrument reports RE-DERIVED. Reporting
// binding alone as a pass would be the vacuous green this epic legislates
// against, rebuilt inside its own remedy.
//
// Pure. No I/O, no execution. ESM named exports only.

import { CLAIM_CLASSES } from "./variance.mjs";

/** Term keys a recipe may declare. Unknown keys are a REJECTION, never ignored. */
export const TERM_KEYS = Object.freeze(["ref", "path", "token", "sha", "predicate"]);

/**
 * bindClaim(recipe) → { ok, rejections: [{reason, message}] }
 *
 * Rejections ACCUMULATE (grip's admitFact convention): showing only the first
 * would hide three quarters of a broken recipe.
 */
export function bindClaim(recipe = {}) {
  const rejections = [];
  const push = (reason, message) => rejections.push({ reason, message: `${reason}: ${message}` });

  const command = typeof recipe.command === "string" ? recipe.command : "";
  const claim = typeof recipe.claim === "string" ? recipe.claim : "";
  const terms = recipe.terms && typeof recipe.terms === "object" ? recipe.terms : null;

  if (typeof recipe.doc_id !== "string" || recipe.doc_id.trim() === "") {
    push("MISSING-DOC-ID", "a recipe must name the ledger row it re-derives");
  }
  if (command.trim() === "") {
    push("MISSING-COMMAND", "a recipe with no command re-derives nothing");
  }
  if (claim.trim() === "") {
    push("MISSING-CLAIM", "a recipe must state, in prose, the one thing its command re-derives");
  }
  if (!CLAIM_CLASSES.includes(recipe.claim_class)) {
    push("UNKNOWN-CLAIM-CLASS", `\`${recipe.claim_class}\` is not one of ${CLAIM_CLASSES.join(", ")}`);
  }
  if (terms === null) {
    push("MISSING-TERMS", "a recipe must declare the terms that bind its claim to its command — a claim nothing binds is prose with a shell attached");
    return { ok: false, rejections };
  }

  const declared = Object.entries(terms).filter(([, v]) => typeof v === "string" && v.trim() !== "");
  if (declared.length === 0) {
    push("MISSING-TERMS", "`terms` is present but declares nothing");
  }
  for (const key of Object.keys(terms)) {
    if (!TERM_KEYS.includes(key)) {
      push("UNKNOWN-TERM", `\`${key}\` is not one of ${TERM_KEYS.join(", ")} — an unrecognised term binds nothing and must not be silently dropped`);
    }
  }

  for (const [key, value] of declared) {
    if (!command.includes(value)) {
      push("UNBOUND-CLAIM", `term ${key}="${value}" does not occur in the command, so the command is not about this claim — \`${command}\``);
    }
    if (!claim.includes(value)) {
      push("UNBOUND-CLAIM", `term ${key}="${value}" does not occur in the claim prose, so the prose and the command are asserting different things — "${claim}"`);
    }
  }

  return { ok: rejections.length === 0, rejections };
}
