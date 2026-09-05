defmodule BarkparkCloud.Repo.Migrations.AddDeploymentRefusedToEmailNotificationSettings do
  @moduledoc """
  cch-w29-bl — the per-team toggle for the AUTO-DEPLOY PREBUILT REFUSAL alert.

  ## What had no column

  `Sites.AutoDeployWorker.refuse/1` mints a `cancelled` deployment row carrying a
  full actionable sentence and returns a cancel tuple. That row is the ONLY trace
  of a refused publish, and it lives on a console page. A person who publishes
  content and walks away learns nothing: the content-publish webhook already
  answered `202 ok` before the guard ran, so the promise was made and quietly
  broken.

  `EmailSettings`'s event vocabulary had no name for it — no atom, no column, no
  dispatcher, no render arm — so there was nothing to switch on even if a person
  had wanted the alert.

  ## DEFAULT TRUE, and the default is the argument

  `EmailSettings`'s own moduledoc states the alert-hygiene rule this table has
  followed since it was created: **failures default ON, successes default OFF**
  (Coolify's rule). A refused publish is a FAILURE — the deploy the person asked
  for did not happen — so the honest default is ON, exactly like
  `deployment_failed`, `provision_failed` and `agent_unreachable` beside it.

  ## No back-fill beyond the column default

  `default: true` + `null: false` is applied by Postgres to existing rows as part
  of the ADD (PG 11+ stores it in the catalog rather than rewriting the table),
  so every existing team gets the same answer a new team gets, and there is no
  separate UPDATE pass to reason about. Nothing else is touched.

  ## The toggle does NOT land ahead of its dispatcher

  Charter D333's shape — a checkbox promising an alert with zero dispatch sites —
  is what this column would BE if it shipped alone. It does not: the same change
  adds `:deployment_refused` to `EmailSettings.@events`, the
  `Notifications.dispatch_site_event/3` call in `AutoDeployWorker.refuse/1`, the
  `EventEmail` and `Render` arms, and the console row. `__app.test.mjs`'s
  bidirectional notification census reds if any half is missing.
  """

  use Ecto.Migration

  def change do
    alter table(:email_notification_settings) do
      add :deployment_refused, :boolean, null: false, default: true
    end
  end
end
