defmodule Barkpark.Repo.Migrations.AttributeSyncTablesToWorkspace do
  use Ecto.Migration

  @moduledoc """
  Per-workspace attribution for the FULL sync_* bare-slug family (charter D55).

  All five sync tables were keyed on a bare `{source, dataset[, event_id|doc_id]}`
  tuple with ZERO workspace column, so their tenant grain was a project-ambiguous
  `dataset` slug (every workspace gets a `"production"`). That made them
  E3-dataset / E3-doc-keyed in the workspace bundle — a shared slug was
  project-qualified OUT of both export and delete (charter D21), so a workspace's
  cursors / dead-letters / push-ledger under a shared slug were silently dropped
  from its bundle and orphaned on teardown.

  This migration attributes every row to its owning workspace by adding a NULLABLE
  `workspace_id` FK (`ON DELETE CASCADE`, so a workspace delete sweeps its rows at
  the final `Repo.delete(workspace)`). The column's mere PRESENCE reclassifies all
  five from the E3 lists to E1 (`Catalog.@pinned_e1`): export keys
  `WHERE workspace_id = $ws` and delete rides the FK cascade — the same clean path
  every other E1 table uses.

  ## Nullable, NOT in the primary key (charter D43 / D57)

  The `workspace_id` is a stamped ATTRIBUTION column, not a key component: the
  existing composite PKs (`{source, dataset[, …]}`) and every monotonic-upsert /
  insert-only conflict target are PRESERVED byte-for-byte. This mirrors the D43
  `data_keys` precedent ("nullable keeps E1 classification without forcing the
  write path to crash") and, decisively, keeps the LIVE per-dataset caller of
  `sync_push_cursors` — the GitHub outbound mirror
  (`Barkpark.Plugins.Github.Cursor`, source `"github:outbound"`) — working
  unchanged: it has no single workspace to key on and stamps `NULL` (its rows are
  workspace-agnostic infrastructure and survive any single workspace's teardown).

  The `Barkpark.Sync.*` write path (dormant behind `Sync.enabled?()` /
  `push_active?()`) stamps the resolved configured `workspace_id` on INSERT, so a
  configured workspace's sync state is attributed and export/delete-clean.

  Dormant/empty everywhere (`BARKPARK_SYNC_ENABLED` set by no deploy target), so
  a nullable FK add is a pure metadata change — no backfill, no rewrite.
  """

  @tables ~w(sync_cursors sync_dead_letters sync_push_cursors sync_push_doc_revs sync_push_conflicts)a

  def change do
    for table <- @tables do
      alter table(table) do
        add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      end
    end
  end
end
