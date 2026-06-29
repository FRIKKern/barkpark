defmodule BarkparkCloud.Repo.Migrations.CreateEmailNotificationSettings do
  use Ecto.Migration

  # One row per Team holding that team's email-notification preferences — the
  # Cloud analogue of Coolify's `email_notification_settings` table
  # (app/Models/EmailNotificationSettings.php). It mirrors the `providers` table:
  # team-owned, unique per team, and any secret column holds CIPHERTEXT only (the
  # Base64 of an AES-256-GCM encryption via BarkparkCloud.Registry.Vault) — the
  # plaintext SMTP password / API key never touches the DB. The per-event boolean
  # toggles follow Coolify's alert-hygiene default: failures default ON, successes
  # default OFF.
  def change do
    create table(:email_notification_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      # Transport selection. "instance" rides the platform Mailer (Barkpark
      # Cloud's own outbound), "smtp" uses the per-team SMTP relay below, "api"
      # a hosted-provider key. One string instead of Coolify's three mutually
      # exclusive booleans (smtp_enabled / resend_enabled /
      # use_instance_email_settings) — same intent, less foot-gun.
      add :transport, :string, null: false, default: "instance"
      add :alerts_enabled, :boolean, null: false, default: true

      # Per-team SMTP transport. The *_encrypted columns hold ciphertext only.
      # host/username/password are secrets; port/encryption/from_* are plain.
      add :smtp_host_encrypted, :text
      add :smtp_username_encrypted, :text
      add :smtp_password_encrypted, :text
      add :smtp_port, :integer
      # starttls | tls | none
      add :smtp_encryption, :string
      # Hosted-provider key (Resend/SendGrid) — ciphertext. The "api" transport
      # adapter itself is deferred (needs a Finch/Hackney HTTP dep), but the
      # column ships so a later adapter has its home.
      add :api_key_encrypted, :text
      add :from_address, :string
      add :from_name, :string

      # Per-event toggles. Failures default true, successes default false
      # (Coolify's alert-hygiene rule). Only events with a real trigger in
      # cloud/ today, plus member_invited / token_expiring whose emit site the
      # owning feature (teams-invite / api-token) adds later.
      add :provision_succeeded, :boolean, null: false, default: false
      add :provision_failed, :boolean, null: false, default: true
      add :deployment_succeeded, :boolean, null: false, default: false
      add :deployment_failed, :boolean, null: false, default: true
      add :agent_reachable, :boolean, null: false, default: false
      add :agent_unreachable, :boolean, null: false, default: true
      add :subscription_past_due, :boolean, null: false, default: true
      add :member_invited, :boolean, null: false, default: false
      add :token_expiring, :boolean, null: false, default: true

      # Rate-limit backstop for the "send test" button (Coolify's 10s/team).
      add :last_test_sent_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_notification_settings, [:team_id])
  end
end
