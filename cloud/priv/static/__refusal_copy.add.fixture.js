// __refusal_copy.add.fixture.js — THE ADD ARM'S POSITIVE CONTROL, AND ITS NEGATIVE ONE.
//
// Run: node cloud/priv/static/__refusal_copy_census.mjs --add-check \
//        cloud/priv/static/__refusal_copy.add.fixture.js        → exit 1
//      node cloud/priv/static/__refusal_copy_census.mjs --remove-check \
//        cloud/priv/static/__refusal_copy.add.fixture.js        → exit 0  (the CROSS cell)
//
// This file is NEVER imported, bundled or executed. It is a SUBJECT: the census
// points its real extractor at these bytes and diffs the sites it derives against
// the small FIXTURE_PIN in its own fixture-mode block.
//
// WHY A COMMITTED FIXTURE AND NOT A MUTANT OF app.js. A control anchored to a
// LIVE DEFECT stays honest only for as long as the defect stays unfixed — the
// guard quietly acquires an interest in the bug surviving (cch-w38-bl). Every
// site below is INVENTED, so nothing anyone does to the console can make this
// proof stale, and nothing anyone does to this proof can hold the console still.
//
// FOUR SITES, TWO AND TWO — THE FLOOR IS DISCRIMINATION, NOT NOISE (charter D442).
// Two sites are ABSENT from FIXTURE_PIN and must be FLAGGED; two are PRESENT in it
// and the SAME RUN must leave them alone. A fixture with only must-flag rows
// proves the mode is wired and NOTHING about whether the arm can tell a new site
// from a known one — and "it reds when I add something" is the failure mode this
// two-and-two shape exists to rule out. The observed set must EQUAL the must-flag
// set: firing for an UNDECLARED reason exits 2 exactly like not firing at all.
//
// THE MUST-FLAG PAIR COVERS TWO DIFFERENT KINDS ON PURPOSE — one FN and one MAP.
// A control that only exercised FN would leave the MAP kind, the one that gives
// `ERRORS.forbidden` its key, unproven in the arm that matters most.
//
// ── the ADD arm: two live sites FIXTURE_PIN does not carry ───────────────────
// @must-flag ADD FN|fixtureInventedFailureCopy|a078a469
// @must-flag ADD MAP|FIXTURE_ERRORS.invented
//
// ── the negative half: rows this SAME run must NOT fire on ───────────────────
// @must-clear ADD MAP|FIXTURE_ERRORS.forbidden
// @must-clear ADD ARG|fixtureDelegatingHandler|friendly|4c6b5137
//
// ── the cross cell: `--remove-check` on THIS file, which must exit 0 ─────────
// Arms are mode-scoped, so these rows are out of scope under `--add-check` and
// are evaluated only in the cross run — where every pinned row IS present and the
// REMOVE arm must therefore stay silent on a fixture built to fire ADD.
// @must-clear REMOVE MAP|FIXTURE_ERRORS.forbidden
// @must-clear REMOVE MAP|FIXTURE_ERRORS.departed

/* eslint-disable */

// ── THE FOUR FENCES ─────────────────────────────────────────────────────────
// Present so the FENCE arm does not refuse this subject before the set diff runs
// — which is itself a small proof that the arm is ordered the way it claims.
// `friendly` consults here exactly as it does in app.js, which is what makes the
// ARG row below DELEGATED rather than AUTHORED.
function friendly(data, fallback) {
  if (data && data.error === "forbidden") return FIXTURE_ERRORS.forbidden;
  return (data && FIXTURE_ERRORS[data.error]) || fallback;
}
function forbiddenEvidenceCopy(data) {
  return data && data.required ? FIXTURE_ERRORS.forbidden : null;
}
function readFailureCopy(r, forbiddenCopy, fallback) {
  return r.status === 403 ? forbiddenCopy : fallback;
}
function faultCopy(status, data, fallback, transport) {
  return status === 404 ? fallback : friendly(data, fallback);
}

// ── the qualified map. It QUALIFIES because `FIXTURE_ERRORS` is referenced from
//    inside friendly()'s body above — the same rule that admits ERRORS,
//    TRANSPORT_COPY, FORBIDDEN_ROLE_COPY and FORBIDDEN_REASON_COPY in app.js and
//    rejects the ~30 all-caps label maps that have nothing to do with refusals.
var FIXTURE_ERRORS = {
  // pinned and present — the ADD arm must stay silent about this one
  forbidden: "You don't have permission to do that, and nobody said which role would.",
  // pinned and present — its ABSENCE is what the remove fixture proves
  departed: "That thing is gone and this sentence went with it.",
  // NOT pinned — this is a must-flag row: a cause sentence nobody judged
  invented: "The scheduler declined this job for reasons of its own.",
};

// ── NOT pinned: a refusal renderer, anchored by the NAMING CONVENTION alone.
//    It carries no status test and no fence call, so predicate-anchoring would
//    produce ZERO rows for it — the same blindness that makes
//    notifDeliveriesErrorHtml invisible in app.js. This row therefore proves the
//    naming anchor is load-bearing and not decorative.
function fixtureInventedFailureCopy() {
  return "We could not finish that, and the server never told us why.";
}

// ── pinned and present: a delegated fallback. friendly() above provably
//    consults, so this literal is what the console says when the server said
//    nothing — DELEGATED BY CONSTRUCTION, and the ADD arm must clear it.
function fixtureDelegatingHandler(r) {
  if (r.status === 403) {
    return friendly(r.data, "Couldn't apply that change. Try again.");
  }
  return null;
}

// ── pinned and present: an FN row, so the cross cell has something real to be
//    silent about and the REMOVE arm has a live site behind its pin.
function fixturePinnedFailureCopy(r) {
  if (r.status === 409) {
    return "The instance refused the check.";
  }
  return null;
}
