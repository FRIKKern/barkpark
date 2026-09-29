defmodule BarkparkCloud.Workers.AgentRetentionWorker do
  @moduledoc """
  Daily pruner for the two unbounded on-box-agent tables (charter D48). A sibling
  of `StaleProvisionJobReaper` — same `:maintenance` queue, same
  delegate-a-DB-mutation shape — but scheduled DAILY, not per-minute: retention is
  a slow-moving housekeeping concern, not a staleness race.

  Five append-only tables grow forever without this:

    * `agent_events` — one `health` row per 60s beat per box (~1440 rows/box/day)
      PLUS one `space` row per 15-minute disk report (~96 rows/box/day, +6.7% —
      D58), written by `Registry.record_event/3` and never mutated. We keep 14
      days: enough for the metrics window (`BarkparkCloud.Metrics` reads the
      durable table) and the instance event timeline. The prune is deliberately
      TYPE-AGNOSTIC — it keys on `inserted_at` alone, so every event type a box
      learns to post inherits the same 14-day window with no code change here.
      Pruning anything older leaves the timeline's recent tail untouched, and
      the metrics window is now a TYPE-FILTERED read
      (`recent_events_of_type/3`), so a non-health row can neither shorten a
      chart nor be kept alive by one.
    * `agent_tokens` — `mint_agent_token/3` now revokes a box's superseded
      same-scope token at re-mint, so dead rows accumulate as `revoked_at` is
      stamped on every re-claim. We keep a dead token 30 days past whichever
      terminal marker (`revoked_at` / `expires_at`) fired, then delete it. A LIVE
      token (neither revoked nor expired) is NEVER touched.
    * `usage_samples` — one cached usage envelope per checkable instance per
      ~15-min sampler tick (cloud-console wave 3), written by
      `Usage.record_sample/1` and never mutated. We keep 14 days (the same window
      as the metrics beats); the summary read only ever wants the latest row.
    * `platform_deliveries` — one row per (sha, delivering run, first sighting)
      of the PLATFORM's own deploys (dr-w23-s2), append-only. We keep 180 days:
      long enough to compare this quarter's delivery latency to last quarter's,
      which is the whole reason the table exists, and bounded so it can never
      become the next unbounded table someone discovers. Sizing: ~62 commits/day
      at ~200 B/row ≈ 5 MB/year against a 265 MB database — retention here is
      designed in, not inherited.
    * `notification_deliveries` — one row per notification send attempt
      (recipient / event / channel / status / attempts / last_error), written by
      `Notifications.record_delivery/6` and `log_chat_delivery/6` and never
      mutated after its terminal status. NOTHING pruned it: it was the last
      append-only table in cloud/ with no retention arm
      (cch-w34-bl-delivery-log-has-no-retention). We keep 180 days — see
      `@notification_delivery_retention_days` for why that number and not 14.
      This arm is BATCHED, unlike the four above; see
      `@notification_delivery_batch_limit`.

  Idempotent: a run with nothing to prune returns `{:ok, %{events_deleted: 0,
  tokens_deleted: 0, samples_deleted: 0, deliveries_deleted: 0,
  notification_deliveries_deleted: 0}}` and never raises. `max_attempts: 1` —
  a missed daily prune is harmless (the next tick catches up), so there is
  nothing to retry.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.PlatformDelivery
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Registry.{AgentEvent, AgentToken}
  alias BarkparkCloud.Usage.Sample

  # Keep the metrics window + instance timeline; drop older beats.
  @event_retention_days 14
  # Keep a dead (revoked/expired) token this long past its terminal marker.
  @token_grace_days 30
  # Keep cached usage samples this long; the summary read only wants the latest.
  @sample_retention_days 14
  # Keep the platform's own delivery record this long — two quarters, so a
  # quarter-over-quarter comparison always has its predecessor to compare to.
  @delivery_retention_days 180

  # Keep a NOTIFICATION delivery row this long. CHOSEN, not inherited from the
  # 14-day sample window above, and the difference is the point: a usage sample
  # is a cache whose only reader wants the latest row, while a delivery log is
  # EVIDENCE a person reads — `GET /v1/notifications/deliveries` is the one
  # surface that answers "was I notified?", and a member who asks it about an
  # alert they think they missed is asking about something weeks or months old.
  # 180 days is the same window this file already gives the OTHER delivery log
  # (`@delivery_retention_days`, platform_deliveries): two full quarters, so a
  # quarter-over-quarter question always has its predecessor, and short enough
  # that the table is bounded forever. Pruning a delivery log on a sample table's
  # schedule would destroy the audit trail to save a megabyte.
  @notification_delivery_retention_days 180

  # One tick deletes at most this many notification delivery rows per statement,
  # and at most @notification_delivery_max_batches statements. The FIRST prune
  # after this ships is the only bulk one — every later tick removes a single
  # day's drift — and it must not be issued as one unbounded DELETE against a
  # table nobody has ever pruned.
  #
  # THE MEASUREMENT behind the size: production (cloud-db-1) held 2,160 rows /
  # 952 kB when this was re-derived — ~440 B/row — growing ~60 rows/day
  # platform-wide, one team owning 98%. One batch of 5,000 rows is ~2.2 MB: more
  # than TWICE the entire production table, so in practice the first prune is a
  # single statement with the bound never binding. The bound exists for the case
  # the measurement does not cover — a table that grew unwatched between this
  # commit and the day it first runs — and 10 batches gives one tick a ceiling of
  # 50,000 rows, ~23x the measured table, while the daily cron drains any
  # remainder against a 60 rows/day inflow.
  @notification_delivery_batch_limit 5_000
  @notification_delivery_max_batches 10

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    events_cutoff = DateTime.add(now, -@event_retention_days * 24 * 3600, :second)
    tokens_cutoff = DateTime.add(now, -@token_grace_days * 24 * 3600, :second)
    samples_cutoff = DateTime.add(now, -@sample_retention_days * 24 * 3600, :second)
    deliveries_cutoff = DateTime.add(now, -@delivery_retention_days * 24 * 3600, :second)

    {events_deleted, _} =
      from(e in AgentEvent, where: e.inserted_at < ^events_cutoff)
      |> Repo.delete_all()

    # Delete a token only once it has been UNUSABLE for the grace window — past
    # either terminal marker. A live token (both nil) matches neither clause and
    # is left alone; a token still within grace of its most-recent death survives.
    {tokens_deleted, _} =
      from(t in AgentToken,
        where:
          (not is_nil(t.revoked_at) and t.revoked_at < ^tokens_cutoff) or
            (not is_nil(t.expires_at) and t.expires_at < ^tokens_cutoff)
      )
      |> Repo.delete_all()

    # Drop cached usage samples past the retention window — keyed on the honest
    # sample time (`measured_at`), backed by the `barkpark_id + measured_at` index.
    {samples_deleted, _} =
      from(s in Sample, where: s.measured_at < ^samples_cutoff)
      |> Repo.delete_all()

    # Drop platform delivery rows past 180 days, keyed on `inserted_at` — the
    # instant the recorder wrote the row, which is the only clock on this table
    # that is never supplied by the caller (`first_seen_at` is, and a wrong one
    # must not be able to make a row immortal or delete it early).
    {deliveries_deleted, _} =
      from(d in PlatformDelivery, where: d.inserted_at < ^deliveries_cutoff)
      |> Repo.delete_all()

    # Drop notification delivery rows past 180 days, keyed on `inserted_at` —
    # the instant the send attempt was recorded. Time-keyed ONLY: there is no
    # team parameter anywhere in this query, so a row lives or dies by its own
    # age and one team's retention can never reach another team's rows (nor can
    # a team-scoped read of the log see a neighbour's, which is the router's
    # fence, not this worker's). Batched — see the constants above.
    notification_deliveries_deleted =
      prune_notification_deliveries(
        DateTime.add(now, -@notification_delivery_retention_days * 24 * 3600, :second)
      )

    {:ok,
     %{
       events_deleted: events_deleted,
       tokens_deleted: tokens_deleted,
       samples_deleted: samples_deleted,
       deliveries_deleted: deliveries_deleted,
       notification_deliveries_deleted: notification_deliveries_deleted
     }}
  end

  @doc """
  The notification-delivery prune, in bounded batches. Returns rows deleted.

  PUBLIC with explicit `limit` / `max_batches` so the BATCHING itself is
  testable: a test drives it at `limit: 2, max_batches: 2` over five old rows and
  gets four — a number a single unbounded `DELETE` could never return. A private
  helper at production constants would need 5,001 fixture rows to say anything,
  which is a load generator, not a test.

  Stops the instant a batch comes back SHORT: a short batch means the cutoff is
  exhausted, so a tick with nothing to prune costs exactly one SELECT and issues
  no DELETE at all.
  """
  @spec prune_notification_deliveries(DateTime.t(), pos_integer(), pos_integer()) ::
          non_neg_integer()
  def prune_notification_deliveries(
        cutoff,
        limit \\ @notification_delivery_batch_limit,
        max_batches \\ @notification_delivery_max_batches
      ) do
    Enum.reduce_while(1..max_batches, 0, fn _i, acc ->
      ids =
        from(d in Delivery,
          where: d.inserted_at < ^cutoff,
          select: d.id,
          limit: ^limit
        )
        |> Repo.all()

      case ids do
        [] ->
          {:halt, acc}

        ids ->
          {deleted, _} = Repo.delete_all(from(d in Delivery, where: d.id in ^ids))

          if length(ids) < limit do
            {:halt, acc + deleted}
          else
            {:cont, acc + deleted}
          end
      end
    end)
  end

  @doc "The retention window applied to `notification_deliveries`, in days."
  @spec notification_delivery_retention_days() :: pos_integer()
  def notification_delivery_retention_days, do: @notification_delivery_retention_days
end
