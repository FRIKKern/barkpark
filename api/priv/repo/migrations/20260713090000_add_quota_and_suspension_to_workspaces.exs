defmodule Barkpark.Repo.Migrations.AddQuotaAndSuspensionToWorkspaces do
  use Ecto.Migration

  @moduledoc """
  Per-workspace quota + suspension state (perfect-plan-build W1, charter D13).

  The `workspaces` table carried only id/slug/name/settings — greenfield at the
  schema layer for a quota gate. This adds the state the `RequireWithinQuota`
  router plug reads at the mutate seam:

    * `quota` — the write cap (document count). NULL = unlimited (the default,
      so every existing workspace stays uncapped and no write changes behaviour).
    * `suspended` — hard write-block flag. NOT NULL, defaults false.
    * `suspended_reason` — free text stamped by `Tenancy.Quota.suspend/2`.
    * `suspended_at` — when the flip happened (audit companion to the
      `workspace.suspended` audit-chain event).

  Purely additive and reversible. No backfill: absent quota (NULL) means
  unlimited, and `suspended` defaults false, so the gate is a no-op for every
  workspace until an operator sets a quota or calls `Quota.suspend/2`.
  """

  def change do
    alter table(:workspaces) do
      add :quota, :integer
      add :suspended, :boolean, null: false, default: false
      add :suspended_reason, :string
      add :suspended_at, :utc_datetime_usec
    end
  end
end
