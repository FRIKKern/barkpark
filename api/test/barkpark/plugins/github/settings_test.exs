defmodule Barkpark.Plugins.Github.SettingsTest do
  # async: false — mutates the shared `Application.env` config key the GitHub
  # plugin reads (also touched by the singleton Auth/Client tests).
  use Barkpark.DataCase, async: false

  alias Barkpark.Plugins.Github.Settings, as: GH
  alias Barkpark.Plugins.Settings, as: Plugins

  @config_key Barkpark.Plugins.Github
  @plugin "github"

  # A full, valid credential set (env or DB shape).
  @full %{
    repo: "FRIKKern/barkpark",
    app_id: "123456",
    installation_id: "987654",
    private_key: "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----",
    webhook_secret: "shhh-webhook",
    api_base: "https://api.github.com"
  }

  setup do
    prev = Application.get_env(:barkpark, @config_key)
    Application.delete_env(:barkpark, @config_key)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, @config_key, prev),
        else: Application.delete_env(:barkpark, @config_key)
    end)

    :ok
  end

  defp put_env(kw), do: Application.put_env(:barkpark, @config_key, kw)

  defp seed_db(map) do
    stringed = Map.new(map, fn {k, v} -> {Atom.to_string(k), to_string(v)} end)
    assert {:ok, _} = Plugins.put(@plugin, stringed)
  end

  describe "get_credentials/0" do
    test "returns all-nil when neither env nor DB is configured; never raises" do
      creds = GH.get_credentials()

      assert creds.repo == nil
      assert creds.app_id == nil
      assert creds.installation_id == nil
      assert creds.private_key == nil
      assert creds.webhook_secret == nil
      assert creds.project_id == nil
      assert creds.api_base == nil
    end

    test "resolves from env" do
      put_env(Enum.to_list(@full))

      creds = GH.get_credentials()
      assert creds.repo == @full.repo
      assert creds.app_id == @full.app_id
      assert creds.private_key == @full.private_key
      assert creds.api_base == @full.api_base
    end

    test "resolves from the encrypted plugin_settings row when env is absent" do
      seed_db(@full)

      creds = GH.get_credentials()
      assert creds.repo == @full.repo
      assert creds.installation_id == @full.installation_id
      assert creds.webhook_secret == @full.webhook_secret
    end
  end

  describe "resolution precedence (env wins per-field, DB fallback)" do
    test "env value wins over the DB row" do
      seed_db(%{@full | repo: "from-db/repo", app_id: "db-app"})

      put_env(repo: "from-env/repo", app_id: "env-app")

      creds = GH.get_credentials()
      assert creds.repo == "from-env/repo"
      assert creds.app_id == "env-app"
    end

    test "a blank/absent env key falls back to DB per-field" do
      seed_db(@full)

      # repo blank in env, app_id absent in env → both fall back to DB.
      put_env(repo: "   ", installation_id: "env-install")

      creds = GH.get_credentials()
      assert creds.repo == @full.repo
      assert creds.installation_id == "env-install"
      assert creds.app_id == @full.app_id
      assert creds.webhook_secret == @full.webhook_secret
    end
  end

  describe "active?/0" do
    test "true when all required creds are present and non-blank" do
      put_env(Enum.to_list(@full))
      assert GH.active?() == true
    end

    test "true resolving the required creds across env + DB" do
      seed_db(Map.take(@full, [:private_key, :webhook_secret]))
      put_env(repo: @full.repo, app_id: @full.app_id, installation_id: @full.installation_id)

      assert GH.active?() == true
    end

    test "false when a single required cred is missing" do
      put_env(@full |> Map.delete(:webhook_secret) |> Enum.to_list())
      assert GH.active?() == false
    end

    test "false when a required cred is only whitespace (fail-closed)" do
      put_env(%{@full | app_id: "   "} |> Enum.to_list())
      assert GH.active?() == false
    end

    test "false with nothing configured" do
      assert GH.active?() == false
    end

    test "project_id + api_base are NOT required for active?" do
      creds_without_optional = Map.drop(@full, [:api_base])
      put_env(Enum.to_list(creds_without_optional))
      assert GH.active?() == true
    end
  end

  describe "repo/0" do
    test "returns the repo string when set" do
      put_env(repo: "FRIKKern/barkpark")
      assert GH.repo() == "FRIKKern/barkpark"
    end

    test "returns nil when unset" do
      assert GH.repo() == nil
    end

    test "returns nil when blank" do
      put_env(repo: "   ")
      assert GH.repo() == nil
    end

    test "falls back to the DB row" do
      seed_db(%{repo: "db/repo"})
      assert GH.repo() == "db/repo"
    end
  end

  describe "datasets/0" do
    test "defaults to [\"production\"]" do
      assert GH.datasets() == ["production"]
    end

    test "reads :github_mirror_datasets from config" do
      put_env(github_mirror_datasets: ["production", "staging"])
      assert GH.datasets() == ["production", "staging"]
    end

    test "a malformed (non-list) value falls back to the default" do
      put_env(github_mirror_datasets: "production")
      assert GH.datasets() == ["production"]
    end

    test "an empty list falls back to the default" do
      put_env(github_mirror_datasets: [])
      assert GH.datasets() == ["production"]
    end

    test "drops blank/non-binary entries, keeping the rest" do
      put_env(github_mirror_datasets: ["production", "", :bogus, "staging"])
      assert GH.datasets() == ["production", "staging"]
    end
  end

  describe "required_keys/0" do
    test "reuses Github.required_creds/0 (single source of truth)" do
      expected = Enum.map(Barkpark.Plugins.Github.required_creds(), &String.to_existing_atom/1)
      assert GH.required_keys() == expected
      assert :repo in GH.required_keys()
      assert :webhook_secret in GH.required_keys()
      refute :project_id in GH.required_keys()
    end
  end
end
