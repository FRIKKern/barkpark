// record.mjs — the fact record and its admission check.
//
// A fact is { subject, quantity, claim, evidence, rerun, level, observed_at,
// deps[] } (charter D1, D14 shape). Two fields carry ALL the authority
// machinery and they are deliberately asymmetric:
//
//   rerun    — ONE literal shell command string. The level grammar reads THIS
//              and nothing else (level.mjs deriveLevel).
//   evidence — free prose. L6 BY CONSTRUCTION. Never parsed, never leveled,
//              never able to raise anything. It exists for humans and for
//              re-checking, not for authority.
//
// admitFact() is the write-time adjudication of THIS slice: derive the level
// from rerun, treat it as a ceiling on the author's claimed level (LEVEL-SKIP
// on breach), reject path-less line references (PATHLESS-REF, D9), and reject
// continuous quantities that declare no predicate (INADMISSIBLE-CONTINUOUS,
// D7). A missing rerun DEMOTES the fact to L6 — it never rejects (D3).
//
// Pure, dependency-free, no side effect on import. ESM named exports only.

import { deriveLevel, checkCeiling, classifyRef, isDiscretePredicate, LEVELS } from "./level.mjs";

export const FACT_FIELDS = Object.freeze([
  "subject", "quantity", "claim", "evidence", "rerun", "level", "observed_at", "deps",
]);

// path:line-shaped tokens inside prose — candidates handed to classifyRef.
// Extension list is deliberately broad; classifyRef decides admissibility.
const REF_CANDIDATE = /(?<![\w/])[\w./-]+\.(?:ex|exs|heex|eex|mjs|cjs|js|ts|tsx|go|md|json|ya?ml|sh|sql|css|html):\d+(?:-\d+)?(?![\w-])/g;

// Every path:line reference found in the fact's addressable text (subject,
// claim, quantity). NOT the evidence prose — evidence is never parsed.
export function findRefs(text) {
  if (typeof text !== "string") return [];
  return text.match(REF_CANDIDATE) ?? [];
}

// admitFact(input) → { ok: true, fact } | { ok: false, rejections: [...] }
//
// On admission the stored fact.level is the DERIVED level unless the author
// claimed strictly below it (under-claiming is honest and kept). On rejection
// nothing is stored; every rejection names its reason in the doctrine's own
// vocabulary so the fix is legible from the message alone.
export function admitFact(input = {}) {
  const rejections = [];
  const { subject, quantity, claim, evidence, rerun, level, observed_at, deps } = input;

  if (typeof subject !== "string" || subject.trim() === "") {
    rejections.push({ reason: "MISSING-SUBJECT", message: "MISSING-SUBJECT: a fact must name what it is about" });
  }
  if (typeof claim !== "string" || claim.trim() === "") {
    rejections.push({ reason: "MISSING-CLAIM", message: "MISSING-CLAIM: a fact must state what it asserts" });
  }
  if (deps !== undefined && !Array.isArray(deps)) {
    rejections.push({ reason: "BAD-DEPS", message: "BAD-DEPS: deps must be an array of fact subjects this fact reads through" });
  }

  // Level: derived from the rerun command ALONE (the evidence prose is not an
  // input — by construction, not by discipline).
  const derived = deriveLevel(rerun);
  let admittedLevel = derived;
  if (level !== undefined) {
    const ceiling = checkCeiling(level, derived);
    if (!ceiling.ok) {
      rejections.push(ceiling);
    } else if (LEVELS[level] > LEVELS[derived]) {
      admittedLevel = level; // honest under-claim is kept
    }
  }

  // D9 — path-less line references are rejected wherever the fact ADDRESSES
  // code: subject, claim, quantity. (Not evidence — never parsed.)
  for (const field of ["subject", "claim", "quantity"]) {
    const value = input[field];
    for (const ref of findRefs(value)) {
      const classified = classifyRef(ref);
      if (!classified.ok && classified.reason === "PATHLESS-REF") {
        rejections.push({ ...classified, field });
      }
    }
  }

  // D7 — a continuous quantity must declare a predicate.
  const predicateText = [quantity, claim].filter((v) => typeof v === "string").join("\n");
  if (!isDiscretePredicate(predicateText)) {
    rejections.push({
      reason: "INADMISSIBLE-CONTINUOUS",
      message: "INADMISSIBLE-CONTINUOUS: the quantity is a continuous measurement with no declared predicate — re-derivation yields a distribution, and conflict detection would fire forever on noise; declare a threshold (e.g. \"t_total < 2s\") to collapse it to a boolean",
    });
  }

  if (rejections.length > 0) return { ok: false, rejections };

  return {
    ok: true,
    fact: {
      subject: subject.trim(),
      quantity: typeof quantity === "string" ? quantity : quantity ?? null,
      claim: claim.trim(),
      evidence: typeof evidence === "string" ? evidence : "",
      rerun: typeof rerun === "string" ? rerun.trim() : "",
      level: admittedLevel,
      observed_at: typeof observed_at === "string" && observed_at !== "" ? observed_at : new Date().toISOString(),
      deps: Array.isArray(deps) ? [...deps] : [],
    },
  };
}
