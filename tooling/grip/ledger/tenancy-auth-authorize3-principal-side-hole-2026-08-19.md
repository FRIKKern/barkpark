# Re-derivation recipe — authorize/3's PRINCIPAL-side escape from its catch-all

Verifier lane: `authorize3-principal-side-hole` (tenancy-auth-totality wave, 2026-08-19).
Baseline: `api/lib/barkpark/tenancy/auth.ex` md5 `5e2fedb6e83f4dfdef9c71b7c8d5d0ac`,
byte-identical to `origin/main` @ `bf499f54b63135b8ae078305b83f2b5b2c078877`.

## 0. Prove the file under test IS origin/main's

    git fetch -q origin main && \
      git show origin/main:api/lib/barkpark/tenancy/auth.ex | md5 && md5 -q api/lib/barkpark/tenancy/auth.ex

## 1. The four requested principal-side shapes (all RAISE today)

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix run -e 'alias Barkpark.Tenancy.Auth; alias Barkpark.Auth.ApiToken; alias Barkpark.Accounts.User; alias Barkpark.Content.CallerContext; u = Ecto.UUID.generate(); r = fn f -> (try do {:ok, f.()} rescue e -> {:raise, e.__struct__} end) end; IO.inspect(r.(fn -> Auth.authorize(%ApiToken{id: nil, permissions: ["admin"]}, u, :admin) end), label: "apitoken-nil-id"); IO.inspect(r.(fn -> Auth.authorize(%User{id: nil}, u, :read) end), label: "user-nil-id"); IO.inspect(r.(fn -> Auth.workspace_admin?(%ApiToken{id: nil}, u) end), label: "wsadmin-nil-id"); IO.inspect(r.(fn -> Auth.membership(%CallerContext{}, u) end), label: "callerctx-membership")'

Expected on origin/main — every one `{:raise, FunctionClauseError}`
("no function clause matching in Barkpark.Tenancy.Auth.membership/2").
The workspace argument is a VALID uuid in all four rows: the crash is on the PRINCIPAL side.

## 2. The full principal-side matrix (per-cell, never aggregate)

Drive each of `authorize/3`, `membership/2`, `membership_role/2`, `member?/2`,
`workspace_admin?/2` over these principals against a valid workspace uuid:

| principal | authorize/3 | membership/2 + the three arity-2 predicates |
|---|---|---|
| `nil` | `{:error, :forbidden}` (catch-all) | FunctionClauseError |
| `%ApiToken{id: nil}` | **FunctionClauseError** | FunctionClauseError |
| `%User{id: nil}` | **FunctionClauseError** | FunctionClauseError |
| `%ApiToken{id: "zzz"}` | **Ecto.Query.CastError** (auth.ex:145) | Ecto.Query.CastError |
| `%CallerContext{}` (anonymous) | `{:error, :forbidden}` | FunctionClauseError |
| `%CallerContext{principal_type: :api_token, token_id: nil}` | `{:error, :forbidden}` | FunctionClauseError |
| `%CallerContext{principal_type: :api_token, token_id: ""}` | **Ecto.Query.CastError** | FunctionClauseError |
| `%CallerContext{principal_type: :api_token, token_id: "zzz"}` | **Ecto.Query.CastError** (auth.ex:145) | FunctionClauseError |
| `%CallerContext{principal_type: :user, user_id: "zzz"}` | **Ecto.Query.CastError** (auth.ex:134) | FunctionClauseError |

Module name is `Ecto.Query.CastError`, NOT `Ecto.CastError` — the module
`Repo.uuid_or_nil/1`'s own docstring names. A test rescuing `Ecto.CastError` is vacuous.

