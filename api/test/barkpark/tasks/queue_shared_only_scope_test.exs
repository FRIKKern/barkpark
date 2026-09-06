defmodule Barkpark.Tasks.QueueSharedOnlyScopeTest do
  @moduledoc """
  `Tasks.Queue.ready_query/1` must honour the `:shared_only` empty-scope
  sentinel (task-3e2a70930c6df723).

  ## The defect

  `ready_query/1` hands `workspace_id` to TWO interpreters. `Content.Scope`
  (the `done_tasks` CTE and the outer scope) has owned a `:shared_only` arm
  since the class fix. The raw-SQL `ready_unsatisfied_tasks` CTE did not: the
  atom is TRUTHY, so `workspace_id && Ecto.UUID.dump!(workspace_id)` fell
  through to `dump!/1`, which raises `ArgumentError` on anything that is not a
  36-char UUID string or a 16-byte binary.

  THREE doors reach it, because all three ride `ready_query/1`:
  `GET /v1/tasks/ready` (`tasks_controller.ex` -> `Tasks.ready/1`),
  `GET /v1/tasks/prime`, and `Tasks.Claim.claim/2`. Each 500s whenever no
  Default workspace is seeded — exactly the condition the sentinel exists for.

  ## Why the arms below are shaped the way they are

  Every assertion is scoped to a UNIQUE `phase_id` this test mints. The tasks
  table is written by every other suite (and, in this repo, by other agents
  against the same database), so an unscoped `ready/1` assertion measures the
  neighbourhood, not the fixture.

  `(1)` is the INSTRUMENT SELF-TEST and it PASSES BEFORE THE FIX: it proves the
  fixture is well-formed and reaches the workspace clause through a real
  workspace id. Without it, `(2)`'s red could be any upstream failure and the
  suite would prove nothing about this defect.

  `(4)` is the arm that matters most after the fix lands. A predicate that
  narrowed to the shared layer but emptied the CTE would make the dependency
  gate silently stop firing for shared-layer tasks — a fail-OPEN traded for a
  crash. `(4)` pins the gate live in BOTH directions under the sentinel.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Queue

  @dataset "production"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_schemas!(scope, @dataset)

    %{scope: scope, ws: ws}
  end

  defp register_schemas!(scope, dataset) do
    for schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Move rows to the SHARED layer (`workspace_id IS NULL`) — the pre-tenancy
  # shape an unresolved request is supposed to read. A fixture that merely OMITS
  # the scope does NOT produce this: `WriteScope` stamps an unscoped write with
  # the seeded Default, so it would be a Default-OWNED row and every arm below
  # would pass for the wrong reason.
  defp share!(docs) do
    ids = Enum.map(docs, & &1.id)

    {n, _} =
      Repo.update_all(
        from(d in Document, where: d.id in ^ids),
        set: [workspace_id: nil, project_id: nil]
      )

    assert n == length(ids),
           "share! moved #{n} rows but was given #{length(ids)} — the fixture is not " <>
             "on the shared layer and every arm below would measure the wrong thing"

    docs
  end

  defp phase, do: "phase-so-#{System.unique_integer([:positive])}"
  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp ids_of(docs), do: Enum.map(docs, & &1.id)

  # ── (1) INSTRUMENT SELF-TEST — passes BEFORE the fix ────────────────────────

  describe "instrument" do
    test "a workspace-owned task in this phase IS visible through its own workspace id",
         %{scope: scope, ws: ws} do
      p = phase()
      owned = mk_task!(uid("owned"), scope, %{"parent_id" => p})

      ready = Queue.ready(workspace_id: ws.id, dataset: @dataset, phase_id: p)

      assert owned.id in ids_of(ready),
             "INSTRUMENT BLIND: the fixture is not reachable even through a real " <>
               "workspace id, so the sentinel arms below would be absence-shaped and " <>
               "would prove nothing about the workspace clause"
    end
  end

  # ── (2) the crash arm ───────────────────────────────────────────────────────

  describe "the :shared_only sentinel reaches the raw-SQL CTE" do
    test "ready/1 does not raise and returns the shared-layer task", %{scope: scope} do
      p = phase()
      shared = mk_task!(uid("shared"), scope, %{"parent_id" => p})
      share!([shared])

      ready = Queue.ready(workspace_id: :shared_only, dataset: @dataset, phase_id: p)

      assert shared.id in ids_of(ready),
             "the :shared_only sentinel did not survive ready_query/1 — before the fix " <>
               "this raises ArgumentError out of Ecto.UUID.dump!/1, a 500 on " <>
               "GET /v1/tasks/ready whenever no Default workspace is seeded"
    end

    # ── (3) and it must narrow, not widen ──────────────────────────────────────
    test "it does NOT return a workspace-owned task in the same phase", %{scope: scope} do
      p = phase()
      shared = mk_task!(uid("shared"), scope, %{"parent_id" => p})
      owned = mk_task!(uid("owned"), scope, %{"parent_id" => p})
      share!([shared])

      ready_ids = ids_of(Queue.ready(workspace_id: :shared_only, dataset: @dataset, phase_id: p))

      assert shared.id in ready_ids,
             "the shared-layer row is missing, so the refutation below is vacuous"

      refute owned.id in ready_ids,
             "CROSS-TENANT LEAK: :shared_only surfaced a workspace-owned task. The " <>
               "sentinel means workspace_id IS NULL, never every tenant"
    end
  end

  # ── (4) the dependency gate must stay LIVE under the sentinel ───────────────

  describe "the dependency CTE still gates under :shared_only" do
    test "an unsatisfied dependency withholds a shared task, and satisfying it releases it",
         %{scope: scope} do
      p = phase()
      dep_id = uid("dep")

      # The dependency is deliberately PARENTLESS, so the phase-scoped result
      # contains only `main` and an empty list localises the exclusion to it.
      dep = mk_task!(dep_id, scope, %{"lifecycle_status" => "open"})

      main =
        mk_task!(uid("main"), scope, %{"parent_id" => p, "dependencies" => [dep_id]})

      share!([dep, main])

      withheld = Queue.ready(workspace_id: :shared_only, dataset: @dataset, phase_id: p)

      refute main.id in ids_of(withheld),
             "FAIL-OPEN: a shared-layer task with an OPEN dependency was ready. If the " <>
               "sentinel narrowed the scope but emptied ready_unsatisfied_tasks, the " <>
               "dependency gate stops firing for the whole shared layer — a crash traded " <>
               "for a silent hole"

      {n, _} =
        Repo.update_all(
          from(d in Document, where: d.id == ^dep.id),
          set: [
            content: %{
              "kind" => "task",
              "close_reason" => "fixture: closed through the verb",
              "lifecycle_status" => "done"
            }
          ]
        )

      assert n == 1, "the dependency was not marked done; the release arm below is vacuous"

      released = Queue.ready(workspace_id: :shared_only, dataset: @dataset, phase_id: p)

      assert main.id in ids_of(released),
             "the dependency is done but the shared task never became ready — the CTE is " <>
               "matching nothing under the sentinel, which would gate the shared layer shut"
    end
  end

  # ── (5) nil is untouched ────────────────────────────────────────────────────

  describe "nil keeps its meaning" do
    test "an explicit nil workspace_id still returns []", %{scope: scope} do
      p = phase()
      _shared = share!([mk_task!(uid("shared"), scope, %{"parent_id" => p})])

      assert Queue.ready(workspace_id: nil, dataset: @dataset, phase_id: p) == [],
             "nil must keep failing CLOSED at Scope.scope_to_workspace/3. Widening it " <>
               "here would change ~90 internal callers that legitimately mean everything"
    end
  end
end
