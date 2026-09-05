defmodule Barkpark.Repo.Migrations.BackfillTwinCanonicalTaskEdges do
  @moduledoc """
  Re-point every existing `task_edges` endpoint that binds a DRAFT twin at the
  PUBLISHED twin of the same slug (task-85bba5cb33dbd59b).

  `task_edges` FKs reference `documents.id`, a per-row uuid, so an edge binds to
  ONE twin. The ready query's twin-collapse axis surfaces the PUBLISHED row, so
  a `blocks` edge filed onto the draft twin never gated the row anybody can
  claim — a blocker that silently does not block. `Tasks.Edges.add_dep/3` now
  canonicalises on the WRITE path; this repairs the edges written before it.

  THIN CALLER BY DESIGN. The logic is
  `Barkpark.Tasks.Edges.backfill_twin_canonical_edges/0`, not this file, because
  a migration body needs a runner process and so cannot be driven from a test —
  and because an operator needs a re-runnable arm for edges written by an older
  release still in flight. Same split as
  `Barkpark.Tenancy.backfill_user_owner_memberships/0` and its migration.

  IRREVERSIBLE ON PURPOSE: the draft-bound uuids are not recorded after the
  update, and re-pointing edges back at draft twins would restore a silent
  correctness bug. Rolling this deploy back leaves the edges canonical, which is
  harmless — the older `add_dep/3` simply stops canonicalising new ones.
  """

  use Ecto.Migration

  def up do
    %{from: {from_moved, from_deduped}, to: {to_moved, to_deduped}} =
      Barkpark.Tasks.Edges.backfill_twin_canonical_edges()

    # BOTH numbers, because they mean different things to an operator reading a
    # deploy log: "0 re-pointed" is reassuring only if 0 were also de-duplicated.
    IO.puts("""
    twin-canonical task_edges backfill:
      from_id: #{from_moved} re-pointed, #{from_deduped} redundant duplicates removed
      to_id:   #{to_moved} re-pointed, #{to_deduped} redundant duplicates removed
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible: the draft-bound endpoints are not recorded after the update, " <>
          "and restoring them would reinstate a blocker that silently does not block"
  end
end
