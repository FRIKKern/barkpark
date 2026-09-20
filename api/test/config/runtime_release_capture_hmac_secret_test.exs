defmodule Barkpark.Config.RuntimeReleaseCaptureHmacSecretTest do
  @moduledoc """
  BARKPARK_RELEASE_CAPTURE_HMAC_SECRET is a FEATURE secret, not a boot secret.

  Until this suite, `config/runtime.exs` raised in `:prod` when the var was
  absent or shorter than 32 bytes. runtime.exs is evaluated for every prod Mix
  invocation — `mix ecto.migrate` included — so that raise made a box without
  the secret unable to migrate and unable to be told its schema was behind. The
  2026-09-19 fleet migration-lag census measured three warm boxes crashlooping
  on `runtime.exs:44` with their schema pinned 28-52 days behind HEAD.

  These tests are the guard: the prod config must LOAD with the var unset (the
  migrate path), and it must not configure the release authority when it does.
  The complementary half — the feature itself refusing —
  lives in `Barkpark.CycleReleaseGateHostileTest`
  ("a missing release-capture HMAC secret refuses the release gate…").
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  # THE MIGRATE PATH. `mix ecto.migrate` under MIX_ENV=prod evaluates exactly
  # this file before it touches the database; if reading it raises, the box can
  # never migrate. This test reds the moment the raise is restored.
  test "the prod config LOADS with the secret unset, so a box without it can still migrate" do
    {runtime, log} = with_log(&read_runtime!/0)

    assert get_in(runtime, [:barkpark, :cycle_release_capture_hmac_secret]) == nil

    assert log =~ "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must be at least 32 bytes"
    assert log =~ "it is not set"
    assert log =~ "release-capture surface is DISABLED"
    assert log =~ ":release_capture_signing_unavailable"
  end

  test "a shorter-than-32-byte secret also loads, warns with the LENGTH, and configures nothing" do
    System.put_env(@secret_env, String.duplicate("x", 31))

    {runtime, log} = with_log(&read_runtime!/0)

    assert get_in(runtime, [:barkpark, :cycle_release_capture_hmac_secret]) == nil
    assert log =~ "got 31 bytes"
    refute log =~ String.duplicate("x", 31)
  end

  test "an empty secret is named as empty, not as unset" do
    System.put_env(@secret_env, "")

    {runtime, log} = with_log(&read_runtime!/0)

    assert get_in(runtime, [:barkpark, :cycle_release_capture_hmac_secret]) == nil
    assert log =~ "it is set but empty"
  end

  test "production accepts exactly 32 bytes, exposes the release authority, and stays silent" do
    secret = String.duplicate("x", 32)
    System.put_env(@secret_env, secret)

    {runtime, log} = with_log(&read_runtime!/0)

    assert get_in(runtime, [:barkpark, :cycle_release_capture_hmac_secret]) == secret
    refute log =~ "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"
  end

  defp read_runtime! do
    base = Config.Reader.read!(@config_exs, env: :prod)
    runtime = Config.Reader.read!(@runtime_exs, env: :prod)
    Config.Reader.merge(base, runtime)
  end
end
