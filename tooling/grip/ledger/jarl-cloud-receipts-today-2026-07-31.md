# jarl.no Cloud receipts — re-derivation recipes (verified 2026-07-31T01:04Z)

Every line below is a command that re-derives the fact, not a conclusion. Run
date-stamped: `date -u` → `Fri Jul 31 01:04:23 UTC 2026`.

## 0. The MUST-RUN shortlog command as briefed is BROKEN

    git shortlog -sne -- cloud/          # HANGS: no committish → reads stdin
    git shortlog -sne HEAD -- cloud/     # correct form

Anyone quoting an empty result from the first form is quoting a hang, not an
absence. Always pass `HEAD` (and `</dev/null` under an agent harness).

## 1. cloud/ authorship — single HUMAN, three git identities

    cd /Users/frikkjarl/Documents/GitHub/barkpark
    git shortlog -sne HEAD -- cloud/ </dev/null
    #  323  Frikk Jarl <32601161+FRIKKern@users.noreply.github.com>
    #   15  Frikkern <pelle@jarl.no>
    #   14  Frikkern <frikk@guerrilla.no>

352 commits touch `cloud/`, 2026-06-26 → 2026-07-30 (`git log HEAD --format=%ad
--date=short -- cloud/ | sort | sed -n '1p;$p'`). All three author identities are
the same person (Frikk Jarl / Frikkern); `pelle@jarl.no` and `frikk@guerrilla.no`
are that person's identities on other boxes, NOT a second contributor.

Committer split (`git log HEAD --format='%cN <%cE>' -- cloud/ | sort | uniq -c`):
309 `GitHub <noreply@github.com>` (squash-merged PRs), 28 Frikk Jarl, 15 Frikkern.

AI co-authorship is heavy and must not be hidden — trailers over cloud/:

    git log HEAD --format='%b' -- cloud/ </dev/null | grep -i '^Co-authored-by' | sort | uniq -c | sort -rn
    #  83 Frikkern <pelle@jarl.no>   69 probe@local   46 survey@local
    #  16 surveyor@local   13+10 Claude Fable 5   7 Claude Opus 4.8   2 Claude Opus 5   10 verifier@example.com

**Safe framing: "one person + a fleet of agents", NOT "written by one person".**
"Én person" is defensible as *authorship/direction*; a bare "one human wrote it"
is refutable in one grep.

## 2. TLS today — all three green

    for h in jarl.no www.jarl.no barkpark.jarl.no; do
      curl -so /dev/null -w "$h %{http_code} ssl=%{ssl_verify_result} ip=%{remote_ip}\n" https://$h; done
    # jarl.no 200 ssl=0 ip=91.98.139.58
    # www.jarl.no 200 ssl=0 ip=91.98.139.58
    # barkpark.jarl.no 302 ssl=0 ip=91.98.139.58     (→ /w/default/p/default/d/production/studio)

Certs (Let's Encrypt, issuer CN=YE1), issued the day before this check:

    echo | openssl s_client -servername jarl.no -connect jarl.no:443 2>/dev/null | openssl x509 -noout -subject -dates
    # CN=jarl.no          notBefore=Jul 30 17:24:16 2026 GMT  notAfter=Oct 28 17:24:15 2026 GMT
    # CN=www.jarl.no      notBefore=Jul 30 17:24:24 2026 GMT  notAfter=Oct 28 17:24:23 2026 GMT
    # CN=barkpark.jarl.no notBefore=Jul 30 15:09:37 2026 GMT  notAfter=Oct 28 15:09:36 2026 GMT

jarl.no is Next.js behind Caddy, ISR live: `via: 1.1 Caddy`, `x-nextjs-cache: HIT`,
`cache-control: s-maxage=60, stale-while-revalidate=31535940` (`curl -sI https://jarl.no`).

## 3. Push-to-deploy: STILL NOT PROVEN — do not soften the beat

    bp task get sites-github-auto-build     # lifecycle_status "open", criteria met 0/2, updated 2026-07-30T17:14:07Z
    gh issue view 8148 --repo FRIKKern/barkpark --json state,closedAt
    # {"closedAt":null,"state":"OPEN"}

    bp task get jarl-golive-epic            # lifecycle "done", criteria met 4 of 5
    # criterion 1 "Push-to-deploy proven: a git push to main deploys to live with
    #   no human step" → met=false, evidence="" (the honest 4/5 close holds)

## 4. Deployment trigger is MANUAL

    bp cloud site status jarl-website
    # deployment 2f3c5ebd-bc65-4ced-9b54-1f57c51eb590  status "live"  trigger "manual"
    # site b376168d… framework nextjs, kind container, port 7001, instance "jarl"

Oddity to not quote: the live deployment reports all six stages
(PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE) as `"pending"` while `status: "live"`.
Also `https://jarl.barkpark.cloud/sites/jarl-website/` — the URL the status
command advertises — returns **404** today (curl, ssl=0). Public URL is jarl.no.

## 5. Fleet count — TWO different registries, never conflate

    bp cloud status
    # count 5 barkparks; buckets {healthy 3, attention 2}
    # jarl 91.98.139.58 ok/online   Guerrilla 157.180.90.121 ok   dooodo 116.203.91.216 ok
    # Gyldendal 5.75.169.183 degraded(health down)   muscle-1 46.224.19.120 degraded(agent offline)
    # all five: update_running_release 0.2.25 == update_latest_release, update_state "current"

    bp cloud instance list
    # provider hetzner, 5 rows: barkpark-cms 89.167.28.206, polyflor-no 62.238.14.213,
    # polyflor-se 89.167.14.174, shared-no 157.180.122.229, guerrilla 157.180.90.121

These are DIFFERENT sets that happen to both have 5 rows. `bp cloud status` =
managed Barkpark instances (the fleet figure); `bp cloud instance list` = Hetzner
provisioning inventory. A "5 boxes" stat must name which one it counts.

jarl.no's serving IP 91.98.139.58 == the `jarl` barkpark host in `bp cloud status`
— that link is the proof that jarl.no runs on Barkpark's own cloud.
