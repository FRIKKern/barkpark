defmodule Barkpark.Tasks.Expectations do
  @moduledoc """
  The expectation REVERSE VIEW (living-values lvw-t8; paper
  `nextgen-wiki-living-values-v1` §8/§9): given a paper, list the TASKS that
  cite it — the `design_doc` / `papers` reference edges the schema-declared
  extractor already materialises into `content_edges` — each with its
  acceptance-criteria expectation state.

  ## Expectation semantics (§9)

  `acceptance_criteria` = expectation: `criterion` is the claim that must
  become true, `met` the observation, `evidence` the provenance. This module
  is the read that makes the pattern visible from the PAPER side:

    * *paper drives task* — an inbound task referencer with unmet criteria is
      the reason that task is open;
    * *task proves paper* — closing the task with `met=true` + `evidence`
      (the lvw-t9 close-time mutation) flips `satisfied` here on the next
      read. No reprojection is needed for the flip: the EDGE is stable across
      a close (close never touches `design_doc`/`papers`), and the criteria
      state is re-read live from the task doc on every call.

  READ-side only. No reactor, no write-path changes — reflag-on-edit is
  explicitly deferred (§8 post-v1).

  ## Publish gating + scope

  Built on `Content.Graph.reverse_referencers/2`, whose corpus is the
  materialised published-only `content_edges` table (the projector rebuilds
  at `perspective: :published`) — a draft-only task NEVER appears here. The
  caller's scope opts pass through UNCHANGED to both the edge read and the
  per-task hydration, inheriting reverse_referencers' fail-closed posture: a
  task the caller can't see is dropped entirely, never stubbed.

  ## The drop is COUNTED, never silent (task-464b89f30e3f8e41)

  The two reads are not clamped identically. `reverse_referencers/2` hydrates
  its sources through `Content.Graph`'s keyed read (tenancy + owner + grant);
  `entries/3` re-hydrates the SAME ids through
  `Content.Query.get_documents_by_ids/3`, which additionally applies
  `scope_to_dataset/3` and `restrict_to_visible_types/3`. A referencer that
  clears the first stack and fails the second used to vanish with NO trace:
  the caller saw a shorter `tasks` list, `truncated` said `false`, and the
  paper looked as if the task had never cited it. MEASURED on the live corpus
  2026-09-06: `forked-authorization-equivalence-wave-2026-08-19` holds 14
  inbound citation edges in `content_edges` and answered 13 tasks;
  `api-read-path-security-sweep-wave6-liveview-2026-08-18` 8 and 7;
  `authoring-excellence-wave-2026-07-23` 5 and 4 — three real edges, two
  tasks, invisible to every reader AND to the edge-level census that was
  filed as a projector gap (the edges were materialised the whole time).

  So `unhydrated` now rides the result: the doc_ids whose edge was read but
  whose document did not hydrate. Fail-closed is preserved — nothing is
  stubbed and no title leaks — but the reader can no longer report a partial
  answer as a complete one, and a `Logger.warning` names the ids.

  ## doc_id is not unique across types

  One measured cause of that miss is a NAME COLLISION, not a scope refusal:
  `documents.doc_id` is unique per (scope, type), so a `tag` document and a
  `task` document can both be `authoring-excellence`. The batch hydration is
  TYPELESS and keys its result by doc_id, so the two rows collapse and the
  last one wins — a task whose name is also a tag drops out of its own
  paper's list. `resolve_task/4` re-reads such a miss TYPE-PINNED under the
  identical clamp stack; see its comment.

  ## Bounding

  One inbound hop (no traversal), capped at the graph engine's existing
  `Content.Graph.node_budget/0` — the same 1000-node ceiling `traverse/2`
  enforces — with a `truncated` flag when the cap bites, mirroring the
  traverse contract.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Graph
  alias Barkpark.Tasks.Criteria

  @typedoc """
  One driven task. `criteria_progress` is `nil` when the task has no
  criteria (the Criteria omit-never-0/0 contract); `satisfied` is `true`
  only when criteria exist AND every one is met.
  """
  @type driven_task :: %{
          doc_id: String.t(),
          title: String.t() | nil,
          lifecycle_status: String.t() | nil,
          via: [String.t()],
          criteria: [%{criterion: String.t() | nil, met: boolean(), evidence: String.t() | nil}],
          criteria_progress: %{met: non_neg_integer(), total: pos_integer()} | nil,
          satisfied: boolean()
        }

  @doc """
  Tasks that reference `paper_id` (published-coalesced), each with its
  expectation state. Returns
  `%{tasks: [driven_task], truncated: boolean, unhydrated: [doc_id]}`; an
  unresolvable paper yields `%{tasks: [], truncated: false, unhydrated: []}`
  (nothing references a non-existent doc — the `reverse_referencers/2`
  posture). `unhydrated` lists citing tasks whose edge was read but whose
  document did not survive the hydration clamp — see the moduledoc.

  Opts are the standard scope keywords (`:dataset`, `:workspace_id`,
  `:project_id`, …), passed through to the graph read and the task
  hydration alike.
  """
  @spec driven_tasks(binary(), keyword()) :: %{
          tasks: [driven_task()],
          truncated: boolean(),
          unhydrated: [String.t()]
        }
  def driven_tasks(paper_id, opts \\ []) when is_binary(paper_id) do
    paper_id
    |> Content.published_id()
    |> Graph.reverse_referencers(opts)
    |> driven_tasks_from_referencers(opts)
  end

  @doc """
  `driven_tasks/2` fed an ALREADY-COMPUTED `Graph.reverse_referencers/2` list —
  the am-w1-s3 reader dedupe seam. A caller that needs the referencers for
  another section too (the Bulldocs reader renders backlinks AND driven tasks
  off the same paper) runs the walk ONCE and hands the list to both; `opts`
  must be the SAME scope keywords the walk itself ran under (they still scope
  the per-task hydration here). Non-task referencers are ignored.
  """
  @spec driven_tasks_from_referencers([map()], keyword()) ::
          %{tasks: [driven_task()], truncated: boolean(), unhydrated: [String.t()]}
  def driven_tasks_from_referencers(referencers, opts \\ []) when is_list(referencers) do
    referencers = Enum.filter(referencers, &(&1.type == "task"))

    # A task may cite the paper via more than one field (design_doc AND the
    # papers list) — one entry per task, `via` carrying every edge kind, first
    # sighting preserving the engine's order.
    kinds_by_doc =
      Enum.reduce(referencers, %{}, fn ref, acc ->
        Map.update(acc, ref.from_doc_id, [ref.kind], &(&1 ++ [ref.kind]))
      end)

    doc_ids = referencers |> Enum.map(& &1.from_doc_id) |> Enum.uniq()

    budget = Graph.node_budget()
    truncated = length(doc_ids) > budget

    {tasks, unhydrated} =
      doc_ids
      |> Enum.take(budget)
      |> entries(kinds_by_doc, opts)

    warn_unhydrated(unhydrated)

    %{tasks: tasks, truncated: truncated, unhydrated: unhydrated}
  end

  # A referencer whose edge was read but whose document did not hydrate is a
  # CORPUS fact, not a rendering detail — the reader is answering a smaller
  # question than the one asked. Name the ids so the next reader does not have
  # to re-derive them from `content_edges` by hand.
  defp warn_unhydrated([]), do: :ok

  defp warn_unhydrated(ids) do
    Logger.warning(
      "Tasks.Expectations: #{length(ids)} citing task(s) had an inbound edge but did NOT " <>
        "hydrate under this read's scope — they are ABSENT from the driven-task answer: " <>
        Enum.join(ids, ", ")
    )
  end

  # Hydrate the citing tasks in ONE batched, scope-identical read
  # (`Content.get_documents_by_ids/3`) instead of a `get_document/4` per task —
  # the am-w1-s3 N+1 fix (4.0 statements per citing task per leg at the
  # baseline). Fail-closed exactly like the per-doc read it replaces: a source
  # that vanished between the edge read and this fetch, that the scope rejects,
  # or that is no longer a `task` drops entirely — the batch read is TYPELESS,
  # so the type gate `get_document(_, "task", _, _)` used to apply moves to the
  # post-fetch filter here.
  # Returns `{entries, unhydrated_doc_ids}` — the miss is RETURNED, not
  # swallowed, so `driven_tasks_from_referencers/2` can report it.
  defp entries([], _kinds_by_doc, _opts), do: {[], []}

  defp entries(doc_ids, kinds_by_doc, opts) do
    dataset = Keyword.get(opts, :dataset, "production")
    docs_by_id = Content.get_documents_by_ids(doc_ids, dataset, opts)

    doc_ids
    |> Enum.reduce({[], []}, fn doc_id, {kept, missed} ->
      case resolve_task(docs_by_id, doc_id, dataset, opts) do
        %{type: "task"} = doc -> {[entry(doc, Map.fetch!(kinds_by_doc, doc_id)) | kept], missed}
        nil -> {kept, [doc_id | missed]}
      end
    end)
    |> then(fn {kept, missed} -> {Enum.reverse(kept), Enum.reverse(missed)} end)
  end

  # `doc_id` is NOT unique across types — a `tag` document and a `task`
  # document can both be named `authoring-excellence`. The batch read is
  # TYPELESS and keys its result `Map.new(fn d -> {d.doc_id, d} end)`, so when
  # both rows come back the LAST one wins: a task whose name is also a tag can
  # be shadowed out of its own paper's driven-task list, with no error and no
  # short-read signal (task-464b89f30e3f8e41).
  #
  # We know the type we want. So a batch entry that is missing OR is some other
  # type is re-read TYPE-PINNED through `get_document/4`, which carries the
  # SAME clamp stack (dataset + tenancy + owner + grants) plus `type == "task"`
  # — no scope is widened, a shadowed row is simply asked for by its real
  # identity. Bounded: the retry runs only on the batch's misses, normally
  # none. A genuine scope miss still returns nil and lands in `unhydrated`.
  defp resolve_task(docs_by_id, doc_id, dataset, opts) do
    case Map.get(docs_by_id, doc_id) do
      %{type: "task"} = doc ->
        doc

      _shadowed_or_absent ->
        case Content.get_document(doc_id, "task", dataset, opts) do
          {:ok, %{type: "task"} = doc} -> doc
          _ -> nil
        end
    end
  end

  # One hydrated task entry.
  defp entry(doc, kinds) do
    content = doc.content || %{}
    progress = Criteria.progress(content)

    %{
      doc_id: doc.doc_id,
      title: doc.title,
      lifecycle_status: string_or_nil(Map.get(content, "lifecycle_status")),
      via: Enum.uniq(kinds),
      criteria: criteria_rows(content),
      criteria_progress: progress,
      satisfied: progress != nil and progress.met == progress.total
    }
  end

  # The per-claim rows the reverse view shows. Same garbage tolerance as
  # `Criteria`: `met` counts only when EXACTLY `true`; a non-map row renders
  # as an unmet claim with no text rather than crashing the paper page.
  defp criteria_rows(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) -> Enum.map(list, &criterion_row/1)
      _ -> []
    end
  end

  defp criterion_row(%{} = row) do
    %{
      criterion: string_or_nil(Map.get(row, "criterion")),
      met: Map.get(row, "met") == true,
      evidence: string_or_nil(Map.get(row, "evidence"))
    }
  end

  defp criterion_row(_), do: %{criterion: nil, met: false, evidence: nil}

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil
end
