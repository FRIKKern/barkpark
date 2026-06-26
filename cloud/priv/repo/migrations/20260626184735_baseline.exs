defmodule BarkparkCloud.Repo.Migrations.Baseline do
  use Ecto.Migration

  def change do
    # The one and only baseline table for the control plane skeleton: a place
    # to stamp the schema version and other control-plane-wide key/value meta.
    # Identity, instance-registry, teams, and barkparks tables are cloud-8/9.
    create table(:control_plane_meta, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:control_plane_meta, [:key])
  end
end
