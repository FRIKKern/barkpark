defmodule Barkpark.EdgeProjector.TasksEdgeProjectionTest do
  @moduledoc """
  Phase 3 — the Tasks plugin's `extract_edges/2` projects the AUTHORITATIVE
  `task_edges` rows (gap #1) carrying their real `kind` (gap #2).

  These are the two CONFIRMED blocking fixes:

    1. The dependency graph comes from the `task_edges` table — the only
       authoritative store — NOT the DEAD `content.dependencies` key. The pure
       callback reads the rows the worker HYDRATES onto the payload
       (`Tasks.hydrate_edges/1`); writing `content.dependencies` projects NO
       blocks edge.
    2. BOTH whitelisted kinds (`blocks` AND `discovered-from`) surface — the
       row's real `kind` is mapped straight through, never hardcoded `"blocks"`.

  Runs against the test DB (Postgres on :5432).
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Tasks, as: TasksPlugin

  @dataset "production"

  setup do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

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

    prev_plugins = Application.get_env(:barkpark, :plugins)
    Application.delete_env(:barkpark, :plugins)

    # Register the REAL Tasks plugin so the collector drives its
    # resolve_extract_edges/2 (not a fake) — the headline blast-radius path.
    :ok = Registry.register(TasksPlugin, %{"plugin_name" => "tasks"})

    on_exit(fn ->
      Registry.reset()

      case prev_plugins do
        nil -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end
    end)

    %{scope: scope}
  end

  # Create + publish a task doc, return the published %Document{}. `content_extra`
  # is merged into the task content (where `parent_id` / `dependencies` live).
  defp publish_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Barkpark.LabelFixtures.with_labels()
      |> Map.merge(content_extra)

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, "task", @dataset, scope)
    doc
  end

  defp project_edges(doc) do
    Registry.collect_edge_extractors(baseline: [], ctx: %{doc: doc, dataset: @dataset})
  end

  describe "task_edges is the authoritative source (gap #1)" do
    test "a real blocks task_edges row surfaces as a blocks content edge", %{scope: scope} do
      src = publish_task!("t-a", scope)
      blk = publish_task!("t-b", scope)

      # Real dependency lives in task_edges (from = dependent, to = blocker).
      {:ok, _} = Tasks.add_dep(src.id, blk.id, :blocks)

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      blocks = Enum.filter(edges, &(&1[:kind] == "blocks"))
      assert [%{from_id: "t-a", to_id: "t-b", plugin_source: "tasks"}] = blocks
    end

    test "content.dependencies is a DEAD KEY — writing it projects NO blocks edge",
         %{scope: scope} do
      # No task_edges rows; the dependency lives ONLY in the dead key.
      src = publish_task!("t-c", scope, %{"dependencies" => ["t-d"]})
      _blk = publish_task!("t-d", scope)

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      assert Enum.filter(edges, &(&1[:kind] == "blocks")) == []
    end

    test "an un-hydrated task emits no blocks edge (the dead key is never read)",
         %{scope: scope} do
      src = publish_task!("t-e", scope)
      blk = publish_task!("t-f", scope)
      {:ok, _} = Tasks.add_dep(src.id, blk.id, :blocks)

      # Project the RAW (un-hydrated) doc — no task_edges on the payload.
      edges = project_edges(src)
      assert Enum.filter(edges, &(&1[:kind] == "blocks")) == []
    end
  end

  describe "both kinds surface (gap #2)" do
    test "a discovered-from task_edges row surfaces as a discovered-from content edge",
         %{scope: scope} do
      src = publish_task!("t-g", scope)
      disc = publish_task!("t-h", scope)

      {:ok, _} = Tasks.add_dep(src.id, disc.id, :"discovered-from")

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      found = Enum.filter(edges, &(&1[:kind] == "discovered-from"))
      assert [%{from_id: "t-g", to_id: "t-h", plugin_source: "tasks"}] = found
    end

    test "blocks AND discovered-from from the same source both surface with their real kind",
         %{scope: scope} do
      src = publish_task!("t-i", scope)
      b = publish_task!("t-j", scope)
      d = publish_task!("t-k", scope)

      {:ok, _} = Tasks.add_dep(src.id, b.id, :blocks)
      {:ok, _} = Tasks.add_dep(src.id, d.id, :"discovered-from")

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      kinds = edges |> Enum.map(& &1[:kind]) |> Enum.sort()
      assert "blocks" in kinds
      assert "discovered-from" in kinds
    end
  end

  describe "parent_id still projects (regression)" do
    test "content.parent_id surfaces as a parent edge alongside task_edges",
         %{scope: scope} do
      src = publish_task!("t-l", scope, %{"parent_id" => "t-parent"})
      b = publish_task!("t-m", scope)
      {:ok, _} = Tasks.add_dep(src.id, b.id, :blocks)

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      parent = Enum.find(edges, &(&1[:kind] == "parent"))
      assert parent[:from_id] == "t-l"
      assert parent[:to_id] == "t-parent"

      assert Enum.any?(edges, &(&1[:kind] == "blocks"))
    end
  end

  # ── Paper citations: wave_paper + papers (graph-papers) ───────────────────
  #
  # THE DEFECT THESE PIN. `wave_paper` is undeclared on the task schema and
  # `papers` is declared `"type" => "array"` (not `arrayOf reference`), so the
  # CORE extractor — which folds only over `"reference"` and
  # `"arrayOf"`-of-`"reference"` fields — projected neither. Measured on the
  # live corpus 2026-08-24: 4320 published tasks carry `wave_paper` and 412
  # carry `papers`, against 213 carrying the one declared reference
  # `design_doc`; distinct papers reachable through `bp graph tasks` was 24 of
  # 1015 while the three keys together cite 564.
  #
  # The last test in this block is the one the row asked for: it goes through
  # `Tasks.Expectations.driven_tasks/2` — the reader a Paper actually uses — so
  # a regression to a string field cannot pass by projecting an edge that no
  # reader can see.

  describe "paper citations project (wave_paper + papers)" do
    test "content.wave_paper surfaces as a wave_paper edge", %{scope: scope} do
      src = publish_task!("t-wp", scope, %{"wave_paper" => "some-wave-paper"})

      edges = project_edges(TasksPlugin.hydrate_edges(src))

      wave = Enum.filter(edges, &(&1[:kind] == "wave_paper"))
      assert [%{from_id: "t-wp", to_id: "some-wave-paper", plugin_source: "tasks"}] = wave
    end

    test "content.papers surfaces one edge per entry", %{scope: scope} do
      src = publish_task!("t-pl", scope, %{"papers" => ["paper-one", "paper-two"]})

      edges = project_edges(TasksPlugin.hydrate_edges(src))

      targets =
        edges |> Enum.filter(&(&1[:kind] == "papers")) |> Enum.map(& &1[:to_id]) |> Enum.sort()

      assert targets == ["paper-one", "paper-two"]
    end

    test "a repeated target in papers emits ONE edge — (from,to,kind) is unique",
         %{scope: scope} do
      # `published_id/1` collapses the drafts. twin onto the same target, so a
      # naive one-edge-per-entry projection would emit a colliding pair here.
      src = publish_task!("t-dup", scope, %{"papers" => ["p-dup", "drafts.p-dup", "p-dup"]})

      edges = project_edges(TasksPlugin.hydrate_edges(src))

      assert [%{to_id: "p-dup"}] = Enum.filter(edges, &(&1[:kind] == "papers"))
    end

    test "blank and non-string entries are skipped, not projected as empty targets",
         %{scope: scope} do
      src =
        publish_task!("t-blank", scope, %{
          "wave_paper" => "   ",
          "papers" => ["", "  ", "real-paper"]
        })

      edges = project_edges(TasksPlugin.hydrate_edges(src))

      assert Enum.filter(edges, &(&1[:kind] == "wave_paper")) == []
      assert [%{to_id: "real-paper"}] = Enum.filter(edges, &(&1[:kind] == "papers"))
    end

    test "a task citing one paper through BOTH keys emits both, with distinct kinds",
         %{scope: scope} do
      src =
        publish_task!("t-both", scope, %{
          "wave_paper" => "shared-paper",
          "papers" => ["shared-paper"]
        })

      edges = project_edges(TasksPlugin.hydrate_edges(src))

      kinds =
        edges
        |> Enum.filter(&(&1[:to_id] == "shared-paper"))
        |> Enum.map(& &1[:kind])
        |> Enum.sort()

      assert kinds == ["papers", "wave_paper"]
    end

    test "a task with neither key projects no paper edge", %{scope: scope} do
      src = publish_task!("t-none", scope)

      edges = project_edges(TasksPlugin.hydrate_edges(src))

      assert Enum.filter(edges, &(&1[:kind] in ["wave_paper", "papers"])) == []
    end

    test "parent_id and task_edges still project alongside the paper edges",
         %{scope: scope} do
      src =
        publish_task!("t-mix", scope, %{
          "parent_id" => "t-mix-parent",
          "wave_paper" => "t-mix-wave"
        })

      # A deliberately UNRELATED doc_id: `publish_task!/3` uses the doc_id as the
      # title, and the dedup wall refuses a near-duplicate title (`t-mix-blocker`
      # scored 0.75 against `t-mix` and was refused).
      blk = publish_task!("t-qq", scope)
      {:ok, _} = Tasks.add_dep(src.id, blk.id, :blocks)

      kinds =
        src
        |> TasksPlugin.hydrate_edges()
        |> project_edges()
        |> Enum.map(& &1[:kind])
        |> Enum.sort()

      assert "parent" in kinds
      assert "blocks" in kinds
      assert "wave_paper" in kinds
    end

    # THE READER TEST (the row's criterion 4). An edge nothing can read is not a
    # fix — this drives the real projector into content_edges and then asks the
    # Paper-side reader, `Tasks.Expectations.driven_tasks/2`, what drives it.
    test "a wave_paper citation is readable by Tasks.Expectations.driven_tasks/2",
         %{scope: scope} do
      paper_slug = "gp-driven-paper-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: paper_slug,
            body_html: ~s(<section id="gp"><h1>Driven</h1></section>),
            event_type: "plan-written"
          })
        )

      task = publish_task!("t-driven", scope, %{"wave_paper" => paper_slug})

      # Project for real — this is the path the EdgeProjector worker takes.
      {:ok, _} =
        Barkpark.EdgeProjector.Projector.upsert_record(
          TasksPlugin.hydrate_edges(task),
          Keyword.put(scope, :dataset, @dataset)
        )

      %{tasks: driven} =
        Barkpark.Tasks.Expectations.driven_tasks(
          paper_slug,
          Keyword.put(scope, :dataset, @dataset)
        )

      entry = Enum.find(driven, &(&1.doc_id == "t-driven"))

      assert entry,
             "the paper's driven-task reader did not see the citing task; got " <>
               inspect(Enum.map(driven, & &1.doc_id))

      assert "wave_paper" in entry.via,
             "expected the citing channel in via, got #{inspect(entry.via)}"
    end

    # THE OPERATOR PATH (the row's criterion 2). The tests above prove the pure
    # callback; this proves the command an operator actually runs against the
    # live corpus — `mix barkpark.edges.backfill --apply --types task` — puts the
    # edge in `content_edges` for a task that ALREADY EXISTED before this change,
    # and that a second sweep converges rather than duplicating.
    #
    # No new backfill was written for this row: `EdgeProjector.Backfill.run/1`
    # and its mix task both predate it, and the task's own @moduledoc already
    # documents `--types paper,task`. Only the projection was missing.
    test "the existing backfill materializes the edge for a pre-existing task, idempotently",
         %{scope: scope} do
      paper_slug = "gp-backfill-paper-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: paper_slug,
            body_html: ~s(<section id="gpb"><h1>Backfilled</h1></section>),
            event_type: "plan-written"
          })
        )

      # A task that cites the paper but was NEVER projected — the shape of all
      # 4320 rows already on the ledger.
      _task = publish_task!("t-backfill", scope, %{"wave_paper" => paper_slug})

      read = fn ->
        paper_slug
        |> Barkpark.Tasks.Expectations.driven_tasks(Keyword.put(scope, :dataset, @dataset))
        |> Map.fetch!(:tasks)
        |> Enum.filter(&(&1.doc_id == "t-backfill"))
      end

      {:ok, _} =
        Barkpark.EdgeProjector.Backfill.run(
          types: ["task"],
          dataset: @dataset,
          dry_run: false
        )

      after_first = read.()

      # `assert pattern = expr, message` can never print its message — the match
      # raises MatchError before assert/2 runs. Assert matchability first so the
      # diagnostic survives, THEN destructure.
      assert match?([_], after_first),
             "backfill did not connect the pre-existing task to its paper; got " <>
               inspect(after_first)

      [%{via: via}] = after_first
      assert "wave_paper" in via

      # Re-runnable: a second sweep converges to the same single entry.
      {:ok, _} =
        Barkpark.EdgeProjector.Backfill.run(
          types: ["task"],
          dataset: @dataset,
          dry_run: false
        )

      assert read.() == after_first,
             "a second backfill changed the result — the sweep is not idempotent"
    end
  end
end
