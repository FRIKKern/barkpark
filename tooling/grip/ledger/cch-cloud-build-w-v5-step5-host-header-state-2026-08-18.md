<!-- doc-tier: cold | re-derivation recipe | wave: bp-cloud-build-2026-08-18 | assignment: V5-step5-host-header-current-state -->

# Step-5 host-header current state — re-derivation recipe

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Authority: read against **origin/main = 41b16d78** (local HEAD a6535504 is behind — do not quote the worktree).

## Claim: no host->tenant/workspace derivation exists in api/ today; the host-header mechanism is fully UNBUILT. Disposition = MIXED (mechanism offline-buildable / DNS-TLS cutover + /v1/tls/ask CP verification human-gated).

Re-derive:

```
# 1. ResolveWorkspace resolves ONLY from path_params[workspace_slug] + token/user — never Host
git show origin/main:api/lib/barkpark_web/plugs/resolve_workspace.ex | grep -niE 'get_req_header|path_params|workspace_slug'
#   -> line 69: slug = conn.path_params["workspace_slug"]  ; zero get_req_header/host reads

# 2. No host-derivation plug anywhere in api/lib/barkpark_web
git grep -niE 'get_req_header.*host|x-forwarded-host|derive.*host|host.*derive' origin/main -- api/lib/barkpark_web/
#   -> EMPTY

# 3. Every conn.host use in api/ is self-referential URL building or origin/tunnel guard — NOT tenant derivation
git grep -n 'conn.host' origin/main -- api/lib/
#   capabilities_controller/ticket_keys_controller/scim_response -> public base_url
#   public_share_guard -> tunnel-trust local_host? ; scope_resolver -> same_origin? CSRF ; request_stats -> route_info telemetry

# 4. /v1/tls/ask lives ONLY on the control plane (cloud/), NOT in api/
git grep -niE 'tls/ask|ask_tls|tlsask' origin/main -- api/lib/
#   -> EMPTY  (matches are all in cloud/ + charters: registry.ex domain_registered?/1 on-demand ACME gate)
```

Conclusion: api/ has NO host->workspace plumbing at all. A builder adding host-based tenancy starts from zero (offline-buildable). The cutover half (DNS/TLS attach, /v1/tls/ask allowlisting, live CP verification) is human/prod-gated and not in api/. Clean MIXED, not fully-unbuilt-monolith and not already-built.
