<!-- doc-tier: agent | canonical-for: pds-rung6-faildemo-record | budget: 12000tok -->

# Rung 6's two fail-demos — the reds, quoted

**What this is.** The two wave-8 fail-demos that PDS-D100 requires of a corrected
assertion, transcribed verbatim from the bp ledger into the repository. Both demos were
really run, and their output was really captured — but it lives ONLY in
`pds-w8-rung6-sentinel`'s acceptance-criteria evidence, and both scratch scripts were
deleted after capture. An auditor working from GitHub alone therefore reads D100's
precondition as unmet:

```
$ gh pr view 4771 --json body | grep -icE 'demo1|demo2|nosentinel|nostamp|FAIL-DEMO'
0
```

This file closes that gap **by quotation** (PDS-D176). Nothing here was re-run.

**What this is NOT.** No demo was re-executed, no target was booted, no export attempt
was spent, and the frozen harness was not touched. The instrument stays at blob
`e219e97ccf7f33797c86a2b84d998d599b6bda31` (`git rev-parse origin/main:scripts/pds-pull-proof.sh`
— never `shasum`, PDS-D154, the two disagree by construction). This record is a
transcription; it is not itself a proof that the demos would red again today. That
property is carried by the demos having been run once against the shipped assertion,
and by the shipped assertion being frozen since.

**Verified at `origin/main` = `8b24003d193373f621fbde181c61fc9248195a60`.** Line numbers
move; the sha is the anchor. Round-1 merges quoted throughout:
`58d1bd3a5` (#4771, the sentinel), `09072b0b0` (#4770, TagRegistry), `65541e2d4` (#4772,
the owner map).

---

## 1. Why rung 6 needed fail-demos at all

Before #4771, rung 6 measured **nothing in either direction**. `step_6` digests eight
guarded columns of `schema_definitions`, reboots with the provenance stamp present (leg A:
digest must not change), then clears the stamp and reboots (leg B: digest must change).
But Bootstrap's clobber is a *write of the declaration*, and step 0b REQUIRES the target's
sha to equal guerrilla's deployed sha — same sha, same plugin modules, byte-identical
declarations. The rows therefore **cannot differ from what Bootstrap writes**: 34 rows
written, 34 already exactly right. The guard was demonstrably gated AND released (34 SKIP
stamped, 34 REGISTER cleared) while **zero rows moved either way**.

So leg A was vacuous: "the eight columns did not change" would have held with the guard
DELETED. #4771 writes a sentinel into the eight guarded columns before the first reboot,
so leg A proves drifted rows **survive** — the hazard the guard exists for — and leg B
proves they **revert**.

A corrected assertion that has never failed is not a proof (PDS-D100). The two demos
below are that failure.

---

## 2. FAIL-DEMO 1 — sentinel step disabled ⇒ the corrected rung is RED

Source: `bp task get pds-w8-rung6-sentinel -o json`, `acceptance_criteria[4].evidence`.
Criterion 4 reads: *"FAIL-DEMO 1 (PDS-D134): with the sentinel step disabled, the
corrected rung is SHOWN RED — the fix is load-bearing. Evidence: captured run output of
the red."* Quoted verbatim:

> Run w8r6-demo1 via an UNSHIPPED scratch copy (scripts/.pds-demo1-nosentinel.sh, deleted
> after capture) in which the sentinel UPDATE is replaced by a read-only count — i.e. the
> pre-fix rung. Fresh scratch target, --only 1,6, EXIT=1: 'RETURNING 34 rows sentinelled'
> (counted, not written) / 'before reboot digest c3b6f2d3950a9a9ec8f5f13e9c4243a7 rows=36'
> / 'after reboot digest c3b6f2d3950a9a9ec8f5f13e9c4243a7 rows=36' / 'sentinel intact 0 of
> 34' -> FAIL 6 'LEG A: only 0 of 34 sentinelled rows still carry the deliberate drift
> after the stamped reboot — the guard is leaking rows even though the aggregate digest
> happened to hold.' This is sharper than expected and is the whole finding: WITHOUT the
> sentinel the aggregate digest HOLDS across the reboot (identical md5 before and after),
> so the pre-fix leg A passed vacuously and would have passed with the guard deleted. Only
> the positive sentinel-presence assertion catches it. Shipped script on a fresh target
> immediately after: PASS 6 (run w8r6-final).

**What it establishes.** The digest is identical before and after
(`c3b6f2d3950a9a9ec8f5f13e9c4243a7`, rows=36 both sides) — the *old* leg A's entire
assertion, satisfied, with the drift silently gone. Only `sentinel intact 0 of 34` reds.
The fix is load-bearing.

---

## 3. FAIL-DEMO 2 — provenance stamp cleared ⇒ leg A is RED

Source: same task, `acceptance_criteria[5].evidence`. Criterion 5 reads: *"FAIL-DEMO 2
(PDS-D134): with the provenance stamp cleared before leg A, leg A is SHOWN RED — the
corrected rung can still catch a broken engine, and no new force-disable flag was added to
do it. Evidence: captured run output of the red."* Quoted verbatim:

