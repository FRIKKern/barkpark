defmodule Barkpark.Plugins.Github.InboundEvents do
  @moduledoc """
  INBOUND event breadth — the bookkeeping-only sibling of birth-only `Intake`
  (epic charter Wave 8, **D14**).

  `Intake.ingest/2` owns exactly ONE inbound shape: `issues.opened` → a born-dark
  `gh-<num>` task. Everything else an outsider can do to their intake issue —
  DELETE it, have it TRANSFERRED to another repo, or CLOSE it themselves — used
  to leave the ledger with a live-looking link forever (a deleted/transferred
  issue) or a task stuck `needs-human` invisibly (a self-closed intake). This
  handler closes those gaps with ZERO silent states: every path acts, records,
  or deliberately no-ops.

  ## Doctrine (unchanged, LAW)

  Inbound stays BOOKKEEPING-only. This handler NEVER writes `lifecycle_status`
  (the ownership matrix says `outbound_only` — an inbound lifecycle write is a
  bidirectionality breach), never reads a GitHub field back into a task field,
  and adds NO new conflict `kind` (Health's 3-kind bucketing stays untouched —
  the `detail.reason` discriminator carries deleted/transferred/closed_by_author).
  Barkpark stays the single source of truth; the mirror is OUTBOUND-only.

  ## The gates (in order)

    1. **Bot drop FIRST (D4 cut #1).** `Intake.bot_sender?/1` — if `sender.type ==
       "Bot"` → `:dropped`, before any lookup or write. The outbound mirror closes
       an adopted task's issue AS the App; that close echo arrives here as a Bot
       sender and MUST drop, never detach. This is the same structural loop cut
       intake uses; it runs before everything.

    2. **Deterministic target (D3/D6).** `doc_id = "gh-" <> issue["number"]`. For
       a `transferred` event that number is the OLD issue in the SOURCE repo —
       birth-era identity, NOT a field read-back. Only `gh-<num>` intake-born docs
       are inbound-addressable; an outbound MIRROR (a real task slug whose issue
       we created) keeps the reactive 410 detach in `MirrorJob` — nothing here
       ever touches it, because its doc_id is never `gh-<num>`.

    3. **Action routing.**
       * `deleted` / `transferred`: the intake issue is GONE. If the `gh-<num>`
         task exists → detach it (reason `deleted` / `transferred`). If no such
         task exists → `:ignored` (a delete of an issue we never intook is a
         genuine no-op, 2xx).
       * `closed`: act ONLY when the `gh-<num>` task exists AND its
         `content.github.state == "intake"` AND (redundantly) the sender is not a
         Bot → detach (reason `closed_by_author`). An adopted/mirrored task's
         close is `:ignored` — the outbound loop owns that surface, and the App's
         own close echo already dropped at gate 1.
       * anything else → `:ignored` (the controller only routes the three actions
         above here, but the handler stays robust to a stray action).

  ## Detach = state + record (both, always)

  A detach is TWO writes: `Link.put(doc_id, dataset, %{"state" => "detached"})`
  (stamped `source: :github` — the mutation_events row is EXACTLY `"github"`, so
  the outbox excludes it, loop-cut #2) followed by a DB-only `Conflicts.record`
  with `kind: "detached"` and `detail.reason`. The state flip makes the stale
  link honest; the conflict row makes the detach VISIBLE in the wave-6 console. A
  detached task is NOT adoptable (the adopt gate keys on `state == "intake"`,
  unchanged).

  ## Outcomes

    * `{:ok, :detached, doc_id}` — the `gh-<num>` task was detached + recorded
    * `:ignored`                 — no `gh-<num>` task, a non-intake close, or a
      non-inbound action; a deliberate 2xx no-op (never a 500 → never a retry
      storm)
    * `:dropped`                 — the App's own `[bot]` sender (gate 1)
    * `{:error, reason}`         — the `Link.put` state flip failed for a genuine
      (non-not-found) reason; the controller answers 5xx and GitHub redelivers,
      idempotent via the deterministic `gh-<num>` + `Conflicts.record` dedup

  ## Injected seams (Intake precedent — no network in tests)

    * `:conflict_fun` — default `&Github.Conflicts.record/1` (resolved
      dynamically so this compiles regardless of module load order); `(attrs)` in,
      records the `detached` row. Best-effort: a failure is logged and swallowed
      so a durable state flip is never lost to a flaky recorder.
    * `:repo`    — the `owner/name` for the recorded row; defaults to
      `Settings.repo/0`, else the webhook's `repository.full_name`.
    * `:dataset` — the dataset the task lives in; defaults to `"production"`.

  Every other `opts` key (`:workspace_id`/`:project_id`/`:user_id`) threads
  through to `Link.put` for tenant-scoped lookup + write.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Intake, Link, Settings}

  @task_type "task"
  @default_dataset "production"

  @typedoc "Inbound-event outcome. See the moduledoc for the full contract."
  @type result ::
          {:ok, :detached, String.t()}
          | :ignored
          | :dropped
          | {:error, term()}

  @doc """
  Handle a decoded GitHub `issues` webhook whose action is
  `deleted`/`transferred`/`closed`. Bot-drops first, then routes per the
  moduledoc. See the `result` type for every outcome.
  """
  @spec handle(map(), keyword()) :: result()
  def handle(payload, opts \\ []) when is_map(payload) do
    cond do
      Intake.bot_sender?(payload) -> :dropped
      true -> route(payload, opts)
    end
  end

  # ── action routing ─────────────────────────────────────────────────────────

  defp route(payload, opts) do
    issue = Map.get(payload, "issue")

    cond do
      not is_map(issue) ->
        :ignored

      Map.get(payload, "action") in ["deleted", "transferred"] ->
        detach_gone(payload, issue, Map.get(payload, "action"), opts)

      Map.get(payload, "action") == "closed" ->
        detach_self_closed(payload, issue, opts)

      true ->
        :ignored
    end
  end

  # deleted / transferred: the intake issue is gone. Detach the gh-<num> task if
  # it exists; a delete of an issue we never intook is a genuine 2xx no-op.
  defp detach_gone(payload, issue, reason, opts) do
    number = Map.get(issue, "number")
    doc_id = "gh-" <> to_string(number)
    dataset = Keyword.get(opts, :dataset, @default_dataset)

    case fetch_existing(doc_id, dataset, opts) do
      {:ok, _doc} -> detach(doc_id, number, dataset, reason, payload, opts)
      :none -> :ignored
    end
  end

  # closed: act ONLY on an existing gh-<num> task still in the "intake" state and
  # a non-Bot sender (the App's own close echo already dropped at gate 1). An
  # adopted/mirrored/detached task's close is the outbound loop's surface → no-op.
  defp detach_self_closed(payload, issue, opts) do
    number = Map.get(issue, "number")
    doc_id = "gh-" <> to_string(number)
    dataset = Keyword.get(opts, :dataset, @default_dataset)

    with {:ok, doc} <- fetch_existing(doc_id, dataset, opts),
         %{"state" => "intake"} <- Link.get(doc) || %{} do
      detach(doc_id, number, dataset, "closed_by_author", payload, opts)
    else
      _ -> :ignored
    end
  end

  # ── detach = state flip + visible record ────────────────────────────────────

  # Flip the link to "detached" (the durable, honest state), then record a
  # VISIBLE `detached` conflict with the reason discriminator. Order matters: the
  # state flip is the correctness write; the record is bookkeeping layered on top.
  # A record failure never un-does or fails the detach (a retry re-detaches
  # idempotently and the recorder dedups the open {repo,issue,kind} row).
  defp detach(doc_id, number, dataset, reason, payload, opts) do
    case Link.put(doc_id, dataset, %{"state" => "detached"}, opts) do
      {:ok, _doc} ->
        record_detach(number, dataset, reason, payload, opts)
        {:ok, :detached, doc_id}

      # Raced away between the fetch and the write (a concurrent detach) — nothing
      # left to detach, so a 2xx no-op, never a 500.
      {:error, :not_found} ->
        :ignored

      # A genuine ledger-write failure: surface it so the controller answers 5xx
      # and GitHub redelivers (idempotent via the deterministic gh-<num>).
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Record the detach into `github_sync_conflicts` (DB-only, no loop surface) so
  # a maintainer SEES it. `kind` stays "detached" (Health's 3-kind bucketing
  # untouched); `detail.reason` is the deleted|transferred|closed_by_author
  # discriminator. Best-effort: a failing/raising recorder is logged and swallowed
  # so the durable state flip already committed is never rolled back.
  defp record_detach(number, dataset, reason, payload, opts) do
    repo = Keyword.get(opts, :repo) || Settings.repo() || issue_repo(payload)
    record_fun = Keyword.get(opts, :conflict_fun, &default_record/1)

    attrs = %{
      repo: repo,
      issue: number,
      doc_id: "gh-" <> to_string(number),
      dataset: dataset,
      kind: "detached",
      detail: %{"reason" => reason}
    }

    case record_fun.(attrs) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "github inbound: recording detached for ##{number} (#{reason}) failed: #{inspect(other)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "github inbound: recording detached for ##{number} (#{reason}) raised: #{inspect(e)}"
      )

      :ok
  end

  # Default conflict recorder, resolved dynamically (the Intake precedent) so this
  # compiles regardless of module load order.
  defp default_record(attrs) do
    mod = Module.concat(Barkpark.Plugins.Github, Conflicts)
    mod.record(attrs)
  end

  # ── shared lookup ───────────────────────────────────────────────────────────

  # Resolve the gh-<num> task draft-first, then the published perspective (an
  # adopted+published task), under the caller's tenant scope. Returns
  # `{:ok, doc}` or `:none`. Mirror of `Intake.fetch_existing/3`.
  defp fetch_existing(doc_id, dataset, opts) do
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

  # The repo the issue lives in — the webhook's `repository.full_name`, used only
  # as a last resort for the recorded row when Settings has no configured repo.
  defp issue_repo(payload) do
    case Map.get(payload, "repository") do
      %{"full_name" => full} when is_binary(full) -> full
      _ -> nil
    end
  end
end
