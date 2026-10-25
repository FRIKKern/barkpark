defmodule Barkpark.Search.SearchFiltersTest do
  @moduledoc """
  Field filters and named facets inside the search.

  task-1c1558e9c5d9eda3: `[in]` matches a scalar field whose value is one of
  the values, and an array field that holds one of them.

  task-6496d34cb0a43ca7: a filter that leaves the exact matches in place does
  not start typo recovery. The hits are the unfiltered hits minus the ones
  the filter drops.

  task-b2a224d49a3f27eb: the SQL shape that keeps filters and facets cheap.
  The filters run as a subplan on the matched rows only, a named facet rides
  in the count's scan, and a field is read once per document.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "search-filters-test"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "displayName", "type" => "string"},
            %{"name" => "Format", "type" => "string"},
            %{"name" => "BookGroupCodes", "type" => "arrayOf", "of" => %{"type" => "string"}},
            %{"name" => "BaseVisible", "type" => "boolean"}
          ]
        },
        @ds,
        scope
      )

    book = fn id, content ->
      {:ok, _} =
        Content.create_document("book", %{"doc_id" => id, "content" => content}, @ds, scope)

      {:ok, _} = Content.publish_document(id, "book", @ds, scope)
      id
    end

    book.("exact-1", %{
      "displayName" => "Legemiddelhåndtering for sykepleiere",
      "Format" => "Heftet",
      "BookGroupCodes" => ["801", "327"],
      "BaseVisible" => true
    })

    book.("exact-2", %{
      "displayName" => "Legemiddelhåndtering i praksis",
      "Format" => "Lydbok",
      "BookGroupCodes" => ["802"],
      "BaseVisible" => false
    })

    book.("exact-3", %{
      "displayName" => "Legemiddelhåndtering",
      "Format" => "Ebok",
      "BookGroupCodes" => ["342"],
      "BaseVisible" => false
    })

    # A near miss: the widened typo pass finds it, the words do not.
    book.("near-miss", %{
      "displayName" => "Legemiddelhåndtring",
      "Format" => "Pocket",
      "BookGroupCodes" => ["801"],
      "BaseVisible" => true
    })

    %{scope: scope}
  end

  defp search(q, scope, opts) do
    {hits, total, meta} = Content.search_documents(q, @ds, [type: "book"] ++ opts ++ scope)
    {hits |> Enum.map(& &1.doc_id) |> Enum.sort(), total, meta}
  end

  describe "[in]" do
    test "on an array field matches documents whose array holds one of the values",
         %{scope: scope} do
      {ids, total, meta} =
        search("legemiddelhåndtering", scope,
          filter_map: %{"BookGroupCodes" => %{"in" => ["802", "342"]}}
        )

      assert ids == ["exact-2", "exact-3"]
      assert total == 2
      assert meta.recovery == nil
    end

    test "on an array field matches nothing when no array holds a value", %{scope: scope} do
      {ids, total, _} =
        search("legemiddelhåndtering", scope,
          filter_map: %{"BookGroupCodes" => %{"in" => ["999"]}}
        )

      assert ids == []
      assert total == 0
    end

    test "on a scalar field matches documents whose value is one of the values",
         %{scope: scope} do
      {ids, total, _} =
        search("legemiddelhåndtering", scope,
          filter_map: %{"Format" => %{"in" => ["Lydbok", "Ebok"]}}
        )

      assert ids == ["exact-2", "exact-3"]
      assert total == 2
    end

    test "on scalar and array fields through the query API", %{scope: scope} do
      list = fn filter ->
        "book"
        |> Content.list_documents(@ds, [filter_map: filter, perspective: :published] ++ scope)
        |> Enum.map(& &1.doc_id)
        |> Enum.sort()
      end

      assert list.(%{"BookGroupCodes" => %{"in" => ["801"]}}) == ["exact-1", "near-miss"]
      assert list.(%{"Format" => %{"in" => ["Lydbok"]}}) == ["exact-2"]
    end
  end

  describe "a filter on an exact match" do
    test "keeps the unfiltered hits minus the filtered ones, with no recovery",
         %{scope: scope} do
      {all, 3, %{recovery: nil}} = search("legemiddelhåndtering", scope, [])
      assert all == ["exact-1", "exact-2", "exact-3"]

      {ids, total, meta} =
        search("legemiddelhåndtering", scope, filter_map: %{"BaseVisible" => "true"})

      assert ids == ["exact-1"]
      assert total == 1
      assert meta.recovery == nil
    end

    test "that leaves no hit answers empty instead of recovering", %{scope: scope} do
      # Only the near miss is a Pocket. The words find three documents, so
      # the answer is empty, not the near miss through typo recovery.
      {ids, total, meta} =
        search("legemiddelhåndtering", scope, filter_map: %{"Format" => "Pocket"})

      assert ids == []
      assert total == 0
      assert meta.recovery == nil
    end

    test "with a typo finds what the unfiltered search finds, minus the filtered ones",
         %{scope: scope} do
      {all, _, all_meta} = search("legemidelhåndtering", scope, [])
      assert all != []

      {ids, _, meta} =
        search("legemidelhåndtering", scope, filter_map: %{"BaseVisible" => "true"})

      assert ids == all -- ["exact-2", "exact-3"]
      assert ids != []
      assert meta.recovery == all_meta.recovery
    end
  end

  describe "SQL shape" do
    test "filters run as a subplan, facets ride in the count, a field is read once",
         %{scope: scope} do
      {statements, {_ids, total, meta}} =
        capture_sql(fn ->
          search("legemiddelhåndtering", scope,
            filter_map: %{"BookGroupCodes" => %{"in" => ["801", "802"]}},
            facet_fields: ["Format"]
          )
        end)

      assert total == 2
      assert meta.recovery == nil

      assert meta.facets["fields"]["Format"] == [
               %{"label" => "Heftet", "count" => 1},
               %{"label" => "Lydbok", "count" => 1}
             ]

      searches = Enum.filter(statements, &(&1 =~ ~s(FROM "documents")))

      # Every statement that applies the filter does it inside a correlated
      # EXISTS with OFFSET 0, which Postgres keeps as a subplan and tests
      # after the cheaper conditions of the scan.
      filtered =
        Enum.filter(searches, &(&1 =~ "THEN EXISTS (SELECT 1 FROM jsonb_array_elements(f.v)"))

      assert filtered != []

      for sql <- filtered do
        assert sql =~
                 ~r/exists\(\(SELECT 1 FROM "documents" AS \w+ WHERE \(\w+\."id" = \w+\."id"\)/

        assert sql =~ "OFFSET 0"
      end

      # The `in` filter reads the field once per row.
      for sql <- filtered do
        assert length(String.split(sql, "jsonb_extract_path(")) == 2
      end

      # The named facet is a grouping set of the count's own statement; no
      # other statement counts field values.
      [count_sql] = Enum.filter(searches, &(&1 =~ "GROUPING SETS"))
      assert count_sql =~ "unnest("
      assert count_sql =~ "WITH ORDINALITY"
      refute Enum.any?(searches -- [count_sql], &(&1 =~ "jsonb_array_elements_text"))
    end

    test "a facet counts each array element once per document", %{scope: scope} do
      {:ok, _} =
        Content.create_document(
          "book",
          %{
            "doc_id" => "dup",
            "content" => %{
              "displayName" => "Legemiddelhåndtering igjen",
              "BookGroupCodes" => ["801", "801", "803"]
            }
          },
          @ds,
          scope
        )

      {:ok, _} = Content.publish_document("dup", "book", @ds, scope)

      {_ids, total, meta} =
        search("legemiddelhåndtering", scope, facet_fields: ["BookGroupCodes", "Format"])

      assert total == 4
      assert meta.facets["type"] == [%{"label" => "book", "count" => 4}]

      assert meta.facets["fields"]["BookGroupCodes"] == [
               %{"label" => "801", "count" => 2},
               %{"label" => "327", "count" => 1},
               %{"label" => "342", "count" => 1},
               %{"label" => "802", "count" => 1},
               %{"label" => "803", "count" => 1}
             ]

      assert meta.facets["fields"]["Format"] == [
               %{"label" => "Ebok", "count" => 1},
               %{"label" => "Heftet", "count" => 1},
               %{"label" => "Lydbok", "count" => 1}
             ]
    end
  end

  # task-8af256dcd8f17902: search counts what the query API's facet counts.
  test "a facet counts booleans, numbers and references, as the query API does",
       %{scope: scope} do
    {:ok, _} =
      Content.create_document(
        "book",
        %{
          "doc_id" => "typed",
          "content" => %{
            "displayName" => "Legemiddelhåndtering typed",
            "Pages" => 120,
            "Author" => %{"_ref" => "ada"},
            "Editors" => [%{"_ref" => "ada"}, %{"_ref" => "bo"}],
            "BaseVisible" => true
          }
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("typed", "book", @ds, scope)

    {_ids, _total, meta} =
      search("legemiddelhåndtering", scope,
        facet_fields: ["BaseVisible", "Pages", "Author", "Editors"]
      )

    f = meta.facets["fields"]

    assert f["BaseVisible"] == [
             %{"label" => "false", "count" => 2},
             %{"label" => "true", "count" => 2}
           ]

    assert f["Pages"] == [%{"label" => "120", "count" => 1}]
    assert f["Author"] == [%{"label" => "ada", "count" => 1}]

    assert f["Editors"] == [
             %{"label" => "ada", "count" => 1},
             %{"label" => "bo", "count" => 1}
           ]
  end

  describe "the pool of a filtered search" do
    test "pages through every filtered match once, past the pool", %{scope: scope} do
      for n <- 1..6 do
        {:ok, _} =
          Content.create_document(
            "book",
            %{
              "doc_id" => "pool-#{n}",
              "content" => %{
                "displayName" => "Poolbok #{n}",
                "BaseVisible" => rem(n, 3) != 0
              }
            },
            @ds,
            scope
          )

        {:ok, _} = Content.publish_document("pool-#{n}", "book", @ds, scope)
      end

      pages =
        for offset <- [0, 2] do
          {ids, total, _} =
            search("poolbok", scope,
              filter_map: %{"BaseVisible" => "true"},
              limit: 2,
              offset: offset,
              ranking_pool_size: 2
            )

          assert total == 4
          ids
        end

      assert pages |> List.flatten() |> Enum.sort() == ["pool-1", "pool-2", "pool-4", "pool-5"]

      # A narrow filter: fewer than a pool's worth pass among the candidates,
      # so the pool falls back to the full filtered match.
      {ids, 2, _} =
        search("poolbok", scope,
          filter_map: %{"BaseVisible" => "false"},
          limit: 1,
          ranking_pool_size: 1
        )

      assert length(ids) == 1
    end
  end

  defp capture_sql(fun) do
    owner = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:barkpark, :repo, :query],
        fn _event, _measure, meta, _ ->
          if self() == owner, do: send(owner, {ref, meta.query})
        end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {collect(ref, []), result}
  end

  defp collect(ref, acc) do
    receive do
      {^ref, sql} -> collect(ref, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