## 3. Shadow-module proof: ONE terminal arm closes all four crash shapes,
##    and all three legitimate shapes still reach their ORIGINAL query head

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix run -e '
    defmodule Shadow do
      alias Barkpark.Auth.ApiToken
      alias Barkpark.Accounts.User
      def membership(%ApiToken{id: pid}, ws), do: membership(pid, ws)
      def membership(%User{id: pid}, ws) when is_binary(pid) and is_binary(ws), do: {:user_query, pid, ws}
      def membership(pid, ws) when is_binary(pid) and is_binary(ws), do: {:token_query, pid, ws}
      def membership(_p, _ws), do: nil
    end
    alias Barkpark.Auth.ApiToken; alias Barkpark.Accounts.User; alias Barkpark.Content.CallerContext
    u = Ecto.UUID.generate()
    IO.inspect(Shadow.membership(%ApiToken{id: nil}, u), label: "apitoken-nil-id")
    IO.inspect(Shadow.membership(%User{id: nil}, u), label: "user-nil-id")
    IO.inspect(Shadow.membership(%CallerContext{}, u), label: "callerctx")
    IO.inspect(Shadow.membership(nil, u), label: "nil-principal")
    IO.inspect(Shadow.membership(%ApiToken{id: u}, u), label: "apitoken-valid")
    IO.inspect(Shadow.membership(%User{id: u}, u), label: "user-valid")
    IO.inspect(Shadow.membership(u, u), label: "raw-binary-valid")'

Expected: first four `nil`; `apitoken-valid` and `raw-binary-valid` → `{:token_query, ...}`;
`user-valid` → `{:user_query, ...}`. The principal_type discriminator is preserved.

CLAUSE-ORDER LAW: the denial arm is LAST. A normalisation clause placed FIRST
(unguarded on the principal position) shadows the `%ApiToken{}`/`%User{}` heads
and silently collapses the user/api_token discriminator — that is the bypass shape.

## 4. Reachability of `%ApiToken{id: nil}` from a real request

    cd /Volumes/SATECHI/github/barkpark/api
    grep -rn '%ApiToken{' lib --include='*.ex' | grep -v tenancy/auth.ex
    grep -rn 'struct(ApiToken\|struct!(ApiToken\|struct(Barkpark.Accounts.User' lib --include='*.ex'
    grep -rn 'assign(conn, :api_token\|assign(socket, :api_token' lib --include='*.ex'

Every request-path `%ApiToken{}` / `%User{}` is a `Repo`-loaded row (id is a
DB-generated binary_id). The only in-memory constructions are
`%ApiToken{} |> ApiToken.changeset(...) |> Repo.insert()` (never handed to Auth)
and `Tenancy.Auth.membership_authorizes?/3`'s reconstruction from a CallerContext,
which is guarded `when is_binary(tid)` / `is_binary(uid)`. So a nil-id principal
struct is TEST-SYNTHESIZABLE ONLY today — the hole is latent, not live.

## 5. CallerContext: inherit, never unwrap

    grep -rn 'Auth.authorize(' lib --include='*.ex'
    grep -rn 'CallerContext' lib --include='*.ex' | grep -i 'workspace_admin\|membership\|member?'

Second grep returns NOTHING: no caller passes a `%CallerContext{}` to
`membership/2`, `membership_role/2`, `member?/2` or `workspace_admin?/2`.
`authorize/3`'s CallerContext arm re-enters via RECONSTRUCTED `%ApiToken{}` /
`%User{}` structs (auth.ex `membership_authorizes?/3`), so normalising the two
struct heads fixes the CallerContext path transitively. A dedicated CallerContext
normalisation would be a SECOND decision path; unwrapping it at `membership/2`
would (a) have to pick one of two identities and (b) drop the grants half of
`authorize/3`, which would let `workspace_admin?/2` start answering for a
grant-bearer — `caps.ex` states "Grants never confer admin".

## 6. What the existing test file does and does not bank

    grep -c 'test "' api/test/barkpark/tenancy_auth_test.exs        # => 27
    grep -n 'id: nil\|CallerContext' api/test/barkpark/tenancy_auth_test.exs   # => no hits

The only totality assertion is `tenancy_auth_test.exs:93`
`assert Auth.authorize(nil, ws.id, :read) == {:error, :forbidden}` — the ONE
shape that reaches the catch-all. Zero coverage of nil-id principal structs or
CallerContext. The filed finding `arpss-w8-tenancy-auth-not-total` names the
"principal-id position" only for a non-UUID/empty binary; it never names a
struct with a nil id, and never names CallerContext.
