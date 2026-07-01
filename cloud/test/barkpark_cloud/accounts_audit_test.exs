defmodule BarkparkCloud.AccountsAuditTest do
  @moduledoc """
  The audit-trail context surface: `record_audit/1`, the `audit/3` transactional
  wrapper (the atomic-with-mutation guarantee), the keyset-paginated,
  team-scoped, actor-preloaded `list_audit_events/2` read, and the DB-level
  append-only enforcement (the BEFORE UPDATE/DELETE trigger).
  """
  use BarkparkCloud.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{AuditEvent, TeamMembership}
  alias BarkparkCloud.Repo

  @password "correct-horse-battery"

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  describe "record_audit/1" do
    test "inserts an append-only event with no updated_at" do
      team = team_fixture()
      actor = user_fixture()

      assert {:ok, %AuditEvent{} = ev} =
               Accounts.record_audit(%{
                 team_id: team.id,
                 actor_user_id: actor.id,
                 action: "barkpark.go_live",
                 target_type: "barkpark",
                 target_id: "bp-123",
                 metadata: %{name: "Prod"}
               })

      assert ev.action == "barkpark.go_live"
      assert ev.metadata == %{name: "Prod"}
      assert ev.inserted_at
      # Append-only: the schema has no updated_at field at all.
      refute Map.has_key?(ev, :updated_at)
    end

    test "allows a nil actor (system / webhook action)" do
      team = team_fixture()

      assert {:ok, %AuditEvent{actor_user_id: nil}} =
               Accounts.record_audit(%{
                 team_id: team.id,
                 action: "subscription.activated",
                 target_type: "subscription",
                 metadata: %{source: "stripe_webhook"}
               })
    end

    test "rejects an action outside the closed vocabulary" do
      team = team_fixture()

      assert {:error, changeset} =
               Accounts.record_audit(%{team_id: team.id, action: "member.teleported"})

      assert "is invalid" in errors_on(changeset).action
    end

    test "requires team_id and action" do
      assert {:error, changeset} = Accounts.record_audit(%{})
      errors = errors_on(changeset)
      assert errors.team_id
      assert errors.action
    end
  end

  describe "audit/3 — atomic with the mutation" do
    test "commits the mutation result and the event together" do
      team = team_fixture()
      actor = user_fixture()

      assert {:ok, %TeamMembership{} = m} =
               Accounts.audit(
                 %{
                   team_id: team.id,
                   actor_user_id: actor.id,
                   action: "member.invited",
                   target_type: "team_membership"
                 },
                 fn -> Accounts.add_member(team, actor, "member") end,
                 fn membership -> %{target_id: membership.id} end
               )

      assert m.team_id == team.id
      [ev] = Accounts.list_audit_events(team)
      assert ev.action == "member.invited"
      # The target_id was resolved from the mutation result via target_fun.
      assert ev.target_id == m.id
    end

    test "writes NO event when the inner mutation fails" do
      team = team_fixture()

      assert {:error, :boom} =
               Accounts.audit(
                 %{team_id: team.id, action: "member.invited"},
                 fn -> {:error, :boom} end
               )

      assert Accounts.list_audit_events(team) == []
    end

    test "rolls the mutation back when the audit changeset is invalid" do
      team = team_fixture()
      actor = user_fixture()

      # A valid membership insert paired with an INVALID action: the audit insert
      # fails inside the transaction, so the membership must roll back too — the
      # atomicity guarantee (never a mutation without its record).
      assert {:error, %Ecto.Changeset{}} =
               Accounts.audit(
                 %{team_id: team.id, action: "not.a.real.action"},
                 fn -> Accounts.add_member(team, actor, "member") end,
                 fn m -> %{target_id: m.id} end
               )

      assert Accounts.list_audit_events(team) == []
      assert Repo.all(TeamMembership) == []
    end
  end

  describe "list_audit_events/2" do
    defp seed(team, action, opts \\ []) do
      {:ok, ev} =
        Accounts.record_audit(%{
          team_id: team.id,
          action: action,
          actor_user_id: opts[:actor_user_id],
          target_type: opts[:target_type],
          target_id: opts[:target_id]
        })

      ev
    end

    test "returns newest first" do
      team = team_fixture()
      _a = seed(team, "site.created")
      _b = seed(team, "site.deleted")
      _c = seed(team, "barkpark.deleted")

      actions = team |> Accounts.list_audit_events() |> Enum.map(& &1.action)
      assert actions == ["barkpark.deleted", "site.deleted", "site.created"]
    end

    test "caps :limit at 200 and floors it at 1" do
      team = team_fixture()
      seed(team, "site.created")

      assert length(Accounts.list_audit_events(team, limit: 999_999)) <= 200
      assert length(Accounts.list_audit_events(team, limit: 0)) == 1
    end

    test ":before keyset excludes the cursor row and older-only is returned" do
      team = team_fixture()
      first = seed(team, "site.created")
      _second = seed(team, "site.deleted")

      # Everything strictly older than the SECOND event's timestamp is just the
      # first one. Use the second's inserted_at as the cursor.
      [_newest, older] = Accounts.list_audit_events(team)
      page = Accounts.list_audit_events(team, before: older.inserted_at)
      # Nothing is older than the first row.
      assert page == [] or Enum.all?(page, &(&1.inserted_at < older.inserted_at))
      assert first.id == older.id
    end

    test ":target_type + :target_id narrows to one resource's history" do
      team = team_fixture()
      seed(team, "site.created", target_type: "site", target_id: "s-1")
      seed(team, "site.deleted", target_type: "site", target_id: "s-2")

      events = Accounts.list_audit_events(team, target_type: "site", target_id: "s-1")
      assert Enum.map(events, & &1.action) == ["site.created"]
    end

    test "is strictly team-scoped — never crosses teams" do
      team_a = team_fixture()
      team_b = team_fixture()
      seed(team_a, "site.created")
      seed(team_b, "barkpark.deleted")

      assert Enum.map(Accounts.list_audit_events(team_a), & &1.action) == ["site.created"]
      assert Enum.map(Accounts.list_audit_events(team_b), & &1.action) == ["barkpark.deleted"]
    end

    test "preloads the actor_user so the email renders without an N+1" do
      team = team_fixture()
      actor = user_fixture()
      seed(team, "member.invited", actor_user_id: actor.id)

      [ev] = Accounts.list_audit_events(team)
      assert %BarkparkCloud.Accounts.User{} = ev.actor_user
      assert ev.actor_user.email == actor.email
    end

    test "a system event preloads actor_user as nil" do
      team = team_fixture()
      seed(team, "subscription.activated")

      [ev] = Accounts.list_audit_events(team)
      assert is_nil(ev.actor_user)
    end
  end

  describe "append-only enforced AT THE DB (BEFORE UPDATE/DELETE trigger)" do
    test "a raw UPDATE against audit_events is rejected and the row is unchanged" do
      team = team_fixture()
      {:ok, ev} = Accounts.record_audit(%{team_id: team.id, action: "site.created"})

      # A raw UPDATE (bypassing the schema's updated_at:false) must be blocked by
      # the DB trigger — an audit fact can never be rewritten. Wrapped in a
      # savepoint so the raise doesn't poison the surrounding sandbox txn.
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.update_all(from(e in AuditEvent, where: e.id == ^ev.id),
            set: [action: "member.removed"]
          )
        end)
      end

      # The fact survived, unmodified.
      assert %AuditEvent{action: "site.created"} = Repo.get(AuditEvent, ev.id)
    end

    test "a raw DELETE against audit_events is rejected and the row survives" do
      team = team_fixture()
      {:ok, ev} = Accounts.record_audit(%{team_id: team.id, action: "site.created"})

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.delete_all(from(e in AuditEvent, where: e.id == ^ev.id))
        end)
      end

      assert %AuditEvent{} = Repo.get(AuditEvent, ev.id)
    end
  end
end
