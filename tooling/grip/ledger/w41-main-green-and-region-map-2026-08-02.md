# PDS wave 41 — main-green + census region map (re-derivation recipes)

Observed at origin/main `20d61d1874a260fec273942dd32d7b4e29d86eb5` on 2026-08-02.
Every row below is a command, not a transcription. Re-run before quoting.

| subject | quantity | rerun | level |
|---|---|---|---|
| main head sha | pin | `git -C <repo> fetch origin main -q && git rev-parse origin/main` | L3 |
| main's own check-runs | per-commit feed, not the run rollup | `SHA=$(git rev-parse origin/main); gh api "repos/FRIKKern/barkpark/commits/$SHA/check-runs?per_page=100" -q '.check_runs[]\|[.name,.status,.conclusion]\|@tsv' \| sort` | L1 |
| non-success check-runs | names + conclusions only | `SHA=$(git rev-parse origin/main); gh api "repos/FRIKKern/barkpark/commits/$SHA/check-runs?per_page=100" -q '.check_runs[]\|select(.conclusion!="success" and .conclusion!="skipped")\|[.name,.conclusion,.id]\|@tsv'` | L1 |
| Sobelow finding count | counted off the DECIDING step's own scan output, never the job rollup | `gh api repos/FRIKKern/barkpark/actions/jobs/<job_id>/logs > sob.log; grep -n '##\[group\]Run mix sobelow' sob.log  # then read from that line to the next group; count `^…Detector.Name:` headers` | L1 |
| Sobelow breakdown | detector histogram | `sed -n '<scan-start>,<scan-end>p' sob.log \| sed 's/\x1b\[[0-9;]*m//g' \| grep -oE ' (Config\|Traversal\|SQL\|XSS\|CI\|DOS\|RCE\|Misc)\.[A-Za-z]+:' \| sort \| uniq -c \| sort -rn` | L1 |
| required-checks committed spec | 4 contexts | `git show origin/main:.github/required-checks.json \| python3 -c "import json,sys;print([c['context'] for c in json.load(sys.stdin)['protection']['required_status_checks']['checks']])"` | L2 |
| required-checks LIVE protection | 2 contexts | `gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.contexts'` | L1 |
| drift job's failing case | 1 of 115 | `gh api repos/FRIKKern/barkpark/actions/jobs/<job_id>/logs \| sed 's/\x1b\[[0-9;]*m//g' \| grep -E "^.*(FAIL\|passed, .* failed)"` | L1 |
| census health at this sha | rc + arms | `mkdir t && git archive origin/main \| tar -x -C t && cd t && elixir scripts/pds-elixir-receipt-census.exs; echo rc=$?` | L1 |
| census region map | def/attr line anchors | `grep -n '^  defp report_routed_population\|^  defp report_derivation_partition\|^  defp derive_row\|^  @derivation_order\|^  @derivation_residual\|^  @routed_excluded\|^  @selftest_cases' scripts/pds-elixir-receipt-census.exs` | L2 |
| residue-lens slice's declared surface | does it claim the census? | `bp task get pds-w40-residue-lens-can-fail -o json \| grep -o 'Surface: [^\\]*'` | L2 |

## Settled this run

- Two check-runs are RED on main's own head: `Sobelow static analysis (regression gate…)` and
  `Required-check spec drift (advisory)`. NEITHER is in live branch protection
  (`["Elixir gate","PR references an active task"]`), so neither blocks a merge.
- Sobelow deciding step (step 7, `mix sobelow --skip --exit Low`) reports **24** findings:
  9 Traversal.FileModule · 7 SQL.Query · 3 SQL.Stream · **3 Config.CSRF** · 2 CI.System.
  The itemization in circulation (9/7/3/2 = 21) OMITS the 3 Config.CSRF rows
  (`lib/barkpark_web/router.ex` pipelines `media_mutate`:604, `user_auth`:545, `session_token_root`:521).
  Use 24 with the 5-way breakdown as the baseline, or a real regression rides through as "unchanged".
- Drift job: 114 passed / 1 failed — case `§11 full mode reds on the committed spec — hgw2-s7's slice
  gate cannot pass`. Committed spec declares 4 contexts, live protection carries 2.
- `pds-w40-residue-lens-can-fail` is NOT a census claimant: its own description says
  "Surface: scripts/pds-status-only-residue.exs ONLY. Do NOT touch the census."
- Region map inside `scripts/pds-elixir-receipt-census.exs` (5479 lines):
  ladder print block 3697–3708, LiveView exclusion print block 3714–3719 — 5 lines apart,
  inside the same `report_routed_population/4` (3681). The residual slice's own defs
  (`@derivation_order` 3346, `@derivation_residual` 3357, `derive_row/3` 3398,
  `report_derivation_partition/2` 3728) are disjoint from both — but its CALL SITE
  (3711–3712) sits INSIDE the 5-line gap, so an arity/signature change is a hairline collision.
  All three append to `@selftest_cases` (4206) — assign head/tail.
