defmodule BarkparkCloud.Accounts.Erasure do
  @moduledoc """
  HARD ERASURE of a team and of an account — the two routes the control plane
  did not have.

  ## The ruling this implements

  Barkpark Cloud OFFERS SELF-SERVE ERASURE, at both levels, as routes. That was
  ruled by team-lead on 2026-09-02 and recorded on `task-c161ba42b88805c0`; the
  alternative on the table was to record the absence as consented, and it was
  declined because nobody had consented to it. Before this module the only
  erasable object on the plane was a single archive bundle
  (`ArchiveStore.delete_bundle/2`, PR #15458): a person who asked to be removed
  could have one archive object purged and nothing else.

  ## What is DELETED, what is ANONYMISED, what CASCADES, what is REFUSED

  This is a data-erasure surface, so the four are stated separately and the
  tests assert each one.

  ### `delete_team/2` — DELETED

  The `teams` row. The FK graph then cascades (`on_delete: :delete_all`, every
  one verified against the migration that created it):

      team_memberships · team_invitations · providers · subscriptions ·
      email_notification_settings · notification_deliveries ·
      github_installations · deploy_rate_alert_states · audit_events ·
      user_tokens (the team-scoped PATs; `user_tokens.team_id`)

  ### `delete_team/2` — REFUSED

  `{:error, :instances_present}` while the team still owns ANY `barkparks` or
  `sites` row. This refusal is the whole safety argument of the function.
  `barkparks.team_id` cascades, so a naive team delete would drop every instance
  ROW while the Hetzner/Azure server it names keeps running and keeps billing,
  and the row is the only thing that still says what to tear down. Erasure must
  not strand a billed box. The owner decommissions the fleet first
  (`DELETE /v1/barkparks/:id`, which runs the real deprovision path), and the
  refusal names the counts so the console can say what is in the way.

  A team with a live subscription is NOT refused: `subscriptions` cascades and
  the plane's own cancel-on-decommission path already runs when the last
  instance goes. The refusal above therefore implies an instance-free team.

  ### `delete_user/2` — DELETED

  The `users` row, cascading:

      team_memberships · user_tokens (sessions AND every PAT) ·
      external_identities · device_push_tokens · device_auth_requests ·
      user_security_events

  ### `delete_user/2` — ANONYMISED, NOT DELETED

  `audit_events.actor_user_id` is `ON DELETE SET NULL`, deliberately and it stays
  that way. A team's audit trail is the TEAM's record of what happened to the
  TEAM, not the leaving user's personal data; erasing the actor pointer removes
  the person from it while the team keeps an honest history of its own instances.
  The row's `metadata` may still carry an email the producing route put there —
  callers who need those scrubbed too need a separate sweep, and this module does
  not claim to have done it. `list_orphaned_audit_actor_count/1` exists so a test
  can assert the trail SURVIVED rather than assume it.

  ### `delete_user/2` — REFUSED (second ground)

  An account with no usable password hash — an OAuth-only account — cannot reach
  this function through `DELETE /v1/account` at all: the route reauthenticates
  with the account password before calling, and `Accounts.valid_password?/2`
  returns false for such a user at the same cost as a wrong password. That is a
  known, deliberate gap in self-serve coverage, not an oversight, and it is the
  one erasure case that still needs a human: an OAuth-only holder must set a
  password first, or ask an operator.

  ### `delete_user/2` — REFUSED (primary ground)

  `{:error, {:sole_owner, slugs}}` when the user is the ONLY `owner` of any team
  that still exists. Deleting them would leave a team nobody can administer:
  `team_memberships` cascades, so the team would survive with its instances, its
  subscription and its members, and no one able to delete it, invite into it or
  pay for it. The refusal names the team slugs; the owner's route out is to
  promote another owner (`PATCH /v1/teams/:id/members/:user_id`) or to erase the
  team first (`DELETE /v1/teams/:id`). A team where the user is one of several
  owners, or is an admin/member, never blocks.

  ## The append-only bypass

  `audit_events` and `user_security_events` carry BEFORE UPDATE OR DELETE
  triggers that raise. A row-level BEFORE DELETE trigger fires on an FK CASCADE
  too, so both deletes above would ABORT without a bypass. Migration
  `20260917100000` narrowed both trigger functions to fall through on
  `TG_OP = 'DELETE'` when the session GUC `barkpark.erasure` reads `'on'`;
  `SET LOCAL` inside the erasure transaction turns it on for that transaction and
  that connection only. `arm_erasure/0` is the only caller of that `SET LOCAL`
  in the codebase.

  `audit_events` needed a second, narrower exception that the first test run
  found: the anonymisation above is an `ON DELETE SET NULL`, which reaches the
  trigger as an **UPDATE**, so an unconditional UPDATE raise aborted the account
  erasure exactly as the DELETE raise had aborted the team one. The exception is
  shaped to be that nilify and nothing else — flag on, `actor_user_id` going
  non-NULL → NULL, every other column byte-identical. Rewriting an `action`, a
  `metadata` or a `team_id` still raises under the flag, and
  `user_security_events` keeps its unconditional UPDATE raise.
  """

  import Ecto.Query, warn: false

  alias BarkparkCloud.Accounts.{AuditEvent, Team, TeamMembership, User}
  alias BarkparkCloud.Registry.{Barkpark, Site}
  alias BarkparkCloud.Repo

  @type blocker :: %{barkparks: non_neg_integer(), sites: non_neg_integer()}

  @doc """
  What stands in the way of erasing `team`, as counts. `%{barkparks: 0, sites: 0}`
  means `delete_team/2` will not refuse on this ground.

  Separate from `delete_team/2` on purpose: the console needs to SAY what blocks
  the delete before the person types the team name, and a refusal reason a
  surface can only learn by attempting the destructive call is not a surface.
  """
  @spec team_erasure_blockers(Team.t() | binary()) :: blocker()
  def team_erasure_blockers(team) do
    tid = id_of(team)

    %{
      barkparks: Repo.aggregate(from(b in Barkpark, where: b.team_id == ^tid), :count),
      sites: Repo.aggregate(from(s in Site, where: s.team_id == ^tid), :count)
    }
  end

  @doc """
  Slugs of the teams `user` solely owns — the `delete_user/2` refusal, readable
  before the attempt for the same reason as `team_erasure_blockers/1`.

  "Solely owns" is exactly: the user holds `role == "owner"` on the team AND the
  team has no other owner membership. Counted in SQL over the team's OWN owner
  rows, never from a cached role string.
  """
  @spec sole_owner_team_slugs(User.t() | binary()) :: [String.t()]
  def sole_owner_team_slugs(user) do
    uid = id_of(user)

    from(m in TeamMembership,
      join: t in Team,
      on: t.id == m.team_id,
      where: m.user_id == ^uid and m.role == "owner",
      where:
        1 ==
          fragment(
            "(SELECT count(*) FROM team_memberships o WHERE o.team_id = ? AND o.role = 'owner')",
            m.team_id
          ),
      select: t.slug,
      order_by: t.slug
    )
    |> Repo.all()
  end

  @doc """
  How many audit rows on `team` have a NULL actor — the anonymisation assertion.
  A test proving `delete_user/2` anonymised rather than deleted reads this.
  """
  @spec orphaned_audit_actor_count(Team.t() | binary()) :: non_neg_integer()
  def orphaned_audit_actor_count(team) do
    tid = id_of(team)

    Repo.aggregate(
      from(e in AuditEvent, where: e.team_id == ^tid and is_nil(e.actor_user_id)),
      :count
    )
  end

  @doc """
  Erase `team`. Returns `{:ok, :erased}`, or `{:error, {:instances_present,
  blockers}}` when the team still owns instances or sites.

  The blocker re-count happens INSIDE the transaction, under a lock on the team
  row, so a `POST /v1/barkparks` racing the delete cannot slip an instance in
  between the console's pre-check and the cascade.
  """
  @spec delete_team(Team.t(), keyword()) ::
          {:ok, :erased} | {:error, {:instances_present, blocker()} | :not_found}
  def delete_team(%Team{} = team, _opts \\ []) do
    Repo.transaction(fn ->
      case Repo.one(from(t in Team, where: t.id == ^team.id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        %Team{} = locked ->
          blockers = team_erasure_blockers(locked)

          if blockers.barkparks > 0 or blockers.sites > 0 do
            Repo.rollback({:instances_present, blockers})
          end

          arm_erasure()
          Repo.delete!(locked)
          :erased
      end
    end)
  end

  @doc """
  Erase `user`. Returns `{:ok, :erased}`, or `{:error, {:sole_owner, slugs}}`
  when the user is the last owner of a team that still exists.

  The sole-owner re-check happens INSIDE the transaction, under a lock on the
  user's owner memberships, so a concurrent demotion of the other owner cannot
  produce an ownerless team.
  """
  @spec delete_user(User.t(), keyword()) ::
          {:ok, :erased} | {:error, {:sole_owner, [String.t()]} | :not_found}
  def delete_user(%User{} = user, _opts \\ []) do
    Repo.transaction(fn ->
      case Repo.one(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        %User{} = locked ->
          case sole_owner_team_slugs(locked) do
            [] ->
              arm_erasure()
              Repo.delete!(locked)
              :erased

            slugs ->
              Repo.rollback({:sole_owner, slugs})
          end
      end
    end)
  end

  # The ONE call site of the append-only bypass. `SET LOCAL` binds the GUC to
  # this transaction on this connection: it reverts at COMMIT and at ROLLBACK,
  # and no other connection ever observes it. Calling it outside a transaction
  # would be a silent no-op (Postgres warns and discards a SET LOCAL with no
  # transaction) — both callers above are inside `Repo.transaction/1`.
  defp arm_erasure do
    Repo.query!("SET LOCAL barkpark.erasure = 'on'")
    :ok
  end

  defp id_of(%Team{id: id}), do: id
  defp id_of(%User{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id
end
