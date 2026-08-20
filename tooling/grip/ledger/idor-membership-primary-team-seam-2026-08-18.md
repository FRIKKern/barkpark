<!-- doc-tier: cold | canonical-for: idor-wave-membership-primary-team-rederivation | budget: 800tok -->

# IDOR wave — membership/primary-team resolve-edge seam re-derivation (2026-08-18)

VERDICT: seam closed, ZERO findings. `conn.assigns.current_team` can never be a team the authenticated caller is not a LIVE member of.

## Re-derivation recipes

resolve_team fills current_team only from a membership row (header path requires get_membership non-nil; else primary_team):

    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '121,129p'

primary_team = List.first(list_user_teams); list_user_teams is JOIN-scoped on TeamMembership (no membership row = no team):

    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '/def list_user_teams/,/Repo.all/p; /def primary_team/p'

Membership rows are created ONLY via add_member/add_member_as. Deleted only via:
- do_remove (line ~1815): Repo.delete!(membership) + delete_user_session_tokens + revoke_team_pats, ALL in one Repo.transaction — never leaves a stale grant after credential revocation:

    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1815,1832p'

- FK cascade (user delete / team delete): both user_id and team_id are references(... on_delete: :delete_all) — cascading REMOVES the membership row (safe direction: less access, never a stale grant):

    git show origin/main:cloud/priv/repo/migrations/20260626190200_create_team_memberships.exs | sed -n '13,17p'

No direct delete_all / bulk mutation targets team_memberships anywhere in cloud/lib or post-create migrations:

    grep -rn 'team_memberships\|TeamMembership' cloud/lib/ cloud/priv/repo/migrations/ | grep -iE 'delete_all|Repo.delete'
    # only hit: accounts.ex do_remove (Repo.delete!(membership)) — the clean path above.
    # 1763 (locked_owner_count) and 1947 (list_team_members) are READS.

## Conclusion for Decide

The clean-by-construction foundation holds. Role gates (require_team_admin/require_primary_team_admin) read the SAME current_team that is membership-scoped, so role and ownership are never checked against different teams. No stale-membership crack. No inline fix, no child to file from this seam.
