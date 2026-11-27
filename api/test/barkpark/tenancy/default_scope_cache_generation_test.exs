defmodule Barkpark.Tenancy.DefaultScopeCacheGenerationTest do
  @moduledoc """
  task-72afe5c9503381da: a load that read the rows before an `invalidate/0`
  and stored after it (a read before COMMIT, the bust after COMMIT) cached
  the old seat for the TTL. A load stores only when no invalidate landed
  between its start and its store.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Tenancy.DefaultScopeCache

  @key :generation_test_seat

  setup do
    previous = Application.get_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()

    on_exit(fn ->
      DefaultScopeCache.invalidate()

      case previous do
        nil -> Application.delete_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
        value -> Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, value)
      end
    end)
  end

  defp fresh, do: DefaultScopeCache.fetch(@key, fn -> :new end)

  test "an invalidate during the load: the old value is returned, not stored" do
    old =
      DefaultScopeCache.fetch(@key, fn ->
        DefaultScopeCache.invalidate()
        :old
      end)

    assert old == :old
    # On main: :old, cached for the TTL.
    assert fresh() == :new
  end

  test "another process invalidates while the load waits: the old value is not stored" do
    test = self()

    loader =
      Task.async(fn ->
        DefaultScopeCache.fetch(@key, fn ->
          send(test, :read)

          receive do
            :store -> :old
          end
        end)
      end)

    assert_receive :read, 1_000
    DefaultScopeCache.invalidate()
    send(loader.pid, :store)

    assert Task.await(loader) == :old
    assert fresh() == :new
  end

  test "a load with no invalidate is cached" do
    assert DefaultScopeCache.fetch(@key, fn -> :first end) == :first
    assert DefaultScopeCache.fetch(@key, fn -> flunk("cache missed") end) == :first
  end

  test "a load after an invalidate is cached" do
    assert DefaultScopeCache.fetch(@key, fn -> :first end) == :first
    DefaultScopeCache.invalidate()
    assert fresh() == :new
    assert DefaultScopeCache.fetch(@key, fn -> flunk("cache missed") end) == :new
  end
end
