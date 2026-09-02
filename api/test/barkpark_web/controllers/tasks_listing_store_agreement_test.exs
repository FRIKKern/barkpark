defmodule BarkparkWeb.TasksListingStoreAgreementTest do
  @moduledoc """
  The ledger's LISTINGS must agree with its by-id STORE.

  Two independently-filed divergences, one law: a reader that lies silently
  sends agents into blind retry loops or past the rows they most need to see.

  ## 1. `ready` serves a doc_id `get` cannot resolve (task-0c30e7b99ad87cec)

  `documents` is unique on `(doc_id, type, dataset_id)`, so ONE task doc_id may
  live in TWO datasets inside a single workspace/project. `bp task ready` lists
  such a row (once per dataset — it carries no dataset discriminator either),
  while `TasksController.fetch_task_exact/3` read it with a bare `Repo.one/1`
  and raised `Ecto.MultipleResultsError` → HTTP 500. Deterministic, not a race:
  measured on guerrilla 2026-09-02, `akbr-feedback-2026-08-epic` appeared TWICE
  in one `bp task ready --limit 1000` page and three consecutive `bp task get`
  calls all returned `internal_error`.

  ## 2. `child_count` means three things (task-3e0eda896a247776)

  Before the fix the field answered differently per door — present on the brief
  card, ABSENT from the full (default) card, and on `show` at the TOP LEVEL but
  absent from `doc`. Two of the three doors read 0 for `doc.child_count`, so an
  epic ROOT passes the fleet's "skip a high child_count" triage filter as a
  childless leaf. Measured: `task-57451a6ce0a0505e` carries 189 children and its
  shards entered a bulk-cancel candidate list twice on exactly this misread.

  ## Scoping

  Every assertion is keyed to ids this test inserted (`System.unique_integer`
  suffixes) and to its own fixture parent. The fleet shares one test database;
  nothing here counts a whole table.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Repo, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-listing-store-agreement"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-listing-store", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)

    %{conn: conn, ws: ws, project: project}
  end

  defp insert_task!(doc_id, ws, project, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(Keyword.get(opts, :content, %{}))

    row = %{
      id: Ecto.UUID.generate(),
      doc_id: doc_id,
      type: "task",
      dataset: Keyword.get(opts, :dataset, "production"),
      title: doc_id,
      status: Keyword.get(opts, :status, "published"),
      content: content,
      workspace_id: ws.id,
      project_id: project.id,
      inserted_at: now,
      updated_at: now,
      rev: "lsa-#{System.unique_integer([:positive])}"
    }

    {1, nil} = Repo.insert_all(Document, [row])
    row
  end

  # ── 1. the by-id reader resolves what the listing served ────────────────

  describe "GET /v1/tasks/:doc_id over a doc_id that lives in two datasets" do
    test "resolves to exactly one row instead of raising (task-0c30e7b99ad87cec)",
         %{conn: conn, ws: ws, project: project} do
      doc_id = "lsa-twodataset-#{System.unique_integer([:positive])}"

      insert_task!(doc_id, ws, project, dataset: "production")
      insert_task!(doc_id, ws, project, dataset: "staging")

      # The premise: the STORE really does hold two rows under this one id,
      # inside one workspace/project. Scoped to THIS test's doc_id.
      assert Repo.aggregate(from(d in Document, where: d.doc_id == ^doc_id), :count) == 2

      # RED before the fix: `Repo.one/1` raises Ecto.MultipleResultsError here,
      # which surfaces as a 500 on every call for the life of the collision.
      resp = get(conn, "/v1/tasks/#{doc_id}") |> json_response(200)

      assert resp["ok"] == true
      assert resp["doc"]["doc_id"] == doc_id
    end

    test "the resolution is stable across repeated reads", %{conn: conn, ws: ws, project: project} do
      doc_id = "lsa-stable-#{System.unique_integer([:positive])}"

      insert_task!(doc_id, ws, project, dataset: "production")
      insert_task!(doc_id, ws, project, dataset: "staging")

      # A `LIMIT 1` with a PARTIAL order would trade the 500 for a silently
      # alternating answer — the worse defect. The order is total, so five
      # reads must name one and the same row.
      ids =
        for _ <- 1..5 do
          get(conn, "/v1/tasks/#{doc_id}") |> json_response(200) |> get_in(["doc", "id"])
        end

      assert length(Enum.uniq(ids)) == 1
    end

    test "a published row wins over a draft row of the same id in another dataset",
         %{conn: conn, ws: ws, project: project} do
      doc_id = "lsa-published-wins-#{System.unique_integer([:positive])}"

      # Insert the DRAFT first and in the alphabetically-earlier dataset, so
      # only the status arm of the order can put the published row on top.
      draft = insert_task!(doc_id, ws, project, dataset: "aaa-staging", status: "draft")
      published = insert_task!(doc_id, ws, project, dataset: "zzz-production", status: "published")

      resp = get(conn, "/v1/tasks/#{doc_id}") |> json_response(200)

      assert resp["doc"]["id"] == published.id
      refute resp["doc"]["id"] == draft.id
    end

    test "an ordinary single-row task is unaffected", %{conn: conn, ws: ws, project: project} do
      doc_id = "lsa-single-#{System.unique_integer([:positive])}"
      row = insert_task!(doc_id, ws, project, [])

      resp = get(conn, "/v1/tasks/#{doc_id}") |> json_response(200)

      assert resp["doc"]["id"] == row.id
      assert resp["child_count"] == 0
    end

    test "a genuinely absent id still 404s — the fix widens nothing", %{conn: conn} do
      absent = "lsa-absent-#{System.unique_integer([:positive])}"

      resp = get(conn, "/v1/tasks/#{absent}") |> json_response(404)
      assert resp["ok"] == false
    end
  end

  # ── 2. one child_count, one meaning, every reader ───────────────────────

  describe "child_count agrees across every task reader" do
    setup %{ws: ws, project: project} do
      parent_id = "lsa-epic-#{System.unique_integer([:positive])}"
      insert_task!(parent_id, ws, project, [])

      for i <- 1..3 do
        insert_task!("#{parent_id}-child-#{i}", ws, project,
          content: %{"parent_id" => parent_id}
        )
      end

      %{parent_id: parent_id}
    end

    test "GET /v1/tasks/:doc_id carries child_count INSIDE doc, not only at the top level",
         %{conn: conn, parent_id: parent_id} do
      resp = get(conn, "/v1/tasks/#{parent_id}") |> json_response(200)

      # The top-level key is the pre-existing contract — unchanged.
      assert resp["child_count"] == 3

      # RED before the fix: `doc` carried no `child_count` key at all, so every
      # reader shaped like a LIST card read 0 for a parent with children.
      assert resp["doc"]["child_count"] == 3
    end

    test "the full (default) list card carries child_count too",
         %{conn: conn, parent_id: parent_id} do
      resp = get(conn, "/v1/tasks?limit=1000") |> json_response(200)

      card = Enum.find(resp["docs"], &(&1["doc_id"] == parent_id))
      assert card, "the fixture parent must be in its own listing"

      # RED before the fix: the full card omitted `child_count` entirely.
      assert card["child_count"] == 3
    end

    test "the brief list card, the full list card and the by-id reader agree",
         %{conn: conn, parent_id: parent_id} do
      brief =
        get(conn, "/v1/tasks?view=brief&limit=1000")
        |> json_response(200)
        |> Map.fetch!("docs")
        |> Enum.find(&(&1["doc_id"] == parent_id))

      full =
        get(conn, "/v1/tasks?limit=1000")
        |> json_response(200)
        |> Map.fetch!("docs")
        |> Enum.find(&(&1["doc_id"] == parent_id))

      by_id = get(conn, "/v1/tasks/#{parent_id}") |> json_response(200)

      assert brief["child_count"] == 3
      assert full["child_count"] == brief["child_count"]
      assert by_id["doc"]["child_count"] == brief["child_count"]
      assert by_id["child_count"] == brief["child_count"]
    end

    test "a childless task reads 0 on every reader — the field is not merely present",
         %{conn: conn, ws: ws, project: project} do
      leaf = "lsa-leaf-#{System.unique_integer([:positive])}"
      insert_task!(leaf, ws, project, [])

      full =
        get(conn, "/v1/tasks?limit=1000")
        |> json_response(200)
        |> Map.fetch!("docs")
        |> Enum.find(&(&1["doc_id"] == leaf))

      assert full["child_count"] == 0
      assert get(conn, "/v1/tasks/#{leaf}") |> json_response(200) |> get_in(["doc", "child_count"]) ==
               0
    end
  end
end
