defmodule Barkpark.Plugins.Github.MirrorJob do
  @moduledoc """
  The outbound heart of the GitHub bridge: a debounced, per-task Oban worker
  that reconciles ONE Barkpark task to its mirror GitHub Issue (epic charter
  Wave 2, D2/D3/D7/D8/D9).

  ## Level-triggered, not edge-triggered (D2)

  The drain worker does NOT replay a mutation — it `enqueue/1`s a per-task job
  keyed `unique` on `{doc_id, dataset}` and scheduled `30s` out. A burst of
  edits to the same task therefore COALESCES into one job (the `unique` clause
  spans `:available`/`:scheduled`/`:executing`), and that single job reads the
  task's CURRENT full state and converges the issue to it. GitHub is a
  non-CAS external target, so desired-state reconcile — not event replay — is
  the correct shape: reorder-tolerance, debounce and coalescing all fall out
  for free.

  ## reconcile/2 — the convergence step

    1. Load the task's CURRENT state DRAFT-FIRST (contract #2): `content.github`
       bookkeeping is written to the DRAFT row by `Link.put`, so reading the
       published perspective would miss `github.issue` and CREATE a duplicate
       issue. Absent task → `{:cancel, :task_gone}`.
    2. `Link.get/1`. A `state: "detached"` link → `{:cancel, :detached}`: the
       issue was deleted/transferred out-of-band and we NEVER recreate it (D7).
    3. `Link.synced?/1` fast-path. This rarely fires in steady state (the stamp
       write itself bumps `_rev`, so `synced_rev` lags — D3 AMENDED). It is a
       cheap COALESCE guard for a duplicate job, NOT the loop guard — the loop
       is broken structurally by the `source="github"` outbox exclusion (D4).
    4. `Projection.task_to_issue/1` → the desired issue shape (pure).
    5. No stored integer `issue` → CREATE via `Client.create_issue/3`, then
       stamp `Link.put(repo, issue, synced_rev, state: "synced")`.
    6. A stored integer `issue` → one idempotent `Client.update_issue/4`
       field-set PATCH (title/body/labels/state[/state_reason]) that covers
       open/reopen/close in a single call, then stamp `Link.put(synced_rev:)`
       (the merge preserves repo/issue).

  ## Error classification (contract #3, D8's fixed 4-type set, D9)

    * `RateLimitError{retry_after}`          → `{:snooze, max(s, 1)}` (retryable, D9)
    * `NetworkError{reason: {:http, 4xx}}`   → `{:cancel, {:client_error, s}}`
      (a 422/validation error is PERMANENT — dead-letter it, never retry forever)
    * other `NetworkError` (transport / exhausted 5xx) → `{:error, err}` (Oban retries)
    * `NotFound` on UPDATE → stamp `state: "detached"`, then `{:cancel, :detached}`
      (deleted/transferred issue — never recreated, D7)
    * `NotFound` on CREATE → `{:cancel, :repo_not_found}` (misconfigured repo)
    * `AuthError`                            → `{:error, err}` (retryable, capped by max_attempts)

  ## Loop immunity

  The `Link.put` stamp writes through the Content upsert path stamped
  `source: :github`, and the wave-1 outbox reader EXCLUDES `source="github"`
  rows — so the bookkeeping write can never echo back out as a fresh mirror
  (D4 cut #2). This job never reads a GitHub field back into a task (D5).
  """

  use Oban.Worker,
    queue: :github_mirror,
    max_attempts: 5,
    unique: [
      keys: [:doc_id, :dataset],
      states: [:available, :scheduled, :executing],
      period: 60
    ]

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Link, Projection}
  alias Barkpark.Plugins.Github.Client

  alias Barkpark.Plugins.Github.Errors.{
    AuthError,
    NetworkError,
    NotFound,
    RateLimitError
  }

  @config_key Barkpark.Plugins.Github
  @task_type "task"
  @debounce_seconds 30

  @doc """
  Build and insert a debounced mirror job for `doc_id` in `dataset`.

  Scheduled `#{@debounce_seconds}s` out and `unique` on `{doc_id, dataset}`, so
  a burst of edits to the same task collapses into ONE reconcile (D2). The
  hand-off is fast — it only constructs and inserts the job; the actual GitHub
  work happens when the job runs and re-reads the task's current state.
  """
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(doc_id) when is_binary(doc_id), do: enqueue(doc_id, "production")

  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(doc_id, dataset) when is_binary(doc_id) and is_binary(dataset) do
    %{"doc_id" => doc_id, "dataset" => dataset}
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"doc_id" => doc_id, "dataset" => dataset}}) do
    reconcile(doc_id, dataset)
  end

  @doc """
  Reconcile ONE task to its mirror GitHub Issue. The public entry point of the
  outbound engine (see the module doc for the full step list and error map).

  Reads the task's CURRENT state, so a snoozed/retried job always converges to
  the latest ledger truth — no intent is lost. `opts` are forwarded to the
  `Client` HTTP verbs (tests inject `:max_retries`/`:retry_delay_ms`/`:base_url`);
  the mirror repo and API base come from plugin config, not from `opts`.

  Returns `:ok`, or an Oban control tuple: `{:snooze, s}`, `{:cancel, reason}`,
  or `{:error, reason}`.
  """
  @spec reconcile(String.t(), String.t(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, term()} | {:error, term()}
  # @canonical capability:github-mirror-reconcile aka:mirror,sync,issue-push,reconcile doc:.claude/workflows/bp-github-bridge-epic-charter.md
  def reconcile(doc_id, dataset, opts \\ []) when is_binary(doc_id) and is_binary(dataset) do
    case load_task(doc_id, dataset) do
      nil ->
        {:cancel, :task_gone}

      %Document{} = task_doc ->
        link = Link.get(task_doc)

        cond do
          detached?(link) ->
            {:cancel, :detached}

          Link.synced?(task_doc) ->
            :ok

          true ->
            converge(doc_id, dataset, task_doc, link, opts)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Convergence
  # ---------------------------------------------------------------------------

  defp converge(doc_id, dataset, task_doc, link, opts) do
    desired = Projection.task_to_issue(task_doc)
    repo = repo()
    rev = rev_of(task_doc)

    case issue_number(link) do
      nil -> create(doc_id, dataset, repo, desired, rev, opts)
      num when is_integer(num) -> update(doc_id, dataset, repo, num, desired, rev, opts)
    end
  end

  defp create(doc_id, dataset, repo, desired, rev, opts) do
    params = %{title: desired.title, body: desired.body, labels: desired.labels}

    case Client.create_issue(repo, params, opts) do
      {:ok, %{"number" => num}} when is_integer(num) ->
        stamp(doc_id, dataset, %{repo: repo, issue: num, synced_rev: rev, state: "synced"})

      {:ok, other} ->
        # A 2xx with no issue number is a GitHub contract violation we can't
        # anchor idempotency on — retry rather than strand an unrecorded issue.
        Logger.error("github mirror create: 2xx without issue number: #{inspect(other)}")
        {:error, :missing_issue_number}

      {:error, err} ->
        classify(err, :create, doc_id, dataset)
    end
  end

  defp update(doc_id, dataset, repo, num, desired, rev, opts) do
    params =
      %{
        title: desired.title,
        body: desired.body,
        labels: desired.labels,
        state: desired.state
      }
      |> put_non_nil(:state_reason, desired.state_reason)

    case Client.update_issue(repo, num, params, opts) do
      {:ok, _} ->
        stamp(doc_id, dataset, %{synced_rev: rev})

      {:error, err} ->
        classify(err, :update, doc_id, dataset)
    end
  end

  # ---------------------------------------------------------------------------
  # Error classification (contract #3, D8/D9)
  # ---------------------------------------------------------------------------

  defp classify(%RateLimitError{retry_after: s}, _mode, _doc_id, _dataset) do
    # D9: retryable, never dead-lettered. Level-triggered reconcile means the
    # snoozed job re-reads current state when it runs, so no intent is lost.
    {:snooze, max(s || 0, 1)}
  end

  defp classify(%NetworkError{reason: {:http, status}} = _err, _mode, _doc_id, _dataset)
       when status in 400..499 do
    # A permanent client error (422 validation, 400 bad request). Retrying it
    # forever is pointless — dead-letter it (contract #3).
    {:cancel, {:client_error, status}}
  end

  defp classify(%NetworkError{} = err, _mode, _doc_id, _dataset) do
    # Transport failure or an exhausted 5xx — genuinely transient. Let Oban
    # apply its backoff (capped by max_attempts).
    {:error, err}
  end

  defp classify(%NotFound{}, :update, doc_id, dataset) do
    # The issue was deleted/transferred out-of-band. Mark it detached and NEVER
    # recreate it (D7 — recreating would fight a human).
    _ = stamp(doc_id, dataset, %{state: "detached"})
    {:cancel, :detached}
  end

  defp classify(%NotFound{}, :create, _doc_id, _dataset) do
    # 404 on CREATE means the mirror repo itself is missing/misconfigured —
    # there is nothing to detach; dead-letter until config is fixed.
    {:cancel, :repo_not_found}
  end

  defp classify(%AuthError{} = err, _mode, _doc_id, _dataset) do
    # Auth may be transiently wrong (token refresh raced, install reprovisioned)
    # — retryable, capped by max_attempts.
    {:error, err}
  end

  defp classify(other, _mode, _doc_id, _dataset), do: {:error, other}

  # ---------------------------------------------------------------------------
  # Link stamp
  # ---------------------------------------------------------------------------

  # Persist the bookkeeping stamp. On the (narrow) chance the stamp write fails
  # AFTER a successful issue write, surface `{:error, _}` so Oban retries — a
  # redundant idempotent PATCH on replay converges (D3 amended), which is safe
  # for UPDATE; a failed CREATE stamp risks one duplicate issue on retry, logged.
  defp stamp(doc_id, dataset, github) do
    case Link.put(doc_id, dataset, github) do
      {:ok, %Document{}} ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "github mirror stamp failed for #{doc_id}/#{dataset}: #{inspect(reason)}"
        )

        err
    end
  end

  # ---------------------------------------------------------------------------
  # Task load (draft-first — contract #2)
  # ---------------------------------------------------------------------------

  # Read the task's CURRENT full state, DRAFT row first: `Link.put` writes the
  # `content.github` bookkeeping to the draft, so the published perspective
  # would miss `github.issue` and re-CREATE the issue. `doc_id` is normalised to
  # its published form so the projection's `Task: <doc_id>` trailer and title
  # fallback never carry the `drafts.` prefix (a draft row stores the prefixed id).
  defp load_task(doc_id, dataset) do
    published = Content.published_id(doc_id)

    doc =
      case Content.get_document(Content.draft_id(published), @task_type, dataset, []) do
        {:ok, %Document{} = d} -> d
        _ -> unwrap(Content.get_document(published, @task_type, dataset, []))
      end

    case doc do
      %Document{} = d -> %{d | doc_id: published}
      _ -> nil
    end
  end

  defp unwrap({:ok, %Document{} = d}), do: d
  defp unwrap(_), do: nil

  # ---------------------------------------------------------------------------
  # Small helpers
  # ---------------------------------------------------------------------------

  defp detached?(link) when is_map(link), do: Map.get(link, "state") == "detached"
  defp detached?(_), do: false

  defp issue_number(link) when is_map(link) do
    case Map.get(link, "issue") do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp issue_number(_), do: nil

  defp rev_of(%Document{rev: rev}), do: rev

  defp put_non_nil(map, _key, nil), do: map
  defp put_non_nil(map, key, value), do: Map.put(map, key, value)

  # The mirror repo ("owner/name"). Read directly from plugin config for now;
  # slice 2's `Github.Settings.repo/0` will centralise the env→DB resolution.
  # Reading the same config key here keeps this slice parallel-safe with slice 2.
  defp repo do
    Application.get_env(:barkpark, @config_key, [])[:repo]
  end
end
