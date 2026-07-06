defmodule Barkpark.Tasks.Dedup do
  @moduledoc """
  Find-or-create gate for NEW task births (task-obsession layer 1).

  The DB adapter around the pure `Barkpark.Tasks.Similarity` decision: on a new
  `kind:task` document, fetch the candidate backlog (scoped), score it, and
  REFUSE the create if a near-duplicate survives structural exclusion — unless
  the author declared it distinct.

  ## Escape hatches ride existing content fields (no new API/CLI surface)

    * **`content.parent_id`** — a task filed under a parent is automatically
      sibling-excluded from its epic peers (structural exclusion in Similarity).
      This subsumes a `--sibling-of` flag: epic seeding just sets `parent_id`.
    * **`content.distinct_from`** — a list of ids the author has consciously
      declared distinct (D1). It is BOTH the escape hatch AND the persisted,
      queryable rejection trail (acceptance criterion 3): it lives in the doc's
      content, so a `bp task get` / query shows exactly which matches were waved
      through and by whose decision.

  A bogus `distinct_from` id cannot bypass a real duplicate: it only removes the
  named candidate from consideration, so any OTHER refusing candidate still
  blocks. That is the D1 "must name a real candidate" property, enforced by
  construction rather than by a separate check.

  ## Fail-open

  Any error fetching candidates yields an EMPTY candidate set, so the create
  proceeds. A dedup query hiccup must never block legitimate work — the gate is
  a guard rail, not a single point of failure. Only a definitively-computed
  refusal blocks.
  """
  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Judge, Similarity}

  # Bound the worst-case scan. The backlog is small (hundreds); this caps a
  # pathological corpus without an FTS pre-filter, which tier-2 can add later.
  @candidate_limit 5000

  @doc """
  `:ok`, or `{:error, {:duplicate_task, payload}}` when a new task duplicates an
  existing one. Only fires for `type == "task"` with **no `prev_doc`** (a genuine
  birth — updates/autosaves/publishes are never gated). All other shapes → `:ok`.
  """
  @spec check_new_task(String.t(), map(), String.t(), Document.t() | nil, keyword()) ::
          :ok | {:error, {:duplicate_task, map()}}
  def check_new_task("task", attrs, dataset, nil, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    new_task = to_task(attrs, content)

    # A task with no textual signal (no title/description) can't be judged —
    # let it through rather than compare empty strings.
    if String.trim("#{new_task.title} #{new_task.description}") == "" do
      :ok
    else
      distinct =
        string_list(Map.get(content, "distinct_from") || Map.get(content, :distinct_from))

      candidates = fetch_candidates(dataset, opts)

      assessment =
        Similarity.assess(new_task, candidates, distinct_from: distinct)

      # Tier-2 (task-obsession layer 2): the gray-zone `advise` matches are the
      # ones tier-1 is unsure about. When a judge is configured, ask it; a
      # confident duplicate/already_landed verdict escalates the match to a hard
      # refuse. Everything fails open — no judge, or a judge error, leaves the
      # tier-1 verdict untouched.
      {escalated, remaining_advise} = judge_escalate(new_task, candidates, assessment.advise)
      refuse = assessment.refuse ++ escalated

      case refuse do
        [] ->
          :ok

        _ ->
          {:error,
           {:duplicate_task,
            %{
              message:
                "this task looks like an existing one — claim/extend it, or pass " <>
                  "distinct_from: [\"<id>\"] to confirm it is different",
              similar: Enum.map(refuse, &present/1),
              advise: Enum.map(remaining_advise, &present/1)
            }}}
      end
    end
  end

  def check_new_task(_type, _attrs, _dataset, _prev_doc, _opts), do: :ok

  # ── tier-2 judge escalation (fail-open) ────────────────────────────────────

  # A judged `duplicate`/`already_landed` needs at least this confidence to
  # escalate an advise match to a hard refuse.
  @judge_confidence 0.7

  # Returns {escalated, remaining_advise}. No judge configured → escalate
  # nothing (tier-1 stands). The advise band is top-K-bounded, so this is a
  # handful of calls at most, only on the gray-zone matches.
  defp judge_escalate(_new_task, _candidates, []), do: {[], []}

  defp judge_escalate(new_task, candidates, advise) do
    if Judge.configured?() do
      by_id = Map.new(candidates, fn c -> {Similarity.norm_id(Map.get(c, :id)), c} end)

      Enum.split_with(advise, fn match ->
        escalate?(new_task, Map.get(by_id, Similarity.norm_id(match.id)))
      end)
    else
      {[], advise}
    end
  end

  defp escalate?(_new_task, nil), do: false

  defp escalate?(new_task, candidate) do
    case Judge.judge(new_task, candidate) do
      {:ok, %{relation: rel, confidence: conf}}
      when rel in ["duplicate", "already_landed"] and conf >= @judge_confidence ->
        true

      # distinct / expands / low confidence / ANY error → fail open, don't escalate.
      _ ->
        false
    end
  end

  # ── candidate fetch (fail-open) ────────────────────────────────────────────

  defp fetch_candidates(dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    query =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        # Cancelled/abandoned work must never block a legitimate re-attempt
        # (acceptance criterion 4). Done tasks stay in — a match against a done
        # task is a real "already landed" signal.
        where: fragment("COALESCE(?->>'lifecycle_status', '')", d.content) != "cancelled",
        select: %{doc_id: d.doc_id, title: d.title, content: d.content},
        limit: @candidate_limit
      )
      |> maybe_filter_dataset(dataset)
      |> Scope.scope_to_workspace(workspace_id, project_id)

    query
    |> Repo.all()
    |> Enum.map(&row_to_task/1)
  rescue
    e ->
      Logger.warning("Tasks.Dedup fail-open: candidate fetch failed: #{inspect(e)}")
      []
  end

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from([doc: d] in query, where: d.dataset == ^dataset)
  end

  # ── shaping ────────────────────────────────────────────────────────────────

  defp to_task(attrs, content) do
    %{
      id: Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id) || "",
      title: Map.get(attrs, "title") || Map.get(attrs, :title) || "",
      description: get(content, "description"),
      labels: string_list(get(content, "labels")),
      parent: get(content, "parent_id"),
      lifecycle: get(content, "lifecycle_status")
    }
  end

  defp row_to_task(%{doc_id: id, title: title, content: content}) do
    content = content || %{}

    %{
      id: id,
      title: title || "",
      description: get(content, "description"),
      labels: string_list(get(content, "labels")),
      parent: get(content, "parent_id"),
      lifecycle: get(content, "lifecycle_status")
    }
  end

  defp present(%{id: id, sim: sim, structural: rel, lifecycle: lc}) do
    # Report the canonical id (strip the `drafts.` prefix) so the author sees the
    # id they'd reference — and the one they'd pass back in `distinct_from`.
    %{id: Similarity.norm_id(id), similarity: sim, relation: to_string(rel), lifecycle_status: lc}
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, safe_atom(key))
  defp get(_map, _key), do: nil

  defp safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__missing__
  end

  defp string_list(nil), do: []
  defp string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp string_list(other), do: [to_string(other)]
end
