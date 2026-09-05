defmodule BarkparkCloud.Push.DevicePushToken do
  @moduledoc """
  One registered mobile DEVICE that wants needs-you push notifications — the
  push-relay spike's schema half (mobile charter D15).

  Mirrors `Accounts.UserToken`'s discriminated row shape: there the
  discriminator is `context` ("session" / "pat" / …); here it is `platform`
  ("apns" | "fcm"). Per-user × per-device ROWS — a user with an iPhone and an
  Android tablet holds two rows — never a team-level config blob.

  ## Severability = ROW-ABSENCE

  This table IS the feature switch (the chat_blocked webhook-row pattern): with
  zero rows, the entire push relay is inert — the inbound
  `/v1/relay/chat-blocked/:barkpark_id` receiver still verifies its HMAC and
  answers 202, but the fan-out selects nothing, no Oban job is enqueued, no
  worker runs. No feature flag exists anywhere in the path; deleting rows is
  the complete off switch, and the wave-2 relay BUILD composes on top without
  touching this contract.

  ## Custody

  `token` is the platform-issued device push token — an ADDRESS we must present
  to APNs/FCM verbatim, not a bearer credential against our own API. Unlike
  `user_tokens` there is therefore no hash-at-rest: the plaintext is stored
  (the row is still team-invisible; it is never serialized by any route).

  Lifecycle mirrors the user_tokens twin:

    * `revoked_at` — tombstone. Stamped when the platform reports the token
      unregistered/invalid (the delivery worker self-heals) or when a future
      explicit-unregister endpoint lands. A revoked row never receives sends.
    * `last_used_at` — refreshed on every successful delivery; feeds the wave-2
      stale-token reaper (design notes in `BarkparkCloud.Push`).
    * `metadata` — client-supplied device descriptors (model, app version …),
      display-only, never trusted for routing.

  UNIQUE(user_id, platform, token) makes registration idempotent: the app
  re-registers on every launch and upserts (un-revoking) the same row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The platform vocabulary — the two stores we can deliver to. Bounded on
  # purpose; a new platform is a schema-review event, not a free string.
  @platforms ~w(apns fcm)

  schema "device_push_tokens" do
    field :platform, :string
    field :token, :string
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :user, BarkparkCloud.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The allowed platforms (`apns` | `fcm`)."
  def platforms, do: @platforms

  @doc """
  Changeset for a device registration. Requires an owner, a platform from the
  bounded vocabulary, and a non-empty token (APNs tokens are 64 hex bytes, FCM
  tokens vary — real tokens are <= ~350 chars; the cap leaves headroom without
  encoding either format).

  The 1024-BYTE cap (counted in bytes, not graphemes — a multibyte token must
  not sneak past) exists because `token` participates in the
  UNIQUE(user_id, platform, token) btree index, and Postgres rejects index
  rows over ~2704 bytes at INSERT time. A cap above that turns an oversize
  token into a raw `Postgrex.Error` 500 instead of this changeset's 422
  (wave-2 hardening, adversarial review of PR #6030).
  """
  def changeset(device_token, attrs) do
    device_token
    |> cast(attrs, [:platform, :token, :metadata, :revoked_at, :last_used_at, :user_id])
    |> validate_required([:platform, :token, :user_id])
    |> validate_inclusion(:platform, @platforms)
    |> validate_length(:token, min: 8, max: 1024, count: :bytes)
    |> assoc_constraint(:user)
    # cch-w37-bl — same shape as `TeamInvitation.changeset/2`: the error hangs
    # on the FIRST field, and `:user_id` is a `belongs_to` key the device never
    # sends. `:token` is what the client registers. The index name is now given
    # explicitly BECAUSE the order changed — Ecto derives the default name from
    # the field order, and the migration created
    # `device_push_tokens_user_id_platform_token_index`.
    |> unique_constraint([:token, :user_id, :platform],
      name: :device_push_tokens_user_id_platform_token_index
    )
  end
end
