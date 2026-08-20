# PDS wave 37 — ledger hygiene re-derivation recipes (2026-08-01)

All measurements at `origin/main` = `501fb9670971998e5e5af05126cabfed3ea425bc`, host quiet,
Elixir run in a clean `git archive` tree (no `_build`, no app boot). Every recipe below
re-derives one fact from scratch and reports its own failure as a non-zero exit or a
visibly absent line. Nothing here reads the working checkout.

## 0. The clean tree every Elixir recipe uses

```bash
cd $(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main api/lib scripts | tar -x
elixir scripts/pds-elixir-receipt-census.exs        # RC 0, prints "CENSUS OK", ~7.4 s
```

## 1. The population at 501fb9670 (the register's denominator)

```bash
elixir scripts/pds-elixir-receipt-census.exs | grep -E 'CLASSIFICATION-TOTAL|UNCLASSIFIED +[0-9]'
# PASS  CLASSIFICATION-TOTAL     classified 16 + unclassified 75 == emitted 91
# UNCLASSIFIED                  75
```

EMITTED is 91 — stable, and the register's 91-row core is safe to size on it.
UNCLASSIFIED is **75**, not the 73 that `PDS-D505` and `pds-w34-census-cas-shadow`'s
description both state. The two-row move came from the wave-37 round-0 merges.

## 2. CAS-shadow set relation — instrument, never re-read

`shape_of/3` (census.exs:988) evaluates `selecting` / `reading_after` / `cas` and then a
`cond` picks ONE. To see the SET, print all three before the `cond`:

```bash
python3 - <<'EOF'
p='scripts/pds-elixir-receipt-census.exs'; s=open(p).read()
old='''    cas = Enum.find(candidates, &cas_confirmed?/1)\n\n    cond do'''
new='''    cas = Enum.find(candidates, &cas_confirmed?/1)\n\n    if System.get_env("PDS_SETPROBE") do\n      IO.puts(:stderr, "SETPROBE\\t#{site.path}:#{site.line}\\twrite=#{site.write?}\\tsel=#{selecting != nil}\\tread=#{reading_after != nil}\\tcas=#{cas != nil}")\n    end\n\n    cond do'''
assert old in s; open(p,'w').write(s.replace(old,new,1))
EOF
PDS_SETPROBE=1 elixir scripts/pds-elixir-receipt-census.exs 2>/tmp/setprobe.txt >/dev/null

# CAS \ POST-READ  — expect ZERO rows
grep '^SETPROBE' /tmp/setprobe.txt | awk -F'\t' '$3=="write=true" && $6=="cas=true" && $4=="sel=false" && $5=="read=false"' | wc -l
# 0        (out of 149 cas=true observations across all 12 sweep depths; ALL have sel=true)
```

The probe fires once per site per sweep depth (12 depths x 90 sites ~ 1092 lines), so it is
a depth-UNION. The authority for the census depth (6) is the script's own printed
`POST-READ SURVIVORS, BY ARM` block — 15 rows, all `[ARM 1 select:]`. Intersect them:

```bash
grep '^SETPROBE' /tmp/setprobe.txt | awk -F'\t' '$3=="write=true"&&$6=="cas=true"{print $2}' | sort -u > /tmp/cas.txt
# ...and the 15 printed survivors into /tmp/pr.txt (prefix api/lib/)
comm -23 /tmp/pr.txt /tmp/cas.txt   # POST-READ \ CAS -> api/lib/barkpark_web/controllers/oidc_controller.ex:82
comm -12 /tmp/pr.txt /tmp/cas.txt | wc -l   # 14  == CAS 0 -> 14 if promoted out of the shadow
```

**Verdict paid on these numbers**, not on the charter's: `pds-w34-census-cas-shadow` closed
`done` by `ledger-hygiene-w37`. Four of D505's five integers hold (CAS 0->14, POST-READ 15,
`CAS \ POST-READ` empty, `POST-READ \ CAS` = oidc:82 alone); its UNCLASSIFIED 73 is stale.
NOT re-verified here: D505's "same function supplies both halves" attribution.

Contingency, recorded not hidden: emptiness holds because today's only CAS idiom puts
`select:` on the same query. A measurement at one sha under one lens — never a standing invariant.

## 3. The selftest's zero-row floor (mutation, not a reading)

`keys_run/1` (census.exs:1264-1287) derives its TSV lines by mapping over `emitted`, and the
selftest case `KEYS-ONE-LINE-PER-SITE` (:1891-1899) is the only non-BASELINE case with
`mut: nil`. Its relation is tautological. Force the emission empty:

```bash
python3 - <<'EOF'
p='scripts/pds-elixir-receipt-census.exs'; s=open(p).read()
old='''    {_consumers, emitted} = Enum.split_with(ast_sites, & &1.pattern?)'''
new='''    {_consumers, _real} = Enum.split_with(ast_sites, & &1.pattern?)\n    emitted = []'''
assert old in s; open(p,'w').write(s.replace(old,new,1))
EOF
elixir scripts/pds-elixir-receipt-census.exs --keys 2>&1 | tail -1   # keys 0 · emitted 0 · normaliser …
elixir scripts/pds-elixir-receipt-census.exs --keys 2>/dev/null | wc -l   # 0
elixir scripts/pds-elixir-receipt-census.exs --selftest; echo RC=$?
#   PASS  KEYS-ONE-LINE-PER-SITE           exit 0 · TSV lines == keys == emitted, all off one run
#   SELFTEST OK — 9 cases, 5 of them mutants that went red as required.
#   RC=0
```

A green `--selftest` is compatible with `--keys` emitting NOTHING. Filed as
`pds-w37-selftest-zero-row-floor`.

## 4. The claim on `pds-w36-help-seal-fix` was NOT a blocker

Measured 21:08 UTC. The lead notes said "epoch 3, no `expired_at`, held by a dead worker".
Reality: epoch 4, `worker: null`, `expired_at` 21:05 (already past).

```bash
bp task claim pds-w36-help-seal-fix probe-verifier-w37    # -> epoch=5, RC 0, no epoch break needed
bp task release pds-w36-help-seal-fix probe-verifier-w37 5  # -> epoch=6, assignee cleared to null
```

The stale `assignee` (the dead builder) did NOT refuse the claim, and the release cleared it.
BUT `bp task next` is **not** a viable route: the ready head is saturated with priority-0 rows
and `pds-w36-help-seal-fix` is itself priority 0 among hundreds. Dispatch by task id.

## 5. `@declared` is keyed on a line number

```bash
git show origin/main:scripts/pds-elixir-receipt-census.exs | sed -n '126,132p;1198,1204p'
# @declared [ %{ path: "...auth_controller.ex", line: 399, ... } ...
# do: Enum.find(@declared, &(&1.path == path and &1.line == line))
```

`pds-w34-hand-bucket-register` criterion 0 excludes LINE from the new key on purpose. Filed
as `pds-w37-declared-key-migration`.

## 6. Class D is NOT in the charter

```bash
git show origin/main:.claude/workflows/bp-pds-charter.md | grep -nE 'Class D|delete/revoke|echo family'
# (no output — exit 1)
```

Absence refutes the DECISION, not the code. Filed UNJUDGED as
`pds-w37-class-d-echo-family-unjudged`.
