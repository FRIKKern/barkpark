defmodule BarkparkWeb.GroqBenchTest do
  @moduledoc """
  Server time of the GROQ page-query shapes over 20,000 synthetic products
  (`Barkpark.Test.GroqSyntheticProducts`), with the `_ref` index and then with
  it dropped inside the test transaction, plus the index's size. Prints a table; asserts only
  that every shape answers. Excluded by default. Run:

      mix test --include groq_bench test/barkpark_web/controllers/groq_bench_test.exs
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Test.GroqSyntheticProducts

  @moduletag :groq_bench
  @moduletag timeout: 600_000

  @dataset "groq_bench"
  @products 20_000
  @runs 9

  # 31 isbns spread over the products, as a page's list of ids.
  @isbns for(g <- 1..31, do: "978" <> String.pad_leading(Integer.to_string(g * 613), 7, "0"))

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
    {"9 count(*[...]) scanned in chunks, isbn > \"0\"",
     ~s'count(*[_type == "product" && isbn > "0"])', %{}},
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
     ~s'*[_type == "product" && isbn > "0"][0...12]._id', %{}},
    {"20 inexact filter | order(isbn desc)[0...12], scanned in full",
     ~s'*[_type == "product" && isbn > "0"] | order(isbn desc)[0...12]._id', %{}},
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
     }}
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

    assert Enum.all?(indexed, fn {_, status, _} -> status == 200 end)
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
