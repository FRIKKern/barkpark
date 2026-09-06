defmodule Barkpark.Tasks.DraftTerminalFenceTest do
  @moduledoc """
  The draft-only terminal fence (task-e49058a7f2b46a63).

  The publish door's transition gate
  (`Content.Lifecycle.ensure_task_publish_transition_legal/5`) runs AT PUBLISH.
  A task row that never publishes never meets it — and for a never-published
  row the DRAFT IS THE ROW OF RECORD. This file measures the seam that gap
  leaves open, and the four things the fix must NOT break.

  RUN-PROVEN OPEN on guerrilla.barkpark.cloud, 2026-09-06, before this fence
  existed. Probe row `drafts.task-probe-draft-terminal-e49058`, created as a
  draft and NEVER published:

      $ bp doc mutate --file - <<'EOF'
      {"mutations":[{"patch":{"id":"drafts.task-probe-draft-terminal-e49058",
        "type":"task","ifRevisionID":"f90e2e97f7ffd91c71661450af062ffe",
        "set":{"lifecycle_status":"cancelled"}}}]}
      EOF
      => "operation":"update", "lifecycle_status":"cancelled"

  No claim, no `closed_by`, no `closed_at`, no `close_reason` — the exact
  2026-07-23 witness shape (`task-77620317484e1185`).

  The refusal test below (`the 2026-07-23 witness shape`) is MUTATION-PROVEN:
  collapsing `DraftTerminalFence.check/6` to `:ok` reds that test and ONLY that
  test.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "draft_terminal_fence_test"

  setup do
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

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp content(extra) do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
    }
    |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # Writes through the Writer seam — the door every raw document write
  # (`/v1/data/mutate` create / createOrReplace / patch-merge) funnels through.
  # With a `prev_doc` present this is the UPDATE arm; with none, the BIRTH arm.
  defp write(doc_id, extra, scope, opts \\ []) do
    Content.create_document(
      "task",
      %{
        "doc_id" => doc_id,
        "title" => "Draft terminal fence fixture #{doc_id}",
        "content" => content(extra)
      },
      @dataset,
      Keyword.merge(scope, opts)
    )
  end

  # A never-published draft sitting at `open` — the state of every one of the
  # store's orphan drafts.
  defp draft_only!(doc_id, scope) do
    {:ok, draft} = write(doc_id, %{}, scope)
    assert draft.doc_id == "drafts." <> doc_id
    assert draft.content["lifecycle_status"] == "open"
    draft
  end

  defp status(doc_id, scope) do
    {:ok, doc} = Content.get_document("drafts." <> doc_id, "task", @dataset, scope)
    doc.content["lifecycle_status"]
  end

  # ── (a) THE HOLE — refused ───────────────────────────────────────────────

  test "the 2026-07-23 witness shape: a never-published draft moved open → cancelled " <>
         "with no closed_by is REFUSED",
       %{scope: scope} do
    draft_only!("dtf-witness", scope)

    result = write("dtf-witness", %{"lifecycle_status" => "cancelled"}, scope)

    assert {:error, {:invalid_task_content, details}} = result
    message = details["lifecycle_status"] |> List.first()
    assert message =~ "draft task row cannot be set to a terminal lifecycle_status"
    assert message =~ "bp task close"
    assert message =~ "delete the draft"

    # And the row did not move.
    assert status("dtf-witness", scope) == "open"
  end

  test "the BIRTH arm: a brand-new draft born `done` with no close provenance is REFUSED",
       %{scope: scope} do
    result = write("dtf-birth", %{"lifecycle_status" => "done"}, scope)

    assert {:error, {:invalid_task_content, details}} = result
    message = details["lifecycle_status"] |> List.first()
    assert message =~ "draft task row cannot be set to a terminal lifecycle_status"

    assert {:error, :not_found} =
             Content.get_document("drafts.dtf-birth", "task", @dataset, scope)
  end

  # ── (b) THE ESCAPE — a real close still lands ────────────────────────────

  test "close provenance passes: a terminal write carrying claim.closed_by LANDS",
       %{scope: scope} do
    draft_only!("dtf-provenance", scope)

    assert {:ok, doc} =
             write(
               "dtf-provenance",
               %{
                 "lifecycle_status" => "cancelled",
                 "claim" => %{
                   "worker" => "dtf-worker",
                   "closed_by" => "dtf-worker",
                   "closed_at" => "2026-09-06T08:00:00Z"
                 }
               },
               scope
             )

    assert doc.content["lifecycle_status"] == "cancelled"
  end

  test "the SANCTIONED path is untouched: publish → claim → close still reaches done",
       %{scope: scope} do
    draft_only!("dtf-sanctioned", scope)
    {:ok, _pub} = Content.publish_document("dtf-sanctioned", "task", @dataset, scope)

    assert {:ok, claimed} = Tasks.claim_by_id("dtf-sanctioned", "dtf-worker", scope)
    epoch = claimed.content["claim"]["epoch"]

    assert {:ok, closed} = Tasks.close(claimed.id, "dtf-worker", observed_epoch: epoch)
    assert closed.content["lifecycle_status"] == "done"
    assert closed.content["claim"]["closed_by"] == "dtf-worker"
  end

  # ── (c) THE SCOPE — what the fence deliberately does not touch ───────────

  test "`blocked` is NOT fenced: filing a blocked draft still works " <>
         "(bp task ready serves blocked rows)",
       %{scope: scope} do
    assert {:ok, doc} = write("dtf-blocked", %{"lifecycle_status" => "blocked"}, scope)
    assert doc.content["lifecycle_status"] == "blocked"
  end

  test "a draft WITH a published twin is not fenced here — the publish door owns it",
       %{scope: scope} do
    draft_only!("dtf-twin", scope)
    {:ok, _pub} = Content.publish_document("dtf-twin", "task", @dataset, scope)

    assert {:ok, doc} = write("dtf-twin", %{"lifecycle_status" => "cancelled"}, scope)
    assert doc.content["lifecycle_status"] == "cancelled"
  end

  test "same → same: an already-cancelled draft can still be patched on other fields",
       %{scope: scope} do
    draft_only!("dtf-samesame", scope)

    {:ok, _} =
      write(
        "dtf-samesame",
        %{"lifecycle_status" => "cancelled", "close_reason" => "created for probe"},
        scope
      )

    assert {:ok, doc} =
             write(
               "dtf-samesame",
               %{"lifecycle_status" => "cancelled", "close_reason" => "created for probe",
                 "priority" => 3},
               scope
             )

    assert doc.content["lifecycle_status"] == "cancelled"
    assert doc.content["priority"] == 3
  end

  test "`source: :sync` is exempt: replication mirrors an upstream close verbatim",
       %{scope: scope} do
    draft_only!("dtf-sync", scope)

    assert {:ok, doc} =
             write("dtf-sync", %{"lifecycle_status" => "cancelled"}, scope, source: :sync)

    assert doc.content["lifecycle_status"] == "cancelled"
  end

  # ── (d) CRITERION 3 — the disposition path must survive ──────────────────
  #
  # A refusal that also blocked deleting or discarding a draft would strand the
  # orphan drafts task-ee33b6f088b35bdb is dispositioning. The fence is scoped
  # to a TERMINAL LIFECYCLE WRITE on the create/upsert path; delete and
  # discard-draft never consult it.

  test "CRITERION 3: deleting a draft-only task row still works",
       %{scope: scope} do
    draft_only!("dtf-delete", scope)

    assert {:ok, _} = Content.delete_document("drafts.dtf-delete", "task", @dataset, scope)

    assert {:error, :not_found} =
             Content.get_document("drafts.dtf-delete", "task", @dataset, scope)
  end

  test "CRITERION 3: discarding a draft still works, and the published row survives",
       %{scope: scope} do
    draft_only!("dtf-discard", scope)
    {:ok, _pub} = Content.publish_document("dtf-discard", "task", @dataset, scope)
    {:ok, _draft} = write("dtf-discard", %{"priority" => 5}, scope)

    assert {:ok, _} = Content.discard_draft("dtf-discard", "task", @dataset, scope)

    assert {:ok, pub} = Content.get_document("dtf-discard", "task", @dataset, scope)
    assert pub.content["lifecycle_status"] == "open"
  end
end
