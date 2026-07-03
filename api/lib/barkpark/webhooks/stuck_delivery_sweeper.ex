defmodule Barkpark.Webhooks.StuckDeliverySweeper do
  @moduledoc """
  Recovers webhook deliveries left stuck in `"pending"` by a crashed dispatcher.

  `Webhooks.claim_delivery/2` inserts a `webhook_deliveries` row with status
  `"pending"` BEFORE the first HTTP attempt, then `Dispatcher.deliver/3` drives
  the (synchronous, retrying) attempt loop and writes the terminal status
  (`"ok"` / `"failed_giveup"`) at the end. If the dispatcher Task crashes — or
  the BEAM restarts — between the claim and that terminal write, the row is
  stranded in `"pending"` forever: the `UNIQUE(endpoint_id, event_id)` constraint
  blocks any re-claim, so the event becomes **permanently undeliverable** with no
  recovery path (statuses are only `pending | ok | failed_giveup`; nothing ever
  revisits a `pending` row).

  This Oban cron worker is that recovery path. Once per minute it:

    1. SELECTs every delivery still `"pending"` whose `updated_at` is older than
       `webhook_stuck_delivery_after_seconds` (default 300s). The threshold sits
       far above the worst-case in-flight window (max_attempts × HTTP timeout +
       fixed retry backoff ≈ tens of seconds), so a genuinely in-flight delivery
       is NEVER a candidate — only crash-orphaned rows are.

    2. For each candidate, atomically **claims the sweep** with a CAS
       `update_all` guarded on `(id, status="pending", updated_at=<observed>)`
       that bumps `updated_at` to now. Exactly one sweeper (or reclaimer) can win
       this CAS; a loser sees 0 rows and skips. Bumping `updated_at` also lifts
       the row above the cutoff, so a concurrent sweep pass won't re-select it.

    3. Rebuilds the ORIGINAL signed payload from the durable `mutation_events`
       row (`event_id` is its PK) — mutation/type/doc_id/document/dataset/scope
       are all persisted there — and re-runs delivery against the SAME row via
       `Dispatcher.redeliver/4`. That resumes the signed HTTP attempt loop and
       writes a terminal status, so a recovered delivery reaches `ok` /
       `failed_giveup` exactly like a first-time one. If it crashes AGAIN mid
       re-dispatch, the row is `"pending"` with a fresh `updated_at` and the next
       sweep past the threshold retries it — self-healing.

  ## Why this cannot double-deliver or violate UNIQUE

    * **No double-delivery of an in-flight row** — the threshold (minutes) is an
      order of magnitude above the max in-flight time (seconds); an in-flight
      delivery's `updated_at` stays at claim time until its own terminal write,
      so it is never selected while alive.
    * **No double-delivery from two sweepers** — the CAS on `updated_at` elects a
      single winner; the loser skips.
    * **`ok` / `failed_giveup` rows are never touched** — they fail both the
      `status = "pending"` SELECT filter and the CAS guard.
    * **No UNIQUE(endpoint_id, event_id) violation** — the sweeper never INSERTs.
      It re-uses the existing claimed row (CAS update + terminal update, both by
      primary key), so the dedup constraint is untouched.

  Configuration: `Application.get_env(:barkpark, :webhook_stuck_delivery_after_seconds, 300)`.
  Tests override this (e.g. to 0) to make the sweep deterministic.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks.{Delivery, Dispatcher, Webhook}

  @default_stuck_after_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{} = _job) do
    {:ok, sweep(stuck_after_seconds())}
  end

  @doc """
  Pure entry point — bypasses Oban.Job wrapping so tests can drive the sweep
  deterministically. Returns `%{swept: N, skipped: M}`. An empty table returns
  `%{swept: 0, skipped: 0}` — it never raises on "nothing to do."
  """
  @spec sweep(non_neg_integer()) :: %{swept: non_neg_integer(), skipped: non_neg_integer()}
  def sweep(stuck_after_seconds)
      when is_integer(stuck_after_seconds) and stuck_after_seconds >= 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-stuck_after_seconds, :second)

    stuck_candidates(cutoff)
    |> Enum.reduce(%{swept: 0, skipped: 0}, fn %Delivery{} = d, acc ->
      case redispatch_one(d) do
        :swept -> %{acc | swept: acc.swept + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp stuck_after_seconds do
    Application.get_env(
      :barkpark,
      :webhook_stuck_delivery_after_seconds,
      @default_stuck_after_seconds
    )
  end

  # Candidate set: still `pending` and untouched since before the cutoff. The
  # per-row CAS re-validates atomically, so the SELECT is intentionally advisory
  # (a row bumped between SELECT and CAS simply loses the CAS and is skipped).
  defp stuck_candidates(%DateTime{} = cutoff) do
    from(d in Delivery,
      where: d.status == "pending" and d.updated_at < ^cutoff
    )
    |> Repo.all()
  end

  defp redispatch_one(%Delivery{} = delivery) do
    # Claim-the-sweep CAS: only the writer that still sees the row `pending` with
    # the SAME updated_at we observed wins. Bumping updated_at both fences other
    # sweepers and lifts the row above the cutoff for the rest of this pass.
    now = DateTime.utc_now()

    {claimed, _} =
      from(d in Delivery,
        where:
          d.id == ^delivery.id and d.status == "pending" and
            d.updated_at == ^delivery.updated_at
      )
      |> Repo.update_all(set: [updated_at: now])

    case claimed do
      0 ->
        # Lost the race — another sweeper claimed it, or it reached a terminal
        # status, since our SELECT. Nothing to do.
        :skipped

      1 ->
        drive_redispatch(delivery.id)
    end
  end

  defp drive_redispatch(delivery_id) do
    # Re-read the row we just claimed (fresh updated_at) plus its webhook and the
    # durable source event. A nil on any of the three means the row is being (or
    # has been) cascade-deleted — both FKs are ON DELETE CASCADE — or was already
    # removed: nothing recoverable, skip.
    with %Delivery{} = delivery <- Repo.get(Delivery, delivery_id),
         %Webhook{} = webhook <- Repo.get(Webhook, delivery.endpoint_id),
         %MutationEvent{} = event <- Repo.get(MutationEvent, delivery.event_id) do
      body =
        Dispatcher.build_payload(
          event.mutation,
          event.type,
          event.doc_id,
          event.document,
          event.dataset,
          workspace_id: event.workspace_id,
          project_id: event.project_id
        )
        |> Jason.encode!()

      Logger.info(
        "Recovering stuck webhook delivery ##{delivery.id} " <>
          "(endpoint #{delivery.endpoint_id}, event #{delivery.event_id})"
      )

      # Re-run the signed attempt loop against the SAME row. redeliver/4 writes
      # the terminal status via mark_delivered/mark_giveup, so the row leaves
      # `pending`. A crash here re-strands it `pending` with a fresh updated_at →
      # the next sweep past the threshold retries it.
      _ = Dispatcher.redeliver(webhook, body, delivery.event_id, delivery)
      :swept
    else
      nil -> :skipped
    end
  end
end
