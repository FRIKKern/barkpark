# cch-w72 — D855 fence-admission population + behavior pin (2026-08-17)

Verifier: detail-fence, wave 72. Baseline origin/main = 386390b9bf.

## Claims and their re-derivation

1. **The fence on origin/main is exactly three slugs, keyed by name, above the
   final fallback return.**
   `git show origin/main:cloud/priv/static/app.js | sed -n '398,418p'` —
   quotes the rung: `barkpark_required || deploy_ability_required || nothing_to_update`
   gated on `typeof data.detail === "string" && data.detail`.

2. **Behavior pin (node:vm, shipped bytes, no build).** Fenced slugs relay the
   detail verbatim; unfenced slugs drop it to the caller fallback; an
   ERRORS-registered slug (`no_admin_token`) drops even a good detail because the
   curated map wins first; a no-fallback unfenced slug humanizes the raw slug.
   Rerun: extract `git show origin/main:cloud/priv/static/app.js > app-origin-main.js`,
   then run the probe (same sandbox skeleton as `cloud/priv/static/__app.test.mjs`,
   grab `hooks.friendly` via `__bpTestHook`):
   `friendly({error:"barkpark_required",detail:"X"},"FB")` → `"X"`;
   `friendly({error:"cloudflare_zone_missing",detail:"Y"},"FB")` → `"FB"`;
   `friendly({error:"provisioning_in_progress",detail:"…"},"Please try again.")` → `"Please try again."`.

3. **Singular-detail emitter population (router.ex only — auth.ex ships zero
   `detail`).**
   `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'detail:' | grep -v details`
   → 45 emitter lines, 33 distinct codes after folding duplicates and the three
   passthrough seams.
   `git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | grep -n detail` → empty.

4. **The three passthrough seams and their upstream code population.**
   - `router.ex:3069` `json(conn, 422, %{error: code, detail: detail})` — fed by
     the `mode` case in the app-token revoke route (lines 3046-3062): exactly two
     codes, `exactly_one_of` and `invalid_token`, both details quoting JSON body
     keys (machine-voiced).
   - `router.ex:7178/7181` (site delete) and `7441/7444` (rollback) — fed by
     `Sites.Deploy.teardown/2` and `rollback/2`
     (`git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1760,1840p'`):
     the ONLY 4-tuple typed code either mints is `identity_refused` (409); the
     3-tuple fallbacks stamp `teardown_failed`/`rollback_failed` with details from
     `rollback_refusal/2`, `teardown_refusal/2`, `unreachable/2`,
     `teardown_unreachable/2` (deploy.ex:1701-1735, 1849-1948) — box-verbatim or
     slug-templated sentences, statuses 409/422/502.

5. **Console reader truth per candidate** (grep counts over shipped app.js):
   `identity_refused`/`not_rollbackable`/`rollback_failed` read per-arm
   (`rollbackConflictCopy`, rollback failure arm renders measured detail —
   app.js ~13295-13392); site-delete arms read per W67 S1; vercel-deploy 409/422
   have curated status-keyed arms (`deployToVercel` render site); the decommission
   modal renders `friendly(r.data,"Please try again.")` (`runDecommission`) so
   `provisioning_in_progress`'s measured 409 sentence is DROPPED today;
   `cloudflare_domain_required`/`cloudflare_zone_missing`/`no_cloudflare_provider`/
   `cloudflare_credential_unreadable`/`instance_no_origin` have ZERO console
   occurrences.
   Rerun: `for c in provisioning_in_progress invalid_parent not_a_support no_bootstrap not_deployable cloudflare_zone_missing instance_no_origin; do grep -c $c app-origin-main.js; done`.

## Verdict carried to Decide

Admit exactly ONE new slug: `provisioning_in_progress` (409, measured,
surface-neutral, human-voiced, render path already `friendly()`). Everything else
stays out: 5xx-borne (`node_ports_exhausted`, `read_token_mint_failed`,
`vercel_error`+inspect, `cloudflare_bind_failed`+inspect,
`registration_not_removed`, `feature_not_configured`, `unavailable`),
CLI-voiced (`content_binding_required/empty`, `no_build_source`,
`not_rollbackable`, four `cloudflare_*`), machine/param-voiced
(`exactly_one_of`, `invalid_token`, `deliveries_required`, `null_column`,
`invalid_window`, `invalid_cursor`), ERRORS-shadowed (`no_admin_token`,
`suspended`), already per-arm-read (`identity_refused`, `teardown_failed`,
`rollback_failed`, `no_bootstrap`, `not_deployable`). `instance_no_origin` is
admissible on criteria but belongs to the domains per-arm slice with its
CLI-voiced siblings — one screen, one dialect.
