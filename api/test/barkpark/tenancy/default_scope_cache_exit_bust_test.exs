defmodule Barkpark.Tenancy.DefaultScopeCacheExitBustTest do
  @moduledoc """
  task-2d336fb1b6c90c7a: `DefaultScopeCache` busts that an exit skipped.

  * A raise inside the import transaction rolls the seat back, but the bust
    ran only when `import_transaction/4` returned. A read the import's own
    process made after the seat moved (it sees the uncommitted row) kept the
    rolled-back seat cached for the TTL.
  * `fetch(:__generation__, loader)` stored an entry over the generation
    counter, and the next `invalidate/0` then raised.
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

  test "an import that raises after the seat moved leaves no rolled-back seat cached",
       %{handler: handler} do
    {src, bundle, manifest} = exported_default_source!()
    purge!(src, manifest)

    _ = Seeds.Shared.ensure_default_scope()
    shell = Tenancy.get_default_workspace()
    refute shell.id == src.id

    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    test_pid = self()

    # A read by the import's own process after the seat moved: it sees the
    # uncommitted seat, the imported workspace, and caches it.
    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measure, _meta, _config ->
          send(test_pid, {:read, Tenancy.get_default_workspace().id})
        end,
        nil
      )

    # The operator grant runs after the seat settles; a principal id that is
    # not a UUID raises inside the transaction, which rolls back.
    assert_raise Ecto.ChangeError, fn ->
      WorkspaceBundle.import_bundle(bundle,
        mode: :merge,
        expected_root_slug: "default",
        grant_admin_to: {"not-a-uuid", "user"}
      )
    end

    assert_received {:read, read_id}
    assert read_id == src.id, "the staged read did not see the moved seat"
    assert Repo.get_by(Workspace, is_default: true).id == shell.id, "the seat did not roll back"

    assert Tenancy.get_default_workspace().id == shell.id,
           "the cache serves the rolled-back seat after the raise"
  end

  test "fetch refuses the generation counter's key, and the counter keeps working" do
    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()

    assert_raise ArgumentError, fn -> DefaultScopeCache.fetch(:__generation__, fn -> :x end) end

    # On main the stored entry clobbered the counter, and this raised.
    assert DefaultScopeCache.invalidate() == :ok
    assert DefaultScopeCache.fetch(:exit_bust_test_key, fn -> :v end) == :v
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
