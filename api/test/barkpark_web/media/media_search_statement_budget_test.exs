defmodule BarkparkWeb.Media.MediaSearchStatementBudgetTest do
  @moduledoc """
  task-55a32a11405d5e9b: media search cost ~12 ms per hit (an N+1 per
  result). Each hit with no asset doc ran its own asset-doc lookup, and each
  hit with one resolved the mediaAsset schema again.

  Pinned here:

    * the number of statements a search issues does not depend on `limit`;
    * the response body is the one the old per-hit render produced (golden
      diff: the hits are re-rendered here the old way and compared).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Auth, Media, QueryCounter, Repo}
  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.AssetResponse
  alias Barkpark.Media.Storage.MediaFile

  @dataset "production"
  @assets 24

  setup do
    {ws, proj} = ensure_default_scope!()
    raw = "msb-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "msb", @dataset, ["read", "write"], ws.id)
    tag = "budget#{System.unique_integer([:positive])}"

    # Half the blobs carry an asset doc, half do not: both per-hit paths.
    for i <- 1..@assets do
      {:ok, file} =
        create_media_file_in!(ws, proj, %{original_name: "#{tag}-#{i}.png"}, @dataset)

      if rem(i, 2) == 0 do
        {:ok, doc} =
          %Document{}
          |> Document.changeset(%{
            doc_id: "msb-asset-#{System.unique_integer([:positive])}",
            type: "mediaAsset",
            dataset: @dataset,
            title: "#{tag} #{i}",
            status: "published",
            rev: "r#{i}",
            content: %{"mediaFileId" => file.id, "title" => "#{tag} #{i}"}
          })
          |> Repo.insert()

        Repo.update_all(from(d in Document, where: d.id == ^doc.id),
          set: [workspace_id: ws.id, project_id: proj.id]
        )
      end
    end

    %{raw: raw, tag: tag}
  end

  defp search(raw, tag, limit) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> get("/v1/media/#{@dataset}/search?q=#{tag}&limit=#{limit}")
  end

  test "the statement count does not grow with limit", %{raw: raw, tag: tag} do
    # Warm the per-node caches (surface config) so both measurements see the
    # same cold/warm state.
    _ = search(raw, tag, 1)

    {r1, {n1, _}} = QueryCounter.census(fn -> search(raw, tag, 1) end)
    {r2, {n2, census2}} = QueryCounter.census(fn -> search(raw, tag, 2) end)
    {r_all, {n_all, census_all}} = QueryCounter.census(fn -> search(raw, tag, @assets) end)

    assert length(json_response(r1, 200)["result"]["hits"]) == 1
    hits2 = json_response(r2, 200)["result"]["hits"]
    assert length(json_response(r_all, 200)["result"]["hits"]) == @assets

    # limit=2 already holds both hit shapes (with and without an asset doc),
    # so every batch the page can need runs once there; a page 12x larger
    # issues exactly as many statements.
    assert Enum.any?(hits2, & &1["assetDocId"]) and Enum.any?(hits2, &is_nil(&1["assetDocId"]))

    assert n2 == n_all,
           "limit=2 issued #{n2} statements, limit=#{@assets} issued #{n_all}: " <>
             "#{inspect(census2)} vs #{inspect(census_all)}"

    # A one-hit page can only need fewer batches, never more.
    assert n1 <= n_all
  end

  test "the body is what the per-hit render produced (golden diff)", %{raw: raw, tag: tag} do
    resp = search(raw, tag, @assets)
    hits = json_response(resp, 200)["result"]["hits"]

    files = Repo.all(from m in MediaFile, where: m.id in ^Enum.map(hits, & &1["id"]))
    by_id = Map.new(files, &{&1.id, &1})
    ordered = Enum.map(hits, &Map.fetch!(by_id, &1["id"]))

    # The OLD path: the request-scope batch, then AssetResponse's own per-hit
    # fallback and per-hit schema lookup for anything it did not cover.
    scope = BarkparkWeb.ScopeHelpers.scope_opts(resp)
    docs = Media.asset_docs_for_files(ordered, @dataset, scope)

    expected =
      Enum.map(ordered, fn file ->
        AssetResponse.render(file, Map.get(docs, file.id), conn: resp, dataset: @dataset)
      end)

    assert Jason.decode!(Jason.encode!(expected)) == hits
    assert Enum.count(hits, & &1["assetDocId"]) == div(@assets, 2)
  end
end
