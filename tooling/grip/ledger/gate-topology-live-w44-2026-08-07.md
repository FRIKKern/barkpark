# Re-derivation recipes — wave 44 gate topology (verifier: gate-topology-live), 2026-08-07

Every line below re-derives from scratch. The local primary checkout is 49 ahead / 561 behind
origin/main and does NOT contain `scripts/console-path-escape-check.sh` or the census scripts —
read via `git show origin/main:` only.

## R1 — main's own live gate status + the required set

    cd /Volumes/SATECHI/github/barkpark && git fetch -q origin main \
      && SHA=$(git rev-parse origin/main) && echo $SHA \
      && gh api "repos/FRIKKern/barkpark/commits/$SHA/check-runs?per_page=100" \
           --jq '.check_runs[]|"\(.conclusion // .status)\t\(.name)"' | sort \
      && gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks'

## R2 — the Console gate decide body, executed with a synthetic upstream result set

    D=/tmp/w44 && mkdir -p $D
    git show origin/main:.github/workflows/console-harness.yml \
      | awk 'NR>=849 && NR<=1013' | sed 's/^          //' > $D/decide_body.sh
    env R_CHANGES=success R_UNIT=skipped R_CSSOM=skipped R_TIER=skipped \
        R_OVERFLOW=skipped R_ESCAPE=success O_CONSOLE=false bash $D/decide_body.sh; echo "EXIT=$?"
    # gate='true' variant must exit 1:
    env R_CHANGES=success R_UNIT=skipped R_CSSOM=success R_TIER=success \
        R_OVERFLOW=success R_ESCAPE=success O_CONSOLE=true bash $D/decide_body.sh; echo "EXIT=$?"

## R3 — dispatcher verdict for any path (console / cloud / elixir)

    D=/tmp/w44 && mkdir -p $D/scripts
    for s in console cloud elixir; do
      git show origin/main:scripts/$s-path-escape-check.sh > $D/scripts/$s-path-escape-check.sh
    done
    printf '%s\n' scripts/foo.mjs | bash $D/scripts/console-path-escape-check.sh --match console
    printf '%s\n' cloud/priv/static/app.js | bash $D/scripts/cloud-path-escape-check.sh --match cloud

## R4 — the console-unit step order (which census masks which)

    git show origin/main:.github/workflows/console-harness.yml \
      | awk 'NR>=209 && NR<=525 && /^      - name:/ {c++; printf "%d\t%s\n", c, $0}'

## R5 — the declared console path set

    git show origin/main:scripts/console-path-escape-check.sh | sed -n '142,156p'
