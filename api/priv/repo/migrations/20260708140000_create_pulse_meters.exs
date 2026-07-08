defmodule Barkpark.Repo.Migrations.CreatePulseMeters do
  use Ecto.Migration

  @moduledoc """
  Pulse (Shared Storm) — durable accumulators that aren't per-channel counts.

  First tenant: `cost` — the storm's total accrued compute cost since the
  telemetry started, integrated CPU-share × price over time and stored in
  NANO-euros (integer, so the atomic increment never drifts and a single
  cheap tick — fractions of a nano-euro — still lands). Survives restarts,
  exactly like `pulse_counters` — a deploy that swaps the slot must not reset
  "cost so far".
  """

  def change do
    create table(:pulse_meters, primary_key: false) do
      add :name, :text, primary_key: true
      add :nanos, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end
  end
end
