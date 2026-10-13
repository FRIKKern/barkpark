defmodule BarkparkWeb.GroqLargeDatasetTest do
  @moduledoc """
  GROQ over one type with more documents than one `*[...]` may load (10,000
  by default). Each query below is the shape of a page query from a Sanity
  site that this limit refused before `references()`, array membership and
  `count()` were answered in SQL. The data is synthetic: 10,500 products from
  `Barkpark.Test.GroqSyntheticProducts`, whose moduledoc lists what each
  product holds. Their families, series, contributors, departments and slugs
  give the expected results below.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Test.GroqSyntheticProducts

  @dataset "groq_big"
  @version "v2025-02-19"
  @products 10_500

  @sibling_query """
  *[_type == "product" && isbn == $isbn][0]{
    _id,
    "siblings": *[
      _type == "product" && _id != ^._id && (defined(isbn) || defined(onix.isbn)) && (
        (references(^._id) && (
          mainProduct._ref == ^._id ||
          ^._id in bokbasen.languageFormatVariants[]._ref
        )) ||
        _id == ^.mainProduct._ref ||
        (defined(^.mainProduct._ref) && references(^.mainProduct._ref) && (
          mainProduct._ref == ^.mainProduct._ref ||
          ^.mainProduct._ref in bokbasen.languageFormatVariants[]._ref
        )) ||
        _id in ^.bokbasen.languageFormatVariants[]._ref ||
        (
          defined(^.onix.publicationId) && defined(onix.publicationId) &&
          onix.publicationId == ^.onix.publicationId &&
          lower(title) == lower(^.title)
        )
      ) &&
      (!defined(bokbasen.undervisningsmateriell) || !defined(^.bokbasen.undervisningsmateriell))
    ] | order(_id asc)._id
  }
  """

  @series_query """
  *[_type == "product" && !(_id in path("drafts.**")) && defined(isbn) &&
    isMainProduct == true && references($seriesId)]{_id}
  """

  @contributor_query """
  *[_type == "product" && references($contributorId) &&
    count(onix.contributors[contributor._ref == $contributorId && role._ref in ["A01", "B01"]]) > 0].isbn
  """

  @redirect_query """
  *[($paths[0] in slugHistory[].value || $paths[1] in slugHistory[].value) &&
    count((slugHistory)[match == "url" && lower(value) in $paths]) > 0 &&
    (isHidden != true || _type == "article")] | order(_updatedAt desc)[0]{_id, _type}
  """

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-big", name: "GROQ big"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    for type <- ["product", "article", "department"] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )
    end

    {:ok, _} = Content.create_document("product", %{"_id" => "template"}, @dataset, scope)
    {:ok, _} = Content.publish_document("template", "product", @dataset, scope)
    GroqSyntheticProducts.seed!(@dataset, @products)

    {:ok, _} =
      Content.create_document(
        "article",
        %{
          "_id" => "a1",
          "isHidden" => true,
          "slugHistory" => [%{"_key" => "s", "match" => "url", "value" => "/bok/p123"}]
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("a1", "article", @dataset, scope)

    for id <- ["dept-big", "dept-small"] do
      {:ok, _} = Content.create_document("department", %{"_id" => id}, @dataset, scope)
      {:ok, _} = Content.publish_document(id, "department", @dataset, scope)
    end

    token = "groq-big-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "groq big", @dataset, ["read", "write"], ws.id)

    {:ok, token: token, scope: scope}
  end

  defp path, do: "/w/groq-big/p/site/#{@version}/data/query/#{@dataset}"

  defp query(token, query, params, extra \\ %{}) do
    body = Map.merge(%{"query" => query, "params" => params}, extra)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(path(), Jason.encode!(body))
  end

  defp result!(token, q, params, extra \\ %{}),
    do: token |> query(q, params, extra) |> json_response(200) |> Map.fetch!("result")

  defp isbn(g), do: "978" <> String.pad_leading(Integer.to_string(g), 7, "0")

  defp with_groq_config(config) do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, config)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)
  end

  test "the dataset is above the per-fetch limit: a type scan without an index condition is refused",
       %{token: token} do
    body =
      token
      |> query(~s'*[_type == "product" && isMainProduct == true && count(slugHistory) > 0]', %{})
      |> json_response(422)

    assert body["error"]["description"] =~ "more than 10000 documents"
  end

  describe "the four shapes answer over 10,500 products" do
    test "sibling editions inside a projection: references(^._id) in an ||", %{token: token} do
      assert result!(token, @sibling_query, %{"isbn" => isbn(5)}) == %{
               "_id" => "p5",
               "siblings" => ["p4", "p405", "p6", "p7"]
             }

      assert result!(token, @sibling_query, %{"isbn" => isbn(4)}) == %{
               "_id" => "p4",
               "siblings" => ["p5", "p6", "p7"]
             }

      assert result!(token, @sibling_query, %{"isbn" => isbn(9000)}) == %{
               "_id" => "p9000",
               "siblings" => []
             }
    end

    test "a series page: references($seriesId) with isMainProduct", %{token: token} do
      expected =
        for g <- 1..@products,
            rem(g, 50) == 3,
            not (g in 4..400 and rem(g, 4) != 0),
            do: "p#{g}"

      ids = token |> result!(@series_query, %{"seriesId" => "series-3"}) |> Enum.map(& &1["_id"])
      assert Enum.sort(ids) == Enum.sort(expected)
      assert length(ids) == 203
    end

    test "an author's books: references($contributorId) with a role check", %{token: token} do
      expected = for g <- 1..@products, rem(g, 700) == 8, do: isbn(g)

      assert Enum.sort(result!(token, @contributor_query, %{"contributorId" => "c-8"})) ==
               expected

      # c-7 sits only on odd products, whose role is B06: SQL narrows to 15
      # candidates and the evaluator's role check rejects all of them.
      assert result!(token, @contributor_query, %{"contributorId" => "c-7"}) == []
    end

    test "a redirect lookup with no _type: $path in slugHistory[].value", %{token: token} do
      assert result!(token, @redirect_query, %{"paths" => ["/bok/p9000", "/bok/P9000"]}) == %{
               "_id" => "p9000",
               "_type" => "product"
             }

      # p123 and the article a1 both carry /bok/p123; a1 is the newer one.
      assert result!(token, @redirect_query, %{"paths" => ["/bok/p123", "/bok/P123"]}) == %{
               "_id" => "a1",
               "_type" => "article"
             }

      assert result!(token, @redirect_query, %{"paths" => ["/nope", "/NOPE"]}) == nil
    end
  end

  test "SQL narrows each shape to a few hundred candidates at most", %{token: token} do
    with_groq_config(max_documents_per_fetch: 250)

    assert %{"siblings" => [_ | _]} = result!(token, @sibling_query, %{"isbn" => isbn(5)})
    assert length(result!(token, @series_query, %{"seriesId" => "series-3"})) == 203
    assert length(result!(token, @contributor_query, %{"contributorId" => "c-8"})) == 15
    assert %{"_id" => "a1"} = result!(token, @redirect_query, %{"paths" => ["/bok/p123", "x"]})
  end

  test "references() reads documents_content_refs_idx", %{token: token} do
    plans = explain_reads(fn -> result!(token, @series_query, %{"seriesId" => "series-3"}) end)
    assert Enum.any?(plans, &(&1 =~ "documents_content_refs_idx")), Enum.join(plans, "\n---\n")
  end

  test "the drafts perspective tests references() against the draft, not its published twin",
       %{token: token, scope: scope} do
    # p8 references series-8 when published; its draft moves it to series-99.
    %{rows: [[content]]} =
      Repo.query!("SELECT content FROM documents WHERE doc_id = 'p8' AND dataset = $1", [
        @dataset
      ])

    draft = Map.merge(content, %{"_id" => "p8", "series" => %{"_ref" => "series-99"}})
    {:ok, _} = Content.create_document("product", draft, @dataset, scope)

    q = ~s'*[_type == "product" && references($s)]._id'

    published = result!(token, q, %{"s" => "series-8"})
    assert "p8" in published

    drafts = result!(token, q, %{"s" => "series-8"}, %{"perspective" => "drafts"})
    refute "p8" in drafts
    assert length(drafts) == length(published) - 1

    assert result!(token, q, %{"s" => "series-99"}, %{"perspective" => "drafts"}) == ["p8"]
    assert result!(token, q, %{"s" => "series-99"}) == []
  end

  describe "count(*[...]) with an exact filter is a SQL count" do
    @main_products 10_500 - 297

    test "a type, a field equality and a ^ equality inside a projection", %{token: token} do
      # The template row is a product too.
      assert result!(token, ~s'count(*[_type == "product"])', %{}) == @products + 1

      assert result!(token, ~s'count(*[_type == "product" && isMainProduct == true])', %{}) ==
               @main_products

      assert result!(
               token,
               ~s'*[_type == "department"] | order(_id asc){_id, "n": count(*[_type == "product" && department._ref == ^._id])}',
               %{}
             ) == [%{"_id" => "dept-big", "n" => 10_200}, %{"_id" => "dept-small", "n" => 300}]
    end

    test "it loads no documents to count", %{token: token} do
      with_groq_config(max_documents_per_fetch: 5, max_documents_loaded: 5)

      assert result!(token, ~s'count(*[_type == "product" && department._ref == $d])', %{
               "d" => "dept-big"
             }) == 10_200

      # A filter SQL cannot match exactly still loads, and is refused.
      body =
        token
        |> query(~s'count(*[_type == "product" && isbn > "0"])', %{})
        |> json_response(422)

      assert body["error"]["type"] == "queryLimitError"
    end

    test "the SQL count equals the evaluator's count of the loaded documents", %{
      token: token,
      scope: scope
    } do
      # p8's draft moves it from series-8 to series-9.
      %{rows: [[content]]} =
        Repo.query!("SELECT content FROM documents WHERE doc_id = 'p8' AND dataset = $1", [
          @dataset
        ])

      draft = Map.merge(content, %{"_id" => "p8", "series" => %{"_ref" => "series-9"}})
      {:ok, _} = Content.create_document("product", draft, @dataset, scope)

      for perspective <- ["published", "drafts", "raw"],
          series <- ["series-8", "series-9"] do
        filter = ~s'_type == "product" && series._ref == $s'
        params = %{"s" => series}
        extra = %{"perspective" => perspective}

        counted = result!(token, "count(*[#{filter}])", params, extra)
        # `[0...100000]` makes the count read the loaded list.
        loaded = result!(token, "count(*[#{filter}][0...100000])", params, extra)

        assert counted == loaded, "#{perspective} #{series}: #{counted} != #{loaded}"
      end

      assert result!(token, ~s'count(*[_type == "product" && series._ref == "series-9"])', %{}, %{
               "perspective" => "drafts"
             }) == 211

      assert result!(token, ~s'count(*[_type == "product" && series._ref == "series-9"])', %{}, %{
               "perspective" => "raw"
             }) == 211
    end
  end

  # EXPLAIN for every documents read the function sends that carries a GROQ
  # pushdown condition, with the parameters it ran with.
  defp explain_reads(fun) do
    ref = make_ref()
    parent = self()
    handler = "groq-explain-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ -> send(parent, {ref, meta.query, meta.params}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect(ref, [])
    |> Enum.filter(fn {sql, _} ->
      sql =~ "FROM \"documents\"" and
        sql =~ "jsonb_path_query_array"
    end)
    |> Enum.map(fn {sql, params} ->
      Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)
    end)
  end

  defp collect(ref, acc) do
    receive do
      {^ref, sql, params} -> collect(ref, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
