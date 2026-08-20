defmodule BarkparkCloud.Repo.Migrations.CreateDevicePushTokens do
  use Ecto.Migration

  # Push-relay spike (mobile charter D15) — per-user × per-DEVICE push
  # registrations, mirroring user_tokens' discriminated row shape (there the
  # discriminator is `context`; here it is `platform`: "apns" | "fcm"). One row
  # per registered device, NEVER a team-level config blob.
  #
  # SEVERABILITY = ROW-ABSENCE (the chat_blocked webhook-row pattern): with zero
  # rows in this table the entire push relay is inert — the inbound receiver
  # verifies + 202s with nothing enqueued, no worker runs, no feature flag
  # exists. Deleting rows IS the off switch.
  #
  # Expand/contract: purely ADDITIVE (new table). Old code ignores it; new code
  # works with it empty. Safe under blue/green overlap.
  #
  # `token` is the platform-issued device push token — an ADDRESS, not a bearer
  # credential against our API (unlike user_tokens we must keep the plaintext to
  # address APNs/FCM sends, so there is no hash-at-rest here; custody note in
  # BarkparkCloud.Push.DevicePushToken's moduledoc).
  #
  # UNIQUE(user_id, platform, token) makes registration idempotent: the app
  # re-registering on every launch upserts the same row (un-revoking it) instead
  # of accreting duplicates. `revoked_at` is the tombstone (mirrors
  # user_tokens.revoked_at); `last_used_at` is refreshed on each delivery and
  # feeds the wave-2 stale-token reaper (design-notes only in the spike).
  def change do
    create table(:device_push_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :platform, :string, null: false
      add :token, :text, null: false
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:device_push_tokens, [:user_id])
    create unique_index(:device_push_tokens, [:user_id, :platform, :token])
  end
end
