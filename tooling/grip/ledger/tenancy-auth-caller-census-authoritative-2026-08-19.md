# Re-derivation recipe — Tenancy.Auth caller census (origin/main, 2026-08-19)

Authoritative denominator: **58 real call sites across 32 modules** in `api/lib`.
Three reference forms exist and only three; no `import`, no `apply/3`, no
`alias Barkpark.Tenancy, as: X` renaming, no `alias Barkpark.Tenancy.{…, Auth}`
brace form.

## 1. The three call forms

```sh
cd /Volumes/SATECHI/github/barkpark
# Form 1+2 (Tenancy.Auth.* and TenancyAuth.*): 54 syntactic hits, 2 are prose
git grep -nE '(Tenancy\.Auth|TenancyAuth)\.[a-z_]+[?!]?\(' origin/main -- api/lib
# the 2 prose hits to subtract:
#   api/lib/barkpark_web/live/studio/studio_live/handlers/access_panel.ex:16 (comment)
#   api/lib/barkpark_web/plugs/resolve_workspace.ex:10                       (moduledoc)

# Form 3 (bare `Auth.` after `alias Barkpark.Tenancy.Auth` with NO `as:`) — 6 hits
git grep -lE '^\s*alias Barkpark\.Tenancy\.Auth$' origin/main -- api/lib
# -> access.ex, access_controller.ex, access_panel.ex ; then per file:
git show origin/main:api/lib/barkpark/access.ex | grep -nE '(^|[^.A-Za-z_])Auth\.[a-z_]+[?!]?\('
```

## 2. Completeness (proves no fourth form)

```sh
git grep -nE 'import Barkpark\.Tenancy\.Auth|apply\((Barkpark\.)?Tenancy\.Auth' origin/main -- api/lib   # empty
git grep -nE '^\s*alias Barkpark\.Tenancy,\s*as:' origin/main -- api/lib                                  # empty
git grep -nE 'alias Barkpark\.Tenancy\.\{' origin/main -- api/lib                                         # 7 hits, none contain Auth
```

## 3. The rescue question — answer: ZERO

No caller wraps a `Tenancy.Auth.*` call in `try/rescue` used as a control-flow
branch. Re-derive by enclosing-function analysis, not by proximity:

```sh
python3 - <<'PY'
import subprocess,re
# sites = output of section 1 (both forms), as (file, line)
# for each site: walk back to nearest /^  defp? [a-z]/, forward to nearest /^  end$/,
# and grep that body for \brescue\b or ^\s*try do
PY
```
The naive ±150-line proximity scan produces 7 candidates; all 7 are false
positives, each verified by reading the enclosing function:
`auth.ex:435,439` (rescue at 566 is in `touch_last_used/1`),
`workspace_controller.ex:879` (`try` at 730 is in `spill_body/2`),
`live_auth.ex:202,261,269` (rescue at 313 is in `requested_uri/1`),
`access.ex:479` (rescue at 534 is in `emit_grant_event/4`).

## 4. Tests do not pin the raise

```sh
git grep -nE 'Ecto\.Query\.CastError|Ecto\.CastError|FunctionClauseError' origin/main -- api/test
```
The only `assert_raise Ecto.Query.CastError` block is
`api/test/barkpark/secrets_castgap_contract_test.exs:28-50`, and it pins
`Barkpark.Secrets`, NOT `Tenancy.Auth`. Out of fence; the seam cannot red it.

## 5. The two REACHABLE-CRASH sites (both out of fence, both fixed transitively)

```sh
git show origin/main:api/lib/barkpark_web/controllers/access_controller.ex | sed -n '78,82p;181,182p'
git show origin/main:api/lib/barkpark/access.ex | sed -n '/def mint(/,/authorize_capabilities/p'
git show origin/main:api/lib/barkpark/tenancy/auth.ex | sed -n '170,172p;142,152p'
```
`GET /v1/access?workspace_id=zzz` — `fetch_workspace_id/1` guards only
`is_binary(id) and id != ""`. `POST /v1/access` with a non-empty `capabilities`
list and `workspace_id: "zzz"` — `authorize_capabilities/3` guards only
`is_binary(workspace_id)`. Both reach `authorize/3`'s `%ApiToken{}` arm
(guard: `is_binary(workspace_id) and action in [...]`) → `member?/2` →
`membership/2` raw-binary clause → `Repo.one` → `Ecto.Query.CastError` → 500.
Note: `capabilities: []` falls to `authorize_capabilities/3`'s own catch-all
`{:error, :forbidden}` — the crash needs a NON-EMPTY caps list.
