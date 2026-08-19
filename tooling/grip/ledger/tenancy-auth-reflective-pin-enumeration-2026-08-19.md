# Re-derivation: Tenancy.Auth reflective-pin enumeration (2026-08-19)

Baseline: local `api/lib/barkpark/tenancy/auth.ex` sha1 `2f2d030f829d6e2e23d251b03a2db6811e3f24d2`
== `git show origin/main:api/lib/barkpark/tenancy/auth.ex | shasum`. The runs below are therefore
claims about origin/main, not just this checkout.

## 1. The pin set (RUN, not read)

    cd api && MIX_ENV=test mix run -e 'IO.inspect(Enum.sort(Barkpark.Tenancy.Auth.__info__(:functions)), limit: :infinity)'

    [authorize: 3, create_membership: 2, create_membership: 3, create_membership: 4,
     member?: 2, membership: 2, membership_role: 2, permits?: 2,
     role_for_permissions: 1, role_permits?: 3, workspace_admin?: 2]

11 tuples / 9 distinct names — `create_membership` has arities 2, 3, 4 (inline defaults).
A name-only pin (the projects_test.exs:346 precedent) collapses 11 -> 9 and cannot see an arity change.

    cd api && MIX_ENV=test mix run -e 'fs = Barkpark.Tenancy.Auth.__info__(:functions); IO.puts("tuples=#{length(fs)} names=#{fs |> Enum.map(&elem(&1,0)) |> Enum.uniq() |> length()}")'

## 2. Nothing is injected

    git show origin/main:api/lib/barkpark/tenancy/auth.ex | grep -cE '^\s*use '     # -> 0
    cd api && MIX_ENV=test mix run -e 'IO.inspect(Barkpark.Tenancy.Auth.__info__(:macros))'  # -> []

Only `import Ecto.Query, warn: false`; imports are not exports. No behaviours.

## 3. Per-function malformed-input behaviour (probe script)

    cd api && MIX_ENV=test mix run <scratch>/probe.exs

Each row `try/rescue`s and prints the exception module. Decisive results on origin/main:

| call | today |
|---|---|
| membership(nil, nil) | FunctionClauseError |
| membership(%ApiToken{id: nil}, uuid) | FunctionClauseError |
| membership(%User{id: nil}, uuid) | FunctionClauseError |
| membership(uuid, "") | Ecto.Query.CastError |
| membership(uuid, "zzz") | Ecto.Query.CastError |
| membership(:atom, uuid) | FunctionClauseError |
| membership_role / member? / workspace_admin? (uuid, "zzz") | Ecto.Query.CastError |
| authorize(%ApiToken{id: nil, permissions: ["admin"]}, uuid, :admin) | FunctionClauseError |
| authorize(%ApiToken{id: uuid, ...}, "", :admin) | Ecto.Query.CastError |
| role_permits?("admin", "", :admin) | {:ok, true}  <-- DO NOT FLIP |
| role_permits?("custom-x", "zzz", :admin) | Ecto.Query.CastError |
| permits?(nil, :admin) / permits?(%ApiToken{permissions: nil}, :admin) | {:ok, false} (already total) |
| role_for_permissions(nil) | FunctionClauseError |
| create_membership(nil, nil) | FunctionClauseError |
| create_membership("zzz", uuid) | Ecto.Query.CastError (from valid_role_names/1, BEFORE the changeset) |

`Ecto.CastError` fires zero times. Every cast raise is `Ecto.Query.CastError`.

## 4. Gate trap

`scripts/docs-anchors-check.sh` §8 greps `--include='*.exs'` and is comment-unaware, so the
totality test must never write the literal `@canonical capability:<slug>` (slug-uniqueness fail).

    git show origin/main:scripts/docs-anchors-check.sh | sed -n '310,330p'
