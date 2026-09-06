defmodule Barkpark.Tasks.ExpectationsTest do
  @moduledoc """
  The expectation REVERSE VIEW (lvw-t8) — full-loop, anti-vacuous:

    1. THE DEMO LOOP (living-values §8): a PUBLISHED task doc whose
       `design_doc` cites a paper materialises a real `content_edges` row via
       the REAL performed projector job; `driven_tasks/2` lists it unsatisfied;
       closing the task with met=true + evidence (the lvw-t9 close mechanism,
       riding the claim's fencing epoch) flips the SAME read to satisfied —
       no re-publish, no reprojection.
    2. Publish gating: a draft-only task NEVER appears (the projector corpus
       is `perspective: :published`).
    3. Criteria-less task: appears with `criteria_progress: nil` (omit, never
       0/0), `satisfied: false`, `criteria: []`.
    4. Unresolvable paper: `%{tasks: [], truncated: false}` — the
       `reverse_referencers/2` posture.
  """

  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Graph
  alias Barkpark.EdgeProjector.ProjectorWorker
  alias Barkpark.Tasks.Expectations

  @dataset "production"

  setup do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # The REAL task schemas — edge extraction is schema-declared, so the
    # `design_doc` reference field must be the genuine article, not a stub.
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_paper!(slug) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [%{"id" => "b-intro", "type" => "paragraph", "text" => "the strategy"}]
        })
      )

    Content.get_paper(slug, @dataset)
  end

  defp mk_task!(doc_id, scope, content_extra) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "Task #{doc_id}", "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp publish_task!(doc_id, scope) do
    # Known dedup wrinkle (lvw-t11-followup-dedup): the worker's uniqueness
    # keys ignore `types`, so the paper upsert's earlier rebuild would swallow
    # this publish's `types: ["task"]` enqueue and no task edge would ever
    # project. Drop pending jobs first so the task publish enqueues fresh —
    # the same workaround paper_body_edges_test.exs uses.
    Repo.delete_all(Oban.Job)

    {:ok, doc} = Content.publish_document(doc_id, "task", @dataset, scope)
    doc
  end

  # Perform every REAL enqueued projector job (config/test.exs runs Oban
  # :manual). Draining all of them side-steps the known types-dedup wrinkle
  # (lvw-t11-followup-dedup) — rebuilds are idempotent.
  defp drain_projector! do
    for job <- all_enqueued(worker: ProjectorWorker) do
      perform_job(ProjectorWorker, job.args)
    end

    :ok
  end

  defp view_opts(scope), do: [dataset: @dataset] ++ scope

  # ── 1. THE DEMO LOOP (§8) ───────────────────────────────────────────────────

  test "published task appears via design_doc edge; close(met+evidence) flips satisfied",
       %{scope: scope} do
    slug = uniq("lvw-demo-paper")
    task_id = uniq("lvw-demo-task")
    mk_paper!(slug)

    mk_task!(task_id, scope, %{
      "design_doc" => slug,
      "acceptance_criteria" => [
        %{"criterion" => "the reverse view lists this task", "met" => false},
        %{"criterion" => "closing with evidence flips satisfied", "met" => false}
      ]
    })

    published = publish_task!(task_id, scope)
    drain_projector!()

    # BEFORE the close: listed, unsatisfied, both claims unmet.
    assert %{tasks: [entry], truncated: false} =
             Expectations.driven_tasks(slug, view_opts(scope))

    assert entry.doc_id == task_id
    assert entry.title == "Task #{task_id}"
    assert entry.lifecycle_status == "open"
    assert "design_doc" in entry.via
    assert entry.criteria_progress == %{met: 0, total: 2}
    refute entry.satisfied

    assert [
             %{criterion: "the reverse view lists this task", met: false, evidence: nil},
             %{criterion: "closing with evidence flips satisfied", met: false, evidence: nil}
           ] = entry.criteria

    # Claim (the fencing epoch the close CASes on), then close with
    # met=true + evidence — the lvw-t9 single-write mechanism. The close
    # targets the PUBLISHED row: publish deleted the draft, so the task's
    # lifecycle now lives on the exact doc the published-corpus view reads.
    assert {:ok, claimed} = Tasks.claim_by_id(task_id, "fable-w8", scope)
    epoch = get_in(claimed.content, ["claim", "epoch"])
    assert is_integer(epoch)

    assert {:ok, _closed} =
             Tasks.close(published.id, "fable-w8",
               observed_epoch: epoch,
               # PDS-D289: both criteria are unmet on the doc AS READ and this
               # close flips them in its own command, so it lands only with a
               # recorded reason. The lvw-t9 single-write mechanism under test
               # is unchanged — the override rides the same rev-CAS write.
               criteria_override: "reverse-view close-out under test, not criteria proof",
               # D56: a met-flip names its criterion — the 0-based index alone is
               # unverifiable, so an unguarded flip is :criterion_text_required.
               criteria: [
                 %{
                   "index" => 0,
                   "met" => true,
                   "evidence" => "expectations_test.exs demo loop",
                   "criterion" => "the reverse view lists this task"
                 },
                 %{
                   "index" => 1,
                   "met" => true,
                   "evidence" => "this very assertion",
                   "criterion" => "closing with evidence flips satisfied"
                 }
               ]
             )

    # AFTER the close: the SAME read now shows the claims satisfied — the
    # 'satisfied' flip is purely the reverse view re-reading (§8). No
    # re-publish, no reprojection between the two reads.
    assert %{tasks: [entry2], truncated: false} =
             Expectations.driven_tasks(slug, view_opts(scope))

    assert entry2.doc_id == task_id
    assert entry2.lifecycle_status == "done"
    assert entry2.criteria_progress == %{met: 2, total: 2}
    assert entry2.satisfied

    assert [
             %{met: true, evidence: "expectations_test.exs demo loop"},
             %{met: true, evidence: "this very assertion"}
           ] = entry2.criteria
  end

  # ── 2. Publish gating ───────────────────────────────────────────────────────

  test "a draft-only task never appears (published-corpus projection)", %{scope: scope} do
    slug = uniq("lvw-gate-paper")
    task_id = uniq("lvw-gate-task")
    mk_paper!(slug)

    mk_task!(task_id, scope, %{
      "design_doc" => slug,
      "acceptance_criteria" => [%{"criterion" => "never visible", "met" => false}]
    })

    # No publish — but DO run any enqueued rebuilds, so the assertion is
    # against the projector's real output, not against "no job ran".
    drain_projector!()

    assert %{tasks: [], truncated: false} = Expectations.driven_tasks(slug, view_opts(scope))
  end

  # ── 3. Criteria-less task ───────────────────────────────────────────────────

  test "a task without criteria lists with nil progress and satisfied: false",
       %{scope: scope} do
    slug = uniq("lvw-nocrit-paper")
    task_id = uniq("lvw-nocrit-task")
    mk_paper!(slug)

    mk_task!(task_id, scope, %{"design_doc" => slug})
    publish_task!(task_id, scope)
    drain_projector!()

    assert %{tasks: [entry], truncated: false} =
             Expectations.driven_tasks(slug, view_opts(scope))

    assert entry.doc_id == task_id
    assert entry.criteria_progress == nil
    assert entry.criteria == []
    refute entry.satisfied
  end

  # ── 4. Unresolvable paper ───────────────────────────────────────────────────

  test "an unknown paper id yields an empty view, never an error", %{scope: scope} do
    assert %{tasks: [], truncated: false} =
             Expectations.driven_tasks(uniq("no-such-paper"), view_opts(scope))
  end

  # ── 5. The drop is COUNTED (task-464b89f30e3f8e41) ──────────────────────────
  #
  # `reverse_referencers/2` and `entries/3` do NOT clamp identically: the walk
  # hydrates through `Content.Graph`'s keyed read, the per-task hydration adds
  # `Content.Query.get_documents_by_ids/3`'s `scope_to_dataset/3` +
  # `restrict_to_visible_types/3`. A referencer that clears the first and fails
  # the second used to vanish with no trace — a SHORT answer that reported
  # itself complete. Measured live 2026-09-06: three real `content_edges` rows
  # (api-read-path-security-sweep -> two papers, authoring-excellence -> one)
  # were absent from every `GET /v1/graph/<paper>/tasks` while present in
  # `GET /v1/graph/<paper>`, and the filed diagnosis blamed the projector.
  test "a referencer that does not hydrate under the read's scope is reported in :unhydrated",
       %{scope: scope} do
    slug = uniq("unhydrated-paper")
    task_id = uniq("unhydrated-task")
    mk_paper!(slug)

    mk_task!(task_id, scope, %{
      "design_doc" => slug,
      "acceptance_criteria" => [%{"criterion" => "listed", "met" => false}]
    })

    publish_task!(task_id, scope)
    drain_projector!()

    # NON-VACUITY: the edge is real and the task DOES hydrate under its own
    # scope — so a later empty answer is the clamp, not a missing fixture.
    complete = Expectations.driven_tasks(slug, view_opts(scope))
    assert Enum.map(complete.tasks, & &1.doc_id) == [task_id]
    assert complete.unhydrated == []

    # The SAME edge, re-hydrated under a scope the source document cannot
    # satisfy. The answer is short — and says so.
    referencers = Graph.reverse_referencers(Content.published_id(slug), view_opts(scope))
    assert Enum.any?(referencers, &(&1.from_doc_id == task_id))

    short =
      Expectations.driven_tasks_from_referencers(
        referencers,
        Keyword.put(view_opts(scope), :dataset, uniq("no-such-dataset"))
      )

    assert short.tasks == []
    assert short.unhydrated == [task_id]
    refute short.truncated
  end
end
