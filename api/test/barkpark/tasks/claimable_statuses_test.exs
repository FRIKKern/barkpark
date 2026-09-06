defmodule Barkpark.Tasks.ClaimableStatusesTest do
  @moduledoc """
  Protective tests for the single-sourced claimability allowlist —
  `Barkpark.Tasks.Validation.claimable_statuses/0` (folds spd-b24: `blocked`
  is claim-equivalent to `open`; blocking is advisory, the readiness gates
  are what hold work back).

  Three derived copies ride the one source, and each has a test here that
  FAILS if that copy forks (mutation-provable):

    1. The pin — `claimable_statuses/0 == ~w(open blocked)` and the thought
       states (considering/researching) stay excluded ("OPEN MEANS READY"
       is held by construction).
    2. `Tasks.Queue` Ecto `in` + `Tasks.Claim` targeted-claim guard — a
       `blocked` task with no unsatisfied gate is ready AND claimable;
       dropping `blocked` from either derived copy reds these.
    3. `Tasks.Queue`'s raw-SQL unsatisfied-deps CTE (`= ANY(?)` bind) — an
       open OR blocked task with an unsatisfied blocks-edge or
       `content.dependencies` entry is NOT ready; narrowing the CTE's list
       (e.g. back to a hand-typed `IN ('open')`) leaks a blocked candidate
       past the dependency gate and reds the blocked variant.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Validation

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_schemas!(scope)

    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # The create validator only admits valid lifecycle values; flips to other
  # states go through a raw update (same helper shape as tasks_ready_test.exs).
  defp set_lifecycle!(doc, new_status) do
    # cch-w3-task-birth-attribution: a done row satisfies a dependent only if it
    # ALSO carries close provenance, because `lifecycle_status` alone is
    # forgeable by a fresh create. A fixture that flips to "done" is simulating
    # a CLOSE, so it writes what a close writes.
    new_content =
      doc.content
      |> Map.put("lifecycle_status", new_status)
      |> then(fn c ->
        if new_status == "done" and c["close_reason"] in [nil, ""],
          do: Map.put(c, "close_reason", "fixture: closed through the verb"),
          else: c
      end)

    doc
    |> Ecto.Changeset.change(content: new_content)
    |> Repo.update!()
  end

  defp ids_of(docs), do: Enum.map(docs, & &1.id)

  defp ready_ids(scope, phase_id) do
    scope
    |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
    |> Tasks.ready()
    |> ids_of()
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ─── (1) The pin ───────────────────────────────────────────────────────────

  describe "claimable_statuses/0 — the pin" do
    test "is exactly [\"open\", \"blocked\"]" do
      assert Validation.claimable_statuses() == ["open", "blocked"]
    end

    test "is a strict subset of lifecycle_statuses/0; the thought states are excluded" do
      claimable = Validation.claimable_statuses()
      lifecycle = Validation.lifecycle_statuses()

      assert Enum.all?(claimable, &(&1 in lifecycle)),
             "every claimable status must be a valid lifecycle status"

      for thought <- ~w(considering researching) do
        assert thought in lifecycle

        refute thought in claimable,
               "#{thought} must stay out of the claimability allowlist (OPEN MEANS READY)"
      end
    end
  end

  # ─── (2) blocked is claim-equivalent to open ──────────────────────────────

  describe "blocked with no unsatisfied gate is ready + claimable" do
    test "a blocked task with no edges/deps appears in ready/1 and claim_by_id succeeds",
         %{scope: scope} do
      phase_id = uniq("phase-blocked-ready")
      task = mk_task!(uniq("blocked-ready"), scope, %{"parent_id" => phase_id})
      task = set_lifecycle!(task, "blocked")

      assert task.id in ready_ids(scope, phase_id),
             "blocked with no unsatisfied gate must be READY (claim-equivalent to open)"

      assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "worker-blocked", scope)
      assert claimed.content["lifecycle_status"] == "in_progress"
      assert claimed.content["claim"]["worker"] == "worker-blocked"
    end
  end

  # ─── (3) unsatisfied gates exclude BOTH open and blocked ──────────────────

  describe "unsatisfied blocks-edge excludes the candidate" do
    for candidate_status <- ~w(open blocked) do
      test "a #{candidate_status} task with an unsatisfied blocks-edge is NOT ready, NOT claimable",
           %{scope: scope} do
        candidate_status = unquote(candidate_status)
        phase_id = uniq("phase-edge-#{candidate_status}")

        blocker = mk_task!(uniq("edge-blocker"), scope, %{"parent_id" => phase_id})
        candidate = mk_task!(uniq("edge-candidate"), scope, %{"parent_id" => phase_id})

        if candidate_status != "open" do
          _ = set_lifecycle!(candidate, candidate_status)
        end

        {:ok, _} = Tasks.add_dep(candidate.id, blocker.id, :blocks)

        refute candidate.id in ready_ids(scope, phase_id),
               "#{candidate_status} candidate with a non-done blocker must NOT be ready"

        assert {:error, :blocked_by_unsatisfied_deps} =
                 Tasks.claim_by_id(candidate.doc_id, "worker-edge", scope)
      end
    end
  end

  describe "unsatisfied content.dependencies excludes the candidate (raw-SQL CTE copy)" do
    for candidate_status <- ~w(open blocked) do
      test "a #{candidate_status} task depending on a non-done task is NOT ready",
           %{scope: scope} do
        candidate_status = unquote(candidate_status)
        phase_id = uniq("phase-dep-#{candidate_status}")

        dep = mk_task!(uniq("dep-open"), scope, %{"parent_id" => phase_id})

        candidate =
          mk_task!(uniq("dep-candidate"), scope, %{
            "parent_id" => phase_id,
            "dependencies" => [dep.doc_id]
          })

        if candidate_status != "open" do
          _ = set_lifecycle!(candidate, candidate_status)
        end

        ready = ready_ids(scope, phase_id)

        assert dep.id in ready, "the dep itself is open with no gates — ready"

        refute candidate.id in ready,
               "#{candidate_status} candidate with an unsatisfied content.dependencies " <>
                 "entry must NOT be ready (fail closed); a fork of the raw-SQL " <>
                 "lifecycle list in Queue's unsatisfied-deps CTE leaks it here"
      end
    end

    test "satisfying the dependency (done) makes the blocked candidate ready again",
         %{scope: scope} do
      phase_id = uniq("phase-dep-flip")

      dep = mk_task!(uniq("dep-flip"), scope, %{"parent_id" => phase_id})

      candidate =
        mk_task!(uniq("dep-flip-candidate"), scope, %{
          "parent_id" => phase_id,
          "dependencies" => [dep.doc_id]
        })

      candidate = set_lifecycle!(candidate, "blocked")

      refute candidate.id in ready_ids(scope, phase_id)

      _ = set_lifecycle!(dep, "done")

      assert candidate.id in ready_ids(scope, phase_id),
             "done dep satisfies the gate — the blocked candidate is ready again"
    end
  end
end
