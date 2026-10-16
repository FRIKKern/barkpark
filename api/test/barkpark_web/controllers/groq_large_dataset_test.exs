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
      assert result!(token, ~s'count(*[_type == "product" && lower(isbn) > "0"])', %{}) ==
               @products
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
          # Even products have role A01. SQL cannot test lower().
          assert result!(
                   token,
                   ~s'count(*[_type == "product" && count(onix.contributors[lower(role._ref) == "a01"]) > 0])',
                   %{}
                 ) == div(@products, 2)
        end)

      assert Enum.count(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/)) == div(@products + 1, 500) + 1

      # A chunk does not count toward the documents a query loads.
      assert result!(
               token,
               ~s'{"n": count(*[_type == "product" && lower(isbn) > "0"]), "p": *[_id == "p5"][0]._id}',
               %{}
             ) == %{"n" => @products, "p" => "p5"}
    end

    test "inside a projection, per parent, with ^ and a -> in the filter", %{token: token} do
      q = """
      *[_type == "department"] | order(_id asc){
        _id,
        "n": count(*[_type == "product" && department->_id == ^._id && lower(isbn) > "0"])
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

        counted =
          result!(token, ~s'count(*[_type == "product" && lower(isbn) > "0"])', %{}, extra)

        with_groq_config(max_documents_per_fetch: 20_000, max_documents_loaded: 40_000)

        loaded =
          result!(
            token,
            ~s'count(*[_type == "product" && lower(isbn) > "0"][0...100000])',
            %{},
            extra
          )

        with_groq_config([])

        assert counted == loaded, "#{perspective}: #{counted} != #{loaded}"
      end
    end

    test "the query timeout still applies", %{token: token} do
      with_groq_config(timeout_ms: 50)

      body =
        token
        |> query(~s'count(*[_type == "product" && lower(isbn) > "0"])', %{})
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

    # The query evaluated in memory over `docs`, which `products/2` reads by
    # type alone, once per perspective.
    defp in_memory(docs, query, params) do
      {:ok, tree} = Parser.parse(query, params)
      {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new(docs))
      value
    end

    defp products(token, perspective) do
      with_groq_config(max_documents_per_fetch: 20_000, max_documents_loaded: 40_000)
      docs = result!(token, ~s'*[_type == "product"]', %{}, %{"perspective" => perspective})
      with_groq_config([])
      docs
    end

    test "each shape equals in-memory evaluation in every perspective", %{token: token} do
      for perspective <- ["published", "drafts", "raw"] do
        docs = products(token, perspective)
        expected = Map.new(@in_shapes, fn {q, params} -> {q, in_memory(docs, q, params)} end)

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
      ~s'*[_type == "product" && lower(isbn) > "0"][0...12]._id',
      ~s'*[_type == "product" && lower(isbn) > "0"][9000...9010]._id',
      ~s'*[_type == "product" && lower(isbn) > "0"] | order(isbn desc)[0...12]._id',
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
        docs = products(token, perspective)

        expected =
          Map.new(@slice_shapes, &{&1, in_memory(docs, &1, %{"s" => "series-3"})})

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
          assert result!(token, ~s'*[_type == "product" && lower(isbn) > "0"][0...3]._id', %{}) ==
                   ["p1", "p10", "p100"]
        end)

      assert Enum.count(sql, &(&1 =~ ~r/COLLATE "C"/)) == 1
    end

    test "a slice wider than the per-fetch limit is still refused", %{token: token} do
      for q <- [
            ~s'*[_type == "product"][0...10501]',
            ~s'*[_type == "product" && lower(isbn) > "0"][0...10001]'
          ] do
        body = token |> query(q, %{}) |> json_response(422)
        assert body["error"]["type"] == "queryLimitError", q
      end
    end

    test "the query timeout still applies", %{token: token} do
      with_groq_config(timeout_ms: 50)

      body =
        token
        |> query(~s'*[_type == "product" && lower(isbn) > "0"] | order(lower(isbn) desc)[0]', %{})
        |> json_response(422)

      assert body["error"]["description"] =~ "ran longer than 50 ms"
    end
  end

  describe "a match inside an array filter" do
    # The twin's "more by this author" query on a product page, over the
    # fields the synthetic products hold.
    @author_query """
    *[_type == "product" && !(_id in path("drafts.**")) && isHidden != true &&
      isMainProduct == true && defined(title) && defined(onix.isbn) &&
      count(onix.contributors[role._ref == "A01" && contributor._ref in $authorIds]) > 0 &&
      !(onix.isbn in $excludeIsbns) && !(title in $excludeTitles) &&
      onix.publicationStatus.value in $validPublishingStatuses &&
      onix.availability.value in $validAvailabilityCodes && access.buyStatus != "sold_out"
    ] | order(onix.publishingDate desc, onix.isbn asc) [0...$limit] {_id, "isbn": onix.isbn}
    """

    @author_params %{
      "authorIds" => ["c-8"],
      "excludeIsbns" => ["9780000708"],
      "excludeTitles" => ["Product 1408"],
      "validPublishingStatuses" => ["04"],
      "validAvailabilityCodes" => ["21"],
      "limit" => 10
    }

    @pair ~s'[role._ref == "A01" && contributor._ref in $authorIds]'

    # c-8 sits on 15 products, all of them even and so A01. The y documents
    # below test the edges SQL could get wrong.
    @array_shapes [
      {@author_query, @author_params},
      {~s'*[_type == "product" && count(onix.contributors#{@pair}) > 0]._id', @author_params},
      {~s'*[_type == "product" && count(onix.contributors#{@pair}) >= 1]._id', @author_params},
      {~s'*[_type == "product" && 0 < length(onix.contributors#{@pair})]._id', @author_params},
      {~s'*[_type == "product" && defined(onix.contributors#{@pair}[0])]._id', @author_params},
      {~s'*[_type == "product" && count(onix.contributors[contributor._ref == $c && lower(role._ref) == "a01"]) > 0]._id',
       %{"c" => "c-8"}},
      {~s'*[_type == "product" && count(tags[@ == "x"]) > 0]._id', %{}},
      {~s'*[_type == "product" && count(items[n in [7, "y"]]) > 0]._id', %{}},
      {~s'*[_type == "product" && count(onix.contributors#{@pair}) > 0] | order(isbn desc)[0...4]._id',
       @author_params}
    ]

    setup %{scope: scope} do
      a01 = fn c -> %{"role" => %{"_ref" => "A01"}, "contributor" => %{"_ref" => c}} end

      # y1 holds the role and the author in two elements; y2 holds an object
      # where the array is; y3 an array where the role's _ref is; y4 a null
      # and a string before the matching element; y5 an array where the role
      # is. Only y4 matches. tags and items hold a string where the array
      # is, a nested array, and 7 written as a float.
      for {id, doc} <- [
            {"y1",
             %{
               "onix" => %{
                 "contributors" => [
                   %{"role" => %{"_ref" => "A01"}, "contributor" => %{"_ref" => "c-9"}},
                   %{"role" => %{"_ref" => "B06"}, "contributor" => %{"_ref" => "c-8"}}
                 ]
               },
               "tags" => "x"
             }},
            {"y2", %{"onix" => %{"contributors" => a01.("c-8")}, "tags" => [["x"]]}},
            {"y3",
             %{
               "onix" => %{
                 "contributors" => [
                   %{"role" => %{"_ref" => ["A01"]}, "contributor" => %{"_ref" => "c-8"}}
                 ]
               },
               "tags" => ["y", "x"],
               "items" => [%{"n" => 7.0}]
             }},
            {"y4",
             %{
               "onix" => %{"contributors" => [nil, "c-8", a01.("c-8")]},
               "items" => [%{"n" => "7"}, 7]
             }},
            {"y5",
             %{
               "onix" => %{
                 "contributors" => [
                   %{"role" => [%{"_ref" => "A01"}], "contributor" => %{"_ref" => "c-8"}}
                 ]
               },
               "items" => [%{"n" => [7]}]
             }}
          ] do
        {:ok, _} = Content.create_document("product", Map.put(doc, "_id", id), @dataset, scope)
        {:ok, _} = Content.publish_document(id, "product", @dataset, scope)
      end

      # Drafts: p708 loses the author, y1 gains it in one element, and y6
      # exists only as a draft that matches.
      %{rows: [[content]]} =
        Repo.query!("SELECT content FROM documents WHERE doc_id = 'p708' AND dataset = $1", [
          @dataset
        ])

      for doc <- [
            put_in(content, ["onix", "contributors"], [a01.("c-9")]) |> Map.put("_id", "p708"),
            %{"_id" => "y1", "onix" => %{"contributors" => [a01.("c-8")]}, "tags" => ["x"]},
            %{
              "_id" => "y6",
              "onix" => %{"contributors" => [a01.("c-8")]},
              "items" => [%{"n" => 7}]
            }
          ] do
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
      end

      :ok
    end

    test "each shape equals in-memory evaluation in every perspective", %{token: token} do
      for perspective <- ["published", "drafts", "raw"] do
        docs = products(token, perspective)
        expected = Map.new(@array_shapes, fn {q, params} -> {q, in_memory(docs, q, params)} end)

        for {q, params} <- @array_shapes do
          got = result!(token, q, params, %{"perspective" => perspective})
          assert got == expected[q], "#{perspective} #{q}"
        end
      end

      # Spot checks against the seed, published. Of c-8's 15 products the
      # excludes drop p708 and p1408, the publication status p9108 and the
      # buy status p2808; the limit keeps 10 of the other 11.
      ids = token |> result!(@author_query, @author_params) |> Enum.map(& &1["_id"])
      assert length(ids) == 10

      assert ids -- ~w(p8 p2108 p3508 p4208 p4908 p5608 p6308 p7008 p7708 p8408 p9808) == []

      assert result!(
               token,
               ~s'*[_type == "product" && count(onix.contributors#{@pair}) > 0]._id',
               @author_params
             )
             |> Enum.sort() ==
               Enum.sort(["y4" | for(g <- 1..@products, rem(g, 700) == 8, do: "p#{g}")])

      assert Enum.sort(
               result!(token, ~s'*[_type == "product" && count(tags[@ == "x"]) > 0]._id', %{})
             ) ==
               ["y3"]

      assert Enum.sort(
               result!(
                 token,
                 ~s'*[_type == "product" && count(items[n in [7, "y"]]) > 0]._id',
                 %{}
               )
             ) == ["y3"]
    end

    test "SQL reads only the documents whose array holds a match", %{token: token} do
      for perspective <- ["published", "drafts", "raw"], {q, params} <- @array_shapes do
        {_result, rows} =
          rows_read(fn -> result!(token, q, params, %{"perspective" => perspective}) end)

        # 15 products and y1 to y6, with their published twins in drafts.
        assert rows <= 60, "#{perspective} read #{rows} rows for #{q}"
      end
    end

    test "count() over the exact shapes is a SQL count", %{token: token} do
      shapes = Enum.slice(@array_shapes, 1..4)

      sql =
        sql_reads(fn ->
          for {q, params} <- shapes do
            assert result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), params) == 16
          end
        end)

      refute Enum.any?(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/))
      assert Enum.count(sql, &(&1 =~ "@?")) == 4
    end

    test "the element test is one jsonpath that documents_content_path_idx serves",
         %{token: token} do
      Repo.query!("SET LOCAL enable_seqscan = off")

      plans =
        explain_reads("@?", fn ->
          result!(
            token,
            ~s'*[_type == "product" && count(onix.contributors#{@pair}) > 0]._id',
            @author_params
          )
        end)

      assert [plan] = plans
      assert plan =~ "documents_content_path_idx", plan
    end
  end

  describe "an || whose every branch narrows in SQL" do
    # The twin's recommendation rail: books that share any of several codes.
    # `seriesIds` is `["series-<g mod 50>"]`, so each value holds 210 products.
    @rail_query """
    *[_type == "product" && ($a in seriesIds || $b in seriesIds) && isMainProduct == true &&
      access.buyStatus != "sold_out"] | order(onix.publishingDate desc)[0...5]{_id}
    """

    @or_params %{"a" => "series-3", "b" => "series-7", "isbns" => ["9780000101", "9780000202"]}

    @two ~s'($a in seriesIds || $b in seriesIds)'

    # `exact?` says whether SQL counts the shape.
    @or_shapes [
      {@rail_query, false},
      {~s'*[_type == "product" && #{@two}]._id', true},
      {~s'*[_type == "product" && #{@two}] | order(isbn desc)[0...12]._id', true},
      {~s'*[_type == "product" && #{@two}][3...8]._id', true},
      {~s'*[_type == "product" && #{@two} && lower(isbn) > "0"] | order(isbn desc)[0...12]._id',
       false},
      {~s'*[_type == "product" && (isbn in $isbns || _id == "p77" || count(onix.contributors[role._ref == "B06" && contributor._ref == "c-11"]) > 0 || defined(onix.contributors[3]))]._id',
       true},
      {~s'*[_type == "product" && (references("c-9") || $a in seriesIds)]._id', false},
      {~s'*[_type == "product" && ($a in seriesIds || title == "Book 3")]._id', false},
      {~s'*[_type == "product" && (($a in seriesIds && isMainProduct == false) || (onix.publicationStatus.value == "07" && $b in seriesIds) || (lower(isbn) == "x" && code == 7))]._id',
       false},
      {~s'*[_type == "product" && (code == 7 || "x" in tags)]._id', true},
      {~s'*[(_type == "product" && code == 7) || (_type == "product" && $b in seriesIds)]._id',
       true}
    ]

    setup %{scope: scope} do
      # z1 holds a string where the array is, z2 an array nested in the
      # array, z3 the value next to another and a float 7, z4 the string "7".
      for {id, doc} <- [
            {"z1", %{"seriesIds" => "series-3", "tags" => "x"}},
            {"z2", %{"seriesIds" => [["series-7"]], "tags" => [["x"]]}},
            {"z3", %{"seriesIds" => ["other", "series-7"], "code" => 7.0}},
            {"z4", %{"code" => "7", "tags" => ["y", "x"]}}
          ] do
        {:ok, _} = Content.create_document("product", Map.put(doc, "_id", id), @dataset, scope)
        {:ok, _} = Content.publish_document(id, "product", @dataset, scope)
      end

      # Drafts: p3 leaves series-3, p8 joins series-7, and z5 exists only as
      # a draft that matches.
      for {id, series} <- [{"p3", ["other"]}, {"p8", ["series-7"]}] do
        %{rows: [[content]]} =
          Repo.query!("SELECT content FROM documents WHERE doc_id = $1 AND dataset = $2", [
            id,
            @dataset
          ])

        doc = content |> Map.put("seriesIds", series) |> Map.put("_id", id)
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
      end

      {:ok, _} =
        Content.create_document(
          "product",
          %{"_id" => "z5", "seriesIds" => ["series-3"], "isMainProduct" => true},
          @dataset,
          scope
        )

      :ok
    end

    test "each shape and its count equal in-memory evaluation in every perspective",
         %{token: token} do
      for perspective <- ["published", "drafts", "raw"] do
        docs = products(token, perspective)
        extra = %{"perspective" => perspective}

        for {q, _exact?} <- @or_shapes do
          want = in_memory(docs, q, @or_params)
          assert result!(token, q, @or_params, extra) == want, "#{perspective} #{q}"

          if String.ends_with?(q, "]._id") do
            counted =
              result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), @or_params, extra)

            assert counted == length(want), "#{perspective} count #{q}"
          end
        end
      end

      # Spot checks against the seed, published.
      ids = result!(token, ~s'*[_type == "product" && #{@two}]._id', @or_params)
      assert length(ids) == 420 + 1
      assert "z3" in ids and "p3" in ids and "p7" in ids
      refute "z1" in ids or "z2" in ids

      assert Enum.sort(
               result!(token, ~s'*[_type == "product" && (code == 7 || "x" in tags)]._id', %{})
             ) == ["z3", "z4"]
    end

    test "SQL narrows each shape before the per-fetch limit", %{token: token} do
      with_groq_config(max_documents_per_fetch: 1_000)

      for {q, _exact?} <- @or_shapes do
        assert is_list(result!(token, q, @or_params)), q
      end
    end

    test "an exact or is a SQL count, not a chunked scan", %{token: token} do
      for {q, true} <- @or_shapes, String.ends_with?(q, "]._id") do
        sql =
          sql_reads(fn ->
            result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), @or_params)
          end)

        refute Enum.any?(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/)), q
        assert Enum.any?(sql, &(&1 =~ " OR ")), q
      end
    end

    test "an exact slice reads only the rows it returns", %{token: token} do
      {_result, rows} =
        rows_read(fn ->
          result!(
            token,
            ~s'*[_type == "product" && #{@two}] | order(isbn desc)[0...12]._id',
            @or_params
          )
        end)

      # The sized read returns 12 ids and the load 12 rows.
      assert rows <= 24
    end

    test "the or is a BitmapOr over documents_content_path_idx", %{token: token} do
      Repo.query!("SET LOCAL enable_seqscan = off")

      plans =
        explain_reads("@?", fn ->
          result!(token, ~s'*[_type == "product" && #{@two}]._id', @or_params)
        end)

      assert [plan] = plans
      assert plan =~ "BitmapOr", plan
      assert plan =~ "documents_content_path_idx", plan
    end
  end

  describe "!=, ranges, negations and long lists in SQL" do
    # Products hold `hidden` (true for g mod 17 == 0, false for 1, else
    # missing), `description` ("" for g mod 19 == 0), `publishedAt` in ms and
    # `themaCodes` (`T<g mod 2000>`, `T<7g mod 2000>`, `U<g mod 23>`).
    @codes40 Enum.map(0..39, &"T#{&1}")

    @ne_params %{
      "s" => "series-3",
      "t" => 1_600_000_000_000,
      "u" => 1_700_000_000_000,
      "astral" => "\u{1F600}",
      "codes5" => ["T1", "T2", "T3", "T4", "T5"],
      "codes40" => @codes40,
      "codes2" => Enum.map(40..99, &"T#{&1}"),
      "mixed" => [7 | Enum.map(1..8, &"T#{&1}")],
      "ex" => ["T5", "T6"],
      "isbns" => ["9780000003", "9780000053"]
    }

    @s ~s'_type == "product" && $s in seriesIds'

    # Each `._id` shape is also counted.
    @ne_shapes [
      ~s'*[#{@s} && hidden != true]._id',
      ~s'*[#{@s} && true != hidden && hidden != false]._id',
      ~s'*[#{@s} && hidden != null]._id',
      ~s'*[#{@s} && !(hidden == true)]._id',
      ~s'*[#{@s} && defined(description) && description != ""]._id',
      ~s'*[#{@s} && !defined(description)]._id',
      ~s'*[#{@s} && code != 7]._id',
      ~s'*[_type == "product" && hidden != true] | order(publishedAt desc)[0...20]._id',
      ~s'*[_type == "product" && hidden != true] | order(publishedAt desc)[500...520]._id',
      ~s'*[_type == "product" && publishedAt > $t]._id',
      ~s'*[_type == "product" && $t < publishedAt && publishedAt <= $u]._id',
      ~s'*[_type == "product" && publishedAt >= 1700000000000.0 && publishedAt < 1700100000000]._id',
      ~s'*[_type == "product" && publishedAt > $t] | order(publishedAt desc)[0...10]._id',
      ~s'*[_type == "product" && onix.publishingDate < "2000-02-01"]._id',
      ~s'*[_type == "product" && isbn >= $astral]._id',
      ~s'*[_type == "product" && isbn > "Y"]._id',
      ~s'*[_type == "product" && isbn < 13]._id',
      ~s'*[#{@s} && hidden > false]._id',
      ~s'*[_type == "product" && count(themaCodes[@ in $codes5]) > 0]._id',
      ~s'*[_type == "product" && count(themaCodes[@ in $codes40]) > 0]._id',
      ~s'*[_type == "product" && count(themaCodes[@ in $mixed]) > 0]._id',
      ~s'*[_type == "product" && (count(themaCodes[@ in $codes40]) > 0 || count(themaCodes[@ in $codes2]) > 0 || "U3" in themaCodes) && hidden != true] | order(publishedAt desc)[0...30]._id',
      ~s'*[#{@s} && !(count(themaCodes[@ in $codes40]) > 0)]._id',
      ~s'*[#{@s} && !("T5" in themaCodes)]._id',
      ~s'*[#{@s} && (!defined(themaCodes) || !(count(themaCodes[@ in $ex]) > 0))]._id',
      ~s'*[#{@s} && !(isbn in $isbns)]._id'
    ]

    setup %{scope: scope} do
      # Each field below holds a value of another type than the products', a
      # null, an array or an object, so SQL must answer as GROQ does for it.
      # n6 holds a float equal to a bound; n7 a character above U+FFFF and n8
      # one in U+E000..U+FFFF, which UTF-16 orders the other way round.
      edges = [
        {"n1",
         %{
           "hidden" => "true",
           "publishedAt" => "1650000000000",
           "themaCodes" => "T5",
           "description" => nil
         }},
        {"n2",
         %{"hidden" => [true], "publishedAt" => [1_650_000_000_000], "themaCodes" => [["T5"]]}},
        {"n3",
         %{"hidden" => nil, "publishedAt" => nil, "themaCodes" => %{"0" => "T5"}, "code" => "7"}},
        {"n4",
         %{
           "hidden" => 1,
           "publishedAt" => 1_650_000_000_000.5,
           "themaCodes" => ["T5", nil],
           "code" => 7.0
         }},
        {"n5", %{"hidden" => true, "publishedAt" => true, "themaCodes" => [], "isbn" => 12}},
        {"n6", %{"hidden" => false, "publishedAt" => 1_700_000_000_000.0, "themaCodes" => [7]}},
        {"n7", %{"isbn" => "\u{1F600}x", "description" => ""}},
        {"n8", %{"isbn" => "\u{E000}", "themaCodes" => ["U3"]}},
        {"n9", %{"isbn" => "Z", "description" => %{"x" => 1}}}
      ]

      for {id, doc} <- edges do
        doc = doc |> Map.put("_id", id) |> Map.put_new("seriesIds", ["series-3"])
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
        {:ok, _} = Content.publish_document(id, "product", @dataset, scope)
      end

      # Drafts: p153 (hidden) shows, p103 (shown) hides, p203 moves past $t
      # and gains T5, p253 leaves the 40 codes, and n10 exists only as a draft.
      for {id, change} <- [
            {"p153", %{"hidden" => false}},
            {"p103", %{"hidden" => true}},
            {"p203", %{"publishedAt" => 1_690_000_000_000, "themaCodes" => ["T5"]}},
            {"p253", %{"themaCodes" => ["U1"]}}
          ] do
        %{rows: [[content]]} =
          Repo.query!("SELECT content FROM documents WHERE doc_id = $1 AND dataset = $2", [
            id,
            @dataset
          ])

        doc = content |> Map.merge(change) |> Map.put("_id", id)
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
      end

      {:ok, _} =
        Content.create_document(
          "product",
          %{
            "_id" => "n10",
            "seriesIds" => ["series-3"],
            "publishedAt" => 1_650_000_000_000,
            "themaCodes" => ["T1"]
          },
          @dataset,
          scope
        )

      :ok
    end

    test "each shape and its count equal in-memory evaluation in every perspective",
         %{token: token} do
      for perspective <- ["published", "drafts", "raw"] do
        docs = products(token, perspective)
        extra = %{"perspective" => perspective}

        for q <- @ne_shapes do
          want = in_memory(docs, q, @ne_params)
          assert result!(token, q, @ne_params, extra) == want, "#{perspective} #{q}"

          if String.ends_with?(q, "]._id") do
            counted =
              result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), @ne_params, extra)

            assert counted == length(want), "#{perspective} count #{q}"
          end
        end
      end

      # Spot checks against the seed and the edge documents, published.
      ids = result!(token, ~s'*[#{@s} && hidden != true]._id', @ne_params)
      assert "n1" in ids and "n2" in ids and "n3" in ids and "n4" in ids and "n7" in ids
      refute "n5" in ids or "p153" in ids
      assert result!(token, ~s'*[_type == "product" && isbn < 13]._id', @ne_params) == ["n5"]

      assert result!(token, ~s'*[_type == "product" && isbn >= $astral]._id', @ne_params) ==
               ["n7", "n8"]

      refute "n4" in result!(token, ~s'*[#{@s} && code != 7]._id', @ne_params)

      assert "n6" in result!(
               token,
               ~s'*[_type == "product" && count(themaCodes[@ in $mixed]) > 0]._id',
               @ne_params
             )

      refute "n2" in result!(
               token,
               ~s'*[_type == "product" && count(themaCodes[@ in $codes40]) > 0]._id',
               @ne_params
             )
    end

    test "the shapes are exact: counts are SQL counts and slices one sized read",
         %{token: token} do
      for q <- @ne_shapes, String.ends_with?(q, "]._id") do
        sql =
          sql_reads(fn ->
            result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), @ne_params)
          end)

        refute Enum.any?(sql, &(&1 =~ ~r/ORDER BY d0."id" LIMIT/)), q
      end

      {_result, rows} =
        rows_read(fn ->
          result!(
            token,
            ~s'*[_type == "product" && hidden != true] | order(publishedAt desc)[0...20]._id',
            @ne_params
          )
        end)

      # The sized read returns 20 ids and the load 20 rows.
      assert rows <= 40
    end

    test "a long list is one index probe per value", %{token: token} do
      Repo.query!("SET LOCAL enable_seqscan = off")

      plans =
        explain_reads("unnest", fn ->
          result!(
            token,
            ~s'*[_type == "product" && count(themaCodes[@ in $codes40]) > 0]._id',
            @ne_params
          )
        end)

      assert [plan] = plans
      assert plan =~ "documents_content_path_idx", plan
      assert plan =~ "Nested Loop", plan
      assert plan =~ "Function Scan on unnest", plan
    end
  end

  describe "a filter with several content tests" do
    # A category listing's filter, as the gyldendal.no twin sends it: the
    # visibility checks, two display rules, the department fence, an `||` of
    # rule groups (one code, a long list and a short list) and the sold-out
    # rule.
    @long_group Enum.map(0..39, &"T#{&1 * 3}")
    @category_filter ~s'_type == "product" && hidden != true && isMainProduct != false && defined(description) && description != "" && (onix.publicationStatus.value in $statuses || !defined(onix.publicationStatus.value)) && department._ref == $dept && ($code in themaCodes || count(themaCodes[@ in $long]) > 0 || count(themaCodes[@ in $short]) > 0) && (access.buyStatus != "sold_out" || isMainProduct == true)'
    @category_params %{
      "statuses" => ["04"],
      "dept" => "dept-big",
      "code" => "U3",
      "long" => @long_group,
      "short" => ["T1", "T2", "T5"]
    }

    @content_shapes [
      {~s'*[#{@category_filter}]._id', @category_params},
      {~s'*[_type == "product" && code == 7]._id', %{}},
      {~s'*[_type == "product" && code == 7 && kind == "e"]._id', %{}},
      {~s'*[_type == "product" && kind == "e" && count(tags[@ in $long]) > 0]._id',
       %{"long" => ["a" | Enum.map(1..9, &"z#{&1}")]}},
      {~s'*[_type == "product" && kind == "e" && count(tags[@ in ["a", "b"]]) > 0]._id', %{}},
      {~s'*[_type == "product" && kind == "e" && count(tags[@ in [1, "a"]]) > 0]._id', %{}},
      {~s'*[_type == "product" && kind == "e" && !(count(tags[@ in $long]) > 0)]._id',
       %{"long" => ["a" | Enum.map(1..9, &"z#{&1}")]}},
      {~s'*[_type == "product" && kind == "e" && (code == 7 || "a" in tags)]._id', %{}}
    ]

    setup %{scope: scope} do
      # The values SQL could get wrong: a number written as an integer, as a
      # float, as a string and inside an array or an object, and `tags` as a
      # string, an object with the key, an array of objects, a nested array,
      # an array of numbers, an empty array and missing.
      for {id, doc} <- [
            {"e1", %{"code" => 7, "tags" => "a"}},
            {"e2", %{"code" => 7.0, "tags" => %{"a" => 1}}},
            {"e3", %{"code" => "7", "tags" => [%{"a" => 1}]}},
            {"e4", %{"code" => [7], "tags" => [["a"]]}},
            {"e5", %{"code" => %{"v" => 7}, "tags" => [1, 2]}},
            {"e6", %{"tags" => ["x", "a"]}},
            {"e7", %{"tags" => []}},
            {"e8", %{"code" => 8, "tags" => ["b"]}}
          ] do
        doc = doc |> Map.put("_id", id) |> Map.put("kind", "e")
        {:ok, _} = Content.create_document("product", doc, @dataset, scope)
        {:ok, _} = Content.publish_document(id, "product", @dataset, scope)
      end

      # e6's draft drops its tags, and e8's draft holds code 7.
      {:ok, _} =
        Content.create_document("product", %{"_id" => "e6", "kind" => "e"}, @dataset, scope)

      {:ok, _} =
        Content.create_document(
          "product",
          %{"_id" => "e8", "kind" => "e", "code" => 7, "tags" => ["b"]},
          @dataset,
          scope
        )

      :ok
    end

    test "each shape and its count equal in-memory evaluation in every perspective",
         %{token: token} do
      for perspective <- ["published", "drafts", "raw"] do
        docs = products(token, perspective)
        extra = %{"perspective" => perspective}

        for {q, params} <- @content_shapes do
          want = in_memory(docs, q, params)

          assert Enum.sort(result!(token, q, params, extra)) == Enum.sort(want),
                 "#{perspective} #{q}"

          counted =
            result!(token, "count(" <> String.replace_suffix(q, "._id", ")"), params, extra)

          assert counted == length(want), "#{perspective} count #{q}"
        end
      end

      # Spot checks against the seed and the documents above, published.
      assert Enum.sort(result!(token, ~s'*[_type == "product" && code == 7]._id', %{})) ==
               ["e1", "e2"]

      assert Enum.sort(
               result!(
                 token,
                 ~s'*[_type == "product" && kind == "e" && count(tags[@ in ["a", "b"]]) > 0]._id',
                 %{}
               )
             ) == ["e6", "e8"]

      assert result!(token, ~s'count(*[#{@category_filter}])', @category_params) == 672
    end

    test "the rows are read once: one copy of content, and one narrowing on the stored value",
         %{token: token} do
      [sql] =
        token
        |> count_sql(~s'count(*[#{@category_filter}])', @category_params)
        |> Enum.filter(&(&1 =~ "count("))

      assert sql =~ ~s|(d0."content" #> '{}') AS content OFFSET 0|
      # The copy, and the one jsonpath predicate the index serves.
      assert length(String.split(sql, ~s|d0."content"|)) - 1 == 2, sql
      refute sql =~ "unnest", sql
    end

    test "an equality alone is one jsonpath predicate on the stored content", %{token: token} do
      [sql] =
        token
        |> count_sql(~s'count(*[_type == "product" && department._ref == $d])', %{
          "d" => "dept-big"
        })
        |> Enum.filter(&(&1 =~ "count("))

      assert sql =~ "@@", sql
      refute sql =~ "#>", sql
    end

    test "the index finds the candidate rows of both", %{token: token} do
      Repo.query!("SET LOCAL enable_seqscan = off")

      plans =
        explain_reads("count(", fn ->
          result!(token, ~s'count(*[#{@category_filter}])', @category_params)

          result!(token, ~s'count(*[_type == "product" && department._ref == $d])', %{
            "d" => "dept-big"
          })
        end)

      assert length(plans) == 2
      assert Enum.all?(plans, &(&1 =~ "documents_content_path_idx")), Enum.join(plans, "\n---\n")
    end
  end

  defp count_sql(token, q, params) do
    sql_reads(fn -> result!(token, q, params) end)
    |> Enum.filter(&(&1 =~ ~s|FROM "documents"|))
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

  # The function's result and the number of rows its documents reads return.
  defp rows_read(fun) do
    ref = make_ref()
    parent = self()
    handler = "groq-rows-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ ->
        with true <- meta.query =~ "FROM \"documents\"",
             {:ok, %{num_rows: n}} <- meta.result do
          send(parent, {ref, n, nil})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, ref |> collect([]) |> Enum.map(&elem(&1, 0)) |> Enum.sum()}
  end

  defp collect(ref, acc) do
    receive do
      {^ref, sql, params} -> collect(ref, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
