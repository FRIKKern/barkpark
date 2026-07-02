defmodule BarkparkCloud.Web.RouterSelfUpdateTest do
  @moduledoc """
  isu-6 — `POST /v1/barkparks/:id/self-update`: the control plane relays a
  self-update trigger to the instance's `POST /v1/admin/self-update` server-side
  with the STORED admin token (studio-link pattern) and RELAYS the instance's
  verdict. Proves:

    * happy path: instance 202 → our 202 {status: "updating"}; the instance was
      called with the DECRYPTED admin bearer; a one-row status refresh job is
      enqueued; the admin token never leaks into the response
    * instance semantics relay intact: 409 already_running / 503 not_enabled /
      500 runner_start_failed / 404 not_supported
    * ADMIN gate: a plain team member → 403 (and the instance is never called)
    * team scope fail-closed: an admin of ANOTHER team gets the SAME 404 as a
      nonexistent id (no existence leak)
    * unauthenticated → 401; not-live instance → 409 not_live; transport
      failure → 502 instance_unreachable
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router
  alias BarkparkCloud.Workers.UpdateStatusWorker

  @opts Router.init([])

  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"

  ## Fixtures (mirror RouterStudioLinkTest's)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  # A LIVE instance: url + host set, encrypted admin token stored (what the
  # provision-succeed path writes).
  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/barkparks/:id/self-update" do
    test "team admin, instance 202 → 202 {status: updating}; admin bearer used; refresh enqueued; token never leaks" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 202, body: ~s({"ok":true,"status":"started"})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", token)

      assert conn.status == 202
      assert json_body(conn) == %{"ok" => true, "status" => "updating"}

      # The instance-side trigger was called correctly: POST on the admin
      # endpoint, the DECRYPTED admin token as bearer, an empty-object body.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :post
      assert req.url == @instance_url <> "/v1/admin/self-update"
      assert req.body == "{}"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)

      # The admin token itself must NEVER appear in the response.
      refute conn.resp_body =~ @instance_admin_token

      # A one-row status refresh is queued so the fleet row reflects the run.
      assert_enqueued(worker: UpdateStatusWorker, args: %{"barkpark_id" => bp.id})
    end

    test "instance error semantics relay intact: 409 / 503 / 500 / 404" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      # Bodies mirror the REAL instance controller's nested error envelope
      # (self_update_controller.ex): {"error":{"code":…}}. The 503 relay
      # matches on that body, not the status alone — see the proxy case below.
      cases = [
        {409, 409, ~s({"error":{"code":"already_running"}}), "already_running"},
        {503, 503, ~s({"error":{"code":"feature_not_configured"}}), "not_enabled"},
        {500, 500, ~s({"error":{"code":"runner_start_failed"}}), "runner_start_failed"},
        {404, 404, ~s({"error":{"code":"not_found"}}), "not_supported"}
      ]

      for {instance_status, relayed_status, body, code} <- cases do
        StudioLinkFakeHttpClient.program([{:ok, %{status: instance_status, body: body}}])
        conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", token)

        assert conn.status == relayed_status
        assert json_body(conn)["error"]["code"] == code
      end

      # A 503 WITHOUT the instance's feature_not_configured envelope is the
      # box's front proxy during a restart window (e.g. the Caddy maintenance
      # page) — advising the operator to set BARKPARK_SELF_UPDATE_APPLY=1
      # there would be actively wrong. It relays as unavailable instead.
      StudioLinkFakeHttpClient.program([{:ok, %{status: 503, body: "<html>maintenance</html>"}}])
      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", token)
      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "instance_unavailable"

      # None of the error relays queued a refresh (only a started run does).
      refute_enqueued(worker: UpdateStatusWorker)
    end

    test "a plain team member → 403, instance never called" do
      {_owner, team} = user_with_team()
      bp = live_barkpark(team)

      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, token} = Accounts.create_user_session_token(member)

      StudioLinkFakeHttpClient.program([])
      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", token)

      assert conn.status == 403
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "cross-team: an admin of ANOTHER team gets the same 404 as a nonexistent id (no leak)" do
      {_user_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      StudioLinkFakeHttpClient.program([])
      wrong_team = call(:post, "/v1/barkparks/#{bp_b.id}/self-update", token_a)
      nonexistent = call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/self-update", token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert json_body(wrong_team) == json_body(nonexistent)

      # And the instance was never called for either.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "no token → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update")
      assert conn.status == 401
    end

    test "not-live instance (no url yet) → 409 not_live" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", token)
      assert conn.status == 409
      assert json_body(conn)["error"]["code"] == "not_live"
    end

    test "transport failure → 502 instance_unreachable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])
      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", token)

      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "instance_unreachable"
    end
  end
end
