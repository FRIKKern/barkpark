<!-- doc-tier: agent | canonical-for: pds-schema-row-census | budget: 12000tok -->

# The 36 rows of `schema_definitions` — who writes each one, and on which leg

**What this is.** A committed derivation of the exclusion roster the wave-8 rung-6
sentinel rests on. PDS-D128 scopes that sentinel with a hand-typed literal —
`name NOT IN ('tag','metric')` — and PDS-D129 states plainly that no SQL discriminator
for "plugin-declared" exists, so the roster **cannot be derived from the table**. A
roster that cannot be derived and is not written down is a rot vector, and it is
precisely the vacuous-green shape this epic exists to kill. This file writes it down,
from evidence, with the command that produced each number.

**What this is NOT.** No engine code is changed here and no full-export attempt was
spent. `scripts/pds-pull-proof.sh` is not touched — it is frozen and a sibling slice
owns it. Nothing below re-measures the live box; every figure is either reproduced by a
command printed inline, or explicitly labelled **UNPROVEN HERE** and attributed to the
charter decision that measured it.

**Reproduced at** `origin/main` = `3be27f0fd1e4dcaeca2180c76b96a420ba064ea2` (fetched
2026-07-20). Line numbers move; the sha is the anchor. Every command below runs from the
repo root against that sha's working tree.

---

## 1. The taxonomy: 34 + `tag` + `metric` = 36

The wave-7 crown transcript reports the guarded-column digest over **`rows=36`** at all
three readings, while the target's own `server.log` shows **34 SKIP** on the stamped leg
and **34 REGISTER** on the cleared leg. That two-row gap went unexplained by every prior
wave. It is exactly the two rows below.

```
grep -n "rows=36" scripts/pds-pull-proof.crown-transcript.txt
```

> `:836  before reboot   guarded-column digest c3b6f2d3950a9a9ec8f5f13e9c4243a7 rows=36`
> `:838  after reboot    guarded-column digest c3b6f2d3950a9a9ec8f5f13e9c4243a7 rows=36`
> `:842  after guard-off c3b6f2d3950a9a9ec8f5f13e9c4243a7 rows=36`
> `:979  guarded-column digest, all three readings: c3b6f2d3950a9a9ec8f5f13e9c4243a7 rows=36`

The bundle manifest in the same transcript agrees independently — `"schema_definitions":36`
(transcript `:512`) — so 36 is the row count of the copied table, not an artefact of the
digest query.

### The 34, extracted rather than asserted

The transcript records each guarded row by name on both legs. Extract both sets and
compare them:

```
grep -o 'schema "[a-zA-Z]*"  \[SKIPPED - guard FIRED\]' \
  scripts/pds-pull-proof.crown-transcript.txt | sed 's/schema "//;s/".*//' | sort > /tmp/skip.txt
grep -o 'registered schema "[a-zA-Z]*"  \[REGISTERED - guard RELEASED\]' \
  scripts/pds-pull-proof.crown-transcript.txt | sed 's/.*schema "//;s/".*//' | sort > /tmp/reg.txt
wc -l < /tmp/skip.txt ; wc -l < /tmp/reg.txt ; diff /tmp/skip.txt /tmp/reg.txt && echo IDENTICAL
```

> `34` / `34` / `IDENTICAL`

The 34 names, in sorted order:

```
ability arena book bossAbility bossType cameraPreset command coordinatorLoop enemyType
gameClock hudElement mediaAsset mediaCollection overlay paper pickup player playerStat
projectileType quiz rune runRuleset scalingCurve sheet sound spreeTier task theme ticket
timeState upgradeCard vfx waveTemplate weapon
```

And neither `tag` nor `metric` appears in either set:

```
grep -x 'tag\|metric' /tmp/skip.txt /tmp/reg.txt ; echo "exit=$?"
```

> no output, `exit=1` — absent from both legs.

**This is the load-bearing result of this file.** The SKIP set and the REGISTER set are
the *same* 34 names, and that set is exactly the complement of `{tag, metric}` in the 36.
`36 − 34 = 2`, and the two are named. The roster in the sentinel's `NOT IN` is therefore
not a guess; it is the observed difference between what `Plugins.Bootstrap` walks and
what the table holds.

---

## 2. Why each class behaves the way it does, on both legs

