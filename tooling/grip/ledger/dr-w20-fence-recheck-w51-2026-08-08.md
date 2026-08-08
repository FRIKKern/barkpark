# deploy-reliability wave 20 — fence recheck against cch wave 51 (2026-08-08)

Baseline: `origin/main` = `ca5bc542941e23591b1c84a0840f2145595b40eb`.

## 0. `bp paper view` is BROKEN for every paper — 422 `semantic_empty` is not emptiness

    bp paper view deploy-reliability-wave-20-2026-08-08          # 422 semantic_empty
    bp paper view deploy-reliability-wave-19-2026-08-07          # 422 semantic_empty
    bp paper view cloud-console-hardening-wave-51-2026-08-08     # 422 semantic_empty (our OWN paper)
    bp paper view deploy-reliability-wave-19-2026-08-07 >/dev/null 2>&1; echo $?   # 4

Read the body around the broken verb:

    bp doc get paper deploy-reliability-wave-20-2026-08-08 -o json

`_updatedAt = 2026-08-07T23:55:37.066298Z`, `body` = 78,761 JSON bytes / 49,841 chars of text.
The survey's "wave 20 paper was EMPTY" is an artifact of this verb, not a fact about the paper.

## 1. Wave 20's own fence declaration (quoted from its body)

    FENCED by cloud-console-hardening wave 50, in flight and owning them:
      cloud/priv/static/app.js, cloud/lib/**/web/auth.ex, router.ex's auth region, and the billing surface.
    OURS: deploy/, internal/agent/**, report.go, internal/cloudclient, the vitals rows in
      registry.ex, bp cloud status, bp cloud deployments, bp cloud webhook, attentionStatus()
      and the deploy ledger taxonomy.

Vocabulary absent from the whole 49,841-char body:

    grep -ic telemetry w20.txt                                   -> 0
    grep -i 'agent_event\|AgentEvent\|record_event\|timeline'    -> 0 lines
    grep -i 'app\.js' w20.txt                                    -> 1 line, the FENCE line above

Wave 20 is in VERIFY (V1-V9), no builders flown, no dr-w20 tasks exist:

    bp search query 'dr-w20' -o json     # count:1, and the single hit is the cch wave-51 paper

## 2. Branch / PR scan — nothing in flight touches the four regions

    git branch -r --sort=-committerdate | grep -v HEAD | head -40 | while read b; do \
      git diff --name-only origin/main...$b | grep -E 'telemetry\.ex|registry/agent_event\.ex'; done
    # -> empty

    # app.js hunk starts across every branch that touches it: 231, 1951, 6994, 7011,
    # 13474, 14221, 14453, 17315, 21164 — none inside 10200-10700.

    gh pr diff 10509 | grep '^@@'   # router.ex hunks at 1816, 1828, 5376, 9313 — not 1281-1370

## 3. The REAL collision is not wave 20 — it is a stale-open wave-4/5 row

    bp task get task-3b69c3e24bf3d8ca -o json
    # lifecycle_status = open, criteria_progress = {met:0, total:1}
    # parent_id = task-fb4fb869490b4213  (the deploy-reliability epic)
    # title: "The control plane lands the agent's space payload: POST /v1/agent/space,
    #         the 'space' event type, and a named-consumer render"

Its brief claims, verbatim, all three cloud-side things wave 51 wants:
add `"space"` to `AgentEvent` `@types`; add `post "/v1/agent/space"` calling `record_event/3`;
and **"render the newest space row as a named-consumer breakdown ... in three honest states"**.

The first two LANDED (#9889, `f4194c51f`) and are on main:

    git show origin/main:cloud/lib/barkpark_cloud/registry/agent_event.ex | sed -n 38p
    #   @types ~w(health status backup tls content verify space)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1357,1366p'
    #   post "/v1/agent/space" do ... Registry.record_event(..., "space", conn.body_params)

The render half did NOT:

    git show origin/main:cloud/priv/static/app.js | grep -n 'sites_top\|root_used_bytes\|pg_top_relations'
    # -> empty
    git show origin/main:cloud/priv/static/app.js | sed -n '10228,10239p'
    #   // ... (AgentEvent @types: health status backup tls content verify);
    #   var TLV_EVENT_TITLES = { health, status, backup, tls, content, verify }   <- no space

So the comment above `TLV_EVENT_TITLES` states a six-type closed vocabulary that the server
widened to seven on the same day — the console's own comment is the fourth liar, and the
missing `space` title is the unbuilt half of an OPEN deploy-reliability row, not virgin ground.

Its one unmet criterion is agent-side backoff (`internal/agent/**`) — squarely wave 20's fence
and NOT wave 51's — so the render half is claimable by wave 51 without contending for the file.

## 4. Last-writer history (true, and not a claim)

    git log origin/main -1 --format='%h %ad %s' --date=short -- cloud/lib/barkpark_cloud/telemetry.ex
    git log origin/main -1 --format='%h %ad %s' --date=short -- cloud/lib/barkpark_cloud/registry/agent_event.ex
    # both: f4194c51f 2026-08-07 feat(cloud): land the agent's space payload ... (#9889)

Historical territory, zero present claim.
