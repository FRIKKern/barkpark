# Recipe — /v1/graph collapses under concurrency (2026-07-28)

Tree: `origin/main @ ab396959c`. Client host load avg **10.8 → 25.4** during the run.
Target: live `guerrilla.barkpark.cloud`. Guerrilla's own load was NOT measured.

## This reconciles the 10x disagreement

    PUB=UXOvtfPOUiJF7Bw4kAz3jVW3IDyHGoLBz6Ygj7NcpnE   # site-read-search-ember, {public-read}
    for i in 1 2 3 4 5 6; do
      curl -s -o /dev/null -w "conc$i code=%{http_code} t=%{time_total}\n" \
        -H "Authorization: Bearer $PUB" \
        'https://guerrilla.barkpark.cloud/v1/graph?dataset=production' &
    done; wait

Output:

    conc3 code=200 t=21.463206
    conc4 code=200 t=21.637529
    conc5 code=200 t=21.644419
    conc1 code=200 t=21.667212
    conc6 code=200 t=21.752196
    conc2 code=200 t=21.891163

Serial warm on the same host, same minute: **2.7 – 5.2s**.
Six concurrent: **21.5 – 21.9s, all six landing within 0.43s of each other.**

That flat-topped profile is serialization, not queueing jitter: six requests
cost ~6x one request and finish together. So:

- The direction's **2.5-3.6s** is the WARM SERIAL number. True, and unrepresentative.
- count-truth-live's **28-36s** is the CONTENDED number. Also true.
- Neither is wrong; neither is quotable without naming concurrency AND load.

**#6284 removed the N+1, it did not make the route concurrent.** A single visitor
is fast; six simultaneous cold visitors to the flagship landing each wait ~21s.

## The cold 500 (recorded, NOT reproduced)

The very first request of the session:

    admin run1 t=50.247070 code=500

Not reproduced in 19 subsequent requests (serial or 6-way concurrent), and the
body was discarded (`-o /dev/null`) — so the mechanism is UNPROVEN.
It matters because `stw10-backlog-flagship-health-pool` was CLOSED 2026-07-27 by
`w10-lead` on the criterion that #6284 resolved exactly this 500:

    bp task get stw10-backlog-flagship-health-pool -o json
    # claim.closed_at = 2026-07-27T17:40:53Z, closed_by = w10-lead
    # evidence: "RESOLVED BY #6284 (the /v1/graph N+1 fix), verified 2026-07-27"

A 500 on that route was still observed today. This does NOT prove the close is
wrong — one unreproduced 500 with no body is weak evidence, and the closing
evidence is a real causal argument. It DOES mean the close rests on a warm-path
read, and the cold/contended path was never probed. Re-probing it needs the
response body captured:

    curl -s -D- -o body.json -w "\ncode=%{http_code} t=%{time_total}\n" \
      -H "Authorization: Bearer $PUB" 'https://guerrilla.barkpark.cloud/v1/graph?dataset=production'

## Why this sizes the wave

The node HEALTH gate probes the site landing; the landing SSRs `/v1/graph`.
Any deploy-gate timeout, build-time bake, or SSR budget chosen against the 3s
figure will fail whenever more than one request is in flight.
