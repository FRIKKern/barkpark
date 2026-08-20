# PDS wave 48 — second read on the FOREIGN price re-opener (2026-08-05)

Verifier lane `round2-foreign-price-second-read`. Every row below is a command a stranger
(or a later wave) can re-run. `curl` rows carry NO credentials on purpose — that is the point
of the lane. `gh` rows are the authenticated control.

## A. Can an UNAUTHENTICATED stranger re-open a run / job on this repo?

    curl -s -o /dev/null -w 'UNAUTH_RUN=%{http_code}\n' https://api.github.com/repos/FRIKKern/barkpark/actions/runs/25024987220
    curl -s -o /dev/null -w 'UNAUTH_JOB=%{http_code}\n' https://api.github.com/repos/FRIKKern/barkpark/actions/jobs/73293996420
    curl -s https://api.github.com/repos/FRIKKern/barkpark/actions/runs/25024987220 | python3 -c 'import json,sys;d=json.load(sys.stdin);print({k:d.get(k) for k in ["id","head_sha","conclusion","created_at","html_url"]})'

YES for metadata (200/200, repo is public). Unauth budget: 60 req/hr —
`curl -s -D- -o /dev/null https://api.github.com/rate_limit | grep -i x-ratelimit-limit`.

## B. Logs — the form criterion 7 names ("quotes the metered line from the runner log")

    curl -s -o /dev/null -w 'UNAUTH_LOGS=%{http_code}\n' -L https://api.github.com/repos/FRIKKern/barkpark/actions/runs/29261030044/logs      # 403, at ANY age
    curl -s -o /dev/null -w 'ANON_WEB_STEPLOG=%{http_code}\n' -H 'User-Agent: Mozilla/5.0' -L 'https://github.com/FRIKKern/barkpark/commit/7b84802479cf5a0472c61dbefd7359cc5c91e19e/checks/88503780155/logs/1'   # 404
    for r in 25024987220 29261030044; do gh api repos/FRIKKern/barkpark/actions/runs/$r/logs -i 2>&1 | head -1; done                          # 410 Gone (100d) / 200 (23d)

## C. Retention ladder (authenticated logs vs unauth steps), one row per age

    for d in 2026-04-28 2026-05-20 2026-06-10 2026-07-20; do R=$(gh api "repos/FRIKKern/barkpark/actions/runs?created=$d&per_page=1" -q '.workflow_runs[0].id'); J=$(curl -s "https://api.github.com/repos/FRIKKern/barkpark/actions/runs/$R/jobs" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["jobs"][0]["id"],len(d["jobs"][0]["steps"] or []))'); JID=${J%% *}; S=$(curl -s "https://api.github.com/repos/FRIKKern/barkpark/actions/jobs/$JID" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("steps") or []))'); echo "$d run=$R list=$J single=$S authlogs=$(gh api repos/FRIKKern/barkpark/actions/runs/$R/logs -i 2>&1 | head -1)"; done

## D. Artifacts

    curl -s https://api.github.com/repos/FRIKKern/barkpark/actions/runs/31029776156/artifacts   # anon list OK, expires_at = +90d
    curl -s -o /dev/null -w 'ANON_ZIP=%{http_code}\n' -L https://api.github.com/repos/FRIKKern/barkpark/actions/artifacts/8940273362/zip   # 401
    git grep -n 'retention-days' origin/main -- .github                                          # ci.yml pins 14

## E. Does the instrument side even emit a host measurement today?

    git grep -n -E 'nproc|loadavg|uptime|/usr/bin/time' origin/main -- .github   # EMPTY
    git grep -n 'FOREIGN' origin/main -- scripts                                  # no FOREIGN price row anywhere
    git show origin/main:scripts/pds-door-census.sh | sed -n '840,856p'           # the shape arm is a pure glob
