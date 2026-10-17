defmodule BarkparkWeb.GroqBenchTest do
  @moduledoc """
  Server time of the GROQ page-query shapes over 20,000 synthetic products
  (`Barkpark.Test.GroqSyntheticProducts`), with the `_ref` index and then with
  it dropped inside the test transaction, plus the index's size. Prints a table; asserts only
  that every shape answers. Excluded by default. Run:

      mix test --include groq_bench test/barkpark_web/controllers/groq_bench_test.exs
  """
  use BarkparkWeb.ConnCase, async: false
  import Barkpark.RateLimiterSandbox
  setup :reset_rate_limiter!

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Test.GroqSyntheticProducts

  @moduletag :groq_bench
  # 39 shapes, 10 runs each, twice, and several shapes take seconds on main.
  @moduletag timeout: 1_800_000
  @moduletag ownership_timeout: 1_800_000

  @dataset "groq_bench"
  @products 20_000
  @runs 9

  # 31 isbns spread over the products, as a page's list of ids.
  @isbns for(g <- 1..31, do: "978" <> String.pad_leading(Integer.to_string(g * 613), 7, "0"))

  # The visibility filters a Sanity-style product query sends.
  @visible ~s'_type == "product" && hidden != true && isMainProduct != false && defined(description) && description != ""'

  # A category hub's automatic row: 20 rule groups of thema codes, sized as
  # the gyldendal.no twin's sakprosa hub, 372 codes in all. A group of one
  # code is `$c in themaCodes`, as the twin writes it.
  @hub_sizes [3, 22, 27, 15, 27, 30, 3, 1, 48, 4, 3, 32, 25, 1, 15, 6, 48, 30, 18, 14]
  @hub_codes @hub_sizes
             |> Enum.scan({0, 0}, fn n, {_from, to} -> {to, to + n} end)
             |> Enum.map(fn {from, to} -> Enum.map(from..(to - 1)//1, &"T#{&1}") end)
  @hub_params @hub_codes
              |> Enum.with_index()
              |> Map.new(fn
                {[code], i} -> {"g#{i}", code}
                {codes, i} -> {"g#{i}", codes}
              end)
              |> Map.put("ex", ["series-7", "series-9"])
  @hub_groups @hub_codes
              |> Enum.with_index()
              |> Enum.map_join(" || ", fn
                {[_code], i} -> "$g#{i} in themaCodes"
                {_codes, i} -> "count(themaCodes[@ in $g#{i}]) > 0"
              end)

  # A category listing's filter, as the gyldendal.no twin sends it: the
  # visibility checks, two display rules, the department fence (an
  # equality), an `||` of rule groups (one code, 94 codes, 39 codes, 28
  # codes, the /skjonnlitteratur sizes) and the sold-out rule.
  @category ~s'#{@visible} && (onix.publicationStatus.value in $statuses || !defined(onix.publicationStatus.value)) && (onix.availability.value in $codes || !defined(onix.availability.value)) && department._ref == $dept && ($c0 in themaCodes || count(themaCodes[@ in $c1]) > 0 || count(themaCodes[@ in $c2]) > 0 || count(themaCodes[@ in $c3]) > 0) && (access.buyStatus != "sold_out" || isMainProduct == true)'
  @category_params %{
    "statuses" => ["04", "02", "08", "10"],
    "codes" => [
      "21",
      "20",
      "22",
      "23",
      "30",
      "31",
      "33",
      "40",
      "43",
      "44",
      "45",
      "47",
      "99",
      "10"
    ],
    "dept" => "dept-big",
    "c0" => "U3",
    "c1" => Enum.map(0..93, &"T#{&1 * 7}"),
    "c2" => Enum.map(0..38, &"T#{&1 * 11 + 1}"),
    "c3" => Enum.map(0..27, &"T#{&1 * 13 + 2}")
  }
  @listing "{_id, isbn, title, description, themaCodes, seriesIds, onix, access, publishedAt}"

  @shapes [
    {"1 sibling editions, references(^._id) in ||",
     """
     *[_type == "product" && isbn == $isbn][0]{_id, "siblings": *[
       _type == "product" && _id != ^._id && (defined(isbn) || defined(onix.isbn)) && (
         (references(^._id) && (mainProduct._ref == ^._id || ^._id in bokbasen.languageFormatVariants[]._ref)) ||
         _id == ^.mainProduct._ref ||
         (defined(^.mainProduct._ref) && references(^.mainProduct._ref) && (
           mainProduct._ref == ^.mainProduct._ref || ^.mainProduct._ref in bokbasen.languageFormatVariants[]._ref)) ||
         _id in ^.bokbasen.languageFormatVariants[]._ref ||
         (defined(^.onix.publicationId) && defined(onix.publicationId) &&
          onix.publicationId == ^.onix.publicationId && lower(title) == lower(^.title))
       )] | order(_id asc)._id}
     """, %{"isbn" => "9780000005"}},
    {"2 series page, references($seriesId)",
     """
     *[_type == "product" && !(_id in path("drafts.**")) && defined(isbn) &&
       isMainProduct == true && references($seriesId)]{_id, isbn}
     """, %{"seriesId" => "series-3"}},
    {"3 author books, references($contributorId)",
     """
     *[_type == "product" && references($contributorId) &&
       count(onix.contributors[contributor._ref == $contributorId && role._ref in ["A01", "B01"]]) > 0].isbn
     """, %{"contributorId" => "c-8"}},
    {"4 redirect, $path in slugHistory[].value",
     """
     *[($paths[0] in slugHistory[].value || $paths[1] in slugHistory[].value) &&
       count((slugHistory)[match == "url" && lower(value) in $paths]) > 0 &&
       (isHidden != true || _type == "article")] | order(_updatedAt desc)[0]{_id}
     """, %{"paths" => ["/bok/p12345", "/bok/P12345"]}},
    {"5 count(*[_type == \"product\"])", ~s'count(*[_type == "product"])', %{}},
    {"6 count per department via ^",
     ~s'*[_type == "department"]{_id, "n": count(*[_type == "product" && department._ref == ^._id])}',
     %{}},
    {"7 count(*[... && count(onix.contributors) > 0])",
     ~s'count(*[_type == "product" && count(onix.contributors) > 0])', %{}},
    {"8 count(*[... && defined(bokbasen.languageFormatVariants[0])])",
     ~s'count(*[_type == "product" && defined(bokbasen.languageFormatVariants[0])])', %{}},
    {"9 count(*[...]) scanned in chunks, lower(isbn) > \"0\"",
     ~s'count(*[_type == "product" && lower(isbn) > "0"])', %{}},
    {"10 isbn in $isbns, 31 values", ~s'*[_type == "product" && isbn in $isbns]._id',
     %{"isbns" => @isbns}},
    {"11 isbn in $isbns && isMainProduct == true",
     ~s'*[_type == "product" && isbn in $isbns && isMainProduct == true]._id',
     %{"isbns" => @isbns}},
    {"12 isbn in *[... && references($c)].isbn",
     ~s'*[_type == "product" && isbn in *[_type == "product" && references($c)].isbn]._id',
     %{"c" => "c-8"}},
    {"13 $s in seriesIds", ~s'*[_type == "product" && $s in seriesIds]._id',
     %{"s" => "series-3"}},
    {"14 *[_type == \"product\"][0]", ~s'*[_type == "product"][0]._id', %{}},
    {"15 *[...][0...12]", ~s'*[_type == "product"][0...12]._id', %{}},
    {"16 *[...][19990...20000]", ~s'*[_type == "product"][19990...20000]._id', %{}},
    {"17 | order(isbn desc)[0...12]", ~s'*[_type == "product"] | order(isbn desc)[0...12]._id',
     %{}},
    {"18 | order(_updatedAt desc)[0...12]",
     ~s'*[_type == "product"] | order(_updatedAt desc)[0...12]._id', %{}},
    {"19 inexact filter [0...12], scanned until full",
     ~s'*[_type == "product" && lower(isbn) > "0"][0...12]._id', %{}},
    {"20 inexact filter | order(isbn desc)[0...12], scanned in full",
     ~s'*[_type == "product" && lower(isbn) > "0"] | order(isbn desc)[0...12]._id', %{}},
    {"21 more by this author, count(onix.contributors[...]) > 0",
     """
     *[_type == "product" && !(_id in path("drafts.**")) && isHidden != true &&
       isMainProduct == true && defined(title) && defined(onix.isbn) &&
       count(onix.contributors[role._ref == "A01" && contributor._ref in $authorIds]) > 0 &&
       !(onix.isbn in $excludeIsbns) && !(title in $excludeTitles) &&
       onix.publicationStatus.value in $validPublishingStatuses &&
       onix.availability.value in $validAvailabilityCodes && access.buyStatus != "sold_out"
     ] | order(onix.publishingDate desc, onix.isbn asc) [0...$limit] {_id, title, "isbn": onix.isbn}
     """,
     %{
       "authorIds" => ["c-8"],
       "excludeIsbns" => ["9780000708"],
       "excludeTitles" => [],
       "validPublishingStatuses" => ["04"],
       "validAvailabilityCodes" => ["21"],
       "limit" => 10
     }},
    {"22 rail, $a in seriesIds && filters | order()[0...5]",
     """
     *[_type == "product" && $a in seriesIds && isMainProduct == true &&
       access.buyStatus != "sold_out"] | order(onix.publishingDate desc)[0...5]{_id}
     """, %{"a" => "series-3"}},
    {"23 rail, ($a in seriesIds || $b in seriesIds) && filters | order()[0...5]",
     """
     *[_type == "product" && ($a in seriesIds || $b in seriesIds) && isMainProduct == true &&
       access.buyStatus != "sold_out"] | order(onix.publishingDate desc)[0...5]{_id}
     """, %{"a" => "series-3", "b" => "series-7"}},
    {"24 count(*[... && ($a in seriesIds || $b in seriesIds)])",
     ~s'count(*[_type == "product" && ($a in seriesIds || $b in seriesIds)])',
     %{"a" => "series-3", "b" => "series-7"}},
    {"25 | order(publishedAt desc)[0...5], no filter",
     ~s'*[_type == "product"] | order(publishedAt desc)[0...5]._id', %{}},
    {"26 hidden != true | order(publishedAt desc)[0...5]",
     ~s'*[_type == "product" && hidden != true] | order(publishedAt desc)[0...5]._id', %{}},
    {"27 four != filters | order(publishedAt desc)[0...30]",
     ~s'*[#{@visible} && onix.publicationStatus.value != "02"] | order(publishedAt desc)[0...30]._id',
     %{}},
    {"28 count(*[... && hidden != true])", ~s'count(*[_type == "product" && hidden != true])',
     %{}},
    {"29 publishedAt > $t | order(publishedAt desc)[0...5]",
     ~s'*[_type == "product" && publishedAt > $t] | order(publishedAt desc)[0...5]._id',
     %{"t" => 1_600_000_000_000}},
    {"30 count(*[... && publishedAt > $t])", ~s'count(*[_type == "product" && publishedAt > $t])',
     %{"t" => 1_600_000_000_000}},
    {"31 count(*[... && $t < publishedAt && publishedAt <= $u])",
     ~s'count(*[_type == "product" && $t < publishedAt && publishedAt <= $u])',
     %{"t" => 1_600_000_000_000, "u" => 1_700_000_000_000}},
    {"32 count(*[... && onix.publishingDate >= $d])",
     ~s'count(*[_type == "product" && onix.publishingDate >= $d])', %{"d" => "2020-01-01"}},
    {"33 count(themaCodes[@ in $codes]) > 0, 10 codes, | order()[0...30]",
     ~s'*[_type == "product" && count(themaCodes[@ in $codes]) > 0] | order(publishedAt desc)[0...30]._id',
     %{"codes" => Enum.map(0..9, &"T#{&1}")}},
    {"34 count(themaCodes[@ in $codes]) > 0, 372 codes, | order()[0...30]",
     ~s'*[_type == "product" && count(themaCodes[@ in $codes]) > 0] | order(publishedAt desc)[0...30]._id',
     %{"codes" => Enum.map(0..371, &"T#{&1}")}},
    {"35 hub row, 20 groups, 372 codes, != filters and an exclude",
     ~s'*[#{@visible} && (#{@hub_groups}) && (!defined(seriesIds) || !(count(seriesIds[@ in $ex]) > 0)) && onix.publicationStatus.value != "02"] | order(publishedAt desc)[0...30]._id',
     @hub_params},
    {"36 category listing filter, count()", ~s'count(*[#{@category}])', @category_params},
    {"37 category listing filter, ._id", ~s'*[#{@category}]._id', @category_params},
    {"38 category listing filter | order() {listing keys}",
     ~s'*[#{@category}] | order(publishedAt desc, isbn asc) #{@listing}', @category_params},
    {"39 category listing filter {listing keys}", ~s'*[#{@category}] #{@listing}',
     @category_params}
  ]

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-bench", name: "GROQ bench"})
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

    for id <- ["dept-big", "dept-small"] do
      {:ok, _} = Content.create_document("department", %{"_id" => id}, @dataset, scope)
      {:ok, _} = Content.publish_document(id, "department", @dataset, scope)
    end

    GroqSyntheticProducts.seed!(@dataset, @products)

    token = "groq-bench-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "groq bench", @dataset, ["read"], ws.id)
    {:ok, token: token}
  end

  test "page-query shapes over 20,000 products", %{token: token} do
    indexed = Enum.map(@shapes, &measure(token, &1))

    sizes = index_sizes()
    Repo.query!("DROP INDEX documents_content_refs_idx")
    unindexed = Enum.map(@shapes, &measure(token, &1))

    IO.puts("\nGROQ over #{@products} products, median of #{@runs} runs (server ms)")
    IO.puts(sizes)
    IO.puts("| shape | status | with the _ref index | without it |")
    IO.puts("|---|---|---|---|")

    for {{name, status, ms}, {_, _, ms_off}} <- Enum.zip(indexed, unindexed) do
      IO.puts("| #{name} | #{status} | #{ms} | #{ms_off} |")
    end

    assert Enum.all?(indexed ++ unindexed, fn {_, status, _} -> status == 200 end)
  end

  # The documents table (heap, TOAST and every index) and the _ref index, as
  # this test transaction sees them.
  defp index_sizes do
    %{rows: [[table, heap, refs, entries, bytes]]} =
      Repo.query!("""
      SELECT pg_total_relation_size('documents'), pg_relation_size('documents'),
             pg_relation_size('documents_content_refs_idx'),
             sum(jsonb_array_length(a)), sum(octet_length(a::text))
      FROM (SELECT jsonb_path_query_array(content, 'strict $.** ? (exists(@._ref))._ref') AS a
            FROM documents) s
      """)

    # The migration's estimate, over the whole table instead of a sample.
    estimate = bytes + 64 * entries

    "documents: #{div(table, 1024)} KiB in all, #{div(heap, 1024)} KiB heap; " <>
      "documents_content_refs_idx: #{div(refs, 1024)} KiB for #{entries} _ref values " <>
      "(#{Float.round(refs / max(entries, 1), 1)} bytes each); the migration's formula " <>
      "estimates #{div(estimate, 1024)} KiB"
  end

  defp measure(token, {name, query, params}) do
    # Ten runs of every shape, twice, pass the read rate limit when the shapes
    # are fast, and a 429 carries no `ms`. Each shape starts with full buckets.
    reset!()

    timings =
      for _ <- 0..@runs do
        conn =
          scoped_conn()
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "application/json")
          |> post(
            "/w/groq-bench/p/site/v2025-02-19/data/query/#{@dataset}",
            Jason.encode!(%{"query" => query, "params" => params})
          )

        {conn.status, Jason.decode!(conn.resp_body)["ms"]}
      end

    # The first run warms caches and is dropped.
    [_ | timed] = timings
    {status, _} = List.last(timed)
    ms = timed |> Enum.map(fn {_, ms} -> ms || 0 end) |> Enum.sort() |> Enum.at(div(@runs, 2))
    {name, status, ms}
  end
end
