defmodule Barkpark.Search.SearchRefreshTest do
  @moduledoc """
  task-9d83c3e0c3b8fabf — a schema write recomputed the search slots of every
  document of its type inside the write, whatever the change. On the
  gyldendal-no workspace (18,022 products) the write answered 500 after the
  15 s request timeout and rolled back.

  Migration 20261016130000 recomputes only what a change touches, inline for
  a scope of at most `barkpark.search_refresh_inline_max` documents and in
  batches through `SearchRefresh.drain/1` above that. While a refresh after a
  change that made a field restricted is pending, a non-admin text search
  leaves the scope's documents out.

  The tests lower the inline limit with `SET LOCAL` inside the sandbox
  transaction, so three documents stand in for a large type.
  """
  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Repo
  alias Barkpark.Search.SearchRefresh
  alias Barkpark.Search.Workers.SearchRefresh, as: Worker

  @ds "search-refresh-test"
  @admin %CallerContext{principal_type: :api_token, is_admin: true}

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    %{scope: [workspace_id: ws.id, project_id: proj.id]}
  end

  defp schema!(scope, fields, extra \\ %{}) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(
          %{"name" => "memo", "title" => "Memo", "visibility" => "public", "fields" => fields},
          extra
        ),
        @ds,
        scope
      )
  end

  defp doc!(scope, id, content) do
    {:ok, _} =
      Content.create_document(
        "memo",
        Map.merge(%{"doc_id" => id, "title" => "Memo #{id}"}, content),
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(id, "memo", @ds, scope)
    id
  end

  defp large_type! do
    Repo.query!("SET LOCAL barkpark.search_refresh_inline_max = '1'")
  end

  defp column(id, col) do
    %{rows: [[v]]} =
      Repo.query!(
        "SELECT #{col}::text FROM documents WHERE doc_id = $1 AND dataset = $2",
        [id, @ds]
      )

    v
  end

  defp pending do
    %{rows: rows} =
      Repo.query!(
        "SELECT type, slots, public, gate FROM search_refresh_pending WHERE scope_dataset = $1",
        [@ds]
      )

    rows
  end

  defp count(scope, q, ctx, opts \\ []) do
    {_hits, total, _meta} =
      Content.search_documents(q, @ds, [caller_context: ctx] ++ opts ++ scope)

    total
  end

  test "a change to nothing the slots read leaves every document unwritten", %{scope: scope} do
    fields = [
      %{"name" => "displayName", "type" => "string"},
      %{"name" => "isbn", "type" => "string"}
    ]

    schema!(scope, fields)
    doc!(scope, "m1", %{"displayName" => "Min kamp", "isbn" => "978"})

    # A marker the slot recompute would overwrite. A column write fires no
    # document trigger.
    Repo.query!(
      "UPDATE documents SET search_author = 'marker' WHERE doc_id = 'm1' AND dataset = $1",
      [@ds]
    )

    # The kind of change the gyldendal-no product schema made: a list
    # preview subtitle, a description, a required rule, a new plain field.
    schema!(
      scope,
      [
        %{"name" => "displayName", "type" => "string", "description" => "Shown on the page"},
        %{"name" => "isbn", "type" => "string", "validation" => %{"required" => true}},
        %{"name" => "notes", "type" => "text"}
      ],
      %{"list_preview" => %{"subtitle" => %{"parts" => ["isbn"]}}}
    )

    assert column("m1", "search_author") == "marker"
    assert pending() == []
  end

  test "a slot change on a large type is left to the worker, which recomputes it in batches",
       %{scope: scope} do
    schema!(scope, [
      %{"name" => "body", "type" => "string"},
      %{"name" => "writer", "type" => "string"}
    ])

    for i <- 1..3, do: doc!(scope, "m#{i}", %{"writer" => "Karl Ove Knausgård"})
    assert column("m1", "search_author") == nil

    large_type!()

    schema!(scope, [
      %{"name" => "body", "type" => "string"},
      %{"name" => "writer", "type" => "string", "search" => "author"}
    ])

    # Not recomputed in the write.
    assert column("m1", "search_author") == nil
    assert pending() == [["memo", true, false, false]]
    assert_enqueued(worker: Worker)

    assert SearchRefresh.drain(batch: 2) == 3
    for i <- 1..3, do: assert(column("m#{i}", "search_author") == "Karl Ove Knausgård")
    assert pending() == []
  end

  test "the worker drains the pending refreshes", %{scope: scope} do
    schema!(scope, [%{"name" => "writer", "type" => "string"}])
    for i <- 1..3, do: doc!(scope, "m#{i}", %{"writer" => "Geir Gulliksen"})
    large_type!()
    schema!(scope, [%{"name" => "writer", "type" => "string", "search" => "author"}])

    assert {:ok, 3} = perform_job(Worker, %{})
    assert column("m3", "search_author") == "Geir Gulliksen"
    assert pending() == []
  end

  test "a small type is still recomputed in the write", %{scope: scope} do
    schema!(scope, [%{"name" => "writer", "type" => "string"}])
    doc!(scope, "m1", %{"writer" => "Geir Gulliksen"})
    schema!(scope, [%{"name" => "writer", "type" => "string", "search" => "author"}])

    assert column("m1", "search_author") == "Geir Gulliksen"
    assert pending() == []
  end

  test "a field made private on a large type is never searchable by a non-admin, before or after the refresh",
       %{scope: scope} do
    schema!(scope, [
      %{"name" => "notes", "type" => "text"},
      %{"name" => "summary", "type" => "text"}
    ])

    for i <- 1..3,
        do: doc!(scope, "m#{i}", %{"notes" => "quixotical", "summary" => "harmless"})

    anon = CallerContext.anonymous()
    assert count(scope, "quixotical", anon) == 3

    large_type!()

    schema!(scope, [
      %{"name" => "notes", "type" => "text", "private" => true},
      %{"name" => "summary", "type" => "text"}
    ])

    # The public vectors are stale: they were NULL (nothing restricted), so
    # the full vector, which holds the private word, would stand in for them.
    assert column("m1", "public_search_vector") == nil
    assert pending() == [["memo", false, true, true]]

    # The pending gate leaves the documents out of a non-admin search, with or
    # without a type, so the private word neither matches nor counts.
    for ctx <- [anon, nil], opts <- [[], [type: "memo"]] do
      assert count(scope, "quixotical", ctx, opts) == 0
      assert count(scope, "harmless", ctx, opts) == 0
    end

    # An admin searches the full vector and is not gated.
    assert count(scope, "quixotical", @admin) == 3

    # A browse reads no vector and still lists them.
    assert count(scope, "", anon) == 3

    assert SearchRefresh.drain() == 3
    assert pending() == []

    for ctx <- [anon, nil], opts <- [[], [type: "memo"]] do
      assert count(scope, "quixotical", ctx, opts) == 0
      assert count(scope, "harmless", ctx, opts) == 3
    end

    assert count(scope, "quixotical", @admin) == 3
  end

  test "a restriction removed on a large type needs no gate", %{scope: scope} do
    schema!(scope, [%{"name" => "notes", "type" => "text", "private" => true}])
    for i <- 1..3, do: doc!(scope, "m#{i}", %{"notes" => "quixotical", "summary" => "harmless"})
    large_type!()
    schema!(scope, [%{"name" => "notes", "type" => "text"}])

    assert pending() == [["memo", false, true, false]]
    # The stale public vectors hide more than the new schema does.
    anon = CallerContext.anonymous()
    assert count(scope, "harmless", anon) == 3
    assert count(scope, "quixotical", anon, type: "memo") == 3

    SearchRefresh.drain()
    assert count(scope, "quixotical", anon) == 3
  end

  test "a kid made private inside an array item shape sets the gate", %{scope: scope} do
    rows = fn private? ->
      [
        %{
          "name" => "rows",
          "type" => "array",
          "of" => %{
            "fields" => [
              Map.merge(
                %{"name" => "secret", "type" => "string"},
                if(private?, do: %{"private" => true}, else: %{})
              ),
              %{"name" => "label", "type" => "string", "description" => "private"}
            ]
          }
        }
      ]
    end

    schema!(scope, rows.(false))
    for i <- 1..3, do: doc!(scope, "m#{i}", %{"rows" => [%{"secret" => "foxtrotword"}]})
    large_type!()

    # The old fields mention "private" (an option value) but restrict nothing,
    # so the change is a real restriction change.
    schema!(scope, rows.(true))
    assert pending() == [["memo", false, true, true]]
    assert count(scope, "foxtrotword", CallerContext.anonymous()) == 0

    SearchRefresh.drain()
    assert count(scope, "foxtrotword", CallerContext.anonymous()) == 0
    assert count(scope, "foxtrotword", @admin) == 3
  end

  test "two writes before the refresh leave one pending row with both needs", %{scope: scope} do
    schema!(scope, [
      %{"name" => "notes", "type" => "text"},
      %{"name" => "writer", "type" => "string"}
    ])

    for i <- 1..3, do: doc!(scope, "m#{i}", %{"notes" => "quixotical", "writer" => "Geir"})
    large_type!()

    schema!(scope, [
      %{"name" => "notes", "type" => "text", "private" => true},
      %{"name" => "writer", "type" => "string"}
    ])

    schema!(scope, [
      %{"name" => "notes", "type" => "text", "private" => true},
      %{"name" => "writer", "type" => "string", "search" => "author"}
    ])

    assert pending() == [["memo", true, true, true]]

    %{rows: [[gen]]} =
      Repo.query!("SELECT gen FROM search_refresh_pending WHERE scope_dataset = $1", [@ds])

    assert gen == 2

    SearchRefresh.drain()
    assert pending() == []
    assert column("m1", "search_author") == "Geir"
    assert count(scope, "quixotical", CallerContext.anonymous()) == 0
  end
end
