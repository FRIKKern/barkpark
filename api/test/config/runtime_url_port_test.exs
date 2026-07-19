defmodule Barkpark.Config.RuntimeUrlPortTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads
  # at eval time (same pattern as RuntimeMailerTest).
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # The PUBLIC url port must follow the scheme (Caddy fronts 443/80; the app
  # listens on PORT 4000/4001) — baking PORT into `url:` broke every absolute
  # URL: emailed reset/confirm links and the /login cloud deep link carried
  # ":4000". PHX_PORT stays as the explicit override for a genuinely
  # nonstandard public port.

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  setup do
    keys = Map.keys(@prod_env) ++ ~w(PHX_SCHEME PHX_PORT PORT)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    Enum.each(~w(PHX_SCHEME PHX_PORT PORT), &System.delete_env/1)
    :ok
  end

  defp url_config(env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    @runtime_exs
    |> Config.Reader.read!(env: :prod)
    |> get_in([:barkpark, BarkparkWeb.Endpoint, :url])
  end

  defp capabilities_base_url(env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    @runtime_exs
    |> Config.Reader.read!(env: :prod)
    |> get_in([:barkpark, :capabilities_base_url])
  end

  test "https + internal PORT 4001 → public url port 443 (no :4001 leak)" do
    url = url_config(%{"PHX_SCHEME" => "https", "PORT" => "4001"})
    assert url[:port] == 443
    assert url[:scheme] == "https"
    assert url[:host] == "guerrilla.barkpark.cloud"
  end

  test "http defaults the public url port to 80, not the listen PORT" do
    url = url_config(%{"PORT" => "4000"})
    assert url[:port] == 80
    assert url[:scheme] == "http"
  end

  test "PHX_PORT overrides for a genuinely nonstandard public port" do
    url = url_config(%{"PHX_SCHEME" => "https", "PHX_PORT" => "8443", "PORT" => "4000"})
    assert url[:port] == 8443
  end

  test "capabilities base URL follows the public scheme and host" do
    base_url = capabilities_base_url(%{"PHX_SCHEME" => "https"})
    previous = Application.fetch_env(:barkpark, :capabilities_base_url)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, :capabilities_base_url, value)
        :error -> Application.delete_env(:barkpark, :capabilities_base_url)
      end
    end)

    Application.put_env(:barkpark, :capabilities_base_url, base_url)
    manifest = Barkpark.Plugins.Capabilities.manifest("admin", project: false)

    assert base_url == "https://guerrilla.barkpark.cloud"
    assert get_in(manifest, ["server", "base_url"]) == base_url
    assert Barkpark.Api.OpenApi.spec(manifest)["servers"] == [%{"url" => base_url}]
  end
end
