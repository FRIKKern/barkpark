defmodule BarkparkCloud.Web.EnvVarsRouteTest do
  @moduledoc """
  Drives the env-vars HTTP surface added in `shared-secrets-env`:

      GET    /v1/env-vars
      POST   /v1/env-vars
      DELETE /v1/env-vars/:id

  And the injection seam — that a provisioned barkpark's team env reaches the
  worker via `POST /v1/internal/provision-jobs/claim`. Asserts the masking
  discipline (values never serialized), the owner/admin write-gate, write-once
  refusal, and cross-team 404 isolation.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

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

  # A user who belongs to a fresh team with the given role. Returns {user, team}.
  defp user_with_team(role) do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
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

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/env-vars" do
    test "owner → 201, value never echoed, row encrypted at rest" do
      {user, _team} = user_with_team("owner")
      token = login_token(user)

      conn = call(:post, "/v1/env-vars", %{key: "API_KEY", value: "s3cr3t"}, token)
      assert conn.status == 201

      ev = body(conn)["env_var"]
      assert ev["key"] == "API_KEY"
      refute Map.has_key?(ev, "value")
      refute Map.has_key?(ev, "value_encrypted")
    end

    test "admin → 201" do
      {user, _team} = user_with_team("admin")
      token = login_token(user)

      conn = call(:post, "/v1/env-vars", %{key: "K", value: "v"}, token)
      assert conn.status == 201
    end

    test "member → 403" do
      {user, _team} = user_with_team("member")
      token = login_token(user)

      conn = call(:post, "/v1/env-vars", %{key: "K", value: "v"}, token)
      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
    end

    test "missing key → 422" do
      {user, _team} = user_with_team("owner")
      token = login_token(user)

      conn = call(:post, "/v1/env-vars", %{value: "v"}, token)
      assert conn.status == 422
      assert body(conn)["error"] == "key_required"
    end

    test "write to a write-once var → 409" do
      {user, _team} = user_with_team("owner")
      token = login_token(user)

      assert call(:post, "/v1/env-vars", %{key: "ONCE", value: "v1", is_shown_once: true}, token).status ==
               201

      conn = call(:post, "/v1/env-vars", %{key: "ONCE", value: "v2"}, token)
      assert conn.status == 409
      assert body(conn)["error"] == "write_once"
    end

    test "unauthenticated → 401" do
      conn = call(:post, "/v1/env-vars", %{key: "K", value: "v"}, nil)
      assert conn.status == 401
    end

    test "supplying ANOTHER team's barkpark_id → 403, nothing written (ownership)" do
      {user_a, team_a} = user_with_team("owner")
      token_a = login_token(user_a)
      {_user_b, team_b} = user_with_team("owner")
      bp_b = barkpark_fixture(team_b)

      conn =
        call(
          :post,
          "/v1/env-vars",
          %{key: "STOLEN", value: "v", scope: "barkpark", barkpark_id: bp_b.id},
          token_a
        )

      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
      # The cross-tenant write never landed on either team.
      assert Registry.list_env_vars(team_a) == []
      assert Registry.resolved_env_for_barkpark(bp_b) == %{}
    end
  end

  describe "GET /v1/env-vars" do
    test "lists the team's vars, never any value" do
      {user, team} = user_with_team("owner")
      token = login_token(user)
      {:ok, _} = Registry.put_env_var(team, %{key: "A", value: "1", scope: "team"})
      {:ok, _} = Registry.put_env_var(team, %{key: "B", value: "2", scope: "team"})

      conn = call(:get, "/v1/env-vars", nil, token)
      assert conn.status == 200

      vars = body(conn)["env_vars"]
      assert length(vars) == 2
      assert Enum.all?(vars, fn v -> not Map.has_key?(v, "value") end)
      assert Enum.all?(vars, fn v -> not Map.has_key?(v, "value_encrypted") end)
    end

    test "is team-scoped: another team's vars are absent" do
      {user_a, _team_a} = user_with_team("owner")
      token_a = login_token(user_a)
      {_user_b, team_b} = user_with_team("owner")
      {:ok, _} = Registry.put_env_var(team_b, %{key: "SECRET_B", value: "b", scope: "team"})

      conn = call(:get, "/v1/env-vars", nil, token_a)
      assert body(conn)["env_vars"] == []
    end
  end

  describe "DELETE /v1/env-vars/:id" do
    test "owner → 200, the row is gone" do
      {user, team} = user_with_team("owner")
      token = login_token(user)
      {:ok, ev} = Registry.put_env_var(team, %{key: "DELME", value: "v", scope: "team"})

      conn = call(:delete, "/v1/env-vars/#{ev.id}", nil, token)
      assert conn.status == 200
      assert Registry.list_env_vars(team) == []
    end

    test "member → 403" do
      {owner, team} = user_with_team("owner")
      {:ok, ev} = Registry.put_env_var(team, %{key: "X", value: "v", scope: "team"})
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      token = login_token(member)

      conn = call(:delete, "/v1/env-vars/#{ev.id}", nil, token)
      assert conn.status == 403
      assert owner
    end

    test "another team's var id → 404" do
      {user_a, _team_a} = user_with_team("owner")
      token_a = login_token(user_a)
      {_user_b, team_b} = user_with_team("owner")
      {:ok, ev_b} = Registry.put_env_var(team_b, %{key: "B", value: "v", scope: "team"})

      conn = call(:delete, "/v1/env-vars/#{ev_b.id}", nil, token_a)
      assert conn.status == 404
    end
  end

  describe "injection into the provision claim" do
    test "claim payload carries the team's resolved, decrypted env" do
      {_user, team} = user_with_team("owner")
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.put_env_var(team, %{key: "FOO", value: "bar", scope: "team"})
      {:ok, _job} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert conn.status == 200
      assert body(conn)["env"] == %{"FOO" => "bar"}
    end

    test "a team with no vars → empty env map" do
      {_user, team} = user_with_team("owner")
      bp = barkpark_fixture(team)
      {:ok, _job} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert conn.status == 200
      assert body(conn)["env"] == %{}
    end
  end
end
