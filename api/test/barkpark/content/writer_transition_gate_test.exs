defmodule Barkpark.Content.WriterTransitionGateTest do
  @moduledoc """
  The Writer-seam transition gate (task-lifecycle-visibility, charter D7b) —
  `Content.Writer` enforces `Barkpark.Tasks.Transitions.legal?/2` for
  `type=task` lifecycle_status CHANGES at do_create_document + do_upsert_document.

  The load-bearing choice under test is the WAS-RESOLUTION: `was` is resolved
  published-fallback (drafts.<id> first, then the bare id), NOT via the
  Writer's drafts-exact prev_doc. Proven open at L1 before the gate: with the
  drafts-exact lookup, a createOrReplace on a PUBLISHED-ONLY open task births
  a `drafts.<id>` done twin that Queue.ready's done-CTE (which regexp-strips
  the `drafts.` prefix) counts — flipping a gated dependent to ready with zero
  attribution. A birth is when NEITHER spelling exists.

  Every refusal here is mutation-proven: reverting the was-resolution to the
  drafts-exact prev_doc (or skipping the gate call) turns the forgery-door
  test red-in-the-other-direction (the twin is born, the dependent unblocks).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "writer_transition_gate_test"

  setup do
    # E3 tag registry: the fixture weighted tags the publish in the forgery
    # test carries must resolve to PUBLISHED type:tag docs in this dataset.
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

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      # Unique description per call — keeps Tasks.Dedup AND the E4 publish
      # dedup wall quiet, so only the transitions under test drive outcomes.
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "Gate fixture #{doc_id}", "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # A whole-document createOrReplace payload — the fleet file-order.sh shape.
  defp task_doc(id, lifecycle) do
    content =
      %{"kind" => "task", "lifecycle_status" => lifecycle}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    %{"_id" => id, "_type" => "task", "title" => "Gate fixture #{id}", "content" => content}
  end

  defp lifecycle_of(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc.content["lifecycle_status"]
  end

  defp ready_doc_ids(scope) do
    (scope ++ [dataset: @dataset]) |> Tasks.ready() |> Enum.map(& &1.doc_id)
  end

  # ── (a) the forgery door, CLOSED ─────────────────────────────────────────

  test "forgery door: createOrReplace on a PUBLISHED-ONLY open task carrying done is refused — " <>
         "no drafts twin born, the dependent stays gated in Queue.ready",
       %{scope: scope} do
    # The blocker, made PUBLISHED-ONLY: create → publish (publish collapses the
    # draft), so the task exists at the bare id and mutations.ex's drafts-exact
    # `existing` lookup sees NOTHING — the exact shape that slipped every
    # upstream guard before the Writer-seam gate.
    mk_task!("wtg-forge-target", scope)
    {:ok, _pub} = Content.publish_document("wtg-forge-target", "task", @dataset, scope)

    assert {:error, _} = Content.get_document("drafts.wtg-forge-target", "task", @dataset, scope)
    assert lifecycle_of("wtg-forge-target", scope) == "open"

    # A dependent gated on the blocker, plus a dependency-free CONTROL so a
    # ready query that silently returns [] can never pass the gated assertions
    # vacuously (distrust vacuous green).
    mk_task!("wtg-forge-dependent", scope, %{"dependencies" => ["wtg-forge-target"]})
    mk_task!("wtg-forge-control", scope)

    before_ids = ready_doc_ids(scope)
    assert "drafts.wtg-forge-control" in before_ids
    refute "drafts.wtg-forge-dependent" in before_ids

    # THE PROBE (measured HTTP 200 + twin born + dependent ready, pre-gate):
    # the published-fallback was-resolution reads the bare id → was=open,
    # now=done → illegal → refused, naming from, to and the sanctioned verb.
    assert {:error, {:invalid_task_content, %{"lifecycle_status" => [message]}}} =
             Content.apply_mutations(
               [%{"createOrReplace" => task_doc("wtg-forge-target", "done")}],
               @dataset,
               scope ++ [source: :api]
             )

    assert message =~ "\"open\""
    assert message =~ "\"done\""
    assert message =~ "bp task close"

    # No drafts twin was born…
    assert {:error, _} = Content.get_document("drafts.wtg-forge-target", "task", @dataset, scope)
    # …the published row never moved…
    assert lifecycle_of("wtg-forge-target", scope) == "open"

    # …and the dependent stays gated while the control stays ready.
    after_ids = ready_doc_ids(scope)
    assert "drafts.wtg-forge-control" in after_ids
    refute "drafts.wtg-forge-dependent" in after_ids
  end

  # ── (b) legal transitions still pass ─────────────────────────────────────

  test "legal patch transitions pass: done → open (the false-done reopen recipe)",
       %{scope: scope} do
    # An already-done row is a BIRTH with done (importer shape, birth-exempt).
    mk_task!("wtg-reopen", scope, %{"lifecycle_status" => "done"})

    assert {:ok, {_tx, [%{operation: "update"}]}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "wtg-reopen",
                     "type" => "task",
                     "set" => %{"lifecycle_status" => "open"}
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :api]
             )

    assert lifecycle_of("drafts.wtg-reopen", scope) == "open"
  end

  test "legal patch transitions pass: open → blocked rides the revision escape unchanged",
       %{scope: scope} do
    doc = mk_task!("wtg-block", scope)

    # `blocked` is terminal for the mutations close guard, so the patch carries
    # the rev escape — and because open → blocked is LEGAL in the D7 table the
    # downstream Writer gate lets it through (the D7a supersede flips ONLY
    # illegal transitions).
    assert {:ok, {_tx, [%{operation: "update"}]}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "wtg-block",
                     "type" => "task",
                     "ifRevisionID" => doc.rev,
                     "set" => %{"lifecycle_status" => "blocked"}
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :api]
             )

    assert lifecycle_of("drafts.wtg-block", scope) == "blocked"
  end

  # ── (c) births stay legal ────────────────────────────────────────────────

  test "task BIRTH with lifecycle open succeeds — plain create AND the fleet createOrReplace shape",
       %{scope: scope} do
    # Plain create birth (the Writer path every `bp task create` rides).
    doc = mk_task!("wtg-birth-create", scope)
    assert doc.content["lifecycle_status"] == "open"

    # The fleet file-order.sh shape: createOrReplace birth on a FRESH id —
    # neither spelling exists, so the gate treats it as a birth and never
    # consults legal?/2 (legal?(nil, x) is false and would refuse every birth).
    assert {:ok, {_tx, [%{operation: "createOrReplace"}]}} =
             Content.apply_mutations(
               [%{"createOrReplace" => task_doc("wtg-birth-cor", "open")}],
               @dataset,
               scope ++ [source: :api]
             )

    assert lifecycle_of("drafts.wtg-birth-cor", scope) == "open"
  end

  # ── (d) replication is exempt, and the exemption is not vacuous ──────────

  test "a source :sync mirror of open → done passes; the same shape from :api is refused " <>
         "even WITH the revision escape",
       %{scope: scope} do
    mk_task!("wtg-sync", scope)

    # Sync.Applier mirrors an upstream close it did not itself perform.
    assert {:ok, {_tx, [%{operation: "update"}]}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "wtg-sync",
                     "type" => "task",
                     "set" => %{"lifecycle_status" => "done"}
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :sync]
             )

    assert lifecycle_of("drafts.wtg-sync", scope) == "done"

    # Control (distrust vacuous green): the SAME transition from the api
    # source carries a CORRECT ifRevisionID — which satisfies the mutations.ex
    # close guard's escape — and the Writer-seam gate refuses it anyway. This
    # is the D7a supersede measured end-to-end through apply_mutations.
    control = mk_task!("wtg-sync-control", scope, %{"distinct_from" => ["wtg-sync"]})

    assert {:error, {:invalid_task_content, %{"lifecycle_status" => [message]}}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "wtg-sync-control",
                     "type" => "task",
                     "ifRevisionID" => control.rev,
                     "set" => %{"lifecycle_status" => "done"}
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :api]
             )

    assert message =~ "bp task close"
    assert lifecycle_of("drafts.wtg-sync-control", scope) == "open"
  end

  # ── the refusal names the sanctioned verb per target ─────────────────────

  test "each illegal target names ITS sanctioned verb: claim for in_progress, stage for thought states",
       %{scope: scope} do
    # open → in_progress and open → researching are illegal from `open`;
    # `considering` is LEGAL from open (D7 re-weigh), so its illegal probe
    # comes from a terminal row (done → considering — terminal never re-enters
    # thought).
    mk_task!("wtg-verbs", scope)
    mk_task!("wtg-verbs-done", scope, %{"lifecycle_status" => "done"})

    for {id, from, target, verb} <- [
          {"wtg-verbs", "open", "in_progress", "bp task claim"},
          {"wtg-verbs", "open", "researching", "bp task stage"},
          {"wtg-verbs-done", "done", "considering", "bp task stage"}
        ] do
      result =
        Content.apply_mutations(
          [
            %{
              "patch" => %{
                "id" => id,
                "type" => "task",
                "set" => %{"lifecycle_status" => target}
              }
            }
          ],
          @dataset,
          scope ++ [source: :api]
        )

      assert match?({:error, {:invalid_task_content, %{"lifecycle_status" => [_]}}}, result),
             "expected the #{from} → #{target} patch to be refused, got #{inspect(result)}"

      {:error, {:invalid_task_content, %{"lifecycle_status" => [message]}}} = result

      assert message =~ "\"#{from}\""
      assert message =~ "\"#{target}\""
      assert message =~ verb
    end

    assert lifecycle_of("drafts.wtg-verbs", scope) == "open"
    assert lifecycle_of("drafts.wtg-verbs-done", scope) == "done"
  end
end
