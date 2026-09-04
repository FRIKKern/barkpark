defmodule BarkparkWeb.MediaCollectionsShareViewScopeTest do
  @moduledoc """
  Tenancy regression for the ANONYMOUS share-view door
  (`BarkparkWeb.V1.MediaCollectionsController.share_view/2`,
  task-09c411d26528dd86).

  `share_view/2` handed `Collections.assets/3` nothing but the parsed search
  params and a `:limit`. The collection-search take derives its tenancy half
  from `@scope_keys`, so a caller passing no tenancy keys yields none:
  `Media.search_files/2` read a nil `workspace_id`, and
  `Content.Scope.scope_to_workspace_or_global/3`'s nil arm returns the query
  UNTOUCHED — the deliberate all-tenants read. For a `kind: "virtual"`
  collection with an EMPTY `virtualFilter` nothing else narrows the read, so
  the rows, the `total` AND every facet bucket spanned every workspace sharing
  that dataset STRING. The door is reachable with no credential but a resolved
  share token and renders with `sign_urls: true`.

  THE TWO OMISSIONS ON THIS DOOR ARE NOT THE SAME DEFECT, and only one is
  closed here:

    * `scope_opts(conn)` — cross-tenant SCOPING. Genuinely open, and the
      subject of every RED-before assertion below. Note the fix is NOT
      `scope_opts(conn)`: the requester is not the principal here, the TOKEN
      is, so the read is bounded by the SHARE's own workspace/project (carried
      on the resolved collection document), never by whichever tenant the
      request happened to resolve.

    * `visibility_clamp_opts(conn)` — DOCUMENTED-INTENTIONAL and deliberately
      left alone. A resolved share token IS a principal; clamping it to
      `:public` would empty every shared collection of exactly the non-public
      assets being shared. `"the clamp is still not applied"` below pins that
      so a later reading of this row as "add both opts" reds instead of
      breaking every live share link.

  The assertions pin the AGGREGATE as well as the rows, and the facet buckets
  besides: a fix validated only on the row list looks adequate while `total`
  and the facet counts still span tenants.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Media.Storage.Collections

  @dataset "test"
  @asset_type "mediaAsset"
  @collection_type "mediaCollection"

  # Insert the asset Document straight through the changeset (no hook
  # pipeline), stamped to the same workspace/project as the blob — the shape
  # `collections_workspace_scope_test.exs` already uses for this class.
  # `bp_visibility` is the key `maybe_clamp_visibility/2` reads, so a
  # "private" doc here is what the clamp would remove if it were applied.
  defp link_asset!(media_file, workspace, project, tags, visibility) do
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
        content: %{
          "mediaFileId" => media_file.id,
          "tags" => tags,
          "bp_visibility" => visibility
        },
        workspace_id: workspace.id,
        project_id: project && project.id
      })
      |> Barkpark.Repo.insert()

    doc
  end

  # A VIRTUAL collection with an EMPTY filter, carrying a live share link.
  # `virtual_to_search_opts/2` adds no narrowing key and the virtual branch
  # never sets `:collection`, so the ONLY thing that can bound this read is the
  # tenancy scope — which is precisely the door under test. The share link is
  # written into `content` directly rather than through `Share.create/3` so the
  # fixture never depends on the write pipeline; `Share.resolve/2` reads exactly
  # these three keys.
  defp shared_virtual_collection!(workspace, project) do
    suffix = System.unique_integer([:positive])
    token = "sharetok-#{suffix}-#{:erlang.unique_integer([:positive])}"
    expires_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "coll-#{suffix}",
        type: @collection_type,
        dataset: @dataset,
        title: "shared virtual collection #{suffix}",
        status: "draft",
        rev: "rc#{suffix}",
        content: %{
          "kind" => "virtual",
          "virtualFilter" => %{},
          "shareLink" => %{
            "enabled" => true,
            "token" => token,
            "expiresAt" => expires_at
          }
        },
        workspace_id: workspace.id,
        project_id: project && project.id
      })
      |> Barkpark.Repo.insert()

    {doc, token}
  end

  defp share_get(token) do
    scoped_conn()
    |> get("/v1/media/#{@dataset}/share/#{token}")
    |> json_response(200)
  end

  defp hit_ids(%{"result" => %{"hits" => hits}}), do: Enum.map(hits, & &1["id"])

  setup do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    # Both workspaces share the SAME dataset STRING — isolation must come from
    # workspace_id, never from the dataset leaf.
    {:ok, file_a_public} = create_media_file_in!(ws_a, proj_a, %{}, @dataset)
    link_asset!(file_a_public, ws_a, proj_a, ["a-only", "shared"], "public")

    {:ok, file_a_private} = create_media_file_in!(ws_a, proj_a, %{}, @dataset)
    link_asset!(file_a_private, ws_a, proj_a, ["a-private"], "private")

    {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @dataset)
    link_asset!(file_b, ws_b, proj_b, ["b-only", "shared"], "public")

    {collection, token} = shared_virtual_collection!(ws_a, proj_a)

    # The scope the controller now DERIVES from the resolved share record —
    # read off the persisted document, not hand-typed, so the test cannot
    # assert a binding the controller does not actually build.
    share_scope = [workspace_id: collection.workspace_id, project_id: collection.project_id]

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      file_a_public: file_a_public,
      file_a_private: file_a_private,
      file_b: file_b,
      collection: collection,
      token: token,
      share_scope: share_scope
    }
  end

  # ── The anti-vacuity floor ────────────────────────────────────────────────
  #
  # A media fixture with no reachable rows greens every `refute` below for
  # free, and a media fixture is exactly where that happens. So first prove,
  # in this same run, that (1) the fixture CAN produce a foreign row on an
  # unscoped read of this dataset, and (2) the door itself answers 200 and
  # surfaces workspace A's OWN assets. Without both, a "clean" result below is
  # evidence of nothing — it would equally mean the seed was invisible to
  # everybody.

  test "FLOOR: the fixture can produce a foreign row, and the door surfaces A's own",
       %{
         file_a_public: file_a_public,
         file_a_private: file_a_private,
         file_b: file_b,
         token: token
       } do
    {files, total, _facets, _meta} = Search.search(@dataset, [])
    unscoped_ids = Enum.map(files, & &1.id)

    assert file_a_public.id in unscoped_ids

    assert file_b.id in unscoped_ids,
           "the fixture cannot produce a cross-workspace row on an unscoped read, " <>
             "so every refute below would pass vacuously"

    assert total >= 3

    # The POSITIVE CONTROL on the door itself: an anonymous share request must
    # actually return workspace A's rows. A share_view that returned nothing at
    # all would satisfy every leak refute in this file.
    body = share_get(token)
    ids = hit_ids(body)

    assert file_a_public.id in ids,
           "the share door returned none of its OWN workspace's assets, so a " <>
             "clean cross-tenant result proves nothing"

    assert file_a_private.id in ids
  end

  # ── Rows ──────────────────────────────────────────────────────────────────

  test "an anonymous share view's ROWS exclude another workspace's assets",
       %{file_a_public: file_a_public, file_b: file_b, token: token} do
    ids = token |> share_get() |> hit_ids()

    assert file_a_public.id in ids

    refute file_b.id in ids,
           "CROSS-TENANT SHARE LEAK: a share token minted in workspace A returned " <>
             "workspace B's media file — share_view/2 handed Collections.assets/3 " <>
             "no tenancy keys, so the read spanned every workspace sharing the " <>
             "dataset string"
  end

  # ── Aggregates: total ─────────────────────────────────────────────────────

  test "an anonymous share view's TOTAL counts only the share's own workspace",
       %{token: token} do
    %{"result" => %{"total" => total}} = share_get(token)

    assert total == 2,
           "expected the share's own workspace's two assets, got total=#{total} — " <>
             "the count spans every workspace sharing the dataset string even when " <>
             "the row list looks right"
  end

  # ── Aggregates: facet buckets ─────────────────────────────────────────────
  #
  # `share_view/2` computes facets and DISCARDS them (`{files, total, _facets}`),
  # so the HTTP body cannot expose a facet leak. The buckets are pinned on the
  # exact opts the controller now derives from the resolved share record, which
  # is where the leak lived: the facet SQL reads `opts[:workspace_id]` /
  # `opts[:project_id]` directly, so keys that never arrive leave every bucket
  # spanning tenants.

  test "the share's derived scope bounds the FACET BUCKETS too",
       %{collection: collection, share_scope: share_scope} do
    # THE FLOOR FOR THIS ASSERTION: the opts `share_view/2` used to pass — a
    # `:facets` key and no tenancy at all — must actually produce the foreign
    # bucket, or the refute below is satisfied by an empty facet map rather
    # than by the scope.
    {_files, _total, unscoped_facets} =
      Collections.assets(collection.doc_id, @dataset, facets: ["tags"])

    unscoped_values = (unscoped_facets["tags"] || []) |> Enum.map(& &1.value)

    assert "b-only" in unscoped_values,
           "the tenancy-free opts share_view/2 used to pass did NOT surface " <>
             "workspace B's tag, so the scoped refute below proves nothing"

    {_files, _total, facets} =
      Collections.assets(collection.doc_id, @dataset, [facets: ["tags"]] ++ share_scope)

    values = facets["tags"] |> Enum.map(& &1.value)

    assert "a-only" in values
    assert "a-private" in values

    refute "b-only" in values,
           "CROSS-TENANT FACET LEAK: the share's tags facet #{inspect(values)} " <>
             "included workspace B's exclusive tag"
  end

  test "a facet VALUE shared across workspaces is not double-counted",
       %{collection: collection, share_scope: share_scope} do
    {_files, _total, facets} =
      Collections.assets(collection.doc_id, @dataset, [facets: ["tags"]] ++ share_scope)

    shared = Enum.find(facets["tags"] || [], &(&1.value == "shared"))

    assert shared, "expected a 'shared' tag bucket for the share's own workspace"

    assert shared.count == 1,
           "expected the share workspace's 'shared' count to be 1 (its own asset " <>
             "only), got #{shared.count} — workspace B's matching asset leaked into " <>
             "the bucket COUNT even though the bucket VALUE is legitimately shared"
  end

  # ── The half that must STAY open ──────────────────────────────────────────
  #
  # `visibility_clamp_opts/1` is deliberately NOT applied to `share_view/2`.
  # This is not an oversight to be tidied up alongside the scope fix: a share
  # token IS the principal, and clamping to `:public` would empty every shared
  # collection of exactly the non-public assets someone chose to share. This
  # test fails the moment the clamp is added.

  test "the clamp is still not applied: an anonymous share returns NON-PUBLIC assets",
       %{file_a_private: file_a_private, token: token} do
    ids = token |> share_get() |> hit_ids()

    assert file_a_private.id in ids,
           "the visibility clamp reached share_view/2 — a resolved share token is a " <>
             "principal, and clamping it to :public empties every shared collection " <>
             "of the very assets being shared. This half of the omission is " <>
             "DOCUMENTED-INTENTIONAL; only the cross-tenant scope was ever open."
  end
end
