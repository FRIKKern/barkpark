defmodule BarkparkCloud.Web.RouterAuditTest do
  @moduledoc """
  The audit read route (`GET /v1/audit`, ADMIN-gated) and the audited write
  seams: the router wraps each mutating route in `Accounts.audit/3` (or a
  best-effort post-commit `record_audit/1` for the Stripe webhook) so a
  successful mutation stamps exactly one correctly-shaped audit row, and a failed
  one stamps none. Driven via Plug.Test, mirroring RouterTest.
  """
  # async: false — the GitHub credential seams toggle the global
  # `BarkparkCloud.GitHub` app env to simulate a configured App (same reason the
  # dedicated GitHub router tests run non-async), so this module must not race a
  # parallel test reading `GitHub.configured?/0`.
  use BarkparkCloud.DataCase, async: false

  import BarkparkCloud.TotpTestHelper
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.AuditEvent
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.StubGateway
  alias BarkparkCloud.GitHub
  alias BarkparkCloud.GitHub.Fake
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Vercel
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

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

  # An OWNER of a fresh team, plus a session token. {user, team, token}.
  defp logged_in do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  # Add a member to `team` at `role` and return {user, token}.
  defp member_of(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp barkpark_fixture(team, attrs) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp site_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    bp = barkpark_fixture(team, %{})

    {:ok, site} =
      Registry.create_site(bp, Enum.into(attrs, %{name: "Site #{n}", slug: "site-#{n}"}))

    site
  end

  # Simulate a wired GitHub App (id + private key present) so `configured?/0` is
  # true; the client stays the in-memory Fake, so validation costs nothing. The
  # on_exit restores the base config (whole-module async: false makes this safe).
  defp configure_github do
    base = Application.get_env(:barkpark_cloud, GitHub, [])

    Application.put_env(
      :barkpark_cloud,
      GitHub,
      Keyword.merge(base, app_id: "test-app-id", private_key: "dummy-pem", app_slug: "bp-deploy")
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)
  end

  defp events(team, action),
    do: team |> Accounts.list_audit_events() |> Enum.filter(&(&1.action == action))

  # ROW-COUNT WITNESSES (cch-w54). `events/2` and `actions/1` both read through
  # `Accounts.list_audit_events/2`, which is `where: e.team_id == ^tid` — so
  # neither can be asked "was a row written AT ALL?". That is the exact blind
  # spot of `audit_account_security/2` in the cloud router, whose TWO
  # fail-open arms — the `nil` `current_team` skip and the `record_audit`
  # `{:error, cs}` branch — each log and then fall through to a bare `:ok`
  # produced OUTSIDE the `case`. Neither caller inspects it, so a 200 plus a
  # log line is exactly what a SUCCESSFUL write also produces. Only a count
  # can tell them apart.
  defp audit_count, do: Repo.aggregate(AuditEvent, :count)

  # Rows attributable to `user` on ANY team. For a team-less user this is the
  # platform-level question the console cannot answer, and unlike the bare
  # global count it is immune to rows this test did not create.
  defp audit_count_for(user),
    do: Repo.aggregate(from(e in AuditEvent, where: e.actor_user_id == ^user.id), :count)

  ## Request helpers

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp call_raw(method, path, raw_body, headers) do
    conn = conn(method, path, raw_body) |> put_req_header("content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp actions(team), do: team |> Accounts.list_audit_events() |> Enum.map(& &1.action)

  ## GET /v1/audit — ADMIN-gated read

  describe "GET /v1/audit" do
    test "401 without a bearer token" do
      conn = call(:get, "/v1/audit")
      assert conn.status == 401
    end

    test "200 with an empty list for a fresh admin's team" do
      {_u, _t, token} = logged_in()
      conn = call(:get, "/v1/audit", nil, token)
      assert conn.status == 200
      assert json_body(conn) == %{"events" => []}
    end

    test "a plain MEMBER is 403 (RBAC: the trail is owner/admin-only)" do
      {_owner, team, _owner_token} = logged_in()
      {_member, member_token} = member_of(team, "member")

      conn = call(:get, "/v1/audit", nil, member_token)
      assert conn.status == 403
    end

    test "an ADMIN member gets the trail" do
      {_owner, team, _owner_token} = logged_in()
      {_admin, admin_token} = member_of(team, "admin")

      {:ok, _} =
        Accounts.record_audit(%{team_id: team.id, action: "site.created", target_id: "s-1"})

      conn = call(:get, "/v1/audit", nil, admin_token)
      assert conn.status == 200
      assert %{"events" => [ev]} = json_body(conn)
      assert ev["action"] == "site.created"
    end

    test "returns rows after an audited mutation, newest first, with actor" do
      {user, team, token} = logged_in()

      {:ok, _} =
        Accounts.record_audit(%{
          team_id: team.id,
          actor_user_id: user.id,
          action: "site.created",
          target_type: "site",
          target_id: "s-1"
        })

      conn = call(:get, "/v1/audit", nil, token)
      assert conn.status == 200
      assert %{"events" => [ev]} = json_body(conn)
      assert ev["action"] == "site.created"
      assert ev["actor"]["email"] == user.email
      assert ev["target_id"] == "s-1"
    end

    test "?limit and ?before paginate" do
      {_u, team, token} = logged_in()

      for _ <- 1..3 do
        {:ok, _} = Accounts.record_audit(%{team_id: team.id, action: "site.created"})
      end

      conn = call(:get, "/v1/audit?limit=2", nil, token)
      assert %{"events" => first_page} = json_body(conn)
      assert length(first_page) == 2

      cursor = List.last(first_page)["inserted_at"]
      conn2 = call(:get, "/v1/audit?limit=2&before=" <> URI.encode_www_form(cursor), nil, token)
      assert %{"events" => second_page} = json_body(conn2)
      assert length(second_page) == 1
    end

    test "?actor_user_id narrows the trail to one member's events" do
      {owner, team, token} = logged_in()
      {other, _other_token} = member_of(team, "admin")

      {:ok, _} =
        Accounts.record_audit(%{
          team_id: team.id,
          actor_user_id: owner.id,
          action: "site.created"
        })

      {:ok, _} =
        Accounts.record_audit(%{
          team_id: team.id,
          actor_user_id: other.id,
          action: "site.deleted"
        })

      # A system/webhook event carries a NIL actor and must never be swept in.
      {:ok, _} = Accounts.record_audit(%{team_id: team.id, action: "barkpark.deleted"})

      conn = call(:get, "/v1/audit?actor_user_id=" <> owner.id, nil, token)
      assert conn.status == 200
      assert %{"events" => [ev]} = json_body(conn)
      assert ev["action"] == "site.created"
      assert ev["actor"]["email"] == owner.email
    end

    test "a non-uuid ?actor_user_id is a no-op filter, never a 500" do
      {_u, team, token} = logged_in()
      {:ok, _} = Accounts.record_audit(%{team_id: team.id, action: "site.created"})

      # A raw binary in a :binary_id comparison would raise Ecto.Query.CastError;
      # the cast guard turns it into "no filter" instead.
      conn = call(:get, "/v1/audit?actor_user_id=not-a-uuid", nil, token)
      assert conn.status == 200
      assert %{"events" => [_]} = json_body(conn)
    end

    test "?action_prefix narrows to one noun of the action vocabulary" do
      {_u, team, token} = logged_in()

      for action <- ~w(webhook.created webhook.rotated site.created) do
        {:ok, _} = Accounts.record_audit(%{team_id: team.id, action: action})
      end

      conn = call(:get, "/v1/audit?action_prefix=webhook", nil, token)
      assert conn.status == 200
      assert %{"events" => events} = json_body(conn)
      assert length(events) == 2
      assert Enum.all?(events, &String.starts_with?(&1["action"], "webhook."))
    end

    test "?action_prefix treats LIKE metacharacters as literals (no wildcard widening)" do
      {_u, team, token} = logged_in()

      for action <- ~w(webhook.created site.created) do
        {:ok, _} = Accounts.record_audit(%{team_id: team.id, action: action})
      end

      # Unescaped, `%` would match everything and `_` would match any single
      # character (`webhoo_` would sweep in `webhook.*`). Escaped, both are
      # literals that match nothing in the closed vocabulary.
      for probe <- ["%", "webhoo_"] do
        conn = call(:get, "/v1/audit?action_prefix=" <> URI.encode_www_form(probe), nil, token)
        assert conn.status == 200
        assert json_body(conn) == %{"events" => []}, "prefix #{probe} widened its own match"
      end

      # `_` is a LEGITIMATE literal in the vocabulary and must still match.
      {:ok, _} =
        Accounts.record_audit(%{team_id: team.id, action: "notifications.channels_changed"})

      conn = call(:get, "/v1/audit?action_prefix=notifications.channels_ch", nil, token)
      assert %{"events" => [ev]} = json_body(conn)
      assert ev["action"] == "notifications.channels_changed"
    end

    test "the filters compose, and empty filter values are ignored" do
      {owner, team, token} = logged_in()

      for action <- ~w(webhook.created webhook.rotated) do
        {:ok, _} =
          Accounts.record_audit(%{team_id: team.id, actor_user_id: owner.id, action: action})
      end

      {:ok, _} = Accounts.record_audit(%{team_id: team.id, action: "webhook.deleted"})

      conn =
        call(
          :get,
          "/v1/audit?actor_user_id=#{owner.id}&action_prefix=webhook.rot",
          nil,
          token
        )

      assert %{"events" => [ev]} = json_body(conn)
      assert ev["action"] == "webhook.rotated"

      # Empty values must not degenerate into "match nothing".
      conn2 = call(:get, "/v1/audit?actor_user_id=&action_prefix=", nil, token)
      assert %{"events" => all} = json_body(conn2)
      assert length(all) == 3
    end

    test "an admin in team A never sees team B's events" do
      {_ua, _ta, token_a} = logged_in()
      team_b = team_fixture()
      {:ok, _} = Accounts.record_audit(%{team_id: team_b.id, action: "barkpark.deleted"})

      conn = call(:get, "/v1/audit", nil, token_a)
      assert json_body(conn) == %{"events" => []}
    end
  end

  ## DELETE /v1/barkparks/:id

  describe "DELETE /v1/barkparks/:id audits the removal" do
    test "a non-live box delete writes exactly one barkpark.deleted event" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{name: "Doomed"})

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)
      assert conn.status == 200

      assert [ev] = Accounts.list_audit_events(team)
      assert ev.action == "barkpark.deleted"
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => "Doomed"}
    end

    # cch-w57 — THIS TEST USED TO PIN THE DEFECT, AND IT IS INVERTED, NOT DELETED.
    #
    # It shipped titled "a live box (deprovision path) writes NO barkpark.deleted
    # event" and its last line asserted an empty trail. That was a true sentence
    # about a broken lane, written down as an EXPECTATION — the live deprovision
    # is the only path a box that actually RAN can take, so the console's
    # append-only audit list recorded the removal of every box that never ran and
    # was silent about every box that did.
    #
    # Inverting keeps the half of the old assertion that was always right (at the
    # 202 instant nothing has been destroyed, so an audit row claiming a removal
    # would be a lie) and moves the trail assertion one step later, to where the
    # row actually dies. Deleting the test outright would have thrown that half
    # away and left the ordering unpinned.
    test "a live box is audited when the deprovision LANDS, not when it is requested" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{name: "Live", host: "10.0.0.1"})
      slug = "shop-#{System.unique_integer([:positive])}"
      {:ok, site} = Registry.create_site(bp, %{name: "Shop", slug: slug})

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)
      assert conn.status == 202

      # Still true, and the reason it is true has not changed: the box is up, the
      # row is here, and the worker has not been anywhere yet.
      assert Accounts.list_audit_events(team) == []

      # The worker's two seams are ordinary public Elixir — the Go process is a
      # caller, not a prerequisite — so the lane runs to completion in-process.
      claim_token = "probe-#{System.unique_integer([:positive])}"
      assert {job, claimed} = Registry.claim_next_deprovision_job(claim_token)
      assert claimed.id == bp.id
      assert {:ok, :deleted} = Registry.succeed_deprovision_job(job.id, claim_token: claim_token)
      assert Repo.get(Barkpark, bp.id) == nil

      assert [ev] = Accounts.list_audit_events(team)
      assert ev.action == "barkpark.deleted"
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id

      # NIL ON PURPOSE. The row is deleted by the deprovision worker, minutes to
      # hours after the admin pressed Remove, and provision_jobs carries no actor
      # column to relay them through. The register's declared shape for a
      # system-driven fact is a nil actor, not a guessed one.
      assert ev.actor_user_id == nil
      assert ev.metadata["name"] == "Live"
      assert ev.metadata["via"] == "deprovision"

      # The cascade's victims are NAMED by the row that outlives them: the site
      # dies with the box and nothing else in this product records that it did.
      assert ev.metadata["sites"] == [site.slug]
    end

    # cch-w57 — the ATOMICITY arm. The audit insert is REFUSED at the database,
    # inside the same transaction as the delete, and the box must be standing
    # afterwards. Without the rollback the register would be back to recording
    # fewer removals than happened — which is the exact defect, just rarer.
    #
    # The refusal is a real CHECK constraint rather than a mocked writer: the
    # claim under test is "one transaction", and only the database can answer it.
    # This module is `async: false`, so the ACCESS EXCLUSIVE lock the ALTER takes
    # is never held while another test is running, and the sandbox transaction
    # drops the constraint when the test ends.
    test "the audit row and the delete are ONE transaction — a refused insert leaves the box up" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{name: "Live", host: "10.0.0.1"})

      assert call(:delete, "/v1/barkparks/#{bp.id}", nil, token).status == 202

      claim_token = "probe-#{System.unique_integer([:positive])}"
      assert {job, _} = Registry.claim_next_deprovision_job(claim_token)

      Repo.query!(
        "ALTER TABLE audit_events ADD CONSTRAINT tmp_refuse_bp_deleted " <>
          "CHECK (action <> 'barkpark.deleted')"
      )

      assert_raise Ecto.ConstraintError, fn ->
        Registry.succeed_deprovision_job(job.id, claim_token: claim_token)
      end

      Repo.query!("ALTER TABLE audit_events DROP CONSTRAINT tmp_refuse_bp_deleted")

      # THE POINT: the delete went back. A box the control plane still bills for
      # is better than a removal nobody can prove happened.
      assert %Barkpark{host: "10.0.0.1"} = Repo.get(Barkpark, bp.id)
      assert Accounts.list_audit_events(team) == []

      # NON-VACUITY: with the refusal lifted the very same call succeeds and
      # writes, so the assertions above failed on the constraint and not on some
      # unrelated breakage in the lane.
      assert {:ok, :deleted} = Registry.succeed_deprovision_job(job.id, claim_token: claim_token)
      assert [%AuditEvent{action: "barkpark.deleted"}] = Accounts.list_audit_events(team)
    end
  end

  ## POST /v1/go-live — recorded post-commit (register_managed_barkpark retries
  ## incompatibly with an enclosing txn), so the audit is best-effort here.

  describe "POST /v1/go-live audits the launch" do
    test "an entitled launch writes a barkpark.go_live event for the created row" do
      {user, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/go-live", %{name: "Prod", plan: "supporter"}, token)
      assert conn.status == 201
      bp_id = json_body(conn)["barkpark"]["id"]

      assert [ev] =
               Enum.filter(Accounts.list_audit_events(team), &(&1.action == "barkpark.go_live"))

      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp_id
      assert ev.metadata["name"] == "Prod"
    end
  end

  ## Member / invitation seams

  describe "member + invitation seams" do
    test "POST invitations writes member.invited; a duplicate writes none" do
      {_owner, team, token} = logged_in()

      conn =
        call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{email: "new@x.io", role: "member"},
          token
        )

      assert conn.status == 201
      assert [ev] = Accounts.list_audit_events(team)
      assert ev.action == "member.invited"
      assert ev.target_type == "invitation"
      assert ev.metadata["email"] == "new@x.io"

      # A second live invite to the same email 409s — and stamps NO new row.
      dup =
        call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{email: "new@x.io", role: "member"},
          token
        )

      assert dup.status == 409
      assert actions(team) == ["member.invited"]
    end

    test "DELETE invitation writes invitation.revoked" do
      {owner, team, token} = logged_in()
      {:ok, %{invitation: inv}} = Accounts.invite_member(team, "gone@x.io", "member", owner)

      conn = call(:delete, "/v1/teams/#{team.id}/invitations/#{inv.id}", nil, token)
      assert conn.status == 200

      assert Enum.any?(Accounts.list_audit_events(team), fn e ->
               e.action == "invitation.revoked" and e.target_id == inv.id
             end)
    end

    test "POST /v1/invitations/accept writes invitation.accepted under the team" do
      {owner, team, _owner_token} = logged_in()
      invitee = user_fixture(%{email: "invitee-#{System.unique_integer([:positive])}@x.io"})
      {:ok, %{token: raw}} = Accounts.invite_member(team, invitee.email, "member", owner)
      {:ok, invitee_token} = Accounts.create_user_session_token(invitee)

      conn = call(:post, "/v1/invitations/accept", %{token: raw}, invitee_token)
      assert conn.status == 200

      assert [ev] =
               Accounts.list_audit_events(team)
               |> Enum.filter(&(&1.action == "invitation.accepted"))

      assert ev.actor_user_id == invitee.id
      assert ev.team_id == team.id
    end

    test "PATCH member role writes member.role_changed; an invalid role writes none" do
      {_owner, team, token} = logged_in()
      {target, _} = member_of(team, "member")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{target.id}", %{role: "admin"}, token)

      assert conn.status == 200

      assert [ev] =
               Enum.filter(
                 Accounts.list_audit_events(team),
                 &(&1.action == "member.role_changed")
               )

      assert ev.target_id == target.id
      assert ev.metadata["new_role"] == "admin"

      # An invalid role 422s and stamps nothing new.
      before = length(Accounts.list_audit_events(team))
      bad = call(:patch, "/v1/teams/#{team.id}/members/#{target.id}", %{role: "wizard"}, token)
      assert bad.status == 422
      assert length(Accounts.list_audit_events(team)) == before
    end

    test "DELETE member writes member.removed" do
      {_owner, team, token} = logged_in()
      {target, _} = member_of(team, "member")

      conn = call(:delete, "/v1/teams/#{team.id}/members/#{target.id}", nil, token)
      assert conn.status == 200

      assert [ev] =
               Enum.filter(Accounts.list_audit_events(team), &(&1.action == "member.removed"))

      assert ev.target_id == target.id
    end
  end

  ## Token seams

  describe "token seams" do
    test "POST /v1/tokens writes token.minted and still returns the plaintext once" do
      {_owner, _team, token} = logged_in()

      conn = call(:post, "/v1/tokens", %{name: "ci-bot", abilities: ["read"]}, token)
      assert conn.status == 201
      assert is_binary(json_body(conn)["token"])

      user = Accounts.verify_user_session_token(token)
      team = Accounts.primary_team(user)
      assert [ev] = Enum.filter(Accounts.list_audit_events(team), &(&1.action == "token.minted"))
      assert ev.metadata["name"] == "ci-bot"
    end

    test "a forbidden mint (member minting root) writes NO token.minted row" do
      {_owner, team, _owner_token} = logged_in()
      {_member, member_token} = member_of(team, "member")

      conn = call(:post, "/v1/tokens", %{name: "escalate", abilities: ["root"]}, member_token)
      assert conn.status == 403
      assert Enum.filter(Accounts.list_audit_events(team), &(&1.action == "token.minted")) == []
    end

    test "DELETE /v1/tokens/:id writes token.revoked" do
      {_owner, team, token} = logged_in()
      mint = call(:post, "/v1/tokens", %{name: "revoke-me", abilities: ["read"]}, token)
      pat_id = json_body(mint)["pat"]["id"]

      conn = call(:delete, "/v1/tokens/#{pat_id}", nil, token)
      assert conn.status == 200

      assert [ev] = Enum.filter(Accounts.list_audit_events(team), &(&1.action == "token.revoked"))
      assert ev.target_id == pat_id
    end
  end

  ## Billing cancel seam

  describe "POST /v1/billing/cancel audits the cancel" do
    test "a password-confirmed cancel writes subscription.canceled and persists" do
      {_owner, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/billing/cancel", %{password: @password}, token)
      assert conn.status == 200

      assert [ev] =
               Enum.filter(
                 Accounts.list_audit_events(team),
                 &(&1.action == "subscription.canceled")
               )

      assert ev.target_type == "subscription"
    end

    test "a wrong-password cancel 401s and writes NO row" do
      {_owner, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/billing/cancel", %{password: "not-it"}, token)
      assert conn.status == 401
      assert Accounts.list_audit_events(team) == []
    end
  end

  ## Stripe webhook — best-effort, post-commit, system actor

  describe "POST /v1/billing/webhook audits with a null (system) actor" do
    test "a valid activation writes subscription.activated (nil actor) AND persists the sub" do
      {_u, team, _token} = logged_in()

      raw =
        Jason.encode!(%{
          "id" => "evt_#{System.unique_integer([:positive])}",
          "type" => "checkout.session.completed",
          "data" => %{
            "object" => %{"metadata" => %{"team_id" => team.id, "plan" => "supporter"}}
          }
        })

      conn =
        call_raw(:post, "/v1/billing/webhook", raw, [
          {"stripe-signature", StubGateway.test_signature()}
        ])

      assert conn.status == 200

      # The subscription persisted (the audit is post-commit + best-effort, so it
      # can never roll the subscription back).
      sub = Billing.active_subscription(team)
      assert sub != nil and sub.status == "active"

      assert [ev] =
               Enum.filter(
                 Accounts.list_audit_events(team),
                 &(&1.action == "subscription.activated")
               )

      assert is_nil(ev.actor_user_id)
      assert ev.metadata["source"] == "stripe_webhook"
      assert ev.metadata["plan"] == "supporter"
    end
  end

  ## Instance-lifecycle levers (OC24) — every headline console button leaves a
  ## trail. The seven async triggers (retry / verify / studio-link /
  ## self-update / rollback / vercel-deploy / resurrect) record post-commit on
  ## the SUCCESS branch only; the sync trio (site-url / autoupdate / domain)
  ## is transactional — a failed action writes NO row (asserted below). No
  ## detail map ever carries a token, a ticket, or a URL that embeds one.

  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"
  @bundle "s3://barkpark-archives/shop-2026-07-09.tar.zst"

  # All-green fake for the :verify_http_client seam — every probe answers a
  # bare 200, so Verify.run/1 yields {:ok, result} with reachable: true. The
  # app-env swap is bleed-free under async: the seam's only other user
  # (verify_test.exs) is async: false, so it never runs concurrently with
  # this file, and swap_verify_client!/0 restores on exit.
  defmodule FakeVerifyHttp do
    def request(_req), do: {:ok, %{status: 200, body: "", headers: []}}
  end

  defp swap_verify_client! do
    prev = Application.get_env(:barkpark_cloud, :verify_http_client)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:barkpark_cloud, :verify_http_client)
        mod -> Application.put_env(:barkpark_cloud, :verify_http_client, mod)
      end
    end)

    Application.put_env(:barkpark_cloud, :verify_http_client, FakeVerifyHttp)
  end

  # Wire the Vercel platform token + in-memory Fake client (vercel_test's
  # idiom — restored on exit).
  defp configure_vercel! do
    base = Application.get_env(:barkpark_cloud, Vercel, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, Vercel, base) end)

    Application.put_env(
      :barkpark_cloud,
      Vercel,
      Keyword.merge(base, client: Vercel.Fake, token: "vt_test_token")
    )
  end

  # A LIVE instance: url + host + encrypted admin token stored (what the
  # provision-succeed path writes) — the shape the lifecycle relays need.
  defp live_barkpark(team) do
    team
    |> barkpark_fixture(%{})
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  # …plus the dwb-4/5 bootstrap outputs site-url needs to find the
  # revalidation webhook on the instance.
  defp bootstrapped_barkpark(team) do
    team
    |> live_barkpark()
    |> Ecto.Changeset.change(
      template: "blog-starter",
      bootstrap_workspace: "acme",
      bootstrap_project: "default",
      bootstrap_dataset: "production",
      bootstrap_read_token_encrypted: Vault.encrypt("bp_read_secret")
    )
    |> Repo.update!()
  end

  # A vercel-deployable instance (vercel_test's fixture shape): deployable
  # template + bootstrap env stored. No live box needed — deploy_for reads
  # stored state only.
  defp vercel_ready_barkpark(team) do
    env = %{
      "BARKPARK_API_URL" => "https://acme.barkpark.cloud/w/acme/p/default",
      "BARKPARK_TOKEN" => "bp_read_supersecret",
      "BARKPARK_WORKSPACE" => "acme",
      "BARKPARK_PROJECT" => "default",
      "BARKPARK_DATASET" => "production",
      "BARKPARK_WEBHOOK_SECRET" => "whsec_test"
    }

    team
    |> barkpark_fixture(%{})
    |> Ecto.Changeset.change(
      template: "blog-starter",
      bootstrap_workspace: "acme",
      bootstrap_project: "default",
      bootstrap_dataset: "production",
      bootstrap_read_token_encrypted: Vault.encrypt("bp_read_supersecret"),
      bootstrap_env_encrypted: Vault.encrypt(Jason.encode!(env))
    )
    |> Repo.update!()
  end

  # The instance webhook-list response carrying the bootstrap-owned endpoint
  # (what wire_site_url LISTs before it PUTs).
  defp webhook_list_response do
    {:ok,
     %{
       status: 200,
       body:
         Jason.encode!(%{
           webhooks: [%{id: "wh_bootstrap_1", name: "bootstrap-revalidation", active: false}]
         })
     }}
  end

  defp find_events(team, action),
    do: team |> Accounts.list_audit_events() |> Enum.filter(&(&1.action == action))

  describe "lifecycle async triggers audit post-commit on the success branch" do
    test "POST retry writes barkpark.retry_requested; a not-retryable 409 writes none" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert conn.status == 201

      assert [ev] = find_events(team, "barkpark.retry_requested")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name}

      # The retry's own fresh job is now PENDING → a second retry 409s and
      # stamps nothing new (success branch only).
      dup = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert dup.status == 409
      assert length(find_events(team, "barkpark.retry_requested")) == 1
    end

    test "POST verify writes barkpark.verify_requested with the headline verdict, never a token" do
      swap_verify_client!()
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", nil, token)
      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.verify_requested")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name, "reachable" => true}
      refute inspect(ev.metadata) =~ @instance_admin_token
    end

    test "POST studio-link writes barkpark.studio_link_minted — the mint, never the URL/ticket" do
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_audit-ticket-1","expires_in":60})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", nil, token)
      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.studio_link_minted")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name}
      refute inspect(ev.metadata) =~ "bplt_"
      refute inspect(ev.metadata) =~ @instance_admin_token
    end

    test "a failed mint (transport error → 502) writes NO studio_link row" do
      {_user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", nil, token)
      assert conn.status == 502
      assert find_events(team, "barkpark.studio_link_minted") == []
    end

    test "POST self-update writes barkpark.self_update_triggered with the force flag" do
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 202, body: ~s({"ok":true,"status":"started"})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", nil, token)
      assert conn.status == 202

      assert [ev] = find_events(team, "barkpark.self_update_triggered")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name, "force" => false}
    end

    test "an instance 409 (already_running) writes NO self_update row" do
      {_user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 409, body: ~s({"error":{"code":"already_running"}})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", nil, token)
      assert conn.status == 409
      assert find_events(team, "barkpark.self_update_triggered") == []
    end

    test "POST rollback writes barkpark.rollback_triggered with the REPORTED sha + pin" do
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 202, body: ~s({"status":"started","target_sha":"abc123def456"})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/rollback", nil, token)
      assert conn.status == 202

      assert [ev] = find_events(team, "barkpark.rollback_triggered")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id

      assert ev.metadata == %{
               "name" => bp.name,
               "target_sha" => "abc123def456",
               "pinned_release" => "abc123def456"
             }
    end

    test "an instance 409 (no_previous_slot) writes NO rollback row" do
      {_user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 409, body: ~s({"error":{"code":"no_previous_slot"}})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/rollback", nil, token)
      assert conn.status == 409
      assert find_events(team, "barkpark.rollback_triggered") == []
    end

    test "POST vercel-deploy writes barkpark.vercel_deploy_triggered — never the claim state" do
      configure_vercel!()
      {user, team, token} = logged_in()
      bp = vercel_ready_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 201

      assert [ev] = find_events(team, "barkpark.vercel_deploy_triggered")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id
      # The metadata is EXACTLY the instance name — no claim code / claim_url
      # (a bearer-shaped capability link) can ride along.
      assert ev.metadata == %{"name" => bp.name}
    end

    test "a bootstrap-less deploy (409) writes NO vercel_deploy row" do
      configure_vercel!()
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 409
      assert find_events(team, "barkpark.vercel_deploy_triggered") == []
    end

    test "POST /v1/resurrect writes barkpark.resurrected for the fresh row with the resolved bundle" do
      {user, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn =
        call(:post, "/v1/resurrect", %{name: "Shop", bundle_ref: @bundle}, token)

      assert conn.status == 202
      new_id = json_body(conn)["id"]

      assert [ev] = find_events(team, "barkpark.resurrected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == new_id
      assert ev.metadata == %{"name" => "Shop", "bundle_ref" => @bundle}
    end
  end

  describe "lifecycle sync trio audits transactionally — no row on failure" do
    test "POST site-url writes barkpark.site_url_set with the wired URLs, never the admin token" do
      {user, team, token} = logged_in()
      bp = bootstrapped_barkpark(team)

      StudioLinkFakeHttpClient.program([
        webhook_list_response(),
        {:ok, %{status: 200, body: ~s({"webhook":{"id":"wh_bootstrap_1","active":true}})}}
      ])

      site = "https://acme-blog.vercel.app"
      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: site}, token)
      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.site_url_set")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id

      assert ev.metadata == %{
               "site_url" => site,
               "webhook_url" => site <> "/api/barkpark/webhook"
             }

      refute inspect(ev.metadata) =~ @instance_admin_token
    end

    test "a failed wire (transport error → 502) writes NO site_url row" do
      {_user, team, token} = logged_in()
      bp = bootstrapped_barkpark(team)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: "https://x.vercel.app"}, token)

      assert conn.status == 502
      assert find_events(team, "barkpark.site_url_set") == []
    end

    test "a non-http url (422) writes NO site_url row" do
      {_user, team, token} = logged_in()
      bp = bootstrapped_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: "ftp://nope"}, token)
      assert conn.status == 422
      assert find_events(team, "barkpark.site_url_set") == []
    end

    test "PATCH autoupdate writes barkpark.autoupdate_changed with the PERSISTED policy" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn =
        call(:patch, "/v1/barkparks/#{bp.id}/autoupdate", %{autoupdate_enabled: false}, token)

      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.autoupdate_changed")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id

      assert ev.metadata == %{
               "enabled" => false,
               "paused" => false,
               "pinned_release" => nil
             }
    end

    test "an invalid autoupdate PATCH (422) writes NO row" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn =
        call(:patch, "/v1/barkparks/#{bp.id}/autoupdate", %{autoupdate_enabled: "nope"}, token)

      assert conn.status == 422
      assert find_events(team, "barkpark.autoupdate_changed") == []
    end

    test "POST domain writes barkpark.domain_attached with the persisted host" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})
      host = "audited-#{System.unique_integer([:positive])}.barkpark.cloud"

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: host}, token)
      assert conn.status == 202

      assert [ev] = find_events(team, "barkpark.domain_attached")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"custom_host" => host}
    end

    test "an invalid domain (422) writes NO domain row" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: "not a host"}, token)
      assert conn.status == 422
      assert find_events(team, "barkpark.domain_attached") == []
    end

    test "a taken host (409) writes NO domain row for the loser" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})
      other = barkpark_fixture(team, %{})
      host = "claimed-#{System.unique_integer([:positive])}.barkpark.cloud"

      assert call(:post, "/v1/barkparks/#{other.id}/domain", %{domain: host}, token).status ==
               202

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: host}, token)
      assert conn.status == 409

      # Exactly ONE row — the winner's; the refused attach stamped nothing.
      assert [ev] = find_events(team, "barkpark.domain_attached")
      assert ev.target_id == other.id
    end
  end

  ## OC24 cluster A — credential / settings seams
  ##
  ## The secrets law is verified structurally, not just by shape: every credential
  ## route asserts the plaintext material (token / secret / value) is absent from
  ## the audit row's metadata.

  describe "provider connect seam" do
    test "POST /v1/providers writes provider.connected — kind+label only, NEVER the token" do
      {user, team, token} = logged_in()

      conn =
        call(
          :post,
          "/v1/providers",
          %{kind: "hetzner", token: "secret-hz-token", label: "main"},
          token
        )

      assert conn.status == 201

      assert [ev] = events(team, "provider.connected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "provider"
      assert ev.metadata["kind"] == "hetzner"
      assert ev.metadata["label"] == "main"
      # The plaintext credential never reaches the audit row.
      refute Enum.any?(Map.values(ev.metadata), &(&1 == "secret-hz-token"))
      refute Map.has_key?(ev.metadata, "token")
      refute Map.has_key?(ev.metadata, "credential")
      # A first connect is NOT a rotation, and says so.
      assert ev.metadata["rotated"] == false
    end

    test "a re-connect stamps rotated: true — METADATA, never a second action string" do
      {_user, team, token} = logged_in()

      assert call(:post, "/v1/providers", %{kind: "hetzner", token: "hz-first"}, token).status ==
               201

      assert call(
               :post,
               "/v1/providers",
               %{kind: "hetzner", token: "hz-rotated", label: "main"},
               token
             ).status == 201

      # Two events, ONE action: the closed noun.verb vocabulary that
      # list_audit_events' :action_prefix filter reads is not widened, so the
      # rotation is legible without a `provider.rotated` action existing.
      assert [newer, older] = events(team, "provider.connected")
      assert older.metadata["rotated"] == false
      assert newer.metadata["rotated"] == true
      assert newer.metadata["kind"] == "hetzner"
      assert newer.metadata["label"] == "main"
      # …and the rotation reuses the ONE row, so both events point at it.
      assert newer.target_id == older.target_id
      refute Enum.any?(Map.values(newer.metadata), &(&1 == "hz-rotated"))
    end
  end

  describe "github credential seams" do
    test "POST /v1/github/installations writes github.installation_connected (login only)" do
      configure_github()
      {user, team, token} = logged_in()

      conn = call(:post, "/v1/github/installations", %{installation_id: "4242"}, token)
      assert conn.status == 201

      assert [ev] = events(team, "github.installation_connected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "github_installation"
      assert is_binary(ev.metadata["account_login"])
      # The installation handle is stored encrypted, never in the audit row.
      refute Map.has_key?(ev.metadata, "installation_id")
    end

    test "DELETE /v1/github/installation writes github.installation_disconnected" do
      configure_github()
      {user, team, token} = logged_in()
      {:ok, _} = GitHub.record_installation(team, "4242")

      conn = call(:delete, "/v1/github/installation", nil, token)
      assert conn.status == 200

      assert [ev] = events(team, "github.installation_disconnected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "github_installation"
    end

    test "a disconnect with NO installation 404s and writes NO row" do
      configure_github()
      {_user, team, token} = logged_in()

      conn = call(:delete, "/v1/github/installation", nil, token)
      assert conn.status == 404
      assert events(team, "github.installation_disconnected") == []
    end

    test "POST /v1/github/repos writes github.repo_pushed (repo + template + count)" do
      configure_github()
      {user, team, token} = logged_in()
      {:ok, _} = GitHub.record_installation(team, "4242")
      Fake.reset()

      conn =
        call(
          :post,
          "/v1/github/repos",
          %{template: "blog-starter", name: "my-blog", private: true},
          token
        )

      assert conn.status == 201

      assert [ev] = events(team, "github.repo_pushed")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "github_repo"
      assert ev.metadata["repo_full_name"] == "octo-4242/my-blog"
      assert ev.metadata["template"] == "blog-starter"
      assert ev.metadata["pushed"] > 0
    end
  end

  describe "notifications settings seams" do
    test "PUT /v1/notifications/settings writes notifications.settings_changed (field NAMES, no secret)" do
      {user, team, token} = logged_in()

      conn =
        call(
          :put,
          "/v1/notifications/settings",
          %{"alerts_enabled" => true, "smtp_password" => "hunter2"},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "notifications.settings_changed")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "notification_settings"
      # The submitted field NAMES are recorded; the secret VALUE is not.
      assert "smtp_password" in ev.metadata["fields"]
      refute Enum.any?(List.flatten(Map.values(ev.metadata)), &(&1 == "hunter2"))
    end

    test "PUT /v1/notifications/channels writes notifications.channels_changed (type only, no creds)" do
      {_user, team, token} = logged_in()

      conn =
        call(
          :put,
          "/v1/notifications/channels",
          %{
            "type" => "slack",
            "enabled" => true,
            "credentials" => %{"url" => "https://hooks.slack.com/services/secret-hook"}
          },
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "notifications.channels_changed")
      assert ev.metadata["type"] == "slack"
      assert ev.metadata["enabled"] == true
      # The channel credentials (chat webhook URL) never reach the audit row.
      refute Map.has_key?(ev.metadata, "credentials")

      refute Enum.any?(
               Map.values(ev.metadata),
               &(&1 == "https://hooks.slack.com/services/secret-hook")
             )
    end

    test "PUT /v1/notifications/events writes notifications.events_changed" do
      {_user, team, token} = logged_in()

      conn =
        call(
          :put,
          "/v1/notifications/events",
          %{"event" => "provision_succeeded", "channels" => ["slack"]},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "notifications.events_changed")
      assert ev.metadata["event"] == "provision_succeeded"
      assert ev.metadata["channels"] == ["slack"]
    end
  end

  ## OC24 cluster B — Sites consistency (create + promote already audit)

  describe "site sibling seams" do
    test "POST /v1/sites/:id/deploy writes site.deploy_requested for a freshly minted row" do
      {user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{git_ref: "abc123", artifact_url: "file:///tmp/app.tgz"},
          token
        )

      assert conn.status == 201

      assert [ev] = events(team, "site.deploy_requested")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "deployment"
      assert ev.metadata["site_id"] == site.id
      assert ev.metadata["git_ref"] == "abc123"
      assert ev.metadata["has_artifact"] == true
    end

    # site-spawner W10: the site-scoped upload route is RETIRED, so
    # `site.artifact_uploaded` is a dead action — and that it was ALWAYS dead in
    # practice is the evidence that retiring it costs nothing. Prod's audit table
    # holds 244 rows across four weeks and ZERO with `target_type: "site"`, while
    # the deployment-scoped sibling's rows prove auditing fires; no human ever
    # called this route. Its only caller was `bp deploy`'s no-flag branch, whose
    # every insert was an orphan by construction.
    test "POST /v1/sites/:id/artifact is unrouted → 404 and NO audit is written" do
      {_user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        conn(:post, "/v1/sites/#{site.id}/artifact", "tarball-bytes")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(@opts)

      assert conn.status == 404
      assert events(team, "site.artifact_uploaded") == []
    end

    test "POST /v1/sites/:id/env writes site.env_changed — key names only, NEVER the values" do
      {user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/env",
          %{env: %{"DB_URL" => "postgres://secret", "API_KEY" => "sk-live"}},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "site.env_changed")
      assert ev.actor_user_id == user.id
      assert Enum.sort(ev.metadata["keys"]) == ["API_KEY", "DB_URL"]
      refute Enum.any?(List.flatten(Map.values(ev.metadata)), &(&1 == "sk-live"))
    end

    test "POST /v1/sites/:id/domains writes site.domain_added" do
      {_user, team, token} = logged_in()
      site = site_fixture(team)

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "shop.example.com"}, token)
      assert conn.status == 200

      assert [ev] = events(team, "site.domain_added")
      assert ev.metadata["domain"] == "shop.example.com"
    end

    # Transactional no-row proof for the Sites family: a cross-site domain
    # collision rolls the audit row back with the changeset.
    test "a domain collision 409s and writes NO site.domain_added row" do
      {_user, team, token} = logged_in()
      site_a = site_fixture(team)
      site_b = site_fixture(team)
      {:ok, _} = Registry.add_site_domain(site_a, "taken.example.com")

      conn = call(:post, "/v1/sites/#{site_b.id}/domains", %{domain: "taken.example.com"}, token)
      assert conn.status == 409
      assert events(team, "site.domain_added") == []
    end

    test "POST /v1/sites/:id/github writes site.github_connected — repo/branch, NEVER the secret" do
      {user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github",
          %{repo: "octo/app", branch: "main", webhook_secret: "whsec-plaintext"},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "site.github_connected")
      assert ev.actor_user_id == user.id
      assert ev.metadata["repo"] == "octo/app"
      assert ev.metadata["branch"] == "main"
      # The webhook secret never reaches the audit row.
      refute Enum.any?(Map.values(ev.metadata), &(&1 == "whsec-plaintext"))
      refute Map.has_key?(ev.metadata, "webhook_secret")
    end

    test "DELETE /v1/sites/:id/github writes site.github_disconnected" do
      {_user, team, token} = logged_in()
      site = site_fixture(team)
      {:ok, _} = Registry.set_site_github(site, "octo/app", "main", "whsec")

      conn = call(:delete, "/v1/sites/#{site.id}/github", nil, token)
      assert conn.status == 200

      assert [ev] = events(team, "site.github_disconnected")
      assert ev.metadata["repo"] == "octo/app"
    end
  end

  ## Account security — the 2FA pair (cch-w53-s3)
  ##
  ## Turning 2FA on/off is the most security-relevant act a PLAIN MEMBER can
  ## perform, and it is the only audited seam here that is NOT admin-gated on
  ## the write side. Both producers are post-commit best-effort by design: the
  ## account state has already changed, so nothing below may 500.

  # Enroll `user` and return the raw TOTP secret so a test can compute a code.
  defp enroll_two_factor(user) do
    {:ok, %{secret_base32: b32}} = Accounts.start_two_factor_enrollment(user)
    {:ok, secret} = Base.decode32(b32, padding: false)
    secret
  end

  describe "the two-factor pair writes to the team trail" do
    test "POST /v1/account/two-factor/confirm writes twofa.enabled" do
      {user, team, token} = logged_in()
      secret = enroll_two_factor(user)
      before_count = audit_count()

      conn =
        call(
          :post,
          "/v1/account/two-factor/confirm",
          %{code: totp_code_stable!(secret)},
          token
        )

      assert conn.status == 200

      # FAIL-OPEN ARM 2 (`record_audit` -> `{:error, cs}`) is invisible to a
      # team+action-scoped read of a DIFFERENT verb, so pin the global delta:
      # exactly one row entered the table, not zero and not two.
      assert audit_count() == before_count + 1
      assert audit_count_for(user) == 1

      assert [ev] = events(team, "twofa.enabled")
      assert ev.team_id == team.id
      assert ev.actor_user_id == user.id
      assert ev.target_type == "user"
      assert ev.target_id == user.id
      # Nothing about the secret or the recovery codes reaches the row.
      assert ev.metadata in [nil, %{}]
    end

    test "a WRONG code 422s and writes NO twofa.enabled row" do
      {user, team, token} = logged_in()
      _secret = enroll_two_factor(user)

      conn = call(:post, "/v1/account/two-factor/confirm", %{code: "000000"}, token)
      assert conn.status == 422
      assert events(team, "twofa.enabled") == []
    end

    test "a PLAIN MEMBER (not admin) can write the row — the write side is not RBAC-gated" do
      {_owner, team, _owner_token} = logged_in()
      {member, member_token} = member_of(team, "member")
      secret = enroll_two_factor(member)

      conn =
        call(
          :post,
          "/v1/account/two-factor/confirm",
          %{code: totp_code_stable!(secret)},
          member_token
        )

      assert conn.status == 200
      assert [ev] = events(team, "twofa.enabled")
      assert ev.actor_user_id == member.id
    end

    test "DELETE /v1/account/two-factor writes twofa.disabled" do
      {user, team, token} = logged_in()
      secret = enroll_two_factor(user)

      {:ok, _codes} =
        Accounts.confirm_two_factor(
          Accounts.get_user(user.id),
          totp_code_stable!(secret)
        )

      before_count = audit_count()
      conn = call(:delete, "/v1/account/two-factor", nil, token)
      assert conn.status == 200

      # Same witness for the disable verb: the row reached the table.
      assert audit_count() == before_count + 1

      assert [ev] = events(team, "twofa.disabled")
      assert ev.team_id == team.id
      assert ev.actor_user_id == user.id
      assert ev.target_id == user.id
    end

    test "DELETE when 2FA was never ON writes NO row — the route is idempotent, the trail is not" do
      {_user, team, token} = logged_in()

      conn = call(:delete, "/v1/account/two-factor", nil, token)
      assert conn.status == 200
      assert events(team, "twofa.disabled") == []
    end
  end

  # THE FAIL-CLOSED ARM. `Auth.require_user/2` assigns :current_team through
  # `Accounts.primary_team/1`, which is `List.first/1` and returns nil for a
  # user who belongs to no team — while `audit_events.team_id` is `null: false`.
  # An unguarded producer would raise there and make ENABLING 2FA return 500:
  # a security regression far worse than the missing row it was added to fix.
  describe "a team-less user still gets 2FA (the audit write is skipped, LOGGED, never fatal)" do
    setup do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)
      assert Accounts.primary_team(user) == nil
      %{user: user, token: token}
    end

    test "confirm answers 200 and logs the skip", %{user: user, token: token} do
      secret = enroll_two_factor(user)
      before_count = audit_count()

      {conn, log} =
        with_log(fn ->
          call(
            :post,
            "/v1/account/two-factor/confirm",
            %{code: totp_code_stable!(secret)},
            token
          )
        end)

      assert conn.status == 200
      assert %{"recovery_codes" => codes} = json_body(conn)
      assert length(codes) > 0
      # 2FA is genuinely ON — the missing audit row cost the user nothing.
      assert Accounts.two_factor_enabled?(Accounts.get_user(user.id))

      # FAIL-OPEN ARM 1 (`current_team` is nil). NO ROW IS WRITTEN ANYWHERE —
      # not to this user's (non-existent) team and not to any other. This is
      # the honest severity: the team trail is not FALSIFIED (the console says
      # "Who did what on your team", and a team-less user's 2FA change is not
      # an act on any team) — it is that NO platform-level record of the act
      # exists at all, and no surface would say so. Without these two lines the
      # block passes identically whether the row was written or skipped: the
      # 200, the recovery codes, the two_factor_enabled? flag and the SKIPPED
      # log are all produced on BOTH sides of the `case`.
      assert audit_count() == before_count
      assert audit_count_for(user) == 0

      # Skipped AND LOGGED, never silently discarded.
      assert log =~ "audit twofa.enabled SKIPPED"
      assert log =~ user.id
    end

    test "disable answers 200 and logs the skip", %{user: user, token: token} do
      secret = enroll_two_factor(user)

      {:ok, _} =
        Accounts.confirm_two_factor(
          Accounts.get_user(user.id),
          totp_code_stable!(secret)
        )

      before_count = audit_count()

      {conn, log} = with_log(fn -> call(:delete, "/v1/account/two-factor", nil, token) end)

      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true}
      refute Accounts.two_factor_enabled?(Accounts.get_user(user.id))

      # FAIL-OPEN ARM 1 again, on the disable verb. Same reasoning as the
      # enable arm above: 200 + SKIPPED log is what a WRITE would look like too.
      assert audit_count() == before_count
      assert audit_count_for(user) == 0

      assert log =~ "audit twofa.disabled SKIPPED"
    end
  end
end
