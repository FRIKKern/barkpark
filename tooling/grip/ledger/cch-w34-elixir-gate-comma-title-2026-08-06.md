# cch-w34 [elixir-gate-comma] — the disclosure title is comma-truncated 4x, and the ratchet is blind to the title field

Verifier re-derivation recipes. Every row is one literal command; no prose stands in for output.

## R1 — the comma-bearing `::notice title=` idiom is 4x, one per aggregator

```
cd /Volumes/SATECHI/github/barkpark && for f in elixir cloud console-harness security; do echo "--- $f"; git show origin/main:.github/workflows/$f.yml | grep -n '::notice title='; done
```

Expect: `elixir.yml:779`, `cloud.yml:407`, `console-harness.yml:750`, `security.yml:586`, each
`::notice title=<X> gate: green, nothing ran::NOTHING <X> RAN on this head.%0A…`.

## R2 — repo-wide census: 4 of 9 `::notice title=` sites carry a comma, and they are exactly the four aggregators

```
cd /Volumes/SATECHI/github/barkpark && for f in $(git ls-tree -r --name-only origin/main .github/workflows/); do out=$(git show origin/main:$f | grep -n '::notice title=' || true); [ -n "$out" ] && echo "--- $f" && echo "$out"; done
```

Comma-free (deliver intact): `pr-task-gate.yml:223` (`Hotfix lane`), `reland-check.yml:67`
(`Re-land check skipped`), `release.yml:162` (`Dry-run mode`), `retag.yml:84/101/108`.
No `::error`/`::warning title=` anywhere carries a comma.

## R3 — GitHub DELIVERS the truncated title (live, all four gates, PR #9677)

```
cd /Volumes/SATECHI/github/barkpark && sha=$(gh pr view 9677 --json headRefOid -q .headRefOid); for cr in $(gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" -q '.check_runs[] | select(.name|endswith(" gate")) | "\(.id):\(.name)"'); do id=${cr%%:*}; echo -n "${cr#*:} -> "; gh api "repos/:owner/:repo/check-runs/$id/annotations" -q '.[]|select(.annotation_level=="notice")|.title' 2>/dev/null | head -1; echo; done
```

Expect `Elixir gate: green` / `Cloud gate: green` / `Console gate: green` / `Security gate: green` —
`, nothing ran` gone in all four. `,` is the workflow-command property separator; ` nothing ran`
parses as a valueless property and is dropped.

Single-gate form (the assignment's pin):

```
gh api repos/:owner/:repo/check-runs/92495314414/annotations -q '.[] | [.annotation_level,.title] | @tsv'
```

The BODY survives intact — same call without `-q` returns the full four-line `message` including
`Not dispatched: mix-test mix-prod-compile validation-perf`.

## R4 — the ratchet passes 106/0 on origin/main (script is NOT in this checkout; HEAD is behind)

`git cat-file -e HEAD:scripts/gate-announces-skips.test.sh` → *does not exist in HEAD*. Materialize
origin/main and run:

```
S=$(mktemp -d); mkdir -p $S/scripts $S/.github/workflows; cd /Volumes/SATECHI/github/barkpark; git show origin/main:scripts/gate-announces-skips.test.sh > $S/scripts/gate-announces-skips.test.sh; for f in elixir cloud console-harness security; do git show origin/main:.github/workflows/$f.yml > $S/.github/workflows/$f.yml; done; bash $S/scripts/gate-announces-skips.test.sh; echo EXIT=$?
```

Expect `106 passed, 0 failed` / `EXIT=0`.

## R5 — THE MUTATION: delete the title property outright, ratchet STILL 106/0

```
S=$(mktemp -d); mkdir -p $S/scripts $S/.github/workflows; cd /Volumes/SATECHI/github/barkpark; git show origin/main:scripts/gate-announces-skips.test.sh > $S/scripts/gate-announces-skips.test.sh; for f in elixir cloud console-harness security; do git show origin/main:.github/workflows/$f.yml > $S/.github/workflows/$f.yml; done; python3 -c "
import sys;p='$S/.github/workflows/elixir.yml';s=open(p).read()
o='::notice title=Elixir gate: green, nothing ran::';assert o in s
open(p,'w').write(s.replace(o,'::notice::',1))"; bash $S/scripts/gate-announces-skips.test.sh | tail -3; echo MUT_EXIT=${PIPESTATUS[0]}
```

Expect `106 passed, 0 failed`. The ratchet has NO assertion on the title field. `notice_has_name`
survives the deletion because the gate name also appears in the body sentence
(`Elixir gate is green because…`). So the title can be truncated, gutted, or removed entirely and
the ratchet stays green — clause-4 blindness on the epic's own disclosure instrument.

## R6 — the shipped title was never in the proven probe

Charter `.claude/workflows/bp-cloud-console-hardening-charter.md:779` records the probe form as a
BARE `echo "::notice::NOTHING ELIXIR RAN…"` with no `title=`. D378 (charter:652) says the probe
"worked with `title=`" but names no comma-bearing instance. The comma title is a post-probe addition
shipped in `f1fd89ddb` (#9689) and measured by nothing.

```
cd /Volumes/SATECHI/github/barkpark && grep -n '::notice' .claude/workflows/bp-cloud-console-hardening-charter.md
```

## R7 — no prior art

```
bp search query "notice title comma truncated annotation gate" ; bp search query "gate-announces-skips"
```

Neither returns a row naming the truncation. `cch-w33-s5-gate-green-discloses-nothing-ran` is the
parent row; it does not cover the title.

## The fix that can lose

One character per file (drop the comma, e.g. `title=<X> gate: green — nothing ran`, or
`title=<X> gate ran nothing`) + one ratchet assertion that FAILS on a comma in the title property,
proven by a planted mutant that reinstates it. D378's "match MESSAGE TEXT, never counts" is already
honoured by cases 4-5 and is untouched by this.
