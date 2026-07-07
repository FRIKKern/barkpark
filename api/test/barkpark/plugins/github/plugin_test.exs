defmodule Barkpark.Plugins.GithubTest do
  @moduledoc """
  Wave-1 skeleton contract for the `github` bridge plugin: the manifest loads,
  the module compiles inert (no routes/workers/schemas yet), and
  `validate_settings/1` is fail-closed on the required GitHub App credentials.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Github

  # A fully-provisioned credential row (nested under the "github" settings row,
  # the shape the admin Plugin Settings LiveView hands validate_settings/1).
  defp full_settings do
    %{
      "github" => %{
        "repo" => "FRIKKern/barkpark",
        "app_id" => "123456",
        "installation_id" => "987654",
        "private_key" => "-----BEGIN RSA PRIVATE KEY-----\nMIIfake\n-----END RSA PRIVATE KEY-----",
        "webhook_secret" => "s3cr3t-hmac",
        "project_id" => "PVT_kwFAKE"
      }
    }
  end

  describe "manifest/0" do
    test "loads and validates against the manifest schema" do
      manifest = Github.manifest()

      assert manifest["plugin_name"] == "github"
      assert manifest["module"] == "Barkpark.Plugins.Github"
      assert is_binary(manifest["version"])
      assert "settings" in manifest["capabilities"]
      # Manifest.validate! ran at compile time via `use Barkpark.Plugin`; a
      # non-map return would mean the frozen literal never landed.
      assert is_map(manifest)
    end
  end

  describe "wave-1 inert surfaces" do
    test "register_routes/1 returns [] (controllers land wave 2)" do
      assert Github.register_routes(%{}) == []
    end

    test "oban_crontab/0 returns [] (drain worker lands wave 2)" do
      assert Github.oban_crontab() == []
    end

    test "register_schemas/1 returns [] (github adds no task schema, D3)" do
      assert Github.register_schemas([]) == []
    end
  end

  describe "settings_schema/0" do
    test "declares the six App credential fields, secrets masked" do
      fields = Github.settings_schema()
      names = Enum.map(fields, & &1.name)

      assert "github.repo" in names
      assert "github.app_id" in names
      assert "github.installation_id" in names
      assert "github.private_key" in names
      assert "github.webhook_secret" in names
      assert "github.project_id" in names

      # project_id is the only optional credential.
      required_names =
        fields |> Enum.filter(&Map.get(&1, :required)) |> Enum.map(& &1.name)

      refute "github.project_id" in required_names
      assert "github.repo" in required_names

      # Both secrets are password-typed AND masked so they never render clear.
      for secret <- ["github.private_key", "github.webhook_secret"] do
        field = Enum.find(fields, &(&1.name == secret))
        assert field.type == :password
        assert field.masked == true
      end
    end
  end

  describe "validate_settings/1 (fail-closed)" do
    test "accepts a fully-populated credential map" do
      assert Github.validate_settings(full_settings()) == :ok
    end

    test "project_id is optional — absent still validates" do
      settings = update_in(full_settings(), ["github"], &Map.delete(&1, "project_id"))
      assert Github.validate_settings(settings) == :ok
    end

    test "rejects a map missing private_key" do
      settings = update_in(full_settings(), ["github"], &Map.delete(&1, "private_key"))

      assert {:error, errors} = Github.validate_settings(settings)
      assert {:"github.private_key", _msg} = List.keyfind(errors, :"github.private_key", 0)
    end

    test "rejects a blank (whitespace-only) required credential" do
      settings = put_in(full_settings(), ["github", "webhook_secret"], "   ")

      assert {:error, errors} = Github.validate_settings(settings)
      assert List.keyfind(errors, :"github.webhook_secret", 0)
    end

    test "rejects an entirely empty settings map (nothing provisioned)" do
      assert {:error, errors} = Github.validate_settings(%{})
      # Every required credential surfaces as an error.
      assert length(errors) == 5
    end

    test "rejects a non-map argument fail-closed" do
      assert {:error, _} = Github.validate_settings(nil)
    end

    test "rejects a present-but-non-map github row fail-closed (no crash)" do
      # The admin LiveView rescues any raise from validate_settings into :ok,
      # so a BadMapError on a junk row would be treated as VALID (fail-open).
      # A non-map row must instead surface every required credential as missing.
      assert {:error, errors} = Github.validate_settings(%{"github" => "junk"})
      assert length(errors) == 5
    end
  end

  describe "desk_items/1" do
    test "one link under /admin (not /studio, which the scoper mangles)" do
      assert [item] = Github.desk_items("production")
      assert item.type == :link
      assert item.path == "/admin/github"
      assert String.starts_with?(item.path, "/admin/")
    end
  end
end
