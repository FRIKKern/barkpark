// __binding_census.ratchet.fixture.js — THE RATCHET ARM'S POSITIVE CONTROL.
//
// Run: node cloud/priv/static/__binding_census.mjs --ratchet-check \
//        cloud/priv/static/__binding_census.ratchet.fixture.js    → exit 1
//
// Never imported, bundled or executed — a subject, like its ADD and REMOVE
// siblings. Same six invented call sites, same small FIXTURE_PIN in the census's
// own fixture-mode block, and the same reason for being a committed fixture
// rather than a mutant of app.js: a control anchored to a live defect stays
// honest only while the defect stays unfixed, and quietly acquires an interest
// in the bug surviving (cch-w38-bl).
//
// WHY THIS FIXTURE HAD TO EXIST AT ALL. `--add-check` and `--remove-check`
// short-circuit high in the census — after `seenByKey`, before every check
// below it — and the ratchet arm lives well underneath that line, with the rest
// of the (2x) checks. So neither existing mode reaches it: run the add fixture
// under `--add-check` and the ratchet line prints ZERO times. A guard whose
// fixture control cannot produce its defect is green by construction, which is
// the failure this wave's standing test exists to catch, so the arm brought its
// own mode with it.
//
// THE ARM IS PIN-SIDE, exactly like VERDICT-COLLAPSE, and is driven the same
// way. No arrangement of source text can make a pin row say `elevated: true,
// predicate: null` — that is a hand-written judgement — so this fixture
// manufactures the defect with `@pin-override`, nulling the predicate on two
// rows that the declared ceiling does not cover. That is precisely the shipping
// move the live arm exists to red on: a new elevated write, pinned unbound.
//
// ── the CEILING this fixture measures against ────────────────────────────────
// The two rows FIXTURE_PIN already carries as elevated-and-unbound. Declared
// here, in the fixture's own bytes, rather than in a table inside the census
// that could drift away from the file it describes.
// @legacy fixtureBareProvider|POST /v1/fixture/providers
// @legacy fixtureDepartedWrite|POST /v1/fixture/departed
//
// ── the mutants: two NEW unbound elevated writes ─────────────────────────────
// Both rows are pinned elevated WITH a predicate in FIXTURE_PIN; nulling them is
// the miniature of the console defect — an affordance above plain membership
// with nothing in front of it, arriving with a pin row that sums perfectly.
// Neither key is on the ceiling above, so both are NOVEL.
// @pin-override fixtureTeamWrite|DELETE /v1/fixture/team/:* predicate=null
// @pin-override fixtureDepartedTeam|DELETE /v1/fixture/departed/:* predicate=null
// @must-flag RATCHET fixtureTeamWrite|DELETE /v1/fixture/team/:*
// @must-flag RATCHET fixtureDepartedTeam|DELETE /v1/fixture/departed/:*
//
// ── the ceiling LOWERING, in the same run ────────────────────────────────────
// `fixtureDepartedWrite` is ON the ceiling and is given a predicate here. That
// is the HEALED direction, and it must stay silent while the two rows above
// fire: an arm that reddened on a row getting FIXED would be a guard that only
// stays green while the disease stays untreated (charter D452). The census
// prints it as a HEALED line under this mode, with the ceiling list untouched.
// @pin-override fixtureDepartedWrite|POST /v1/fixture/departed predicate=fixtureCanManage
// @must-clear RATCHET fixtureDepartedWrite|POST /v1/fixture/departed
//
// ── the negative half: two rows the SAME run must leave alone ────────────────
// `fixtureBareProvider` is elevated, unbound, and ON the ceiling — the exact
// property the two must-flag rows have, differing only in whether the ceiling
// covers it. If the arm fired here it would be counting, not ratcheting.
// `fixtureSelfWrite` is unbound too but is NOT elevated: a plain-member write
// with no predicate is not a defect, and an arm that could not tell those apart
// would red on most of the console.
// @must-clear RATCHET fixtureBareProvider|POST /v1/fixture/providers
// @must-clear RATCHET fixtureSelfWrite|POST /v1/fixture/self
//
// ── the cross cells: `--add-check` and `--remove-check` on THIS file, exit 0 ──
// All six pinned rows are present below and every call site is pinned, so ADD
// and REMOVE both stay silent. The provider pair keeps its contrasting verdicts
// under the overrides above — only rows OUTSIDE that route are nulled — so
// VERDICT-COLLAPSE stays silent too. Arms are mode-scoped, so these rows are out
// of scope here and are evaluated only in the cross runs.
// @must-clear ADD fixtureGatedProvider|POST /v1/fixture/providers
// @must-clear REMOVE fixtureDepartedWrite|POST /v1/fixture/departed
// @must-clear VERDICT-COLLAPSE POST /v1/fixture/providers

/* eslint-disable */
function api(verb, path, body) {
  return { verb, path, body };
}
function fixtureCanManage() { return true; }
function fixtureCanWrite() { return true; }

// ── all six pinned rows, present: the SET DIFF must stay silent on this file ──
// The ratchet arm reads the PIN, not the source, so nothing here is arranged to
// make it fire. These bytes exist so the two cross cells are a real measurement
// of the other arms rather than an exemption granted to this filename.

function fixtureSelfWrite(email) {
  return api("POST", "/v1/fixture/self", { email });
}

function fixtureTeamWrite(id) {
  if (!fixtureCanManage()) return null;
  return api("DELETE", "/v1/fixture/team/" + encodeURIComponent(id));
}

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
