defmodule Barkpark.Repo.Migrations.AddAutodisableToWebhooks do
  use Ecto.Migration

  # Additive / reversible / no-backfill. Auto-disable substrate for permanently
  # dead endpoints: `consecutive_failures` counts TRUE terminal give-ups
  # (post retry-classification) and resets to 0 on any successful delivery; when
  # it crosses `:webhook_auto_disable_threshold` the row is flipped inactive and
  # stamped with `auto_disabled_at` / `disable_reason`. Existing rows adopt the
  # `default: 0` — no data migration is needed. `change/0` auto-reverses (each
  # `add` drops cleanly on rollback).
  def change do
    alter table(:webhooks) do
      add :consecutive_failures, :integer, null: false, default: 0
      add :auto_disabled_at, :utc_datetime
      add :disable_reason, :string
    end
  end
end
