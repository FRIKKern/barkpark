defmodule Barkpark.Repo.Migrations.AddPlaygroundTtlToWorkspaces do
  use Ecto.Migration

  @moduledoc """
  Ephemeral-playground TTL + tier state (perfect-plan-build W2c, charter
  D25/D27 — the playground front door).

  Two additive `workspaces` columns feed the self-cleaning playground provision
  path and its future TTL reaper:

    * `expires_at` — when this workspace's TTL lapses. NULL = never expires (the
      default, so every existing/normal workspace is permanent). A playground
      workspace is stamped `now + 48h` at provision time. The plain index on
      this column is the reaper's scan key (`WHERE expires_at < now()`).
    * `tier` — the workspace tier. NULL = a normal, operator/self-provisioned
      workspace (the default). `"playground"` marks a disposable, quota-capped
      ephemeral workspace minted by the front door.

  Purely additive and reversible, mirroring
  `20260713090000_add_quota_and_suspension_to_workspaces.exs`. No backfill:
  absent `expires_at` (NULL) means never-expires and absent `tier` (NULL) means
  normal, so no existing workspace changes behaviour. `workspaces` is
  tenant-scale (one row per tenant), so a plain `create index` is correct — no
  `CONCURRENTLY` ceremony needed.
  """

  def change do
    alter table(:workspaces) do
      add :expires_at, :utc_datetime_usec
      add :tier, :string
    end

    create index(:workspaces, [:expires_at])
  end
end
