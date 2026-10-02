// __binding_census.remove.fixture.js — THE REMOVE ARM'S POSITIVE CONTROL.
//
// Run: node cloud/priv/static/__binding_census.mjs --remove-check \
//        cloud/priv/static/__binding_census.remove.fixture.js     → exit 1
//
// Never imported, bundled or executed — a subject, like its ADD sibling. Same
// FIXTURE_PIN, two of whose rows have no call site here: `fixtureDepartedWrite`
// and `fixtureDepartedTeam` are pinned and GONE, which is what REMOVE is for.
// The arm exists so the pin stays a DESCRIPTION of the tree instead of decaying
// into fiction that nothing ever contradicts.
//
// THE SYMMETRY WITH THE ADD FIXTURE IS THE POINT. Two arms, two committed
// subjects, each declaring what must fire and what must stay silent. A gate with
// only the positive half tells you it can shout; it does not tell you it can
// tell things apart.
//
// ── the REMOVE arm: two pinned rows whose call sites have vanished ───────────
// @must-flag REMOVE fixtureDepartedWrite|POST /v1/fixture/departed
// @must-flag REMOVE fixtureDepartedTeam|DELETE /v1/fixture/departed/:*
//
// ── the negative half ────────────────────────────────────────────────────────
// The two REMOVE rows are evaluated by `--remove-check` alongside the must-flag
// rows above: the same run that names two departures has to leave two present
// rows alone.
// @must-clear REMOVE fixtureSelfWrite|POST /v1/fixture/self
// @must-clear REMOVE fixtureGatedProvider|POST /v1/fixture/providers
//
// ── the cross cell: `--add-check` on THIS file, which must exit 0 ─────────────
// Arms are mode-scoped, so these two are out of scope under `--remove-check` and
// evaluated only in the cross run. That run is what proves the ADD arm can stay
// silent, and it is the VERDICT-COLLAPSE arm's silent side. Paired with the add
// fixture's must-flag row, that arm is measured in BOTH directions — the
// difference between a tripwire and an alarm that is simply always on.
//
// THE SILENT SIDE NOW CARRIES THE RULING, NOT JUST AN UNTOUCHED PAIR
// (cch-bl-2d-ii-identical-predicate). This fixture used to declare no
// `@pin-override` at all, so its must-clear proved only that a pair with
// CONTRASTING verdicts stays quiet — which is the easy half and is not the
// question anyone asks. The override below flattens the pair to ONE SHARED
// PREDICATE NAME, `fixtureCanWrite` on both rows: the exact shape the real
// console reaches the day somebody puts `providerCanWrite()` in front of the
// launch wizard's provider button and honestly re-pins the bare row. (2d) rules
// that shape PERMITTED — one fence for one write family, correctly named twice —
// and this cell is where that ruling stops being prose. If (2d-ii) ever grows a
// "the pair may not share a name" clause, this cell reds, which is precisely the
// D452 failure mode (a rule that reds on the plausible fix) caught by
// measurement instead of by review.
// @pin-override fixtureBareProvider|POST /v1/fixture/providers predicate=fixtureCanWrite
// @must-clear ADD fixtureTeamWrite|DELETE /v1/fixture/team/:*
// @must-clear VERDICT-COLLAPSE POST /v1/fixture/providers

/* eslint-disable */
function api(verb, path, body) {
  return { verb, path, body };
}
function fixtureCanManage() { return true; }
function fixtureCanWrite() { return true; }

// ── pinned, present: four rows the REMOVE arm must leave alone ──────────────

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

// ── the departures ──────────────────────────────────────────────────────────
// `fixtureDepartedWrite` and `fixtureDepartedTeam` are pinned and deliberately
// absent from this file. Nothing is written here on purpose: an absence is what
// the arm reads, and a commented-out stub would be a call site the extractor
// still cannot see but a reader would think it could.
