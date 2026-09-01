defmodule Barkpark.Media.ScopedMediaPublicReadTierAuditTest do
  @moduledoc """
  AUDIT — does the `public-read` tier clamp reach the SCOPED MEDIA surface?
  (`dr-w2-s7-followup-scoped-media-public-read-audit`)

  ## The premise, stated as the router actually spells it

  There is no pipeline named `scoped_media_api`. The scoped v1 media READ block
  in `router.ex` ("Scoped v1 media — public reads") pipes through
  **`:scoped_api` alone**, and `:scoped_api` mounts NO `Plugs.PublicRead` —
  unlike `:shared_docs_api`, `:api_grant_read` and `:require_token`, which each
  mount it. Its sibling scoped surface `/w/:ws/p/:proj/media` rides
  `:shared_media_api` — also no `PublicRead`. That absence is DELIBERATE
  (search-template D49: `PublicRead` is deny-by-default outside a
  query/doc/graph allowlist and would 403 all 21 routes riding bare
  `:scoped_api`), so the clamp must live at the RETRIEVAL seat.

  ## What the retrieval seat asked, before this row

  `V1.MediaController.visibility_clamp_opts/1` (and its fork in
  `MediaCollectionsController`) keys the whole media read tier on
  `Media.Storage.Access.authenticated?/1`, which was PRESENCE of any
  `%ApiToken{}`. A `public-read` token is a real token AND `Tenancy.Auth` maps
  `public-read -> :read` (`Tenancy.Auth.@read_perms`), so it clears
  `ResolveWorkspace`'s membership gate and then arrives at the media
  controllers as a fully-authenticated principal:

    * `visibility_clamp_opts/1` returns `[]` -> `bp_visibility: "private"`
      assets are returned by search / index / collection listings, count
      included;
    * `Access.allowed?(_, _, doc, :view)` reduces to
      `delivery_ok?("private", true, _)` -> `true`, so single-asset `show`
      answers 200 with `filename` / `path` / `size` / `visibility`;
    * `render_opts/3` grants `sign_urls` on request — the escalation from
      "I know an id" to BYTES that `v1_media_anon_read_clamp_test.exs` closed
      for the ANONYMOUS caller and not for this tier.

  That is the exact shape `DocumentsRetriever` closed for the scoped DOCUMENT
  search door in `dr-w2-s7`
  (`DocumentsRetriever.restrict_anonymous_to_public_types/3`, "KEYED ON THE
  PERMISSION, NOT ON `principal_type`"). The media surface never routed through
  it.

  ## Direction of capability

  Every clamp assertion below is paired with an ADMIN CONTROL on the SAME door
  proving the seed is leak-observable, plus a `{read}`-tier NON-REGRESSION
  proving the clamp moved exactly one tier. A clamp test whose fixture is
  invisible to everybody is vacuous, and a media fixture is unusually easy to
  make invisible (a mismatched `dataset_id` empties the listing outright), so
  the controls are asserted, never merely printed.

  ## What this file does NOT close

  The collections index is a third door around the same clamp, on a different
  seat, and it leaks too — measured here, fixed elsewhere. See the recorded
  finding above the `COLLECTIONS index` describe block and
  `task-b4a4b33bfb6e2954`.

  ## Fleet-shared database

  Every id asserted here is one this test seeded, in a workspace whose slug is
  unique to this run. No `Repo.all/1`, no bare counts over shared tables — the
  `count` / `total` assertions are safe only because the listing is scoped to
  that fresh workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Media.Storage.MediaFile

  @ds "production"

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp mint!(label, perms, ws_id) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @ds, perms, ws_id)
    raw
  end

  defp scoped(ctx, suffix), do: "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}#{suffix}"

  setup do
    uniq = System.unique_integer([:positive])
    probe = "zarquonaut#{uniq}"

    ws = create_workspace!("smprt-ws-#{uniq}")
    proj = create_project!(ws, "smprt-proj-#{uniq}")
    scope = [workspace_id: ws.id, project_id: proj.id]

    # THE DATASET ENTITY IS LOAD-BEARING, NOT DECORATION.
    # `Search.resolve_dataset_id/2` resolves `(project_id, "production")` and,
    # when it hits, the media query filters `m.dataset_id == ^id` — a blob row
    # with a NULL `dataset_id` then matches NOTHING and every assertion below
    # greens against an EMPTY listing. Creating the row and stamping the blob
    # with it keeps the fixture visible on whichever branch the resolver takes.
    {:ok, dataset} = Tenancy.get_or_create_dataset(proj, @ds)

    # `mediaAsset` is private in the live schema census — the same type the
    # dr-w2-s7 independent derivation seeds. It makes the SCHEMA-tier question
    # explicit: on the document surface a public-read token 404s this type; the
    # media surface has no schema gate at all.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "mediaAsset",
          "title" => "Media Asset",
          "visibility" => "private",
          "fields" => []
        },
        @ds,
        scope
      )

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "#{probe}.png",
        original_name: "#{probe}-original.png",
        path: "test/smprt/#{probe}.png",
        mime_type: "image/png",
        size: 42,
        dataset: @ds,
        dataset_id: dataset.id,
        workspace_id: ws.id,
        project_id: proj.id
      })
      |> Repo.insert!()

    doc_id = "smprt-asset-#{uniq}"

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "_id" => doc_id,
          "title" => "#{probe} Confidential Asset",
          "mediaFileId" => file.id,
          "bp_visibility" => "private",
          "rightsNote" => "CONFIDENTIAL-#{String.upcase(probe)}"
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "mediaAsset", @ds, scope)

    # The row's brief names `mediaCollection` alongside `mediaAsset`, and the
    # collections index is a THIRD door onto the same clamp: the document
    # surface 404s a private type for this tier and the scoped search door
    # filters it, so whatever `/v1/media/:ds/collections` does is the answer
    # for the third. Seeded private-visibility, same as the asset type.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "mediaCollection",
          "title" => "Media Collection",
          "visibility" => "private",
          "fields" => []
        },
        @ds,
        scope
      )

    coll_id = "smprt-coll-#{uniq}"

    {:ok, _} =
      Content.create_document(
        "mediaCollection",
        %{
          "_id" => coll_id,
          "title" => "#{probe} Confidential Collection",
          "slug" => probe,
          "description" => "CONFIDENTIAL-#{String.upcase(probe)}"
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(coll_id, "mediaCollection", @ds, scope)

    %{
      ws: ws,
      proj: proj,
      asset_file: file,
      probe: probe,
      admin: mint!("smprt-admin", ["read", "write", "admin"], ws.id),
      read: mint!("smprt-read", ["read"], ws.id),
      public_read: mint!("smprt-pr", ["public-read", "read"], ws.id),
      singleton: mint!("smprt-pr1", ["public-read"], ws.id)
    }
  end

  # ── door readers ─────────────────────────────────────────────────────────

  defp index(ctx, token) do
    result =
      ctx.conn
      |> bearer(token)
      |> get(scoped(ctx, "/v1/media/#{@ds}?limit=500"))
      |> json_response(200)
      |> Map.fetch!("result")

    {Enum.map(result["assets"] || [], & &1["id"]), result["count"]}
  end

  defp search(ctx, token) do
    result =
      ctx.conn
      |> bearer(token)
      |> get(scoped(ctx, "/v1/media/#{@ds}/search?q=#{ctx.probe}&limit=500"))
      |> json_response(200)
      |> Map.fetch!("result")

    {Enum.map(result["hits"] || [], & &1["id"]), result["total"]}
  end

  # Titles, not ids: publishing rewrites `doc_id`, and the probe string is
  # unique to this run, so a title match is both stable and mine alone.
  defp collection_titles(ctx, token) do
    ctx.conn
    |> bearer(token)
    |> get(scoped(ctx, "/v1/media/#{@ds}/collections?limit=1000"))
    |> json_response(200)
    |> get_in(["result", "collections"])
    |> Kernel.||([])
    |> Enum.map(& &1["title"])
    |> Enum.filter(&(is_binary(&1) and String.contains?(&1, ctx.probe)))
  end

  defp show(ctx, token) do
    conn =
      ctx.conn
      |> bearer(token)
      |> get(scoped(ctx, "/v1/media/#{@ds}/#{ctx.asset_file.id}"))

    case conn.status do
      200 -> {:ok, json_response(conn, 200)["result"]}
      status -> {:refused, status}
    end
  end

  # ── the scoped media surface, public-read tier ───────────────────────────

  describe "scoped media LISTING door (/w/:ws/p/:proj/v1/media/:dataset)" do
    test "CONTROL: admin reads the private asset — the seed is leak-observable", ctx do
      {ids, count} = index(ctx, ctx.admin)

      assert ctx.asset_file.id in ids,
             "seed is NOT leak-observable on the listing door — every clamp assertion " <>
               "below would be vacuous. ids=#{inspect(ids)}"

      assert count >= 1
    end

    test "NON-REGRESSION: a {read} token still reads the private asset", ctx do
      {ids, _count} = index(ctx, ctx.read)

      assert ctx.asset_file.id in ids,
             "the clamp moved more than one tier: a plain {read} token lost the private asset"
    end

    test "a [public-read, read] token must not read the private asset — rows AND count", ctx do
      {ids, count} = index(ctx, ctx.public_read)

      refute ctx.asset_file.id in ids,
             "PUBLIC-READ TIER LEAK on the scoped media listing: #{ctx.asset_file.id} " <>
               "(bp_visibility=private) was returned to a public-read token"

      assert count == 0,
             "EXISTENCE LEAK: rows were clamped but count still reported #{count}"
    end

    test "a singleton [public-read] token is clamped identically", ctx do
      {ids, count} = index(ctx, ctx.singleton)

      refute ctx.asset_file.id in ids,
             "PUBLIC-READ TIER LEAK (singleton token) on the scoped media listing"

      assert count == 0
    end
  end

  describe "scoped media SEARCH door (/w/:ws/p/:proj/v1/media/:dataset/search)" do
    test "CONTROL: admin finds the private asset by probe — the seed is leak-observable", ctx do
      {ids, total} = search(ctx, ctx.admin)

      assert ctx.asset_file.id in ids,
             "seed is NOT leak-observable on the search door. ids=#{inspect(ids)}"

      assert total >= 1
    end

    test "NON-REGRESSION: a {read} token still finds it", ctx do
      {ids, _total} = search(ctx, ctx.read)

      assert ctx.asset_file.id in ids,
             "the clamp moved more than one tier: a plain {read} token lost the private asset"
    end

    test "a [public-read, read] token must not find it — hits AND total", ctx do
      {ids, total} = search(ctx, ctx.public_read)

      refute ctx.asset_file.id in ids,
             "PUBLIC-READ TIER LEAK on the scoped media search: #{ctx.asset_file.id} " <>
               "(bp_visibility=private) was returned to a public-read token"

      assert total == 0,
             "EXISTENCE LEAK: hits were clamped but total still reported #{total}"
    end
  end

  # RECORDED FINDING, NOT FIXED HERE — `task-b4a4b33bfb6e2954`.
  #
  # The collections index is a THIRD door around the same clamp and it has none:
  # `Collections.list/2` is a bare `Repo.all` over `mediaCollection` documents
  # with tenancy scoping and NO schema-visibility filter, and `Collections.get/3`
  # goes through `Content.Query.get_document/4`, a single-type keyed read that
  # carries no `restrict_to_visible_types/3` either. MEASURED on this exact
  # fixture with the control below green in the same run: a `[public-read, read]`
  # token was listed the private-visibility `mediaCollection` seeded in `setup`,
  # title and description included.
  #
  # It is a DIFFERENT SEAT from the asset tier this file fixes, with two hazards
  # that make it its own change rather than a line in this one: `share_view/2`
  # reaches `Collections.assets/3` with no caller context by design (the share
  # token IS the credential), and the FLAT collections route is
  # anonymous-reachable, so clamping `list/2` is a product call about the public
  # demo surface. Both are written up on the row.
  #
  # The seed and the reader stay here so the next agent inherits a working
  # repro. The assertion that reds is the one line the follow-up adds back:
  #
  #     assert collection_titles(ctx, ctx.public_read) == []
  #
  describe "scoped media COLLECTIONS index (/w/:ws/p/:proj/v1/media/:dataset/collections)" do
    test "CONTROL: admin reads the private-typed collection — the repro is leak-observable",
         ctx do
      assert collection_titles(ctx, ctx.admin) != [],
             "the collections repro kept for task-b4a4b33bfb6e2954 has gone blind — the " <>
               "seeded private mediaCollection is invisible even to admin, so re-adding " <>
               "the clamp assertion would pass VACUOUSLY"
    end
  end

  describe "scoped media SHOW door (/w/:ws/p/:proj/v1/media/:dataset/:id)" do
    test "CONTROL: admin reads the private asset's metadata", ctx do
      assert {:ok, result} = show(ctx, ctx.admin)
      assert result["visibility"] == "private"
    end

    test "NON-REGRESSION: a {read} token still reads it", ctx do
      assert {:ok, _result} = show(ctx, ctx.read)
    end

    test "a public-read token is refused the private asset's metadata", ctx do
      case show(ctx, ctx.public_read) do
        {:refused, status} ->
          assert status in [403, 404],
                 "expected a refusal on the private asset, got #{status}"

        {:ok, result} ->
          flunk(
            "PUBLIC-READ TIER LEAK on the scoped media show door: filename=" <>
              "#{result["filename"]} path=#{result["path"]} size=#{result["size"]} " <>
              "visibility=#{result["visibility"]}"
          )
      end
    end
  end
end
