defmodule Barkpark.Search.DocumentsRetrieverGencolParityTest do
  @moduledoc """
  Parity guard for search-latency slice b (task-2da0f8ab1580d7d6): the slug-ILIKE
  match arm + the author/category facet GROUP BYs were moved off the per-row
  `content->>...` jsonb detoast onto the `slug_text`/`author_text`/`category_text`
  GENERATED STORED columns (migration 20260718090000).

  The swap must be behavior-identical BY CONSTRUCTION. Two proofs:

  1. Column ≡ source expression: for every seeded row, the generated column
     equals the exact jsonb expression the query sites used before the swap
     (`coalesce(content->>'slug','')`, `content->>'author'`, `content->>'category'`).
     This is the real parity lock — it FAILS if the migration's GENERATED
     expression ever drifts from the query-site expression.

  2. End-to-end: a slug-only match still returns the doc, and author/category
     facet buckets are identical in shape/counts to what the jsonb GROUP BY
     produced. Proves the retriever reads the new columns correctly.

  DB-backed; the SQL sandbox isolates it. `async: true` is safe here (each test
  seeds unique doc_ids in a private dataset); a concurrent DB partition run
  should set a distinct MIX_TEST_PARTITION per D55.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Repo

  @ds "gencol-parity-test"

  defp setup_scope do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    # W10 schema-visibility gate: anonymous searches (no caller_context) are
    # restricted to PUBLIC schema types — seed "post" as one; the generated
    # column parity stays the behaviour under test.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public"},
        @ds,
        scope
      )

    scope
  end

  defp unique_id, do: "doc-#{System.unique_integer([:positive])}"

  defp create_published!(type, attrs, scope) do
    doc_id = Map.fetch!(attrs, "doc_id")
    {:ok, _} = Content.create_document(type, attrs, @ds, scope)
    {:ok, _} = Content.publish_document(doc_id, type, @ds, scope)
    doc_id
  end

  # ── 1. Column ≡ source expression (the by-construction parity lock) ─────────

  test "generated columns equal the pre-swap jsonb expressions for every row" do
    scope = setup_scope()

    # A spread of shapes: full triple, slug-only, missing keys, empty strings.
    _ =
      create_published!(
        "post",
        %{
          "doc_id" => unique_id(),
          "title" => "Full Triple",
          "content" => %{
            "slug" => "quantum-widgets",
            "author" => "Ada Lovelace",
            "category" => "engineering"
          }
        },
        scope
      )

    _ =
      create_published!(
        "post",
        %{
          "doc_id" => unique_id(),
          "title" => "Slug Only",
          "content" => %{"slug" => "orphan-slug"}
        },
        scope
      )

    _ =
      create_published!(
        "post",
        %{"doc_id" => unique_id(), "title" => "No Facet Keys", "content" => %{"body" => "x"}},
        scope
      )

    _ =
      create_published!(
        "post",
        %{
          "doc_id" => unique_id(),
          "title" => "Empty Strings",
          "content" => %{"slug" => "", "author" => "", "category" => ""}
        },
        scope
      )

    # For EVERY documents row: assert the generated column is NOT DISTINCT FROM
    # the exact expression each query site used before the swap. `IS DISTINCT
    # FROM` compares NULL-safely, so a divergence on absent keys is caught too.
    {:ok, %{rows: [[divergent]]}} =
      Repo.query("""
      SELECT count(*)
      FROM documents
      WHERE slug_text IS DISTINCT FROM coalesce(content->>'slug', '')
         OR author_text IS DISTINCT FROM (content->>'author')
         OR category_text IS DISTINCT FROM (content->>'category')
      """)

    assert divergent == 0,
           "#{divergent} rows where a generated column diverges from its source jsonb expression"
  end

  # ── 2a. End-to-end: slug-only match still hits via slug_text ────────────────

  test "a doc matched ONLY by its slug is returned (slug_text ILIKE arm)" do
    scope = setup_scope()

    slug_id =
      create_published!(
        "post",
        %{
          "doc_id" => unique_id(),
          # Title shares no token with the query; the ONLY match path is the slug.
          "title" => "Completely Unrelated Heading",
          "content" => %{"slug" => "photosynthesis-primer"}
        },
        scope
      )

    {hits, total, _meta} = Content.search_documents("photosynthesis", @ds, scope)

    assert total >= 1

    assert slug_id in Enum.map(hits, & &1.doc_id),
           "slug-only doc must match via the slug_text ILIKE arm"
  end

  # ── 2b. End-to-end: author/category facet buckets identical in shape/counts ─

  test "author & category facets bucket by the generated columns, empty labels dropped" do
    scope = setup_scope()

    for {author, category} <- [
          {"Ada Lovelace", "engineering"},
          {"Ada Lovelace", "engineering"},
          {"Grace Hopper", "engineering"},
          {"Grace Hopper", "science"}
        ] do
      create_published!(
        "post",
        %{
          "doc_id" => unique_id(),
          "title" => "Faceted #{author} #{category}",
          "content" => %{"author" => author, "category" => category}
        },
        scope
      )
    end

    # A doc with no author/category — must NOT create an empty-label bucket.
    create_published!(
      "post",
      %{"doc_id" => unique_id(), "title" => "Unfaceted", "content" => %{}},
      scope
    )

    {_hits, _total, meta} = Content.search_documents("", @ds, scope)
    facets = meta.facets

    author_counts =
      facets |> Map.fetch!("author") |> Map.new(&{&1["label"], &1["count"]})

    category_counts =
      facets |> Map.fetch!("category") |> Map.new(&{&1["label"], &1["count"]})

    assert author_counts == %{"Ada Lovelace" => 2, "Grace Hopper" => 2}
    assert category_counts == %{"engineering" => 3, "science" => 1}

    # The unfaceted doc contributes NO empty-label bucket (parity with the old
    # jsonb GROUP BY, where put_facet drops nil/"" labels).
    refute Enum.any?(facets["author"], &(&1["label"] == ""))
    refute Enum.any?(facets["category"], &(&1["label"] == ""))
  end
end
