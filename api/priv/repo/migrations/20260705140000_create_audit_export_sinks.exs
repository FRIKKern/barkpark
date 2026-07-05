defmodule Barkpark.Repo.Migrations.CreateAuditExportSinks do
  @moduledoc """
  era-w5-siem-export — configured SIEM/webhook endpoints that the audit log
  streams to. Cursor-based tail-shipping: each sink carries a `last_exported_id`
  high-water mark into `audit_events`, so export is fully decoupled from the
  emit path (no per-mutation overhead, no in-transaction HTTP). A `nil`
  `workspace_id` is a GLOBAL sink (every event); a set one ships only that
  workspace's events. Auto-disable columns mirror the webhook substrate.
  """
  use Ecto.Migration

  def change do
    create table(:audit_export_sinks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :binary_id
      add :name, :string, null: false
      add :url, :string, null: false
      add :secret, :string
      add :format, :string, null: false, default: "generic"
      add :active, :boolean, null: false, default: true
      # High-water mark into audit_events.id — the tail-shipping cursor.
      add :last_exported_id, :bigint, null: false, default: 0
      # Auto-disable substrate, mirroring webhooks.
      add :consecutive_failures, :integer, null: false, default: 0
      add :auto_disabled_at, :utc_datetime_usec
      add :disable_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:audit_export_sinks, [:active])
    create index(:audit_export_sinks, [:workspace_id])
  end
end
