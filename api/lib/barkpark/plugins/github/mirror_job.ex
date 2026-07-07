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
       stamp `Link.put(repo, issue, synced_rev, state: "synced")`. A new issue
       is always born `open`; if the ledger wants it closed, a follow-up PATCH
       converges `state` in the same reconcile (create alone can't birth closed).
    6. A stored integer `issue` → BEFORE the PATCH, `Client.get_issue/3` reads
       the issue's CURRENT state and fingerprints its ledger-owned fields
       (title/body/labels-sorted/state). If a `synced_fingerprint` was stored on
       the last write AND the observed fingerprint differs, the issue drifted
       out-of-band since we last wrote it → RECORD an `out_of_band_edit` conflict
       (ledger wins, but the drift is VISIBLE — D7). This GET reads GitHub values
       ONLY to fingerprint for the record; it NEVER writes a GitHub value into a
       task field (D5). THEN one idempotent `Client.update_issue/4` field-set
       PATCH (title/body/labels/state[/state_reason]) covering open/reopen/close
       in a single call, then stamp `Link.put(synced_rev:, synced_fingerprint:)`
       with the fingerprint of the DESIRED shape (the merge preserves repo/issue)
       so the NEXT reconcile can detect the next drift. Absent a stored
       fingerprint (first-ever mirror, or a pre-slice task) → record nothing this
       pass, just PATCH + stamp the fingerprint (rolls forward, no backfill).

  ## Error classification (contract #3, D8's fixed 4-type set, D9)

    * `RateLimitError{retry_after}`          → `{:snooze, max(s, 1)}` (retryable, D9)
    * `NetworkError{reason: {:http, 4xx}}`   → `{:cancel, {:client_error, s}}`
      (a 422/validation error is PERMANENT — dead-letter it, never retry forever)
    * other `NetworkError` (transport / exhausted 5xx) → `{:error, err}` (Oban retries)
    * `NotFound` on UPDATE (from the pre-PATCH GET or the PATCH itself) → RECORD
      a `detached` conflict, stamp `state: "detached"`, then `{:cancel, :detached}`
      (deleted/transferred issue — surfaced + never recreated, D7)
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
  alias Barkpark.Plugins.Github.{Conflicts, Link, Projection}
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

  Accepts either positional `doc_id`/`dataset` (the wave-2 shape) OR a map
  `%{doc_id:, dataset:, workspace_id:, project_id:}` — the map form is what the
  `DrainWorker` hands the `enqueue_fun` seam, and it carries the outbox event's
  TENANT SCOPE so a non-default-workspace task is loaded and stamped under its
  OWN scope. `workspace_id`/`project_id` are OPTIONAL: absent → the job runs
  against the default workspace/project (back-compatible with the wave-2 args).
  """
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(doc_id) when is_binary(doc_id),
    do: enqueue(%{doc_id: doc_id, dataset: "production"})

  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{doc_id: doc_id} = fields) when is_binary(doc_id) do
    fields
    |> build_args()
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(doc_id, dataset) when is_binary(doc_id) and is_binary(dataset),
    do: enqueue(%{doc_id: doc_id, dataset: dataset})

  # Serialise the Oban args, carrying tenant scope ONLY when present so an
  # absent workspace/project keeps the wave-2 default-scope behavior (the args
  # map stays `%{"doc_id","dataset"}` exactly as before when no scope is threaded).
  defp build_args(fields) do
    %{"doc_id" => fields.doc_id, "dataset" => Map.get(fields, :dataset, "production")}
    |> put_non_nil("workspace_id", Map.get(fields, :workspace_id))
    |> put_non_nil("project_id", Map.get(fields, :project_id))
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"doc_id" => doc_id, "dataset" => dataset} = args}) do
    reconcile(doc_id, dataset, scope_opts(args))
  end

  @doc """
  Reconcile ONE task to its mirror GitHub Issue. The public entry point of the
  outbound engine (see the module doc for the full step list and error map).

  Reads the task's CURRENT state, so a snoozed/retried job always converges to
  the latest ledger truth — no intent is lost. `opts` are forwarded three ways,
  each consumer ignoring the keys it does not use:

    * TENANT SCOPE (`:workspace_id`/`:project_id`) → `load_task` + `Link.put`, so
      a task living in a non-default workspace is found and stamped under its OWN
      scope instead of the default workspace/project. Absent → default scope
      (back-compatible with the wave-2 empty-opts behavior).
    * HTTP tuning (`:max_retries`/`:retry_delay_ms`/`:base_url`) → the `Client`
      verbs (tests inject these). The mirror repo and API base come from plugin
      config, not from `opts`.

  Returns `:ok`, or an Oban control tuple: `{:snooze, s}`, `{:cancel, reason}`,
  or `{:error, reason}`.
  """
  @spec reconcile(String.t(), String.t(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, term()} | {:error, term()}
  # @canonical capability:github-mirror-reconcile aka:mirror,sync,issue-push,reconcile doc:.claude/workflows/bp-github-bridge-epic-charter.md
  def reconcile(doc_id, dataset, opts \\ []) when is_binary(doc_id) and is_binary(dataset) do
    case load_task(doc_id, dataset, opts) do
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
    case repo() do
      repo when is_binary(repo) and repo != "" ->
        desired = Projection.task_to_issue(task_doc)
        rev = rev_of(task_doc)

        case issue_number(link) do
          nil ->
            create(doc_id, dataset, repo, desired, rev, opts)

          num when is_integer(num) ->
            update(doc_id, dataset, repo, num, desired, rev, link, opts)
        end

      _ ->
        # No mirror repo configured — the client verbs would FunctionClause-crash
        # on a nil repo and Oban would retry the crash forever. Dead-letter it
        # until config is fixed (slice 2 centralises the env→DB resolution).
        {:cancel, :repo_unconfigured}
    end
  end

  defp create(doc_id, dataset, repo, desired, rev, opts) do
    params = %{title: desired.title, body: desired.body, labels: desired.labels}

    case Client.create_issue(repo, params, opts) do
      {:ok, %{"number" => num}} when is_integer(num) ->
        after_create(doc_id, dataset, repo, num, desired, rev, opts)

      {:ok, other} ->
        # A 2xx with no issue number is a GitHub contract violation we can't
        # anchor idempotency on — retry rather than strand an unrecorded issue.
        Logger.error("github mirror create: 2xx without issue number: #{inspect(other)}")
        {:error, :missing_issue_number}

      {:error, err} ->
        classify(err, :create, repo, nil, doc_id, dataset, opts)
    end
  end

  # A brand-new GitHub issue is ALWAYS born `open` — the REST create verb has no
  # `state` parameter. When the ledger already wants the task closed (created
  # `done`/`cancelled`, or closed inside the 30s debounce window so create+close
  # coalesce into one reconcile), create alone would strand the issue `open`: the
  # stamp write is `source: :github`, so it never re-enqueues to fix itself.
  # Record the issue number first (so a retry PATCHes, never re-CREATEs), then
  # converge `state` with a follow-up idempotent PATCH in the SAME reconcile.
  defp after_create(doc_id, dataset, repo, num, %{state: "open"}, rev, opts) do
    stamp(doc_id, dataset, %{repo: repo, issue: num, synced_rev: rev, state: "synced"}, opts)
  end

  defp after_create(doc_id, dataset, repo, num, desired, rev, opts) do
    case stamp(doc_id, dataset, %{repo: repo, issue: num, state: "synced"}, opts) do
      # The issue is one HTTP call old and carries no stored fingerprint yet, so
      # there is nothing to drift from — pass a nil link so `update` records no
      # spurious conflict and just PATCHes state + stamps the first fingerprint.
      :ok -> update(doc_id, dataset, repo, num, desired, rev, nil, opts)
      err -> err
    end
  end

  # BEFORE the PATCH, read the issue's CURRENT state and fingerprint its
  # ledger-owned fields; if it drifted out-of-band since our last write, RECORD
  # the conflict (ledger still wins — D7). A GET 404/410 → the issue vanished
  # between drain and reconcile → route to the detached branch via `classify`.
  defp update(doc_id, dataset, repo, num, desired, rev, link, opts) do
    case Client.get_issue(repo, num, opts) do
      {:ok, issue} ->
        maybe_record_drift(repo, num, doc_id, dataset, issue, stored_fingerprint(link))
        patch(doc_id, dataset, repo, num, desired, rev, opts)

      {:error, err} ->
        classify(err, :update, repo, num, doc_id, dataset, opts)
    end
  end

  defp patch(doc_id, dataset, repo, num, desired, rev, opts) do
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
        # Stamp the DESIRED fingerprint alongside the rev, so the next reconcile
        # compares the issue's future state against exactly what we just wrote.
        stamp(
          doc_id,
          dataset,
          %{synced_rev: rev, synced_fingerprint: desired_fingerprint(desired)},
          opts
        )

      {:error, err} ->
        classify(err, :update, repo, num, doc_id, dataset, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Out-of-band drift fingerprint (D7 — record before converging; D5 — the GET
  # reads GitHub values ONLY to fingerprint for the record, never into a task)
  # ---------------------------------------------------------------------------

  # Record an `out_of_band_edit` conflict ONLY when a fingerprint was stored on
  # the last write AND the issue's current fingerprint differs. Absent a stored
  # fingerprint (first-ever mirror, or a task mirrored before this slice) → there
  # is nothing to compare against, so record nothing and let the PATCH+stamp roll
  # the feature forward with no backfill.
  defp maybe_record_drift(repo, num, doc_id, dataset, issue, stored)
       when is_integer(stored) do
    current = issue_fingerprint(issue)

    if current != stored do
      _ =
        Conflicts.record(%{
          repo: repo,
          issue: num,
          doc_id: doc_id,
          dataset: dataset,
          kind: "out_of_band_edit",
          detail: %{
            "github_fields" => %{
              "title" => Map.get(issue, "title"),
              "state" => Map.get(issue, "state"),
              "labels" => issue |> Map.get("labels") |> label_names()
            },
            "observed_fp" => current
          }
        })
    end

    :ok
  end

  defp maybe_record_drift(_repo, _num, _doc_id, _dataset, _issue, _stored), do: :ok

  defp stored_fingerprint(link) when is_map(link) do
    case Map.get(link, "synced_fingerprint") do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp stored_fingerprint(_), do: nil

  # Fingerprint the GitHub GET response over ONLY the ledger-owned projected
  # fields (title, body, labels-SORTED, state). Applied identically to the
  # desired projection (`desired_fingerprint/1`) so the two hashes are comparable.
  defp issue_fingerprint(issue) when is_map(issue) do
    :erlang.phash2({
      to_str(Map.get(issue, "title")),
      to_str(Map.get(issue, "body")),
      issue |> Map.get("labels") |> label_names() |> Enum.sort(),
      to_str(Map.get(issue, "state"))
    })
  end

  # Fingerprint the DESIRED issue shape (the projection we are about to PATCH),
  # so the value we STAMP equals what the next GET should fingerprint to when no
  # human touches the issue in between.
  defp desired_fingerprint(desired) do
    :erlang.phash2({
      to_str(desired.title),
      to_str(desired.body),
      desired.labels |> List.wrap() |> Enum.sort(),
      to_str(desired.state)
    })
  end

  # GitHub returns labels as `[%{"name" => ...}, ...]`; tolerate bare strings too.
  defp label_names(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => n} when is_binary(n) -> n
      n when is_binary(n) -> n
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp label_names(_), do: []

  defp to_str(nil), do: ""
  defp to_str(s) when is_binary(s), do: s
  defp to_str(other), do: to_string(other)

  # ---------------------------------------------------------------------------
  # Error classification (contract #3, D8/D9)
  # ---------------------------------------------------------------------------

  defp classify(%RateLimitError{retry_after: s}, _mode, _repo, _num, _doc_id, _dataset, _opts) do
    # D9: retryable, never dead-lettered. Level-triggered reconcile means the
    # snoozed job re-reads current state when it runs, so no intent is lost.
    {:snooze, max(s || 0, 1)}
  end

  defp classify(
         %NetworkError{reason: {:http, status}} = _err,
         _mode,
         _repo,
         _num,
         _doc_id,
         _dataset,
         _opts
       )
       when status in 400..499 do
    # A permanent client error (422 validation, 400 bad request). Retrying it
    # forever is pointless — dead-letter it (contract #3).
    {:cancel, {:client_error, status}}
  end

  defp classify(%NetworkError{} = err, _mode, _repo, _num, _doc_id, _dataset, _opts) do
    # Transport failure or an exhausted 5xx — genuinely transient. Let Oban
    # apply its backoff (capped by max_attempts).
    {:error, err}
  end

  defp classify(%NotFound{}, :update, repo, num, doc_id, dataset, opts) do
    # The issue was deleted/transferred out-of-band (caught by the pre-PATCH GET
    # or the PATCH itself). RECORD the detach so it is VISIBLE (D7), mark the link
    # detached, and NEVER recreate it (recreating would fight a human). Stamp
    # under the task's own tenant scope so a non-default-workspace detach lands.
    _ =
      Conflicts.record(%{
        repo: repo,
        issue: num,
        doc_id: doc_id,
        dataset: dataset,
        kind: "detached",
        detail: %{"reason" => "issue deleted or transferred; not recreated"}
      })

    _ = stamp(doc_id, dataset, %{state: "detached"}, opts)
    {:cancel, :detached}
  end

  defp classify(%NotFound{}, :create, _repo, _num, _doc_id, _dataset, _opts) do
    # 404 on CREATE means the mirror repo itself is missing/misconfigured —
    # there is nothing to detach; dead-letter until config is fixed.
    {:cancel, :repo_not_found}
  end

  defp classify(%AuthError{} = err, _mode, _repo, _num, _doc_id, _dataset, _opts) do
    # Auth may be transiently wrong (token refresh raced, install reprovisioned)
    # — retryable, capped by max_attempts.
    {:error, err}
  end

  defp classify(other, _mode, _repo, _num, _doc_id, _dataset, _opts), do: {:error, other}

  # ---------------------------------------------------------------------------
  # Link stamp
  # ---------------------------------------------------------------------------

  # Persist the bookkeeping stamp. On the (narrow) chance the stamp write fails
  # AFTER a successful issue write, surface `{:error, _}` so Oban retries — a
  # redundant idempotent PATCH on replay converges (D3 amended), which is safe
  # for UPDATE; a failed CREATE stamp risks one duplicate issue on retry, logged.
  defp stamp(doc_id, dataset, github, opts) do
    # Forward `opts` (tenant scope + any HTTP tuning) — `Link.put` threads them
    # to `Content.*`, which reads only `:workspace_id`/`:project_id`/`:source`
    # and ignores the HTTP keys, so the stamp lands under the task's OWN scope.
    case Link.put(doc_id, dataset, github, opts) do
      {:ok, %Document{}} ->
        :ok

      {:error, reason} = err ->
        Logger.error("github mirror stamp failed for #{doc_id}/#{dataset}: #{inspect(reason)}")

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
  defp load_task(doc_id, dataset, opts) do
    published = Content.published_id(doc_id)

    doc =
      case Content.get_document(Content.draft_id(published), @task_type, dataset, opts) do
        {:ok, %Document{} = d} -> d
        _ -> unwrap(Content.get_document(published, @task_type, dataset, opts))
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

  # Lift TENANT SCOPE out of the JSON Oban args (string keys) into keyword opts
  # threaded to the task load + Link stamp so a non-default-workspace task is
  # found and written under its own scope. Absent keys → default workspace/project
  # (the wave-2 behavior), so an args map without scope is fully back-compatible.
  defp scope_opts(args) when is_map(args) do
    []
    |> put_scope(:workspace_id, Map.get(args, "workspace_id"))
    |> put_scope(:project_id, Map.get(args, "project_id"))
  end

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, value), do: Keyword.put(opts, key, value)

  # The mirror repo ("owner/name"). Read directly from plugin config for now;
  # slice 2's `Github.Settings.repo/0` will centralise the env→DB resolution.
  # Reading the same config key here keeps this slice parallel-safe with slice 2.
  defp repo do
    Application.get_env(:barkpark, @config_key, [])[:repo]
  end
end
