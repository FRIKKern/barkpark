defmodule BarkparkCloud.Registry.FleetSettings do
  @moduledoc """
  isu-w5.2 — fleet-WIDE operator settings, held in a single row.

  Today this carries one field, `autoupdate_halted`: the platform-operator kill
  switch that stops the `AutoupdateRolloutWorker` from ADVANCING (triggering new
  self-updates) across the whole fleet. Halting never touches settle bookkeeping
  — already in-flight boxes keep resolving so fleet state stays honest — it only
  freezes new advancement until an operator resumes.

  Single-row by convention: the registry reads-or-defaults the one row and
  upserts it (`Registry.autoupdate_halted?/0`, `Registry.set_autoupdate_halted/1`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fleet_settings" do
    field :autoupdate_halted, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Narrow changeset — only the halt flag is castable."
  def changeset(fleet_settings, attrs) do
    fleet_settings
    |> cast(attrs, [:autoupdate_halted])
    |> validate_required([:autoupdate_halted])
  end
end
