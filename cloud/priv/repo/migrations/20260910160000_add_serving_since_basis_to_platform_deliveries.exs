defmodule BarkparkCloud.Repo.Migrations.AddServingSinceBasisToPlatformDeliveries do
  use Ecto.Migration

  # deploy-reliability W29 — WHICH CLOCK PRODUCED serving_since.
  #
  # `serving_since` is non-NULL on both legs, and the two legs DERIVE it from
  # different things:
  #
  #   * cp       — the control plane's /health `serving_since`, which is
  #                PROCESS-DERIVED (BarkparkCloud.Health: "this is when THIS BEAM
  #                started, not when this sha was deployed"). A bare restart that
  #                deploys nothing moves it FORWARD, so any lag measured against
  #                it is an UPPER BOUND that reads SMALLER than the truth.
  #   * instance — the mtime of `/opt/barkpark/.instance-deploy-last`, which IS
  #                the flip instant.
  #
  # The recorder has always known which one it was writing (deploy.yml prints
  # "(basis: process start, not the flip instant)" on one leg and "(basis: mtime
  # of .instance-deploy-last, the flip instant)" on the other) and has never
  # written it down. A reader of the table alone therefore cannot tell an upper
  # bound from a real timestamp, and a cross-target lag comparison silently mixes
  # the two.
  #
  # NULLABLE, NO DEFAULT, NO BACKFILL — the same law `carried` and `transition`
  # are held to on this table (charter D422/D437). NULL means NOT RECORDED, and
  # it is NOT a third basis: every row written before this column existed carries
  # NULL, and there is no fact on this control plane from which those rows could
  # be reclassified. A default of "process_start" would mint a measurement for
  # every historical instance row, which is the exact lie this column exists to
  # end.
  #
  # EXPAND-SAFE. The idle slot boots and migrates WHILE THE OLD SLOT STILL SERVES
  # (cloud/Dockerfile), so this must be readable by a release that knows nothing
  # about it: an additive nullable column with no default is, a NOT NULL one is
  # not.
  #
  # NOT INDEXED. Two live values over the whole table discriminate nothing, and
  # no reader filters on it — an index here would be write cost for nobody.
  def change do
    alter table(:platform_deliveries) do
      add :serving_since_basis, :string
    end
  end
end
