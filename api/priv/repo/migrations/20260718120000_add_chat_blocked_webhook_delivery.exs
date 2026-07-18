defmodule Barkpark.Repo.Migrations.AddChatBlockedWebhookDelivery do
  use Ecto.Migration

  # Herd-layer s5 (chat-tui charter D57h–D59h): a Studio chat session blocked on
  # a pending ask longer than a per-workspace threshold emits EXACTLY ONE
  # debounced webhook (openclaw/Discord ride the existing signed delivery path).
  # Dispatcher-native, a NEW `source_kind: "chat_blocked"` — never the audit
  # category (org-scoped, never-deduped, hash-chained), never the dead Notifier.
  #
  #   * `webhook_deliveries.dedupe_key` (TEXT, nullable) — the pending ask's
  #     `chat_messages` integer PK stringified. Globally unique per ask, so a
  #     re-sweep of the SAME still-blocked ask claims the same key and no-ops.
  #     NULL for every other source_kind (document/media/audit key differently).
  #
  #   * PARTIAL UNIQUE (endpoint_id, dedupe_key) WHERE source_kind='chat_blocked'
  #     — the exactly-once claim gate. `event_id` stays NULL on chat_blocked rows
  #     (no `mutation_events` source), and NULL event_ids are never deduped by the
  #     existing UNIQUE(endpoint_id, event_id); this partial index is a SEPARATE
  #     dedup axis scoped to chat_blocked rows only, so it never touches the
  #     document/media/audit dedup behaviour. `claim_chat_blocked_delivery/3`
  #     CASes on it via `on_conflict: :nothing`.
  #
  #   * `webhooks.blocked_threshold_s` (INTEGER, nullable) — DOUBLES as the
  #     chat_blocked subscription discriminator AND the per-workspace threshold:
  #     no row / NULL = OFF (default), a row with a threshold = subscribed. Enabling
  #     is a pure config insert (a workspace-scoped `webhooks` row with a threshold)
  #     — zero code change. Never overloads `audit_categories`; content fan-out
  #     (`active_webhooks_for/4`) excludes rows with a non-NULL threshold so the
  #     two channels never cross.
  #
  # Additive, reversible, no backfill: every existing delivery row reads
  # dedupe_key NULL (correct — they are not chat_blocked rows) and every existing
  # webhook reads blocked_threshold_s NULL (correct — off by default).
  def up do
    alter table(:webhook_deliveries) do
      add :dedupe_key, :text
    end

    alter table(:webhooks) do
      add :blocked_threshold_s, :integer
    end

    create unique_index(:webhook_deliveries, [:endpoint_id, :dedupe_key],
             where: "source_kind = 'chat_blocked'",
             name: :webhook_deliveries_chat_blocked_dedupe_index
           )
  end

  def down do
    drop index(:webhook_deliveries, [:endpoint_id, :dedupe_key],
           name: :webhook_deliveries_chat_blocked_dedupe_index
         )

    alter table(:webhooks) do
      remove :blocked_threshold_s
    end

    alter table(:webhook_deliveries) do
      remove :dedupe_key
    end
  end
end
