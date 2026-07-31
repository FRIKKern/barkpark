# Builder-identity ruling — re-derivation recipes (2026-07-31, verifier: builder-identity-decision)

Ruling: move all five /v1/builder/* routes to `require_agent` + barkpark scoping,
reusing /etc/barkpark/agent.token. Reject both the WORKER_TOKEN status quo and a
new dedicated builder-token mint. Queue-age alarm must ship in the same release
as box-scoped claim (it becomes the only orphan surfacer).

| # | Claim | Rerun |
|---|-------|-------|
| 1 | All 5 builder routes (claim, transition, console, detail, env) gate on `require_worker` today | `git -C barkpark show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'v1/builder' \| head -20` |
| 2 | Same WORKER_TOKEN also opens /v1/internal/* fleet ops (list/deprovision barkparks, warm-servers, provision-jobs) | `git -C barkpark show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n '"/v1/internal'` |
| 3 | require_agent assigns current_barkpark from a hashed, revocable, per-box AgentToken; verify ignores scope | `git -C barkpark show origin/main:cloud/lib/barkpark_cloud/web/auth.ex \| sed -n '255,290p'` and `...registry.ex \| sed -n '4237,4252p'` |
| 4 | Agent-side pipeline half is ALREADY barkpark-scoped (claim_pending_deployment_for_barkpark, agent_owns_deployment?) — builder half is the asymmetric outlier | `git -C barkpark show origin/main:cloud/lib/barkpark_cloud/registry.ex \| sed -n '6042,6082p'` |
| 5 | site-runtime-install.sh defaults builder to agent.token, prefers worker.token if present ("cp-ops builder-token-fix" = the one manually-fixed box) | `git -C barkpark show origin/main:deploy/site-runtime-install.sh \| sed -n '68,71p'` |
| 6 | Builder Run loop survives 401 (sleep+retry, no crash) → route-flip-first migration is safe | `git -C barkpark show origin/main:internal/builder/builder.go \| sed -n '165,190p'` |
| 7 | Builder+runtime share one on-box cache dir (filesystem tarball handoff) → fleet-wide claim is already wrong-box-broken at ≥2 planes | `git -C barkpark show origin/main:deploy/site-runtime-install.sh \| grep -n 'cache-dir'` |
| 8 | Only production consumer of /v1/builder/* is the per-box builder binary; tests pinning worker auth: router_builder_test.exs (53), router_site_env_read_test.exs (10) | `grep -rn 'v1/builder' barkpark/cmd barkpark/internal barkpark/cloud/test --include='*.go' --include='*.exs' \| grep -v _test.go \| grep -v worktrees` |
| 9 | mint_agent_token(bp, scope) supersedes-per-scope atomically; S12c re-mints "report" on provision claim — daemons read token file at start only (pre-existing rotation exposure, not new) | `git -C barkpark show origin/main:cloud/lib/barkpark_cloud/registry.ex \| sed -n '4180,4220p'` |
| 10 | Reaper pass (0) never ages out repo/artifact-backed queued rows → box-scoped strand is invisible without the queue-age alarm | `git -C barkpark show origin/main:cloud/lib/barkpark_cloud/registry.ex \| sed -n '6100,6130p'` |
