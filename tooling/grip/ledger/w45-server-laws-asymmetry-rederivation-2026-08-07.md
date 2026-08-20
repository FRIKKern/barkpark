# Re-derivation recipe — the two member laws DISAGREE, and origin/main already pins it

Wave 45 verifier `[server-laws-asymmetry]`. Subject: `origin/main` = `b00d793c0e2065e98a03fed6c4356245d897ee3a`
(which IS the merge commit of PR #10252, `cch-w44-s5`).

## 0. THE TRAP THIS ROW EXISTS FOR

The primary checkout was **571 commits behind `origin/main`**. Its
`accounts_invitations_test.exs` has **29 tests**; `origin/main`'s has **32** — the three
missing ones are exactly the crux pin. A local `mix test` therefore answered
"the collapse is UNCAUGHT" when the truth on `origin/main` is "caught, 1 failure".
Always extract the test file from `origin/main` and require it from a scratchpad shim.

```
git rev-parse HEAD; git log --oneline HEAD..origin/main | wc -l   # -> 571
```

## 1. READ THE TWO LAWS (never a charter sentence)

```
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1715,1733p;1784,1811p'
```

* `remove_member_as/3` :1722 — `if actor_role == "owner" or TeamMembership.outranks?(actor_role, target_role) do`  → **OWNER ESCAPE HATCH**, no `self?` branch.
* `update_member_role_as/4` :1798/:1801 — `Authz.can_grant?/3` AND `not self? and not outranks?(...)` → **NO hatch**, but a **`self?` bypass**.

## 2. PROVE THE LAW BODIES ARE SAFE TO RUN LOCALLY

```
diff <(git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1715,1733p') <(sed -n '1540,1558p' cloud/lib/barkpark_cloud/accounts.ex)
diff <(git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1784,1811p') <(sed -n '1605,1632p' cloud/lib/barkpark_cloud/accounts.ex)
```
Both empty on 2026-08-07 → the local module is byte-identical for these two functions
(`team_membership.ex` and `accounts/authz.ex` are whole-file identical by `shasum`).

## 3. MUTATE WITHOUT TOUCHING THE REPO

`mix test` has no `--require`. Put the mutation and a `Code.require_file` of
`origin/main`'s test file in ONE scratchpad `.exs` and pass that to `mix test`.
`Code.compile_string` never writes a `.beam`, so nothing is left behind.

```elixir
src = File.read!("lib/barkpark_cloud/accounts.ex")
Code.compiler_options(ignore_module_conflict: true)
Code.compile_string(String.replace(src, OLD, NEW), "MUT.ex")
Code.require_file("<scratch>/main_invitations_test.exs")
```
Run from `cloud/` with `CC=clang`.

## 4. THE THREE MUTATIONS AND THEIR MEASURED VERDICTS (32-test file)

| # | mutation | result |
|---|---|---|
| — | clean | 32 tests, 0 failures |
| A | add remove's owner hatch to `update_member_role_as/4` (collapse role-change onto remove) | **1 failure** — only "owner on a PEER OWNER" |
| B | strip the hatch from `remove_member_as/3` (collapse remove onto the rank rule) | **3 failures** |
| C | drop the `self?` bypass from `update_member_role_as/4` | **3 failures** |

Mutation A is caught by a **single** assertion pair. Delete or weaken
`accounts_invitations_test.exs`'s "owner on a PEER OWNER" test and the collapse ships green.

## 5. THE OFF-LADDER EDGE (corroborates `cch-w44-bl-remove-member-as-holds-only-in-composition`)

`rank/1` answers 0 for an unknown role, so `outranks?("member", "bogus")` is TRUE:

```
Accounts.remove_member_as("member", team, off_ladder_target)  # -> {:ok, :removed}
```
Ran green. Anti-escalation here holds ONLY because of the route wrapper
`with_team_role(conn, "admin", …)` (`router.ex` DELETE member), which the function does not name.

## 6. WHERE THE PIN IS *NOT*

`cloud/priv/static/__app.test.mjs` (`cch-w42-s3`, ~:7712) pins the CONSOLE mirror
(`canRemoveMember("owner","owner",false) === true`, `canChangeMemberRole("owner","owner",false) === false`)
and reads only `app.js` / `app.css` / `index.html` / `__preview__/mock.js` — **never the Elixir source**.
A server-side collapse leaves the whole JS suite green; the Elixir crux test is the only catcher.
`role_agreement_census_test.exs` deliberately has NO ARM E (charter D462) and asserts nothing here.