> Run w8r6-demo2 via an UNSHIPPED scratch copy (scripts/.pds-demo2-nostamp.sh, deleted
> after capture) that injects one psql line clearing the stamp AFTER the sentinel write and
> BEFORE the reboot — clearing the stamp IS disabling the guard, so NO force-disable flag
> ships and none was added. Fresh target, --only 1,6, EXIT=1: 'RETURNING 34 rows
> sentinelled' / 'FAIL-DEMO 2 provenance stamp CLEARED after the sentinel write, before the
> reboot' / 'boot log 0 SKIP (guard fired) · 34 REGISTER, this boot only' / 'after reboot
> digest c3b6f2d3950a9a9ec8f5f13e9c4243a7' (moved from 3cf6497098ba4cada6181a321400fb7a) ->
> FAIL 6 'LEG A — THE GUARD DID NOT FIRE: 34 rows were sentinelled and stamped, yet the
> boot logged ZERO guard SKIPs and 34 plugin REGISTERs ... Guarded columns that moved on
> those rows: title icon visibility owner_scoped fields cors_origins desk_groups
> list_preview.' The 0 SKIP / 34 REGISTER split independently reproduces the wave-7
> diagnosis symmetry. NOTE: the first cut of this demo red at the ROSTER DRIFT tripwire
> instead, which was a MISDIAGNOSIS (0 SKIPs means the guard never ran, not that the roster
> drifted); the shipped script now splits those two cases and reads leg A's per-column diff
> BEFORE the count assertions so the red names the reverted columns.

**What it establishes.** With the guard disabled, the digest **moves**
(`3cf6497098ba4cada6181a321400fb7a` → `c3b6f2d3950a9a9ec8f5f13e9c4243a7`) and all eight
guarded columns are named as moved. The corrected rung still catches a broken engine.

---

## 4. PDS-D168 — "stamp cleared" discharges "guard inverted"

The wish for wave 8 asked for leg A shown red with the provenance guard **inverted**. That
word is the wish's, not the epic's. PDS-D134 charters demand (ii) as *stamp cleared* and
denies an invertible branch in the same sentence.

`.claude/workflows/bp-pds-charter.md:1085-1092` at `origin/main`, verbatim:

```
- **PDS-D134 — THE THAW HONOURS THE FREEZE AND CARRIES THREE FAIL-DEMOS.** PDS-D100 licenses a filed
  HARNESS BUG to be corrected in PREFLIGHT with the corrected assertion SHOWN still failing on the
  pre-fix condition. Wave 8 pays that three times: (i) sentinel step disabled → the corrected rung
  RED, proving the fix is load-bearing and not decoration; (ii) stamp cleared → leg A RED, proving
  the corrected rung can still catch a broken engine (clearing the stamp IS disabling the guard —
  there is no separate branch to invert, so no new flag ships); (iii) a planted lower-pid foreign
  `beam.smp` matcher → the OLD selector picks it, the NEW one does not. The edit makes every rung
  STRICTER; nothing anywhere is loosened.
```

**Provenance of the word.** `git log -S invert -- .claude/workflows/bp-pds-charter.md`
returns **two** commits, newest first:

```
3be27f0fd docs(pds-charter): wave-8 decisions D124-D144 — the sort is BOTH, TagRegistry is a second unguarded writer, the sentinel is scoped to 34 (#4743)
aac015edf docs(pds-charter): PDS-D39-D74 — land the stranded wave-3 ledger + the wave-4 crown-proof amendment (#4494)
```

Read honestly: the older commit `aac015edf` matches only because `-S` is a substring
search and it introduced the *different inflection* **"inverting"**, at `:361-362`, in an
unrelated context (mutation-testing scenarios S1/S7 of a 7-scenario probe). The exact
token is unique to D134's own commit:

```
$ git log --oneline -S 'to invert' -- .claude/workflows/bp-pds-charter.md
3be27f0fd docs(pds-charter): wave-8 decisions D124-D144 — ... (#4743)
```

So "invert" as a *guard-branch* concept enters the charter in the same commit that denies
it. There was never a prior inversion contract to honour.

**On the merits, stamp-clear is strictly stronger.** `Tenancy.provenance_covered?/2`
(`api/lib/barkpark/tenancy.ex:669-681`) is one boolean over one runtime input:

```elixir
defp provenance_covered?(%Content.SchemaDefinition{workspace_id: nil}, _dataset), do: false

defp provenance_covered?(%Content.SchemaDefinition{} = existing, dataset) do
  slug = existing.dataset || dataset

  existing.workspace_id
  |> get_workspace_by_id()
  |> pull_provenance(slug)
  |> map_size()
  |> Kernel.>(0)
end
```

