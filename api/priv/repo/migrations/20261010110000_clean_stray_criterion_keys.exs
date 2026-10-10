defmodule Barkpark.Repo.Migrations.CleanStrayCriterionKeys do
  use Ecto.Migration

  @moduledoc """
  The reviewed data step for pds-bl-stray-keys-on-acceptance-criteria, run by
  deploy (lead ruling: a migration, not an owner step). From this release
  `Tasks.Validation` refuses any acceptance_criteria key outside the declared
  set; this cleans the rows that already carry one, in the same deploy, so no
  doc patch on them is ever refused for a key nobody wrote on purpose.

  Exactly `Barkpark.Tasks.StrayCriterionKeys.plan/2`: drop `index` where it
  equals the entry's position, fold a singular `amendment` into `amendments`,
  move `note` into `attempts`, drop a padded `" met"`; anything else is left
  (and reported by the Release re-run). Measured on the live snapshot: 23
  published rows. Idempotent — a clean row is not written — and rev-fenced.

  `down/0` is a no-op on purpose: the dropped keys carried nothing a reader
  used, and restoring them would re-arm the refusal against those rows.
  """

  def up do
    Barkpark.Tasks.StrayCriterionKeys.migrate(repo())
    :ok
  end

  def down, do: :ok
end
