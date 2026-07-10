defmodule Barkpark.Repo.Migrations.IdempotencyClaimFirst do
  use Ecto.Migration

  @moduledoc """
  Claim-first idempotency: a reservation row is inserted BEFORE the handler runs,
  so `status_code`/`response_body` are unknown at claim time and must be nullable.
  A `state` column distinguishes a held reservation (`pending`) from a cached
  response (`completed`).

  Safe DDL — the table holds only short-lived (24h TTL) idempotency rows:
    * dropping NOT NULL is metadata-only (no rewrite, no lock of consequence).
    * adding a column WITH a constant default is metadata-only on PG 11+.
  Existing rows are all completed responses, so backfilling `state` = "completed"
  via the column default is correct.
  """

  def up do
    alter table(:idempotency_keys) do
      modify :status_code, :integer, null: true
      modify :response_body, :text, null: true
      add :state, :string, null: false, default: "completed"
    end
  end

  def down do
    # A pending row carries NULL status/body; those must be cleared before the
    # NOT NULL constraints can be restored (the table is transient — safe).
    execute("DELETE FROM idempotency_keys WHERE state = 'pending'")

    alter table(:idempotency_keys) do
      remove :state
      modify :response_body, :text, null: false
      modify :status_code, :integer, null: false
    end
  end
end
