defmodule Barkpark.Config.RuntimeConnectorsOauthTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads
  # at eval time (same pattern as RuntimeTaskLeaseTtlTest / RuntimeUrlPortTest).
  use ExUnit.Case, async: false

  @config_exs Path.join(File.cwd!(), "config/config.exs")
  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # catalog.ex's slack_oauth_config/0 + linear_oauth_config/0 read
  # :slack_client_id / :slack_redirect_uri / :linear_client_id /
  # :linear_redirect_uri from `config :barkpark, Barkpark.Connectors`.
  # runtime.exs (connectors D171) plumbs those from CONNECTORS_SLACK_CLIENT_ID /
  # CONNECTORS_SLACK_REDIRECT_URI / CONNECTORS_LINEAR_CLIENT_ID /
  # CONNECTORS_LINEAR_REDIRECT_URI. Unset ⇒ the key is absent (nil at read) and
  # both cards keep the honest not-configured gate — the compiled config.exs
  # default (bridge_url + connect_secret: nil) is otherwise untouched.

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  @oauth_envs ~w(
    CONNECTORS_SLACK_CLIENT_ID CONNECTORS_SLACK_REDIRECT_URI
    CONNECTORS_LINEAR_CLIENT_ID CONNECTORS_LINEAR_REDIRECT_URI
  )

  setup do
    keys = Map.keys(@prod_env) ++ @oauth_envs
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    Enum.each(@oauth_envs, &System.delete_env/1)
    :ok
  end

  # Mirror the real boot order: config.exs sets the compiled default, then
  # runtime.exs applies the env plumbing on top. Merging both is what proves
  # the OAuth env vars actually reach `config :barkpark, Barkpark.Connectors`.
  defp connectors_config(env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    base = Config.Reader.read!(@config_exs, env: :prod)
    runtime = Config.Reader.read!(@runtime_exs, env: :prod)

    Config.Reader.merge(base, runtime)
    |> get_in([:barkpark, Barkpark.Connectors])
  end

  test "Slack OAuth env vars flow into Barkpark.Connectors config" do
    cfg =
      connectors_config(%{
        "CONNECTORS_SLACK_CLIENT_ID" => "slack-client-123",
        "CONNECTORS_SLACK_REDIRECT_URI" =>
          "https://guerrilla.barkpark.cloud/connectors/oauth/slack/callback"
      })

    assert cfg[:slack_client_id] == "slack-client-123"

    assert cfg[:slack_redirect_uri] ==
             "https://guerrilla.barkpark.cloud/connectors/oauth/slack/callback"
  end

  test "Linear OAuth env vars flow into Barkpark.Connectors config" do
    cfg =
      connectors_config(%{
        "CONNECTORS_LINEAR_CLIENT_ID" => "linear-client-456",
        "CONNECTORS_LINEAR_REDIRECT_URI" =>
          "https://guerrilla.barkpark.cloud/connectors/oauth/linear/callback"
      })

    assert cfg[:linear_client_id] == "linear-client-456"

    assert cfg[:linear_redirect_uri] ==
             "https://guerrilla.barkpark.cloud/connectors/oauth/linear/callback"
  end

  test "unset OAuth env vars leave the keys nil (honest not-configured gate)" do
    cfg = connectors_config(%{})

    assert cfg[:slack_client_id] == nil
    assert cfg[:slack_redirect_uri] == nil
    assert cfg[:linear_client_id] == nil
    assert cfg[:linear_redirect_uri] == nil

    # The compiled default is otherwise untouched — the connect seam still boots.
    assert cfg[:bridge_url] == "http://127.0.0.1:4020/connectors"
  end

  test "empty (blank) OAuth env vars are rejected, not written as empty strings" do
    cfg =
      connectors_config(%{
        "CONNECTORS_SLACK_CLIENT_ID" => "",
        "CONNECTORS_LINEAR_REDIRECT_URI" => "   "
      })

    assert cfg[:slack_client_id] == nil
    assert cfg[:linear_redirect_uri] == nil
  end
end
