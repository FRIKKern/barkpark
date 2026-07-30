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

  ## When the gate cannot run: it SAYS SO (it does not silently pass)

  This used to fail OPEN and silently: any candidate-fetch error yielded an empty
  candidate set, so the create returned `200 OK` having never actually checked
  for a duplicate. That is the exact lie this epic exists to kill — a verb
  reporting success on a claim ("this task is not a duplicate") it never
  computed, on the ledger the epic is audited on.

  It now fails LOUD. A candidate fetch that errors or times out returns
  `{:error, {:halted, msg}}` (409) whose message names precisely what could not
  be done and how to proceed. The owner's escape hatch is
  **`content.dedup_bypass: true`** — file it unchecked, deliberately, and the
  flag persists on the document as the trail (same shape as `distinct_from`).

  Two honest caveats, both live:

    * `{:halted, …}` is a borrowed code. A dedicated `dedup_unavailable` code
      belongs in `Barkpark.Content.Errors`, which is another slice's fence this
      wave — filed as `pds-bl-dedup-unavailable-error-code`. The *message* is
      already exact; only the machine code is generic.
    * The dedup query is bounded (`@query_timeout_ms`) so it fails fast and named
      instead of eating the request's 15 s DB-checkout budget and poisoning the
      INSERT that follows. That closes dedup's share of the window in which the
      `bp` CLI abandons a request at 30 s while the server keeps executing it
      (measured up to 61 s); the rest of the write path is still unbounded, which
      is tracked as `pds-bl-cli-budget-window`.
  """
  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Judge, Similarity}

  # Bound the worst-case scan. MEASURED 2026-07-30 (`bp doc ls task --all -o json`
  # against guerrilla, `production`): 3,793 published `type:task` rows, ~4.1k
  # counting draft twins — NOT the "hundreds" this cap was calibrated against in
  # #1210. The limit is therefore live, not theoretical: the corpus is inside one
  # order of magnitude of it. An FTS/trigram pre-filter is still the real answer
  # (tier-2); until then the cost is held down by projecting the candidate row
  # (below) instead of hauling full content JSONB, and by tokenizing the new task
  # once (Similarity.probe/1).
  @candidate_limit 5000

  # The dedup scan gets its OWN budget, well inside the request's 15 s DB
  # checkout. Without it the scan raced that budget and the FOLLOW-UP insert was
  # the statement that blew up — so the owner saw `internal_error / unknown
  # error` from a write that had actually been starved by the read.
  @query_timeout_ms 5_000

  @doc """
  `:ok`, `{:error, {:duplicate_task, payload}}` when a new task duplicates an
  existing one, or `{:error, {:halted, message}}` when the gate could not run at
  all (the message names what could not be done — it never passes silently).
  Only fires for `type == "task"` with **no `prev_doc`** (a genuine birth —
  updates/autosaves/publishes are never gated). All other shapes → `:ok`.
  """
  @spec check_new_task(String.t(), map(), String.t(), Document.t() | nil, keyword()) ::
          :ok | {:error, {:duplicate_task, map()}} | {:error, {:halted, String.t()}}
  def check_new_task("task", attrs, dataset, nil, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    new_task = to_task(attrs, content)

    cond do
      # A task with no textual signal (no title/description) can't be judged —
      # let it through rather than compare empty strings.
      String.trim("#{new_task.title} #{new_task.description}") == "" ->
        :ok

      # The author has consciously chosen to file without the gate. Unlike the
      # old silent fail-open this is the OWNER's claim, not the server's, and it
      # persists on the document as the trail.
      bypass?(content) ->
        :ok

      true ->
        gate(new_task, content, dataset, opts)
    end
  end

  def check_new_task(_type, _attrs, _dataset, _prev_doc, _opts), do: :ok

  defp gate(new_task, content, dataset, opts) do
    distinct =
      string_list(Map.get(content, "distinct_from") || Map.get(content, :distinct_from))

    case fetch_candidates(dataset, opts) do
      {:degraded, reason} ->
        {:error, {:halted, degraded_message(reason)}}

      {:ok, candidates} ->
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

  # The refusal SAYS WHAT IT COULD NOT DO, in the response body, and names the
  # one action that gets the owner unstuck. Never `unknown error`.
  defp degraded_message(reason) do
    "task dedup gate could not complete: #{reason}. The create was REFUSED rather " <>
      "than filed unchecked — no duplicate check ran, so nothing here claims this " <>
      "task is new. Retry, or resend with content.dedup_bypass: true to file it " <>
      "deliberately without the duplicate check."
  end

  defp bypass?(content) do
    case Map.get(content, "dedup_bypass") || Map.get(content, :dedup_bypass) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

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

  # ── candidate fetch ────────────────────────────────────────────────────────

  # `{:ok, candidates}` or `{:degraded, reason}` — NEVER a silently-empty list.
  #
  # WHAT THIS QUERY CHANGED, said out loud (no silent narrowing):
  #
  #   * It projects the five scored fields instead of the whole `content` JSONB.
  #     A task row's content carries `brief`, `acceptance_criteria`,
  #     `disposition_reason` … none of which is scored; hauling them for 4.1k
  #     rows was most of the cost. Detection is UNCHANGED — Similarity only ever
  #     read title/description/labels/parent_id/lifecycle_status.
  #   * `DISTINCT ON` the canonical (drafts-stripped) id collapses a
  #     draft/published TWIN pair to one row, preferring the published one.
  #     Detection is UNCHANGED here too: both rows normalize to the same id and
  #     scored identically, so the twin only ever bought a duplicate entry in
  #     `similar` and a second scoring pass. A task that exists ONLY as a draft
  #     still has exactly one row and is still detected.
  #
  # So: no duplicate that was caught before goes uncaught now. Only the cost and
  # the double-reporting are gone.
  defp fetch_candidates(dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    timeout = Keyword.get(opts, :dedup_timeout_ms, @query_timeout_ms)

    query =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        # Cancelled/abandoned work must never block a legitimate re-attempt
        # (acceptance criterion 4). Done tasks stay in — a match against a done
        # task is a real "already landed" signal.
        where: fragment("COALESCE(?->>'lifecycle_status', '')", d.content) != "cancelled",
        distinct: [asc: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id)],
        # Second key: `false` sorts before `true`, so the PUBLISHED row of a twin
        # pair wins the DISTINCT ON.
        order_by: [asc: fragment("? LIKE 'drafts.%'", d.doc_id)],
        select: %{
          doc_id: d.doc_id,
          title: d.title,
          description: fragment("?->>'description'", d.content),
          labels: fragment("?->'labels'", d.content),
          parent: fragment("?->>'parent_id'", d.content),
          lifecycle: fragment("?->>'lifecycle_status'", d.content)
        },
        limit: @candidate_limit
      )
      |> maybe_filter_dataset(dataset)
      |> Scope.scope_to_workspace(workspace_id, project_id)

    {:ok, query |> Repo.all(timeout: timeout) |> Enum.map(&row_to_task/1)}
  rescue
    e ->
      Logger.warning("Tasks.Dedup degraded: candidate fetch failed: #{inspect(e)}")
      {:degraded, reason_phrase(e, Keyword.get(opts, :dedup_timeout_ms, @query_timeout_ms))}
  catch
    :exit, reason ->
      Logger.warning("Tasks.Dedup degraded: candidate fetch exited: #{inspect(reason)}")
      {:degraded, "the backlog scan was cut off by the database"}
  end

  defp reason_phrase(%DBConnection.ConnectionError{}, timeout),
    do: "the backlog scan did not finish inside its #{timeout}ms budget"

  defp reason_phrase(%{__struct__: mod}, _timeout),
    do: "the backlog scan failed (#{inspect(mod)})"

  defp reason_phrase(_, _timeout), do: "the backlog scan failed"

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

  # The projected row IS the scored shape — no JSONB decoding left to do beyond
  # the `labels` array.
  defp row_to_task(row) do
    %{
      id: row.doc_id,
      title: row.title || "",
      description: row.description,
      labels: string_list(row.labels),
      parent: row.parent,
      lifecycle: row.lifecycle
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
