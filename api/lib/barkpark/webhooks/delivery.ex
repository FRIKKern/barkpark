defmodule Barkpark.Webhooks.Delivery do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending ok failed_giveup)

  # A delivery row's SOURCE — which rebuild path `RetryWorker` /
  # `StuckDeliverySweeper` use to RESUME it (both branch on this via
  # `Barkpark.Webhooks.PayloadRebuild`, the single place the branch lives):
  #
  #   * "document" — rebuild the signed payload from the durable `mutation_events`
  #     row (`event_id`), keyed off the live `webhooks` row (`endpoint_id`).
  #     `payload_snapshot` stays NIL.
  #   * "media"    — the source event is gone by design (`media.deleted` passes the
  #     file struct at delete time; nothing persists it), so the row carries a
  #     `payload_snapshot` (url / secret / body) and resumes FROM it.
  #     `endpoint_id` / `event_id` are NULL (media endpoints are config-driven via
  #     `:media_webhooks`, not `webhooks` rows).
  #   * "chat_blocked" — a herd-layer blocked-session notification (charter
  #     D57h–D59h). Targets a real workspace-scoped `webhooks` row (`endpoint_id`)
  #     but has no `mutation_events` source (`event_id` NULL), so it carries a
  #     `payload_snapshot` (the encoded body) and resumes FROM it. Dedup is a
  #     SEPARATE axis — `dedupe_key` (the pending ask's `chat_messages` id) under
  #     a partial UNIQUE(endpoint_id, dedupe_key) WHERE source_kind='chat_blocked'
  #     — so a re-sweep of the same still-blocked ask never fires twice.
  #   * "test" — a one-shot admin PROBE (`POST .../test-send`, GR45). Like media
  #     it carries a `payload_snapshot` (the synthetic body) and no `event_id`,
  #     but it also keeps `endpoint_id` NULL so a test — success OR failure —
  #     never perturbs the target endpoint's consecutive-failure auto-disable
  #     accounting (`mark_*` no-op on a nil `endpoint_id`). Never retried: a row
  #     stranded "pending" by a mid-probe crash is abandoned (`PayloadRebuild`
  #     returns `:gone`), because the admin has long since moved on.
  @source_kinds ~w(document media audit chat_blocked test)

  schema "webhook_deliveries" do
    field :endpoint_id, Ecto.UUID
    field :event_id, :integer
    field :source_kind, :string, default: "document"
    # Exactly-once discriminator for chat_blocked rows only (the pending ask's
    # stringified integer PK); NULL for every other source_kind.
    field :dedupe_key, :string
    field :payload_snapshot, :map
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_status_code, :integer
    field :last_error_text, :string
    field :last_latency_ms, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :endpoint_id,
      :event_id,
      :source_kind,
      :dedupe_key,
      :payload_snapshot,
      :status,
      :attempts,
      :last_status_code,
      :last_error_text,
      :last_latency_ms
    ])
    |> validate_inclusion(:source_kind, @source_kinds)
    |> validate_required_for_kind()
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:endpoint_id, :event_id])
  end

  # Document rows are keyed on (endpoint_id, event_id) — both required so the
  # UNIQUE dedup + FK-backed rebuild hold. Media rows have neither (config-driven
  # endpoint, source event gone), so they instead require a `payload_snapshot` to
  # be resumable. The default kind ("document") preserves the original required
  # set exactly, so existing document callers are unaffected.
  defp validate_required_for_kind(changeset) do
    case get_field(changeset, :source_kind) do
      # Media and test rows both key on the snapshot alone: no `webhooks` row
      # (`endpoint_id` NULL — media is config-driven, a test intentionally leaves
      # it NULL so it never touches endpoint health) and no `mutation_events`
      # source (`event_id` NULL). The synthetic/verbatim body lives in the snapshot.
      kind when kind in ["media", "test"] ->
        validate_required(changeset, [:payload_snapshot])

      # Audit rows target a real webhook (`endpoint_id`) but carry no content
      # `event_id` (the source lives in `audit_events`, a different table with
      # its own FK), so they key on the snapshot to stay resumable — like media,
      # never deduped (the bridge fires once per emit).
      "audit" ->
        validate_required(changeset, [:endpoint_id, :payload_snapshot])

      # Chat-blocked rows target a real webhook (`endpoint_id`) but carry no
      # content `event_id`; they resume from the snapshotted body and dedup on
      # `dedupe_key` (the pending ask id) under the partial UNIQUE index, so all
      # three are required. `event_id` stays NULL.
      "chat_blocked" ->
        validate_required(changeset, [:endpoint_id, :payload_snapshot, :dedupe_key])

      _ ->
        validate_required(changeset, [:endpoint_id, :event_id])
    end
  end
end
