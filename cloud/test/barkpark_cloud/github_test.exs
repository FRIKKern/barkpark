defmodule BarkparkCloud.GitHubTest do
  @moduledoc """
  The GitHub context (gh-2) + the in-memory Fake client: connect/state/disconnect,
  connect-time validation through the seam, encryption at rest, cross-team
  isolation, and the Fake's deterministic + inspectable side effects.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.GitHub
  alias BarkparkCloud.GitHub.{Fake, Installation}
  alias BarkparkCloud.Registry.Vault

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = BarkparkCloud.Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  describe "client selection + configured?/install_url" do
    test "defaults to the in-memory Fake" do
      assert GitHub.client() == BarkparkCloud.GitHub.Fake
    end

    test "configured? is false in test (no App credentials wired)" do
      refute GitHub.configured?()
    end

    test "configured? is true only when BOTH app_id and private_key are present" do
      base = Application.get_env(:barkpark_cloud, GitHub, [])
      on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)

      Application.put_env(:barkpark_cloud, GitHub, Keyword.merge(base, app_id: "123"))
      refute GitHub.configured?()

      Application.put_env(
        :barkpark_cloud,
        GitHub,
        Keyword.merge(base, app_id: "123", private_key: "-----BEGIN…")
      )

      assert GitHub.configured?()
    end

    test "install_url derives from the app slug, nil when unset" do
      base = Application.get_env(:barkpark_cloud, GitHub, [])
      on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)

      assert GitHub.install_url() == nil

      Application.put_env(
        :barkpark_cloud,
        GitHub,
        Keyword.merge(base, app_slug: "barkpark-deploy")
      )

      assert GitHub.install_url() == "https://github.com/apps/barkpark-deploy/installations/new"
    end
  end

  describe "record_installation/2" do
    test "a valid id → stored, account_login from the seam, id encrypted at rest" do
      team = team_fixture()

      assert {:ok, %Installation{} = inst} = GitHub.record_installation(team, "4242")
      assert inst.team_id == team.id
      assert inst.account_login == "octo-4242"

      # The stored handle is CIPHERTEXT, never the plaintext id.
      refute inst.installation_id_encrypted == "4242"
      assert {:ok, "4242"} = Vault.decrypt(inst.installation_id_encrypted)
      assert {:ok, "4242"} = GitHub.reveal_installation_id(inst)
    end

    test "an unknown/uninstalled id → :installation_not_found, nothing written" do
      team = team_fixture()

      assert {:error, :installation_not_found} =
               GitHub.record_installation(team, Fake.invalid_installation_id())

      assert GitHub.installation_for(team) == nil
    end

    test "re-connect replaces the row (one installation per team)" do
      team = team_fixture()
      {:ok, _} = GitHub.record_installation(team, "100")
      {:ok, inst2} = GitHub.record_installation(team, "200")

      assert inst2.account_login == "octo-200"
      # Still exactly one row for the team.
      assert %Installation{account_login: "octo-200"} = GitHub.installation_for(team)
      assert {:ok, "200"} = GitHub.reveal_installation_id(GitHub.installation_for(team))
    end
  end

  describe "connection_state/1 + disconnect/1" do
    test "state reflects connect then disconnect; never leaks the handle" do
      team = team_fixture()
      assert GitHub.connection_state(team) == %{connected: false, account_login: nil}

      {:ok, _} = GitHub.record_installation(team, "7")
      assert GitHub.connection_state(team) == %{connected: true, account_login: "octo-7"}

      assert :ok = GitHub.disconnect(team)
      assert GitHub.connection_state(team) == %{connected: false, account_login: nil}
    end

    test "disconnect with no connection → :not_found" do
      assert {:error, :not_found} = GitHub.disconnect(team_fixture())
    end
  end

  describe "cross-team isolation" do
    test "one team's installation is invisible to another" do
      team_a = team_fixture()
      team_b = team_fixture()
      {:ok, _} = GitHub.record_installation(team_a, "11")

      assert GitHub.connected?(team_a)
      refute GitHub.connected?(team_b)
      assert GitHub.installation_for(team_b) == nil
      assert GitHub.connection_state(team_b) == %{connected: false, account_login: nil}
    end
  end

  describe "Fake client — deterministic + inspectable side effects" do
    setup do
      Fake.reset()
      :ok
    end

    test "create_repo records + returns a deterministic full_name" do
      assert {:ok, repo} = Fake.create_repo("55", "my-blog", true)
      assert repo["full_name"] == "octo-55/my-blog"
      assert repo["private"] == true
      assert [%{"full_name" => "octo-55/my-blog"}] = Fake.created_repos()
    end

    test "push_files records the batch + counts pushed" do
      files = [%{path: "index.md", content: "# hi"}, %{path: "about.md", content: "x"}]
      assert {:ok, %{pushed: 2}} = Fake.push_files("55", "octo-55/my-blog", files, "seed")
      assert [%{repo: "octo-55/my-blog", files: ^files, message: "seed"}] = Fake.pushes()
    end

    test "register_webhook records url+secret, never returns the secret" do
      assert {:ok, hook} = Fake.register_webhook("55", "octo-55/my-blog", "https://x/hook", "sh")
      refute hook |> Map.get("config") |> Map.has_key?("secret")
      assert [%{url: "https://x/hook", secret: "sh"}] = Fake.registered_webhooks()
    end

    test "an invalid installation id fails every action closed" do
      bad = Fake.invalid_installation_id()
      assert {:error, :not_found} = Fake.get_installation(bad)
      assert {:error, :not_found} = Fake.exchange_installation_token(bad)
      assert {:error, :not_found} = Fake.create_repo(bad, "r", false)
      assert {:error, :not_found} = Fake.list_repos(bad)
    end
  end
end
