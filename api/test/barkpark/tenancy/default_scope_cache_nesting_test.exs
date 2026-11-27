defmodule Barkpark.Tenancy.DefaultScopeCacheNestingTest do
  @moduledoc """
  task-5c41ef4f5b3f11b2 (#29077 review, check 4, P4b): `DefaultScopeCache.transaction/2`
  busts in its `after`. Nested in a plain outer `Repo.transaction`, that runs
  before the outer COMMIT: a concurrent load in between reads the committed
  old seat and keeps it for the TTL, after the outer COMMIT took it away.
  The wrapper now refuses to nest in a plain transaction, before anything is
  written. Nested in itself it runs, and the outer wrapper's bust covers it.

  The ordering is shown in the sandbox: the reviewer's probe needed
  committing connections (`Sandbox.mode(:auto)`), which delete the default
  workspace for real. Here a concurrent reader's load is a `fetch/2` whose
  loader returns the committed old row, as a READ COMMITTED reader sees it.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Repo, Tenancy}
  alias Barkpark.Tenancy.{DefaultScopeCache, Workspace}

  setup do
    previous = Application.get_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)

    on_exit(fn ->
      DefaultScopeCache.invalidate()

      case previous do
        nil -> Application.delete_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
        value -> Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, value)
      end
    end)

    {ws, _project} = ensure_default_scope!()
    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    %{ws: ws}
  end

  defp stored_default do
    Repo.one(from(w in Workspace, where: w.is_default == true, select: w.id))
  end

  defp id(nil), do: nil
  defp id(%{id: id}), do: id

  # A reader on another connection, between the writer's inner bust and its
  # outer COMMIT: it reads the committed old seat and caches it.
  defp concurrent_load(ws), do: DefaultScopeCache.fetch(:default_workspace, fn -> ws end)

  # The guard reads `Repo.in_transaction?/0`; were it true at a test's top
  # level, the guard would refuse in every sandboxed test.
  test "the sandbox leaves Repo.in_transaction? false at a test's top level" do
    refute Repo.in_transaction?()
    assert {:ok, true} = Repo.transaction(fn -> Repo.in_transaction?() end)
    refute Repo.in_transaction?()
  end

  test "at top level the wrapper runs and busts after it", %{ws: ws} do
    assert {:ok, :done} =
             DefaultScopeCache.transaction(fn ->
               concurrent_load(ws)
               :done
             end)

    assert :ets.lookup(:barkpark_tenancy_default_scope_cache, :default_workspace) == []
  end

  test "P4b: delete_workspace nested in a plain Repo.transaction leaves no stale default seat",
       %{ws: ws} do
    outcome =
      try do
        Repo.transaction(fn ->
          {:ok, _} = Tenancy.delete_workspace(ws)
          concurrent_load(ws)
          :committed
        end)
      rescue
        e in ArgumentError -> {:refused, Exception.message(e)}
      end

    # On main the delete commits after the inner bust, and the reader's
    # entry serves the deleted seat.
    assert id(Tenancy.get_default_workspace()) == stored_default(),
           "the cache serves another seat than the store holds after the outer COMMIT"

    assert {:refused, message} = outcome
    assert message =~ "nested in a plain Repo.transaction"
    assert stored_default() == ws.id, "the refused delete wrote"
  end

  test "an Ecto.Multi step into the wrapper is refused the same way", %{ws: ws} do
    multi =
      Ecto.Multi.run(Ecto.Multi.new(), :delete, fn _repo, _changes ->
        Tenancy.delete_workspace(ws)
      end)

    assert_raise ArgumentError, ~r/nested in a plain Repo.transaction/, fn ->
      Repo.transaction(multi)
    end

    assert stored_default() == ws.id
  end

  test "nested in the wrapper itself it runs, and the outer bust comes after the inner",
       %{ws: ws} do
    assert {:ok, {:ok, :inner}} =
             DefaultScopeCache.transaction(fn ->
               inner = DefaultScopeCache.transaction(fn -> :inner end)
               # Between the inner bust and the outer COMMIT.
               concurrent_load(ws)
               inner
             end)

    assert :ets.lookup(:barkpark_tenancy_default_scope_cache, :default_workspace) == [],
           "the outer wrapper did not bust after the inner one"
  end

  test "a raise inside the wrapper leaves no depth behind", %{ws: ws} do
    assert_raise RuntimeError, fn ->
      DefaultScopeCache.transaction(fn -> raise "boom" end)
    end

    assert_raise ArgumentError, fn ->
      Repo.transaction(fn -> DefaultScopeCache.transaction(fn -> :inner end) end)
    end

    assert {:ok, :ok} = DefaultScopeCache.transaction(fn -> :ok end)
    assert stored_default() == ws.id
  end
end
