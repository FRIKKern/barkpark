<!-- doc-tier: agent | canonical-for: cloud-object-authz | budget: 1200tok -->
# Cloud object authz — team · barkpark ownership

How `cloud/` decides that **this caller may act on that object**. Object-level (BOLA/IDOR) authorization for the control plane, whose unit is the **team** and whose objects are **barkparks**. Code: `cloud/lib/barkpark_cloud/web/auth.ex`, `cloud/lib/barkpark_cloud/web/router.ex`, `cloud/lib/barkpark_cloud/accounts.ex`.

**Different model from `docs/contracts/tenancy.md`**, which owns the *API-layer* workspace·project·dataset scoping. Nothing here is workspace-scoped; nothing there is team-scoped. A cloud route that reached for `scope_to_workspace/3` would be in the wrong model.

## The foundation — `current_team` is never attacker-chosen

`BarkparkCloud.Web.Auth`'s private `resolve_team/2` is the only producer of the `:current_team` assign. It honors the SPA team-switcher header `x-barkpark-team` **only** when `Accounts.get_membership/2` confirms the caller holds a live membership on that team; every other case — absent header, malformed id, a team the user was removed from — falls back to `Accounts.primary_team/1` (the oldest membership).

So the invariant every route below leans on:

> **`current_team` is always a team the caller is a live member of.** A caller can *choose which* of their teams is current; they cannot name a team they do not belong to.

The fallback is deliberate: a stale switcher value degrades to a working dashboard instead of bricking it. Note it is **not** fail-closed but fail-*sideways* — it never widens (the fallback team is still one the caller belongs to), and `primary_team/1` returns `nil` for a memberless user, which denies downstream.

Role authority on the resolved team is a separate axis: `Accounts.Authz.team_admin?/2` and `team_owner?/2`, surfaced as the `require_team_admin/2` and `require_team_owner/2` plugs.

## The 3+1 blessed resolve signals

Membership proves *which team*. It does **not** prove the `:id` in the path belongs to that team — that is object-level authz, and every `/v1/barkparks/:id*` route must carry exactly one of these:

| signal | where | shape |
|---|---|---|
| `resolve_team_barkpark/2` | private in `BarkparkCloud.Web.Router` | `Registry.get_barkpark/1`, then `%Barkpark{team_id: tid} when tid == team.id` → the row, else `nil` |
| `proxy_instance_webhook/2` | private in `BarkparkCloud.Web.Router` | require_user → `current_team` → `resolve_team_barkpark/2` **before** proxying; the whole `/api/webhooks*` family |
| `Registry.recent_events_for_team/3` | `BarkparkCloud.Registry` | same team-id match, `nil` cross-team; the events/telemetry read pair |
| inline `tid == team.id` | route bodies in `BarkparkCloud.Web.Router` | body pattern-matches the resolved `%Barkpark{team_id: tid}` against `current_team` inline |

All four collapse to one rule: **resolve, then assert `team_id`, and return `nil` cross-team** so the route 404s. A cross-team id is indistinguishable from a missing one — the control plane does not confirm that another team's barkpark exists.

## The forward guard — `BarkparkCloud.Web.BarkparksIdOwnershipCensusTest`

`cloud/test/barkpark_cloud/web/barkparks_id_ownership_census_test.exs` re-derives the population from `router.ex` **source** on every run: it matches every block-form `/v1/barkparks/:id*` route head, cuts each body at the strict route-indentation `end`, and classifies it by the first blessed signal it contains. Three assertions — the route count matches `@expected_route_count`, the offender list (bodies matching **no** signal) is empty, and the per-signal tally matches the disposition table pinned in its `@moduledoc`.

**What it proves and does not.** It is syntactic: it proves a blessed resolve *name* appears in the body, not that the body honors the `nil`. That second guarantee belongs to the per-route cross-team-404 regression tests it pairs with and does not replace. The tally assertion exists because an over-matching signal would hide a real offender.

## How a new route earns a disposition

Add a `/v1/barkparks/:id*` route and the census reds immediately on the count assertion — that is the design, not an obstacle. Pick one of the four signals and use it. If the route genuinely needs new team-scoping vocabulary (say `scope_to_team/2`), the census stays red until a human adds that signal to `@signals` **with its reason** and re-derives the disposition table and tally. New authorization vocabulary is ruled on deliberately, never absorbed silently.
