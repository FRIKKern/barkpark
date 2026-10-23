defmodule Barkpark.Content.QueryReferenceArrayFiltersTest do
  @moduledoc """
  `in` and `contains` on an array of references read an index, not every
  document of the type.

  On the gyldendal-no catalogue (18,000 products),
  `filter[bokbasen.themaCodes][in]=thema.LBB,thema.LNDC` and
  `filter[bokbasen.themaCodes][contains]=thema.LBB` took 0.8 to 0.9 s warm and
  6 to 7 s cold, because each test decompressed every product's `content`.

    * `in` keeps its test and is first narrowed to the rows holding one of its
      containment probes, each looked up in `documents_content_path_idx`. The
      rows it keeps do not change.
    * `contains` on a field the schema declares as an array of references
      matches a reference whose id contains the text, narrowed first by
      `documents_content_refs_trgm_idx`. On any other field it still matches
      the field's text.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Query
  alias Barkpark.Repo

  @type_name "refarrayfilterbook"
  @refs_text "jsonb_path_query_array(d0.\"content\", 'strict $.** ? (exists(@._ref))._ref')::text ILIKE"

  setup do
    # Unique per run: this database is shared with every other agent's suite.
    dataset = "ref_array_filters_#{System.unique_integer([:positive])}"
    ref = %{"type" => "reference", "to" => [%{"type" => "themaCode"}]}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Ref array filter book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "codes", "type" => "arrayOf", "of" => ref},
            %{
              "name" => "meta",
              "type" => "object",
              "fields" => [%{"name" => "codes", "type" => "arrayOf", "of" => ref}]
            },
            %{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}},
            %{"name" => "group", "type" => "string"},
            %{"name" => "rank", "type" => "number"}
          ]
        },
        dataset
      )

    ctx = %{dataset: dataset}

    doc!(ctx, "a", %{
      "codes" => [ref("thema.LBB"), ref("thema.JBSF1")],
      "meta" => %{"codes" => [ref("thema.LBB")]},
      "tags" => ["801", "327"],
      "group" => "x",
      "rank" => 801
    })

    doc!(ctx, "b", %{
      "codes" => [ref("thema.LBBR")],
      "meta" => %{"codes" => [ref("thema.LNDC")]},
      "tags" => ["802"],
      "group" => "y",
      "rank" => 5
    })

    # The key holds `thema.LBB`; the reference is to `thema.YFB`.
    doc!(ctx, "c", %{
      "codes" => [%{"_key" => "thema.LBB", "_ref" => "thema.YFB", "_type" => "reference"}]
    })

    doc!(ctx, "d", %{"group" => "z"})

    # A bare id in the array, as imported content sometimes stores it.
    doc!(ctx, "e", %{"codes" => ["thema.LNDC"]})

    ctx
  end

  defp ref(id), do: %{"_key" => id, "_ref" => id, "_type" => "reference", "_weak" => true}

  defp doc!(ctx, id, content) do
    {:ok, _} =
      Content.create_document(@type_name, %{"doc_id" => id, "content" => content}, ctx.dataset)

    {:ok, _} = Content.publish_document(id, @type_name, ctx.dataset)
  end

  defp ids(ctx, filter_map) do
    @type_name
    |> Query.list_documents(ctx.dataset, perspective: :published, filter_map: filter_map)
    |> Enum.map(& &1.doc_id)
    |> Enum.sort()
  end

  defp filtered(ctx, filter_map) do
    from(d in Document, where: d.type == ^@type_name and d.dataset == ^ctx.dataset)
    |> Query.apply_search_filters(filter_map, @type_name, ctx.dataset, [])
  end

  defp sql(ctx, filter_map) do
    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Repo, filtered(ctx, filter_map))
    sql
  end

  describe "in" do
    test "keeps the documents whose array holds one of the references", ctx do
      assert ids(ctx, %{"codes" => %{"in" => ["thema.LBB", "thema.LNDC"]}}) == ["a", "e"]
      assert ids(ctx, %{"meta.codes" => %{"in" => ["thema.LNDC"]}}) == ["b"]
      assert ids(ctx, %{"codes" => %{"in" => ["thema.LB"]}}) == []
    end

    test "keeps scalar, string-array and number fields as before", ctx do
      assert ids(ctx, %{"tags" => %{"in" => ["801", "802"]}}) == ["a", "b"]
      assert ids(ctx, %{"group" => %{"in" => ["y", "nope"]}}) == ["b"]
      assert ids(ctx, %{"rank" => %{"in" => ["801"]}}) == ["a"]
    end

    test "a long list keeps the same documents", ctx do
      values = Enum.map(1..200, &"thema.X#{&1}") ++ ["thema.LBBR"]
      assert ids(ctx, %{"codes" => %{"in" => values}}) == ["b"]
    end

    test "a path through an array position is tested without the index", ctx do
      assert ids(ctx, %{"tags.0" => %{"in" => ["802"]}}) == ["b"]
      refute sql(ctx, %{"tags.0" => %{"in" => ["802"]}}) =~ "CROSS JOIN LATERAL"
    end

    test "looks each probe up in documents_content_path_idx, never @> ANY on the row", ctx do
      filter = %{"codes" => %{"in" => ["thema.LBB", "thema.LNDC"]}}
      sql = sql(ctx, filter)

      assert sql =~ "CROSS JOIN LATERAL (SELECT s.id FROM documents AS s WHERE s.content @> p.probe OFFSET 0)"
      refute sql =~ "@> ANY"

      # At sandbox scale a scan is cheaper; with scans penalised the plan
      # shows whether the lookup can use the index at all.
      Repo.query!("SET LOCAL enable_seqscan = off")
      plan = Repo.explain(:all, filtered(ctx, filter))
      assert plan =~ "documents_content_path_idx", "expected the GIN lookup, got:\n#{plan}"
    end
  end

  describe "contains on an array of references" do
    test "matches a reference whose id contains the text, in any case", ctx do
      assert ids(ctx, %{"codes" => %{"contains" => "thema.LBB"}}) == ["a", "b"]
      assert ids(ctx, %{"codes" => %{"contains" => "THEMA.lbb"}}) == ["a", "b"]
      assert ids(ctx, %{"meta.codes" => %{"contains" => "LND"}}) == ["b"]
    end

    test "reads the ids, not the keys or the text of the array", ctx do
      # The text of the array holds `_key`, `_type` and `_weak` too.
      assert ids(ctx, %{"codes" => %{"contains" => "reference"}}) == []
      refute "c" in ids(ctx, %{"codes" => %{"contains" => "thema.LBB"}})
    end

    test "notContains keeps every other document, with or without the field", ctx do
      assert ids(ctx, %{"codes" => %{"notContains" => "thema.LBB"}}) == ["c", "d", "e"]
    end

    test "a value the index cannot narrow is still tested", ctx do
      assert ids(ctx, %{"codes" => %{"contains" => "LB"}}) == ["a", "b"]
      refute sql(ctx, %{"codes" => %{"contains" => "LB"}}) =~ @refs_text

      assert ids(ctx, %{"codes" => %{"contains" => ~s(thema.LBB")}}) == []
      refute sql(ctx, %{"codes" => %{"contains" => ~s(thema.LBB")}}) =~ @refs_text
    end

    test "is narrowed by documents_content_refs_trgm_idx", ctx do
      assert sql(ctx, %{"codes" => %{"contains" => "thema.LBB"}}) =~ @refs_text

      # The bare expression, so the plan shows only whether it reaches the index.
      bare =
        from(d in Document,
          where:
            fragment(
              "jsonb_path_query_array(?, 'strict $.** \\? (exists(@._ref))._ref')::text ILIKE ?",
              d.content,
              ^"%thema.lbb%"
            ),
          select: d.id
        )

      Repo.query!("SET LOCAL enable_seqscan = off")
      plan = Repo.explain(:all, bare)
      assert plan =~ "documents_content_refs_trgm_idx", "expected the trigram index, got:\n#{plan}"
    end
  end

  describe "contains on any other field" do
    test "still matches the text of the field", ctx do
      assert ids(ctx, %{"tags" => %{"contains" => "80"}}) == ["a", "b"]
      # The text of `["801", "327"]` holds `", "`.
      assert ids(ctx, %{"tags" => %{"contains" => ~s(", ")}}) == ["a"]
      assert ids(ctx, %{"group" => %{"contains" => "Y"}}) == ["b"]
    end
  end
end
