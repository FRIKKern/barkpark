defmodule Barkpark.Repo.Migrations.AddMediaDeliveryDedupeIndex do
  use Ecto.Migration

  # Media webhook deliveries were NEVER deduped (asm-bl-media-delivery-event-id-dedup):
  # `create_media_delivery/1` inserts `source_kind: "media"` with `endpoint_id` NULL
  # (config-driven `:media_webhooks` endpoints) and `event_id` NULL (the source event
  # is gone by design), so the document path's UNIQUE(endpoint_id, event_id) covers
  # nothing here — a media re-drive (the stuck-processing sweeper re-firing
  # `media.processed`) delivered the SAME logical event twice.
  #
  # The fix rides the EXISTING exactly-once column, `dedupe_key`, exactly as
  # chat_blocked does — not `event_id`, which is an INTEGER FK to `mutation_events`
  # and cannot hold a synthetic media identity without dropping that FK.
  #
  #   * PARTIAL UNIQUE (dedupe_key) WHERE source_kind = 'media'.
  #     The column list is `dedupe_key` ALONE and that is load-bearing: media rows
  #     carry `endpoint_id` NULL, and a NULL anywhere in a btree unique tuple never
  #     collides, so a (endpoint_id, dedupe_key) index — the chat_blocked shape —
  #     would be INERT for media. The endpoint is folded INTO the key instead (the
  #     derivation in `Webhooks.create_media_delivery/1` hashes the target url with
  #     the event identity), so two configured endpoints still each get the event.
  #
  #   * NO BACKFILL, deliberately. Every pre-existing media row has `dedupe_key`
  #     NULL; NULLs never collide under this index, so (a) the CREATE cannot fail on
  #     historical duplicates, and (b) history is preserved verbatim — old rows stay
  #     un-deduped rather than being retro-keyed into a collision. Rows whose
  #     snapshot carries no derivable identity (an unparseable body, or a body
  #     without event/dataset/media_file_id) likewise keep a NULL key and keep the
  #     old at-least-once behaviour, which is the honest fallback: a key we cannot
  #     derive must not be invented.
  #
  # Additive and reversible: `down` drops only this index.
  #
  # `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).
  def up do
    create unique_index(:webhook_deliveries, [:dedupe_key],
             where: "source_kind = 'media'",
             name: :webhook_deliveries_media_dedupe_index
           )
  end

  def down do
    drop index(:webhook_deliveries, [:dedupe_key], name: :webhook_deliveries_media_dedupe_index)
  end
end
