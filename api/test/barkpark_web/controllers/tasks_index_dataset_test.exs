defmodule BarkparkWeb.TasksIndexDatasetTest do
  @moduledoc """
  `GET /v1/tasks?dataset=` — THE INDEX ROUTE, as a scope selector
  (task-8483029782444df4).

  `Barkpark.Tasks.TwinResolver` states THE ONE RULE; this file proves the index
  listing is an instance of it and not a second, competing rule. `ready` has
  honoured `?dataset=` since task-0084e191d406de96 and the by-id/claim doors
  since #18509 — the index did not, and did not REFUSE either: `dataset` rides
  the `@phoenix_injected` allowlist, so `?dataset=nosuchds` answered 200 with a
  full global page.

  RED on origin/main (measured by reverting the controller hunk):

    * `?dataset=<a>` returned rows from dataset <b> as well,
    * `?dataset=nosuchds` returned a full page instead of an empty one,
    * `page` carried no `dataset` / `datasets` / `dataset_scope` /
      `dataset_ambiguous` keys at all.

  The QUIET arm is the last two tests: a caller who names NO dataset gets the
  same rows it always got (twins still withheld, never silently un-collapsed),
  and a named dataset does not disturb a task that lives in exactly one.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-index-dataset"
  @primary "production"
  @secondary "aker-brygge"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-index-dataset", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for dataset <- [@primary, @secondary], schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Same fixture shape as `BarkparkWeb.TasksTwinOneRuleTest` — a published row is
  # seeded by renaming a draft in place.
  defp mk_published!(doc_id, dataset, scope, extra) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ]
        },
        extra
      )

    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "#{doc_id} (#{dataset} #{System.unique_integer([:positive])})",
          "content" => content
        },
        dataset,
        scope
      )

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  # NEVER `Repo.all` the corpus and never assert on a whole page: every agent
  # shares ONE Postgres test DB, so every assertion here is scoped to the ids
  # THIS test seeded. `?label=` is the narrowing — one indexed filter the route
  # already honours — so the page is this test's rows and nobody else's.
  defp page(conn, label, query \\ "") do
    authed(conn)
    |> get("/v1/tasks?label=#{label}&limit=50#{query}")
    |> json_response(200)
  end

  defp doc_ids(resp), do: resp["docs"] |> Enum.map(& &1["doc_id"]) |> Enum.sort()

  describe "?dataset= narrows the index page" do
    setup %{scope: scope} do
      label = uniq("idxds")
      only_primary = uniq("idxds-p")
      only_secondary = uniq("idxds-s")

      mk_published!(only_primary, @primary, scope, %{"labels" => [label]})
      mk_published!(only_secondary, @secondary, scope, %{"labels" => [label]})

      %{label: label, only_primary: only_primary, only_secondary: only_secondary}
    end

    test "names ONE dataset and gets only that dataset's rows", ctx do
      # RED on origin/main: BOTH ids come back under either dataset.
      primary = page(ctx.conn, ctx.label, "&dataset=#{@primary}")
      assert doc_ids(primary) == [ctx.only_primary]

      secondary = page(ctx.conn, ctx.label, "&dataset=#{@secondary}")
      assert doc_ids(secondary) == [ctx.only_secondary]
    end

    test "the page envelope NAMES the scope, the way /v1/tasks/ready does", ctx do
      # RED on origin/main: `page` has none of these four keys.
      named = page(ctx.conn, ctx.label, "&dataset=#{@primary}")

      assert named["page"]["dataset"] == @primary
      assert named["page"]["datasets"] == [@primary]
      assert named["page"]["dataset_scope"] == "named"
      assert named["page"]["dataset_ambiguous"] == []
    end

    test "?dataset=nosuchds is an EMPTY page, not a full global one", ctx do
      # THE FILED SYMPTOM, verbatim: `?limit=50&dataset=nosuchds` returned a
      # full page of 50 rows.
      resp = page(ctx.conn, ctx.label, "&dataset=nosuchds")

      assert resp["docs"] == []
      assert resp["page"]["returned"] == 0
      assert resp["page"]["dataset"] == "nosuchds"
      assert resp["page"]["datasets"] == []
      assert resp["page"]["dataset_scope"] == "named"
    end

    # ── THE QUIET ARM ───────────────────────────────────────────────────────
    test "with NO dataset the page still spans both, and SAYS which", ctx do
      resp = page(ctx.conn, ctx.label)

      assert doc_ids(resp) == Enum.sort([ctx.only_primary, ctx.only_secondary])
      assert resp["page"]["dataset"] == nil
      assert resp["page"]["dataset_scope"] == "all-datasets-in-scope"
      assert resp["page"]["datasets"] == Enum.sort([@primary, @secondary])
    end
  end

  describe "a doc_id living in TWO datasets (TwinResolver rule 3)" do
    setup %{scope: scope} do
      label = uniq("idxtwin")
      twin = uniq("idxtwin-both")
      solo = uniq("idxtwin-solo")

      mk_published!(twin, @primary, scope, %{"labels" => [label]})
      mk_published!(twin, @secondary, scope, %{"labels" => [label], "dataset_twin_intended" => true})
      mk_published!(solo, @primary, scope, %{"labels" => [label]})

      %{label: label, twin: twin, solo: solo}
    end

    test "with NO dataset it is WITHHELD and named once in page.dataset_ambiguous", ctx do
      resp = page(ctx.conn, ctx.label)

      # The withholding itself predates this row (collapse_cross_dataset_twins
      # was unconditional). What is new is that the page SAYS so instead of
      # dropping the id in silence — the rule-3 refusal, scoped to the row.
      assert doc_ids(resp) == [ctx.solo]

      assert %{"doc_id" => ctx.twin, "datasets" => Enum.sort([@primary, @secondary])} in
               resp["page"]["dataset_ambiguous"]
    end

    test "naming the dataset IS the disambiguation — the twin comes back, once", ctx do
      # RED on origin/main twice over: `?dataset=` did nothing, so the twin
      # stayed withheld no matter what the caller named.
      resp = page(ctx.conn, ctx.label, "&dataset=#{@secondary}")

      assert doc_ids(resp) == [ctx.twin]
      assert resp["page"]["dataset_ambiguous"] == []
    end

    test "a single-dataset task is unaffected by either spelling", ctx do
      named = page(ctx.conn, ctx.label, "&dataset=#{@primary}")
      assert ctx.solo in doc_ids(named)

      unnamed = page(ctx.conn, ctx.label)
      assert ctx.solo in doc_ids(unnamed)
    end
  end
end
