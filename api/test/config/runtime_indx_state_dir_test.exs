defmodule Barkpark.Config.RuntimeIndxStateDirTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads
  # at eval time (same pattern as RuntimeTaskLeaseTtlTest).
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # task-527b519e47669559: Indx.Persistence's compiled default is priv/indx_state,
  # which a release version bump abandons and a slot flip leaves behind. The
  # runtime override must (a) apply BARKPARK_INDX_STATE_DIR verbatim (expanded),
  # (b) treat an empty value as unset, and (c) when unset in :prod, pick the
  # persistent /var/lib/barkpark/indx-state ONLY when that parent exists — a
  # personal-local :prod boot without it keeps the compiled default.

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
    keys = Map.keys(@prod_env) ++ ~w(BARKPARK_INDX_STATE_DIR)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    System.delete_env("BARKPARK_INDX_STATE_DIR")
    :ok
  end

  defp persistence_dir(env, config_env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    @runtime_exs
    |> Config.Reader.read!(env: config_env)
    |> get_in([:barkpark, Barkpark.Plugins.Indx.Persistence, :dir])
  end

  test "BARKPARK_INDX_STATE_DIR is applied verbatim (expanded) in :prod" do
    assert persistence_dir(%{"BARKPARK_INDX_STATE_DIR" => "/srv/indx/./state"}, :prod) ==
             "/srv/indx/state"
  end

  test "BARKPARK_INDX_STATE_DIR is honoured in :dev too (all envs)" do
    assert persistence_dir(%{"BARKPARK_INDX_STATE_DIR" => "/srv/indx/state"}, :dev) ==
             "/srv/indx/state"
  end

  test "an EMPTY value is unset, not a relative-path dir named \"\"" do
    expected = if File.dir?("/var/lib/barkpark"), do: "/var/lib/barkpark/indx-state", else: nil
    assert persistence_dir(%{"BARKPARK_INDX_STATE_DIR" => ""}, :prod) == expected
  end

  test "unset in :prod picks /var/lib/barkpark/indx-state only when that parent exists" do
    expected = if File.dir?("/var/lib/barkpark"), do: "/var/lib/barkpark/indx-state", else: nil
    assert persistence_dir(%{}, :prod) == expected
  end

  test "unset in :dev leaves the compiled default alone (no :dir key at all)" do
    assert persistence_dir(%{}, :dev) == nil
  end
end
