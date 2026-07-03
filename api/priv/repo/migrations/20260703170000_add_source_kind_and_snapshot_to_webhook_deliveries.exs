defmodule Barkpark.Repo.Migrations.AddSourceKindAndSnapshotToWebhookDeliveries do
  use Ecto.Migration

  # Converge MEDIA lifecycle webhooks onto the shared durable-row retry machinery
  # (kills the in-task `Process.sleep` twin in `Media.Delivery.Events`). Additive,
  # reversible, no backfill.
  #
  #   * `source_kind` — "document" (default) | "media". `RetryWorker` and
  #     `StuckDeliverySweeper` BRANCH on this to choose the payload-rebuild source.
  #     Every existing row adopts the `default: "document"`, which is exactly right
  #     (they ARE document rows), so no backfill is needed.
  #   * `payload_snapshot` — NULLABLE. NIL for document rows: they rebuild the
  #     signed body from the durable `mutation_events` row, still their truth.
  #     POPULATED for media rows only, because media's source event is gone by
  #     design (`media.deleted` hands the file struct at delete time and the
  #     underlying row is already gone), so the resumable unit (url/secret/body)
  #     MUST be snapshotted to survive a crash / BEAM restart.
  #
  # `endpoint_id` / `event_id` are relaxed to NULLABLE: a media row has neither a
  # `webhooks` row (endpoints are config-driven via `:media_webhooks`) nor a
  # `mutation_events` row. The FK constraints stay intact (NULLs are exempt from FK
  # checks), and the existing UNIQUE(endpoint_id, event_id) dedup is untouched for
  # document rows — Postgres treats NULLs as distinct, so unbounded media rows with
  # (NULL, NULL) never collide (media is not deduped, matching prior behaviour:
  # each lifecycle event fires once and is never re-broadcast).
  def up do
    alter table(:webhook_deliveries) do
      add :source_kind, :string, null: false, default: "document"
      add :payload_snapshot, :map
    end

    execute "ALTER TABLE webhook_deliveries ALTER COLUMN endpoint_id DROP NOT NULL"
    execute "ALTER TABLE webhook_deliveries ALTER COLUMN event_id DROP NOT NULL"
  end

  def down do
    # Reversible. Media rows (endpoint_id / event_id NULL) must be cleared before
    # NOT NULL can be re-imposed; acceptable because `webhook_deliveries` is a
    # transient delivery-LOG table — no durable content lives here, and any media
    # rows still pending would simply be re-created on the next dispatch.
    execute "DELETE FROM webhook_deliveries WHERE source_kind = 'media'"
    execute "ALTER TABLE webhook_deliveries ALTER COLUMN event_id SET NOT NULL"
    execute "ALTER TABLE webhook_deliveries ALTER COLUMN endpoint_id SET NOT NULL"

    alter table(:webhook_deliveries) do
      remove :payload_snapshot
      remove :source_kind
    end
  end
end
