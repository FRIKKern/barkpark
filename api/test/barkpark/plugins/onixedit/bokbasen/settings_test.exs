defmodule Barkpark.Plugins.OnixEdit.Bokbasen.SettingsTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Settings, as: Bokbasen
  alias Barkpark.Plugins.Settings, as: Plugins

  @env_module Barkpark.Plugins.OnixEdit.Bokbasen
  @plugin "bokbasen"

  @valid %{
    api_base: "https://api.bokbasen.io",
    oauth_token_url: "https://login.bokbasen.io/oauth2/token",
    client_id: "test-client-id",
    client_secret: "test-secret-value",
    client_role: "publisher"
  }

  setup do
    prev = Application.get_env(:barkpark, @env_module)
    Application.delete_env(:barkpark, @env_module)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, @env_module, prev),
        else: Application.delete_env(:barkpark, @env_module)
    end)

    :ok
  end

  describe "default_client_role/0" do
    test "returns publisher (Q-J: Barkpark = Publisher)" do
      assert Bokbasen.default_client_role() == "publisher"
    end
  end

  describe "valid?/1" do
    test "passes with all required keys + valid role" do
      assert Bokbasen.valid?(@valid) == true
    end

    test "rejects missing required keys" do
      assert {:invalid, missing} = Bokbasen.valid?(%{client_id: "x"})
      assert :api_base in missing
      assert :oauth_token_url in missing
      assert :client_secret in missing
    end

    test "rejects empty-string values" do
      assert {:invalid, missing} = Bokbasen.valid?(%{@valid | client_id: ""})
      assert :client_id in missing
    end

    test "rejects invalid client_role" do
      assert {:invalid, [:client_role]} = Bokbasen.valid?(%{@valid | client_role: "vendor"})
    end

    test "accepts distributor role" do
      assert Bokbasen.valid?(%{@valid | client_role: "distributor"}) == true
    end
  end

  describe "put_credentials/1 + get_credentials/0 round-trip" do
    test "stores and retrieves the same values" do
      assert {:ok, _} = Bokbasen.put_credentials(@valid)

      got = Bokbasen.get_credentials()

      assert got.client_id == @valid.client_id
      assert got.client_secret == @valid.client_secret
      assert got.api_base == @valid.api_base
      assert got.oauth_token_url == @valid.oauth_token_url
      assert got.client_role == "publisher"
    end

    test "rejects invalid input without writing" do
      assert {:error, {:invalid, missing}} = Bokbasen.put_credentials(%{client_id: "only"})

      assert :client_secret in missing
      assert {:error, :not_found} = Plugins.get(@plugin)
    end

    test "missing role defaults to publisher on read" do
      no_role = Map.delete(@valid, :client_role)

      assert {:error, {:invalid, [:client_role]}} = Bokbasen.put_credentials(no_role)
    end
  end

  describe "encryption at rest" do
    test "stored secret value is not present in raw column" do
      marker = "TEST_BOKBASEN_PLAINTEXT_MARKER_42a"
      payload = %{@valid | client_secret: marker}
      assert {:ok, _} = Bokbasen.put_credentials(payload)

      %{rows: [[raw]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT settings FROM plugin_settings WHERE plugin_name = $1",
          [@plugin]
        )

      raw_str =
        cond do
          is_binary(raw) -> raw
          is_list(raw) -> IO.iodata_to_binary(raw)
          true -> inspect(raw)
        end

      refute String.contains?(raw_str, marker)
    end
  end

  describe "env override precedence" do
    test "Application env wins over plugin_settings DB row" do
      assert {:ok, _} = Bokbasen.put_credentials(%{@valid | client_id: "from-db"})

      Application.put_env(:barkpark, @env_module,
        client_id: "from-env",
        client_secret: "from-env-secret",
        api_base: "https://env.example",
        oauth_token_url: "https://env.example/token",
        client_role: "distributor"
      )

      got = Bokbasen.get_credentials()
      assert got.client_id == "from-env"
      assert got.client_secret == "from-env-secret"
      assert got.api_base == "https://env.example"
      assert got.oauth_token_url == "https://env.example/token"
      assert got.client_role == "distributor"
    end

    test "missing env keys fall back to DB per-field" do
      assert {:ok, _} = Bokbasen.put_credentials(@valid)

      Application.put_env(:barkpark, @env_module, client_id: "env-id-only")

      got = Bokbasen.get_credentials()
      assert got.client_id == "env-id-only"
      assert got.client_secret == @valid.client_secret
      assert got.api_base == @valid.api_base
      assert got.oauth_token_url == @valid.oauth_token_url
      assert got.client_role == "publisher"
    end

    test "empty string env value is treated as unset" do
      assert {:ok, _} = Bokbasen.put_credentials(@valid)
      Application.put_env(:barkpark, @env_module, client_id: "")

      assert Bokbasen.get_credentials().client_id == @valid.client_id
    end
  end

  describe "get_credentials/0 with no DB row, no env" do
    test "returns nils + default role; never raises" do
      got = Bokbasen.get_credentials()
      assert got.client_id == nil
      assert got.client_secret == nil
      assert got.api_base == nil
      assert got.oauth_token_url == nil
      assert got.client_role == "publisher"
    end
  end
end
