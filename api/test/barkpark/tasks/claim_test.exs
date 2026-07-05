defmodule Barkpark.Tasks.ClaimTest do
  @moduledoc """
  DB-backed tests for `Barkpark.Tasks.Claim` (via the `Barkpark.Tasks` facade
  which defdelegates `claim/2` and `claim_by_id/3` here).

  Covers:
    1. claim/2 — happy path: atomically claims the next ready task.
    2. claim/2 — returns {:ok, nil} when the queue is empty.
    3. claim_by_id/3 — happy path: claims a task by doc_id.
    4. claim_by_id/3 — drafts. fallback: claim by bare id when the row lives as drafts.<id>.
    5. claim_by_id/3 — :not_ready when the target is already in_progress.
    6. claim_by_id/3 — resource conflict: refuses when the requested resource is held.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

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
        %{"kind" => "task", "lifecycle_status" => "open"},
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ─── (1) claim/2 happy path ────────────────────────────────────────────────

  describe "claim/2 — happy path" do
    test "claims the next ready task, sets in_progress + worker + epoch=1", %{scope: scope} do
      phase_id = uniq("phase-claim")
      task = mk_task!(uniq("claim-happy"), scope, %{"parent_id" => phase_id})

      assert {:ok, claimed} =
               Tasks.claim("worker-1", scope ++ [phase_id: phase_id, dataset: @dataset])

      assert claimed.id == task.id
      assert claimed.content["lifecycle_status"] == "in_progress"
      assert claimed.content["assignee"] == "worker-1"
      assert claimed.content["claim"]["worker"] == "worker-1"
      assert claimed.content["claim"]["epoch"] == 1
      assert is_binary(claimed.content["claim"]["ts_iso"])

      # Verify the DB row was actually updated.
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "in_progress"
      assert reloaded.content["claim"]["epoch"] == 1
    end
  end

  # ─── (2) claim/2 — empty queue ─────────────────────────────────────────────

  describe "claim/2 — empty queue" do
    test "returns {:ok, nil} when no ready tasks exist for the given phase", %{scope: scope} do
      phase_id = uniq("phase-empty")
      # Create a task but in a DIFFERENT phase so the claim query finds nothing.
      _other = mk_task!(uniq("other"), scope, %{"parent_id" => "different-phase"})

      assert {:ok, nil} =
               Tasks.claim("worker-nobody", scope ++ [phase_id: phase_id, dataset: @dataset])
    end
  end

  # ─── (3) claim_by_id/3 — happy path ────────────────────────────────────────

  describe "claim_by_id/3 — happy path" do
    test "claims the named task, sets in_progress + worker, epoch=1", %{scope: scope} do
      doc_id = uniq("byid-happy")
      task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-2", scope)

      assert claimed.id == task.id
      assert claimed.content["lifecycle_status"] == "in_progress"
      assert claimed.content["assignee"] == "worker-2"
      assert claimed.content["claim"]["worker"] == "worker-2"
      assert claimed.content["claim"]["epoch"] == 1
    end
  end

  # ─── (4) claim_by_id/3 — drafts. fallback ──────────────────────────────────

  describe "claim_by_id/3 — drafts. fallback" do
    test "bare doc_id falls back to drafts.<id> when the exact row is absent", %{scope: scope} do
      bare_id = uniq("bare")
      drafts_id = "drafts." <> bare_id

      # Insert the row with the `drafts.` prefix (the shape mutate-created tasks produce).
      task = mk_task!(drafts_id, scope)

      # Claim with the bare id — must resolve to the drafts. row.
      assert {:ok, claimed} = Tasks.claim_by_id(bare_id, "worker-fb", scope)
      assert claimed.id == task.id
      assert claimed.content["lifecycle_status"] == "in_progress"
    end

    test "returns {:error, :not_found} when neither exact nor drafts. row exists", %{scope: scope} do
      nonexistent = uniq("does-not-exist")

      assert {:error, :not_found} = Tasks.claim_by_id(nonexistent, "worker-miss", scope)
    end
  end

  # ─── (5) claim_by_id/3 — :not_ready ────────────────────────────────────────

  describe "claim_by_id/3 — not_ready" do
    test "returns {:error, :not_ready} when the task is already in_progress", %{scope: scope} do
      doc_id = uniq("in-prog")
      task = mk_task!(doc_id, scope)

      # First claim — should succeed.
      assert {:ok, _} = Tasks.claim_by_id(doc_id, "worker-first", scope)

      # Second targeted claim on the same task — must be rejected as not_ready.
      assert {:error, :not_ready} = Tasks.claim_by_id(task.doc_id, "worker-second", scope)
    end
  end

  # ─── (6) claim_by_id/3 — resource conflict ─────────────────────────────────

  describe "claim_by_id/3 — resource conflict" do
    test "refuses claim when the requested resource is already held by another in_progress task",
         %{scope: scope} do
      holder_id = uniq("holder")
      contender_id = uniq("contender")

      mk_task!(holder_id, scope)
      mk_task!(contender_id, scope)

      # Holder claims lib/shared.ex.
      assert {:ok, _} =
               Tasks.claim_by_id(
                 holder_id,
                 "worker-holder",
                 scope ++ [resources: ["lib/shared.ex"]]
               )

      # Contender tries to claim the same resource — must be refused.
      assert {:error, {:resource_conflict, conflicts}} =
               Tasks.claim_by_id(
                 contender_id,
                 "worker-contender",
                 scope ++ [resources: ["lib/shared.ex"]]
               )

      assert [conflict] = conflicts
      assert conflict.worker == "worker-holder"
      assert "lib/shared.ex" in conflict.resources
    end
  end

  # ─── (7) claim_by_id/3 — nil workspace scope FAILS CLOSED ───────────────────
  # The tasks resource unifies its workspace scoping through the ONE shared
  # `Content.Scope.scope_to_workspace/3` helper (matching the ready-queue path),
  # so a nil `workspace_id` yields ZERO rows — never every tenant's rows. This
  # protects internal / worker / test callers that drop their scope: they can no
  # longer reach a task in ANOTHER tenant. HTTP callers are unaffected (they
  # always carry the Default workspace).

  describe "claim_by_id/3 — nil workspace fails CLOSED (scope unification)" do
    test "a nil workspace_id can NOT reach a real, scoped task (not_found, not a leak)",
         %{scope: scope} do
      doc_id = uniq("nil-scope-target")
      _task = mk_task!(doc_id, scope)

      # The row exists and is claimable WITH the real scope — but a nil-workspace
      # claim must fail closed rather than resolving over every tenant's rows.
      assert {:error, :not_found} =
               Tasks.claim_by_id(doc_id, "worker-nil", workspace_id: nil, project_id: nil)

      # And the scoped claim still works (byte-identical behaviour for real scope).
      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-ok", scope)
      assert claimed.content["lifecycle_status"] == "in_progress"
    end

    test "the resource-overlap scan is workspace-scoped — a nil-scope claim sees no holders",
         %{scope: scope} do
      holder_id = uniq("nil-holder")
      mk_task!(holder_id, scope)

      # Holder takes lib/shared.ex under the real scope.
      assert {:ok, _} =
               Tasks.claim_by_id(
                 holder_id,
                 "worker-holder",
                 scope ++ [resources: ["lib/shared.ex"]]
               )

      # A nil-scope targeted claim can't even find its OWN target row (fail
      # closed), so it never reaches the overlap scan — the point is that a
      # dropped scope resolves to NOTHING, not to a cross-tenant view.
      assert {:error, :not_found} =
               Tasks.claim_by_id(holder_id, "worker-nil",
                 workspace_id: nil,
                 project_id: nil,
                 resources: ["lib/shared.ex"]
               )
    end
  end

  # ─── work-digest stamp (both claim paths) ──────────────────────────────────

  describe "claim stamps content.claim.work_digest" do
    alias Barkpark.Tasks.WorkDigest

    test "claim_by_id/3 stamps the combined digest + per-field map over the brief",
         %{scope: scope} do
      doc_id = uniq("byid-digest")

      task =
        mk_task!(doc_id, scope, %{
          "description" => "ship the fence",
          "acceptance_criteria" => [%{"criterion" => "409 on edit", "met" => false}]
        })

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-d1", scope)

      claim = claimed.content["claim"]
      {expected_combined, expected_fields} = WorkDigest.stamp(task.title, task.content)

      assert claim["work_digest"] == expected_combined
      assert claim["work_field_digests"] == expected_fields
      # The stamp is derived from the actual brief, so it names all three fields.
      assert Map.keys(expected_fields) |> Enum.sort() ==
               ["acceptance_criteria", "description", "title"]

      # Persisted, not just in the returned struct.
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["claim"]["work_digest"] == expected_combined
    end

    test "claim/2 (queue path) stamps the same digest the brief hashes to", %{scope: scope} do
      phase_id = uniq("phase-digest")

      task =
        mk_task!(uniq("queue-digest"), scope, %{
          "parent_id" => phase_id,
          "description" => "queue-claimed brief"
        })

      assert {:ok, claimed} =
               Tasks.claim("worker-d2", scope ++ [phase_id: phase_id, dataset: @dataset])

      assert claimed.id == task.id

      {expected_combined, expected_fields} = WorkDigest.stamp(task.title, task.content)
      assert claimed.content["claim"]["work_digest"] == expected_combined
      assert claimed.content["claim"]["work_field_digests"] == expected_fields
    end
  end
end
