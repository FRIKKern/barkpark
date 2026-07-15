defmodule Barkpark.Search.SearchableFieldsRankingTest do
  @moduledoc """
  `searchable_fields` per-field weights REORDER results (charter W7 /
  bpb-searchable-fields-dead-config).

  The weighted per-field ranking knob was persisted + echoed by `SurfaceConfigs`
  and shown in admin settings, but NEVER read on the query path:
  `DocumentsRetriever.order_rank/3` underscored its `config` arg and ranked on a
  hardcoded `similarity(title, query)`; `Media.Delivery.Search`'s relevance sort
  was a hardcoded boolean CASE. Presenting a knob that does nothing is a lie in
  the admin UI — the Kinsta/Vercel bar is per-workspace tuning that actually
  reorders results.

  Each test seeds two rows where the query near-misses a DIFFERENT field in each
  (field X in row A, field Y in row B), then flips the per-field weights and
  asserts the winner flips with them.

  FAIL-BEFORE (proven at build): against the pre-wire code both weightings
  produce the SAME order (title/first-field always decides), so the
  `title_heavy` vs `body_heavy` (resp. `name_heavy` vs `file_heavy`) assertions
  cannot both hold — the weight change is inert. Wiring the config into the
  ORDER BY is exactly what makes the second assertion pass.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Media.Delivery.Search, as: MediaSearch
  alias Barkpark.Search.{DocumentsRetriever, QueryParser, SurfaceConfigs}

  # --- documents ------------------------------------------------------------

  @docs_dataset "sf-rank-docs"

  # A shared EXACT token, present in a NON-searchable content field of BOTH docs,
  # so `where_match` admits both (search_vector indexes content strings at band
  # D) with an IDENTICAL, ranking-neutral contribution. Without it a doc whose
  # only near-miss lives in the body would never be admitted (the fuzzy arm
  # matches title only) and the reorder could not be observed.
  @docs_anchor "anchortoken"
  # `borealix` is a one-substitution near-miss of the query token `borealis`:
  # trigram-similar (moves `similarity()`), but a DIFFERENT lexeme (so it never
  # matches `plainto_tsquery('borealis')` → ts_rank stays 0 and the weighted
  # field-similarity is the sole rank signal).
  @docs_query "#{@docs_anchor} borealis"

  defp doc_title_heavy,
    do: %{
      "searchable_fields" => [
        %{"path" => "title", "weight" => 10},
        %{"path" => "content.body", "weight" => 1}
      ]
    }

  defp doc_body_heavy,
    do: %{
      "searchable_fields" => [
        %{"path" => "title", "weight" => 1},
        %{"path" => "content.body", "weight" => 10}
      ]
    }

  defp make_doc!(id, title, body) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => id, "title" => title, "content" => %{"body" => body, "note" => @docs_anchor}},
        @docs_dataset
      )

    {:ok, _} = Content.publish_document(id, "post", @docs_dataset)
    :ok
  end

  defp doc_ranked_ids(config) do
    parsed = QueryParser.parse(@docs_query)
    {docs, _count, _meta} = DocumentsRetriever.search(@docs_dataset, parsed, config, [])
    Enum.map(docs, & &1.doc_id)
  end

  describe "documents order_rank folds searchable_fields weights" do
    setup do
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @docs_dataset
      )

      # A: near-miss in TITLE, plain body. B: plain title, near-miss in BODY.
      make_doc!("sf-doc-a", "borealix ridge", "quiet harbor census")
      make_doc!("sf-doc-b", "quiet harbor census", "borealix ridge")
      :ok
    end

    test "flipping title vs content.body weight flips the winner" do
      title_heavy = doc_ranked_ids(doc_title_heavy())
      body_heavy = doc_ranked_ids(doc_body_heavy())

      # Both docs are admitted under both weightings.
      assert "sf-doc-a" in title_heavy and "sf-doc-b" in title_heavy
      assert "sf-doc-a" in body_heavy and "sf-doc-b" in body_heavy

      # Title-weighted: the title near-miss (doc A) wins.
      assert index_of(title_heavy, "sf-doc-a") < index_of(title_heavy, "sf-doc-b"),
             "expected doc A (title near-miss) first under title-heavy weights, got #{inspect(title_heavy)}"

      # Body-weighted: the SAME weight flip reorders — the body near-miss (doc B)
      # now wins. Inert-config code would still rank A first here.
      assert index_of(body_heavy, "sf-doc-b") < index_of(body_heavy, "sf-doc-a"),
             "expected doc B (body near-miss) first under body-heavy weights, got #{inspect(body_heavy)} — the searchable_fields weight change is inert"
    end
  end

  # --- media ----------------------------------------------------------------

  @media_dataset "sf-rank-media"
  @media_query "borealis"

  defp media_name_heavy,
    do: %{
      "searchableFields" => [
        %{"path" => "original_name", "weight" => 10},
        %{"path" => "filename", "weight" => 1}
      ]
    }

  defp media_file_heavy,
    do: %{
      "searchableFields" => [
        %{"path" => "original_name", "weight" => 1},
        %{"path" => "filename", "weight" => 10}
      ]
    }

  defp media_ranked_ids(ws, proj) do
    {files, _total, _facets, _meta} =
      MediaSearch.search(@media_dataset,
        q: @media_query,
        sort: "relevance",
        workspace_id: ws.id,
        project_id: proj.id,
        limit: 50
      )

    Enum.map(files, & &1.id)
  end

  describe "media apply_sort relevance folds searchable_fields weights" do
    test "flipping original_name vs filename weight flips the winner" do
      ws = create_workspace!()
      proj = create_project!(ws)

      # File A: query near-miss in original_name, plain filename.
      {:ok, file_a} =
        create_media_file_in!(
          ws,
          proj,
          %{original_name: "borealis-anchor.png", filename: "quiet-harbor.png"},
          @media_dataset
        )

      # File B: plain original_name, query near-miss in filename.
      {:ok, file_b} =
        create_media_file_in!(
          ws,
          proj,
          %{original_name: "quiet-harbor.png", filename: "borealis-anchor.png"},
          @media_dataset
        )

      # original_name-heavy → file A wins.
      {:ok, _} = SurfaceConfigs.upsert("media", @media_dataset, media_name_heavy(), ws.id)
      name_heavy = media_ranked_ids(ws, proj)

      # filename-heavy → the SAME weight flip reorders → file B wins.
      {:ok, _} = SurfaceConfigs.upsert("media", @media_dataset, media_file_heavy(), ws.id)
      file_heavy = media_ranked_ids(ws, proj)

      assert file_a.id in name_heavy and file_b.id in name_heavy
      assert file_a.id in file_heavy and file_b.id in file_heavy

      assert index_of(name_heavy, file_a.id) < index_of(name_heavy, file_b.id),
             "expected file A (original_name near-miss) first under name-heavy weights, got #{inspect(name_heavy)}"

      assert index_of(file_heavy, file_b.id) < index_of(file_heavy, file_a.id),
             "expected file B (filename near-miss) first under filename-heavy weights, got #{inspect(file_heavy)} — the searchable_fields weight change is inert"
    end
  end

  defp index_of(list, id), do: Enum.find_index(list, &(&1 == id))
end
