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

  ## Bounding

  One inbound hop (no traversal), capped at the graph engine's existing
  `Content.Graph.node_budget/0` — the same 1000-node ceiling `traverse/2`
  enforces — with a `truncated` flag when the cap bites, mirroring the
  traverse contract.
  """

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
  expectation state. Returns `%{tasks: [driven_task], truncated: boolean}`;
  an unresolvable paper yields `%{tasks: [], truncated: false}` (nothing
  references a non-existent doc — the `reverse_referencers/2` posture).

  Opts are the standard scope keywords (`:dataset`, `:workspace_id`,
  `:project_id`, …), passed through to the graph read and the task
  hydration alike.
  """
  @spec driven_tasks(binary(), keyword()) :: %{tasks: [driven_task()], truncated: boolean()}
  def driven_tasks(paper_id, opts \\ []) when is_binary(paper_id) do
    referencers =
      paper_id
      |> Content.published_id()
      |> Graph.reverse_referencers(opts)
      |> Enum.filter(&(&1.type == "task"))

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

    tasks =
      doc_ids
      |> Enum.take(budget)
      |> Enum.flat_map(&entry(&1, Map.fetch!(kinds_by_doc, &1), opts))

    %{tasks: tasks, truncated: truncated}
  end

  # One task entry, hydrated under the caller's scope. A source that vanished
  # between the edge read and this fetch (or that the scope rejects) drops —
  # the same fail-closed posture as reverse_referencers' own hydration.
  defp entry(doc_id, kinds, opts) do
    dataset = Keyword.get(opts, :dataset, "production")

    case Content.get_document(doc_id, "task", dataset, opts) do
      {:ok, doc} ->
        content = doc.content || %{}
        progress = Criteria.progress(content)

        [
          %{
            doc_id: doc.doc_id,
            title: doc.title,
            lifecycle_status: string_or_nil(Map.get(content, "lifecycle_status")),
            via: Enum.uniq(kinds),
            criteria: criteria_rows(content),
            criteria_progress: progress,
            satisfied: progress != nil and progress.met == progress.total
          }
        ]

      _ ->
        []
    end
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
