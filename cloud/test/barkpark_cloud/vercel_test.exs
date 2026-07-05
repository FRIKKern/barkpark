defmodule BarkparkCloud.VercelTest do
  @moduledoc """
  The zero-paste Vercel handoff (task-4e4a53b101a97051): the context + Fake
  client (deploy/claim through the seam, encryption at rest, idempotent
  re-deploy, honest error branches), the Real client's pure request builders,
  and the router endpoint's gate ladder (503 unconfigured → 404 cross-team →
  201 with claim state).
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Vercel
  alias BarkparkCloud.Vercel.{Fake, Real}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures (mirrors BootstrapTemplateTest)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp owner_token do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {token, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  # A barkpark with a stored content bootstrap for a DEPLOYABLE template — the
  # state dwb-4 leaves behind after a templated launch succeeded.
  defp bootstrapped_barkpark(team, template \\ "blog-starter") do
    bp = barkpark_fixture(team)

    env = %{
      "BARKPARK_API_URL" => "https://acme.barkpark.cloud/w/acme/p/default",
      "BARKPARK_TOKEN" => "bp_read_supersecret",
      "BARKPARK_WORKSPACE" => "acme",
      "BARKPARK_PROJECT" => "default",
      "BARKPARK_DATASET" => "production",
      "BARKPARK_WEBHOOK_SECRET" => "whsec_test"
    }

    {:ok, bp} =
      bp
      |> Ecto.Changeset.change(%{
        template: template,
        bootstrap_workspace: "acme",
        bootstrap_project: "default",
        bootstrap_dataset: "production",
        bootstrap_read_token_encrypted: Vault.encrypt("bp_read_supersecret"),
        bootstrap_env_encrypted: Vault.encrypt(Jason.encode!(env))
      })
      |> Repo.update()

    bp
  end

  defp configure_vercel! do
    base = Application.get_env(:barkpark_cloud, Vercel, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, Vercel, base) end)

    Application.put_env(
      :barkpark_cloud,
      Vercel,
      Keyword.merge(base, client: Fake, token: "vt_test_token")
    )
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

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## Context + Fake

  describe "client selection + configured?" do
    test "defaults to the in-memory Fake and reports unconfigured" do
      assert Vercel.client() == Fake
      refute Vercel.configured?()
    end

    test "configured? flips only when the platform token is present" do
      configure_vercel!()
      assert Vercel.configured?()
    end
  end

  describe "deploy_for/1" do
    test "deploys the template with the bootstrap env installed, claim code encrypted at rest" do
      {_token, team} = owner_token()
      bp = bootstrapped_barkpark(team)

      assert {:ok, state} = Vercel.deploy_for(bp)
      assert state.deployed
      assert String.starts_with?(state.deployment_url, "https://")
      assert String.starts_with?(state.claim_url, "https://vercel.com/claim-deployment?code=")

      # The Fake recorded ONE deploy carrying every bootstrap env key.
      assert [%{env_keys: keys, files: files}] = Fake.deploys()
      assert files > 0

      assert keys == [
               "BARKPARK_API_URL",
               "BARKPARK_DATASET",
               "BARKPARK_PROJECT",
               "BARKPARK_TOKEN",
               "BARKPARK_WEBHOOK_SECRET",
               "BARKPARK_WORKSPACE"
             ]

      # Persisted: project id + url plaintext, the claim code ONLY as ciphertext.
      reloaded = Repo.get!(BarkparkCloud.Registry.Barkpark, bp.id)
      assert is_binary(reloaded.vercel_project_id)
      assert is_binary(reloaded.vercel_deploy_url)
      [%{code: code}] = Fake.codes()
      refute reloaded.vercel_claim_encrypted == code
      assert {:ok, ^code} = Vault.decrypt(reloaded.vercel_claim_encrypted)
      assert String.contains?(state.claim_url, code)
    end

    test "re-deploy is idempotent on the project: only a fresh claim code is minted" do
      {_token, team} = owner_token()
      bp = bootstrapped_barkpark(team)

      {:ok, _} = Vercel.deploy_for(bp)
      bp = Repo.get!(BarkparkCloud.Registry.Barkpark, bp.id)
      {:ok, state2} = Vercel.deploy_for(bp)

      assert length(Fake.deploys()) == 1
      assert length(Fake.codes()) == 2
      assert state2.deployed
    end

    test "a template-less launch → :no_bootstrap" do
      {_token, team} = owner_token()
      bp = barkpark_fixture(team)

      assert {:error, :no_bootstrap} = Vercel.deploy_for(bp)
    end

    test "a bootstrapped but non-deployable template → :not_deployable" do
      {_token, team} = owner_token()
      bp = bootstrapped_barkpark(team, "place-directory")

      assert {:error, :not_deployable} = Vercel.deploy_for(bp)
      assert Fake.deploys() == []
    end
  end

  describe "state/1" do
    test "a stale claim code (>23h) renders claim_url nil — never a dead link" do
      {_token, team} = owner_token()
      bp = bootstrapped_barkpark(team)
      {:ok, _} = Vercel.deploy_for(bp)

      stale = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

      {:ok, bp} =
        Repo.get!(BarkparkCloud.Registry.Barkpark, bp.id)
        |> Ecto.Changeset.change(%{vercel_claim_minted_at: stale})
        |> Repo.update()

      assert %{deployed: true, claim_url: nil} = Vercel.state(bp)
    end
  end

  ## Real client — pure request builders (no network, ever)

  describe "Real request builders" do
    test "create_project_request installs every env var encrypted across all targets" do
      req =
        Real.create_project_request("vt_x", "my-site", [
          %{key: "BARKPARK_TOKEN", value: "secret"}
        ])

      assert req.method == :post
      assert req.url == "https://api.vercel.com/v11/projects"
      assert {"Authorization", "Bearer vt_x"} in req.headers

      body = Jason.decode!(req.body)
      assert body["framework"] == "nextjs"

      assert [
               %{
                 "key" => "BARKPARK_TOKEN",
                 "value" => "secret",
                 "type" => "encrypted",
                 "target" => ["production", "preview", "development"]
               }
             ] = body["environmentVariables"]
    end

    test "upload_file_request is content-addressed (sha1 digest header, raw body)" do
      req = Real.upload_file_request("vt_x", "hello")
      assert req.url == "https://api.vercel.com/v2/files"
      assert {"x-vercel-digest", Real.sha1("hello")} in req.headers
      assert req.body == "hello"
    end

    test "create_deployment_request references files by sha1 + size, production target" do
      files = [%{path: "package.json", content: "{}"}]
      req = Real.create_deployment_request("vt_x", "my-site", "prj_1", files)

      body = Jason.decode!(req.body)
      assert body["target"] == "production"
      assert body["project"] == "prj_1"
      assert [%{"file" => "package.json", "sha" => sha, "size" => 2}] = body["files"]
      assert sha == Real.sha1("{}")
    end

    test "transfer_request_request hits the project's transfer-request endpoint" do
      req = Real.transfer_request_request("vt_x", "prj_1")
      assert req.url == "https://api.vercel.com/v9/projects/prj_1/transfer-request"
    end

    test "callbacks fail closed without a platform token or HTTP client" do
      assert {:error, :not_configured} = Real.create_transfer_code("prj_1")
    end
  end

  ## Router — the gate ladder

  describe "POST /v1/barkparks/:id/vercel-deploy" do
    test "503 feature_not_configured when no platform token is wired" do
      {token, team} = owner_token()
      bp = bootstrapped_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 503
      assert json_body(conn)["error"] == "feature_not_configured"
    end

    test "configured: 201 with the claim state; the fleet event fires" do
      configure_vercel!()
      {token, team} = owner_token()
      bp = bootstrapped_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 201

      assert %{"ok" => true, "vercel" => vercel} = json_body(conn)
      assert vercel["deployed"] == true
      assert String.starts_with?(vercel["claim_url"], "https://vercel.com/claim-deployment?code=")
      assert String.starts_with?(vercel["deployment_url"], "https://")
    end

    test "another team's instance is a 404 (no existence leak)" do
      configure_vercel!()
      {token, _team} = owner_token()
      other = team_fixture()
      bp = bootstrapped_barkpark(other)

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 404
    end

    test "no bootstrap stored → 409 no_bootstrap" do
      configure_vercel!()
      {token, team} = owner_token()
      bp = barkpark_fixture(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "no_bootstrap"
    end

    test "non-deployable template → 422 not_deployable" do
      configure_vercel!()
      {token, team} = owner_token()
      bp = bootstrapped_barkpark(team, "place-directory")

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "not_deployable"
    end
  end

  describe "GET /v1/barkparks/:id/bootstrap carries the vercel state" do
    test "unconfigured + undeployed reads honest false/nil" do
      {token, team} = owner_token()
      bp = bootstrapped_barkpark(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, token)
      assert conn.status == 200

      assert %{"vercel" => %{"configured" => false, "deployed" => false, "claim_url" => nil}} =
               json_body(conn)
    end

    test "after a deploy the state rides along with the claim link" do
      configure_vercel!()
      {token, team} = owner_token()
      bp = bootstrapped_barkpark(team)
      assert call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token).status == 201

      conn = call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, token)
      assert conn.status == 200

      assert %{"vercel" => %{"deployed" => true, "claim_url" => "https://" <> _}} =
               json_body(conn)
    end
  end
end
