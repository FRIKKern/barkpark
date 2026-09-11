defmodule BarkparkCloud.Repo.Migrations.AddRouteStatusToDeployments do
  @moduledoc """
  deploy-reliability W21 (charter D608): THE DEPLOYMENT ROW LEARNS WHETHER ITS
  CADDY ROUTE WAS ACTUALLY ARMED.

  ## The decision was durable and unreported

  Both site engines emit `BPSTAGE name=ROUTE status=<ok|failed> detail="…"`
  after their Caddy arming attempt, into the run's durable status file. Wave 21
  measured where that reaches: nowhere. The log tail structurally cannot carry
  it (`emit()` writes the BPSTAGE line to stdout and to the STATUS file, never
  to the LOG file), the stage fold discarded it through `parse_stage_line/2`'s
  `name in @stage_names` guard, and on this side the `deployments` table had no
  column for it. The nearest thing was `console jsonb[]`, and of 19,327 rows
  carrying console entries, ZERO contained "ROUTE".

  PR #17569 made the runner forward it; this migration is where it lands.

  ## Columns, not console entries

  `console` is capped at 300 lines and drops its oldest, so a ROUTE entry on a
  chatty build is droppable — and an aggregate over a droppable line cannot
  answer "how many deploys failed to arm their route". A column can be counted,
  which is the entire criterion this wave is trying to make answerable:

      SELECT count(*) FROM deployments WHERE route_status IS NOT NULL;

  ## Both columns are NULLABLE with NO default

  NULL means "never measured" and it is the honest answer for every row written
  before the engines gained ROUTE (2026-08-08), every row from a box that has
  not pulled since, and every run that died before arming. A default would have
  to be "ok" — the SUCCESS token — so a defaulted row would certify an arm
  nobody attempted. That is the same discipline `health_exit_code` states one
  migration family over (20260902091000), argued from the same defect: a zero
  value cannot tell "not measured" from "measured, and it passed".

  Nothing is backfilled. A backfilled `route_status` would be a guess about a
  Caddyfile that has moved on.

  ## Why this ALTER is safe on the live table

  `add_if_not_exists`, both columns nullable with no default: a catalog-only
  `ALTER`, no table rewrite, no per-row work, and the ACCESS EXCLUSIVE lock is
  held for a catalog update rather than a scan of `deployments`. No index —
  nothing queries these columns on a hot path yet, and an index with no reader
  is write cost for nothing. The counting query above is an operator's one-off.
  """

  use Ecto.Migration

  def change do
    alter table(:deployments) do
      # The box's own ROUTE token: "ok" (the route is armed), "failed" (the arm
      # was refused), NULL (never measured).
      add_if_not_exists :route_status, :string

      # The box's own sentence about it ("already armed", "caddy validate
      # rejected the block"). Box-authored free text, relayed verbatim — the
      # same class as a stage's `detail`.
      add_if_not_exists :route_detail, :string
    end
  end
end
