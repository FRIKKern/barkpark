defmodule BarkparkCloud.Web.SupportBoxCapTest do
  @moduledoc """
  Owner ruling #37 (2026-10-03, "Per-team cap"): `POST /v1/fleet/supports`
  `mode: "provision"` starts a PAID server, so it runs under a per-team cap that
  an operator can raise. Before this, PDF-D86's quota exemption let a trial
  team's admin, or a deploy PAT, stand up any number of boxes.

    * at the cap → 403 `support_cap_reached` naming cap + count; no row, no job
    * register-only supports (the team's own boxes) neither count nor are capped
    * the operator override: PUT /v1/operator/teams/:id/support-cap raises it,
      `null` returns the team to the platform default; a non-operator is 403

  `async: false` — the operator allowlist and the default cap are
  process-global Application config.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob, Vault}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    prior_ops = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    prior_cap = Application.get_env(:barkpark_cloud, :support_box_cap_default)
    Application.put_env(:barkpark_cloud, :support_box_cap_default, 2)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, :platform_admin_emails, prior_ops)

      if is_nil(prior_cap),
        do: Application.delete_env(:barkpark_cloud, :support_box_cap_default),
        else: Application.put_env(:barkpark_cloud, :support_box_cap_default, prior_cap)
    end)

    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp owner_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  defp operator_token do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Ops #{n}", slug: "ops-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp live_main(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Main #{n}", slug: "main-#{n}"})
    {:ok, main} = bp |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()

    main
    |> Ecto.Changeset.change(
      url: "https://main-#{n}.barkpark.cloud",
      host: "203.0.113.5",
      admin_token_encrypted: Vault.encrypt("admin-secret-#{n}")
    )
    |> Repo.update!()
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp provision(main, token, name),
    do:
      call(
        :post,
        "/v1/fleet/supports",
        %{name: name, barkpark_id: main.id, mode: "provision"},
        token
      )

  defp supports(team),
    do: Repo.all(from b in Barkpark, where: b.team_id == ^team.id and b.fleet_role == "support")

  defp support_jobs(team) do
    ids = Enum.map(supports(team), & &1.id)

    Repo.all(
      from j in ProvisionJob, where: j.barkpark_id in ^ids and j.kind == "provision_support"
    )
  end

  describe "POST /v1/fleet/supports mode=provision — the per-team cap" do
    test "under the cap provisions (202); AT the cap is 403 support_cap_reached — no row, no job" do
      {team, token} = owner_with_team()
      main = live_main(team)

      assert provision(main, token, "Helper One").status == 202
      assert provision(main, token, "Helper Two").status == 202

      conn = provision(main, token, "Helper Three")

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "support_cap_reached"
      assert body["cap"] == 2
      assert body["count"] == 2
      assert length(supports(team)) == 2
      assert length(support_jobs(team)) == 2
    end

    test "register-only supports neither count toward the cap nor are capped" do
      {team, token} = owner_with_team()
      main = live_main(team)

      for i <- 1..3 do
        conn =
          call(:post, "/v1/fleet/supports", %{name: "Own #{i}", parent_id: main.id}, token)

        assert conn.status == 201, conn.resp_body
      end

      assert provision(main, token, "Paid One").status == 202
      assert Registry.count_provisioned_supports(team.id) == 1
    end
  end

  describe "PUT /v1/operator/teams/:id/support-cap — the operator override" do
    test "an operator raises one team's cap, and that team can provision again" do
      {team, token} = owner_with_team()
      main = live_main(team)
      assert provision(main, token, "A").status == 202
      assert provision(main, token, "B").status == 202
      assert provision(main, token, "C").status == 403

      conn = call(:put, "/v1/operator/teams/#{team.id}/support-cap", %{cap: 3}, operator_token())

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["effective_cap"] == 3
      assert provision(main, token, "C").status == 202
      assert provision(main, token, "D").status == 403
    end

    test "null returns the team to the platform default" do
      {team, _token} = owner_with_team()
      op = operator_token()

      assert call(:put, "/v1/operator/teams/#{team.id}/support-cap", %{cap: 9}, op).status == 200
      conn = call(:put, "/v1/operator/teams/#{team.id}/support-cap", %{cap: nil}, op)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["support_box_cap"] == nil
      assert body["effective_cap"] == 2
    end

    test "a team owner who is not an operator cannot raise their own cap (403)" do
      {team, token} = owner_with_team()

      conn = call(:put, "/v1/operator/teams/#{team.id}/support-cap", %{cap: 50}, token)

      assert conn.status == 403
      assert Repo.reload(team).support_box_cap == nil
    end

    test "a negative or non-integer cap is 422; an unknown team is 404" do
      {team, _token} = owner_with_team()
      op = operator_token()

      assert call(:put, "/v1/operator/teams/#{team.id}/support-cap", %{cap: -1}, op).status == 422

      assert call(:put, "/v1/operator/teams/#{team.id}/support-cap", %{cap: "7"}, op).status ==
               422

      assert call(:put, "/v1/operator/teams/#{team.id}/support-cap", %{}, op).status == 422

      assert call(:put, "/v1/operator/teams/#{Ecto.UUID.generate()}/support-cap", %{cap: 3}, op).status ==
               404
    end
  end
end
