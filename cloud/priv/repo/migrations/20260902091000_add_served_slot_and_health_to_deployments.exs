defmodule BarkparkCloud.Repo.Migrations.AddServedSlotAndHealthToDeployments do
  @moduledoc """
  site-spawner (node slot truth): THE DEPLOYMENT ROW LEARNS WHICH SLOT IS
  SERVING IT, AND WHETHER ITS HEALTH GATE ACTUALLY RAN.

  ## The three columns did not exist at all

  `deploy/site-spawner-node-live-proof.sh` reads `deployment.slot`,
  `deployment.port` and `deployment.health_exit_code` off `bp cloud site deploy
  -o json`. `deployment_json/1` emitted none of the three — and the reason was
  one layer lower than a serializer omission: the `deployments` table had no
  such columns. The two a naive grep hits (`add_port_base_to_sites`) are SITE
  columns, and `router.ex`'s `port: s.port` is the SITE serializer. So the
  node-slot half of a deploy was, end to end, unrecorded.

  ## health_exit_code IS NULLABLE, AND THAT IS THE WHOLE POINT

  A non-nullable integer cannot tell "the HEALTH stage never ran" from "it ran
  and exited 0" — and 0 IS SUCCESS, so the missing measurement renders as a
  pass. A build that died in BUILD would read as health-certified. The column is
  therefore nullable with NO default, nothing coerces it, and the serializer
  emits `null` for "not measured" rather than a zero.

  The discipline is already in this repo, argued from a defect it caused:
  `internal/cloudclient/client.go`'s `Deployment` carries its six cause/lifecycle
  fields as POINTERS on purpose, because a zero value cannot tell "the control
  plane did not send this key" from "the control plane measured it as empty",
  and nil must render as an explicit dash. Same class, same answer.

  ## `slot` is the SERVED slot, never the intended one

  In a blue/green deploy the Caddy upstream port IS the slot truth. What lands
  in these columns is read BACK out of the box's Caddyfile after the flip has
  committed (`deploy/site-deploy-node.sh` emits it as its report-only `SERVED`
  marker; `Sites.Deploy` maps the served PORT onto the site's own `port_base` to
  name the slot). A `slot` derived from the control plane's INTENT would report
  intent while looking like state — the exact failure three deploy-truth lanes
  closed on 2026-08-24. When the served port matches neither of the site's two
  allocated slots, `slot` stays NULL while `port` still carries the measurement:
  "we do not know which half" is a different sentence from "we did not look".

  ## Why this ALTER is safe on the live table

  `add_if_not_exists` rather than `add`: this migration first shipped under
  version 20260901120000, which collided with #14853's
  `finalize_lapsed_trial_subscriptions` (Ecto refuses a duplicated version), so
  it was re-stamped to 20260902091000. Any database that already ran the old
  version has the three columns; the guarded add makes the re-stamp a no-op
  there instead of a failed ALTER.

  All three columns are NULLABLE with NO default, so this is a catalog-only
  `ALTER` — no table rewrite, no per-row work, and the ACCESS EXCLUSIVE lock is
  held for a catalog update rather than a scan of the ~45 MB `deployments`
  table. Nothing is backfilled: every existing row is honestly unknown, and a
  backfilled slot would be a guess at which half was serving months ago. No
  index — nothing queries these columns yet, and an index with no reader is
  write cost for nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:deployments) do
      # The slot Caddy was measured to be serving after SWITCH ("blue" | "green"),
      # NULL on every static deploy (a symlink swap has no slot), on any node
      # build that died before SWITCH, and whenever the served port matched
      # neither of this site's allocated slots.
      add_if_not_exists :slot, :string

      # The loopback port that slot answers on — the literal read out of the
      # site's Caddy marker block. Independently nullable from `slot`: the port
      # is the stronger fact (it is what the Caddyfile carries), the slot is a
      # NAME derived from it against `sites.port_base`.
      add_if_not_exists :port, :integer

      # The HEALTH stage's exit code: 0 (ran, passed), 14 (ran, failed — the
      # cross-engine HEALTH convention), or NULL (never measured). NO DEFAULT,
      # deliberately: see the moduledoc.
      add_if_not_exists :health_exit_code, :integer
    end
  end
end
