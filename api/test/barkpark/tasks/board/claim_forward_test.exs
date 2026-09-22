defmodule Barkpark.Tasks.Board.ClaimForwardTest do
  @moduledoc """
  The GUI half of claim-forward (task-adaae4196cffa86f).

  `Barkpark.Tasks.Board.ClaimForward.violations/2` is the LiveView board's twin
  of the TUI's `ClaimForwardViolations` — C0 ready work implies a surfaced move,
  C1 every surfaced row is real, C2 nothing ready implies an honest empty state.

  BOTH ARMS, as the row requires:

    * the INJECTED-BREACH arm — an emptied ready column over ready work, a
      surfaced row absent from the overlay, a surfaced row that is already an
      in-flight claim, and a ready column over an empty overlay: each reds,
      naming its clause;
    * the QUIET arm — an honest board, and the genuinely-nothing-ready board,
      both report `[]`.

  And the TWO-ROUTE cross-check, which is the axis a fixture cannot reach:
  readiness is derived TWICE — by `Tasks.Queue.ready/1` (SQL, what
  `/v1/tasks/prime`'s ready head serves) and by `Board.build/2`'s in-memory
  overlay (what the GUI column renders). The last two tests run BOTH routes over
  the SAME corpus and hand the predicate the server route's answer.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Board
  alias Barkpark.Tasks.Board.ClaimForward
  alias Barkpark.Tasks.Edge
  alias Barkpark.Tasks.Queue
  alias Barkpark.TenancyFixtures

  @dataset "production"

  # ── the pure arms: a hand-built board projection + a hand-built overlay ─────

  describe "violations/2 — the injected-breach arm" do
    test "C0: ready work in the overlay, an emptied ready column" do
      board = board_with_ready([])
      overlay = %{ready_ids: ["r1", "r2"], in_progress_ids: []}

      assert [%{clause: clause, detail: detail}] = ClaimForward.violations(board, overlay)
      assert clause == :c0_no_move_surfaced_over_ready_overlay
      assert detail =~ "2 claimable row(s)"
    end

    test "C1: a surfaced row the overlay does not mark ready" do
      board = board_with_ready(["r1", "ghost"])
      overlay = %{ready_ids: ["r1"], in_progress_ids: []}

      assert [%{clause: clause, doc_id: "ghost"}] = ClaimForward.violations(board, overlay)
      assert clause == :c1_surfaced_row_absent_from_overlay
    end

    test "C1: a surfaced row that is already somebody's in-flight claim" do
      board = board_with_ready(["r1", "held"])
      overlay = %{ready_ids: ["r1", "held"], in_progress_ids: ["held"]}

      assert [%{clause: clause, doc_id: "held"}] = ClaimForward.violations(board, overlay)
      assert clause == :c1_surfaced_row_is_already_an_in_flight_claim
    end

    test "C2: a ready column over an overlay that holds nothing claimable" do
      board = board_with_ready(["r1"])
      overlay = %{ready_ids: [], in_progress_ids: ["w1"]}

      clauses = board |> ClaimForward.violations(overlay) |> Enum.map(& &1.clause)
      assert :c2_ready_surfaced_over_empty_overlay in clauses
    end
  end

  describe "violations/2 — the quiet arm" do
    test "an honest board reports nothing" do
      board = board_with_ready(["r1", "r2"])
      overlay = %{ready_ids: ["r1", "r2", "r3"], in_progress_ids: ["w1"]}

      assert ClaimForward.violations(board, overlay) == []
    end

    test "the genuinely-nothing-ready board is honest, not a breach" do
      board = board_with_ready([])
      overlay = %{ready_ids: [], in_progress_ids: ["w1"]}

      assert ClaimForward.violations(board, overlay) == []
    end

    test "an absent :in_progress_ids key is tolerated" do
      board = board_with_ready(["r1"])
      assert ClaimForward.violations(board, %{ready_ids: ["r1"]}) == []
    end
  end

  # ── the two-route cross-check: Queue.ready/1 vs Board.build/2 ───────────────

  describe "the derived-ready overlay vs the rendered ready column" do
    setup do
      # The board projects the WHOLE `type:task` corpus of the dataset, so a
      # stray row from another agent's committed fixture poisons every count.
      # This delete runs inside the sandbox transaction and rolls back.
      Repo.delete_all(from(d in Document, where: d.type == "task"))

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

      %{scope: scope}
    end

    test "an edge-blocked corpus: both routes agree, the predicate is quiet", %{scope: scope} do
      blocker =
        mk_task!("cf-blocker", "Wire the mirror job for the nightly bake", scope, %{
          "lifecycle_status" => "in_progress"
        })

      dependent =
        mk_task!("cf-dependent", "Translate the Bokbasen codelist appendix", scope, %{
          "lifecycle_status" => "open"
        })

      _free =
        mk_task!("cf-free", "Retune the media thumbnail cache headers", scope, %{
          "lifecycle_status" => "open"
        })

      # `blocks`: from = the dependent, to = the blocker. This is the ONE
      # dependency store both routes read.
      Repo.insert!(%Edge{from_id: dependent.id, to_id: blocker.id, kind: "blocks"})

      board = Board.snapshot(dataset: @dataset)
      overlay = overlay_from_queue(scope)

      assert MapSet.member?(overlay.ready_ids, "cf-free")
      refute MapSet.member?(overlay.ready_ids, "cf-dependent")
      assert ClaimForward.surfaced_ready_ids(board) == ["cf-free"]
      assert ClaimForward.violations(board, overlay) == []
    end

    test "a content.dependencies-blocked row: the board surfaces what the overlay refuses",
         %{scope: scope} do
      # `Tasks.Queue` gates readiness on TWO stores — the `task_edges` graph AND
      # the `content.dependencies` doc_id list. `Board.snapshot/1` reads only the
      # first (`load_blocker_targets/1`). A row blocked ONLY by the second is
      # therefore ready to the board and not ready to the queue — the exact
      # "different route" divergence no fixture-only assertion can see, and the
      # predicate names it.
      _blocker =
        mk_task!("cf-dep-blocker", "Provision the staging TLS certificate", scope, %{
          "lifecycle_status" => "open"
        })

      _dependent =
        mk_task!("cf-dep-dependent", "Rewrite the onboarding welcome email copy", scope, %{
          "lifecycle_status" => "open",
          "dependencies" => ["cf-dep-blocker"]
        })

      board = Board.snapshot(dataset: @dataset)
      overlay = overlay_from_queue(scope)

      refute MapSet.member?(overlay.ready_ids, "cf-dep-dependent")
      assert "cf-dep-dependent" in ClaimForward.surfaced_ready_ids(board)

      assert Enum.any?(
               ClaimForward.violations(board, overlay),
               &(&1.clause == :c1_surfaced_row_absent_from_overlay and
                   &1.doc_id == "cf-dep-dependent")
             )
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp board_with_ready(ids) do
    %{columns: %{ready: Enum.map(ids, &%{doc_id: &1, title: &1})}}
  end

  defp overlay_from_queue(scope) do
    ready =
      [dataset: @dataset, limit: 200]
      |> Keyword.merge(scope)
      |> Queue.ready()
      |> Enum.map(& &1.doc_id)

    in_progress =
      Repo.all(
        from(d in Document,
          where: d.type == "task",
          where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
          select: d.doc_id
        )
      )

    %{ready_ids: MapSet.new(ready), in_progress_ids: MapSet.new(in_progress)}
  end

  defp mk_task!(doc_id, title, scope, content_extra) do
    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(content_extra)
      # The Tasks plugin's :before_publish brief wall (inert until #19303).
      |> Barkpark.TaskBriefFixtures.with_brief()

    {:ok, _draft} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => title, "content" => content},
        @dataset,
        scope
      )

    # `create_document` always writes the `drafts.<id>` shadow. PUBLISH it, so
    # the corpus both routes read is the published shape prod carries — and so
    # the two routes' ids are comparable without a prefix strip.
    {:ok, published} = Content.publish_document(doc_id, "task", @dataset, scope)
    published
  end
end
