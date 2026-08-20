# PDS w44 — the pds-* instrument denominator, and what its "owning doc" actually owns

Re-derivation recipes. Every figure below is produced by the command beside it, at
`origin/main` (NOT the working tree: the primary checkout was **379 commits behind**
origin/main when these were taken — `git rev-list --count HEAD..origin/main` → `379`).

## The denominator

```sh
# 19 — executable-shaped pds instruments (.sh + .exs) on origin/main
git ls-tree -r --name-only origin/main scripts/ | grep -cE '^scripts/pds-.*\.(sh|exs)$'

# 17 — the same set minus the two .exs. This is the provenance of the "17".
git ls-tree -r --name-only origin/main scripts/ | grep -cE '^scripts/pds-.*\.sh$'

# 43 — a bare `scripts/pds-*` glob; 24 are .md runbooks and .txt transcripts, not instruments.
git ls-tree -r --name-only origin/main scripts/ | grep -c '^scripts/pds-'

# 3 (NOT 4) — harnesses whose subject is another pds instrument
git ls-tree -r --name-only origin/main scripts/ | grep -E '^scripts/pds-.*(_test|\.test)\.sh$'
#   scripts/pds-ledger-census_test.sh   -> pds-ledger-census.sh
#   scripts/pds-record-parity.test.sh   -> pds-record-parity.sh
#   scripts/pds-scratch-target_test.sh  -> pds-scratch-target.sh
```

Peer-instrument denominator, harnesses excluded: **19 − 3 = 16**.
Census-with-harnesses denominator (the row #9333 actually gates): **19**.
A census must PRINT which of the two it is using; the two differ by exactly the three
rows above, and each of those three is the only door its subject has.

## The gate leg, both halves

```sh
# Leg B — the declared set. EXACTLY ONE pds path is in it.
git show origin/main:scripts/elixir-path-escape-check.sh | sed -n '89,101p'
#   -> scripts/pds-status-only-residue.exs   (the only pds-* member)

# Leg A — an api/test/** file that literally shells a ../../../scripts/pds-* path
git grep -n '\.\./\.\./\.\./scripts/pds-' origin/main -- 'api/test/**'
#   -> api/test/barkpark/pds_residue_lens_test.exs:44

# Consumption — elixir.yml reads the set, it does not restate it
git grep -n 'elixir-path-escape-check' origin/main -- '.github/**'
#   -> .github/workflows/elixir.yml:196,197 (--match compile / --match test), :241, :244
```

**THROUGH (both legs) on landed origin/main: 1 of 19.**
`ELIXIR_TEST_ONLY_PATHS` also appears in `.github/workflows/studio-journey-smoke.yml:16`
— **inside a `#` comment**, not consumed. The "appears in no workflow yml" phrasing is
imprecise; the operative claim (single source of truth) survives.

## The owning doc

```sh
git show origin/main:docs/decisions/success-claim-census.md | grep -n 'pds-'
```
`docs/decisions/success-claim-census.md` (`canonical-for: success-claim-census`) names
exactly ONE pds instrument — `pds-elixir-receipt-census.exs` — and carries **no
instrument inventory of any kind**. It is the owning doc for *receipt claim sites*, not
for the *door/instrument census*. **No doc owns the instrument inventory.**

## D640's six stale terms, re-derived

```sh
D=$(mktemp -d); git archive origin/main api/lib scripts | tar -x -C $D
cd $D && elixir scripts/pds-elixir-receipt-census.exs 2>&1 | sed -n '266,305p'
```

| doc | line | doc says | live run | verdict |
|---|---|---|---|---|
| JUDGED | :159 | 65 | 67 | STALE |
| EXCLUDED | :161 | 180 | 178 | STALE |
| `action_not_in_corpus` row | :169 | 2 | class not emitted at all (2 classes: 40 + 138) | STALE — delete row |
| "claims success by STATUS alone" | :171 | present | script prints "That clause is RETIRED here" | STALE |
| JUDGED FRACTION | :173 | 72/252 = 28.6% | 67+7 = 74/252 = 29.4%; **the run prints no fraction at all** | STALE |
| "the false legend at :159" | :159 | — | legend text is **byte-identical** to the live run's | **DOES NOT REPRODUCE** — :159 is double-counted; five distinct terms, not six |

Doc figures that are NOT stale (checked, all still match the run): 469 routed entries ·
83 plugin specs · 17 `plugin_routes/1` · 252 population · ROSTERED 7 · UNDISPOSED 0 ·
sum 252 · liveview_handle_event 40 · status_only_receipt 138 · 804 corpus files ·
104/95/9/4/91 · classified 16 + unclassified 75 · depth 3 = 34/20/37 · depth 6 =
54/14/23 · POST-READ 15 · blind shapes 218/66/3 · `live_dashboard/2` at router.ex:2601.

## PDS-D636 — the census's false self-gating sentence, confirmed at source

```sh
git show origin/main:scripts/pds-elixir-receipt-census.exs | sed -n '10,11p'
```
> `scripts/pds-*` is in NEITHER Elixir path set (scripts/elixir-path-escape-check.sh),
> so this file costs no Elixir gate minute.

False as a class claim: `scripts/pds-status-only-residue.exs` IS in
`ELIXIR_TEST_ONLY_PATHS`. True only of the census file itself.

## Prices, OS meter around a shell (this host, NOT quiet)

```sh
cd $D && /usr/bin/time -p elixir scripts/pds-elixir-receipt-census.exs >/dev/null
#   real 65.51  user 21.27  sys 4.84   (script's own line: `wall clock 55621 ms`)
```
The script prints `wall clock N ms` — the exact unit PDS-D605 forbids — and its own
figure (55.6 s) disagrees with the OS wall (65.5 s) by ~10 s, which is the parent-BEAM
blindness PDS-D633 describes, in the census's own output.

```sh
cd $D && bash scripts/pds-record-parity.sh --selftest; echo rc=$?
#   rc=3 · "pds-record-parity: unknown argument '--selftest'"
```
