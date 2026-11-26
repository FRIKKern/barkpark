defmodule Barkpark.Tenancy.WorkspaceBundleSeatCacheTest do
  @moduledoc """
  task-e9972c538ed9209f: a merge-import that takes the Default seat (the
  `bp cloud support add --ws default` flow) moved the seat and busted
  `DefaultScopeCache` INSIDE its transaction. A read between that bust and
  COMMIT still sees the old seat, the committed one, and caches it again; the
  cache then served the evicted shell for its TTL, and `AssignDefaultScope`
  scoped every flat request to it. The bust now runs after COMMIT.

  The sandbox shares one connection, so no second process can see the
  pre-COMMIT state. The concurrent read is staged at the documented
  `[:barkpark, :workspace_bundle, :import, :seat_settled]` event, which fires
  after the seat moves and before COMMIT: the handler caches what such a read
  returns, the old seat.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Repo, Seeds, Tenancy}
  alias Barkpark.Tenancy.{DefaultScopeCache, Workspace, WorkspaceBundle}
  alias Barkpark.Tenancy.WorkspaceBundle.Archive

  @event [:barkpark, :workspace_bundle, :import, :seat_settled]

  setup do
    previous = Application.get_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
    handler = "seat-cache-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :telemetry.detach(handler)
      DefaultScopeCache.invalidate()

      case previous do
        nil -> Application.delete_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
        value -> Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, value)
      end
    end)

    # Vacate the seat (workspace_bundle_reserved_slug_test.exs explains why a
    # rename alone no longer does).
    {_n, _} =
      Repo.update_all(from(w in Workspace, where: w.slug == "default"),
        set: [slug: "parked-for-seat-cache-test"]
      )

    {_n, _} =
      Repo.update_all(from(w in Workspace, where: w.is_default == true), set: [is_default: false])

    DefaultScopeCache.invalidate()
    refute Tenancy.get_default_workspace()
    %{handler: handler}
  end

  test "after an import takes the seat, the cache names the imported workspace, not the shell",
       %{handler: handler} do
    {src, bundle, manifest} = exported_default_source!()
    purge!(src, manifest)

    # SupportAdminTokenStep: an empty default shell holds the seat.
    _ = Seeds.Shared.ensure_default_scope()
    shell = Tenancy.get_default_workspace()
    refute shell.id == src.id

    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    test_pid = self()

    # The concurrent read: before COMMIT the committed seat is still the shell.
    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measure, meta, _config ->
          cached = DefaultScopeCache.fetch(:default_workspace, fn -> shell end)
          send(test_pid, {:seat_settled, meta, cached.id})
        end,
        nil
      )

    assert {:ok, _stats} =
             WorkspaceBundle.import_bundle(bundle, mode: :merge, expected_root_slug: "default")

    assert_received {:seat_settled, %{adopted: :seat_evicted, workspace_id: ws_id}, read_id}
    assert ws_id == src.id
    assert read_id == shell.id, "the staged read cached the old seat"

    assert Tenancy.get_default_workspace().id == src.id,
           "the cache still serves the evicted shell after COMMIT"
  end

  test "control: an import that does not take the seat leaves it where it was", %{
    handler: handler
  } do
    holder = create_workspace!(unique("holder"))

    {1, _} =
      Repo.update_all(from(w in Workspace, where: w.id == ^holder.id), set: [is_default: true])

    src = create_workspace!(unique("src"))
    proj = create_project!(src, unique("srcproj"))
    {:ok, _} = create_document_in!(src, proj, "post", %{"doc_id" => unique("d")}, "test")
    {:ok, bundle} = WorkspaceBundle.export(src.id)
    {manifest, _} = Archive.unpack(bundle)
    purge!(src, manifest)

    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    assert Tenancy.get_default_workspace().id == holder.id
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _e, _m, meta, _c -> send(test_pid, {:seat_settled, meta}) end,
        nil
      )

    assert {:ok, _} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

    assert_received {:seat_settled, %{adopted: :ok}}
    assert Tenancy.get_default_workspace().id == holder.id
  end

  # A `default`-slugged source with one document, exported (the slug is stamped
  # after creation, as in workspace_bundle_reserved_slug_test.exs).
  defp exported_default_source! do
    src = create_workspace!(unique("src"))
    proj = create_project!(src, unique("srcproj"))
    {:ok, _} = create_document_in!(src, proj, "post", %{"doc_id" => unique("d")}, "test")
    {1, _} = Repo.update_all(from(w in Workspace, where: w.id == ^src.id), set: [slug: "default"])
    {:ok, bundle} = WorkspaceBundle.export(src.id)
    {manifest, _} = Archive.unpack(bundle)
    {Repo.get!(Workspace, src.id), bundle, manifest}
  end

  # Delete the source, then sweep the manifest's E1 members by workspace_id
  # (`audit_events` has no FK; see workspace_bundle_reserved_slug_test.exs).
  defp purge!(%Workspace{} = ws, manifest) do
    {:ok, _} = Tenancy.delete_workspace(ws)
    Repo.query!("SET session_replication_role = replica", [])

    try do
      for %{"partition" => "E1", "name" => table} <- manifest["tables"] do
        Repo.query!(
          ~s(DELETE FROM "#{String.replace(table, "\"", "\"\"")}" WHERE workspace_id = $1::text::uuid),
          [ws.id]
        )
      end
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
