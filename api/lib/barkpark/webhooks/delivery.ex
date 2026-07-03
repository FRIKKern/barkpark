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
  @source_kinds ~w(document media)

  schema "webhook_deliveries" do
    field :endpoint_id, Ecto.UUID
    field :event_id, :integer
    field :source_kind, :string, default: "document"
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
      "media" -> validate_required(changeset, [:payload_snapshot])
      _ -> validate_required(changeset, [:endpoint_id, :event_id])
    end
  end
end
