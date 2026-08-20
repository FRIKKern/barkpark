<!-- doc-tier: agent | canonical-for: pds-tagregistry-rung-ruling | budget: 12000tok -->

# The TagRegistry guard gets no rung — and `metric` is not a comparable gap

**Ruling: NO RUNG. Suite-only coverage is the standing position for the TagRegistry
pull-provenance guard.** Recorded under PDS-D187, discharging the backlog item
`pds-bl-tagregistry-guard-no-rung`, which sat open at 0/4 demanding a written decision either
way. This file IS that decision. It does not add a rung, does not touch
`scripts/pds-pull-proof.sh`, and does not amend the charter.

Every number below was **re-derived in the branch that carries this file**, not copied from
wave briefing material. Two figures in circulation were wrong and are corrected here (§3).

---

## 1. What the ruling actually means

The `tag` row's guard is proven by an ExUnit suite against a real DB-sandboxed row, and by
nothing else. It has never been verified by the crown-proof ladder against a real booted
target, and under this ruling it will not be. That gap is **accepted and named**, not closed
and not hidden: a reader of any future climb transcript should understand that the silence
around `tag` at rung 6 is a decision, not an oversight (§5).

---

## 2. The three reasons, each independently checkable

### 2.1 The engine fix is already merged and suite-proven

The defect PDS-D125 named — TagRegistry as the **second** unguarded boot-time schema writer,
the one every prior wave's "Bootstrap is the only clobber path" premise missed — is closed in
code on `main`:

| Fact | Where |
|---|---|
| `alias Barkpark.Tenancy` exists in TagRegistry (it did not, pre-fix) | `api/lib/barkpark/content/tag_registry.ex:54` |
| `register_attrs!/2` branches on the guard predicate | `api/lib/barkpark/content/tag_registry.ex:125-129`, the `case` at `:126` |
| The stamped branch skips the content UPDATE only | `tag_registry.ex:134` `defp skip_pulled/2` |
| The absent branch registers unconditionally | `tag_registry.ex:146` `defp do_register!/2` |

The build task `pds-w8-tagregistry-guard` is `lifecycle_status: done`.

> **Correction to the brief, made honestly.** The brief for this ruling states that task is
> "done 4/4". It is **done at 4 of 6 criteria met**. The four met are the build obligations
> (defect-exists test, unconditional-INSERT test, one-implementation check, Bootstrap
> unchanged). The two unmet are criterion 4 (the differential sentence in the PR body) and
> criterion 5 ("PR merged to main"), which is lead-closed on merge by standing convention. The
> engine claim this ruling rests on — the fix exists and is test-covered — is carried entirely
> by the four that are met. Recording 4/6 rather than repeating 4/4 is the point of
> re-deriving.

What remains open is therefore **only** that the fix is suite-proven and never
ladder-verified. That is the whole of the gap.

### 2.2 The suite is real, not theater

`api/test/barkpark/content/tag_registry_provenance_test.exs` — 12 tests, five describe blocks:

- **`"a pull-provenance-stamped tag row"` (`:87`)** — asserts survival of **all eight guarded
  columns**, including the four that `Ecto.Changeset.cast/3` silently drops when absent from
  params (`owner_scoped`, `cors_origins`, `desk_groups`, `list_preview` — `:16-17`, asserted
  `:190-191`). It also covers repeated boots (`:112` — convergence, not a one-shot), the
  escape hatch (`:126` — clearing the stamp registers again on the very next boot), and
  sibling-dataset non-coverage (`:138`).
- **`"INSERT-when-absent stays unconditional"` (`:150`)** — a deleted `tag` row inside a
  **stamped** slot is recreated, never silently skipped (`:151`), and the recreated row is
  itself stamp-covered (`:162`).
- **`"negative control"` (`:176`)** — a genuine one: an **unstamped** slot keeps today's
  (pre-fix, clobbering) behaviour verbatim (`:177`). A guard deleted from the codebase would
  make this test's siblings fail; this test is what proves the suite is measuring the stamp
  and not the weather.
- **`"the guard predicate has ONE home"` (`:197`)** — pins the shared predicate, including
  that an absent row is never "pulled" (`:210`), which is precisely what keeps the insert
  unconditional.
- **A fail-open test that forces a real raise** (`:227`) — a raise inside the guard's own read
  fails OPEN and the boot proceeds unguarded. This matches the engine's own stated contract
  (`tenancy.ex:636-638`: "losing the guard is recoverable, a boot loop is not").

A suite with a negative control, an eight-column assertion, and a forced-raise path is not a
green a broken build could also produce — the PDS-D20 bar. It is weaker than a ladder rung in
**reach** (no real booted target), not in **honesty**.

