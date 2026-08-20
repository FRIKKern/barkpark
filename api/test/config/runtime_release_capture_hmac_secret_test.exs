defmodule Barkpark.Config.RuntimeReleaseCaptureHmacSecretTest do
  use ExUnit.Case, async: false

  @config_exs Path.join(File.cwd!(), "config/config.exs")
  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")
  @secret_env "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"

  @prod_env %{
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  setup do
    keys = Map.keys(@prod_env) ++ [@secret_env, "BARKPARK_PAPER_CANVAS"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(@prod_env, fn {key, value} -> System.put_env(key, value) end)
    System.delete_env(@secret_env)
    :ok
  end

  test "production refuses a missing or shorter-than-32-byte release HMAC secret" do
    assert_raise RuntimeError,
                 "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must contain at least 32 bytes",
                 &read_runtime!/0

    System.put_env(@secret_env, String.duplicate("x", 31))

    assert_raise RuntimeError,
                 "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must contain at least 32 bytes",
                 &read_runtime!/0
  end

  test "production accepts exactly 32 bytes and exposes the release authority" do
    secret = String.duplicate("x", 32)
    System.put_env(@secret_env, secret)

    runtime = read_runtime!()

    assert get_in(runtime, [:barkpark, :cycle_release_capture_hmac_secret]) == secret
  end

  defp read_runtime! do
    base = Config.Reader.read!(@config_exs, env: :prod)
    runtime = Config.Reader.read!(@runtime_exs, env: :prod)
    Config.Reader.merge(base, runtime)
  end
end
