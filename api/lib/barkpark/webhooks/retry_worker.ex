defmodule Barkpark.Webhooks.RetryWorker do
  @moduledoc """
  One-shot Oban job that runs the NEXT attempt of a retrying webhook delivery,
  scheduled `delay` out by `Webhooks.schedule_retry/3`.

  It replaces the dispatcher's in-task `Process.sleep` backoff. The old loop
  parked one of the bounded `WebhookDeliverySupervisor` async_stream slots
  (`webhook_delivery_concurrency`, default 100) for the WHOLE backoff window —
  so a retry storm saturated the pool with SLEEPING tasks and head-of-line
  blocked deliveries to healthy endpoints. Now a retryable failure enqueues one
  of these `scheduled_at: now + delay` and the delivery task RETURNS, freeing the
  slot immediately.

  It shares `StuckDeliverySweeper`'s durable-resume machinery:

    * **Fenced on `updated_at`.** `schedule_retry/3` stamps the row's `updated_at`
      to a fresh value (the fence) and carries it in the job args. `perform/1`
      CAS-claims on `(id, status="pending", updated_at=<fence>)`. A miss means a
      crash-sweep — or any racing writer — already owns the row, so this job
      YIELDS without delivering. Because both this worker and the sweeper guard
      on the SAME `updated_at` token, a scheduled retry and a sweep are mutually
      exclusive: whichever bumps it first wins, the other's CAS misses. No
      double-delivery.
    * **Resumes the same row.** On a win it rebuilds the ORIGINAL signed payload
      from the durable `mutation_events` row and resumes the attempt loop against
      the SAME `webhook_deliveries` row via `Dispatcher.redeliver/5`, picking up
      at the persisted attempt number so `max_attempts` is honoured across
      scheduled hops. Re-using the row (never re-inserting) keeps
      UNIQUE(endpoint_id, event_id) intact.
    * **Terminalises like a first-timer.** If this attempt again fails retryably
      the dispatcher schedules the next hop; if it exhausts it writes
      `failed_giveup`. Either way the row leaves `pending`.

  Crash-safety: a crash after the CAS bump re-strands the row `pending` with a
  fresh `updated_at`. The stale Oban retry (old fence) then misses the CAS and
  no-ops, and the per-minute `StuckDeliverySweeper` recovers the row once it ages
  past the stuck threshold. No path double-delivers beyond webhooks' inherent
  at-least-once contract (consumers dedup on the delivery-id header).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Barkpark.Repo
  alias Barkpark.Webhooks.{Delivery, Dispatcher, PayloadRebuild}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"delivery_id" => id, "attempt" => n, "fence" => fence_iso}
      })
      when is_integer(id) and is_integer(n) and is_binary(fence_iso) do
    case DateTime.from_iso8601(fence_iso) do
      {:ok, fence, _offset} ->
        if claim_fence(id, fence), do: drive(id, n), else: :ok

      _ ->
        # Unparseable fence — nothing safe to CAS on; leave the row for the
        # crash sweeper rather than risk a fence-blind re-delivery.
        :ok
    end
  end

  # CAS on the SHARED `updated_at` fence. Exactly one of {this job, a crash-sweep,
  # another racing writer that observed the same value} can flip it; a miss
  # (0 rows) means we lost the race — yield without delivering.
  defp claim_fence(id, %DateTime{} = fence) do
    now = DateTime.utc_now()

    {claimed, _} =
      from(d in Delivery,
        where: d.id == ^id and d.status == "pending" and d.updated_at == ^fence
      )
      |> Repo.update_all(set: [updated_at: now])

    claimed == 1
  end

  # Re-read the freshly-claimed row and rebuild its `{webhook, body}` via the
  # shared `PayloadRebuild` (branches on `source_kind`: document rebuilds from the
  # durable `mutation_events` row, media from the row's `payload_snapshot`). A
  # `:gone` means the row is being (or has been) cascade-deleted — both document
  # FKs are ON DELETE CASCADE — or has no usable snapshot: nothing recoverable.
  defp drive(delivery_id, n) do
    case Repo.get(Delivery, delivery_id) do
      %Delivery{} = delivery ->
        case PayloadRebuild.rebuild(delivery) do
          {:ok, webhook, body} ->
            Logger.info(
              "Scheduled webhook retry ##{delivery.id} attempt #{n + 1} " <>
                "(kind #{delivery.source_kind})"
            )

            # Resume the signed attempt loop at attempt n+1 against the SAME row.
            # On a further retryable failure the dispatcher schedules the next hop;
            # on exhaustion / success it writes the terminal status, so the row
            # leaves `pending`. `event_id` is nil for media (no delivery-id header).
            _ = Dispatcher.redeliver(webhook, body, delivery.event_id, delivery, n + 1)
            :ok

          :gone ->
            :ok
        end

      nil ->
        :ok
    end
  end
end
