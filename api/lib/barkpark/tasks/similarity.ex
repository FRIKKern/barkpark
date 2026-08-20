defmodule Barkpark.Tasks.Similarity do
  @moduledoc """
  Tier-1 dedup similarity for the find-or-create gate (task-obsession layer 1).

  PURE — no DB, no aliases. Given a new task and a set of candidate tasks, it
  decides which candidates are close enough that the author should be warned or
  blocked before a duplicate is filed. The DB adapter (the create-path hook)
  fetches the candidate set and the parent index; every judgement here is a pure
  function of its arguments, so the whole decision is unit-testable offline.

  ## Why structural exclusion is the primary lever

  Calibration against the live backlog (`tob-w1-judge-calibration`) found that
  **87% of lexically-similar task pairs are benign structure, not duplication**:
  same-parent siblings (one epic decomposed into slices) and parent-chain pairs
  (a milestone and one of its steps). Similarity alone massively over-flags, so
  those two classes are excluded BEFORE any threshold is applied — otherwise the
  gate would refuse nearly every legitimate epic-seeding create. What survives
  exclusion is the "cross" residue, bucketed by similarity:

      sim >= @refuse   → refuse   (near-identical; block the create)
      @advise..@refuse → advise   (gray zone; surface as a warning — this is the
                                    band the tier-2 LLM judge will adjudicate)
      sim <  @advise   → ignore

  Scoring mirrors the calibrated generator exactly:
  `0.7 * Jaccard(title+description tokens) + 0.3 * Jaccard(labels)`.

  ## Cost: the new task is tokenized ONCE per assessment

  `assess/3` tokenizes the NEW task once (`probe/1`) and reuses that token set
  for every candidate, so the work is `O(N + |new|)`, not `O(N × |new|)`. It used
  to recompute `tokens(new_task)` inside the per-candidate loop, which made a
  single `bp task create` cost proportional to the DISTINCT TOKEN COUNT of its
  description times the whole backlog — measured 2026-07-30 as a fixed 20–30 s
  stall that lost the race against the 15 s DB-checkout budget and handed the
  owner `internal_error / "unknown error"`.

  That is a perf claim, so it is gated by counting the work rather than the
  clock: every `tokens/1` call emits `[:barkpark, :tasks, :similarity, :tokenize]`,
  and `similarity_test.exs` asserts an `assess/3` over N candidates tokenizes
  exactly `N + 1` times. Wall-clock assertions on a shared host measure the load,
  not the code.
  """

  # Calibrated thresholds (tob-w1-judge-calibration). @refuse is deliberately
  # high — on a clean backlog nothing reaches it, so tier-1 hard-refuses only a
  # true near-duplicate; the gray zone is advisory until the judge is wired.
  @refuse 0.55
  @advise 0.30

  # A hard REFUSE additionally requires this many shared title+description
  # tokens. Jaccard over-fires on ultra-thin text — two tasks titled "multi-a"
  # and "multi-b" share the single token "multi" and score a full 1.0, which is
  # not evidence of duplication. A genuine duplicate shares many words. Below
  # this floor a high score is downgraded to ADVISE (surfaced, never blocking).
  @min_refuse_shared 3

  @title_weight 0.7
  @label_weight 0.3

  @stopwords MapSet.new(~w(a an the of to for and or in on at by with from is are be this that
                  these those it its as into per via not no yes we our you your they their
                  can will should must task tasks add fix update use make build run new when
                  then than also each any all one two both only same onto over under out off
                  up down))

  @type task :: %{
          optional(:id) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:labels) => [String.t()],
          optional(:parent) => String.t() | nil,
          optional(:lifecycle) => String.t() | nil,
          optional(any) => any
        }

  @type match :: %{
          id: String.t(),
          sim: float(),
          structural: :cross | :sibling | :chain,
          lifecycle: String.t() | nil,
          verdict: :refuse | :advise | :excluded
        }

  @doc "Default thresholds, exposed so callers/tests share one source of truth."
  @spec thresholds() :: %{refuse: float(), advise: float()}
  def thresholds, do: %{refuse: @refuse, advise: @advise}

  @doc """
  Assess a new task against candidates. Returns
  `%{refuse: [match], advise: [match], excluded: [match]}`, each list sorted by
  descending similarity.

  Options:
    * `:distinct_from` — list of candidate ids the author explicitly declared
      distinct (D1); excluded from refuse/advise and reported under `:excluded`
      with verdict `:excluded`.
    * `:parent_index` — `%{normalized_id => normalized_parent_id}` for ancestor
      walking (chain detection). Defaults to one built from the candidates + the
      new task's own parent link.
    * `:refuse` / `:advise` — threshold overrides (defaults above).
  """
  @spec assess(task, [task], keyword) :: %{
          refuse: [match],
          advise: [match],
          excluded: [match]
        }
  def assess(new_task, candidates, opts \\ []) do
    refuse_at = Keyword.get(opts, :refuse, @refuse)
    advise_at = Keyword.get(opts, :advise, @advise)
    distinct = MapSet.new(Enum.map(Keyword.get(opts, :distinct_from, []), &norm_id/1))
    parent_index = Keyword.get(opts, :parent_index) || build_parent_index([new_task | candidates])

    new_nid = norm_id(field(new_task, :id))

    # Tokenize the new task ONCE, outside the loop — see @moduledoc "Cost".
    probe = probe(new_task)

    matches =
      candidates
      |> Enum.reject(fn c -> norm_id(field(c, :id)) == new_nid end)
      |> Enum.map(fn c -> score(probe, c, parent_index, distinct, refuse_at, advise_at) end)
      |> Enum.reject(&is_nil/1)

    grouped = Enum.group_by(matches, & &1.verdict)

    %{
      refuse: sort(Map.get(grouped, :refuse, [])),
      advise: sort(Map.get(grouped, :advise, [])),
      excluded: sort(Map.get(grouped, :excluded, []))
    }
  end

  # ── scoring one candidate ──────────────────────────────────────────────────

  # The loop-invariant half of a scoring pass: the new task's token and label
  # sets, computed once and carried across every candidate.
  defp probe(new_task) do
    %{
      task: new_task,
      tokens: tokens("#{field(new_task, :title)} #{field(new_task, :description)}"),
      labels: MapSet.new(field(new_task, :labels) || [])
    }
  end

  defp score(probe, cand, parent_index, distinct, refuse_at, advise_at) do
    %{task: new_task, tokens: ta, labels: la} = probe
    tb = tokens("#{field(cand, :title)} #{field(cand, :description)}")
    shared = MapSet.size(MapSet.intersection(ta, tb))
    lb = MapSet.new(field(cand, :labels) || [])
    sim = @title_weight * jaccard(ta, tb) + @label_weight * jaccard(la, lb)

    cid = norm_id(field(cand, :id))
    rel = structural_relation(new_task, cand, parent_index)

    cond do
      MapSet.member?(distinct, cid) ->
        match(cand, sim, rel, :excluded)

      # Benign structure — never a duplicate. Recorded as excluded so the
      # rejection trail can show WHY a similar-looking task was allowed.
      rel in [:sibling, :chain] ->
        match(cand, sim, rel, :excluded)

      # Hard refuse needs both a high score AND enough shared tokens for that
      # score to be trustworthy (thin-content guard).
      sim >= refuse_at and shared >= @min_refuse_shared ->
        match(cand, sim, rel, :refuse)

      sim >= advise_at ->
        match(cand, sim, rel, :advise)

      true ->
        nil
    end
  end

  defp match(cand, sim, rel, verdict) do
    %{
      id: field(cand, :id),
      sim: Float.round(sim, 4),
      structural: rel,
      lifecycle: field(cand, :lifecycle),
      verdict: verdict
    }
  end

  defp sort(list), do: Enum.sort_by(list, & &1.sim, :desc)

  # ── similarity (mirror of gen_candidate_pairs.py) ──────────────────────────

  @doc "0.7·Jaccard(title+desc tokens) + 0.3·Jaccard(labels)."
  @spec similarity(task, task) :: float()
  def similarity(a, b) do
    ta = tokens("#{field(a, :title)} #{field(a, :description)}")
    tb = tokens("#{field(b, :title)} #{field(b, :description)}")
    la = MapSet.new(field(a, :labels) || [])
    lb = MapSet.new(field(b, :labels) || [])
    @title_weight * jaccard(ta, tb) + @label_weight * jaccard(la, lb)
  end

  @doc """
  The token set of a blob of text (downcased, ≤2-char and stopword tokens dropped).

  Emits `[:barkpark, :tasks, :similarity, :tokenize]` with `%{count: 1}` on every
  call. This is the dedup gate's unit of work: it is what made a create cost
  `O(candidates × |description|)`, so the fix is gated by counting these events
  rather than by timing the call.
  """
  def tokens(text) do
    :telemetry.execute([:barkpark, :tasks, :similarity, :tokenize], %{count: 1}, %{})

    (text || "")
    |> String.downcase()
    |> then(&Regex.scan(~r/[a-z0-9]+/, &1))
    |> List.flatten()
    |> Enum.reject(fn t -> String.length(t) <= 2 or MapSet.member?(@stopwords, t) end)
    |> MapSet.new()
  end

  @doc false
  def jaccard(a, b) do
    if MapSet.size(a) == 0 or MapSet.size(b) == 0 do
      0.0
    else
      inter = MapSet.size(MapSet.intersection(a, b))
      union = MapSet.size(MapSet.union(a, b))
      inter / union
    end
  end

  # ── structural relation ────────────────────────────────────────────────────

  @doc """
  `:sibling` (same parent), `:chain` (one is an ancestor of the other, or they
  share an ancestor), else `:cross`. `parent_index` maps normalized id → parent.
  """
  @spec structural_relation(task, task, map) :: :sibling | :chain | :cross
  def structural_relation(a, b, parent_index) do
    pa = norm_id(field(a, :parent))
    pb = norm_id(field(b, :parent))
    na = norm_id(field(a, :id))
    nb = norm_id(field(b, :id))

    anc_a = ancestors(na, parent_index)
    anc_b = ancestors(nb, parent_index)

    cond do
      pa != "" and pa == pb -> :sibling
      MapSet.member?(anc_a, nb) or MapSet.member?(anc_b, na) -> :chain
      not MapSet.disjoint?(anc_a, anc_b) -> :chain
      true -> :cross
    end
  end

  @doc false
  def build_parent_index(tasks) do
    for t <- tasks, id = norm_id(field(t, :id)), id != "", into: %{} do
      {id, norm_id(field(t, :parent))}
    end
  end

  # Walk up to 6 levels; guard against cycles.
  defp ancestors(nid, parent_index) do
    Enum.reduce_while(1..6, {MapSet.new(), nid}, fn _, {acc, cur} ->
      case Map.get(parent_index, cur, "") do
        "" ->
          {:halt, {acc, cur}}

        p ->
          if MapSet.member?(acc, p),
            do: {:halt, {acc, cur}},
            else: {:cont, {MapSet.put(acc, p), p}}
      end
    end)
    |> elem(0)
  end

  @doc "Strip the `drafts.` id prefix so a draft doc's id matches a parent_id ref."
  @spec norm_id(String.t() | nil) :: String.t()
  def norm_id(nil), do: ""
  def norm_id("drafts." <> rest), do: rest
  def norm_id(id) when is_binary(id), do: id
  def norm_id(_), do: ""

  # Read a field by atom OR string key, tolerating both task-map shapes.
  defp field(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      v -> v
    end
  end
end
