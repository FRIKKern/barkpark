defmodule Barkpark.PluginSettingsSchemaTest do
  @moduledoc """
  Contract tests for the tenth `Barkpark.Plugin` callback,
  `settings_schema/0`.

    * Default (no override) → `[]`.
    * OnixEdit → 5 Bokbasen credential fields with `:group => "Bokbasen"`.

  Together these prove the callback is optional (plugins that don't
  declare settings stay silent) and that OnixEdit's declared shape
  matches the field set the admin LV renders.
  """

  use ExUnit.Case, async: true

  describe "default settings_schema/0" do
    # Sibling module compiled at test-suite compile time. The `use
    # Barkpark.Plugin` macro reads the manifest at compile time and
    # `Path.expand`s the relative `manifest_path` against the caller's
    # source dir (`api/test/barkpark/`).
    defmodule FixturePluginNoSettings do
      @moduledoc false
      use Barkpark.Plugin,
        manifest_path: "../../priv/plugins/onixedit/plugin.json"
    end

    test "returns an empty list when not overridden" do
      assert FixturePluginNoSettings.settings_schema() == []
    end
  end

  describe "OnixEdit.settings_schema/0" do
    alias Barkpark.Plugins.OnixEdit

    test "declares 5 Bokbasen credential fields" do
      fields = OnixEdit.settings_schema()

      assert length(fields) == 5

      names = Enum.map(fields, & &1.name)

      assert names == [
               "bokbasen.api_base",
               "bokbasen.oauth_token_url",
               "bokbasen.client_id",
               "bokbasen.client_secret",
               "bokbasen.client_role"
             ]
    end

    test "marks the secret field as :password and the URLs as :url" do
      by_name = OnixEdit.settings_schema() |> Map.new(&{&1.name, &1})

      assert by_name["bokbasen.client_secret"].type == :password
      assert by_name["bokbasen.api_base"].type == :url
      assert by_name["bokbasen.oauth_token_url"].type == :url
      assert by_name["bokbasen.client_id"].type == :string
      assert by_name["bokbasen.client_role"].type == :select
    end

    test "every field carries the Bokbasen group" do
      assert Enum.all?(
               OnixEdit.settings_schema(),
               &(Map.get(&1, :group) == "Bokbasen")
             )
    end

    test "client_role options match Bokbasen.Settings @valid_roles" do
      by_name = OnixEdit.settings_schema() |> Map.new(&{&1.name, &1})
      assert by_name["bokbasen.client_role"].options == ["publisher", "distributor"]
    end

    test "every required field is flagged" do
      assert Enum.all?(OnixEdit.settings_schema(), &Map.get(&1, :required, false))
    end
  end
end
