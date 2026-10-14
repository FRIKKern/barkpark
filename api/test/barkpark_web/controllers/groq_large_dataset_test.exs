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
  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}
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

    scoped_conn()
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
    plans =
      explain_reads("jsonb_path_query_array", fn ->
        result!(token, @series_query, %{"seriesId" => "series-3"})
      end)

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

      # A filter SQL cannot match exactly is scanned in chunks, which keep
      # nothing, so the limits do not refuse it.
      assert result!(token, ~s'count(*[_type == "product" && isbn > "0"])', %{}) == @products
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

  describe "count() over array lengths and defined()" do
    # Each shape, its count over the 10,500 products plus the three below.
    # Every product has one contributor; p<g> with g mod 4 == 1 in 5..397
    # has one language variant.
    @shapes [
      {~s'count(onix.contributors) > 0', @products + 1},
      {~s'count(onix.contributors) >= 1', @products + 1},
      {~s'0 < count(onix.contributors)', @products + 1},
      {~s'count(onix.contributors) == 0', 1},
      {~s'count(onix.contributors) < 2', @products + 1},
      {~s'count(onix.contributors) <= 1', @products + 1},
      {~s'count(onix.contributors) == 2', 1},
      {~s'defined(onix.contributors[0])', @products},
      {~s'defined(onix.contributors[1])', 1},
      {~s'defined(onix.contributors[-1])', @products + 1},
      {~s'defined(onix.contributors)', @products + 3},
      {~s'count(bokbasen.languageFormatVariants) > 0', 99},
      {~s'defined(bokbasen.languageFormatVariants[0])', 99}
    ]

    setup %{scope: scope} do
      # e1 has no contributors, e2 a string where the array would be, e3 a
      # null first contributor.
      for {id, contributors} <- [{"e1", []}, {"e2", "none"}, {"e3", [nil, %{"_key" => "k"}]}] do
        doc = %{"_id" => id, "onix" => %{"contributors" => contributors}}
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
        {:ok, _} = Content.publish_document(id, "product", @dataset, scope)
      end

      :ok
    end

    test "each shape is a SQL count equal to the evaluator's count of the loaded documents",
         %{token: token} do
      sql =
        sql_reads(fn ->
          for {shape, expected} <- @shapes do
            q = ~s'count(*[_type == "product" && #{shape}])'
            assert result!(token, q, %{}) == expected, shape
          end
        end)

      # One count(*) per shape, and no chunked scan.
      assert Enum.count(sql, &(&1 =~ ~r/SELECT .*count\(/i)) >= length(@shapes)
      refute Enum.any?(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/))

      with_groq_config(max_documents_per_fetch: 20_000, max_documents_loaded: 40_000)

      for {shape, expected} <- @shapes do
        q = ~s'count(*[_type == "product" && #{shape}][0...100000])'
        assert result!(token, q, %{}) == expected, shape
      end
    end

    test "the shapes narrow a fetch in SQL", %{token: token} do
      with_groq_config(max_documents_per_fetch: 150)

      assert token
             |> result!(
               ~s'*[_type == "product" && defined(bokbasen.languageFormatVariants[0])]._id',
               %{}
             )
             |> length() == 99

      assert result!(token, ~s'*[_type == "product" && count(onix.contributors) == 0]._id', %{}) ==
               ["e1"]
    end

    test "the drafts perspective counts the draft, not its published twin",
         %{token: token, scope: scope} do
      # e1's draft gains a contributor; p8's draft loses its contributors.
      {:ok, _} =
        Content.create_document(
          "product",
          %{"_id" => "e1", "onix" => %{"contributors" => [%{"_key" => "k"}]}},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.create_document(
          "product",
          %{"_id" => "p8", "onix" => %{"contributors" => []}},
          @dataset,
          scope
        )

      for perspective <- ["published", "drafts", "raw"],
          shape <- [~s'count(onix.contributors) > 0', ~s'count(onix.contributors) == 0'] do
        filter = ~s'_type == "product" && #{shape}'
        extra = %{"perspective" => perspective}
        counted = result!(token, "count(*[#{filter}])", %{}, extra)

        with_groq_config(max_documents_per_fetch: 20_000, max_documents_loaded: 40_000)
        loaded = result!(token, "count(*[#{filter}][0...100000])", %{}, extra)
        with_groq_config([])

        assert counted == loaded, "#{perspective} #{shape}: #{counted} != #{loaded}"
      end

      assert result!(
               token,
               ~s'count(*[_type == "product" && count(onix.contributors) == 0])',
               %{},
               %{
                 "perspective" => "drafts"
               }
             ) == 1
    end
  end

  describe "count() over a filter SQL cannot match exactly" do
    test "reads in chunks and keeps only the total, so the limits do not apply",
         %{token: token} do
      with_groq_config(max_documents_per_fetch: 5, max_documents_loaded: 5)

      sql =
        sql_reads(fn ->
          # Even products have role A01.
          assert result!(
                   token,
                   ~s'count(*[_type == "product" && count(onix.contributors[role._ref == "A01"]) > 0])',
                   %{}
                 ) == div(@products, 2)
        end)

      assert Enum.count(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/)) == div(@products + 1, 500) + 1

      # A chunk does not count toward the documents a query loads.
      assert result!(
               token,
               ~s'{"n": count(*[_type == "product" && isbn > "0"]), "p": *[_id == "p5"][0]._id}',
               %{}
             ) == %{"n" => @products, "p" => "p5"}
    end

    test "inside a projection, per parent, with ^ and a -> in the filter", %{token: token} do
      q = """
      *[_type == "department"] | order(_id asc){
        _id,
        "n": count(*[_type == "product" && department->_id == ^._id && isbn > "0"])
      }
      """

      assert result!(token, q, %{}) == [
               %{"_id" => "dept-big", "n" => 10_200},
               %{"_id" => "dept-small", "n" => 300}
             ]
    end

    test "equals the evaluator's count of the loaded documents in each perspective",
         %{token: token, scope: scope} do
      %{rows: [[content]]} =
        Repo.query!("SELECT content FROM documents WHERE doc_id = 'p8' AND dataset = $1", [
          @dataset
        ])

      {:ok, _} =
        Content.create_document(
          "product",
          Map.merge(content, %{"_id" => "p8", "isbn" => "0"}),
          @dataset,
          scope
        )

      for perspective <- ["published", "drafts", "raw"] do
        extra = %{"perspective" => perspective}
        counted = result!(token, ~s'count(*[_type == "product" && isbn > "0"])', %{}, extra)

        with_groq_config(max_documents_per_fetch: 20_000, max_documents_loaded: 40_000)

        loaded =
          result!(token, ~s'count(*[_type == "product" && isbn > "0"][0...100000])', %{}, extra)

        with_groq_config([])

        assert counted == loaded, "#{perspective}: #{counted} != #{loaded}"
      end
    end

    test "the query timeout still applies", %{token: token} do
      with_groq_config(timeout_ms: 50)

      body =
        token
        |> query(~s'count(*[_type == "product" && isbn > "0"])', %{})
        |> json_response(422)

      assert body["error"]["description"] =~ "ran longer than 50 ms"
    end
  end

  describe "in over a list of values and over a closed subquery" do
    # 31 isbns spread over the products, as a page's list of ids.
    @isbns for g <- 1..31, do: "978" <> String.pad_leading(Integer.to_string(g * 331), 7, "0")

    # Each shape with its parameters. Every product holds `seriesIds`, the
    # array `["series-<g mod 50>"]`.
    @in_shapes [
      {~s'*[_type == "product" && isbn in $isbns]._id', %{"isbns" => @isbns}},
      {~s'*[_type == "product" && isbn in $isbns && isMainProduct == true]._id',
       %{"isbns" => @isbns}},
      {~s'*[_type == "product" && isbn in *[_type == "product" && references($c)].isbn]._id',
       %{"c" => "c-8"}},
      {~s'*[_type == "product" && _id in *[_type == "product" && references($c)]._id]._id',
       %{"c" => "c-8"}},
      {~s'*[_type == "product" && $s in seriesIds]._id', %{"s" => "series-3"}},
      {~s'*[_type == "product" && $s in seriesIds && isMainProduct == true]._id',
       %{"s" => "series-3"}},
      {~s'*[_type == "product" && code in [7, "x"]]._id', %{}},
      {~s'*[_type == "product" && isbn in []]._id', %{}}
    ]

    setup %{scope: scope} do
      first = hd(@isbns)

      # GROQ's `in` against the shapes SQL could get wrong: an array or an
      # object where the scalar is, a missing field, a number written as an
      # integer and as a float, a string where the array is, and an array
      # nested in the array.
      for {id, doc} <- [
            {"x1", %{"isbn" => [first], "seriesIds" => "series-3"}},
            {"x2", %{"isbn" => %{"v" => first}, "seriesIds" => [["series-3"]]}},
            {"x3", %{"code" => 7, "seriesIds" => ["other", "series-3"]}},
            {"x4", %{"code" => 7.0, "isbn" => nil}},
            {"x5", %{"code" => "7", "seriesIds" => []}}
          ] do
        {:ok, _} = Content.create_document("product", Map.put(doc, "_id", id), @dataset, scope)
        {:ok, _} = Content.publish_document(id, "product", @dataset, scope)
      end

      # p331 holds the first isbn and series-31; its draft holds neither, and
      # x5's draft joins series-3.
      %{rows: [[content]]} =
        Repo.query!("SELECT content FROM documents WHERE doc_id = 'p331' AND dataset = $1", [
          @dataset
        ])

      draft = Map.merge(content, %{"_id" => "p331", "isbn" => "0", "seriesIds" => ["series-3"]})
      {:ok, _} = Content.create_document("product", draft, @dataset, scope)

      {:ok, _} =
        Content.create_document(
          "product",
          %{"_id" => "x5", "seriesIds" => ["series-3"]},
          @dataset,
          scope
        )

      :ok
    end

    # Every product in `perspective`, read by type alone, then the query
    # evaluated over them in memory.
    defp in_memory(token, perspective, query, params) do
      with_groq_config(max_documents_per_fetch: 20_000, max_documents_loaded: 40_000)
      docs = result!(token, ~s'*[_type == "product"]', %{}, %{"perspective" => perspective})
      with_groq_config([])

      {:ok, tree} = Parser.parse(query, params)
      {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new(docs))
      value
    end

    test "each shape equals in-memory evaluation in every perspective", %{token: token} do
      for perspective <- ["published", "drafts", "raw"] do
        expected =
          Map.new(@in_shapes, fn {q, params} ->
            {q, in_memory(token, perspective, q, params)}
          end)

        for {q, params} <- @in_shapes do
          extra = %{"perspective" => perspective}
          got = result!(token, q, params, extra)
          want = expected[q]
          assert Enum.sort(got) == Enum.sort(want), "#{perspective} #{q}"

          counted =
            result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), params, extra)

          assert counted == length(want), "#{perspective} count #{q}"
        end
      end

      # Spot checks against the seed, published.
      assert length(
               result!(token, ~s'*[_type == "product" && isbn in $isbns]', %{"isbns" => @isbns})
             ) == 31

      assert Enum.sort(result!(token, ~s'*[_type == "product" && code in [7, "x"]]._id', %{})) ==
               ["x3", "x4"]

      assert "x3" in result!(token, ~s'*[_type == "product" && $s in seriesIds]._id', %{
               "s" => "series-3"
             })
    end

    test "SQL narrows each shape before the per-fetch limit", %{token: token} do
      with_groq_config(max_documents_per_fetch: 250)

      for {q, params} <- @in_shapes do
        assert is_list(result!(token, q, params)), q
      end
    end

    test "the counts are SQL counts, not chunked scans", %{token: token} do
      sql =
        sql_reads(fn ->
          for {q, params} <- @in_shapes do
            result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), params)
          end
        end)

      refute Enum.any?(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/))
    end

    test "the list is one jsonpath that documents_content_path_idx serves", %{token: token} do
      # The test asks whether the index CAN serve the predicate, not which plan
      # the planner prefers. Under a LIMIT the planner may pick a seq scan
      # depending on the table statistics other tests in the shard left behind,
      # which made this test fail in CI and pass locally. SET LOCAL lasts until
      # the sandbox transaction ends, so it touches this test only.
      Repo.query!("SET LOCAL enable_seqscan = off")

      plans =
        explain_reads("@?", fn ->
          result!(token, ~s'*[_type == "product" && isbn in $isbns]._id', %{"isbns" => @isbns})
          result!(token, ~s'*[_type == "product" && $s in seriesIds]._id', %{"s" => "series-3"})
        end)

      assert length(plans) == 2
      assert Enum.all?(plans, &(&1 =~ "documents_content_path_idx")), Enum.join(plans, "\n---\n")
    end

    test "a closed subquery runs once and its list narrows the outer read", %{token: token} do
      q = ~s'*[_type == "product" && isbn in *[_type == "product" && references($c)].isbn]._id'

      sql = sql_reads(fn -> assert length(result!(token, q, %{"c" => "c-8"})) == 15 end)

      assert Enum.count(sql, &(&1 =~ "jsonb_path_query_array")) == 1
      assert Enum.any?(sql, &(&1 =~ "@?"))
    end
  end

  describe "a slice of *[...] over more documents than one read may load" do
    # Every shape is refused when it loads all 10,500 products. `rank` is
    # missing on the products; the x documents below hold one of each kind of
    # value GROQ's order() ranks.
    @slice_shapes [
      ~s'*[_type == "product"][0]',
      ~s'*[_type == "product"][0]._id',
      ~s'*[_type == "product"][3...15]._id',
      ~s'*[_type == "product"][10490..10520]._id',
      ~s'*[_type == "product" && isMainProduct == true][7]._id',
      ~s'*[_type == "product" && $s in seriesIds][2...4]._id',
      ~s'*[_type == "product"] | order(isbn desc)[0...12]._id',
      ~s'*[_type == "product"] | order(rank asc)[0...20]{_id, rank}',
      ~s'*[_type == "product"] | order(rank desc)[0...20]{_id, rank}',
      ~s'*[_type == "product"] | order(rank desc, isbn asc)[0...20]._id',
      ~s'*[_type == "product"] | order(_updatedAt desc)[0...5]._id',
      ~s'*[_type == "product"] | order(_createdAt asc, _id desc)[0..2]._id',
      ~s'*[_type == "product"] | order(_id desc)[0...3]._id',
      ~s'*[_type == "product" && isbn > "0"][0...12]._id',
      ~s'*[_type == "product" && isbn > "0"][9000...9010]._id',
      ~s'*[_type == "product" && isbn > "0"] | order(isbn desc)[0...12]._id',
      ~s'*[_type == "product"] | order(lower(isbn) desc)[1]._id',
      ~s'*[_type == "product" && count(slugHistory[match == "url"]) > 0] | order(rank desc)[0...10]{_id, rank}',
      ~s'{"first": *[_type == "product"][0]._id, "n": count(*[_type == "product"][0...5])}'
    ]

    setup %{scope: scope} do
      # Numbers, strings, booleans, null, an array and an object, a character
      # above U+FFFF and one in U+E000..U+FFFF, which UTF-16 orders the other
      # way round from code points.
      ranks = [
        3,
        2.5,
        -1,
        "b",
        "a",
        "Z",
        true,
        false,
        nil,
        [1],
        %{"a" => 1},
        "\u{1F600}",
        "\u{E000}"
      ]

      for {rank, i} <- Enum.with_index(ranks) do
        id = "x#{i}"
        doc = %{"_id" => id, "rank" => rank, "isbn" => "x#{i}", "seriesIds" => ["series-3"]}
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
        {:ok, _} = Content.publish_document(id, "product", @dataset, scope)
      end

      # Drafts: p5 gains a rank and an isbn that sorts first, x3 a new rank,
      # and y1 exists only as a draft.
      %{rows: [[content]]} =
        Repo.query!("SELECT content FROM documents WHERE doc_id = 'p5' AND dataset = $1", [
          @dataset
        ])

      for doc <- [
            Map.merge(content, %{"_id" => "p5", "rank" => 2, "isbn" => "999"}),
            %{"_id" => "x3", "rank" => "c", "isbn" => "x3", "seriesIds" => ["series-3"]},
            %{"_id" => "y1", "rank" => 10, "isbn" => "y1", "seriesIds" => ["series-3"]}
          ] do
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
      end

      :ok
    end

    test "each shape answers within the limits and equals in-memory evaluation in every perspective",
         %{token: token} do
      for perspective <- ["published", "drafts", "raw"] do
        expected =
          Map.new(@slice_shapes, &{&1, in_memory(token, perspective, &1, %{"s" => "series-3"})})

        for q <- @slice_shapes do
          got = result!(token, q, %{"s" => "series-3"}, %{"perspective" => perspective})
          assert got == expected[q], "#{perspective} #{q}"
        end
      end

      assert result!(token, ~s'*[_type == "product"] | order(rank asc)[0...13].rank', %{}) ==
               [-1, 2.5, 3, "Z", "a", "b", "\u{1F600}", "\u{E000}", false, true, nil, nil, nil]
    end

    test "an exact filter reads only the rows the slice needs", %{token: token} do
      sql =
        sql_reads(fn ->
          assert result!(token, ~s'*[_type == "product"][0]._id', %{}) == "p1"

          # `desc` puts the template, which has no isbn, first.
          assert result!(token, ~s'*[_type == "product"] | order(isbn desc)[0...2]._id', %{}) ==
                   ["template", "x9"]
        end)

      sized = Enum.filter(sql, &(&1 =~ "pg_column_size"))
      assert length(sized) == 2
      assert Enum.all?(sized, &(&1 =~ ~r/LIMIT \$\d+ OFFSET \$\d+/)), Enum.join(sized, "\n")
      refute Enum.any?(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/))
    end

    test "an unordered slice over any other filter stops at the chunk that fills it",
         %{token: token} do
      sql =
        sql_reads(fn ->
          assert result!(token, ~s'*[_type == "product" && isbn > "0"][0...3]._id', %{}) ==
                   ["p1", "p10", "p100"]
        end)

      assert Enum.count(sql, &(&1 =~ ~r/COLLATE "C"/)) == 1
    end

    test "a slice wider than the per-fetch limit is still refused", %{token: token} do
      for q <- [
            ~s'*[_type == "product"][0...10501]',
            ~s'*[_type == "product" && isbn > "0"][0...10001]'
          ] do
        body = token |> query(q, %{}) |> json_response(422)
        assert body["error"]["type"] == "queryLimitError", q
      end
    end

    test "the query timeout still applies", %{token: token} do
      with_groq_config(timeout_ms: 50)

      body =
        token
        |> query(~s'*[_type == "product" && isbn > "0"] | order(lower(isbn) desc)[0]', %{})
        |> json_response(422)

      assert body["error"]["description"] =~ "ran longer than 50 ms"
    end
  end

  # The SQL of every query the function sends.
  defp sql_reads(fun) do
    ref = make_ref()
    parent = self()
    handler = "groq-sql-#{inspect(ref)}"

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

    ref |> collect([]) |> Enum.map(&elem(&1, 0))
  end

  # EXPLAIN for every documents read the function sends whose SQL holds
  # `marker`, with the parameters it ran with.
  defp explain_reads(marker, fun) do
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
        sql =~ marker
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
