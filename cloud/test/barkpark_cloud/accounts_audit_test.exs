defmodule BarkparkCloud.AccountsAuditTest do
  @moduledoc """
  The audit-trail context surface: `record_audit/1`, the `audit/3` transactional
  wrapper (the atomic-with-mutation guarantee), the keyset-paginated,
  team-scoped, actor-preloaded `list_audit_events/2` read, and the DB-level
  append-only enforcement (the BEFORE UPDATE/DELETE trigger).
  """
  use BarkparkCloud.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{AuditEvent, TeamMembership}
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @router_opts Router.init([])

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

    test "accepts site.rolled_back — the router really produces it and the console labels it" do
      team = team_fixture()
      actor = user_fixture()

      assert {:ok, %AuditEvent{} = ev} =
               Accounts.record_audit(%{
                 team_id: team.id,
                 actor_user_id: actor.id,
                 action: "site.rolled_back",
                 target_type: "site",
                 target_id: "site-123",
                 metadata: %{deployment_id: "d-prev", previous_deployment_id: "d-live"}
               })

      assert ev.action == "site.rolled_back"
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

    # REVIEW FIX (GR80 leg 2). The Activity page's Target chips send target_type
    # with NO target_id; before the widening that combination fell through to the
    # catch-all and the "filter" answered the entire unfiltered trail.
    test ":target_type ALONE narrows to that noun — the Activity chip row's real request" do
      team = team_fixture()
      seed(team, "site.created", target_type: "site", target_id: "s-1")
      seed(team, "site.deleted", target_type: "site", target_id: "s-2")
      seed(team, "barkpark.go_live", target_type: "barkpark", target_id: "b-1")

      sites = Accounts.list_audit_events(team, target_type: "site")
      assert Enum.sort(Enum.map(sites, & &1.action)) == ["site.created", "site.deleted"]

      boxes = Accounts.list_audit_events(team, target_type: "barkpark")
      assert Enum.map(boxes, & &1.action) == ["barkpark.go_live"]

      # An ABSENT or empty filter must never narrow — it is not a filter at all.
      assert length(Accounts.list_audit_events(team, target_type: nil)) == 3
      assert length(Accounts.list_audit_events(team, target_type: "")) == 3
      assert length(Accounts.list_audit_events(team)) == 3
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

  # cch-w63-s8 — THE REFUSED WRITE'S ROW, PROVEN BY PERSISTENCE, NEVER BY SOURCE.
  #
  # The audit vocabulary census next door is a SOURCE SCAN and says so in its own
  # moduledoc: declaring `barkpark.credentials_refused` in `AuditEvent.actions/0`
  # and writing that string once anywhere in `cloud/lib` satisfies BOTH its arms
  # unconditionally, whether or not a row is ever persisted. And the failure it
  # cannot see is not hypothetical: a producer that reaches a shared helper with
  # the verb in a MODULE ATTRIBUTE is invisible to all four census arms at once —
  # the literal regex wants a quoted `action: "…"`, the two call-site layers want
  # a quoted verb at the call site, and the helper's own `action: action,` line is
  # already excused in `@accounted_indirection` — while `validate_inclusion`
  # rejects every write at runtime. Zero failures over a producer that has never
  # written a row.
  #
  # So these tests never read source. They drive the REAL routes through
  # `Router.call/2` against a box that answered our stored admin credential 401
  # (`update_unavailable_reason == "identity_refused"`), and then ask the DATABASE
  # what happened. Nothing reaches the wire on this path either: the refusal fires
  # in `Registry.relay_admin_post/3` ABOVE `reveal_admin_token/1`, so no HTTP
  # client is involved and no credential is decrypted.
  describe "a refused instance write leaves a named audit row" do
    defp owner_with_team do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")
      {:ok, token} = Accounts.create_user_session_token(user)
      {Accounts.get_user(user.id), team, token}
    end

    # A LIVE box whose last probe was REFUTED BY THE BOX ITSELF — the one rung of
    # `Barkpark.update_unavailable_reasons/0` that makes the plane stop spending
    # the stored credential (`"forbidden"` is a different fact and does not).
    defp refused_barkpark(team, overrides \\ %{}) do
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      bp
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            host: "203.0.113.#{rem(n, 250) + 1}",
            url: "https://bp-#{n}.barkpark.cloud",
            suspended: false,
            update_state: "unknown",
            update_unavailable_reason: "identity_refused"
          },
          overrides
        )
      )
      |> Repo.update!()
    end

    defp post_as(path, token) do
      conn(:post, path, "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@router_opts)
    end

    defp refused_rows do
      Repo.all(from(e in AuditEvent, where: e.action == "barkpark.credentials_refused"))
    end

    test "the self-update route's refusal persists exactly one row, reason in metadata" do
      {user, team, token} = owner_with_team()
      bp = refused_barkpark(team)

      resp = post_as("/v1/barkparks/#{bp.id}/self-update", token)

      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "identity_refused"

      # THE DATABASE, not the source tree. One row, and only one.
      assert [%AuditEvent{} = ev] = refused_rows()
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.actor_user_id == user.id
      assert ev.team_id == team.id

      # jsonb round-trips to STRING keys. This map is what `audit_json/1` ships as
      # `metadata`, what `auditEntry` renames to `payload`, and what
      # `tlvDetailHtml` prints verbatim as the expanded timeline detail — so the
      # wire word the 409 carried is the word the operator reads an hour later.
      assert ev.metadata == %{"reason" => "identity_refused", "attempted" => "self_update"}
    end

    test "the rollback route's refusal persists its own row, naming the write it refused" do
      {_user, team, token} = owner_with_team()
      bp = refused_barkpark(team)

      resp = post_as("/v1/barkparks/#{bp.id}/rollback", token)

      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "identity_refused"

      assert [%AuditEvent{metadata: metadata}] = refused_rows()
      assert metadata == %{"reason" => "identity_refused", "attempted" => "rollback"}
    end

    # ANTI-VACUITY. The row must be bound to THIS refusal, not to "any 409 on this
    # route": a suspended box is refused by a sibling `cond` clause with the same
    # status and a different fact (the plane withheld attention; the box was never
    # asked and never spoke). If this test ever goes green with a row, the
    # producer has drifted up into the shared refusal path and the verb has
    # stopped meaning what its @actions comment says it means.
    test "a SUSPENDED box's 409 is a different fact and writes NO credentials_refused row" do
      {_user, team, token} = owner_with_team()

      bp =
        refused_barkpark(team, %{suspended: true, update_unavailable_reason: nil})

      resp = post_as("/v1/barkparks/#{bp.id}/self-update", token)

      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "suspended"
      assert refused_rows() == []
    end
  end
end
