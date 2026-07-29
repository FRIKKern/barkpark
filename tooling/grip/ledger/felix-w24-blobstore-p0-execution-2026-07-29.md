# felix w24 — blobstore P0 execution re-derivation recipes (2026-07-29)

Verifier lane `blobstore-p0-execution`. Baseline: `origin/main` @ `606fefd15`.
Every row below re-derives one load-bearing claim from scratch.

| # | Claim | Rerun command |
|---|---|---|
| 1 | The import route's admin gate REJECTS public-read / read / read+write, ADMITS admin (oracle leg proves non-vacuity: admin reaches the action and 422s `invalid_bundle`) | `cd api && CC=clang MIX_ENV=test mix run tooling/grip/ledger/probes/felix-w24-nonadmin-import-probe.exs` (probe body reproduced below) |
| 2 | The committed 403/401 pins for POST /import are green | `cd api && CC=clang mix test test/barkpark_web/controllers/workspace_controller_test.exs` → `40 tests, 0 failures` |
| 3 | `RequireAdmin` is a FLAT global-perm check (`"admin" in token.permissions`), no workspace scoping | `git show origin/main:api/lib/barkpark_web/plugs/require_admin.ex` |
| 4 | The import route rides `[:api, :require_admin]` | `git show origin/main:api/lib/barkpark_web/router.ex \| sed -n '2540,2552p'` |
| 5 | ZERO writer of `media_files` rows outside `api/lib` (no plugins/, tooling/, cloud/, js/, web/, no migration INSERT, no bare `insert_all`) | `git grep -n 'media_files' -- . ':!api/deps' ':!api/_build' ':!.omx' ':!.claude'` and `git grep -n 'insert_all\|%MediaFile{}\|MediaFile.changeset' -- api/lib/barkpark/media` |
| 6 | `Media.upload/3` is the only `:path` writer outside import; its `unique_filename/1` slug regex strips every separator | `git show origin/main:api/lib/barkpark/media.ex \| sed -n '650,662p'` |
| 7 | `Media.put_blob/2` writes BYTES only (no `media_files` row) and is guarded by `valid_blob_path?` segment allowlist | `git show origin/main:api/lib/barkpark/media.ex \| sed -n '596,612p'` ; `git grep -n 'put_blob' -- api/lib` |
| 8 | No HTTP surface mints an `"admin"` api_token: the sole PAT controller hardcodes `["read"]`; `TokenController` allowlist = `~w(public-read read)`; `AppTokenController` = `~w(read write chat)`; fleet support = `~w(read write)` | `git show origin/main:api/lib/barkpark_web/controllers/auth_controller.ex \| sed -n '232,244p'` ; `git grep -n '@allowed_permissions\|@app_token_permissions \|@support_permissions ' -- api/lib` |
| 9 | `Auth.authorize_pat_permissions` WOULD allow owner/admin to mint `["admin"]` — latent, unreachable over HTTP today | `git show origin/main:api/lib/barkpark/auth.ex \| sed -n '470,476p;577,590p'` |
| 10 | cloud/ never asks for `"admin"`: `@app_token_permissions ["read","write","chat"]`, site-mint asks `["public-read"]` | `git grep -n '@app_token_permissions\|permissions: \["public-read"\]' -- cloud/lib` |
| 11 | Charter doctrine bar hook (3) is "closes a SCAR-CLASS risk", NOT "Phoenix Mastery Corpus", and there is a FOURTH hook | `sed -n '26,33p' .claude/workflows/bp-felix-pristine-charter.md` |
| 12 | `import_member/3` COPYs manifest-named table+column list verbatim, bypassing every changeset | `git show origin/main:api/lib/barkpark/tenancy/workspace_bundle.ex \| sed -n '1011,1042p'` |

## Probe body (row 1)

Run with `MIX_ENV=test mix run <path>` from `api/`; mints four tokens and calls
`BarkparkWeb.Endpoint.call/2` on `POST /api/workspaces/no-such-ws/import`.

```elixir
alias Barkpark.Auth
u = System.unique_integer([:positive])
{:ok, _} = Auth.create_token("probe-publicread-#{u}", "probe pr", "test", ["public-read"])
{:ok, _} = Auth.create_token("probe-read-#{u}", "probe r", "test", ["read"])
{:ok, _} = Auth.create_token("probe-rw-#{u}", "probe rw", "test", ["read", "write"])
{:ok, _} = Auth.create_token("probe-admin-#{u}", "probe a", "test", ["read", "write", "admin"])

post = fn raw ->
  Plug.Adapters.Test.Conn.conn(%Plug.Conn{}, :post, "/api/workspaces/no-such-ws/import", "junk")
  |> Plug.Conn.put_req_header("content-type", "application/x-tar")
  |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
  |> BarkparkWeb.Endpoint.call([])
end
```

Observed 2026-07-29 on `606fefd15` (local OTP28/1.19.5):

```
public-read -> status=403 code="forbidden"
read -> status=403 code="forbidden"
read+write -> status=403 code="forbidden"
ADMIN(oracle) -> status=422 code="invalid_bundle"
anonymous -> status=401
```

## Verdict

The admin-only refutation SURVIVES execution. Move 1 is a 15-annotation slice,
not a P0 security slice. The residual latent seam is row 9 (`authorize_pat_permissions`
permits an elevated mint that no controller currently requests).
