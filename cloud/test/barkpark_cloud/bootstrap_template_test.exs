defmodule BarkparkCloud.BootstrapTemplateTest do
  @moduledoc """
  dwb-4 — the content-template bootstrap's control-plane half:

    * `POST /v1/launch` accepts an OPTIONAL `template`, validated against the
      known catalog BEFORE any row/job exists — an unknown slug is a 4xx at
      launch, never a burned box; no template is the pre-dwb-4 launch exactly.
    * the chosen template persists on the barkpark row and rides the provision
      claim payload to the Go worker.
    * the worker's succeed report may carry the bootstrap OUTPUTS — plain slugs
      as columns, the read token + env map Vault-ENCRYPTED at rest.
    * `GET /v1/barkparks/:id/bootstrap` reveals them to the team admin only
      (the /credentials pattern: same auth, same no-leak 404s).
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Registry.{ProvisionJob, Vault}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  ## Fixtures (mirrors ProvisioningTest)

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

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp subscribed_owner_token do
    {user, team} = user_with_team()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    {:ok, token} = Accounts.create_user_session_token(user)
    {token, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  ## Request helpers

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

  # A representative bootstrap payload the Go worker reports on /succeed.
  defp bootstrap_payload do
    %{
      "template" => "place-directory",
      "workspace" => "acme",
      "project" => "default",
      "dataset" => "production",
      "read_token" => "bp_read_supersecret",
      "env" => %{
        "BARKPARK_API_URL" => "https://acme.barkpark.cloud/w/acme/p/default",
        "BARKPARK_TOKEN" => "bp_read_supersecret",
        "BARKPARK_DATASET" => "production"
      }
    }
  end

  ## Launch validation

  describe "POST /v1/launch template validation (dwb-4)" do
    test "a KNOWN template → 201, persisted on the row, and in the claim payload" do
      {token, team} = subscribed_owner_token()

      conn =
        call(:post, "/v1/launch", %{name: "My Site", template: "website-starter"}, token)

      assert conn.status == 201

      [bp] = Registry.list_barkparks(team)
      assert bp.template == "website-starter"

      # The claim payload hands the template to the Go worker.
      claim = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert claim.status == 200
      assert json_body(claim)["template"] == "website-starter"
    end

    test "an UNKNOWN template → 422 with the catalog, and NO row / NO job (never a burned box)" do
      {token, team} = subscribed_owner_token()

      conn = call(:post, "/v1/launch", %{name: "My Site", template: "wordpress"}, token)

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "unknown_template"

      assert body["known_templates"] == [
               "blog-starter",
               "place-directory",
               "website-starter"
             ]

      # Nothing was created — the rejection happened BEFORE any side effect.
      assert Registry.list_barkparks(team) == []
      assert Repo.all(ProvisionJob) == []
    end

    test "NO template → 201 with a nil template (the pre-dwb-4 launch, unchanged)" do
      {token, team} = subscribed_owner_token()

      conn = call(:post, "/v1/launch", %{name: "Plain"}, token)
      assert conn.status == 201

      [bp] = Registry.list_barkparks(team)
      assert bp.template == nil

      claim = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert claim.status == 200
      assert json_body(claim)["template"] == nil
    end

    test "a NON-STRING template (a map) → 422, not a 500" do
      {token, _team} = subscribed_owner_token()

      conn = call(:post, "/v1/launch", %{name: "My Site", template: %{"evil" => true}}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "unknown_template"
    end
  end

  ## Succeed stores the outputs

  describe "succeed with bootstrap outputs (worker report → encrypted storage)" do
    test "plain slugs land as columns; read token + env are Vault-ENCRYPTED, never plaintext" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "203.0.113.7", admin_token: "bp_admin_x", bootstrap: bootstrap_payload()},
          @worker_token
        )

      assert conn.status == 200

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
      assert reloaded.bootstrap_workspace == "acme"
      assert reloaded.bootstrap_project == "default"
      assert reloaded.bootstrap_dataset == "production"

      # The read token column is ciphertext — decryptable, never the plaintext.
      assert is_binary(reloaded.bootstrap_read_token_encrypted)
      refute String.contains?(reloaded.bootstrap_read_token_encrypted, "bp_read_supersecret")
      assert {:ok, "bp_read_supersecret"} = Vault.decrypt(reloaded.bootstrap_read_token_encrypted)

      # The env blob is ciphertext too (it CONTAINS the read token).
      assert is_binary(reloaded.bootstrap_env_encrypted)
      refute String.contains?(reloaded.bootstrap_env_encrypted, "bp_read_supersecret")
      assert {:ok, env_json} = Vault.decrypt(reloaded.bootstrap_env_encrypted)
      assert Jason.decode!(env_json)["BARKPARK_TOKEN"] == "bp_read_supersecret"

      # reveal_bootstrap round-trips the whole map.
      assert {:ok, boot} = Registry.reveal_bootstrap(reloaded)
      assert boot.workspace == "acme"
      assert boot.read_token == "bp_read_supersecret"
      assert boot.env["BARKPARK_DATASET"] == "production"
    end

    test "succeed WITHOUT bootstrap leaves the columns nil (back-compat)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "203.0.113.8"},
          @worker_token
        )

      assert conn.status == 200
      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.bootstrap_workspace == nil
      assert reloaded.bootstrap_read_token_encrypted == nil
      assert reloaded.bootstrap_env_encrypted == nil
      assert {:ok, nil} = Registry.reveal_bootstrap(reloaded)
    end

    test "a retried (idempotent) succeed does not error and keeps the stored outputs" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      body = %{ip: "203.0.113.7", bootstrap: bootstrap_payload()}

      assert call(:post, "/v1/internal/provision-jobs/#{job.id}/succeed", body, @worker_token).status ==
               200

      # The re-POST (a dropped response self-heal) is a 200 and the row still
      # decrypts to the same outputs — nothing duplicated, nothing clobbered.
      assert call(:post, "/v1/internal/provision-jobs/#{job.id}/succeed", body, @worker_token).status ==
               200

      assert {:ok, boot} = Registry.reveal_bootstrap(Registry.get_barkpark(bp.id))
      assert boot.read_token == "bp_read_supersecret"
    end
  end

  ## Retrieval endpoint

  describe "GET /v1/barkparks/:id/bootstrap (owner retrieval)" do
    defp bootstrapped_barkpark(team) do
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "203.0.113.7", bootstrap: bootstrap_payload())
      bp
    end

    test "team owner gets the decrypted outputs (show-to-owner)" do
      {owner, team} = user_with_team()
      {:ok, owner_token} = Accounts.create_user_session_token(owner)
      bp = bootstrapped_barkpark(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, owner_token)

      assert conn.status == 200
      body = json_body(conn)
      assert body["workspace"] == "acme"
      assert body["project"] == "default"
      assert body["dataset"] == "production"
      assert body["read_token"] == "bp_read_supersecret"
      assert body["env"]["BARKPARK_TOKEN"] == "bp_read_supersecret"
      assert body["url"] == bp.url
    end

    test "no bootstrap stored → 404 no_bootstrap (template-less launch)" do
      {owner, team} = user_with_team()
      {:ok, owner_token} = Accounts.create_user_session_token(owner)
      bp = barkpark_fixture(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, owner_token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_bootstrap"
    end

    test "a non-admin MEMBER of the owning team → 403 (team-admin gated)" do
      {_owner, team} = user_with_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, member_token} = Accounts.create_user_session_token(member)
      bp = bootstrapped_barkpark(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, member_token)
      assert conn.status == 403
    end

    test "another team's barkpark → the SAME 404 (no existence leak)" do
      {_owner_a, team_a} = user_with_team()
      {other, _team_b} = user_with_team()
      {:ok, other_token} = Accounts.create_user_session_token(other)
      bp = bootstrapped_barkpark(team_a)

      conn = call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, other_token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "unauthenticated → 401" do
      {_owner, team} = user_with_team()
      bp = bootstrapped_barkpark(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, nil)
      assert conn.status == 401
    end

    test "a NON-UUID id → 404, not an Ecto.CastError 500 (binary_id guard)" do
      {owner, _team} = user_with_team()
      {:ok, owner_token} = Accounts.create_user_session_token(owner)

      conn = call(:get, "/v1/barkparks/not-a-uuid/bootstrap", nil, owner_token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end
  end

  ## Catalog mirror

  test "known_templates/0 mirrors the Go worker's embedded catalog (sorted)" do
    # The Go side locks the same list in TestCatalogCarriesTheThreeTemplates
    # (internal/provisioner/catalog) — change BOTH together.
    assert Registry.known_templates() == ["blog-starter", "place-directory", "website-starter"]
    assert Registry.known_template?("place-directory")
    refute Registry.known_template?("wordpress")
    refute Registry.known_template?(nil)
  end
end
