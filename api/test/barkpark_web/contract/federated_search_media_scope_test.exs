defmodule BarkparkWeb.Contract.FederatedSearchMediaScopeTest do
  @moduledoc """
  Scope + visibility coverage for the federated-search **media** surface.

  Two DISTINCT concerns, two `describe` blocks:

    1. Cross-workspace leak (barkpark-se5b) — the federated
       `/w/:ws/p/:project/v1/search/:dataset` route is workspace-scoped and
       PROMISES a tenant boundary. The documents surface threaded that scope
       into `Content.search_documents`, but the media surface DISCARDED
       `_scope` and called `Media.search_files/2` with no
       `:workspace_id`/`:project_id` — so a media blob in workspace A (sharing
       the dataset STRING) leaked into workspace B's federated results. This
       stands up TWO workspaces in the SAME dataset, puts a media file +
       linked `mediaAsset` doc in each, drives the scoped route as a member of
       workspace B, and asserts B never sees A's blob — plus the legit
       in-scope read. Mirrors `BarkparkWeb.SiblingControllerLeakTest` helpers
       (workspace_with_token, scoped/3, authed/2).

    2. Anonymous caller-context visibility clamp (task-0fcec595765a7b00) — the
       FLAT, unscoped `GET /v1/search/:dataset` door rendered every media hit
       with `include_urls: true` regardless of who asked, discarding
       `caller_context` entirely. Proves an anonymous caller no longer
       receives a `private`/`token`-visibility asset, while a `public` asset
       and the authenticated path stay intact.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "fed_media_leak_ds"
  @asset_type "mediaAsset"

  setup do
    {ws_a, proj_a, tok_a} = workspace_with_token("a")
    {ws_b, proj_b, tok_b} = workspace_with_token("b")

    {:ok, ws_a: ws_a, proj_a: proj_a, tok_a: tok_a, ws_b: ws_b, proj_b: proj_b, tok_b: tok_b}
  end

  describe "federated media surface (/w/:ws/p/:project/v1/search :: media)" do
    test "workspace B's federated media search does not return workspace A's media", ctx do
      file_a = create_media!(ctx.ws_a, ctx.proj_a)
      link_asset!(file_a, ctx.ws_a, ctx.proj_a, "Quokka Field Photo")

      # LEGIT: A sees its own media hit under A's scope.
      a_ids = federated_media_ids(ctx, ctx.ws_a, ctx.proj_a, ctx.tok_a, "quokka")

      assert file_a.id in a_ids,
             "federated media search did not surface A's own media under A's scope"

      # LEAK GUARD: B must NOT see A's media blob.
      b_ids = federated_media_ids(ctx, ctx.ws_b, ctx.proj_b, ctx.tok_b, "quokka")

      refute file_a.id in b_ids,
             "CROSS-WORKSPACE LEAK (federated media): A's media blob surfaced in B's federated results"
    end

    test "workspace B's own federated media is returned (in-scope read works)", ctx do
      file_b = create_media!(ctx.ws_b, ctx.proj_b)
      link_asset!(file_b, ctx.ws_b, ctx.proj_b, "Wombat Burrow Photo")

      b_ids = federated_media_ids(ctx, ctx.ws_b, ctx.proj_b, ctx.tok_b, "wombat")

      assert file_b.id in b_ids,
             "federated media search did not surface B's own media under B's scope"
    end
  end

  # ── Anonymous caller-context visibility clamp (task-0fcec595765a7b00) ──────
  #
  # Separate concern from the cross-workspace leak above: this exercises the
  # FLAT, unscoped `GET /v1/search/:dataset` — the route the task names as
  # anonymous-reachable (`:api` pipeline ends in `Plugs.OptionalToken`, no
  # membership check, unlike the scoped `/w/:ws/p/:proj/...` twin used above).
  # Both the media file and its linked `mediaAsset` doc carry no
  # workspace/project scope (`scope_opts/1`'s `:shared_only` sentinel fires for
  # an unresolved flat-route caller — see `BarkparkWeb.ScopeHelpers`), matching
  # how the sibling `federated_search_test.exs` exercises this same route.
  #
  # The `surface_payload/3` media clause used to discard `caller_context`
  # entirely (bound as `_caller_context`) and render every hit with
  # `include_urls: true` regardless of who asked — unlike the documents-surface
  # sibling immediately above it, which threads `caller_context` into
  # `HitEnvelope.build/5`. Predicate mirrors
  # `Barkpark.Media.Storage.Access.delivery_ok?/3` (private clauses in
  # `media/storage/access.ex`): `public` is visible to everyone, `token`/`private`
  # require an authenticated caller.
  describe "federated media surface :: anonymous caller-context visibility clamp" do
    test "anonymous GET drops a private media hit, keeps the public one, and total matches the returned hits",
         ctx do
      file_private = create_flat_media!()
      link_flat_asset!(file_private, "Falcon Private Dossier", visibility: "private")

      file_public = create_flat_media!()
      link_flat_asset!(file_public, "Falcon Public Snapshot")

      # ctx.conn carries no `authorization` header — `CallerContext.from_conn/1`
      # resolves this to `CallerContext.anonymous/0`.
      body =
        ctx.conn
        |> get("/v1/search/#{@dataset}?q=falcon&surfaces=media")
        |> json_response(200)

      media = body["results"]["media"]
      hit_ids = Enum.map(media["hits"], & &1["id"])

      refute file_private.id in hit_ids,
             "LEAK: anonymous federated media search returned a private asset"

      assert file_public.id in hit_ids,
             "the public asset must still be visible to an anonymous caller"

      # Belt-and-braces: the private asset's identifying fields must not
      # appear ANYWHERE in the payload (filename, path — not merely its id).
      encoded = Jason.encode!(body)
      refute encoded =~ file_private.filename
      refute encoded =~ file_private.path

      # `total` must be consistent with what the anonymous caller actually
      # received — it must not advertise the clamped-away private row.
      assert media["total"] == length(media["hits"])

      # Control: an authenticated caller (any verified token — this route has
      # no membership gate) still sees BOTH assets with delivery URLs intact —
      # the clamp must not weaken the authed path.
      raw = "fedmedia-clamp-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "fed media clamp control", @dataset, ["read"])

      authed_body =
        raw
        |> authed(ctx.conn)
        |> get("/v1/search/#{@dataset}?q=falcon&surfaces=media")
        |> json_response(200)

      authed_hits = authed_body["results"]["media"]["hits"]
      authed_ids = Enum.map(authed_hits, & &1["id"])
      assert file_private.id in authed_ids
      assert file_public.id in authed_ids

      authed_hit = Enum.find(authed_hits, &(&1["id"] == file_private.id))
      assert authed_hit, "authenticated caller lost the private asset entirely"
      assert authed_hit["url"], "authenticated caller's private-asset hit should keep its url"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp workspace_with_token(slug_seed) do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "#{slug_seed}-ws-#{suffix}", name: "WS #{slug_seed}"})

    {:ok, proj} =
      Tenancy.create_project(ws, %{slug: "#{slug_seed}-proj-#{suffix}", name: "Proj #{slug_seed}"})

    raw = "fedmedia-#{slug_seed}-#{suffix}"

    {:ok, _token} =
      Auth.create_token(
        raw,
        "fed media #{slug_seed}",
        @dataset,
        ["read", "write", "admin"],
        ws.id
      )

    {ws, proj, raw}
  end

  # Insert a media_file row STAMPED to workspace/project, sharing the dataset
  # STRING — isolation must come from workspace_id, not the dataset leaf.
  defp create_media!(ws, proj) do
    suffix = System.unique_integer([:positive])

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "fixture-#{suffix}.png",
        original_name: "fixture-#{suffix}.png",
        path: "fixtures/#{suffix}.png",
        mime_type: "image/png",
        size: 1,
        dataset: @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      })
      |> Repo.insert()

    file
  end

  # Link a `mediaAsset` doc (title carries the search term) to the blob, stamped
  # to the same workspace/project as the blob. `opts[:visibility]` sets
  # `bp_visibility` in content — the field `Access.visibility/1` reads
  # (default, when omitted, is "public" per `Access.visibility/1`'s own
  # fallback).
  defp link_asset!(media_file, ws, proj, title, opts \\ []) do
    suffix = System.unique_integer([:positive])

    content =
      case Keyword.get(opts, :visibility) do
        nil -> %{"mediaFileId" => media_file.id, "tags" => []}
        vis -> %{"mediaFileId" => media_file.id, "tags" => [], "bp_visibility" => vis}
      end

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "draft",
        rev: "r#{suffix}",
        content: content,
        workspace_id: ws.id,
        project_id: proj.id
      })
      |> Repo.insert()

    doc
  end

  # Scoped to the seeded Default workspace/project — the scope
  # `BarkparkWeb.Plugs.AssignDefaultScope` resolves for the FLAT,
  # non-scoped `/v1/search/:dataset` route an anonymous caller reaches (a
  # freshly-migrated DB already carries a Default row — see
  # `priv/repo/migrations/20260527110200_backfill_default_tenancy.exs` — so
  # the flat route is scoped there, never to a bare-nil workspace). Uses
  # `Barkpark.TenancyFixtures.ensure_default_scope!/0`, the same helper
  # `ConnCase.scoped_studio/1` relies on.
  defp create_flat_media!() do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    suffix = System.unique_integer([:positive])

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "flatfixture-#{suffix}.png",
        original_name: "flatfixture-#{suffix}.png",
        path: "fixtures/flat-#{suffix}.png",
        mime_type: "image/png",
        size: 1,
        dataset: @dataset,
        workspace_id: ws.id,
        project_id: project.id
      })
      |> Repo.insert()

    file
  end

  defp link_flat_asset!(media_file, title, opts \\ []) do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    suffix = System.unique_integer([:positive])

    content =
      case Keyword.get(opts, :visibility) do
        nil -> %{"mediaFileId" => media_file.id, "tags" => []}
        vis -> %{"mediaFileId" => media_file.id, "tags" => [], "bp_visibility" => vis}
      end

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "flat-asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "draft",
        rev: "r#{suffix}",
        content: content,
        workspace_id: ws.id,
        project_id: project.id
      })
      |> Repo.insert()

    doc
  end

  defp authed(raw, conn), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp scoped(ws, proj, path), do: "/w/#{ws.slug}/p/#{proj.slug}#{path}"

  defp federated_media_ids(ctx, ws, proj, tok, q) do
    body =
      tok
      |> authed(ctx.conn)
      |> get(scoped(ws, proj, "/v1/search/#{@dataset}?q=#{q}&surfaces=media"))
      |> json_response(200)

    body
    |> get_in(["results", "media", "hits"])
    |> Kernel.||([])
    |> Enum.map(& &1["id"])
  end
end
