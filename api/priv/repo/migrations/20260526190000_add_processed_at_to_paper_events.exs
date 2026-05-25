defmodule Barkpark.Repo.Migrations.AddProcessedAtToPaperEvents do
  use Ecto.Migration

  @moduledoc """
  P6.U6a (barkpark-jwai) — the Barkpark half of the loop-closer.

  Adds a `processed_at` marker to `paper_events` so the paperflow-side reader
  loop (U6b) can fetch pending actionable intents (`action:*` / `simplify-*`),
  act on them, then mark each as processed. `NULL` = pending; a timestamp =
  consumed. Partial index covers the hot "pending only" lookup.
  """

  def up do
    alter table(:paper_events) do
      add :processed_at, :utc_datetime_usec
    end

    create index(:paper_events, [:processed_at], where: "processed_at IS NULL")
  end

  def down do
    drop index(:paper_events, [:processed_at], where: "processed_at IS NULL")

    alter table(:paper_events) do
      remove :processed_at
    end
  end
end