| Class | count | stamp PRESENT (leg A) | stamp CLEARED (leg B) | writer |
|---|---|---|---|---|
| plugin-declared | 34 | **SURVIVE** (guard fires, `:ok` without update) | **REVERT** (guard released, `Repo.update` lands) | `Plugins.Bootstrap` |
| `tag` (at `3be27f0fd`) | 1 | **REVERTS** (4 of the 8 guarded columns) | **REVERTS** (same 4) | `Content.TagRegistry` |
| `tag` (post wave-8 guard) | 1 | **SURVIVES** — see the correction in §2 below | **REVERTS** (4 of 8) | `Content.TagRegistry` |
| `metric` | 1 | **SURVIVES** | **SURVIVES** | *nobody* |

Behaviour per class was measured live on a real reboot by the wave-8 verify fleet and is
recorded as PDS-D127 — **UNPROVEN HERE**, since this slice ran no boot. What *is* proven
here is the mechanism that makes each row fall into its class:

**The 34 — guarded, because Bootstrap consults provenance before updating.**
`api/lib/barkpark/plugins/bootstrap.ex:205-209` splits insert from update:

```
if pulled_row(attrs["name"], dataset) do
  skip_pulled(plugin_name, attrs["name"], dataset)
else
  do_upsert(plugin_name, attrs, dataset, scope)
end
```

`pulled_row/2` (`:269`) reads the would-be-matched row and asks
`provenance_covered?/2` (`:287-289`) whether its workspace/dataset slot carries a
`pull_provenance` stamp. Stamped → `skip_pulled/3` (`:305`) logs the `[warning]` line the
34-count above is extracted from and returns `:ok`. Unstamped → `do_upsert/4` (`:220`)
routes into `Content.upsert_schema/2` and the row reverts. Both legs, one branch.

**`tag` — unguarded, because a second boot-time writer never consults provenance.**
`api/lib/barkpark/content/tag_registry.ex:93` is `register!/1 → register_attrs!/2 →
Content.upsert_schema/2` with no provenance read anywhere in the module:

```
grep -c "pull_provenance\|Tenancy" api/lib/barkpark/content/tag_registry.ex
```

> `0`

`api/lib/barkpark/schema_bootstrap.ex:60` fires `TagRegistry.register!("production")`
before `register_all_schemas/0`, so `tag` is rewritten on **every** boot regardless of stamp
(PDS-D125). That is why it appears in neither the SKIP set nor the REGISTER set — it is
not on Bootstrap's path at all — and why it reverts on both legs.

> **CORRECTION 2026-07-20 (review) — the paragraph above describes the engine as it stood
> at the anchor sha `3be27f0fd`, and the SAME WAVE fixes it.** `pds-w8-tagregistry-guard`
> gives `TagRegistry.register_attrs!/2` the shared `Tenancy.pulled_schema_row/2` predicate,
> so from that merge onward `tag` is GUARDED on the update path. Three consequences a wave-9
> reader must not miss:
>
> 1. **The class behaviour changes.** `tag` no longer "reverts on both legs". Post-merge it
>    SURVIVES the stamped leg (like the 34) and REVERTS the cleared leg. Only its
>    INSERT-when-absent stays unconditional, on purpose (PDS-D126/D12).
> 2. **The `grep -c "pull_provenance\|Tenancy"` command above returns NON-ZERO post-merge.**
>    Its `0` is evidence *of the defect*, reproducible only at or before `3be27f0fd`.
> 3. **`tag` stays OUT of the sentinel roster regardless.** The `NOT IN ('tag','metric')`
>    exclusion is unchanged and still correct — but the reason narrows. It is no longer
>    "tag is unguarded"; it is that `tag` is written by a DIFFERENT writer whose skips are
>    logged under its own `TagRegistry:` prefix and must not be summed into Bootstrap's
>    count. §5's tripwire already specifies the Bootstrap-scoped grep, and the harness was
>    corrected at review to match it (an unscoped count reads 35 against 34 and reds ROSTER
>    DRIFT on a healthy target).
>
> What does NOT change: the arithmetic of §1. The 34 and the `rows=36` come from the wave-7
> transcript, which predates this fix, and the SKIP/REGISTER sets it extracts are Bootstrap's
> alone. The census baseline is intact; only `tag`'s per-leg row in §2's table moves.

**`metric` — never walked, because Bootstrap iterates the registry, not the table.**
`register_all_schemas/0` (`bootstrap.ex:61`) begins `plugins = Registry.all()` (`:63`) and
reduces over *that* list; a row with no declaring plugin is never visited by any code
path. Nothing writes it, so nothing can revert it, on either leg.

---

## 3. The four-of-eight split on `tag` is structural

A clobbering update reverts **eight** columns — `title`, `icon`, `visibility`,
`owner_scoped`, `fields`, `cors_origins`, `desk_groups`, `list_preview` — as documented
at `bootstrap.ex:250-254` and pinned by
`test/barkpark/plugins/bootstrap_default_slot_probe_test.exs`. On `tag`, only four of
those eight revert. That is not coincidence; it is a direct consequence of two facts.

