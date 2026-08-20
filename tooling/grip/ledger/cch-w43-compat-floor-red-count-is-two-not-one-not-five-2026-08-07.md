# The wave-42 compatibility floor reds TWO rendered scenarios, not one and not five

Three numbers were in circulation for "what breaks if you delete the wave-42
compatibility floors in app.js":

* the wave-43 digest: "exactly one unit test and one unwatched pixel; all 104
  smoke scenarios render identically"
* `cch-w42-s1-f1-smoke-fixtures-carry-team-authority` (CANCELLED 2026-08-07
  06:35:59Z): "removing it makes `__preview__/smoke.mjs` print `5 scenario(s)
  failed`"
* this measurement: **2**, and the two floors are ASYMMETRIC.

## Re-derivation recipe (hermetic, no repo write, ~3 min)

```sh
SP=$(mktemp -d)
cd <repo>
git archive origin/main cloud/priv/static | tar -x -C "$SP"
cd "$SP/cloud/priv/static/__preview__" && node smoke.mjs | tail -1
#   => all 104 scenarios rendered            (BASELINE, origin/main dad66869e)
```

Then, in `$SP/cloud/priv/static/app.js`:

FLOOR 1 — `canManageOnboarding` (origin/main :6116). Replace the whole body
with `return teamAuthorityState() === "grant";`, deleting the two-line
`if (meCache && meCache.team_authority) return false; return !!(meCache &&
(meCache.role === "owner" || meCache.role === "admin"));` tail.

FLOOR 2 — `membersContext` (origin/main :18135). Replace
`role: (ta && ta.role) || me.role || "member",` with `role: ta && ta.role,`.

| removed | `node smoke.mjs \| tail -1` |
|---|---|
| FLOOR 1 only | `all 104 scenarios rendered` |
| FLOOR 2 only (with FLOOR 1 also removed) | `2 scenario(s) failed` |
| BOTH, after widening the `me()` fixture | `all 104 scenarios rendered` |

The two failures, by name:

```
  FAIL members-populated — the admin-only invitations card renders
  FAIL env-populated  — the add-var form section renders with a save-row
```

## The fixture widening that makes both floors deletable

In `cloud/priv/static/__preview__/scenarios.mjs`, inside `me()` (origin/main
:959), beside `team:` / `role:`:

```js
teams: [{ id: IDS.team, name: teamName, slug: "acme", role: role || "owner" }],
team_authority: {
  team_id: IDS.team,
  role: role || "owner",
  admin: (role || "owner") === "owner" || (role || "owner") === "admin",
  owner: (role || "owner") === "owner",
},
```

With that in place BOTH floors delete at `all 104 scenarios rendered`.

## What this settles

The crown is NOT fixture-tidying. FLOOR 2 is load-bearing on two rendered
scenarios today, so it cannot be deleted until the corpus mints the envelope
the server actually sends. FLOOR 1 has zero rendered coverage — that half of
the digest's claim is correct, and it is itself a finding (a floor no
instrument watches).

## Related, same run

`renderTeamMenu` (origin/main app.js:5217) has exactly ONE pin anywhere:
`cloud/priv/static/__app.test.mjs:1371`, a `/function renderTeamMenu\(/`
regex over `readFileSync(app.js)`. Adding `teams[]` to the fixture changes
what it paints and NOTHING reds — a source-text scan cannot see a rendered
change.

```sh
grep -rn "No teams yet\|renderTeamMenu\|team-menu" \
  cloud/priv/static/__preview__/smoke.mjs cloud/priv/static/__app.test.mjs
```
