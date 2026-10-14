defmodule BarkparkCloud.DeviceAuthTeamBindingTest do
  @moduledoc """
  Cross-workspace approval (bp-login-ux-epic criterion 2). A device login may be
  bound to one team at start (`team_id`); an approver from a DIFFERENT team is
  refused (`:team_mismatch` / HTTP 403), nothing is stamped, and the request
  stays pending for a rightful approver. A member's approval mints THAT team —
  not the approver's primary one — and a membership revoked between approve and
  poll fails closed.
  """
  use BarkparkCloud.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.TeamMembership
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.DeviceAuth
  alias BarkparkCloud.DeviceAuth.RateLimiter
  alias BarkparkCloud.DeviceAuth.Request
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @router_opts Router.init([])

  setup do
    RateLimiter.reset()
    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "devteam-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp member_of(team) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, "member")
    user
  end

  defp row_for(user_code) do
    hash = UserToken.hash_token(String.replace(String.upcase(user_code), ~r/[^0-9A-Z]/, ""))
    Repo.one(from(r in Request, where: r.user_code_hash == ^hash))
  end

  describe "start/1 with a team" do
    test "stores the requested team on the pending row" do
      team = team_fixture()
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{team_id: team.id})
      assert row_for(uc).requested_team_id == team.id
    end

    test "a non-UUID team_id is refused, not silently unbound" do
      assert {:error, :invalid_team} = DeviceAuth.start(%{team_id: "not-a-uuid"})
      assert Repo.aggregate(Request, :count) == 0
    end

    test "an unknown team UUID is refused" do
      assert {:error, :invalid_team} = DeviceAuth.start(%{team_id: Ecto.UUID.generate()})
      assert Repo.aggregate(Request, :count) == 0
    end

    test "a blank team_id is an unbound request" do
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{team_id: ""})
      assert row_for(uc).requested_team_id == nil
    end
  end

  describe "approve/2 across teams" do
    test "an approver from a different team is refused and nothing is stamped" do
      team_a = team_fixture()
      outsider = member_of(team_fixture())
      {:ok, %{user_code: uc, device_code: dc}} = DeviceAuth.start(%{team_id: team_a.id})

      assert {:error, :team_mismatch} = DeviceAuth.approve(uc, outsider.id)

      row = row_for(uc)
      assert row.status == "pending"
      assert row.user_id == nil
      assert {:pending} = DeviceAuth.poll(dc)
    end

    test "an approver in no team at all is refused" do
      team_a = team_fixture()
      loner = user_fixture()
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{team_id: team_a.id})
      assert {:error, :team_mismatch} = DeviceAuth.approve(uc, loner.id)
    end

    test "after a refusal, a member of the requested team can still approve; the session is minted for THAT team" do
      team_a = team_fixture()
      outsider = member_of(team_fixture())

      # The member's PRIMARY (oldest) team is another one — the mint must still
      # answer with the requested team, not primary_team/1.
      member = member_of(team_fixture())
      {:ok, _} = Accounts.add_member(team_a, member, "member")
      refute Accounts.primary_team(member).id == team_a.id

      {:ok, %{user_code: uc, device_code: dc}} = DeviceAuth.start(%{team_id: team_a.id})
      assert {:error, :team_mismatch} = DeviceAuth.approve(uc, outsider.id)
      assert :ok = DeviceAuth.approve(uc, member.id)

      assert {:ok, token, minted_team} = DeviceAuth.poll(dc)
      assert minted_team.id == team_a.id
      assert Accounts.verify_user_session_token(token).id == member.id
    end

    test "an expired team-bound code answers expired_or_invalid, not team_mismatch" do
      team_a = team_fixture()
      outsider = member_of(team_fixture())
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{team_id: team_a.id})

      past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)
      Repo.update_all(Request, set: [expires_at: past])

      assert {:error, :expired_or_invalid} = DeviceAuth.approve(uc, outsider.id)
    end

    test "a membership revoked between approve and poll fails closed" do
      team_a = team_fixture()
      member = member_of(team_a)
      {:ok, %{user_code: uc, device_code: dc}} = DeviceAuth.start(%{team_id: team_a.id})
      assert :ok = DeviceAuth.approve(uc, member.id)

      Repo.delete_all(
        from(m in TeamMembership, where: m.team_id == ^team_a.id and m.user_id == ^member.id)
      )

      assert {:error, :expired_or_invalid} = DeviceAuth.poll(dc)
      # The row was consumed: no second chance to mint.
      assert {:error, :expired_or_invalid} = DeviceAuth.poll(dc)
    end
  end

  ## HTTP — the same contract through the real router.

  defp call(method, path, body, token \\ nil) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @router_opts)
  end

  defp jbody(conn), do: Jason.decode!(conn.resp_body)

  describe "HTTP: cross-team approval" do
    test "outsider gets 403 team_mismatch, CLI keeps waiting, member approves, poll returns the requested team" do
      team_a = team_fixture()
      outsider = member_of(team_fixture())
      member = member_of(team_a)
      {:ok, outsider_session} = Accounts.create_user_session_token(outsider)
      {:ok, member_session} = Accounts.create_user_session_token(member)

      start =
        call(:post, "/v1/auth/device/start", %{client_name: "bp on laptop", team_id: team_a.id})

      assert start.status == 200
      s = jbody(start)

      insp = call(:post, "/v1/auth/device/inspect", %{user_code: s["user_code"]}, member_session)
      assert insp.status == 200 and jbody(insp)["team_id"] == team_a.id

      refused =
        call(:post, "/v1/auth/device/approve", %{user_code: s["user_code"]}, outsider_session)

      assert refused.status == 403
      assert jbody(refused) == %{"error" => "team_mismatch"}

      poll1 = call(:post, "/v1/auth/device/poll", %{device_code: s["device_code"]})
      assert poll1.status == 200 and jbody(poll1) == %{"status" => "pending"}

      ok = call(:post, "/v1/auth/device/approve", %{user_code: s["user_code"]}, member_session)
      assert ok.status == 200

      poll2 = call(:post, "/v1/auth/device/poll", %{device_code: s["device_code"]})
      assert poll2.status == 200
      body = jbody(poll2)
      assert body["team_id"] == team_a.id
      assert Accounts.verify_user_session_token(body["token"]).id == member.id
    end

    # task-c9560d84f704705d: who is asking goes only to someone who could approve.
    test "inspect hides the requester's ip and user agent from a non-member of the bound team" do
      team_a = team_fixture()
      {:ok, outsider_session} = Accounts.create_user_session_token(member_of(team_fixture()))
      {:ok, member_session} = Accounts.create_user_session_token(member_of(team_a))

      s =
        jbody(
          call(:post, "/v1/auth/device/start", %{client_name: "bp on laptop", team_id: team_a.id})
        )

      outsider =
        call(:post, "/v1/auth/device/inspect", %{user_code: s["user_code"]}, outsider_session)

      assert outsider.status == 200
      seen = jbody(outsider)

      refute Map.has_key?(seen, "ip_address"),
             "a non-member saw the requester's ip: #{inspect(seen)}"

      refute Map.has_key?(seen, "user_agent"),
             "a non-member saw the requester's ua: #{inspect(seen)}"

      # The confirm screen still renders, so the Deny valve keeps working.
      assert seen["client_name"] == "bp on laptop" and seen["team_id"] == team_a.id

      member =
        jbody(
          call(:post, "/v1/auth/device/inspect", %{user_code: s["user_code"]}, member_session)
        )

      assert Map.has_key?(member, "ip_address") and Map.has_key?(member, "user_agent")
    end

    test "inspect of an unbound login shows who is asking to any signed-in user (control)" do
      {:ok, session} = Accounts.create_user_session_token(member_of(team_fixture()))
      s = jbody(call(:post, "/v1/auth/device/start", %{client_name: "bp"}))
      body = jbody(call(:post, "/v1/auth/device/inspect", %{user_code: s["user_code"]}, session))
      assert Map.has_key?(body, "ip_address") and Map.has_key?(body, "user_agent")
    end

    test "deny cannot take back an approved login before the CLI collects it" do
      team_a = team_fixture()
      {:ok, outsider_session} = Accounts.create_user_session_token(member_of(team_fixture()))
      member = member_of(team_a)
      {:ok, member_session} = Accounts.create_user_session_token(member)

      s = jbody(call(:post, "/v1/auth/device/start", %{client_name: "bp", team_id: team_a.id}))

      assert call(:post, "/v1/auth/device/approve", %{user_code: s["user_code"]}, member_session).status ==
               200

      # The code holder's deny answers the idempotent 200 and changes nothing.
      assert call(:post, "/v1/auth/device/deny", %{user_code: s["user_code"]}, outsider_session).status ==
               200

      poll = call(:post, "/v1/auth/device/poll", %{device_code: s["device_code"]})
      assert poll.status == 200
      assert Accounts.verify_user_session_token(jbody(poll)["token"]).id == member.id
    end

    test "any signed-in code holder may still deny a PENDING login, member or not (the safety valve)" do
      team_a = team_fixture()
      {:ok, outsider_session} = Accounts.create_user_session_token(member_of(team_fixture()))
      s = jbody(call(:post, "/v1/auth/device/start", %{client_name: "bp", team_id: team_a.id}))

      assert call(:post, "/v1/auth/device/deny", %{user_code: s["user_code"]}, outsider_session).status ==
               200

      poll = call(:post, "/v1/auth/device/poll", %{device_code: s["device_code"]})
      assert poll.status == 404
    end

    test "start with a bad team_id is 422 invalid_team" do
      conn = call(:post, "/v1/auth/device/start", %{team_id: "not-a-uuid"})
      assert conn.status == 422
      assert jbody(conn) == %{"error" => "invalid_team"}
    end

    test "an unbound start is unchanged: any authenticated user approves their own login" do
      user = member_of(team_fixture())
      {:ok, session} = Accounts.create_user_session_token(user)
      s = jbody(call(:post, "/v1/auth/device/start", %{client_name: "bp"}))

      assert call(:post, "/v1/auth/device/approve", %{user_code: s["user_code"]}, session).status ==
               200
    end
  end
end