**Fact one — `TagRegistry.schema_attrs/0` declares five keys, not eight.**

```
awk '/def schema_attrs do/,/^  end/' api/lib/barkpark/content/tag_registry.ex \
  | grep -oE '^      "[a-z]+" =>'
```

> `      "name" =>` `      "title" =>` `      "icon" =>` `      "visibility" =>` `      "fields" =>`

(The indent anchor matters: an unanchored `grep` also catches the `"name"` / `"title"` /
`"type"` keys of the two nested field maps at `tag_registry.ex:78-81`, which are the
*contents* of `fields`, not top-level params.)

Five keys: `name` (the identity, not a guarded column) plus `title`, `icon`,
`visibility`, `fields` — exactly the four that revert.

**Fact two — `Ecto.Changeset.cast/3` ignores keys absent from `params`.** The
changeset at `api/lib/barkpark/content/schema_definition.ex:60-80` casts nineteen keys:

```
awk '/\|> cast\(attrs, \[/,/\]\)/' api/lib/barkpark/content/schema_definition.ex \
  | grep -cE '^\s+:[a-z_]+,?$'
```

> `19`

`cast/3` only puts a change for a key *present* in `params`. `owner_scoped`,
`cors_origins`, `desk_groups` and `list_preview` are in the cast list but never in
TagRegistry's params, so they are never changed and the drifted values survive.

**The contrast that proves it is the writer, not the row.**
`Plugins.Bootstrap.upsert_one/3` (`bootstrap.ex:188-201`) builds its params the opposite
way:

```
attrs = schema |> Map.from_struct() |> Map.drop(@drop_keys) |> stringify_keys()
```

`Map.from_struct/1` yields **every** schema field, so all eight guarded columns are
present in `params` and all eight revert. Same changeset, same dataset, same stamp —
opposite outcomes, decided solely by how the params map was constructed.

### The rot risk, named

**If anyone adds a key to `TagRegistry.schema_attrs/0`, the survived set shrinks
SILENTLY.** Adding, say, `"owner_scoped"` to that five-key map moves `tag` from
four-of-eight to five-of-eight with no test failing, no log line changing, and no
assertion anywhere noticing — the split is an emergent property of two files that do not
reference each other. Any change to `schema_attrs/0` is a change to this census and must
re-run §1's extraction against a fresh transcript. This file is the only place that
statement is written down.

---

## 4. Where `metric` came from — and the bound on that answer

`metric` is present on guerrilla's live `/api/schemas` and is declared by no local
plugin:

```
grep -rn '"metric"' api/lib/barkpark/plugins/ ; echo "exit=$?"
```

> no output, `exit=1` — no plugin's `register_schemas/1` emits it.

It is an orphan, hand-inserted schema that the pull carries across with the rest of the
table. It has no declaring plugin, therefore no entry in `Registry.all()`, therefore no
visit from `Plugins.Bootstrap` on either leg.

**BOUND ON THE EVIDENCE — read this before quoting "metric is the only extra."** The row
was identified (PDS-D127) by diffing guerrilla's `/api/schemas` response (36 names)
against a pristine scratch boot (35 names), and `/api/schemas` serves
**publicly-visible rows only**. The claim this file is entitled to make is therefore:

> *Among rows with `visibility = 'public'`, `metric` is the sole schema present on
> guerrilla that a pristine local boot does not produce.*

A `visibility = 'private'` orphan would be invisible to that diff and would **not** have
been caught. Whether one exists is **UNPROVEN** — settling it needs a direct
`SELECT name FROM schema_definitions` against the target, which this slice did not run.
The count arithmetic in §1 is unaffected either way (it comes from the transcript's
`rows=36` and the extracted 34, not from the public list), but the *completeness* of the
`NOT IN` roster rests on this bound, which is exactly why §5's tripwire is load-bearing.

---

## 5. The sentinel's WHERE clause, and the assertion that keeps it honest

The clause, per PDS-D128, verified live to select exactly 34:

```sql
UPDATE schema_definitions
   SET ...                                  -- the eight guarded columns
 WHERE workspace_id = <the id stamp_before resolved>
   AND dataset      = '$SOURCE_DS'
   AND name NOT IN ('tag','metric')
RETURNING id;
```

Two scoping terms and one exclusion. The `workspace_id` term is why PDS-D132 requires
`stamp_before` to *capture* the id (`ORDER BY id LIMIT 1`) rather than merely prove one
exists. The exclusion is the roster this file derives.

