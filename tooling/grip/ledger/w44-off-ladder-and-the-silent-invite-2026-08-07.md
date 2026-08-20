# Re-derivation recipes — wave 44 verifier [off-ladder-and-the-silent-invite]

Tree under test: `origin/main`, extracted clean (never the dirty worktree).

```bash
cd /tmp && rm -rf omv9 && mkdir omv9 \
  && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud internal deploy | tar -x -C omv9 \
  && cd /tmp/omv9 && node --test cloud/priv/static/__app.test.mjs 2>&1 | tail -6
# => # pass 943 / # fail 0
```

## R1 — memberRowHtml over the off-ladder target domain (driven, not read)

The driver `/tmp/omv9/drive.mjs` rebuilds the `__app.test.mjs` vm sandbox verbatim,
evals the SHIPPED `cloud/priv/static/app.js`, and calls the exported
`hooks.memberRowHtml(m, ctx)` for actor ∈ {owner,admin,member} × target ∈
{owner,admin,member,"wizard","Admin","",null,undefined}, reporting
`data-member-role=` / `data-member-remove=` presence and the rendered chip.

Result: for EVERY actor with `assignableRoles(actor).length > 0` (owner + admin),
BOTH controls render on EVERY target including off-ladder. The target's role is
never consulted. A `member` actor gets neither on any target. Self row: neither,
for all three actors.

## R2 — the server's own rank default is 0, not "above"

```bash
grep -n "@ranks\|def rank\|def outranks?\|validate_inclusion" \
  /tmp/omv9/cloud/lib/barkpark_cloud/accounts/team_membership.ex
grep -n "def can_grant?" -A 10 /tmp/omv9/cloud/lib/barkpark_cloud/accounts/authz.ex
sed -n '1715,1730p;1784,1810p' /tmp/omv9/cloud/lib/barkpark_cloud/accounts.ex
```

`rank(role) = Map.get(@ranks, role, 0)` — the server treats an unrankable role as
BELOW everything. Mirroring it exactly is faithful; treating an unrankable target
as ABOVE the actor is a NEW false refusal.

## R3 — off-ladder is not writable through cloud/lib

```bash
grep -rn "insert_all\|update_all" /tmp/omv9/cloud/lib | grep -i member   # (empty)
grep -rn "team_memberships" /tmp/omv9/cloud/priv/repo/migrations/*.exs | grep -i check  # (empty)
```

`validate_inclusion(:role, @roles)` on the only changeset + no raw writes ⇒ reachable
only by direct SQL. No DB CHECK constraint backs it up.

## R4 — the silent invite

```bash
sed -n '19937,19944p' /tmp/omv9/cloud/priv/static/app.js   # `if (c) openInviteModal(c);` — no else
sed -n '18544,18546p;18590,18595p' /tmp/omv9/cloud/priv/static/app.js  # invite.hidden = !canManage
grep -n "function teamAuthorityState" -A 20 /tmp/omv9/cloud/priv/static/app.js  # "stale" arm
```

## R5 — the shipped comment carrying the false D448 sentence

```bash
sed -n '264,266p' /tmp/omv9/cloud/priv/static/app.js
sed -n '1721,1724p' /tmp/omv9/cloud/lib/barkpark_cloud/accounts.ex
```
