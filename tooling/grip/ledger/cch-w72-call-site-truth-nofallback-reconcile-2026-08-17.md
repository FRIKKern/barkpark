<!-- doc-tier: cold | canonical-for: cch-w72-call-site-truth-rederivation | budget: 1200tok -->

# cch-w72 call-site truth — no-fallback friendly() reconcile + per-candidate H1/H2

Re-derivation recipes for the wave-72 [call-site-truth] verifier findings. All over
`origin/main` app.js (`a6535504` at write time). Run from repo root.

## Pin the app.js under test (origin/main, not the worktree copy)

    git show origin/main:cloud/priv/static/app.js > /tmp/app_main.js
    node --check /tmp/app_main.js        # must print nothing / exit 0

## The RECONCILED no-fallback friendly() site list (cite by FUNCTION NAME)

The single-arg `friendly(x)` calls (no fallback → unregistered slug renders the
humanized-slug gibberish rung):

    grep -nE "friendly\((r\.data|data|r && r\.data)\)" /tmp/app_main.js

Yields 9 sites on origin/main; enclosing function via:

    node -e 'const l=require("fs").readFileSync("/tmp/app_main.js","utf8").split("\n");for(const t of [1660,4719,6290,6817,12081,17131,21397,21466,21734]){let n,ln;for(let i=0;i<t;i++){const m=l[i].match(/function\s+([A-Za-z0-9_]+)\s*\(/);if(m){n=m[1];ln=i+1;}}console.log(t,n+"@"+ln);}'

    1660  paint@1632                (session-revoke toast)
    4719  confirmRevokeToken@4701
    6290  loadFleet@6282            (inline esc)
    6817  loadOverview@6788         (inline esc)
    12081 loadSites@12074          (inline esc)
    17131 loadActivity@17123       (inline esc)
    21397 roleChangeFailureCopy@21393  (return friendly(data) — the role-modal fall-through)
    21466 confirmRevokeInvite@21450
    21734 confirmDeleteEnvVar@21710

Surveyor conflict resolved: Lane-1 {1660,4719,6290,6817} = a correct-but-INCOMPLETE
subset (4 of 9). Lane-2 {1630,4689,21100,21169,21437 + inline esc} = STALE line numbers
(on origin/main those lines are a comment / an anon copy callback / a session-empty
branch / ctl.succeed — NOT friendly). Citing by function name dissolves both.

## Per-candidate H1(gibberish)/H2(generic)/arm render — vm probe

Slice the real source blocks and drive payloads through them:

    sed -n '179,421p' /tmp/app_main.js > /tmp/core.js       # ERRORS + FORBIDDEN maps + forbiddenEvidenceCopy + friendly
    sed -n '21393,21398p' /tmp/app_main.js > /tmp/role.js    # roleChangeFailureCopy
    sed -n '21508,21529p' /tmp/app_main.js > /tmp/env.js     # envVarWriteFailureCopy
    # cat into a node:vm sandbox (stub faultCopy to throw), expose friendly/roleChangeFailureCopy/envVarWriteFailureCopy

Verified renders (verbatim):

| candidate      | primary console call site (fn)        | server status | render                                                            | class |
|----------------|---------------------------------------|---------------|-------------------------------------------------------------------|-------|
| stale_epoch    | require_worker routes only            | 409           | UNREACHABLE from browser (worker token); would be "stale epoch"   | H0    |
| stale_claim    | require_worker routes only            | 409           | UNREACHABLE from browser; would be "stale claim"                  | H0    |
| no_queued      | require_worker routes only            | —             | UNREACHABLE from browser; would be "no queued"                    | H0    |
| no_pending     | require_worker routes only            | —             | UNREACHABLE from browser; would be "no pending"                   | H0    |
| last_owner     | roleChangeFailureCopy/removeMember...  | 409           | "You're the last owner — promote another member to owner first."  | ARM   |
| write_once     | envVarWriteFailureCopy@21508           | 409           | "A write-once variable with that key already exists. Delete it first, then create it again." | ARM |
| role_too_high  | openRoleModal→roleChangeFailureCopy    | 422           | "role too high"  (only 409+last_owner is armed → falls to friendly no-fallback) | H1 |
| live_twin      | resurrectOutcome@2231 (POST /v1/resurrect) | 422       | "Couldn't resurrect — please try again."  (.name dropped)         | H2    |
| checkout_failed| openCheckout arm                       | 422           | "Please try again."                                               | H2    |
| portal_failed  | openBillingPortal@16164                | 422           | "Please try again in a moment."                                   | H2    |
| no_subscription| openBillingPortal/openCheckout         | 422           | "Please try again in a moment." / "Please try again."             | H2    |

Reachability proofs:

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -nE "stale_claim|require_worker"   # 6033: "NEVER user/agent-reachable"; every claim-code emit sits under Auth.require_worker
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5449p;9197p;5842p;5868p'          # role_too_high@5450=422; live_twin@9197=422 (resurrect); checkout_failed@5842; no_subscription@5868

## The two corrections to the digest

1. live_twin's TRUE call site is `resurrectOutcome` (POST /v1/resurrect), NOT the
   site-create path. Its fallback "Couldn't resurrect — please try again." is an
   HONEST generic, not the misleading "The site was created…" the digest attributed.
   It loses the `name` detail — a curated entry would name the live twin.
2. The four claim codes (stale_epoch/stale_claim/no_queued/no_pending) are
   worker-token-only → they never render on the browser console (H0). They DROP OUT
   of the reader-slice population entirely — no ERRORS entry needed.

Real Tier-A/B human-reaching targets left standing by this analysis: role_too_high
(H1 gibberish in the member-role modal) and live_twin (H2, drops the twin's name).
last_owner + write_once are already arm-shielded on their real status paths.
