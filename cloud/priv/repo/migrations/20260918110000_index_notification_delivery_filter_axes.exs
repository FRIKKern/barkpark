defmodule BarkparkCloud.Repo.Migrations.IndexNotificationDeliveryFilterAxes do
  use Ecto.Migration

  @moduledoc """
  cch-w32-bl — THE EMPTY-FILTER CLIFF. Three compound indexes, one per filter
  axis `list_deliveries/2` offers, each `(team_id, <axis>, inserted_at)`.

  ## The defect, RE-MEASURED on this tree (not inherited from the filing)

  `GET /v1/notifications/deliveries?status=…` orders by `(inserted_at DESC, id
  DESC)` and stops at the LIMIT. When the filter matches PLENTY of rows the
  existing `(team_id, inserted_at)` index carries the ORDER BY, the scan stops
  after ~a page, and the read is 7 buffers. When the filter matches NOTHING or
  ALMOST nothing the LIMIT never fills, so the planner flips to a bitmap scan on
  `(team_id)` and reads the team's ENTIRE partition to return zero rows.

  EXPLAIN (ANALYZE, BUFFERS) on a seeded 250 000-row corpus, one 50 000-row hot
  team (PG 17, local; buffers, not milliseconds):

      case                                  BEFORE            AFTER
      ?status=suppressed  (empty, in-vocab)  1159 buf          12 buf
      ?status=bogus       (empty, unknown)   1153 buf           3 buf
      ?status=pending     (rare, 50 rows)    1153 buf          54 buf
      ?event=bogus        (empty, OPEN vocab) 1153 buf          3 buf
      ?channel=bogus      (empty)            1153 buf           3 buf
      ?status=failed      (common, CONTROL)     11 buf           6 buf
      no filter           (CONTROL)              7 buf           7 buf

  Every BEFORE row above reports `Rows Removed by Filter: 50000` — the whole
  team partition, read to return nothing. Both CONTROLs are unchanged, which is
  the point: this is not a plan the fix perturbs, it is a plan the fix replaces
  only where the old one fell off.

  ## Why THREE indexes and not one

  The filing named only `status`. The measurement above says `event` and
  `channel` fall off the identical cliff, and all three are reachable from the
  SHIPPED console: `app.js` renders channel and status as chip rows over the
  schema's closed vocabularies (a team that never used Discord clicks "Discord"
  and gets the empty-result cliff), and renders `event` as a FREE-TEXT input —
  so `event` is the axis a human can miss on by one keystroke, and the one no
  vocabulary check could ever rescue.

  ## Why NOT a vocabulary check instead (the decision, with its measurement)

  Rejecting an out-of-vocabulary `status`/`channel` at the door would fix ONE
  line of the table above (`?status=bogus`) and neither of the other two: a
  RARE-but-real value (`?status=pending`, 50 real rows) and an open-vocabulary
  axis (`?event=`) are both in-vocabulary by construction. With the index the
  unknown-value case costs 3 buffers, so the performance argument for a
  gatekeeper is gone entirely — and `list_deliveries/2`'s moduledoc already
  records why an unknown filter is matched LITERALLY rather than dropped.
  The read contract is therefore unchanged by this migration.

  ## Why NOT `CREATE INDEX CONCURRENTLY`

  Charter D366 records a PROVED fail-green trap: an interrupted concurrent build
  leaves `indisvalid = false`, the `IF NOT EXISTS` retry answers `NOTICE …
  skipping` and RETURNS SUCCESS, and `schema_migrations` stamps the version, so a
  permanently dead index ships green. A plain build cannot enter that state — it
  either commits or rolls back with the version unstamped.

  The cost of the plain build is the write lock, and it is MEASURED, not assumed.
  On the 250 000-row corpus the three builds took 3.2 s / 5.0 s / 5.3 s. The
  production `notification_deliveries` table is ~2k rows (`Web.Router`'s own
  note above the deliveries route, 2026-09), two orders of magnitude smaller, and
  `Workers.AgentRetentionWorker` prunes it past 180 days so it stays that way.
  A sub-100 ms SHARE lock on a log nothing reads synchronously is the cheaper
  risk than a category of failure that ships silently.
  """

  def change do
    create(index(:notification_deliveries, [:team_id, :status, :inserted_at]))
    create(index(:notification_deliveries, [:team_id, :event, :inserted_at]))
    create(index(:notification_deliveries, [:team_id, :channel, :inserted_at]))
  end
end
