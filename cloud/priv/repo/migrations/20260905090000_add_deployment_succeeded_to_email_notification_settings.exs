defmodule BarkparkCloud.Repo.Migrations.AddDeploymentSucceededToEmailNotificationSettings do
  @moduledoc """
  cch-w30-bl — the per-team toggle for the DEPLOYMENT SUCCEEDED alert, restored
  because the producer wave 30 said it lacked now exists.

  ## What wave 30 removed, and why this is not a re-run of it

  `20260804123000_drop_producerless_notification_events` dropped this column with
  `member_invited` and `token_expiring`, because all three were checkboxes for
  events NOTHING in `cloud/lib` dispatched. The verdict was REMOVE rather than
  "wire the producer" — a toggle that reaches a person before its dispatcher does
  is a promise the control plane cannot keep.

  This migration is the OTHER half of that ruling arriving. It lands in the same
  change as `Registry.dispatch_deployment_terminal/2`, which fires
  `:deployment_succeeded` from BOTH writers that can land the `live` terminal:
  `transition_deployment_fenced/4` and
  `transition_deployment_with_site_update/5` — the one `Sites.Deploy.settle_live/2`
  drives on every static site build, which had no post-transaction dispatch at
  all. `__app.test.mjs`'s bidirectional notification census reds if any half of
  the pairing is missing, in either direction.

  ## DEFAULT FALSE, and the default is the argument

  `EmailSettings`'s moduledoc states the alert-hygiene rule this table has
  followed since it was created: **failures default ON, successes default OFF**
  (Coolify's rule). A deployment going live is a SUCCESS, and a team that deploys
  on every content publish would otherwise be opted in to an email per publish it
  never asked for. `provision_succeeded` — the other success column — is
  `default: false` for the same reason.

  ## No back-fill beyond the column default

  `default: false` + `null: false` is applied by Postgres to existing rows as
  part of the ADD (PG 11+ stores it in the catalog rather than rewriting the
  table), so every existing team gets the same answer a new team gets, and there
  is no separate UPDATE pass to reason about. Nothing else is touched.

  The `down` drops the column again, mirroring the shape of the wave 30 drop it
  reverses.
  """

  use Ecto.Migration

  def change do
    alter table(:email_notification_settings) do
      add :deployment_succeeded, :boolean, null: false, default: false
    end
  end
end
