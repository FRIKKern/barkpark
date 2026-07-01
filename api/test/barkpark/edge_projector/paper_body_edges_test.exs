defmodule Barkpark.EdgeProjector.PaperBodyEdgesTest do
  @moduledoc """
  Wire §7 (`portabledoc-inline-liveref-taskchip-wire`) — the body-walk edge
  extractor, the paper-writer reprojection wiring, and the one-shot backfill.

  Four surfaces, each asserted against REAL output (never a vacuous no-crash):

    1. PURE extractor — `Bulldocs.extract_edges/2` walks stored paper content
       via the ONE shared `BodyWalk` walker and emits `valueref`-kind edges for
       inline valueref nodes (kind spelled IDENTICALLY to the node type) and
       `references`-kind edges for wikilinks (docId-preferred), alongside the
       pre-existing ref/href signals. Dedup + self-edge rejection included.
    2. NET-NEW wiring — ALL THREE paper writers (`upsert_paper`,
       `apply_paper_block_op`, `apply_paper_block_ops`) enqueue a debounced
       `ProjectorWorker` rebuild; they bypass `fire_after` so without this no
       paper edit would ever reproject.
    3. The reprojection LOOP — a block-op edit's REAL enqueued job, performed,
       materialises the edge as a `content_edges` row (paper PK → task PK,
       kind `references`) through `Projector.rebuild_scope` → `Content.add_edges`.
    4. BACKFILL — `EdgeProjector.Backfill.run/1` sweeps a pre-existing
       valueref-bearing paper (seeded by a DIRECT content write, exactly the
       corpus state that predates the extractor: the renderer's valueref
       degradation clause is lvw-t1, so such a paper cannot be re-authored yet)
       into real `valueref` + `references` edge rows; dry-run writes nothing;
       a second apply run converges.

  Runs against the test DB (Postgres on :5432).
  """

  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Content, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Content.Edge
  alias Barkpark.EdgeProjector.{Backfill, ProjectorWorker}
  alias Barkpark.Plugins.Bulldocs
  alias Barkpark.Plugins.Registry

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # A minimal task schema so a wikilinked task target exists as a real doc,
    # and a canonical-source type for valueref targets.
    for name <- ["task", "kpi"] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )
    end

    prev_plugins = Application.get_env(:barkpark, :plugins)
    Application.delete_env(:barkpark, :plugins)

    # Register the REAL Bulldocs plugin so the collector drives its
    # resolve_extract_edges/2 (not a fake) — the seam under test.
    :ok = Registry.register(Bulldocs, %{"plugin_name" => "bulldocs"})

    on_exit(fn ->
      Registry.reset()

      case prev_plugins do
        nil -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end
    end)

    %{scope: scope, ws: ws}
  end

  defp publish!(type, doc_id, scope) do
    # Task docs carry the core-validated task content shape.
    content =
      if type == "task", do: %{"kind" => "task", "lifecycle_status" => "open"}, else: %{}

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, type, @dataset, scope)
    doc
  end

  defp valueref_node(target) do
    %{
      "type" => "valueref",
      "target" => target,
      "field" => "launch_delay",
      "as" => "duration",
      "fallback" => "12 weeks",
      "label" => "launch delay",
      "children" => [%{"type" => "text", "value" => "12 weeks"}]
    }
  end

  defp task_wikilink_node(task_doc_id) do
    %{
      "type" => "wikilink",
      "target" => task_doc_id,
      "docId" => task_doc_id,
      "alias" => "the resolver task",
      "children" => []
    }
  end

  # Seed a paper through the canonical write path with RENDER-SAFE blocks, then
  # inject valueref/wikilink nodes into the STORED blocks via a direct content
  # write — the renderer's valueref degradation clause is lvw-t1 (not landed),
  # so a valueref cannot flow through upsert_paper's body_html render yet. This
  # is byte-for-byte the pre-existing-corpus state §7.6's backfill exists for.
  defp seed_paper_with_stored_nodes!(slug, inline_nodes) do
    {:ok, _} =
      Content.upsert_paper(%{
        slug: slug,
        dataset: @dataset,
        blocks: [%{"id" => "b-intro", "type" => "paragraph", "text" => "intro"}]
      })

    doc = Content.get_paper(slug, @dataset)

    injected =
      doc.content["blocks"] ++
        [%{"id" => "b-live", "type" => "paragraph", "content" => inline_nodes}]

    doc
    |> Document.changeset(%{"content" => Map.put(doc.content, "blocks", injected)})
    |> Repo.update!()

    Content.get_paper(slug, @dataset)
  end

  defp edge_pairs(from_pk) do
    Edge
    |> where([e], e.from_id == ^from_pk)
    |> Repo.all()
    |> Enum.map(&{&1.to_id, &1.kind})
    |> MapSet.new()
  end

  # ── 1. The pure extractor ──────────────────────────────────────────────────

  describe "Bulldocs.extract_edges/2 — body-walk (pure, no DB)" do
    test "valueref → valueref-kind edge; wikilink → references (docId preferred); ref/href kept" do
      doc = %{
        "doc_id" => "drafts.paper-x",
        "content" => %{
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [
                %{"type" => "text", "value" => "Launch delay is "},
                valueref_node("kpi-1"),
                %{"type" => "text", "value" => " — tracked by "},
                task_wikilink_node("t-chip")
              ]
            },
            %{"id" => "b2", "type" => "sheet", "ref" => "sheet-1"},
            %{
              "id" => "b3",
              "type" => "paragraph",
              "content" => [
                %{"type" => "link", "href" => "/papers/other-paper#sec", "children" => []},
                %{"type" => "link", "href" => "https://example.com/x", "children" => []},
                %{"type" => "wikilink", "target" => "A Human Title", "children" => []}
              ]
            }
          ]
        }
      }

      edges = Bulldocs.extract_edges(doc, %{})

      assert Enum.all?(edges, &(&1.from_id == "paper-x")),
             "drafts. prefix must coalesce to the published id"

      assert Enum.all?(edges, &(&1.plugin_source == "bulldocs"))

      pairs = edges |> Enum.map(&{&1.to_id, &1.kind}) |> MapSet.new()

      assert pairs ==
               MapSet.new([
                 # the §7 table rows
                 {"kpi-1", "valueref"},
                 {"t-chip", "references"},
                 # a docId-less wikilink falls back to its raw target — the
                 # WRITE path (add_edges) drops it when nothing resolves
                 {"A Human Title", "references"},
                 # the pre-existing ref/href signals, unchanged
                 {"sheet-1", "references"},
                 {"other-paper", "references"}
               ])

      # kind is spelled IDENTICALLY to the node type — never "value-ref"
      refute Enum.any?(edges, &(&1.kind == "value-ref"))
    end

    test "dedup + self-edge rejection" do
      doc = %{
        "doc_id" => "paper-self",
        "content" => %{
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [
                valueref_node("kpi-1"),
                valueref_node("kpi-1"),
                # a valueref pointing at the host paper itself is dropped
                valueref_node("paper-self")
              ]
            }
          ]
        }
      }

      edges = Bulldocs.extract_edges(doc, %{})

      assert edges |> Enum.map(&{&1.to_id, &1.kind}) |> Enum.sort() ==
               [{"kpi-1", "valueref"}]
    end
  end

  # ── 2. The three writers enqueue reprojection ─────────────────────────────

  describe "paper writers fire EdgeProjector.Lifecycle.enqueue_rebuild (§7.5)" do
    test "upsert_paper enqueues a debounced rebuild" do
      slug = "wire-upsert-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: @dataset,
          blocks: [%{"id" => "b1", "type" => "paragraph", "text" => "hello"}]
        })

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "rebuild", "scope" => @dataset, "types" => ["paper"]}
      )
    end

    test "apply_paper_block_op enqueues a debounced rebuild", %{scope: scope} do
      slug = "wire-op-#{System.unique_integer([:positive])}"
      task = publish!("task", "t-op-target", scope)

      # The task publish above already enqueued a types-["task"] rebuild for
      # this scope. The worker's uniqueness key INCLUDES :types
      # (lvw-t11-followup-dedup), so the paper writer's types-["paper"]
      # enqueue below must survive alongside it — no queue-clearing
      # workaround. This doubles as the regression guard for the mixed-type
      # dedup drop #714 surfaced.
      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: @dataset,
          blocks: [%{"id" => "b1", "type" => "paragraph", "text" => "hello"}]
        })

      op = %{
        "op" => "append-block",
        "block" => %{
          "id" => "b-link",
          "type" => "paragraph",
          "content" => [task_wikilink_node(task.doc_id)]
        }
      }

      {:ok, _} = Content.apply_paper_block_op(slug, op, @dataset)

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "rebuild", "scope" => @dataset, "types" => ["paper"]}
      )
    end

    test "apply_paper_block_ops (batch) enqueues a debounced rebuild" do
      slug = "wire-batch-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: @dataset,
          blocks: [%{"id" => "b1", "type" => "paragraph", "text" => "hello"}]
        })

      ops = [
        %{
          "op" => "append-block",
          "block" => %{"id" => "b2", "type" => "paragraph", "text" => "more"}
        }
      ]

      {:ok, %{op_count: 1}} = Content.apply_paper_block_ops(slug, ops, @dataset)

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "rebuild", "scope" => @dataset, "types" => ["paper"]}
      )
    end
  end

  # ── 3. The full loop: block-op edit → performed job → stored edge ─────────

  describe "block-op edit reprojects a real content_edges row" do
    test "wikilink-to-task appended by a block op lands as a references edge", %{scope: scope} do
      slug = "wire-loop-#{System.unique_integer([:positive])}"
      task = publish!("task", "t-loop-target", scope)

      # MIXED-TYPE REPRO (lvw-t11-followup-dedup): the task publish above has
      # already enqueued a types-["task"] rebuild for this scope, and the
      # paper writers below enqueue types-["paper"] INSIDE the same 30s
      # uniqueness window. Both jobs must coexist — before :types joined the
      # unique key, Oban returned the existing ["task"] job and the paper
      # rebuild was silently dropped, so the edge below never materialised.
      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: @dataset,
          blocks: [%{"id" => "b1", "type" => "paragraph", "text" => "hello"}]
        })

      op = %{
        "op" => "append-block",
        "block" => %{
          "id" => "b-link",
          "type" => "paragraph",
          "content" => [task_wikilink_node(task.doc_id)]
        }
      }

      {:ok, _} = Content.apply_paper_block_op(slug, op, @dataset)

      # Perform EVERY real enqueued job (config/test.exs runs Oban :manual):
      # one types-["task"] rebuild from the publish, one types-["paper"]
      # rebuild the upsert + op enqueues dedup'd into. Both types' rebuilds
      # must be present and both must run clean.
      jobs = all_enqueued(worker: ProjectorWorker)
      type_sets = jobs |> Enum.map(& &1.args["types"]) |> Enum.sort()
      assert [["paper"], ["task"]] = type_sets

      for job <- jobs do
        assert :ok = perform_job(ProjectorWorker, job.args)
      end

      paper_pk = Content.get_paper(slug, @dataset).id

      assert {task.id, "references"} in edge_pairs(paper_pk),
             "the performed rebuild must store paper→task references edge"
    end
  end

  # ── 4. The one-shot backfill (§7.6) ────────────────────────────────────────

  describe "EdgeProjector.Backfill" do
    test "dry run projects counts and writes NOTHING", %{scope: scope} do
      task = publish!("task", "t-dry-target", scope)
      _kpi = publish!("kpi", "kpi-dry", scope)
      slug = "backfill-dry-#{System.unique_integer([:positive])}"

      paper =
        seed_paper_with_stored_nodes!(slug, [
          valueref_node("kpi-dry"),
          task_wikilink_node(task.doc_id)
        ])

      {:ok, stats} = Backfill.run(dry_run: true, dataset: @dataset)

      assert stats.dry_run
      assert stats.scopes >= 1
      assert Enum.any?(stats.results, &(&1.edges >= 2)), "must project the seeded edges"
      assert edge_pairs(paper.id) == MapSet.new(), "dry run must not write edges"
    end

    test "apply materialises valueref + references edges for a PRE-EXISTING paper",
         %{scope: scope} do
      task = publish!("task", "t-bf-target", scope)
      kpi = publish!("kpi", "kpi-bf", scope)
      slug = "backfill-apply-#{System.unique_integer([:positive])}"

      paper =
        seed_paper_with_stored_nodes!(slug, [
          valueref_node("kpi-bf"),
          task_wikilink_node(task.doc_id)
        ])

      {:ok, stats} = Backfill.run(dry_run: false, dataset: @dataset)

      refute stats.dry_run
      assert stats.rebuilt >= 1
      assert stats.errored == 0

      pairs = edge_pairs(paper.id)
      assert {kpi.id, "valueref"} in pairs, "valueref edge must resolve paper→canonical doc"
      assert {task.id, "references"} in pairs, "task wikilink must resolve paper→task"

      # Idempotent: a second apply converges to the same rows.
      {:ok, _} = Backfill.run(dry_run: false, dataset: @dataset)
      assert edge_pairs(paper.id) == pairs
    end
  end
end
