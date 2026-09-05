// __refusal_copy.remove.fixture.js — THE REMOVE ARM'S POSITIVE CONTROL.
//
// Run: node cloud/priv/static/__refusal_copy_census.mjs --remove-check \
//        cloud/priv/static/__refusal_copy.remove.fixture.js     → exit 1
//      node cloud/priv/static/__refusal_copy_census.mjs --add-check \
//        cloud/priv/static/__refusal_copy.remove.fixture.js     → exit 0  (the CROSS cell)
//
// The DECAY case: a pin that has quietly become fiction. This file is the add
// fixture with TWO pinned sites DELETED — one MAP member and one FN renderer —
// and nothing else changed. What the census must do is name both departures by
// key while staying silent about everything still standing.
//
// TWO DELETIONS, NOT ONE, AND ACROSS TWO KINDS. A single-deletion fixture proves
// the arm can subtract; it does not prove the arm can tell WHICH pinned rows lost
// their site. Deleting one MAP member and one FN renderer also exercises the two
// kinds whose keys are built by completely different code paths — the object
// literal walker and the copy-position scanner.
//
// A NOTE ON WHY THERE IS NO TEXT-SUBSTITUTION DIRECTIVE HERE. The prototype for
// this census mutated app.js itself, so it could not simply omit a map member and
// needed a `@census-sub` directive to reach inside a live object literal — and
// that directive carried a real bug: a literal `\n` in its replacement text was
// written as two characters rather than a newline, which broke the member it was
// producing and yielded a FALSE REMOVE (exit 1 where the cross cell required 0).
// Because FIXTURE_PIN is the census's OWN small pin, this fixture can simply not
// declare the member. The escape-interpretation bug is not fixed here — it is
// DESIGNED OUT, and the fixture mechanism that remains is plain source text with
// no interpreter of its own to get wrong.
//
// ── the REMOVE arm: two pinned keys with no live site ────────────────────────
// @must-flag REMOVE MAP|FIXTURE_ERRORS.departed
// @must-flag REMOVE FN|fixturePinnedFailureCopy|900502b2
//
// ── the negative half: pinned rows still standing, which must stay silent ────
// @must-clear REMOVE MAP|FIXTURE_ERRORS.forbidden
// @must-clear REMOVE ARG|fixtureDelegatingHandler|friendly|4c6b5137
//
// ── the cross cell: `--add-check` on THIS file, which must exit 0 ────────────
// @must-clear ADD MAP|FIXTURE_ERRORS.forbidden
// @must-clear ADD ARG|fixtureDelegatingHandler|friendly|4c6b5137

/* eslint-disable */

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

// `departed` is GONE from this map. That deletion is the whole fixture: the pin
// still carries MAP|FIXTURE_ERRORS.departed, and there is now nothing behind it.
var FIXTURE_ERRORS = {
  forbidden: "You don't have permission to do that, and nobody said which role would.",
};

// Still standing, and pinned — the arm must leave it alone.
function fixtureDelegatingHandler(r) {
  if (r.status === 403) {
    return friendly(r.data, "Couldn't apply that change. Try again.");
  }
  return null;
}

// `fixturePinnedFailureCopy` IS DELETED HERE. Its pinned FN key has no live site
// and the REMOVE arm must name it.