**Why scope is the fix rather than a detail of it.** A table-wide sentinel — the natural
reading of "write a sentinel into the eight guarded columns on the pulled rows" — reds
leg A on `tag` (which reverts even with the guard working) and hangs leg B red **forever**
on `metric` (which never reverts, guard or no guard). The transcript would then show a
digest that moved with the stamp present, which reads exactly like *the guard failed*.
Getting the scope wrong does not weaken the rung; it inverts its verdict.

### The tripwire

```
assert  count(RETURNING rows)  ==  count of SKIP lines in the target's own server.log
```

The roster is hand-maintained and **cannot be derived in SQL**: `schema_definitions`
records nothing about which plugin declared a row (see §6), and `dataset_id IS NULL` is
an artefact of hand-insertion, not a source marker. So the literal will go stale — the
only question is whether it goes stale loudly.

This one cross-check is what makes it loud. Both sides are measured on the same run
against the same target: the left from the sentinel's own `RETURNING`, the right from the
`[warning] Plugins.Bootstrap: schema "…" sits in a PULLED workspace/dataset` lines
`skip_pulled/3` emits. They agree only when the roster names exactly the rows Bootstrap
declines to touch. Three real futures break that equality and each becomes a red instead
of a silent pass:

1. **A new guerrilla-only orphan** (another `metric`) — RETURNING counts it, no SKIP
   line exists for it, left > right.
2. **A third unguarded core writer** (another `TagRegistry`) — its row is sentinelled and
   then clobbered, and it produces no SKIP line, left > right.
3. **A plugin schema retired or added** — the SKIP count moves while the `NOT IN` literal
   does not, and the counts diverge in whichever direction the change went.

Without the assertion, all three degrade into a green rung asserting something about a
set that no longer matches reality — a vacuous green with a transcript to back it up,
which is worse than a red. PDS-D129 calls it load-bearing rather than belt-and-braces,
and that is the correct reading.

---

## 6. "No column records the source" — what was and was not reproduced

Enumerate the columns the application maps, and look for anything resembling a
plugin/source marker:

```
awk '/^  schema "schema_definitions" do/,/^  end/' api/lib/barkpark/content/schema_definition.ex \
  | grep -oE '^\s+(field|belongs_to) :[a-z_]+' | awk '{print $2}'
```

> `:name :title :icon :visibility :owner_scoped :fields :dataset :cors_origins :actions`
> `:groups :desk_groups :list_preview :initial_values :cross_validations :layout :prefill`
> `:workspace :project :dataset_entity`

Nineteen mapped names (the last three are the FK columns `workspace_id`, `project_id`,
`dataset_id`), plus `id` and the two `timestamps` = **22 columns reproduced here**. Not
one of them names a plugin, a package, or an origin. That much is proven.

**UNPROVEN HERE, and flagged rather than repeated:** PDS-D129 states the table has **23**
columns. That figure comes from an `information_schema.columns` query against the live
target, which this slice did not run. My reproducible count from the Ecto schema and the
migration tree is 22, so **one column is unaccounted for** — most likely a DB column with
no Ecto mapping, but that is a guess and is labelled as one. The gap does not move any
conclusion (the roster's underivability follows from the 22 enumerated names carrying no
source marker, and an unmapped 23rd column is by construction not one the application
writes), but it should be settled the next time anyone has a psql session on the target
rather than inherited as folklore.

---

## 7. Summary of the evidence grade

| Claim | Status |
|---|---|
| 36 rows in `schema_definitions` at the crown run | **PROVEN** — transcript `:836/:838/:842/:979` + manifest `:512` |
| The 34 SKIP names and the 34 REGISTER names are the same set | **PROVEN** — extraction in §1, `diff` returns IDENTICAL |
| `tag` and `metric` are in neither set | **PROVEN** — `grep -x` in §1, exit 1 |
| `TagRegistry.schema_attrs/0` declares 5 keys; the changeset casts 19 | **PROVEN** — commands in §3 |
| Bootstrap carries all 8 via `Map.from_struct`; TagRegistry carries 4 | **PROVEN** — `bootstrap.ex:188-201` vs `tag_registry.ex:72-83` |
| No plugin declares `"metric"` | **PROVEN** — `grep` in §4, exit 1 |
| Per-class survive/revert behaviour on a real reboot | **UNPROVEN HERE** — measured by the wave-8 verify fleet, PDS-D127 |
| The clause selects exactly 34 live | **UNPROVEN HERE** — verified live, PDS-D128 |
| `metric` is the *only* extra row | **BOUNDED** — true of publicly-visible rows only (§4) |
| The table has 23 columns | **UNPROVEN HERE** — 22 reproduced; one-column gap open (§6) |
