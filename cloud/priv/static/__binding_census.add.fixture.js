// __binding_census.add.fixture.js — THE ADD ARM'S POSITIVE CONTROL.
//
// Run: node cloud/priv/static/__binding_census.mjs --add-check \
//        cloud/priv/static/__binding_census.add.fixture.js        → exit 1
//
// This file is NEVER imported, bundled or executed. It is a subject: the census
// points its real extractor at these bytes and diffs the call sites it derives
// against the small FIXTURE_PIN in its own fixture-mode block.
//
// WHY IT IS A COMMITTED FIXTURE AND NOT A MUTANT OF app.js. cch-w38-bl's
// control was anchored to a LIVE DEFECT, which means it stayed honest only for
// as long as the defect stayed unfixed — the guard quietly acquired an interest
// in the bug surviving. These eight call sites are invented, so nothing anyone
// does to the console can make this proof stale, and nothing anyone does to
// this proof can hold the console still.
//
// THE DECLARATIONS BELOW ARE THE CONTRACT, and the census reads them out of this
// file rather than carrying its own copy. `@must-flag` rows are the arms that
// MUST fire; `@must-clear` rows are known-good subjects the same run must leave
// alone — two of each is the floor (charter D442), because a fixture with only
// must-flag rows proves the mode is wired and nothing about discrimination.
// The observed set must EQUAL the must-flag set: firing for an undeclared reason
// exits 2 exactly like not firing at all.
//
// ── the ADD arm: two write call sites no pin row predicts ────────────────────
// @must-flag ADD fixtureNewWrite|POST /v1/fixture/new
// @must-flag ADD fixtureSecondNewWrite|PUT /v1/fixture/new/:*
//
// ── the VERDICT-COLLAPSE arm (charter D452) ─────────────────────────────────
// (2d)'s two DIRECTIONAL verdict sub-clauses were retired because they froze a
// live defect: they required submitProviderCred to stay unpredicated forever.
// What survives is (2d-ii), the non-directional rule — the same-route pair may
// not go BOTH unpredicated. That rule is pin-side, so no arrangement of source
// text can exercise it; the `@pin-override` below drives it as a mutant, nulling
// the gated verdict so the pair collapses. Without this row the split would be a
// net loss of coverage, which is the only reason it is here.
// @pin-override fixtureGatedProvider|POST /v1/fixture/providers predicate=null
// @must-flag VERDICT-COLLAPSE POST /v1/fixture/providers
//
// ── the negative half: rows this same run must NOT fire on ───────────────────
// @must-clear ADD fixtureSelfWrite|POST /v1/fixture/self
// @must-clear ADD fixtureGatedProvider|POST /v1/fixture/providers
//
// ── the cross cell: `--remove-check` on THIS file, which must exit 0 ──────────
// Arms are mode-scoped, so this row is out of scope under `--add-check` and is
// evaluated only in the cross run — where every pinned row IS present and the
// REMOVE arm must therefore stay silent on a fixture built to fire ADD.
// @must-clear REMOVE fixtureDepartedWrite|POST /v1/fixture/departed

/* eslint-disable */
function api(verb, path, body) {
  return { verb, path, body };
}
function fixtureCanManage() { return true; }
function fixtureCanWrite() { return true; }

// ── pinned, present: the census must stay silent about all six ──────────────

function fixtureSelfWrite(email) {
  return api("POST", "/v1/fixture/self", { email });
}

function fixtureTeamWrite(id) {
  if (!fixtureCanManage()) return null;
  return api("DELETE", "/v1/fixture/team/" + encodeURIComponent(id));
}

// The POST /v1/providers pair's shape, kept apart by call-site keying exactly as
// the real one is: one route, two call sites, opposite verdicts.
function fixtureBareProvider(cred) {
  return api("POST", "/v1/fixture/providers", cred);
}

function fixtureGatedProvider(cred) {
  if (!fixtureCanWrite()) return null;
  return api("POST", "/v1/fixture/providers", cred);
}

function fixtureDepartedWrite(payload) {
  return api("POST", "/v1/fixture/departed", payload);
}

function fixtureDepartedTeam(id) {
  return api("DELETE", "/v1/fixture/departed/" + encodeURIComponent(id));
}

// ── the arrivals: two affordances nothing predicts ──────────────────────────
// This is the disease, in miniature — a write affordance grown without a pin
// row, which on the real console means a member sees a button and gets a 403.

function fixtureNewWrite(payload) {
  return api("POST", "/v1/fixture/new", payload);
}

function fixtureSecondNewWrite(id, payload) {
  return api("PUT", "/v1/fixture/new/" + encodeURIComponent(id), payload);
}
