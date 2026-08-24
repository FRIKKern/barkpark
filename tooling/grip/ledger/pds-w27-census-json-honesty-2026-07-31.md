# pds-w27 — the certificate's machine mode is unpipeable exactly when it certifies

Re-derivation recipes for the wave-27 `json-honesty-certificate` verification.
Every command below was run 2026-07-31. The census is read from `origin/main` so
the recipe pins one known revision rather than whatever a checkout happens to be
on. (An earlier version of this line claimed the primary checkout "does not
carry `scripts/pds-ledger-census.sh`" — that has not been true since the script
was committed; `git ls-tree origin/main scripts/pds-ledger-census.sh` resolves.)

> **The census self-test now runs in CI** — `.github/workflows/shell-harnesses.yml`,
> job `pds-harnesses`, step `pds-ledger-census ordering + response-shape matrix`,
> triggered on any change to `scripts/pds-ledger-census*.sh`. Re-running the recipe
> below by hand is no longer how the instrument is kept honest
> (pds-bl-census-runs-in-no-ci-gate).

## 1. THE DEFECT — `--json --assert-round-done` is not valid JSON

```bash
# A DEDICATED scratch dir, never a bare `cd /tmp`: /tmp is the most
# scratch-file-polluted directory on the host, and the census reads code
# relative to its CWD — the shadowing hazard pds-w28-census-isolation fixed.
work=$(mktemp -d) && cd "$work"
git -C <repo> show origin/main:scripts/pds-ledger-census.sh > c.sh
bash c.sh --json --assert-round-done --anchor-from-paper pds-wave-27-2026-07-31 > c.out 2>c.err
echo rc=$?          # 1
jq -e . c.out; echo jq_rc=$?   # 5 — parse error: Invalid numeric literal
```

`census.sh:931-996` prints the whole ROUND-DONE PREDICATE block with bare
`print(...)` — stdout — after the JSON object at `:905`. `die()`, the retry
notices and the failure `VERDICT` lines all correctly use `file=sys.stderr`;
this one block does not.

## 2. THE DEFECT IS WORSE ON THE GREEN PATH (the certifying case)

`:1006-1007` — the success branch — also prints `""` + `VERDICT: ROUND DONE` to
stdout. Reproduce on the selftest's healthy fixture (build it from
`scripts/pds-ledger-census_test.sh` `build_healthy`, or copy the four
`page-N.http` files):

```bash
bash c.sh --root fixture-root --pace 0 --retries 0 --page-limit 4 \
  --fixture-dir <healthy> --assert-round-done --json > a.out
# rc=0 ; jq -e . a.out -> jq_rc=5  "parse error ... line 49"
```

Exit 0 — the certificate wave 27 exists to produce — is the case that cannot be
piped.

## 3. NO TEXTUAL CONSUMER OF THE STDOUT PREDICATE EXISTS

```bash
git grep -n -e 'assert-round-done' -e 'ROUND-DONE PREDICATE' -e 'VERDICT: ROUND' origin/main
```

Hits: `census.sh` itself, `pds-ledger-census_test.sh`, prose in
`.claude/workflows/bp-pds-charter.md`, and two `tooling/grip/ledger/*.md`
recipes that quote only `rc=`. Every selftest assertion captures `2>&1`
(`expect_status`, `expect_status_matching`, `expect_output_contains` in
`_test.sh:116-165`), so a move to stderr costs ZERO test rewrites. The charter
carries no rule placing the predicate on stdout (`grep -n stdout` on the charter
returns two unrelated lines, `:2110`, `:4636`).

## 4. THE FIX, PROVEN

Both halves, together: route the human block to stderr AND fold a machine
verdict into the JSON (`round_done` bool + `round_done_failures` list — the raw
payload today carries counts only, so a scripted consumer has no verdict path in
either mode).

```bash
# patched copy c2.sh; predicate lines collected then written to stderr,
# report["round_done"]/["round_done_failures"] set before the json dump
bash c2.sh --json --assert-round-done --anchor-from-paper pds-wave-27-2026-07-31 > b.out 2>b.err
jq -e -r '.round_done' b.out     # false ; jq_rc=0
bash scripts/pds-ledger-census_test.sh   # SELFTEST PASS: 80 checks
```

## 5. THE ONE CONSTRAINT THE BUILDER MUST RESPECT

Do NOT implement this by deferring the JSON emit until after the predicate is
computed. On `origin/main` the CLAUSE 5 incoherence path (exit 4, `:909-923`)
runs AFTER the emit and therefore still prints valid JSON:

```bash
bash c.sh  ... --fixture-dir <dupes> --assert-round-done --json  # rc=4, jq_rc=0, 985 bytes
bash c2.sh ... --fixture-dir <dupes> --assert-round-done --json  # rc=4, jq_rc=4, 0 bytes  <-- REGRESSION
```

The predicate is a pure function of `report`. Hoist it into one, call it before
the emit at `:904`, stash `round_done` into `report`, print once at the existing
site, then write the human lines to stderr.

## 6. THE SEVEN `usageErrf`-BYPASS DISPATCH SITES

`out.userErr` (`output.go:225`) is human-stderr only; `usageErrf`
(`errors.go:319`) emits `{ok:false,error:{code:"usage",...}}` on stdout in
machine mode. Seven non-test sites bypass it:

```bash
git grep -n 'out.userErr("unknown' origin/main -- internal/cli | grep -v _test
for c in 'provider bogusverb' 'cmux bogusverb' 'paper bogusverb' 'tinker --bogusflag' \
         'uninstall --bogusflag' 'upgrade --bogusflag' 'vercel bogusverb'; do
  bp $c -o json >/tmp/o 2>/tmp/e; echo "$c rc=$? bytes=$(wc -c </tmp/o)"
done
```

Measured (bp `dev` / commit `2c94b0ba7`): SIX are **empty stdout** at rc=2 —
`provider` (`cloud12_cmd.go:730`), `paper` (`paper_cmd.go:102`), `tinker`
(`tinker_cmd.go:72`), `uninstall` (`uninstall_cmd.go:63`), `upgrade`
(`upgrade.go:399`), `vercel` (`vercel_cmd.go:75`). ONE is **stdout prose**:
`cmux` (`cmux_cmd.go:67`) writes 851 bytes of human usage help to stdout under
`-o json`, so `bp cmux <typo> -o json | jq` is a parse ERROR, not an empty read.
Controls confirm the seam works where used: `bp scaffy bogusverb -o json` and
`bp task bogusverb -o json` both return a parseable envelope on stdout with
empty stderr.
