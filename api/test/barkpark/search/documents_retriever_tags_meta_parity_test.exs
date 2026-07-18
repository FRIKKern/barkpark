defmodule Barkpark.Search.DocumentsRetrieverTagsMetaParityTest do
  @moduledoc """
  Parity guard for search-latency slice d (task-9faff63dd9199c7d): the ranking
  ORDER BY's per-candidate content DETOASTs were removed by reading GENERATED
  STORED columns instead of `content` in `order_rank/3`'s two per-row keys —

    1. the weighted-tag boost now reads the `tags_meta` GENERATED column
       (migration 20260718100000) instead of
       `CASE WHEN jsonb_typeof(content->'tags')='array' THEN content->'tags'
        ELSE '[]'::jsonb END`;
    2. the `content.slug` field-similarity arm (the DEFAULT + live-prod
       `documents` config, weight 3) now reads the `slug_text` GENERATED column
       (#4174) instead of `content#>>'{slug}'`.

  Both swaps must be behavior-identical BY CONSTRUCTION. The two `IS DISTINCT
  FROM` locks below are the drift TRIPWIRE: they FAIL the instant a migration's
  GENERATED expression stops matching the query-site expression it replaced, so
  the ranking value can never silently change. The end-to-end reorder proves the
  retriever actually reads `tags_meta` and the strength boost still orders.

  The lock tests insert rows DIRECTLY (Repo.insert!) so they can carry the junk /
  legacy `tags` shapes the boost must survive (flat strings, non-array values,
  mixed elements) that the authoring wall would reject at publish — the generated
  column is a pure DB property, computed however the row arrived. The reorder
  test goes through the real publish path with a registered tag.

  DB-backed; the SQL sandbox isolates it. `async: true` is safe (unique doc_ids
  in a private dataset).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @ds "tags-meta-parity-test"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    :ok
  end

  defp unique_id, do: "doc-#{System.unique_integer([:positive])}"

  # Insert a row straight into `documents` — bypasses the authoring wall so the
  # lock tests can carry arbitrary (incl. malformed) `content` shapes. The
  # generated columns are computed by Postgres on insert regardless.
  defp insert_doc!(content) do
    Repo.insert!(%Document{
      doc_id: unique_id(),
      type: "post",
      dataset: @ds,
      title: "Fixture #{System.unique_integer([:positive])}",
      status: "published",
      content: content,
      rev: Barkpark.Content.Writer.generate_rev()
    })
  end

  # ── 1. tags_meta ≡ the old inline CASE (the by-construction boost lock) ──────

  test "tags_meta equals the pre-swap CASE-over-content expression for every row" do
    # A spread of the shapes order_rank's boost had to survive: object tags with
    # integer / non-integer / missing strength, a flat-string legacy tag, a
    # non-array `tags` value, absent `tags`, an empty array, and mixed elements.
    for content <- [
          %{"tags" => [%{"tag" => "elixir", "strength" => 90, "rationale" => "r"}]},
          %{"tags" => [%{"tag" => "elixir", "strength" => "very-high"}]},
          %{"tags" => [%{"tag" => "elixir"}]},
          %{"tags" => ["elixir"]},
          %{"tags" => "not-an-array"},
          %{"tags" => []},
          %{"tags" => [%{"tag" => "a", "strength" => 5}, "loose", 42]},
          %{"body" => "no tags key at all"}
        ] do
      insert_doc!(content)
    end

    # For EVERY documents row: assert tags_meta is NOT DISTINCT FROM the exact
    # expression the boost subquery used before the swap. NULL-safe, so absent
    # `tags` (→ '[]'::jsonb both sides) is caught too.
    {:ok, %{rows: [[divergent]]}} =
      Repo.query("""
      SELECT count(*)
      FROM documents
      WHERE tags_meta IS DISTINCT FROM
        (CASE WHEN jsonb_typeof(content->'tags') = 'array'
              THEN content->'tags' ELSE '[]'::jsonb END)
      """)

    assert divergent == 0,
           "#{divergent} rows where tags_meta diverges from its source CASE expression"
  end

  # ── 2. slug_text ≡ the old content#>>'{slug}' field-similarity source ────────

  test "coalesce(slug_text,'') equals the pre-swap content#>>'{slug}' similarity source" do
    for content <- [
          %{"slug" => "quantum-widgets"},
          %{"slug" => ""},
          %{"author" => "no slug key"},
          %{}
        ] do
      insert_doc!(content)
    end

    # The field_similarity arm computes similarity(coalesce(<source>,''), q). The
    # swap changed <source> from content#>>'{slug}' to slug_text; assert the
    # coalesced inputs are identical for every row (a single-key #>> equals ->>).
    {:ok, %{rows: [[divergent]]}} =
      Repo.query("""
      SELECT count(*)
      FROM documents
      WHERE coalesce(slug_text, '') IS DISTINCT FROM coalesce(content#>>'{slug}', '')
      """)

    assert divergent == 0,
           "#{divergent} rows where slug_text diverges from the content#>>'{slug}' source"
  end

  # ── 3. End-to-end: the strength boost still orders, reading tags_meta ────────

  test "strength boost still reorders results after the tags_meta swap" do
    LabelFixtures.register_tags!(@ds, ["kelvarite"])

    # Query token "kelvarite" is ABSENT from both titles, so ts_rank + title
    # similarity are identical and ONLY the boost separates them. The strong doc
    # is published FIRST (older updated_at), so recency (order key #3) favors the
    # weak doc — the strong doc can only win via the key-#2 boost read from
    # tags_meta.
    strong = publish_tagged!("Vantar ridge survey", 90)
    weak = publish_tagged!("Molvik harbor census", 20)

    {hits, _total, _meta} = Content.search_documents("kelvarite", @ds)
    ids = Enum.map(hits, & &1.doc_id)

    strong_idx = Enum.find_index(ids, &(&1 == strong))
    weak_idx = Enum.find_index(ids, &(&1 == weak))

    assert strong_idx, "strong doc missing from results: #{inspect(ids)}"
    assert weak_idx, "weak doc missing from results: #{inspect(ids)}"

    assert strong_idx < weak_idx,
           "strength-90 doc must outrank strength-20 via the tags_meta boost"
  end

  defp publish_tagged!(title, strength) do
    id = unique_id()

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "_id" => id,
          "title" => title,
          "content" => %{
            "tags" => [%{"tag" => "kelvarite", "strength" => strength, "rationale" => "r"}]
          }
        },
        @ds
      )

    {:ok, _} = Content.publish_document(id, "post", @ds)
    id
  end
end
