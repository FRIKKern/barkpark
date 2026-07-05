defmodule Barkpark.Repo.Migrations.CreatePulseEventsAndCounters do
  use Ecto.Migration

  @moduledoc """
  Pulse (Shared Storm) — public anonymous event ingest.

  Two tables, deliberately NOT documents: pulse events are high-volume,
  tiny, ephemeral rows (TTL-swept), and the counter needs a race-free
  atomic increment — neither fits the Content document substrate.

    * `pulse_events`   — the ephemeral feed. `id` is the monotonic cursor
      clients poll with (`?since=<id>`); rows die after the channel TTL.
    * `pulse_counters` — one durable row per channel. `total` is the
      number of events EVER ingested (survives the sweep forever).
  """

  def change do
    create table(:pulse_events) do
      add :channel, :text, null: false
      add :payload, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The poll query: WHERE channel = ? AND id > ? ORDER BY id — and the
    # sweep: WHERE channel = ? AND inserted_at < ?.
    create index(:pulse_events, [:channel, :id])
    create index(:pulse_events, [:channel, :inserted_at])

    create table(:pulse_counters, primary_key: false) do
      add :channel, :text, primary_key: true
      add :total, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end
  end
end
