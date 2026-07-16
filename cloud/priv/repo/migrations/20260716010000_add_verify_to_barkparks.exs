defmodule BarkparkCloud.Repo.Migrations.AddVerifyToBarkparks do
  use Ecto.Migration

  # BP-ONB-09 backend — persist the on-demand golden-path VERIFY probe result as
  # a queryable fleet-row fact. Today `run_verify/3` is fire-and-forget: it
  # appends a `verify` agent_event to the timeline, but no `barkparks` column
  # carries the headline verdict, so the fleet list can't answer "when was this
  # instance last verified, and was it reachable?" without walking the event
  # stream.
  #
  # Two FLAT columns, mirroring the `update_*`/`health` cache idiom (a scalar
  # verdict on the row, not a list-time join): `last_verified_at` is when the
  # suite last ran, `verify_reachable` is the headline reachability of that run
  # (the envelope's `reachable`). Both NULL on a never-verified box — an honest
  # "no verdict yet", distinct from a real `false`. Additive ADD COLUMN,
  # metadata-only (no default, no backfill), matching the `add_*_to_barkparks`
  # precedent.
  def change do
    alter table(:barkparks) do
      add :last_verified_at, :utc_datetime_usec
      add :verify_reachable, :boolean
    end
  end
end
