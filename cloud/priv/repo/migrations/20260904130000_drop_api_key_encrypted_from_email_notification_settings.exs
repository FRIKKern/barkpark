defmodule BarkparkCloud.Repo.Migrations.DropApiKeyEncryptedFromEmailNotificationSettings do
  use Ecto.Migration

  # Wave 52 S3 (cloud-console-hardening), PART B. `api_key_encrypted` was the
  # storage behind an email transport that never existed. The console offered a
  # third segmented option "API", the schema validated it, this plane
  # Vault-encrypted a key into this column — and NOTHING carried it:
  # `deliver_alert/2` has an `smtp` clause and a catch-all, there is no Swoosh
  # adapter beyond Local/Test/SMTP, and `config.exs` sets `:swoosh, :api_client,
  # false`, which structurally forbids one. An "api" team's alert rode the
  # PLATFORM mailer and its delivery row was stamped `sent`. The column was
  # WRITE-ONLY for its entire life.
  #
  # cch-w52-s1 (`8f109bcac`, PR #10646) deleted the offer, the transport and the
  # schema field. This migration removes the storage.
  #
  # DESTRUCTIVE AND ORDERED — the same ordering law
  # `20260804123000_drop_producerless_notification_events.exs` states, and this
  # migration is templated on that one. Dropping a column an OLD node still
  # SELECTs breaks every `EmailSettings` read (Ecto selects the full field list),
  # so this migration lands WITH or AFTER the deploy that removes the field —
  # NEVER before it. That precondition is already satisfied on main: `8f109bcac`
  # removed `field :api_key_encrypted` from `EmailSettings`, so the nodes this
  # deploy replaces no longer name the column.
  #
  # `down/0` restores the column with its original name and type, so a rollback
  # lands on a schema the previous release can read. It restores the column
  # SHAPE, NOT THE CIPHERTEXT — the encrypted keys themselves are gone and are
  # not recoverable from this table. That is honest rather than lossy: no code
  # path ever read them.
  #
  # THE DEFENSIVE UPDATE in `up/0` is not decoration. `@transports` no longer
  # contains "api", so `validate_inclusion` refuses to write one — but a node
  # running the PREVIOUS release during a rolling deploy still can, and a row
  # left reading `transport = 'api'` after this migration would fail
  # `EmailSettings.changeset/2` on its next update with a value nobody can
  # explain. Rewriting it to `'instance'` names the transport that team's mail
  # was ACTUALLY riding all along. On today's production it touches zero rows;
  # it exists so the migration is CORRECT under a race instead of merely lucky.

  def up do
    execute(
      "UPDATE email_notification_settings SET transport = 'instance' WHERE transport = 'api'"
    )

    alter table(:email_notification_settings) do
      remove :api_key_encrypted
    end
  end

  def down do
    alter table(:email_notification_settings) do
      add :api_key_encrypted, :text
    end
  end
end
