defmodule Barkpark.Search.IndxPerspectiveTest do
  @moduledoc """
  task-d99d712daf6ca959 — the Indx retriever ignored `:perspective`.

  `QueryPipeline.search_documents/5` hands every retriever the caller's
  perspective (`:published` for an anonymous or `public-read` caller, pinned by
  `AnonPerspective`). `DocumentsRetriever` applies it (`perspective_filter/2`:
  `:published` drops `drafts.%`). `Indx.Retriever` never read it: it hydrated
  whatever ids the engine returned through `Content.get_documents_by_ids/3`,
  which is perspective-free by design (expand and grants reuse it).

  With `incremental_upsert` on, every save — a `drafts.` save of a PUBLIC type
  included — upserts its id into the index (`Indx.Lifecycle`). `engine` is a raw
  caller-supplied query param, so an anonymous
  `GET /v1/data/search/:ds?q=…&engine=indx` returned unpublished drafts and
  counted them in `total`. The finder pinned itself to postgres for exactly this
  reason (`finder_live.ex`); the REST door did not.

  The engine is faked (no Indx runs in test) to return the draft and the
  published id together, exactly what an incrementally-upserted index holds.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Plugins.Indx.Indexer
  alias Barkpark.Plugins.Indx.Retriever, as: IndxRetriever
  alias Barkpark.Search.{QueryParser, SurfaceConfigs}

  @ds "indx_perspective"
  @term "quince"
  @pointer_term {Indexer, :live_dataset}

  defmodule DraftAndPublishedClient do
    def search_full(_dataset, _text, _opts) do
      {:ok,
       %{
         records: [%{"documentKey" => 1}, %{"documentKey" => 2}],
         facets: %{},
         truncation_index: nil
       }}
    end

    def get_json(_dataset, _keys, _opts) do
      {:ok,
       [
         %{"_id" => "drafts.unpublished", "_type" => "post"},
         %{"_id" => "live", "_type" => "post"}
       ]}
    end
  end

  setup do
    ws = Barkpark.Tenancy.get_default_workspace()
    project = Barkpark.Tenancy.get_default_project()
    scope = [workspace_id: ws.id, project_id: project.id]

    prior = :persistent_term.get(@pointer_term, %{})
    on_exit(fn -> :persistent_term.put(@pointer_term, prior) end)
    key = Indexer.index_key(@ds, scope)
    :persistent_term.put(@pointer_term, Map.put(prior, key, %{dataset: "indx-persp-live"}))

    SurfaceConfigs.seed_defaults!()

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public"},
        @ds,
        scope
      )

    # A draft that was never published, and a published doc.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "unpublished", "title" => "#{@term} embargoed"},
        @ds,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "live", "title" => "#{@term} live"},
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("live", "post", @ds, scope)

    %{scope: scope}
  end

  defp search(scope, perspective) do
    {hits, total, _meta} =
      IndxRetriever.search(
        @ds,
        QueryParser.parse(@term),
        SurfaceConfigs.get("documents", @ds),
        [
          perspective: perspective,
          caller_context: CallerContext.anonymous(),
          client: DraftAndPublishedClient
        ] ++ scope
      )

    {Enum.map(hits, & &1.doc_id), total}
  end

  test "ANONYMOUS :published search never returns or counts a draft", %{scope: scope} do
    {ids, total} = search(scope, :published)
    assert ids == ["live"]
    assert total == 1
  end

  test ":drafts is the draft-over-published overlay and :raw keeps both (parity with DocumentsRetriever)",
       %{scope: scope} do
    # Owner ruling #52: `live` has no drafts twin, so the overlay keeps it.
    {draft_ids, draft_total} = search(scope, :drafts)
    assert Enum.sort(draft_ids) == ["drafts.unpublished", "live"]
    assert draft_total == 2

    {raw_ids, raw_total} = search(scope, :raw)
    assert Enum.sort(raw_ids) == ["drafts.unpublished", "live"]
    assert raw_total == 2
  end

  test "an unknown perspective falls back to :published, never unfiltered", %{scope: scope} do
    assert {["live"], 1} = search(scope, "published")
  end
end
