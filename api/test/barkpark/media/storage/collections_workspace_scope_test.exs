defmodule Barkpark.Media.Storage.CollectionsWorkspaceScopeTest do
  @moduledoc """
  Tenancy regression for `Collections.assets/3` (task-f42f7f9c2d10f0bb).

  The GATE was scoped and the PAYLOAD was not. `assets/3` resolves the
  collection through `get/3`, which passes `@scope_keys` to
  `Content.get_document` — correctly workspace-scoped. It then built the
  search opts through a `Keyword.take/2` allowlist that did NOT carry
  `:workspace_id` or `:project_id`, so the controller's real scope
  (`media_collections_controller.ex` `assets/2`) was dropped on the floor.
  `Search.build_query/2` then read `nil` for both and handed them to
  `scope_to_workspace_or_global/3`, whose nil arm returns the query
  UNTOUCHED — an unscoped media search over the dataset STRING.

  For a `virtual` collection nothing else narrows the read (the `folder`
  branch at least pins `:collection`), so rows, `total`, AND every facet
  bucket spanned every workspace sharing that dataset string.

  These tests are written against the `virtual` branch for that reason, and
  they assert the AGGREGATES as well as the rows: a fix validated only on the
  row set looks adequate while `total` and the facet counts still span
  tenants.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Media.Storage.Collections

  @dataset "test"
  @asset_type "mediaAsset"
  @collection_type "mediaCollection"

  # Insert the asset Document directly through the changeset (no hook
  # pipeline), stamped to the same workspace/project as the blob — the shape
  # `media_search_scope_test.exs` already uses for this class.
  defp link_asset!(media_file, workspace, project, tags) do
    suffix = System.unique_integer([:positive])

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: "asset #{suffix}",
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file.id, "tags" => tags},
        workspace_id: workspace.id,
        project_id: project && project.id
      })
      |> Barkpark.Repo.insert()

    doc
  end

  # A VIRTUAL collection with an EMPTY filter: `virtual_to_search_opts/2`
  # adds no narrowing key, and the virtual branch never sets `:collection`,
  # so the only thing that can bound this read is the tenancy scope. That is
  # precisely the door under test.
  defp virtual_collection!(workspace, project) do
    suffix = System.unique_integer([:positive])

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "coll-#{suffix}",
        type: @collection_type,
        dataset: @dataset,
        title: "virtual collection #{suffix}",
        status: "draft",
        rev: "rc#{suffix}",
        content: %{"kind" => "virtual", "virtualFilter" => %{}},
        workspace_id: workspace.id,
        project_id: project && project.id
      })
      |> Barkpark.Repo.insert()

    doc
  end

  setup do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    # Both workspaces share the SAME dataset string — isolation must come from
    # workspace_id, never from the dataset leaf.
    {:ok, file_a} = create_media_file_in!(ws_a, proj_a, %{}, @dataset)
    link_asset!(file_a, ws_a, proj_a, ["a-only", "shared"])

    {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @dataset)
    link_asset!(file_b, ws_b, proj_b, ["b-only", "shared"])

    collection = virtual_collection!(ws_a, proj_a)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]

    %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      file_a: file_a,
      file_b: file_b,
      collection: collection,
      scope_a: scope_a
    }
  end

  # ── The anti-vacuity floor ────────────────────────────────────────────────
  #
  # Everything below is a `refute … in …`, and a refute passes trivially when
  # the read returns nothing. So first PROVE the fixture can actually produce
  # a foreign row: an unscoped search over this dataset must see BOTH files,
  # and the scoped gate must resolve the collection. Without these two, a
  # green below would be evidence of nothing.

  test "FLOOR: the fixture can produce a foreign row, and the gate resolves",
       %{file_a: file_a, file_b: file_b, collection: collection, scope_a: scope_a} do
    {files, total, _facets, _meta} = Search.search(@dataset, [])
    ids = Enum.map(files, & &1.id)

    assert file_a.id in ids

    assert file_b.id in ids,
           "the fixture cannot produce a cross-workspace row, so every refute " <>
             "below would pass vacuously"

    assert total >= 2

    # And the collection gate itself must pass for workspace A, or `assets/3`
    # returns its `{[], 0, %{}}` else-branch and again proves nothing.
    assert {:ok, _} = Collections.get(collection.doc_id, @dataset, scope_a)
  end

  # ── Rows ──────────────────────────────────────────────────────────────────

  test "a virtual collection's ROWS exclude another workspace's assets",
       %{file_a: file_a, file_b: file_b, collection: collection, scope_a: scope_a} do
    {files, _total, _facets} = Collections.assets(collection.doc_id, @dataset, scope_a)
    ids = Enum.map(files, & &1.id)

    assert file_a.id in ids

    refute file_b.id in ids,
           "CROSS-WORKSPACE LEAK: workspace A's virtual collection returned " <>
             "workspace B's media file — the tenancy keys never reached the search"
  end

  # ── Aggregates: total ─────────────────────────────────────────────────────

  test "a virtual collection's TOTAL counts only the caller's workspace",
       %{collection: collection, scope_a: scope_a} do
    {_files, total, _facets} = Collections.assets(collection.doc_id, @dataset, scope_a)

    assert total == 1,
           "expected workspace A's own asset only, got total=#{total} — the count " <>
             "spans every workspace sharing the dataset string even when the row " <>
             "set looks right"
  end

  # ── Aggregates: facet buckets ─────────────────────────────────────────────

  test "a virtual collection's FACET BUCKETS exclude another workspace's values",
       %{collection: collection, scope_a: scope_a} do
    {_files, _total, facets} =
      Collections.assets(collection.doc_id, @dataset, [facets: ["tags"]] ++ scope_a)

    values = facets["tags"] |> Enum.map(& &1.value)

    assert "a-only" in values

    refute "b-only" in values,
           "CROSS-WORKSPACE FACET LEAK: workspace A's tags facet #{inspect(values)} " <>
             "included workspace B's exclusive tag"
  end

  test "a shared facet VALUE is not double-counted across workspaces",
       %{collection: collection, scope_a: scope_a} do
    {_files, _total, facets} =
      Collections.assets(collection.doc_id, @dataset, [facets: ["tags"]] ++ scope_a)

    shared = Enum.find(facets["tags"] || [], &(&1.value == "shared"))

    assert shared, "expected a 'shared' tag bucket for workspace A"

    assert shared.count == 1,
           "expected workspace A's 'shared' count to be 1 (its own asset only), got " <>
             "#{shared.count} — B's matching asset leaked into the bucket COUNT even " <>
             "though the bucket VALUE is legitimately shared"
  end

  # ── Every gate key rides through, not just the two that leaked ────────────
  #
  # `@scope_keys` (the collection GATE's list) carries four keys. The search
  # take now derives its tenancy half from that same constant rather than a
  # hand-copied pair, so the two doors on this module cannot drift. This is
  # the behavioural half of that: hand `assets/3` every key the gate accepts
  # and the read must still be bounded — a take that dropped them would come
  # back with workspace B's row.
  #
  # (`:grant_scoped` and `:caller_context` are not consumed by the media
  # search chain today; they are passed because the gate defines them as
  # tenancy, and a key that should arrive is exactly what went missing here.)

  test "passing every gate key still bounds the read to the caller's workspace",
       %{collection: collection, ws_a: ws_a, proj_a: proj_a, file_a: file_a} do
    opts = [
      workspace_id: ws_a.id,
      project_id: proj_a.id,
      grant_scoped: false,
      caller_context: nil
    ]

    {files, total, _facets} = Collections.assets(collection.doc_id, @dataset, opts)

    assert total == 1
    assert Enum.map(files, & &1.id) == [file_a.id]
  end
end