### 2.3 Adding a rung now is a PDS-D100 thaw

PDS-D100: every harness change lands in PREFLIGHT, before attempt 1; from attempt 1 onward the
harness is FROZEN, and each red sorts into HARNESS BUG or ENGINE FAIL *before anything is
touched*. The freeze is what makes the transcript trustworthy — "it removes the climber's
ability to edit a red away exactly when doing so is most tempting."

The harness is frozen at blob `e219e97ccf7f33797c86a2b84d998d599b6bda31`
(`git rev-parse HEAD:scripts/pds-pull-proof.sh`, verified from this branch). Adding a rung is
instrument work during the very wave issuing the crown verdict — the exact act the freeze
forbids. A rung for the `tag` guard, if it is ever wanted, is **preflight work for a future
climb**, filed and landed before that climb's attempt 1. It is not wave-9 work.

---

## 3. Two errors in circulation, corrected

### 3.1 The count is 12, not 16

Re-derived by running it (`CC=clang mix test`, from `api/`, this branch):

```
$ CC=clang mix test test/barkpark/content/tag_registry_provenance_test.exs
Running ExUnit with seed: 201989, max_cases: 20
............
Finished in 0.2 seconds (0.00s async, 0.2s sync)
12 tests, 0 failures
```

The three-file gate — the provenance suite plus `tag_registry_test.exs` plus
`bootstrap_guard_test.exs` — totals **32**:

```
$ CC=clang mix test test/barkpark/content/tag_registry_provenance_test.exs \
    test/barkpark/content/tag_registry_test.exs \
    test/barkpark/plugins/bootstrap_guard_test.exs
Running ExUnit with seed: 866979, max_cases: 20
Finished in 1.5 seconds (0.00s async, 1.5s sync)
32 tests, 0 failures
```

**12, not 16. 32 for the gate.** Any document repeating 16 is wrong.

### 3.2 ONE predicate with TWO FACES, not two implementations

There is a single implementation and a one-line boolean wrapper over it:

| Face | Location | Returns |
|---|---|---|
| Value-returning (the implementation) | `api/lib/barkpark/tenancy.ex:642-660` | the `%SchemaDefinition{}` or `nil` |
| `@canonical` marker over it | `tenancy.ex:641` — `capability:pull-provenance-schema-guard` | — |
| Boolean face (one line, delegates) | `tenancy.ex:667` — `def pulled_schema_row?(name, dataset), do: not is_nil(pulled_schema_row(name, dataset))` | `boolean()` |

`:642-660` spans both clauses of the implementation: the guarded binary clause at `:642` and
the catch-all `def pulled_schema_row(_name, _dataset), do: nil` at `:660`. The rescue that
makes the read fail-open lives inside it.

Both call sites:

- `api/lib/barkpark/plugins/bootstrap.ex:205` — calls the **boolean** face.
- `api/lib/barkpark/content/tag_registry.ex:126` — calls the **value-returning** face, because
  its skip path logs the surviving row.

**What differs between the callers is SKIP SCOPE, not the predicate.**

```
Bootstrap (bootstrap.ex:205-209)          TagRegistry (tag_registry.ex:125-129)
  stamped? -> skip the whole upsert         stamped? -> skip only the content UPDATE
  absent   -> do_upsert                     absent   -> do_register!  (UNCONDITIONAL)
```

The asymmetry is deliberate and load-bearing (PDS-D126): a naive copy of Bootstrap's skip into
TagRegistry would make core `tag` registration silently skippable on a stamped workspace,
trading a clobber bug for a boot-closed-guarantee bug. `TagRegistry.register!/1` is fired from
`api/lib/barkpark/schema_bootstrap.ex:60`, **outside** the boot rescue, precisely so a missing
core `tag` schema fails the boot CLOSED rather than booting a system whose publish wall can
resolve no tag at all. The predicate returns `nil` when there is no row, so the insert simply
proceeds — one predicate, two policies.

> Note on the D12 citation: the charter's PDS-D126 and the code comment at `tag_registry.ex`
> both cite "D12" for this fail-closed placement. The charter's numbered **PDS-D12** entry is
> the media-honesty decision; the fail-closed-boot rule is carried by D126 itself and by the
> code comment. Cite **PDS-D126** for the asymmetry; treat the bare "D12" reference as the
> inherited shorthand it is.

---

## 4. `metric` is a different thing entirely — proof of ABSENCE

`metric` must **not** be folded into the TagRegistry framing. It is not a second unguarded
writer. It is not a comparable gap. There is **no writer at all**.

The proof is a grep returning zero, run from this branch:

