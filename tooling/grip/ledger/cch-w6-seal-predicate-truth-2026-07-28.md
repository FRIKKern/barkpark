# cch-w6 verify — seal-predicate truth (executed, not read)

Repo HEAD at measurement: `a8c767dbd26e4770bd942f61a3e9c94ab5da8b87`, clean tree.
All fixtures below live in the run scratchpad; the JSON is reproduced inline so every
row re-derives from this file alone.

## R1 — clause (b) is GREEN today; the live verdict is NO SEAL on clause (a) only

```
node cloud/priv/static/__preview__/seal-predicate.mjs ; echo EXIT=$?
node cloud/priv/static/__preview__/overflow-guard.mjs ; echo EXIT=$?
```
Expect: predicate EXIT=1, `CLAUSE (b) … 3 registered` all `✓`, `UNNAMED RESIDUE (orphans) : 4`.
overflow-guard EXIT=0, `OVERFLOW GUARD PASS`.

## R2 — naming the successor does NOT clear clause (a)

```
node cloud/priv/static/__preview__/seal-predicate.mjs --successor cloud-console-hardening-epic
```
Expect EXIT=1 and orphans still 4. Forwarding is membership in the SUCCESSOR'S OWN
roster (`fetchRoster(SUCCESSOR)`, seal-predicate.mjs:131), so the four rows must be
re-parented under `cloud-console-hardening-epic`; naming it in a flag is not enough.

## R3 — gr-bl-predicate-null-successor-silent-seal REPRODUCES (all 3 criteria unfixed)

Fixture `fx-nolive.json`:
```json
{"successor":null,"forwarded":[],"landed":["0261ace15"],
 "children":[{"_id":"row-a","lifecycle_status":"done"},{"_id":"row-b","lifecycle_status":"done"}],
 "gates":{"cloud-console-billing-live-gate":{"lifecycle_status":"open","parent_id":"cloud-console-goal"},
          "gr-ops-platform-admin-emails":{"lifecycle_status":"open","parent_id":"x"},
          "gr-backlog-qr-live-scan-proof":{"lifecycle_status":"open","parent_id":"x"}}}
```
```
node cloud/priv/static/__preview__/seal-predicate.mjs --ledger fx-nolive.json --guard-cmd true --repo "$PWD"
# EXIT=0, "VERDICT: SEAL", SCOPE line reads "to null, and 3 permanent human gate(s)…"

# same fixture with the "successor" key DELETED  -> EXIT=0, SCOPE reads "to undefined"
# same fixture + --successor task-DOES-NOT-EXIST-9999 -> EXIT=0, SCOPE reads
#   "to task-DOES-NOT-EXIST-9999" (a bogus id is accepted as a forwarding address)
```
The defect only fires when live rows are ZERO — i.e. exactly at the moment of a
successful seal. With any live row the null successor orphans them and reds (fixture
with one `open` child: EXIT=1). "Reading the code suggests it orphans" is true for the
failing case and FALSE for the sealing case.

## R4 — a retargeted predicate with an emptied KNOWN_DEFECTS fails OPEN

```
cp cloud/priv/static/__preview__/seal-predicate.mjs /tmp/sp-empty.mjs
perl -0pi -e 's/const KNOWN_DEFECTS = \[.*?\n\];/const KNOWN_DEFECTS = [];/s' /tmp/sp-empty.mjs
node /tmp/sp-empty.mjs --ledger fx-nolive.json --repo "$PWD"
# EXIT=0, "CLAUSE (b) known user-facing defects — 0 registered", "VERDICT: SEAL"
```
No guard is spawned at all: the loop over `[]` yields zero failures. The disclosure
does print "KNOWN over 0 hand-registered defects", so the count is visible — but the
VERDICT is a confident green asserting nothing.

Control (the fail-closed arm works): `--guard-cmd 'exit 3'` -> EXIT=1, three
`guard exited 3` lines.

## R5 — grip's seal.mjs is a PORT, not an engine

```
grep -n 'ROOT_ID\|NAMESPACE_RE\|FROZEN_CRITERIA' tooling/grip/seal.mjs
grep -n 'argOf(argv' tooling/grip/seal.mjs
node tooling/grip/seal.mjs --ledger tooling/grip/fixtures/seal-clean.json --repo . ; echo EXIT=$?
```
Only three flags exist: `--ledger`, `--server`, `--repo`. `ROOT_ID = "truth-grip-epic"`
(:100) is consumed at :370/:373/:376/:382/:391/:425/:429 and `NAMESPACE_RE` at :229 —
even in fixture mode. There is no epic seam. Its clauses are (a)(b)(b')(c) with NO
successor-forwarding clause, so it cannot evaluate the console's clause (a) as written.
Fixture run exits 0 with `VERDICT-TOKEN: SEAL-PREDICATE HOLDS a=PASS b=PASS b'=PASS c=PASS blocking=0`.

## R6 — the console predicate has no test file

```
grep -rln 'seal-predicate' cloud/ tooling/ .github/
```
Hits: overflow-guard.mjs, tooling/grip/seal.mjs (a prose citation), four grip ledger
rows. `tooling/grip/test/seal.test.mjs` tests GRIP's predicate only. Nothing tests
`cloud/priv/static/__preview__/seal-predicate.mjs`.
