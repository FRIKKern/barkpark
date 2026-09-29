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

import { CLAIM_CLASSES, gitVerb } from "./variance.mjs";
import { pipelineSegments, segmentTokens } from "../grip/census.mjs";

// ── WHY `quantity` IS A TERM KEY ─────────────────────────────────────────────
//
// UNTIL 2026-09-10 THIS LIST HAD NO PLACE FOR A NUMBER, so the number in a claim
// was bound to nothing and was structurally immune to the mutation method this
// whole file exists to make possible. MEASURED on wave 29's own spine: two
// recipes with a BYTE-IDENTICAL command, one claiming the true count and one
// claiming 9999, received the IDENTICAL verdict — because every declared term
// (`token`, `path`, `ref`) still occurred literally in both halves, and the only
// thing that moved was a quantity nothing screened.
//
// A count claim is therefore bindable only when the command CARRIES the number,
// which in practice means an equality-GRADED tail (`… | grep -qx 50`) — the same
// shape variance.mjs requires before a count pays for anything. The two halves
// are deliberately joined: a grade with no binding lets the prose drift from the
// number the shell tests, and a binding with no grade binds to a number nobody
// asserted.
//
// NOT DERIVED FOR A STORED RERUN. `deriveTerms` below reads a bare command and
// does NOT manufacture a quantity from a grade it finds there: the row's title
// is the claim, and demanding that a title spell out a graded literal would
// refuse honest rows over a number the author put in the command on purpose.
// A quantity binds when an AUTHOR declares it.

/** Term keys a recipe may declare. Unknown keys are a REJECTION, never ignored. */
export const TERM_KEYS = Object.freeze(["ref", "path", "token", "sha", "predicate", "quantity"]);

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

// ── DERIVED TERMS: BINDING A RERUN NOBODY WROTE A RECIPE FOR ─────────────────
//
// A SIDECAR RECIPE DECLARES ITS TERMS. A ROW'S STORED `disposition_rerun` — the
// fourth durable key `bp task stage` writes — is a BARE COMMAND STRING and
// nothing else. So the binding seam above has no author-declared terms to work
// with, and the choice is: admit the stored rerun unbound (which is exactly the
// "a command passing beside a claim it has nothing to do with" failure this file
// was written to stop, rebuilt inside its own remedy), or DERIVE the terms.
//
// THE DERIVATION IS NOT CIRCULAR, AND THAT IS THE WHOLE DESIGN. Terms are read
// out of the COMMAND — the machine-readable half, which is not the half being
// screened — and then checked against the ROW'S TITLE, which is the claim
// `toFact()` already hands grip. The check that can fail is therefore a real
// one: *does the row's own claim literally name the thing this command reads?*
// Mutate the title, keep the command byte-identical, and the binding breaks.
//
// WHAT IS THE SUBJECT OF A READ:
//
//   git grep <pat> <ref> -- <pathspec>   the PATTERN. The pathspec NARROWS the
//                                        search; it is not what is claimed, and
//                                        binding on it would refuse every honest
//                                        row whose title names a token.
//   git cat-file/show <ref>:<path>       the PATH.
//   git <verb> … -- <pathspec>           the PATH.
//   grep/rg/egrep/fgrep <pat> …          the PATTERN.
//   anything else                        NOTHING. `{}` — and bindClaim then
//                                        refuses it MISSING-TERMS. Fail closed:
//                                        a stored rerun whose subject this table
//                                        cannot name is not silently admitted.
//
// A PATH BINDS BY BASENAME, and that is a STATED WEAKENING. An authored recipe
// declares `path: "scripts/pds-pull-proof.sh"` and binds on the whole pathspec;
// a row title writes `check-doc-budgets.sh`. Demanding the full pathspec in a
// title refuses honest work, which is the road truth-grip D3 forbids. So a
// derived path binding is basename-strength, weaker than an authored one, and
// the verdict note says so rather than letting the two look alike.
const MATCHER_HEADS = new Set(["grep", "rg", "egrep", "fgrep"]);

const basename = (p) => String(p).split("/").filter(Boolean).pop() ?? "";

// grip's `segmentTokens` splits on whitespace and does NOT honour shell quoting,
// so a real stored rerun like
//   git grep -n 'Enum.all?(list, &is_map/1)' origin/main -- api/…/tasks.ex
// arrives as the two fragments `'Enum.all?(list,` and `&is_map/1)'`. Binding on
// the FIRST fragment would be a term the author never wrote, so the quoted run is
// rejoined from the segment TEXT. Adopting grip's tokeniser and repairing the one
// case it does not cover beats shipping a sixth shell parser (truth-grip D24).
function unquote(source, operand) {
  const q = operand[0];
  if (q !== "'" && q !== '"') return operand;
  const start = source.indexOf(operand);
  if (start < 0) return operand;
  const end = source.indexOf(q, start + 1);
  if (end < 0) return operand;
  return source.slice(start + 1, end);
}

/** deriveTerms(command) → the terms a bare command binds on. `{}` = none found. */
export function deriveTerms(command) {
  const cmd = String(command ?? "").trim();
  if (cmd === "") return {};

  // The SOURCE segment owns the subject: in `git grep x | wc -l` the claim is
  // about `x`, and the tail is what variance.mjs is for.
  const source = pipelineSegments(cmd)[0] ?? cmd;
  const tokens = segmentTokens(source);
  const head = String(tokens[0] ?? "").split("/").pop();
  const firstOperand = (args) => args.find((t) => !t.startsWith("-"));

  if (head === "git") {
    const { verb, args } = gitVerb(tokens);
    if (verb === "grep") {
      const pat = firstOperand(args);
      return pat ? { token: unquote(source, pat) } : {};
    }
    const terms = {};
    const colon = tokens.find((t) => /^[^\s:]+:[^\s:]+$/.test(t));
    if (colon) terms.path = basename(colon.slice(colon.indexOf(":") + 1));
    const dd = args.indexOf("--");
    if (dd >= 0 && args[dd + 1]) terms.path = basename(args[dd + 1]);
    return terms;
  }

  if (MATCHER_HEADS.has(head)) {
    const pat = firstOperand(tokens.slice(1));
    return pat ? { token: unquote(source, pat) } : {};
  }

  return {};
}
