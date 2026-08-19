# role_permits?/3 guard placement — re-derivation recipe (tenancy-auth-totality wave)

Baseline: origin/main bf499f54b63135b8ae078305b83f2b5b2c078877.
`api/lib/barkpark/tenancy/auth.ex` is BYTE-IDENTICAL between local HEAD 228090798 and origin/main
(`git diff origin/main -- api/lib/barkpark/tenancy/auth.ex` is empty), so the runs below are authoritative.

## 1. Current values (the thing seam A would flip)

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix run -e '
    alias Barkpark.Tenancy.Auth
    r = fn f -> try do f.() rescue e -> {:raise, e.__struct__} end end
    IO.inspect(r.(fn -> Auth.role_permits?("admin", "", :admin) end), label: "builtin+empty")
    IO.inspect(r.(fn -> Auth.role_permits?("admin", "not-a-uuid", :admin) end), label: "builtin+garbage")
    IO.inspect(r.(fn -> Auth.role_permits?("member", "", :read) end), label: "member+empty+read")
    IO.inspect(r.(fn -> Auth.role_permits?("owner", "", :write) end), label: "owner+empty+write")
    IO.inspect(r.(fn -> Auth.role_permits?("admin", nil, :admin) end), label: "builtin+nil")
    IO.inspect(r.(fn -> Auth.role_permits?("custom", "", :admin) end), label: "custom+empty")
    IO.inspect(r.(fn -> Auth.role_permits?("custom", "not-a-uuid", :admin) end), label: "custom+garbage")'

Expected on origin/main: true / true / true / true / false / {:raise, Ecto.Query.CastError} / {:raise, Ecto.Query.CastError}.
NOTE the module is `Ecto.Query.CastError`, NOT `Ecto.CastError`.

## 2. Both candidate seams, side by side

Script: scratchpad `seam_probe.exs` (reproduced in the verifier report). It replicates
`granted_actions/2` + `db_actions/2` as two closures and tables TODAY vs SEAM_A vs SEAM_B.

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix run <path>/seam_probe.exs

Expected: SEAM_A (guard before the `@builtin_role_actions` lookup) flips FOUR rows true->false
(admin/"", admin/"not-a-uuid", member/""/:read, owner/""/:write). SEAM_B (guard inside `db_actions/2`
only) flips ONLY the two rows that raise today, converting the raise to `false`.

## 3. Caller frontier

    git grep -n "role_permits?" origin/main

Exactly three call sites: auth.ex:186 (internal, inside `authorize(%User{}, ...)` behind a non-nil
`membership/2`), caps.ex:220, caps.ex:249. Both caps.ex sites pattern-match a non-nil membership row
(`%{role: role}`) that `load_memberships/2` produced from `socket.assigns[:current_workspace].id`.

## 4. Non-nil membership implies castable workspace id

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix run -e '
    alias Barkpark.Tenancy.Auth; alias Barkpark.Accounts.User
    u = %User{id: Ecto.UUID.generate()}
    r = fn f -> try do f.() rescue e -> {:raise, e.__struct__} end end
    IO.inspect(r.(fn -> Auth.membership(u, "") end))
    IO.inspect(r.(fn -> Auth.membership(u, nil) end))
    IO.inspect(r.(fn -> Auth.membership(%User{id: nil}, Ecto.UUID.generate()) end))'

Expected: {:raise, Ecto.Query.CastError} / {:raise, FunctionClauseError} / {:raise, FunctionClauseError}.
A malformed workspace id can never YIELD a membership row, so it can never reach `role_permits?/3`.

## 5. Global-role delta check (why `nil -> []` is safe inside db_actions)

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix run -e \
      'IO.inspect(Barkpark.Repo.query!("select count(*) from roles where workspace_id is null").rows)'

Expected on a fresh test DB: [[0]]. Migration 20260705150000_create_rbac_roles.exs documents
NULL workspace_id = GLOBAL BUILT-IN role — and built-in names never reach `db_actions/2`
(`granted_actions/2` short-circuits them to `@builtin_role_actions`).
