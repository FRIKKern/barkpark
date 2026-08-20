<!-- doc-tier: cold | canonical-for: scaffy-cloudclient-add-candidate-verdict | budget: 600tok -->
# Scaffy discover: internal/cloudclient/client.go add-candidate verdict (2026-08-17)

VERDICT: BESPOKE — close-by-evidence. Does NOT earn `add-cloudclient-method`.
Prior recorded CUT ('contextual-bespoke') for cloud/lib/barkpark_cloud/web/router.ex STILL HOLDS.

## Re-derive the cloudclient hunks (7 added Client methods since 2026-07-17)

    git log --since=2026-07-17 --no-merges -p origin/main -- internal/cloudclient/client.go \
      | grep -E '^\+func \(c \*Client\)'

Yields: ListDeployments, FleetDeployCensus, ListSpawnSiteDeployments, MintPrebuiltDeployment,
postSiteDeploy, UploadDeploymentArtifact, DeleteSpawnSite (7). ge3=14 was a commit-frequency
count, NOT a count of copyable identical blocks.

## Why bespoke (read the bodies, not the frequency)

    git log --since=2026-07-17 --no-merges -p origin/main -- internal/cloudclient/client.go \
      | grep -A40 '^+func (c \*Client) ListDeployments'
    # ...same for ListSpawnSiteDeployments, DeleteSpawnSite

The ONLY shared portion is the generic Go-HTTP idiom (~6 lines): `c.do(...)` -> `if err` ->
`if !ok(status){cloudError}` -> `json.Unmarshal` -> return. Every method's SUBSTANCE diverges:
verb (GET/DELETE/POST), query building (some none, some limit/before, some from/to time),
decode shape and post-process (ListDeployments unwraps a `*string` NextCursor; ListSpawnSite
decodes straight into the page; DeleteSpawnSite captures Raw; Upload streams a body+size+sha).
Decisive tell: ListDeployments and ListSpawnSiteDeployments hit the SAME endpoint
(/v1/sites/:id/deployments) yet are NOT copy-paste — different decode + cursor handling. A
catalog template would reproduce only the boilerplate wrapper, never the hand-authored core,
so it clears nothing at the >=3 identical-substance bar.

## router.ex CUT re-confirm (spot-check 3 of the fresh churn since 2026-08-01)

    git log --since=2026-08-01 --no-merges -p origin/main -- cloud/lib/barkpark_cloud/web/router.ex | head -220

Three adds inspected: #11847 delete-site nested-case typed 500 registration_not_removed;
#11808 register per-IP rate bucket + 409 oracle reorder; #11489/agent-space event record.
Each is a bespoke Plug.Router `do` block (halt guard + route-specific body + json). Shared
skeleton is Plug idiom only; no >=3 identical substance. 'contextual-bespoke' CUT holds.