Clearing the stamp exercises the whole chain — stamp data → predicate → skip branch →
sentinel survives. An inversion would short-circuit the *input* and could never prove the
stamp is load-bearing. It would also require shipping a force-disable flag, which the
charter forbids. **Wave 10 must not relitigate this.**

---

## 5. The coverage gap this record must name

Post-#4770 there are **TWO guard call sites**, using two faces of the same predicate:

| Site | Call | Face |
|---|---|---|
| `api/lib/barkpark/plugins/bootstrap.ex:205` | `Tenancy.pulled_schema_row?(attrs["name"], dataset)` | boolean |
| `api/lib/barkpark/content/tag_registry.ex:126` | `Tenancy.pulled_schema_row(attrs["name"], dataset)` | struct-or-nil |

**Rung 6 cannot see the second one.** `sentinel_scope_sql` at
`scripts/pds-pull-proof.sh:2031` scopes the sentinel away from exactly the row TagRegistry
writes:

```sh
sentinel_scope_sql() { # workspace_id -> the WHERE clause selecting exactly those 34
  printf "workspace_id = '%s' AND dataset = '%s' AND name NOT IN ('tag','metric')" \
    "$1" "$SOURCE_DS"
}
```

`tag` is the only row TagRegistry writes, and it is excluded. TagRegistry's guard is
therefore proven **by suite, not by rung** —
`api/test/barkpark/content/tag_registry_provenance_test.exs`, with an explicit negative
control:

```
 87:  describe "a pull-provenance-stamped `tag` row" do
 88:    test "survives ALL EIGHT columns and logs the drift — the clobber is closed", ctx do
102:    test "the skip RETURNS the surviving row, so `register!/1`'s contract is unbroken", ctx do
112:    test "the guard holds across REPEATED boots (convergence, not a one-shot)", ctx do
126:    test "CLEARING the stamp is a real escape hatch — the very next boot registers again", ctx do
138:    test "a stamp on a SIBLING dataset does NOT cover this one", ctx do
150:  describe "INSERT-when-absent stays unconditional (PDS-D126 / D12 fail-closed)" do
151:    test "a DELETED tag row inside a STAMPED slot is recreated, never silently skipped", ctx do
162:    test "the re-created row is itself stamp-covered, so the NEXT boot skips it", ctx do
176:  describe "negative control" do
177:    test "an UNSTAMPED slot keeps today's behaviour verbatim", ctx do
197:  describe "the guard predicate has ONE home" do
198:    test "Tenancy.pulled_schema_row/2 answers for the `tag` row both writers can touch", ctx do
210:    test "an ABSENT row is never 'pulled' — that is what keeps the insert unconditional" do
215:    test "non-binary input degrades to 'not pulled' rather than raising on the boot path" do
227:    test "a RAISE inside the guard's own read fails OPEN — the boot proceeds unguarded", ctx do
```

**COUNT CORRECTION.** This slice's brief and `pds-w9-faildemo-record`'s criterion 3 both
describe this as a "16-test suite". It is **12** tests, verified at
`origin/main:8b24003d1`:

```
$ git show origin/main:api/test/barkpark/content/tag_registry_provenance_test.exs | grep -cE '\btest "'
12
```

(5 + 2 + 1 + 4 across the four `describe` blocks.) The sibling
`api/test/barkpark/tenancy/workspace_pull_provenance_test.exs` also carries 12, so 16 is
not a sum of the two either — it is simply a miscount, corrected here rather than
propagated. The substance is unaffected: the negative control at `:177` exists, and the
suite is the only proof TagRegistry's guard has.

**The ruling this section exists for: a green rung 6 must never be read as covering
`tag_registry.ex:126`.** Rung 6 covers Bootstrap's 34 rows. TagRegistry is covered by a
test suite that runs in CI and by nothing on the ladder. Anyone reading a green climb as
"both writers proven" is reading it wrong.

---

## 6. Reproduce this record without re-running anything

```sh
SHA=8b24003d193373f621fbde181c61fc9248195a60

# the two demos, at source
bp task get pds-w8-rung6-sentinel -o json \
  | python3 -c 'import json,sys; [print(i, c["evidence"]) for i,c in enumerate(json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"])]'

# the charter ruling and the word's provenance
git show "${SHA}":.claude/workflows/bp-pds-charter.md | sed -n '1085,1092p'
git log --oneline -S 'to invert' -- .claude/workflows/bp-pds-charter.md

# the coverage gap
git show "${SHA}":scripts/pds-pull-proof.sh | sed -n '2030,2033p'
git show "${SHA}":api/lib/barkpark/plugins/bootstrap.ex   | grep -n pulled_schema_row
git show "${SHA}":api/lib/barkpark/content/tag_registry.ex | grep -n pulled_schema_row
git show "${SHA}":api/test/barkpark/content/tag_registry_provenance_test.exs | grep -cE '\btest "'

# the freeze is intact (blob OID, never shasum — PDS-D154)
git rev-parse origin/main:scripts/pds-pull-proof.sh   # e219e97ccf7f33797c86a2b84d998d599b6bda31
```
