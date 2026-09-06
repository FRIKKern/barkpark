defmodule Barkpark.Tasks.DependencySourceAgreementTest do
  @moduledoc """
  THE READY QUEUE AND THE CLAIM DOOR MUST ANSWER THE SAME QUESTION
  (task-814b2d28bdb4b2f5).

  Barkpark records a task dependency in TWO stores — a `blocks` row in
  `task_edges`, and a doc_id list at `content.dependencies` — and three doors
  read them:

      Tasks.Queue.ready/1   the queue that HANDS WORK OUT
      Tasks.Claim           the door that LETS A WORKER TAKE IT
      Tasks.Close           the cascade that UNBLOCKS dependents on close

  Before this test existed the three disagreed in two independent ways, and
  each way has its own describe block below:

    * SILENT — `Tasks.Claim`/`Tasks.Close` read only the EDGES. A dependency
      written only into `content.dependencies` was withheld by the queue and
      invisible to the claim door: the row never surfaced in `bp task ready`,
      but `bp task claim <id>` took it anyway. Nothing anywhere said why.

    * LOUD — the queue's blocks-EDGE gate tested `lifecycle_status != 'done'`
      and nothing else, while the claim door applied the FULL
      `DependencySatisfaction` predicate (done AND attributable) to the same
      edges. A blocker that read `done` with no record of a close was satisfied
      for the queue and unsatisfied for the claim door, so the queue OFFERED a
      row the claim door then REFUSED with `blocked_by_unsatisfied_deps`.

  The last describe block is the property the two above are instances of: for
  the same fixture, `in ready?` and `claim succeeds?` must never differ. That
  is the guard that survives a future third store.

  MUTATION NOTE for whoever edits this: each describe block reddens ALONE
  against a DIFFERENT door, which is the point —
    * revert `Tasks.Claim.check_deps_satisfied/1` to `Edges.dependencies/2`
      → the SILENT block reds, the LOUD block stays green.
    * revert the queue's axis-1 edge gate to the bare `!= "done"` test
      → the LOUD block reds, the SILENT block stays green.
    * revert `Tasks.Close.all_blockers_done?/1` to `Edges.dependencies/2`
      → the cascade test reds, the other two stay green.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Blockers

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  # ─── SILENT: a dependency only the QUEUE could see ─────────────────────────

  describe "content.dependencies is visible to the CLAIM door" do
    test "a candidate held back by content.dependencies alone is refused, not waved through",
         %{scope: scope} do
      phase_id = uniq("phase-json-only")

      dep = mk_task!(uniq("json-dep"), scope, %{"parent_id" => phase_id})

      candidate =
        mk_task!(uniq("json-candidate"), scope, %{
          "parent_id" => phase_id,
          "dependencies" => [dep.doc_id]
        })

      # The two fixtures are DISTINCT rows — a twin pair here would make the
      # whole assertion vacuous.
      assert dep.id != candidate.id
      assert dep.doc_id != candidate.doc_id

      # There is NO edge; the dependency lives only in the JSON list.
      assert Tasks.dependencies(candidate.id, kind: :blocks) == []
      assert Blockers.declared_ids(candidate) == [dep.doc_id]

      refute candidate.id in ready_ids(scope, phase_id),
             "the queue withholds it — that half was never broken"

      assert {:error, :blocked_by_unsatisfied_deps} =
               Tasks.claim_by_id(candidate.doc_id, "worker-json", scope),
             "the claim door must see the SAME dependency the queue saw; reading only " <>
               "task_edges here hands out a row the queue is deliberately withholding"
    end

    test "satisfying the JSON dependency opens BOTH doors together", %{scope: scope} do
      phase_id = uniq("phase-json-flip")

      dep = mk_task!(uniq("json-flip-dep"), scope, %{"parent_id" => phase_id})

      candidate =
        mk_task!(uniq("json-flip-candidate"), scope, %{
          "parent_id" => phase_id,
          "dependencies" => [dep.doc_id]
        })

      assert dep.doc_id != candidate.doc_id

      _ = close_like!(dep)

      assert candidate.id in ready_ids(scope, phase_id)
      assert {:ok, claimed} = Tasks.claim_by_id(candidate.doc_id, "worker-json2", scope)
      assert claimed.content["lifecycle_status"] == "in_progress"
    end

    test "a DANGLING content.dependencies id fails closed at BOTH doors", %{scope: scope} do
      phase_id = uniq("phase-dangling")

      candidate =
        mk_task!(uniq("dangling-candidate"), scope, %{
          "parent_id" => phase_id,
          "dependencies" => ["task-no-such-row-#{System.unique_integer([:positive])}"]
        })

      refute candidate.id in ready_ids(scope, phase_id)

      assert {:error, :blocked_by_unsatisfied_deps} =
               Tasks.claim_by_id(candidate.doc_id, "worker-dangling", scope),
             "a dependency that resolves to nothing is UNSATISFIED, not absent"
    end
  end

  # ─── LOUD: a blocker the QUEUE thought was done ────────────────────────────

  describe "the queue's blocks-edge gate applies the FULL satisfaction predicate" do
    test "a done-but-unattributable edge blocker keeps the candidate out of ready",
         %{scope: scope} do
      phase_id = uniq("phase-forged")

      # A row that CLAIMS to be done and carries no evidence a close happened —
      # exactly what one forged `create` produces (cch-w3-task-birth-attribution).
      blocker = mk_task!(uniq("forged-blocker"), scope, %{"parent_id" => phase_id})
      blocker = forge_done!(blocker)

      candidate = mk_task!(uniq("forged-candidate"), scope, %{"parent_id" => phase_id})
      assert blocker.id != candidate.id

      {:ok, _} = Tasks.add_dep(candidate.id, blocker.id, :blocks)

      assert blocker.content["lifecycle_status"] == "done",
             "the fixture must actually read done, or the gate is untested"

      refute Barkpark.Tasks.DependencySatisfaction.satisfied?(blocker.content),
             "the fixture must be done-but-unattributable, or the two gates cannot differ"

      refute candidate.id in ready_ids(scope, phase_id),
             "the queue must NOT offer a row the claim door will refuse: its edge gate " <>
               "has to apply the same done-AND-attributable predicate Tasks.Claim does"

      assert {:error, :blocked_by_unsatisfied_deps} =
               Tasks.claim_by_id(candidate.doc_id, "worker-forged", scope)
    end

    test "giving that blocker close provenance opens BOTH doors together", %{scope: scope} do
      phase_id = uniq("phase-forged-flip")

      blocker = mk_task!(uniq("forged-flip-blocker"), scope, %{"parent_id" => phase_id})
      blocker = forge_done!(blocker)

      candidate = mk_task!(uniq("forged-flip-candidate"), scope, %{"parent_id" => phase_id})
      {:ok, _} = Tasks.add_dep(candidate.id, blocker.id, :blocks)

      refute candidate.id in ready_ids(scope, phase_id)

      _ = close_like!(blocker)

      assert candidate.id in ready_ids(scope, phase_id)
      assert {:ok, _} = Tasks.claim_by_id(candidate.doc_id, "worker-forged2", scope)
    end
  end

  # ─── The CLOSE cascade reads the same set ──────────────────────────────────

  describe "the close cascade reads content.dependencies too" do
    test "closing the edge blocker does NOT unblock a row still held by content.dependencies",
         %{scope: scope} do
      phase_id = uniq("phase-cascade")

      edge_blocker = mk_task!(uniq("cascade-edge-blocker"), scope, %{"parent_id" => phase_id})
      json_blocker = mk_task!(uniq("cascade-json-blocker"), scope, %{"parent_id" => phase_id})

      assert edge_blocker.doc_id != json_blocker.doc_id,
             "the two blockers must be different rows or the cascade proves nothing"

      candidate =
        mk_task!(uniq("cascade-candidate"), scope, %{
          "parent_id" => phase_id,
          "dependencies" => [json_blocker.doc_id]
        })

      candidate = set_lifecycle!(candidate, "blocked")
      {:ok, _} = Tasks.add_dep(candidate.id, edge_blocker.id, :blocks)

      {:ok, claimed} = Tasks.claim_by_id(edge_blocker.doc_id, "worker-cascade", scope)
      epoch = claimed.content["claim"]["epoch"]

      {:ok, _} =
        Tasks.close(edge_blocker.doc_id, "worker-cascade", epoch,
          lifecycle_status: "done",
          reason: "fixture: the edge blocker is finished",
          scope: scope
        )

      still = Repo.get!(Content.Document, candidate.id)

      assert still.content["lifecycle_status"] == "blocked",
             "the cascade must not flip a row to open while content.dependencies still " <>
               "holds it — the queue would keep withholding it and nothing would say why"

      refute candidate.id in ready_ids(scope, phase_id)
    end
  end

  # ─── The property the two blocks above are instances of ────────────────────

  describe "ready/1 and the claim door never disagree" do
    test "over every one-blocker fixture shape, `in ready` == `claim succeeds`",
         %{scope: scope} do
      shapes = [
        {"edge → open blocker", :edge, :open},
        {"edge → forged-done blocker", :edge, :forged},
        {"edge → properly closed blocker", :edge, :closed},
        {"json → open blocker", :json, :open},
        {"json → forged-done blocker", :json, :forged},
        {"json → properly closed blocker", :json, :closed}
      ]

      disagreements =
        for {name, store, blocker_state} <- shapes do
          phase_id = uniq("phase-prop")
          blocker = mk_task!(uniq("prop-blocker"), scope, %{"parent_id" => phase_id})

          blocker =
            case blocker_state do
              :open -> blocker
              :forged -> forge_done!(blocker)
              :closed -> close_like!(blocker)
            end

          extra =
            case store do
              :edge -> %{"parent_id" => phase_id}
              :json -> %{"parent_id" => phase_id, "dependencies" => [blocker.doc_id]}
            end

          candidate = mk_task!(uniq("prop-candidate"), scope, extra)
          if store == :edge, do: {:ok, _} = Tasks.add_dep(candidate.id, blocker.id, :blocks)

          in_ready? = candidate.id in ready_ids(scope, phase_id)

          claimable? =
            match?({:ok, _}, Tasks.claim_by_id(candidate.doc_id, "worker-prop", scope))

          {name, in_ready?, claimable?}
        end
        |> Enum.reject(fn {_n, r, c} -> r == c end)

      assert disagreements == [],
             "the queue and the claim door answered differently for: " <>
               Enum.map_join(disagreements, "; ", fn {n, r, c} ->
                 "#{n} — ready=#{r} claimable=#{c}"
               end)
    end
  end

  # ─── fixtures ──────────────────────────────────────────────────────────────

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

  defp set_lifecycle!(doc, new_status) do
    doc
    |> Ecto.Changeset.change(content: Map.put(doc.content, "lifecycle_status", new_status))
    |> Repo.update!()
  end

  # A row that READS done with NO record that a close happened — the forgeable
  # half of the predicate, on its own.
  defp forge_done!(doc), do: set_lifecycle!(doc, "done")

  # A row that reads done AND carries what a close writes.
  defp close_like!(doc) do
    content =
      doc.content
      |> Map.put("lifecycle_status", "done")
      |> Map.put("close_reason", "fixture: closed through the verb")

    doc
    |> Ecto.Changeset.change(content: content)
    |> Repo.update!()
  end

  defp ready_ids(scope, phase_id) do
    scope
    |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
    |> Tasks.ready()
    |> Enum.map(& &1.id)
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
