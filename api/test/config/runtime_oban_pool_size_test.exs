defmodule Barkpark.Config.RuntimeObanPoolSizeTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads at
  # eval time (same pattern as RuntimeTaskLeaseTtlTest).
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

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
    keys = Map.keys(@prod_env) ++ ~w(OBAN_POOL_SIZE)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    System.delete_env("OBAN_POOL_SIZE")
    :ok
  end

  defp oban_pool_size(env, env_vars \\ %{}) do
    Enum.each(env_vars, fn {k, v} -> System.put_env(k, v) end)

    @runtime_exs
    |> Config.Reader.read!(env: env)
    |> get_in([:barkpark, :oban_pool_size])
  end

  test "prod default (env unset) is 4" do
    assert oban_pool_size(:prod) == 4
  end

  test "OBAN_POOL_SIZE overrides it verbatim, whitespace-trimmed" do
    assert oban_pool_size(:prod, %{"OBAN_POOL_SIZE" => " 6 "}) == 6
  end

  test "OBAN_POOL_SIZE=0 disables the partition (the escape hatch)" do
    assert oban_pool_size(:prod, %{"OBAN_POOL_SIZE" => "0"}) == 0
  end

  test "a malformed value refuses boot rather than degrading silently" do
    for bad <- ["four", "-1", "4.5", ""] do
      System.put_env("OBAN_POOL_SIZE", bad)

      assert_raise RuntimeError, ~r/OBAN_POOL_SIZE/, fn ->
        Config.Reader.read!(@runtime_exs, env: :prod)
      end
    end
  end

  test ":test sets nothing, so Barkpark.Repo.job_pool_size/0 answers 0 under the sandbox" do
    assert oban_pool_size(:test, %{"OBAN_POOL_SIZE" => "4"}) == nil
    assert Barkpark.Repo.job_pool_size() == 0
  end
end