```
$ grep -rn '"metric"' api/lib
(zero matches)

$ grep -rnE "(INSERT INTO|UPDATE) schema_definitions" api/priv/repo/migrations | grep -i metric
(zero matches)

$ grep -rn 'name: "metric"\|name: :metric\|"name" => "metric"' api/lib api/priv/repo/migrations
(zero matches)
```

The first grep is the strong one: the string literal `"metric"` does not appear **anywhere**
in `api/lib`. No plugin declares it, no migration inserts it, nothing updates it. (The word
`metric` does occur in two migrations — `20260715000400` and `20260719010000` — purely as a
PL/pgSQL loop variable over `jsonb_each(costs)` in the epic-benchmark ledger. Unrelated to
`schema_definitions`, and matched by neither of the targeted greps.)

Per **PDS-D127**, `metric` is the 36th row: a **live-only orphan** on guerrilla, identified by
diffing live `/api/schemas` (36 names) against a pristine scratch boot (35). Declared by no
local plugin, it is never visited by Bootstrap's `Registry.all()` walk — which is exactly why,
measured on both legs of a real reboot, the 34 plugin-declared rows SURVIVE stamped and REVERT
cleared, `tag` REVERTS on both legs, and **`metric` SURVIVES FOREVER on both**.

Therefore:

- **Zero coverage of `metric` is CORRECT, not missing.** Coverage measures a writer's
  behaviour. There is no writer to cover.
- **Including it would hang leg B red forever** (**PDS-D128**). A table-wide sentinel reds leg
  A on `tag` and never clears on `metric`, and the transcript would show a digest that moved
  with the stamp present — which reads exactly like "the guard failed." The harness already
  scopes around this: `name NOT IN ('tag','metric')`, verified live to select exactly 34.

`tag` has a writer that was buggy and is now fixed but only suite-proven. `metric` has no
writer. The two are not the same shape of gap and must never be listed side by side as if they
were.

---

## 5. Standing transcript obligation

Rung 6 already scrapes the TagRegistry skip and **deliberately does not assert on it**:

- `scripts/pds-pull-proof.sh:2226` — `tag_skip_count` is grepped from the boot log.
- `:2228-2229` — reported as info, with the reason stated inline: *"The TagRegistry count is
  reported, NOT asserted: `SchemaBootstrap.init/1` hardcodes dataset "production", so it is
  legitimately 1 when SOURCE_DS is production and 0 otherwise."* (`schema_bootstrap.ex:60`
  is the hardcode. **PDS-D145**.)
- `:2248` and `:2336` — the ROSTER DRIFT assertion and the rung-6 pass line both explicitly
  **exclude** the `tag` row's own skip from both sides of the comparison, on purpose. Including
  it would red a healthy target at 35-against-34 — a false red caused by the sibling fix in the
  same wave.

**The obligation, standing until a future preflight revisits it:** every future climb
transcript states (a) that the TagRegistry guard's coverage is **suite-only**, per this
ruling, and (b) that `tag_skip_count` is **scraped but unasserted**, per PDS-D145 — so that a
later reader does not mistake the silence for an oversight. The number is informational
context for the rung-6 counts, never a pass condition.

---

## 6. Scope of this file

- **Does** record the NO RUNG ruling, its three reasons, the two corrections, the `metric`
  absence proof, and the transcript obligation.
- **Does not** edit `scripts/pds-pull-proof.sh` (blob unchanged at
  `e219e97ccf7f33797c86a2b84d998d599b6bda31`), add a rung, or amend the charter — PDS-D187
  carries the ruling there, landed by a sibling wave-9 slice.

**Charter-state note.** At the time this file was written, the charter in-tree
(`.claude/workflows/bp-pds-charter.md`) carried decisions through **PDS-D144**. PDS-D145 and
PDS-D187, both cited above, are wave-9 decisions landing via the sibling "stranded charter
decisions" slice. Their content is quoted here from the wave-9 record and is consistent with
the frozen harness's own inline reasoning at `:2229`, which is the independent check.

---

## 7. How to re-verify this document

```bash
cd api
CC=clang mix test test/barkpark/content/tag_registry_provenance_test.exs      # expect 12 tests, 0 failures
CC=clang mix test test/barkpark/content/tag_registry_provenance_test.exs \
  test/barkpark/content/tag_registry_test.exs \
  test/barkpark/plugins/bootstrap_guard_test.exs                              # expect 32 tests, 0 failures
cd ..
grep -rn '"metric"' api/lib                                                   # expect zero matches
git rev-parse HEAD:scripts/pds-pull-proof.sh                                  # expect e219e97ccf7f33797c86a2b84d998d599b6bda31
grep -rn '@canonical capability:pull-provenance-schema-guard' api/lib         # expect exactly one hit, tenancy.ex:641
```
