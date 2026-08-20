defmodule Barkpark.Config.RuntimeTaskLeaseTtlTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads
  # at eval time (same pattern as RuntimeUrlPortTest / RuntimeMailerTest).
  use ExUnit.Case, async: false

  @config_exs Path.join(File.cwd!(), "config/config.exs")
  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # BARKPARK_TASK_LEASE_TTL_SECONDS lets an operator retune the crashed-agent
  # lease TTL per-fleet without a rebuild. The compiled default (config.exs)
  # is 2700 s / 45 min, sized to real agent work; the override must apply a
  # positive integer verbatim and otherwise leave the compiled default alone.

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
    keys = Map.keys(@prod_env) ++ ~w(BARKPARK_TASK_LEASE_TTL_SECONDS)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    System.delete_env("BARKPARK_TASK_LEASE_TTL_SECONDS")
    :ok
  end

  # Mirror the real boot order: config.exs sets the compiled default, then
  # runtime.exs applies the env override on top. Merging both is what proves
  # BOTH "default is 2700" and "the env var overrides it at runtime."
  defp ttl_config(env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    base = Config.Reader.read!(@config_exs, env: :prod)
    runtime = Config.Reader.read!(@runtime_exs, env: :prod)

    Config.Reader.merge(base, runtime)
    |> get_in([:barkpark, :task_lease_ttl_seconds])
  end

  test "compiled default (env unset) is 2700 s" do
    assert ttl_config(%{}) == 2700
  end

  test "BARKPARK_TASK_LEASE_TTL_SECONDS override is applied verbatim" do
    assert ttl_config(%{"BARKPARK_TASK_LEASE_TTL_SECONDS" => "600"}) == 600
  end

  test "empty override keeps the compiled default" do
    assert ttl_config(%{"BARKPARK_TASK_LEASE_TTL_SECONDS" => ""}) == 2700
  end

  test "non-integer override keeps the compiled default" do
    assert ttl_config(%{"BARKPARK_TASK_LEASE_TTL_SECONDS" => "banana"}) == 2700
  end

  test "non-positive override keeps the compiled default" do
    assert ttl_config(%{"BARKPARK_TASK_LEASE_TTL_SECONDS" => "0"}) == 2700
    assert ttl_config(%{"BARKPARK_TASK_LEASE_TTL_SECONDS" => "-5"}) == 2700
  end
end
