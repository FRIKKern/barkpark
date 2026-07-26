defmodule Barkpark.Search.DocumentsRetrieverFacetCollapseParityTest do
  @moduledoc """
  Parity guard for search-latency slice c (task-5b052c7e19960390): the separate
  `count(id)` statement + the four per-dimension facet `GROUP BY`s (type / status
  / author_text / category_text) were collapsed into ONE `GROUP BY GROUPING SETS`
  pass in `count_and_facets/1`.

  The collapse must be behavior-identical. Two kinds of proof:

  1. Independent reference: an OUT-OF-BAND per-dimension `GROUP BY` (one query per
     facet, exactly the shape the pre-collapse path used) is shaped through the
     same put_facet contract (nil/'' labels dropped, biggest-count first, label
     tiebreak) and asserted EQUAL to the collapsed `meta.facets` — plus a raw
     `count(id)` equal to `total`. This is the real drift lock: if GROUPING SETS
     ever mis-routed a bucket or dropped/duplicated a row, the two disagree.

  2. Hand-computed distributions: explicit expected buckets/counts across a
     mixed author × category × status × type spread on BOTH the browse path
     (base = whole scoped set) AND a real-query path (base carries the match
     predicate), the empty-facet case (a doc with no author/category makes NO
     empty-label bucket), and the no-hit case (a query matching nothing yields
     count 0 with empty facets — proving the GROUPING SETS `()` grand-total row
     still fires over an empty match set).

  Seeds use `create_document` WITHOUT publishing so a doc's `status` is preserved
  (publish forces status → "published"); the plain, non-`drafts.`-prefixed doc_id
  makes them visible on the default published perspective.

  DB-backed; the SQL sandbox isolates it. `async: true` is safe (each test seeds
  a private workspace + dataset).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @ds "facet-collapse-parity-test"

  defp setup_scope do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    # W10 schema-visibility gate: anonymous searches (no caller_context) are
    # restricted to PUBLIC schema types — seed the types under test as public
    # so the facet-collapse parity runs over admitted types.
    for type <- ~w(post note) do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public"},
          @ds,
          scope
        )
    end

    scope
  end

  defp unique_id, do: "doc-#{System.unique_integer([:positive])}"

  # Publish so the doc is visible on the default published perspective, then set
  # the `status` column directly: `publish_document` forces status → "published",
  # so an `update_all` override is the only way to seed status variety for the
  # status facet dimension.
  defp seed!(type, status, content, scope) do
    doc_id = unique_id()

    attrs = %{
      "doc_id" => doc_id,
      "type" => type,
      "title" => "Doc #{doc_id}",
      "content" => content
    }

    {:ok, _} = Content.create_document(type, attrs, @ds, scope)
    {:ok, _} = Content.publish_document(doc_id, type, @ds, scope)

    {1, _} =
      from(d in Document, where: d.doc_id == ^doc_id and d.type == ^type and d.dataset == ^@ds)
      |> Repo.update_all(set: [status: status])

    doc_id
  end

  # ── Independent reference: the pre-collapse per-dimension GROUP BY path ──────

  # Mirror of the retriever's private `put_facet/3`: drop nil/'' labels, sort
  # biggest-count first with an ascending-label tiebreak. Kept verbatim so the
  # reference and the production shaping are the SAME contract; the collapse
  # changes only the AGGREGATION (grouping sets) + routing, not this shaping.
  defp put_facet(map, name, rows) do
    buckets =
      rows
      |> Enum.reject(fn {label, _} -> label in [nil, ""] end)
      |> Enum.map(fn {label, count} -> %{"label" => to_string(label), "count" => count} end)
      |> Enum.sort_by(fn %{"label" => label, "count" => count} -> {-count, label} end)

    if buckets == [], do: map, else: Map.put(map, name, buckets)
  end

  # The base predicate the retriever narrows to for THIS test's scope: dataset +
  # workspace + published perspective. Only this test's uniquely-scoped rows
  # match, so it reproduces the retriever's `base` for a browse ("") query.
  defp reference_base(scope) do
    ws = Keyword.fetch!(scope, :workspace_id)

    from(d in Document,
      where: d.dataset == ^@ds and d.workspace_id == ^ws and not like(d.doc_id, "drafts.%")
    )
  end

  defp reference_group(base, field) do
    base
    |> group_by([d], field(d, ^field))
    |> select([d], {field(d, ^field), count(d.id)})
    |> Repo.all()
  end

  defp reference_facets(scope) do
    base = reference_base(scope)

    %{}
    |> put_facet("type", reference_group(base, :type))
    |> put_facet("status", reference_group(base, :status))
    |> put_facet("author", reference_group(base, :author_text))
    |> put_facet("category", reference_group(base, :category_text))
  end

  defp reference_count(scope) do
    reference_base(scope) |> select([d], count(d.id)) |> Repo.one() || 0
  end

  # ── 1. Collapsed output == independent per-dimension reference ───────────────

  test "browse facets + total equal the independent per-dimension GROUP BY reference" do
    scope = setup_scope()

    # A mixed spread over every dimension, with repetition so counts vary (and
    # equal-count ties — post/note both 3 — exercise the deterministic tiebreak).
    for {type, status, author, category} <- [
          {"post", "published", "Ada Lovelace", "engineering"},
          {"post", "published", "Ada Lovelace", "engineering"},
          {"post", "archived", "Grace Hopper", "engineering"},
          {"note", "published", "Grace Hopper", "science"},
          {"note", "draft", "Alan Turing", "science"},
          {"note", "published", "Ada Lovelace", "math"}
        ] do
      seed!(type, status, %{"author" => author, "category" => category}, scope)
    end

    {_hits, total, meta} = Content.search_documents("", @ds, scope)

    assert total == 6
    assert total == reference_count(scope)
    assert meta.facets == reference_facets(scope)

    # Sanity: the reference is non-trivial — all four dimensions present, and
    # status/type carry MULTIPLE buckets — so the equality is a real comparison,
    # not vacuous {} == {} or a single-bucket coincidence.
    assert Map.keys(meta.facets) |> Enum.sort() == ["author", "category", "status", "type"]
    assert length(meta.facets["status"]) == 3
    assert length(meta.facets["type"]) == 2
  end

  # ── 2. Empty-facet: a doc with no author/category makes no empty bucket ──────

  test "a doc with no author/category contributes no empty-label facet bucket" do
    scope = setup_scope()

    seed!("post", "published", %{"author" => "Ada Lovelace", "category" => "engineering"}, scope)
    # No author, no category keys at all.
    seed!("post", "published", %{}, scope)
    # Present but empty strings — dropped by the nil/'' guard, same as absent.
    seed!("post", "published", %{"author" => "", "category" => ""}, scope)

    {_hits, total, meta} = Content.search_documents("", @ds, scope)

    assert total == 3
    assert meta.facets == reference_facets(scope)

    # Only the one real author/category survives; the empty/absent rows drop out.
    assert meta.facets["author"] == [%{"label" => "Ada Lovelace", "count" => 1}]
    assert meta.facets["category"] == [%{"label" => "engineering", "count" => 1}]
  end

  # ── 3. Real-query path: base carries the match predicate ────────────────────

  test "facets over a real-query match set equal the hand-computed buckets" do
    scope = setup_scope()

    # Three docs share the query token "zorptastic" in their slug; a fourth does
    # not and must be excluded from both count AND facets.
    seed!(
      "post",
      "published",
      %{"author" => "Ada", "category" => "x", "slug" => "zorptastic-a"},
      scope
    )

    seed!(
      "post",
      "archived",
      %{"author" => "Ada", "category" => "y", "slug" => "zorptastic-b"},
      scope
    )

    seed!(
      "note",
      "published",
      %{"author" => "Bo", "category" => "x", "slug" => "zorptastic-c"},
      scope
    )

    seed!(
      "post",
      "published",
      %{"author" => "Ada", "category" => "x", "slug" => "unrelated-d"},
      scope
    )

    {_hits, total, meta} = Content.search_documents("zorptastic", @ds, scope)

    assert total == 3

    assert Map.new(meta.facets["type"], &{&1["label"], &1["count"]}) == %{
             "post" => 2,
             "note" => 1
           }

    assert Map.new(meta.facets["status"], &{&1["label"], &1["count"]}) ==
             %{"published" => 2, "archived" => 1}

    assert Map.new(meta.facets["author"], &{&1["label"], &1["count"]}) == %{"Ada" => 2, "Bo" => 1}
    assert Map.new(meta.facets["category"], &{&1["label"], &1["count"]}) == %{"x" => 2, "y" => 1}

    # Biggest-count-first ordering is preserved by the collapse.
    assert hd(meta.facets["author"])["label"] == "Ada"
  end

  # ── 4. No-hit: empty match set → count 0, empty facets (the () set fires) ────

  test "a query matching nothing yields count 0 and empty facets" do
    scope = setup_scope()
    seed!("post", "published", %{"author" => "Ada", "slug" => "present"}, scope)

    {hits, total, meta} = Content.search_documents("nothingmatchesthisxyzzy", @ds, scope)

    assert hits == []
    assert total == 0
    # An empty match set: the GROUPING SETS `()` grand total still emits (count
    # 0) while the column sets emit nothing, so every dimension is dropped → %{}.
    assert meta.facets == %{}
  end
end
