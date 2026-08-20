defmodule BarkparkCloud.Repo.Migrations.DropProducerlessNotificationEvents do
  use Ecto.Migration

  # Wave 30 S1 (cloud-console-hardening). Three per-event toggle columns were
  # promises the control plane could not keep: NOTHING in `cloud/lib` dispatches
  # `:deployment_succeeded`, `:member_invited` or `:token_expiring`, so every
  # checkbox the console drew for them offered an alert that had no producer to
  # send it. `token_expiring` shipped `default: true`, which means a team that
  # never opened the settings page was shown a CHECKED box promising a warning
  # before an API token lapsed.
  #
  # 20260629120100's sibling migration (20260629120200, lines 41-43) admitted
  # this in its own words — "whose emit site the owning feature adds later" —
  # and shipped the defaults anyway. Fourteen months later the emit sites do not
  # exist. The honest move is to stop offering, not to keep waiting.
  #
  # THE COLUMNS ARE DROPPED RATHER THAN WIRED, and for `token_expiring` that is a
  # SAFETY verdict, not a scope one: `Notifications.dispatch_event/3` fans an
  # alert to `team_member_emails(settings.team_id)` — EVERY member — while a
  # `user_tokens` row belongs to ONE user. The obvious producer would have turned
  # a missing alert into a cross-member credential disclosure. The console already
  # states each token's expiry on the page that owns it. `member_invited` is
  # redundant with the real invite mail `Transactional.deliver_invite/1` already
  # sends, and the deployment-success terminal is written by
  # `Sites.Deploy.settle_live/2`, which may legally re-report `live -> live`.
  # The three genuine feature requests are filed as their own task rows.
  #
  # DESTRUCTIVE AND ORDERED. Dropping a column an OLD node still selects breaks
  # every `EmailSettings` read (Ecto selects the full field list), so this
  # migration lands WITH or AFTER the deploy that shrinks `@events` — never
  # before it. `down/0` restores the columns with their original names, types
  # and defaults, so a rollback lands on a schema the previous release can read;
  # the per-team booleans themselves are NOT recoverable, which is honest — they
  # gated nothing.
  def up do
    alter table(:email_notification_settings) do
      remove :deployment_succeeded
      remove :member_invited
      remove :token_expiring
    end
  end

  def down do
    alter table(:email_notification_settings) do
      add :deployment_succeeded, :boolean, null: false, default: false
      add :member_invited, :boolean, null: false, default: false
      add :token_expiring, :boolean, null: false, default: true
    end
  end
end
