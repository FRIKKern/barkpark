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
       A `state: "intake"` link → `{:cancel, :intake}` (D13, the PRE-ADOPTION
       MIRROR GATE): a born-dark inbound `gh-<num>` holds the outsider's issue
       number but no consent to mirror, so a pre-adoption Barkpark edit must
       NEVER PATCH the outsider's issue with our projection — intake stays
       intake-only until `adopt` flips the state. Keyed on the state string
       ONLY, never `synced_rev` absence: an `adopted` link also lacks a
       `synced_rev` until its first mirror, and that consent-moment push must
       stay live.
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
  # D11-retry: a deferred child re-links `@relink_delay_seconds` out, bounded to
  # `@relink_cap` attempts before it cap-flattens to a body `parent` marker.
  @relink_delay_seconds 60
  @relink_cap 3

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
    # Normalize to the PUBLISHED doc_id so the draft-create event (`drafts.X`)
    # and the publish/edit events (`X`) coalesce onto ONE unique job. Without
    # this the two distinct ids each enqueue a job and both create an issue —
    # a duplicate mirror (the `unique` clause keys on the raw doc_id).
    %{
      "doc_id" => Content.published_id(fields.doc_id),
      "dataset" => Map.get(fields, :dataset, "production")
    }
    |> put_non_nil("workspace_id", Map.get(fields, :workspace_id))
    |> put_non_nil("project_id", Map.get(fields, :project_id))
    |> put_non_nil("relink", Map.get(fields, :relink))
    |> put_non_nil("relink_attempt", Map.get(fields, :relink_attempt))
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

          # PRE-ADOPTION MIRROR GATE (D13). A `state: "intake"` link is a born-dark
          # `gh-<num>` awaiting an operator's `adopt`: it holds the outsider's issue
          # NUMBER but no `synced_rev`, so an ordinary pre-consent Barkpark edit would
          # sail past `synced?` (false without a synced_rev) and converge — PATCHing
          # the outsider's still-owned issue with Barkpark's projection BEFORE anyone
          # said yes. Cancel here so intake stays intake-only until adopt flips the
          # state. Keyed on the STATE STRING only, never synced_rev absence — an
          # `adopted` link also lacks a synced_rev until its first mirror, and that
          # consent-moment push must stay live.
          intake?(link) ->
            {:cancel, :intake}

          # A `relink: true` job (D11-retry) BYPASSES the synced coalesce guard so
          # a child that is already synced still re-runs to link its now-mirrored
          # parent. The issue create/PATCH stays idempotent (nothing changed → a
          # redundant no-op PATCH); the point of the re-run is the relations pass.
          not relink?(opts) and Link.synced?(task_doc) ->
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
        # Capture the rev off the pristine Document BEFORE hydration decorates the
        # in-memory doc with `blocker_issue_refs`/`parent_marker` (D11): those keys
        # are read ONLY by the projection body render, never persisted, and must
        # not shadow the row's `_rev`.
        rev = rev_of(task_doc)
        # Hydrate the relations markers onto the in-memory doc so the projected
        # BODY carries the `blocks` (and, when a prior pass cap-flattened, the
        # `parent`) marker. Pure in-memory decoration — NO GitHub call here (D11).
        task_doc = hydrate(task_doc, dataset, link, opts)
        desired = Projection.task_to_issue(task_doc)

        case issue_number(link) do
          nil ->
            create(doc_id, dataset, repo, desired, rev, opts, task_doc)

          num when is_integer(num) ->
            update(doc_id, dataset, repo, num, desired, rev, link, opts, task_doc)
        end

      _ ->
        # No mirror repo configured — the client verbs would FunctionClause-crash
        # on a nil repo and Oban would retry the crash forever. Dead-letter it
        # until config is fixed (slice 2 centralises the env→DB resolution).
        {:cancel, :repo_unconfigured}
    end
  end

  defp create(doc_id, dataset, repo, desired, rev, opts, task_doc) do
    params = %{title: desired.title, body: desired.body, labels: desired.labels}

    case Client.create_issue(repo, params, opts) do
      {:ok, %{"number" => num}} when is_integer(num) ->
        after_create(doc_id, dataset, repo, num, desired, rev, opts, task_doc)

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
  defp after_create(doc_id, dataset, repo, num, %{state: "open"}, rev, opts, task_doc) do
    case stamp(doc_id, dataset, %{repo: repo, issue: num, synced_rev: rev, state: "synced"}, opts) do
      # The issue mirror converged (created + stamped). NOW the issue number is
      # known and the issue write returned :ok, so run the failure-isolated
      # Projects + relations projections. A fresh create carries no prior link, so
      # pass nil (no stored projects fingerprint → the first sync writes it).
      :ok -> sync_projections(doc_id, dataset, repo, num, task_doc, nil, opts)
      err -> err
    end
  end

  defp after_create(doc_id, dataset, repo, num, desired, rev, opts, task_doc) do
    case stamp(doc_id, dataset, %{repo: repo, issue: num, state: "synced"}, opts) do
      # The issue is one HTTP call old and carries no stored fingerprint yet, so
      # there is nothing to drift from — pass a nil link so `update` records no
      # spurious conflict and just PATCHes state + stamps the first fingerprint.
      # `update` runs the projections at the END of its PATCH (one place only).
      :ok -> update(doc_id, dataset, repo, num, desired, rev, nil, opts, task_doc)
      err -> err
    end
  end

  # BEFORE the PATCH, read the issue's CURRENT state and fingerprint its
  # ledger-owned fields; if it drifted out-of-band since our last write, RECORD
  # the conflict (ledger still wins — D7). A GET 404/410 → the issue vanished
  # between drain and reconcile → route to the detached branch via `classify`.
  defp update(doc_id, dataset, repo, num, desired, rev, link, opts, task_doc) do
    case Client.get_issue(repo, num, opts) do
      {:ok, issue} ->
        maybe_record_drift(repo, num, doc_id, dataset, issue, stored_fingerprint(link))
        patch(doc_id, dataset, repo, num, desired, rev, link, opts, task_doc)

      {:error, err} ->
        classify(err, :update, repo, num, doc_id, dataset, opts)
    end
  end

  defp patch(doc_id, dataset, repo, num, desired, rev, link, opts, task_doc) do
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
        case stamp(
               doc_id,
               dataset,
               %{synced_rev: rev, synced_fingerprint: desired_fingerprint(desired)},
               opts
             ) do
          # Issue mirror converged (PATCH + stamp). NOW run the failure-isolated
          # Projects + relations projections — pass the ORIGINAL link so Projects
          # can diff its stored `projects_fingerprint` (D10 zero-write-when-unchanged).
          :ok -> sync_projections(doc_id, dataset, repo, num, task_doc, link, opts)
          err -> err
        end

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
  # fields (title, body, labels-SORTED, state). Runs through the SAME `fingerprint/4`
  # as the desired projection so the observed and desired hashes can never drift
  # apart through a copy-paste divergence between two hand-kept functions.
  defp issue_fingerprint(issue) when is_map(issue) do
    fingerprint(
      Map.get(issue, "title"),
      Map.get(issue, "body"),
      issue |> Map.get("labels") |> label_names(),
      Map.get(issue, "state")
    )
  end

  # Fingerprint the DESIRED issue shape (the projection we are about to PATCH),
  # so the value we STAMP equals what the next GET should fingerprint to when no
  # human touches the issue in between.
  defp desired_fingerprint(desired) do
    fingerprint(desired.title, desired.body, List.wrap(desired.labels), desired.state)
  end

  # The ONE hash both sides run through. `body` is newline-normalized and
  # title/state trimmed because GitHub re-encodes an issue body's line endings to
  # CRLF on write and echoes them back on read (and trims title/state whitespace):
  # a body we PATCH as "x\ny" returns as "x\r\ny". WITHOUT this normalization the
  # observed fingerprint would differ from the stored desired fingerprint on
  # EVERY steady-state reconcile of a multi-line body (which every mirrored task
  # has — the projection always appends a `Task:` trailer), flooding the
  # quarantine with false `out_of_band_edit` rows. We fingerprint logical
  # content, not GitHub's wire encoding.
  defp fingerprint(title, body, labels, state) do
    :erlang.phash2({
      title |> to_str() |> String.trim(),
      normalize_body(body),
      labels |> Enum.map(&to_str/1) |> Enum.sort(),
      state |> to_str() |> String.trim()
    })
  end

  # Collapse CRLF/CR to LF and strip trailing whitespace so GitHub's line-ending
  # re-encoding of a stored body is never mistaken for a human edit.
  defp normalize_body(body) do
    body
    |> to_str()
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim_trailing()
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

  # An `intake` link is a born-dark inbound issue awaiting adoption (D13). It carries
  # the outsider's issue number but NO consent to mirror, so the reconcile cancels
  # before converge — see the pre-adoption gate in reconcile/3.
  defp intake?(link) when is_map(link), do: Map.get(link, "state") == "intake"
  defp intake?(_), do: false

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
    |> put_scope(:relink, Map.get(args, "relink"))
    |> put_scope(:relink_attempt, Map.get(args, "relink_attempt"))
  end

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, value), do: Keyword.put(opts, key, value)

  # The mirror repo ("owner/name"). Resolves through `Github.Settings.repo/0` —
  # the env→DB credentials resolver — NOT the bare `cfg()` env read. A live
  # instance stores `repo` in the encrypted `plugin_settings` row (not app env),
  # so an env-only read here made every drained MirrorJob cancel with
  # `:repo_unconfigured` even though the plugin was fully provisioned + `active?`.
  defp repo do
    Barkpark.Plugins.Github.Settings.repo()
  end

  # ---------------------------------------------------------------------------
  # Projections (Projects v2 + relations) — the Wave-5 wiring keystone.
  #
  # Run ONLY after the issue exists and its mirror converged (create/PATCH + the
  # `Link.put` stamp returned :ok). Each sub-step is FAILURE-ISOLATED: the issue
  # is the source of truth, so a Projects GraphQL error or a relations hiccup is
  # LOGGED and swallowed — the reconcile still returns the issue-mirror's :ok
  # (D10/D11). NEVER dead-letter the issue mirror on a projection failure.
  #
  # The ONE exception is a rate-limit (`%RateLimitError{}`), which MAY snooze the
  # WHOLE reconcile (D9): the level-triggered re-run re-reads current state and
  # re-PATCHes the issue idempotently, so no intent is lost.
  #
  # Projects/Relations are resolved through an injected seam (opts → plugin config
  # → the real module). When the target module is not loaded (slices 2/3 not yet
  # integrated), the step is a clean no-op — which is exactly the isolation
  # invariant: no projection module ⇒ the proven Issues loop is 100% unaffected.
  # ---------------------------------------------------------------------------
  defp sync_projections(doc_id, dataset, repo, num, task_doc, link, opts) do
    with :ok <- sync_projects(doc_id, dataset, repo, num, task_doc, link, opts) do
      sync_relations(doc_id, dataset, repo, num, task_doc, link, opts)
    end
  end

  # D10: one-directional Projects v2. On a changed fingerprint `Projects.sync`
  # returns `{:ok, %{fingerprint, item_id}}` and we stamp it (source:"github",
  # outbox-excluded) so the NEXT sync diffs against it and writes ZERO GraphQL
  # when unchanged; `:noop` → nothing; `{:error, _}` → snooze on rate-limit,
  # else log + continue.
  defp sync_projects(doc_id, dataset, repo, num, task_doc, link, opts) do
    mod = projects_mod(opts)

    isolate(:projects, doc_id, fn ->
      if available?(mod, :sync, 5) do
        case mod.sync(task_doc, repo, num, link, opts) do
          {:ok, %{fingerprint: fp, item_id: item_id}} ->
            _ =
              stamp(
                doc_id,
                dataset,
                %{projects_fingerprint: fp, projects_item_id: item_id},
                opts
              )

            :ok

          :noop ->
            :ok

          {:error, reason} ->
            projection_error(:projects, repo, num, doc_id, dataset, reason)
        end
      else
        :ok
      end
    end)
  end

  # D11: native `parent_id` → sub-issue linking. `:ok`/`:noop` → continue;
  # `{:flatten, parent_id}` → stamp a `parent_marker` link key + re-enqueue once
  # so the body marker lands (cap-flatten fallback); `{:defer, :parent_unmirrored}`
  # → enqueue the parent's mirror + re-enqueue THIS child (relink, bounded);
  # `{:error, _}` → snooze on rate-limit, else log + continue.
  defp sync_relations(doc_id, dataset, repo, num, task_doc, link, opts) do
    mod = relations_mod(opts)

    isolate(:relations, doc_id, fn ->
      if available?(mod, :sync, 5) do
        case mod.sync(task_doc, repo, num, dataset, opts) do
          ok when ok in [:ok, :noop] ->
            :ok

          {:flatten, parent_id} ->
            handle_flatten(doc_id, dataset, link, parent_id, opts)

          {:defer, :parent_unmirrored} ->
            handle_defer(doc_id, dataset, task_doc, opts)

          {:error, reason} ->
            projection_error(:relations, repo, num, doc_id, dataset, reason)
        end
      else
        :ok
      end
    end)
  end

  # A projection error is SWALLOWED (log + return the issue-mirror's :ok) UNLESS
  # it is a rate-limit, which may snooze the whole reconcile (D9 — safe because
  # the issue PATCH re-runs idempotently on the level-triggered retry).
  #
  # A REST 403/429 surfaces as `%RateLimitError{}` and still snoozes — this
  # branch is byte-identical to before.
  defp projection_error(_which, _repo, _num, _doc_id, _dataset, %RateLimitError{retry_after: s}) do
    {:snooze, max(s || 0, 1)}
  end

  # A GraphQL rate-limit (Projects v2) is NOT a `%RateLimitError{}`: a GraphQL
  # response is `200 OK` even when its `errors` array carries `RATE_LIMITED`, so
  # `Client.graphql/3` surfaces it as `%NetworkError{reason: {:graphql, errors}}`.
  # Left to the bare-log branch it vanishes INVISIBLY. Instead RECORD it as an
  # `out_of_band_edit` conflict (the fixed inclusion set is out_of_band_edit /
  # detached / dedup_refused — slice-1 Health buckets on the KIND, so we reuse it
  # and discriminate with `detail.source`), then CONTINUE — the issue mirror
  # already converged, and the level-triggered next edit re-runs the GraphQL
  # write. NOT a snooze: a 200-body GraphQL error is record-and-continue, not a
  # transport back-off.
  defp projection_error(
         _which,
         repo,
         num,
         doc_id,
         dataset,
         %NetworkError{reason: {:graphql, errors}}
       ) do
    record_projection_conflict(repo, num, doc_id, dataset, %{
      "source" => "graphql",
      "errors" => errors
    })

    :ok
  end

  # A REAL (non-idempotent) sub-issue rejection surfaced by `Relations.sync`
  # (charter 4b): the tree link was refused for a reason OTHER than "already
  # linked". RECORD it (same fixed kind, distinct `detail.source`) so an operator
  # sees the sub-issue never formed, then continue. Failure isolation is
  # inviolate — the issue mirror still returns `:ok`.
  defp projection_error(
         _which,
         repo,
         num,
         doc_id,
         dataset,
         {:sub_issue_rejected, parent_num, child_db_id, detail}
       ) do
    record_projection_conflict(repo, num, doc_id, dataset, %{
      "source" => "sub_issue_rejected",
      "parent_issue" => parent_num,
      "child_db_id" => child_db_id,
      "detail" => to_string(detail)
    })

    :ok
  end

  defp projection_error(which, _repo, _num, doc_id, _dataset, reason) do
    Logger.warning("github #{which} sync failed for #{doc_id}: #{inspect(reason)}")
    :ok
  end

  # Record a projection-layer conflict under the reused `out_of_band_edit` kind
  # with a `detail.source` discriminator. DB-only (Conflicts.record never touches
  # Content/mutation_events — no loop surface, D4/D7). Best-effort: a record
  # failure is ignored (the issue is already mirrored) and any raise is caught by
  # the enclosing `isolate/3`, so the reconcile still returns the mirror's `:ok`.
  defp record_projection_conflict(repo, num, doc_id, dataset, detail) do
    _ =
      Conflicts.record(%{
        repo: repo,
        issue: num,
        doc_id: doc_id,
        dataset: dataset,
        kind: "out_of_band_edit",
        detail: detail
      })

    :ok
  end

  # Failure isolation: a projection sub-step must NEVER crash the reconcile (the
  # issue is already mirrored). Any raise/throw is logged and downgraded to :ok.
  defp isolate(which, doc_id, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("github #{which} sync crashed for #{doc_id}: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("github #{which} sync threw for #{doc_id}: #{inspect({kind, reason})}")
      :ok
  end

  defp available?(mod, fun, arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  # ---------------------------------------------------------------------------
  # Relations retry / cap-flatten (D11-retry) — all bounded, loop-proof
  # ---------------------------------------------------------------------------

  # Parent not mirrored yet: enqueue the PARENT's MirrorJob now (so it gets an
  # issue) and re-enqueue THIS child as a bounded `relink` job. Past the cap,
  # give up on the native sub-issue and fall back to the body `parent` marker.
  defp handle_defer(doc_id, dataset, task_doc, opts) do
    attempt = relink_attempt(opts)
    parent_id = parent_id_of(task_doc)

    if attempt >= @relink_cap do
      handle_flatten(doc_id, dataset, Link.get(task_doc), parent_id, opts)
    else
      if is_binary(parent_id) and parent_id != "" do
        _ =
          reenqueue(
            carry_scope(%{doc_id: parent_id, dataset: dataset}, opts),
            @debounce_seconds,
            opts
          )
      end

      _ =
        reenqueue(
          carry_scope(
            %{doc_id: doc_id, dataset: dataset, relink: true, relink_attempt: attempt + 1},
            opts
          ),
          @relink_delay_seconds,
          opts
        )

      :ok
    end
  end

  # Cap-flatten (D11): skip the native sub-issue, record a `parent_marker` link
  # key (source:"github", outbox-excluded) and re-enqueue ONCE as a relink so the
  # next converge hydrates + PATCHes the body marker. Idempotent + loop-proof: a
  # marker already equal to this parent short-circuits (no re-stamp, no re-enqueue),
  # and the re-enqueued job carries `relink_attempt: @relink_cap` so any further
  # defer immediately re-flattens into this same no-op.
  defp handle_flatten(doc_id, dataset, link, parent_id, opts) do
    already? = is_map(link) and Map.get(link, "parent_marker") == parent_id

    if is_binary(parent_id) and parent_id != "" and not already? do
      _ = stamp(doc_id, dataset, %{parent_marker: parent_id}, opts)

      _ =
        reenqueue(
          carry_scope(
            %{doc_id: doc_id, dataset: dataset, relink: true, relink_attempt: @relink_cap},
            opts
          ),
          @relink_delay_seconds,
          opts
        )
    end

    :ok
  end

  # Insert a follow-up MirrorJob. Injectable seam (`:enqueue_fun` in opts or plugin
  # config) so tests count enqueues without touching Oban; default inserts a real
  # debounced job. The seam receives `%{fields, schedule_in}`.
  defp reenqueue(fields, schedule_in, opts) do
    case opts[:enqueue_fun] || cfg()[:enqueue_fun] do
      fun when is_function(fun, 1) ->
        fun.(%{fields: fields, schedule_in: schedule_in})

      _ ->
        fields |> build_args() |> new(schedule_in: schedule_in) |> Oban.insert()
    end
  end

  # Carry TENANT SCOPE onto a re-enqueued job's fields so a non-default-workspace
  # child/parent stays in its own scope across the retry.
  defp carry_scope(fields, opts) do
    fields
    |> maybe_put(:workspace_id, opts[:workspace_id])
    |> maybe_put(:project_id, opts[:project_id])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # Relations hydration (D11) — decorate the in-memory doc the projection reads
  # ---------------------------------------------------------------------------

  # Merge `blocker_issue_refs` (via the relations seam) and a `parent_marker`
  # (from a prior cap-flatten stamp) onto the in-memory task doc BEFORE the
  # projection renders the body. Pure decoration — never persisted, never a
  # GitHub call. When the relations module is absent the doc is returned as-is.
  defp hydrate(task_doc, dataset, link, opts) do
    task_doc
    |> hydrate_blocker_refs(dataset, opts)
    |> hydrate_parent_marker(link)
  end

  defp hydrate_blocker_refs(task_doc, dataset, opts) do
    mod = relations_mod(opts)

    if available?(mod, :hydrate_blocker_refs, 3) do
      try do
        mod.hydrate_blocker_refs(task_doc, dataset, opts)
      rescue
        _ -> task_doc
      catch
        _, _ -> task_doc
      end
    else
      task_doc
    end
  end

  defp hydrate_parent_marker(task_doc, link) do
    case parent_marker(link) do
      m when is_binary(m) and m != "" -> Map.put(task_doc, "parent_marker", m)
      _ -> task_doc
    end
  end

  # ---------------------------------------------------------------------------
  # Seams + small relations helpers
  # ---------------------------------------------------------------------------

  # Resolve the Projects/Relations modules through an injected seam so slice 4
  # compiles + tests WITHOUT slices 2/3 in the tree (tests stub them; runtime
  # resolves to the real modules once integrated). The default is a literal atom
  # (never a remote call), so referencing a not-yet-existing module is warning-free.
  defp projects_mod(opts),
    do: opts[:projects_mod] || cfg()[:projects_mod] || Barkpark.Plugins.Github.Projects

  defp relations_mod(opts),
    do: opts[:relations_mod] || cfg()[:relations_mod] || Barkpark.Plugins.Github.Relations

  defp cfg, do: Application.get_env(:barkpark, @config_key, [])

  defp relink?(opts), do: opts[:relink] == true

  defp relink_attempt(opts) do
    case opts[:relink_attempt] do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp parent_id_of(task_doc) do
    case content_of(task_doc) do
      content when is_map(content) ->
        Map.get(content, "parent_id") || Map.get(content, :parent_id)

      _ ->
        nil
    end
  end

  defp content_of(%Document{content: c}) when is_map(c), do: c
  defp content_of(%{content: c}) when is_map(c), do: c
  defp content_of(%{"content" => c}) when is_map(c), do: c
  defp content_of(_), do: %{}

  defp parent_marker(link) when is_map(link), do: Map.get(link, "parent_marker")
  defp parent_marker(_), do: nil
end
