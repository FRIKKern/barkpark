# cch-w35 — annotation precondition: s6's file set keeps the Elixir gate green-on-nothing

Verifier lane `annotation-precondition`, wave 35, 2026-08-06. origin/main = `c73bbc07c`.
All commands re-derive from `origin/main`, not the working tree.

## 1. The path matchers say what dispatches (verdict is the literal `true`/`false` on stdout)

```sh
cd /Volumes/SATECHI/github/barkpark
for s in cloud console; do git show origin/main:scripts/$s-path-escape-check.sh > /tmp/$s.sh; done
git show origin/main:scripts/elixir-path-escape-check.sh > /tmp/elixir.sh
printf 'cloud/priv/static/app.js\ncloud/priv/static/__app.test.mjs\n' > /tmp/s6files
echo "cloud=$(bash /tmp/cloud.sh   --match cloud   < /tmp/s6files)"   # true
echo "console=$(bash /tmp/console.sh --match console < /tmp/s6files)" # true
echo "elx_compile=$(bash /tmp/elixir.sh --match compile < /tmp/s6files)" # false
echo "elx_test=$(bash /tmp/elixir.sh    --match test    < /tmp/s6files)" # false
```

## 2. The full contamination list — anything here dispatches the Elixir gate and KILLS the annotation

```sh
bash /tmp/elixir.sh --print-set compile
bash /tmp/elixir.sh --print-set test
```

Note `scripts/required-checks-verify.sh` is NOT in either set (the direction's "a scripts/ touch
dispatches the gate" is too broad); `.github/workflows/elixir.yml` IS, and so are
`scripts/gate-announces-skips.test.sh`, `scripts/elixir-path-escape-check{,.test}.sh`,
`design/**`, `internal/taskboard/**`, `web/__tests__/**`, `docs/api-v1.md`, `docs/openapi.json`.
`.claude/workflows/*.md` and `tooling/grip/ledger/**` are clean.

## 3. The annotation only exists when nothing was dispatched

```sh
git show origin/main:.github/workflows/elixir.yml | sed -n '694,700p;735,740p;778,781p'
```
`dispatched` counts only path-gated jobs (`gate != NEVER`); the `::notice` fires under
`if [ "$dispatched" -eq 0 ]`. `on:` is `pull_request:` with NO workflow-level `paths:`
(line 65-68), so the check-run always exists on a cloud-only head.

## 4. The read-back, pre-staged (this is the exact invocation the builder must run)

```sh
H=$(gh pr view <PR> --json headRefOid -q .headRefOid)
ID=$(gh api "repos/:owner/:repo/commits/$H/check-runs" --paginate \
      -q '.check_runs[] | select(.name=="Elixir gate") | "\(.started_at)\t\(.id)"' | sort | tail -1 | cut -f2)
gh api "repos/:owner/:repo/check-runs/$ID/annotations" \
  | python3 -c "import json,sys; [print(repr(a['title']),'||',repr(a['message'])) for a in json.load(sys.stdin)]"
```
`repr()`, not `echo` — a shell echo hides exactly the truncation this criterion exists to catch.
The criterion must demand string EQUALITY with the full title
`Elixir gate: green — nothing ran`, never a substring/`grep -q` match: the truncated form
`Elixir gate: green` satisfies a substring test and is precisely the bug.

## 5. Precedent — the same file set already produced the annotation on a live head

PR #9738, head `fc3f802edaec5081ff92d84ead27f388b7c4c904`, files
`cloud/priv/static/{app.js,__app.test.mjs,__unknown_census.mjs}` — Elixir gate check-run
`92512650156`, conclusion success, `annotations_count=1`, message
"NOTHING ELIXIR RAN on this head. …". Its title read back as `'Elixir gate: green'`
because that head predates #9740 (title still carried a comma).

## 6. The truncation is UNFIXED-UNPROVEN, not fixed

`b41410134` ("#9740") replaced the comma with an em-dash on origin/main. As of
`c73bbc07c` no PR head carrying that text has greened-on-nothing, so the em-dash form has
never been delivered. Every readable title in the wild is the comma-era truncation:

```sh
for n in 9742 9741 9738 9734; do
  h=$(gh pr view $n --json headRefOid -q .headRefOid)
  gh api "repos/:owner/:repo/commits/$h/check-runs" --paginate \
    -q '.check_runs[] | select(.name|test("gate$")) | select(.output.annotations_count>0) | "\(.id)\t\(.name)"'
done
# -> Elixir gate: green / Security gate: green / Cloud gate: green / Console gate: green
```

## 7. The criterion indices — the direction's c1/c6 are already met

```sh
bp task get cch-w33-s5-gate-green-discloses-nothing-ran -o json   # criterion 2 of 11 = false
bp task get cch-w34-s3-disclosure-survives-delivery      -o json   # criterion 7 of 9  = false
```
(both tasks' final criterion is the lead-closed merge gate, also false by design).
