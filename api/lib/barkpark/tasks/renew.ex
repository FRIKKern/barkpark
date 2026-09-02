defmodule Barkpark.Tasks.Renew do
  @moduledoc """
  `POST /v1/tasks/:doc_id/renew` — the NON-HOLDER lease extension a CI job can
  actually call, so a claim does not lapse underneath its own open pull request.

  ## The defect this closes

  MEASURED 2026-09-02: `:task_lease_ttl_seconds` is 2700 (45 min) and the CI
  queue ran 60-90 min (390 queued runs at 04:15Z). The required
  `PR references an active task` gate reads the claim WHEN THE GATE RUNS, so a
  PR that waited out the queue met a row whose lease had already been reaped —
  "still open and carries no claim". Ten PRs failed that way in one night and
  one lane re-claimed the same rows three times. RULED by the orchestrator:
  **fix on the LEDGER side, the gate stays strict.**

  ## The decision (task-16e56d05b809dd39, criterion 0)

  The row named two mechanisms. Both need the same missing fact — *is PR #n
  still open?* — and the ledger cannot poll GitHub, so the only question worth
  arguing is **what shape that fact takes on the row.**

  **CHOSEN — a bounded, self-expiring extension WINDOW, renewed by an event.**
  A non-holder, write-tier verb stamps `content.claim.lease_extension.until`
  some minutes into the future; the sweeper refuses to reap a row whose window
  is still open. The ledger never learns GitHub's state — it only has to be
  TOLD "still alive" periodically, which is `Tasks.Pulse`'s contract minus the
  holder check. **Silence releases.** When the PR closes, merges, or is
  abandoned, nothing renews, the window elapses on its own, and the very next
  sweep reaps on the normal schedule with no cleanup step anywhere.

  **REJECTED — "the sweeper skips rows carrying an open PR reference"** (a flag
  / a `content.github.prs` entry / a label). Two reasons, the second decisive:

    1. *It is not cheaper.* Nothing on `main` writes such a reference today.
       #14993's `landed-mark.yml` triggers on `push: branches: [main]` — at
       MERGE, never at PR-open — and `content.landed.prs` is written only by
       `Tasks.Close.merge_landed/2`, i.e. by a close. A skip-rule would still
       need a brand-new writer, so it buys nothing on cost.
    2. *It is a LATCH with no clearing event, and it fails DANGEROUS.* There is
       no `pull_request: closed` hook in `.github/workflows/` — a PR closed
       WITHOUT merging never reaches the landed-mark path at all. A reference
       that only a merge can clear makes an abandoned PR's row permanently
       unreapable: exactly the "unreapable task" failure `TtlSweeper` exists to
       prevent (see its moduledoc). Every failure of the renew path — CI down,
       token revoked, workflow deleted — degrades to today's behaviour; every
       failure of the latch path pins a row forever.

  The cap is the same argument applied to the chosen shape: an extension that
  could be renewed without limit is a slow latch. `first_granted_at` +
  `@default_max_seconds` is a hard ceiling on TOTAL extension for one claim, so
  a PR left open for a week buys hours, not days.

  ## What it writes, and what it deliberately does not

  ONE key: `content.claim.lease_extension`.

      %{"until" => iso8601,          # the sweeper's grace boundary
        "pr" => 15234,               # which PR bought it
        "reason" => "open_pr",
        "first_granted_at" => iso,   # the cap's anchor
        "last_renewed_at" => iso,
        "renewals" => 3}

  NOT `claim.epoch` — **this is the point.** A pulse bumps the epoch, so a
  lead's `stamp`/`close` CAS goes stale every time a heartbeat lands; a renew
  must be invisible to that CAS or it would trade one broken gate for another.
  NOT `claim.worker`, NOT `claim.ts_iso` (so boards keep rendering the HONEST
  lease age — an extended lease is old, not fresh), NOT `work_digest` (the L2
  close-fence still catches a brief edited under the claim), NOT
  `lifecycle_status`, NOT the criteria.

  ## Gates

  NO holder check and NO epoch fence — the whole point is that the caller is
  CI, which can never be the holder (`stamp` runs `check_holder` first and
  answers 409 `not_holder` to exactly this caller). What is NOT relaxed:

    * the row must be `in_progress` **with a live `claim.worker`** — otherwise
      `{:error, :not_claimed}`. A renew may EXTEND a lease; it may never
      resurrect one that a reap, a release, or a close already ended.
    * the cumulative cap above — `{:error, :extension_cap_reached}`.
    * the blast radius: one key, named above.

  Write shape is the renewal family's: per-task advisory lock on
  `task:<doc_id>` — the STRING key `TtlSweeper` and `Pulse` use, so a renew and
  a reap of the same row serialize — in-lock re-read, rev-CAS through
  `Internal.fenced_content_write/4`, a durable `task.lease_renewed`
  mutation_event carrying the caller token id, post-commit broadcast.

  ## Clearing

  `state: "closed"` / `"merged"` DELETES the extension, so a merged PR's row is
  reapable on the next sweep rather than at the end of its window. The clear is
  PR-matched: a close of PR #2 never cancels the extension PR #1 bought. It is
  the fast path, not the mechanism — the window elapsing is what makes the
  design safe when no clear ever arrives.

  ## Who calls this

  Nothing in this repo does yet. The mechanism needs one workflow on
  `pull_request: [opened, synchronize, reopened, ready_for_review]` (renew) and
  `[closed]` (clear) that reads the `Task:` trailer `scripts/pr-task-gate.sh`
  already parses and POSTs here. That is `.github/workflows/**` and
  `scripts/**` — the gates lane owns it, and the required task gate stays
  byte-unchanged, as ruled.
  """

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @event_task_lease_renewed "task.lease_renewed"

  # One lease-length per grant: a renewal buys as much grace as a fresh claim
  # would, so a workflow that fires once per PR event never needs to know the
  # TTL to stay ahead of it.
  @default_window_seconds 2700

  # The ceiling on TOTAL extension for ONE claim, anchored on the FIRST grant
  # (not on a renewal count — renewals overlap, wall-clock does not). 6 h is
  # ~8x the worst measured queue and still far short of a working day, so an
  # abandoned PR cannot hold a row past the shift that opened it.
  @default_max_seconds 21_600

  @doc "The mutation_events kind a renew (or a clear) emits."
  @spec event_kind() :: String.t()
  def event_kind, do: @event_task_lease_renewed

  @doc "Seconds of grace one renewal buys."
  @spec window_seconds() :: pos_integer()
  def window_seconds,
    do:
      Application.get_env(
        :barkpark,
        :task_lease_extension_window_seconds,
        @default_window_seconds
      )

  @doc "Hard ceiling on total extension for one claim, from the first grant."
  @spec max_seconds() :: pos_integer()
  def max_seconds,
    do: Application.get_env(:barkpark, :task_lease_extension_max_seconds, @default_max_seconds)

  @doc """
  Extend (or clear) the lease extension on a claimed task.

  `task_id` is the `documents.id` uuid — the controller resolves `doc_id` → row
  under tenancy scope, same as close/release/pulse. Opts:

    * `:pr` (required, positive integer) — the pull request buying the grace.
      An extension with no named reason is a blank cheque.
    * `:state` — `"open"` (default) renews; `"closed"` / `"merged"` clears.
    * `:reason` — free-text label stored on the record, default `"open_pr"`.
    * `:caller_token_id` — audit stamp for the mutation_event.

  Returns `{:ok, doc}` or
  `{:error, :not_found | :not_claimed | :extension_cap_reached | :stale_claim}`.
  """
  @spec renew(binary(), keyword()) ::
          {:ok, Document.t()}
          | {:error, :not_found | :not_claimed | :extension_cap_reached | :stale_claim}
  def renew(task_id, opts \\ []) when is_binary(task_id) do
    pr = Keyword.fetch!(opts, :pr)
    state = Keyword.get(opts, :state, "open")
    reason = Keyword.get(opts, :reason, "open_pr")
    caller_token_id = Keyword.get(opts, :caller_token_id)
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        # Read once for the lock key, lock, re-read: doc_id is immutable so the
        # pre-lock read is safe for keying, and the row state we gate on must
        # be read UNDER the lock or a reap committing in between could race us.
        # global-read: by-PK read for the renewal-family lock key
        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{doc_id: doc_id} ->
            _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:" <> doc_id])

            # global-read: in-lock re-read of the same PK row (see above)
            doc = Repo.get!(Document, task_id)

            case check_claimed(doc) do
              :ok -> apply_renew(doc, pr, state, reason, now, caller_token_id)
              {:error, err} -> {:error, err}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A renew EXTENDS a live lease; it never resurrects a dead one. Reaped rows
  # flip to "open" with `claim.worker` cleared, released rows likewise, closed
  # rows are done/cancelled (and close KEEPS claim.worker for the dossier, so
  # the lifecycle test has to come first). Anything else → :not_claimed.
  defp check_claimed(%Document{content: content}) do
    content = content || %{}

    with "in_progress" <- Map.get(content, "lifecycle_status"),
         worker when is_binary(worker) and worker != "" <-
           get_in(content, ["claim", "worker"]) do
      :ok
    else
      _ -> {:error, :not_claimed}
    end
  end

  defp apply_renew(%Document{content: content} = doc, pr, state, reason, now, caller_token_id) do
    claim = Map.get(content, "claim") || %{}
    existing = Map.get(claim, "lease_extension")

    case next_extension(existing, pr, state, reason, now) do
      {:error, err} ->
        {:error, err}

      {:ok, next} ->
        new_claim =
          case next do
            nil -> Map.delete(claim, "lease_extension")
            ext -> Map.put(claim, "lease_extension", ext)
          end

        write(doc, Map.put(content, "claim", new_claim), next, pr, state, caller_token_id)
    end
  end

  # ─── The extension arithmetic (the whole policy, in one place) ─────────────

  # A close/merge CLEARS — but only the extension THIS pr bought. PR #2 closing
  # must not cancel the grace PR #1 is still paying for. A clear with nothing
  # (or someone else's thing) to clear is an idempotent success, not an error:
  # the workflow that sends it cannot know which PR won the race.
  defp next_extension(existing, pr, state, _reason, _now) when state in ["closed", "merged"] do
    case existing do
      %{"pr" => ^pr} -> {:ok, nil}
      _ -> {:ok, existing}
    end
  end

  defp next_extension(existing, pr, _state, reason, now) do
    # A renewal naming a DIFFERENT pr re-anchors the cap and the count: that is
    # a new pull request buying its OWN grace, not the old one sneaking past
    # its ceiling under a new number.
    carry = if match?(%{"pr" => ^pr}, existing), do: existing, else: nil
    first_granted_at = first_grant(carry, now)
    deadline = DateTime.add(first_granted_at, max_seconds(), :second)

    # The cap is wall-clock from the FIRST grant. Past it, refuse loudly rather
    # than stamping a window that is already behind `now` — a caller that reads
    # 200 and a dead window would keep renewing into a wall forever.
    if DateTime.compare(now, deadline) != :lt do
      {:error, :extension_cap_reached}
    else
      until =
        now
        |> DateTime.add(window_seconds(), :second)
        |> min_dt(deadline)

      {:ok,
       %{
         "until" => DateTime.to_iso8601(until),
         "pr" => pr,
         "reason" => reason,
         "first_granted_at" => DateTime.to_iso8601(first_granted_at),
         "last_renewed_at" => DateTime.to_iso8601(now),
         "renewals" => renewals(carry) + 1
       }}
    end
  end

  defp first_grant(%{"first_granted_at" => iso}, now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> now
    end
  end

  defp first_grant(_, now), do: now

  defp renewals(%{"renewals" => n}) when is_integer(n) and n >= 0, do: n
  defp renewals(_), do: 0

  defp min_dt(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  # ─── The write ────────────────────────────────────────────────────────────

  defp write(%Document{} = doc, new_content, next, pr, state, caller_token_id) do
    observed_rev = doc.rev
    new_rev = generate_rev()

    # PDS-D451: the receipt is the STORED row, not a reconstruction of intent.
    case fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        payload =
          Map.merge(
            %{
              "lease_extension" => %{
                "pr" => pr,
                "state" => state,
                "cleared" => is_nil(next),
                "until" => next && Map.get(next, "until")
              }
            },
            caller_stamp(caller_token_id)
          )

        ev =
          insert_mutation_event!(updated, @event_task_lease_renewed, observed_rev, "api", payload)

        {:ok, updated, [task_broadcast(updated, @event_task_lease_renewed, ev, observed_rev)]}

      :stale ->
        {:error, :stale_claim}
    end
  end
end
