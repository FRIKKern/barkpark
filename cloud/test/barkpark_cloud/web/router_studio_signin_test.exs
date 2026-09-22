defmodule BarkparkCloud.Web.RouterStudioSigninTest do
  @moduledoc """
  "Sign in with Barkpark Cloud" — the CONTROL-PLANE half
  (`task-f44dee5dd62928cc`).

  `POST /v1/auth/studio-signin` is the instance-INITIATED twin of
  `POST /v1/barkparks/:id/studio-link`: the browser arrives from an instance's
  own login page, which knows its public hostname and nothing else (a box is
  never told its control-plane UUID), so the row is resolved BY HOST and the
  caller is authorized by the membership row on the resolved row's team.

  ## What is trusted, and by whom

  The instance verifies NOTHING new. What it finally consumes is a single-use,
  60s login ticket that the instance MINTED ITSELF off its own admin token at
  this plane's server-side request — the same artefact studio-link produces.
  Every trust decision is therefore made here, and these tests are that
  decision's control surface:

    * a live Cloud SESSION is required (§revocation: a revoked session is 401
      before any lookup);
    * a MEMBERSHIP ROW on the resolved instance's team is required (§revocation:
      an ex-member with a still-live session is 404, and the instance is never
      called);
    * resolution is NOT authorization — unregistered, typo'd and other-team
      hosts are the SAME 404, so the door is not an existence oracle.

  ## The negative that is not catchable by inspection

  `§membership check` is the test that REDS when the `Accounts.get_membership/2`
  clause is deleted from the route: with the check gone, `non_member_404` and
  `ex_member_404` both return 200 and the fake transport records a mint. Run it
  by deleting the clause, not by reading it.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Accounts.TeamMembership
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext"

  ## Fixtures (mirror RouterStudioLinkTest's)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # A LIVE instance whose provisioning FQDN is unique per test (the lookup is
  # host-keyed and NOT team-scoped, so a shared host would be ambiguous).
  defp live_barkpark(team, opts \\ []) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    host = Keyword.get(opts, :host, "signin-#{n}.barkpark.cloud")

    bp
    |> Ecto.Changeset.change(
      [
        url: "https://" <> host,
        host: "203.0.113.10",
        admin_token_encrypted: Vault.encrypt(@instance_admin_token)
      ] ++ Keyword.take(opts, [:custom_host])
    )
    |> Repo.update!()
  end

  defp signin(host, token) do
    conn =
      :post
      |> conn("/v1/auth/studio-signin", Jason.encode!(%{host: host}))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp ticket(t), do: {:ok, %{status: 201, body: ~s({"ticket":"#{t}","expires_in":60})}}

  describe "POST /v1/auth/studio-signin — the happy door" do
    test "a member signing in by the instance's provisioning host lands on a ticket URL" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      host = URI.parse(bp.url).host
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_signin-1")])

      conn = signin(host, token)

      assert conn.status == 200
      assert json_body(conn)["url"] == bp.url <> "/login/ticket/bplt_signin-1"

      # The instance minted a USER-shaped ticket for THIS cloud account — that
      # is the JIT provisioning, and it is the only identity that travels.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.url == bp.url <> "/v1/auth/login-tickets"
      assert Jason.decode!(req.body) == %{"email" => user.email}

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)

      # The stored admin credential never reaches the browser.
      refute conn.resp_body =~ @instance_admin_token
    end

    test "a full ORIGIN (scheme, port, path) resolves the same row as the bare host" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      host = URI.parse(bp.url).host
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_origin-1")])

      conn = signin("HTTPS://" <> host <> ":443/login", token)

      assert conn.status == 200
      assert json_body(conn)["url"] == bp.url <> "/login/ticket/bplt_origin-1"
    end

    test "the operator-attached custom host resolves the row, and the ticket lands there" do
      {user, team} = user_with_team()
      n = System.unique_integer([:positive])
      custom = "studio-#{n}.example.com"
      bp = live_barkpark(team, custom_host: custom)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_custom-1")])

      conn = signin(custom, token)

      assert conn.status == 200
      assert json_body(conn)["url"] == "https://" <> custom <> "/login/ticket/bplt_custom-1"
      # Control traffic still went to the PROVISIONING FQDN, not the vanity name.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.url == bp.url <> "/v1/auth/login-tickets"
    end
  end

  describe "POST /v1/auth/studio-signin — §membership check (the revocation gate)" do
    test "non_member_404: a member of ANOTHER team is refused, and the instance is never called" do
      {_owner, team_a} = user_with_team()
      bp = live_barkpark(team_a)
      host = URI.parse(bp.url).host

      {outsider, _team_b} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(outsider)

      StudioLinkFakeHttpClient.program([ticket("bplt_must-not-mint")])

      conn = signin(host, token)

      assert conn.status == 404
      assert json_body(conn) == %{"error" => "not_found"}
      # No ticket was minted: the refusal beats the instance call entirely.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "ex_member_404: deleting ONLY the membership row (session left live) closes the door" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      host = URI.parse(bp.url).host
      {:ok, token} = Accounts.create_user_session_token(user)

      # PRECONDITION — the same user, the same session, the same host mints
      # today. Without this arm the refusal below could be any of a dozen
      # unrelated failures.
      StudioLinkFakeHttpClient.program([ticket("bplt_before-removal")])
      before = signin(host, token)
      assert before.status == 200
      assert [_] = StudioLinkFakeHttpClient.requests()

      # Remove the GRANT only — not the session. `Accounts.remove_member/2`
      # also revokes sessions, which would make this test pass through the 401
      # door and say nothing about membership; deleting the row directly is the
      # narrower, honest probe of the check this route owns.
      %TeamMembership{} = m = Accounts.get_membership(team, user)
      Repo.delete!(m)

      StudioLinkFakeHttpClient.program([ticket("bplt_after-removal")])
      after_removal = signin(host, token)

      assert after_removal.status == 404
      assert json_body(after_removal) == %{"error" => "not_found"}
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "remove_member/2 (the product action) closes the door too — at the session" do
      {user, team} = user_with_team()
      # A second owner, so the last-owner guard does not refuse the removal.
      {:ok, _} = Accounts.add_member(team, user_fixture(), "owner")
      bp = live_barkpark(team)
      host = URI.parse(bp.url).host
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_before-remove-member")])
      assert signin(host, token).status == 200

      {:ok, _} = Accounts.remove_member(team, user)

      StudioLinkFakeHttpClient.program([ticket("bplt_after-remove-member")])
      conn = signin(host, token)

      assert conn.status == 401
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a REVOKED cloud session is 401 before any lookup, and mints nothing" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      host = URI.parse(bp.url).host
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_before-revoke")])
      assert signin(host, token).status == 200

      {:ok, _} = Accounts.delete_user_session_tokens(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_after-revoke")])
      conn = signin(host, token)

      assert conn.status == 401
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "no credential at all → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = signin(URI.parse(bp.url).host, nil)
      assert conn.status == 401
    end
  end

  describe "POST /v1/auth/studio-signin — no existence oracle, no fail-open" do
    test "an unregistered host is the SAME 404 as another team's host" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_must-not-mint")])

      unregistered =
        signin("nobody-here-#{System.unique_integer([:positive])}.example.com", token)

      {_owner, team_a} = user_with_team()
      other = signin(URI.parse(live_barkpark(team_a).url).host, token)

      assert unregistered.status == 404
      assert other.status == 404
      assert unregistered.resp_body == other.resp_body
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a missing, blank or junk host is a clean 404, never a 500" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      for host <- ["", "   ", "https://", "://", "not a host at all"] do
        conn = signin(host, token)
        assert conn.status == 404, "host #{inspect(host)} answered #{conn.status}"
      end

      # No host key at all in the body.
      conn =
        :post
        |> conn("/v1/auth/studio-signin", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(@opts)

      assert conn.status == 404
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a SUSPENDED instance mints nothing and the admin token is never decrypted" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      host = URI.parse(bp.url).host
      {:ok, _n} = Registry.suspend_team_barkparks(team, "billing_lapsed")
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([ticket("bplt_must-not-mint")])

      conn = signin(host, token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "suspended"
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "an instance that does not answer is a 502 — and hands back no session" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      host = URI.parse(bp.url).host
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:error, :econnrefused}])

      conn = signin(host, token)

      assert conn.status == 502
      assert json_body(conn)["error"] == "instance_unreachable"
      refute json_body(conn)["url"]
    end

    test "an instance with no stored admin token is 404 no_admin_token, not a silent pass" do
      {user, team} = user_with_team()
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      bp =
        bp
        |> Ecto.Changeset.change(url: "https://no-token-#{n}.barkpark.cloud")
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      conn = signin(URI.parse(bp.url).host, token)

      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end
  end
end
