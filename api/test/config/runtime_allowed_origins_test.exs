defmodule Barkpark.Config.RuntimeAllowedOriginsTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads at
  # eval time (same pattern as RuntimeObanPoolSizeTest).
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "cms.example.no",
    "PHX_SCHEME" => "https"
  }

  @vars ~w(BARKPARK_ALWAYS_ALLOWED_ORIGINS BARKPARK_EXTRA_ORIGINS BARKPARK_SCIM_DOCUMENTATION_URI)

  @builtin ["https://barkpark.cloud", "https://www.barkpark.cloud", "https://*.vercel.app"]

  setup do
    keys = Map.keys(@prod_env) ++ @vars
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    Enum.each(@vars, &System.delete_env/1)
    :ok
  end

  defp barkpark_config(env_vars) do
    Enum.each(env_vars, fn {k, v} -> System.put_env(k, v) end)
    Config.Reader.read!(@runtime_exs, env: :prod)[:barkpark]
  end

  defp check_origin(config), do: config[BarkparkWeb.Endpoint][:check_origin]

  # Phoenix's own socket origin check, given this check_origin list. A fresh
  # handler name per call, because Phoenix caches the parsed list per handler.
  defp socket_allows?(origins, origin) do
    handler = :"origin_test_#{System.unique_integer([:positive])}"

    conn =
      Plug.Test.conn(:get, "https://cms.example.no/live/websocket")
      |> Plug.Conn.put_req_header("origin", origin)
      |> Phoenix.Socket.Transport.check_origin(
        handler,
        BarkparkWeb.Endpoint,
        [check_origin: origins],
        & &1
      )

    not conn.halted
  end

  test "unset keeps today's list, and DatasetCors gets no override" do
    config = barkpark_config(%{})

    assert check_origin(config) == ["https://cms.example.no" | @builtin]
    refute Keyword.has_key?(config, :always_allowed_origins)
    refute Keyword.has_key?(config, :scim_documentation_uri)
  end

  test "set, the CSV replaces the built-in list and the socket check refuses the old entries" do
    config =
      barkpark_config(%{
        "BARKPARK_ALWAYS_ALLOWED_ORIGINS" =>
          "https://pensum.example.no, https://studio.example.no",
        "BARKPARK_EXTRA_ORIGINS" => "http://10.0.0.5"
      })

    origins = ["https://pensum.example.no", "https://studio.example.no"]
    assert config[:always_allowed_origins] == origins
    assert check_origin(config) == ["https://cms.example.no"] ++ origins ++ ["http://10.0.0.5"]

    refute socket_allows?(check_origin(config), "https://www.barkpark.cloud")
    refute socket_allows?(check_origin(config), "https://x.vercel.app")
    assert socket_allows?(check_origin(config), "https://pensum.example.no")
    assert socket_allows?(check_origin(config), "https://cms.example.no")
  end

  test "a Vercel-hosted front end stays expressible" do
    config = barkpark_config(%{"BARKPARK_ALWAYS_ALLOWED_ORIGINS" => "https://*.vercel.app"})

    assert socket_allows?(check_origin(config), "https://pensum-git-main.vercel.app")
    refute socket_allows?(check_origin(config), "https://www.barkpark.cloud")
  end

  test "BARKPARK_SCIM_DOCUMENTATION_URI sets :scim_documentation_uri" do
    config =
      barkpark_config(%{"BARKPARK_SCIM_DOCUMENTATION_URI" => "https://docs.example.no/scim"})

    assert config[:scim_documentation_uri] == "https://docs.example.no/scim"
  end
end
