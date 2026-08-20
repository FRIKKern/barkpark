# cch-w34 — "cloud/** skips the whole Elixir suite" is REFUTED; the live finding is the truncated title

Re-derivation recipes. Every line below was run 2026-08-06 against `origin/main`
(`f1fd89ddb` era) and the live GitHub API. No repo state was mutated.

## R1 — the premise, both arms (the assigned MUST-RUN)

    cd /Volumes/SATECHI/github/barkpark
    git show origin/main:scripts/elixir-path-escape-check.sh > /tmp/epc34.sh
    printf 'cloud/lib/barkpark_cloud/web/router.ex\n' | bash /tmp/epc34.sh --match compile   # -> false, exit 0
    printf 'cloud/lib/barkpark_cloud/web/router.ex\n' | bash /tmp/epc34.sh --match test      # -> false, exit 0
    git show origin/main:scripts/elixir-path-escape-check.sh | grep -c cloud                  # -> 0

TRUE as stated: `cloud/**` is in NEITHER Elixir path set. Not a hole — see R2.

## R2 — the refutation: the Cloud gate owns cloud Elixir

    git show origin/main:scripts/cloud-path-escape-check.sh > /tmp/cpc34.sh
    printf 'cloud/lib/barkpark_cloud/web/router.ex\n' | bash /tmp/cpc34.sh --match cloud      # -> true
    bash /tmp/cpc34.sh --print-set cloud                                                      # first line: cloud/**
    git show origin/main:cloud/mix.exs | head -12                                             # app: :barkpark_cloud — SEPARATE mix project
    git show origin/main:cloud/mix.exs | grep -n 'path:'                                      # rc=1: no path dep on api/
    git show origin/main:.github/workflows/cloud.yml | sed -n '267,275p'                       # mix compile --warnings-as-errors; mix test
    gh api repos/:owner/:repo/branches/main/protection -q '.required_status_checks.contexts'   # Cloud gate is REQUIRED

## R3 — the reverse hole does not exist either (api suite never reads cloud/)

    ELIXIR_PATH_ESCAPE_ROOT=/Volumes/SATECHI/github/barkpark bash /tmp/epc34.sh --list-escapes | grep -ci cloud   # -> 0
    ELIXIR_PATH_ESCAPE_ROOT=/Volumes/SATECHI/github/barkpark bash /tmp/epc34.sh | tail -3                          # 25 reads, all dispatched

TRAP: running `/tmp/epc34.sh` without `ELIXIR_PATH_ESCAPE_ROOT` resolves
`REPO_ROOT=/` (dirname of /tmp, then `..`) and reports 0 reads. Its floor of 8
catches it and exits 1 — a live demonstration that the fail-closed floor works.
Any re-derivation from a copied script MUST set the env var.

## R4 — the live finding: all four gate disclosures lose their title at the comma

    gh api repos/:owner/:repo/check-runs/92495314414/annotations -q '.[]|.title'   # -> "Elixir gate: green"
    sha=dad4b33bbab29432280ee5c04c3dfd23af9f6934
    for n in "Cloud gate" "Console gate" "Security gate"; do
      id=$(gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" -q ".check_runs[]|select(.name==\"$n\")|.id")
      gh api repos/:owner/:repo/check-runs/$id/annotations -q '.[]|.title'
    done
    # -> "Cloud gate: green" / "Console gate: green" / "Security gate: green"

Emitted (elixir.yml:779, cloud.yml:407, console-harness.yml:750, security.yml:586):
`::notice title=<Gate>: green, nothing ran::...`. `,` is the workflow-command
property separator, so the title is cut there. Message body survives intact.

## R5 — the wave-33 guard cannot lose on this axis

    git show origin/main:scripts/gate-announces-skips.test.sh | grep -n 'notice_has\|notice_says\|notice_names\|title'

Every emitted fact keys on the MESSAGE body (`notice_has_sentinel`,
`notice_says_not_tested`, `notice_says_not_applicable`, `notice_names_skipped`).
Nothing asserts the DELIVERED title. Guard green, title inverted.

## R6 — fence

    sed -n '172,200p' .claude/workflows/bp-cloud-console-hardening-charter.md

D377 grants exactly these four aggregator files + `scripts/gate-announces-skips.test.sh`
under the subject "an aggregator gate's GREEN conclusion must disclose that nothing
was dispatched, on the surface a human and a merge queue actually read." The
truncation is that same subject. No new widening needed; a FIFTH file would.
