# CCH wave 23 — cap-reachability probe (member rung + sites PATCH allow-list)

Re-derivation recipes only. Every number below is reproducible from a clean
checkout of `origin/main` plus the cloud test DB.

## Q1 — can a `role=member` mint a PAT carrying `deploy`? **NO.**

The refusal is in the CONTEXT, not the route. `Accounts.create_personal_access_token/3`
calls `pat_abilities_allowed?(Authz.role(user, team), requested)`, which returns
true only for `owner`/`admin`; every other role is capped at `["read"]` and gets
`{:error, :forbidden}` BEFORE the changeset. The route maps that to 403.

```
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '838,856p'
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4839,4895p'
cd cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/web/router_pat_test.exs:124 --trace
```

Therefore the `cond` at `router.ex:1998-2005` (`POST /v1/fleet/supports`) is NOT
a bypass: its PAT branch fires only for a credential a member can never hold.

## Q1' — the ONE real member-rung hole: a stale grant

An admin mints a `deploy` PAT, is then demoted to `member`; the PAT keeps
passing every admin-gated route. Reproduce:

```
cd cloud && CC=clang MIX_ENV=test mix test \
  <scratch>/cap_reach_probe2_test.exs --trace   # test R3
# -> role after demote = "member"; POST /v1/fleet/supports status=201
```

## Q2 — does `PATCH /v1/sites/:id`'s `Map.take` include `doc_type`? **YES, no drift.**

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex   | sed -n '6070,6082p'
git show origin/main:cloud/lib/barkpark_cloud/registry/site.ex | sed -n '330,335p'
```

Route allow-list `["theme","doc_type","prebuilt_enabled"]` == changeset cast
`[:theme, :doc_type, :prebuilt_enabled]`. Round-trip proof: PATCH `doc_type` →
200 and `Repo.get!(Site).doc_type == "recipe"`.

## Admissibility deltas for the cruelty ledger

* `barkpark.name` (255) — stays **INADMISSIBLE**, and role is not why. Even an
  ADMIN holding a `deploy` PAT is refused at `POST /v1/go-live`:
  `422 {"error":"invalid","details":{"slug":["should be at most 63 character(s)"]}}`.
  D251(2)'s derivation bound holds at the highest person-reachable rung.
* `site.name` (255) — **ADMISSIBLE at the member rung.** `POST /v1/sites`
  (`router.ex:5875`) is bare `Auth.require_user`, no role gate: a `member`
  creates a site with a 255-char name → 201.
* `site.domains` (253) — **ADMISSIBLE at the member rung**, but the cap is
  `validate_change` + `@domain_format` (`site.ex:28,431-436`), so a cruel string
  must be a LEGAL hostname: labels ≤63, dots included. 3×63-char labels + a
  61-char label = exactly 253 → 200, persists. 254 → 422. A naive
  `String.duplicate("q", 253)` is 422 and would record a false NONE-POSSIBLE.
* The ledger needs a **STALE-GRANT** note, not (only) an ADMIN-ONLY class: role
  at mint time, not at use time, is what a deploy PAT encodes.

## Rerun-all

```
cd cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/web/router_pat_test.exs
# -> 16 tests, 0 failures
```
