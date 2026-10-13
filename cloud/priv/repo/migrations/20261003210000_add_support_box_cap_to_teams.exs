defmodule BarkparkCloud.Repo.Migrations.AddSupportBoxCapToTeams do
  @moduledoc """
  Owner ruling #37 (2026-10-03): a per-team cap on CP-provisioned support boxes,
  which an operator can raise per team. ADDITIVE ONLY: one nullable column. NULL
  means "the platform default" (`:support_box_cap_default`), so every existing
  team keeps working with no backfill.
  """
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :support_box_cap, :integer, null: true
    end

    create constraint(:teams, :teams_support_box_cap_non_negative,
             check: "support_box_cap IS NULL OR support_box_cap >= 0"
           )
  end
end
