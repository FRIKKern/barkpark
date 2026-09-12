defmodule Barkpark.Repo.Migrations.AddIsDefaultToWorkspaces do
  @moduledoc """
  Move the instance-default workspace's IDENTITY off the mutable, user-claimable
  `slug` string and onto an unclaimable boolean seat (task-566dc5be4871353b).

  ## The decision, and the date it was taken — 2026-09-09

  CHOSEN: a boolean `workspaces.is_default` column plus a PARTIAL UNIQUE INDEX
  (`WHERE is_default`), so at most one row can ever hold the seat and the seat is
  addressable by NO user-supplied string. `Workspace.changeset/2` deliberately
  does NOT cast `:is_default`, so the flag is unreachable from every attrs map
  the HTTP edge, the Studio and the seeds can build; it moves only through
  `Tenancy.establish_default_workspace!/0` and the bundle import's explicit
  in-transaction transfer.

  THE DECIDING CONSTRAINT was named before the shape was: the bundle import's
  PDS-D9 adopt branch (`WorkspaceBundle.adopt_or_refuse_root_slug!/1`) DELETES an
  empty `default` shell in-transaction and lets the imported workspace take the
  slug. A boolean column survives that with TWO SQL statements after the members
  land (clear whatever the COPY carried, then set the flag iff the evicted shell
  held it) — no new failure mode, no new round trip against a table the import
  does not already touch, and the delete keeps rolling back with the rest of the
  transaction exactly as before.

  REJECTED — a settings/singleton pointer row. Same security properties, but it
  puts a SECOND table inside the import transaction: the adopt branch would have
  to update a row the bundle's member set does not contain, widening precisely
  the transaction the row's own filing named as the reason this work was deferred
  out of the p0. It also adds an indirection to `get_default_workspace/0`, which
  `Plugs.AssignDefaultScope` calls on EVERY flat `/v1/*` request.

  REJECTED — a stable well-known UUID. Cheapest to read, but the identity would
  then be a value the bundle's `workspaces` COPY member carries VERBATIM, so a
  crafted bundle claims the seat by shipping that id — the same "identity is
  transferable through user input" defect this row exists to retire, relocated
  rather than closed. It is also unseedable without a hard-coded constant in
  three writers.

  ## Backfill tolerates an ALREADY-VACANT seat

  `UPDATE ... WHERE slug = 'default'` is a plain no-op when no such row exists,
  which is a NORMAL state, not a corrupt one: `bp cloud support add --ws default`
  runs SupportResetDefaultWorkspaceStep (deletes the row) → SupportAdminTokenStep
  (re-mints it), and a migration running BETWEEN those two steps must leave the
  instance with no default rather than crash. It does: zero rows updated, seat
  vacant, and the next `Seeds.Shared.ensure_default_scope/0` establishes it.

  ## Degrades to VACANCY, never to CAPTURE

  With the seat vacant, `get_default_workspace/0` returns nil and an unscoped
  write lands with `workspace_id` NULL (a bounded problem) instead of being
  attributed to whoever holds a string (an unbounded privilege transfer). The
  partial unique index is what makes that ordering hold under concurrency.

  Additive and reversible: `down/0` drops the index and the column, restoring the
  slug-keyed identity byte for byte.
  """
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :is_default, :boolean, null: false, default: false
    end

    # At most ONE row may hold the seat. Partial, so the millions of ordinary
    # `false` rows are not indexed and no `false` row collides with another.
    create unique_index(:workspaces, [:is_default],
             where: "is_default",
             name: :workspaces_single_default_index
           )

    # Tolerant of zero rows BY CONSTRUCTION — see the moduledoc. No `SELECT`
    # first, no assertion on the row count.
    execute("UPDATE workspaces SET is_default = true WHERE slug = 'default'")
  end

  def down do
    drop index(:workspaces, [:is_default], name: :workspaces_single_default_index)

    alter table(:workspaces) do
      remove :is_default
    end
  end
end
