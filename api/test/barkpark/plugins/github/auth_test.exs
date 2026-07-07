defmodule Barkpark.Plugins.Github.AuthTest do
  # async: false — Auth is a singleton GenServer and these tests mutate the
  # shared `Application.env` GitHub config key.
  use Barkpark.DataCase, async: false

  alias Barkpark.Plugins.Github.Auth
  alias Barkpark.Plugins.Github.Errors.AuthError
  alias Barkpark.Plugins.Settings, as: Plugins

  @config_key Barkpark.Plugins.Github
  @plugin "github"
  @app_id "123456"
  @installation_id "987654"

  setup do
    # Auth runs in its own process; share the sandbox connection so the creds
    # resolver's plugin_settings read reaches the test DB.
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    prev = Application.get_env(:barkpark, @config_key)
    Application.delete_env(:barkpark, @config_key)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, @config_key, prev),
        else: Application.delete_env(:barkpark, @config_key)
    end)

    {:ok, pem: pem}
  end

  defp put_env(kw), do: Application.put_env(:barkpark, @config_key, kw)

  describe "config/0 (delegates to Settings.get_credentials/0)" do
    test "returns the resolved creds map from env", %{pem: pem} do
      put_env(app_id: @app_id, installation_id: @installation_id, private_key: pem)

      cfg = Auth.config()
      assert cfg[:app_id] == @app_id
      assert cfg[:installation_id] == @installation_id
      assert cfg[:private_key] == pem
    end

    test "falls back to the encrypted plugin_settings row when env is blank" do
      assert {:ok, _} =
               Plugins.put(@plugin, %{
                 "app_id" => "db-app",
                 "installation_id" => "db-install"
               })

      cfg = Auth.config()
      assert cfg[:app_id] == "db-app"
      assert cfg[:installation_id] == "db-install"
    end
  end

  describe "build_app_jwt/2" do
    test "mints a 3-part RS256 JWT from a valid PEM", %{pem: pem} do
      assert {:ok, jwt} = Auth.build_app_jwt(@app_id, pem)
      assert [_h, _p, _s] = String.split(jwt, ".")
    end

    test "returns :error on an unparseable key" do
      assert :error =
               Auth.build_app_jwt(
                 @app_id,
                 "-----BEGIN RSA PRIVATE KEY-----\nnope\n-----END RSA PRIVATE KEY-----"
               )
    end
  end

  describe "token/0 fail-closed on missing creds (no HTTP)" do
    setup %{pem: pem} do
      # Auth is a boot-started singleton (register_workers/1); reset its cache
      # rather than starting a second (name-colliding) instance.
      Auth.invalidate()
      {:ok, pem: pem}
    end

    test "missing app_id → AuthError before any HTTP", %{pem: pem} do
      put_env(installation_id: @installation_id, private_key: pem)
      Auth.invalidate()

      assert {:error, %AuthError{status: 0, message: "GitHub App ID not configured"}} =
               Auth.token()
    end

    test "missing installation_id → AuthError", %{pem: pem} do
      put_env(app_id: @app_id, private_key: pem)
      Auth.invalidate()

      assert {:error, %AuthError{status: 0, message: "GitHub installation ID not configured"}} =
               Auth.token()
    end

    test "missing private_key → AuthError" do
      put_env(app_id: @app_id, installation_id: @installation_id)
      Auth.invalidate()

      assert {:error, %AuthError{status: 0, message: "GitHub App private key not configured"}} =
               Auth.token()
    end
  end

  describe "invalidate/0" do
    test "returns :ok" do
      assert :ok = Auth.invalidate()
    end
  end
end
