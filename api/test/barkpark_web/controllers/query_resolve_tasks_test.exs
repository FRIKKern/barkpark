defmodule BarkparkWeb.QueryResolveTasksTest do
  @moduledoc """
  Locks the API resolve seam (`?resolve=tasks`, p-resolve-seam): the query API
  can hand any consumer — Go pdrender, web, exports — the SAME resolved
  snapshot blocks the LiveView reader shows, instead of raw `query` blocks.

  Contract under test:
    * opt-in — without the param the wire shape is byte-identical (query kept)
    * with it, a query-carrying task block gains `snapshot` rows and drops `query`
    * author-pinned snapshots pass through untouched
    * both the list (index) and single-doc (show) routes resolve
    * fail-closed: rows come only from the request's tenant scope
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  setup %{conn: conn} do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    # The bearer must be a REAL token. It used to be a bare
    # "Bearer barkpark-dev-token" with nothing minted behind it — a string that
    # `Auth.verify_token/1` rejects (see test/barkpark/seeds_clean_test.exs),
    # so every request in this file silently ran as an ANONYMOUS caller while
    # reading as authed. The flat `/v1/data` read pipeline now refuses a
    # presented-but-unverifiable bearer with 401 (task-46872cadcfc50c5f), which
    # surfaced the decoration. Minting it makes the file test what it says.
    {:ok, _} =
      Barkpark.Auth.create_token(
        "barkpark-dev-token",
        "dev",
        @dataset,
        ["read", "write", "admin"]
      )

    %{conn: put_req_header(conn, "authorization", "Bearer barkpark-dev-token"), scope: scope}
  end

  defp mk_task!(title, lifecycle, label, scope) do
    doc_id = "rs-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => title,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => lifecycle,
            "labels" => [label]
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp mk_paper!(slug, blocks) do
    {:ok, _doc} =
      Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))

    slug
  end

  test "index: ?resolve=tasks turns a query block into a snapshot block", %{
    conn: conn,
    scope: scope
  } do
    label = "seam-#{System.unique_integer([:positive])}"
    mk_task!("resolve the seam", "done", label, scope)
    mk_task!("ship pdrender", "open", label, scope)

    slug =
      mk_paper!("seam-#{System.unique_integer([:positive])}", [
        %{"id" => "b1", "type" => "task-list", "query" => %{"label" => label}}
      ])

    docs =
      conn
      |> get("/v1/data/query/#{@dataset}/paper", %{"resolve" => "tasks"})
      |> json_response(200)
      |> get_in(["result", "documents"])

    doc = Enum.find(docs, &(&1["_id"] == slug))
    assert %{"blocks" => [block]} = doc
    refute Map.has_key?(block, "query")
    titles = block["snapshot"] |> Enum.map(& &1["title"]) |> Enum.sort()
    assert titles == ["resolve the seam", "ship pdrender"]
    # the honest ladder: open with no blocker surfaces as ready
    statuses = block["snapshot"] |> Enum.map(& &1["status"]) |> Enum.sort()
    assert statuses == ["done", "ready"]
  end

  test "index: WITHOUT the param the query block is untouched (opt-in contract)", %{
    conn: conn,
    scope: scope
  } do
    label = "noresolve-#{System.unique_integer([:positive])}"
    mk_task!("invisible", "open", label, scope)

    slug =
      mk_paper!("noresolve-#{System.unique_integer([:positive])}", [
        %{"id" => "b1", "type" => "task-list", "query" => %{"label" => label}}
      ])

    docs =
      conn
      |> get("/v1/data/query/#{@dataset}/paper")
      |> json_response(200)
      |> get_in(["result", "documents"])

    doc = Enum.find(docs, &(&1["_id"] == slug))
    assert %{"blocks" => [block]} = doc
    assert block["query"] == %{"label" => label}
    refute Map.has_key?(block, "snapshot")
  end

  test "show: single-doc route resolves; pinned snapshots pass through", %{
    conn: conn,
    scope: scope
  } do
    label = "show-#{System.unique_integer([:positive])}"
    mk_task!("only row", "in_progress", label, scope)

    pinned = [%{"title" => "pinned row", "status" => "done"}]

    slug =
      mk_paper!("show-#{System.unique_integer([:positive])}", [
        %{"id" => "b1", "type" => "task-list", "query" => %{"label" => label}},
        %{"id" => "b2", "type" => "task-list", "snapshot" => pinned}
      ])

    doc =
      conn
      |> get("/v1/data/doc/#{@dataset}/paper/#{slug}", %{"resolve" => "tasks"})
      |> json_response(200)
      |> Map.fetch!("result")

    assert [live, kept] = doc["blocks"]

    assert [%{"title" => "only row", "status" => "in_progress"}] =
             Enum.map(live["snapshot"], &Map.take(&1, ["title", "status"]))

    assert kept["snapshot"] == pinned
  end

  test "fail-closed: a foreign workspace's tasks never resolve into the rows", %{
    conn: conn,
    scope: scope
  } do
    label = "tenant-#{System.unique_integer([:positive])}"
    mk_task!("mine", "open", label, scope)

    # a second workspace with a same-labelled task
    other_ws = TenancyFixtures.create_workspace!()
    other_scope = [workspace_id: other_ws.id]
    mk_task!("theirs", "open", label, other_scope)

    slug =
      mk_paper!("tenant-#{System.unique_integer([:positive])}", [
        %{"id" => "b1", "type" => "task-list", "query" => %{"label" => label}}
      ])

    doc =
      conn
      |> get("/v1/data/doc/#{@dataset}/paper/#{slug}", %{"resolve" => "tasks"})
      |> json_response(200)
      |> Map.fetch!("result")

    titles = doc["blocks"] |> hd() |> Map.fetch!("snapshot") |> Enum.map(& &1["title"])
    assert titles == ["mine"]
  end
end
