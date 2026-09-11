defmodule BarkparkCloud.Sites.ArtifactQuotaTest do
  @moduledoc """
  ssw9-bl-artifact-retention-quota, criterion 1 — the PER-TEAM ceiling on stored
  artifact bytes, and the typed refusal the upload route turns into a 429.

  ## Why this file is `async: false`

  The ceiling is `Application.get_env(:barkpark_cloud, :artifact_quota_bytes)`,
  and every test here moves it. An application env is process-global: run this
  async and a concurrent upload test in another file would meet a 1-byte quota it
  never asked for. The sandbox isolates the ROWS, never the env.

  ## What is measured

  Accounting is read back from `site_artifacts` — the same table the reaper
  deletes from — never from a counter this module keeps. That is the property
  that matters: a lifetime counter would refuse a team that reaped everything it
  held, and the refusal test's own control (the same upload passing once the
  ceiling is raised) is what proves the number came from the store.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo, Sites}
  alias BarkparkCloud.Registry.{SiteArtifact, Vault}
  alias BarkparkCloud.Sites.{ArtifactQuota, ArtifactReaper}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"
  @instance_admin_token "instance-admin-token-plaintext"

  setup do
    previous = Application.fetch_env(:barkpark_cloud, :artifact_quota_bytes)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark_cloud, :artifact_quota_bytes, value)
        :error -> Application.delete_env(:barkpark_cloud, :artifact_quota_bytes)
      end
    end)

    :ok
  end

  ## Fixtures

  defp user_with_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "user-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "#{@instance_url}/#{n}",
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp prebuilt_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read_xyz"
      })

    {:ok, site} = Registry.update_site_settings(site, %{prebuilt_enabled: true})
    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call_json(method, path, body, token) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    Router.call(conn, @opts)
  end

  defp call_binary(method, path, body, token) do
    conn(method, path, body)
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp mint_prebuilt(site, token) do
    conn = call_json(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)
    assert conn.status == 201
    json_body(conn)["deployment"]
  end

  # Bytes stored through the SAME writer the upload route uses, on a deployment
  # minted through the real route.
  defp store(site, token, bytes) do
    dep = mint_prebuilt(site, token)
    d = Registry.get_deployment(dep["id"])
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    {:ok, _} = Sites.Deploy.store_artifact(d, bytes, sha)
    d
  end

  # Force a terminal status WITHOUT the driver — the driver's own drop_artifact/1
  # would confound a test about the SWEEP freeing the accounting.
  defp force_status(deployment, status) do
    Repo.update_all(
      from(d in BarkparkCloud.Registry.Deployment, where: d.id == ^deployment.id),
      set: [status: status]
    )
  end

  ## The accounting — read back from the store, per team

  describe "used_bytes/1" do
    test "counts this team's stored artifact bytes and NOT another team's" do
      {user_a, team_a} = user_with_team()
      site_a = prebuilt_site(live_barkpark(team_a))
      token_a = login_token(user_a)

      {user_b, team_b} = user_with_team()
      site_b = prebuilt_site(live_barkpark(team_b))
      token_b = login_token(user_b)

      # PRECONDITION: both teams start empty, so a later non-zero cannot be
      # inherited from a fixture.
      assert ArtifactQuota.used_bytes(team_a.id) == 0
      assert ArtifactQuota.used_bytes(team_b.id) == 0

      store(site_a, token_a, String.duplicate("a", 900))
      store(site_b, token_b, String.duplicate("b", 77))

      assert ArtifactQuota.used_bytes(team_a.id) == 900
      # The CROSS-TEAM control: team B's ceiling is not spent by team A.
      assert ArtifactQuota.used_bytes(team_b.id) == 77
    end

    test "FALLS when the reaper frees the bytes — live usage, not a lifetime counter" do
      {user, team} = user_with_team()
      site = prebuilt_site(live_barkpark(team))
      token = login_token(user)

      d = store(site, token, String.duplicate("x", 512))
      assert ArtifactQuota.used_bytes(team.id) == 512

      force_status(d, "failed")
      {:ok, _} = ArtifactReaper.reap()

      # Measured on the store, then on the accounting that reads it.
      assert Repo.aggregate(SiteArtifact, :count, :id) == 0
      assert ArtifactQuota.used_bytes(team.id) == 0
    end
  end

  ## The refusal — typed, with the numbers a route needs

  describe "check/2" do
    test "AT the limit is allowed; one byte past it is a typed refusal" do
      {user, team} = user_with_team()
      site = prebuilt_site(live_barkpark(team))
      token = login_token(user)

      store(site, token, String.duplicate("q", 100))
      Application.put_env(:barkpark_cloud, :artifact_quota_bytes, 150)

      assert ArtifactQuota.check(team.id, 50) == :ok

      assert {:error, {:artifact_quota_exceeded, refusal}} = ArtifactQuota.check(team.id, 51)

      assert refusal == %{used_bytes: 100, limit_bytes: 150, requested_bytes: 51}
    end

    test ":infinity disables the ceiling" do
      {user, team} = user_with_team()
      site = prebuilt_site(live_barkpark(team))
      token = login_token(user)

      store(site, token, String.duplicate("q", 100))

      Application.put_env(:barkpark_cloud, :artifact_quota_bytes, 10)
      assert {:error, {:artifact_quota_exceeded, _}} = ArtifactQuota.check(team.id, 1)

      Application.put_env(:barkpark_cloud, :artifact_quota_bytes, :infinity)
      assert ArtifactQuota.check(team.id, 1_000_000_000) == :ok
    end
  end

  ## The route — the disk-fill primitive, closed

  describe "POST /v1/sites/:id/deployments/:dep_id/artifact over quota" do
    test "429 artifact_quota_exceeded, and NOTHING is stored" do
      {user, team} = user_with_team()
      token = login_token(user)

      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      # The bytes this team already holds live on a DIFFERENT site of the same
      # team — the ceiling is per TEAM, so a second site must not reset it.
      other = prebuilt_site(bp)
      store(other, token, String.duplicate("h", 1000))
      Application.put_env(:barkpark_cloud, :artifact_quota_bytes, 1024)

      dep = mint_prebuilt(site, token)
      path = "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact"

      conn = call_binary(:post, path, String.duplicate("m", 500), token)

      assert conn.status == 429
      body = json_body(conn)
      assert body["error"] == "artifact_quota_exceeded"
      assert body["used_bytes"] == 1000
      assert body["requested_bytes"] == 500
      assert body["limit_bytes"] == 1024

      # THE MEASUREMENT IS THE STORE: the refused bytes did not land, and the
      # team still holds exactly what it held before.
      assert Sites.Deploy.artifact_for(dep["id"]) == nil
      assert ArtifactQuota.used_bytes(team.id) == 1000

      # THE CONTROL: the SAME upload under a ceiling that fits is a 201. Without
      # this, a 429 from any unrelated cause would pass the assertion above.
      Application.put_env(:barkpark_cloud, :artifact_quota_bytes, 1_000_000)
      ok = call_binary(:post, path, String.duplicate("m", 500), token)
      assert ok.status == 201
      assert Sites.Deploy.artifact_for(dep["id"]).byte_size == 500
    end
  end
end
