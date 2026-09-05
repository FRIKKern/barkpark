defmodule Barkpark.Plugins.Github.MergeEvents do
  @moduledoc """
  Inbound GitHub `pull_request` webhook handler — the merge-event bridge
  (ledger-merge-criterion-autostamp). It is the initiator PR #3039 left missing:
  #3039 shipped the SAFE close-time merge-gate autostamp seam
  (`Tasks.Close.autostamp_merge_gate/6`), but nothing FIRED it when GitHub merged
  the PR, so a merged task's `merge_gate:true` criterion stayed `met=false` until
  a lead hand-stamped it every wave.

  ## What it does

  On a `pull_request` delivery whose `action == "closed"` AND
  `pull_request.merged == true`, it resolves the PR's `Task: <doc_id>` trailer
  (D11 — the same trailer `pr-task-gate` reads), maps it through
  `Content.get_document/4`, and calls `Tasks.reconcile_merge_gate/3` with the
  merge artifact `%{"prs" => [<number>], "commit" => <merge_sha>}`.

  That reconcile is STAMP-ONLY (it never flips `lifecycle_status`): it flips the
  explicit `merge_gate:true` criterion to `met` with evidence naming the PR,
  merge commit, and trigger source, and leaves EVERY other unmet criterion
  visibly partial — a half-proven task reads merge-gate-met but still open, never
  fully done. The lead keeps close/3's claim/epoch judgment.

  ## Named, idempotent outcomes (criterion 4 — never a silent no-op)

    * `{:ok, :stamped, doc_id, [index]}` — merge-gate criterion(s) flipped met.
    * `{:ok, :already_stamped, doc_id}`  — already met: a replayed/duplicate
      merge event, or a lead already closed. No write, no double evidence.
    * `{:ok, :unflagged_merge_gates, doc_id, [index]}` — nothing carries the
      flag, but these criteria READ as merge gates. Nothing was stamped; the
      indices are named so somebody can flag or stamp them deliberately.
    * `{:ok, :no_marker, doc_id}`        — the task carries NO `merge_gate:true`
      criterion. NAMED, never a text/position/index fallback — so an unmarked
      legacy gate is detectable rather than silently guessed.
    * `{:ok, :no_guardable_marker, doc_id}` — an unmet merge-gate criterion with
      no wording (D56 unguardable): left for a human, never faked.
    * `:no_trailer`                      — no `Task:` line on the PR body.
    * `{:ambiguous_trailer, ids}`        — the PR body carries `Task:` lines for
      MORE THAN ONE distinct task. Refused, not guessed.
    * `{:unknown_task, doc_id}`          — the trailer names a doc that does not
      resolve on the ledger.
    * `:ignored`                         — not a merged close (a plain close, a
      non-merge action, or a non-`pull_request` delivery routed here by mistake).
    * `{:error, reason}`                 — a genuine ledger write failure (e.g.
      `:stale_rev`); the controller answers 5xx so GitHub redelivers. The reconcile
      is replay-safe (a redelivery lands `:already_stamped`).

  ## Trailer grammar

  Matches `pr-task-gate.yml`: a line `Task: <doc_id>`, case-insensitive, doc-id
  charset `[a-z0-9][a-z0-9._/-]*`. All matches are collected and de-duplicated;
  a single distinct id proceeds, several distinct ids are `:ambiguous_trailer`.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Tasks

  @task_type "task"
  @default_dataset "production"
  @reconcile_worker "github-merge"

  # Line-anchored, case-insensitive `Task: <doc_id>` trailer. Mirrors the CI
  # gate's grammar so the two never disagree on what counts as a task reference.
  @trailer_regex ~r/^\s*task:\s*([a-z0-9][a-z0-9._\/-]*)/im

  @type result ::
          {:ok, :stamped, String.t(), [non_neg_integer()]}
          | {:ok, :unflagged_merge_gates, String.t(), [non_neg_integer()]}
          | {:ok, :already_stamped | :no_marker | :no_guardable_marker, String.t()}
          | :ignored
          | :no_trailer
          | {:ambiguous_trailer, [String.t()]}
          | {:unknown_task, String.t()}
          | {:error, term()}

  @doc """
  Handle a decoded GitHub `pull_request` webhook payload. Acts ONLY on a merged
  close; everything else is `:ignored`. See the moduledoc for the full contract.
  """
  @spec handle(map(), keyword()) :: result()
  def handle(payload, opts \\ []) when is_map(payload) do
    pr = Map.get(payload, "pull_request")

    cond do
      Map.get(payload, "action") != "closed" ->
        :ignored

      not (is_map(pr) and Map.get(pr, "merged") == true) ->
        # Closed without merging (declined PR) → nothing landed, nothing to stamp.
        :ignored

      true ->
        reconcile_for_pr(pr, opts)
    end
  end

  defp reconcile_for_pr(pr, opts) do
    case task_ids(pr) do
      [] ->
        :no_trailer

      [doc_id] ->
        reconcile_task(doc_id, pr, opts)

      [_ | _] = ids ->
        # More than one distinct task referenced — which one did this PR land?
        # Refuse rather than guess (a wrong stamp is worse than a named refusal).
        {:ambiguous_trailer, ids}
    end
  end

  defp reconcile_task(doc_id, pr, opts) do
    dataset = Keyword.get(opts, :dataset, @default_dataset)

    case fetch_task(doc_id, dataset, opts) do
      {:ok, %Document{} = doc} ->
        landed = landed_digest(pr)

        case Tasks.reconcile_merge_gate(doc.id, landed,
               worker_id: @reconcile_worker,
               dataset: dataset
             ) do
          {:ok, :stamped, indices} -> {:ok, :stamped, doc_id, indices}
          {:ok, :unflagged_merge_gates, ix} -> {:ok, :unflagged_merge_gates, doc_id, ix}
          {:ok, tag} -> {:ok, tag, doc_id}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        {:unknown_task, doc_id}
    end
  end

  # `%{"prs" => [<number>], "commit" => <merge_sha>}` — the merge artifact the
  # reconcile evidence names. Only non-nil components are threaded.
  defp landed_digest(pr) do
    base =
      case Map.get(pr, "number") do
        n when is_integer(n) -> %{"prs" => [n]}
        _ -> %{}
      end

    case Map.get(pr, "merge_commit_sha") do
      sha when is_binary(sha) and sha != "" -> Map.put(base, "commit", sha)
      _ -> base
    end
  end

  # All distinct `Task: <doc_id>` references on the PR body, in first-seen order.
  defp task_ids(pr) do
    body =
      case Map.get(pr, "body") do
        b when is_binary(b) -> b
        _ -> ""
      end

    @trailer_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [id] -> id end)
    |> Enum.uniq()
  end

  # Resolve the doc_id draft-first, then published (an adopted+published task),
  # under the caller's tenant scope. Mirror of `InboundEvents.fetch_existing/3`.
  defp fetch_task(doc_id, dataset, opts) do
    with :none <- lookup(Content.draft_id(doc_id), dataset, opts) do
      lookup(Content.published_id(doc_id), dataset, opts)
    end
  end

  defp lookup(id, dataset, opts) do
    case Content.get_document(id, @task_type, dataset, opts) do
      {:ok, %Document{} = doc} -> {:ok, doc}
      _ -> :none
    end
  end
end
