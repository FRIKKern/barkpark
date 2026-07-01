defmodule BarkparkCloud.Repo.Migrations.AddChatChannelsToNotifications do
  use Ecto.Migration

  # notifications-chat: fold chat egress (Discord/Slack/Telegram/Pushover/generic
  # webhook) INTO the already-merged email notification settings, rather than
  # forking a second `notification_settings` table + a second deliveries table.
  #
  # Two jsonb columns on the existing per-team `email_notification_settings` row:
  #
  #   * `channels`      — a jsonb ARRAY of ChannelConfig embeds. Each carries the
  #                       channel `type`, an `enabled` flag, and a Vault-encrypted
  #                       `credentials_encrypted` blob (Base64 AES-256-GCM; plaintext
  #                       webhook URLs / bot tokens / user keys NEVER touch the DB —
  #                       see BarkparkCloud.Registry.Vault + the `redact: true` field).
  #   * `event_routes`  — a jsonb MAP of event_name => [channel_type, …]. A new event
  #                       type is a one-line default change — zero further migrations.
  #
  # And one column on the shared `notification_deliveries` log so a chat send can
  # persist its HTTP status code alongside the existing status/attempts/last_error
  # shape (email sends leave it null).
  def change do
    alter table(:email_notification_settings) do
      # jsonb array of channel configs; default "[]" gives an empty jsonb array.
      add :channels, :map, null: false, default: fragment("'[]'::jsonb")
      # jsonb map of event_name => [channel_type, …]; default "{}".
      add :event_routes, :map, null: false, default: fragment("'{}'::jsonb")
    end

    alter table(:notification_deliveries) do
      # The provider's HTTP response code for a chat send (null for email/transport).
      add :http_status, :integer
    end
  end
end
