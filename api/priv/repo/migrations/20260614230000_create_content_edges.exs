defmodule Barkpark.Repo.Migrations.CreateContentEdges do
  @moduledoc """
  Content graph — `content_edges` table: a typed, materialised edge between two
  `documents` rows for the content blast-radius / dependency graph.

  Modelled structurally on `20260528110000_w7a_task_edges.exs` (same FK +
  cascade + tenancy posture, same three-index shape) but with one deliberate
  divergence:

  > `content_edges` DIVERGES from `task_edges` by carrying mutable metadata
  > (weight, plugin_source) and therefore `updated_at`; `task_edges` rows are
  > immutable, these are not.

  Phase-3 incremental upsert replaces `weight` / `plugin_source` on conflict
  (`on_conflict: {:replace, [:weight, :plugin_source, :updated_at]}`) and must
  bump a timestamp — hence `timestamps(type: :utc_datetime_usec)` WITH
  `updated_at` (NOT `updated_at: false` as `task_edges` uses). A future author
  must NOT copy `task_edges`' `updated_at: false` back over this table.

  ## Schema

      content_edges(
        id            uuid PRIMARY KEY,
        from_id       uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        to_id         uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        kind          varchar NOT NULL,
        weight        float8 NULL,     -- LAYOUT-ONLY (never read by ranking),
        plugin_source varchar NULL,
        inserted_at   timestamptz NOT NULL,
        updated_at    timestamptz NOT NULL
      )

  ## No `dangling` column (gap #8 decision)

  A dangling edge is UNSTORABLE: the `to_id` FK forbids a `to_id` that is not a
  `documents.id`, so a `dangling` column would ALWAYS be empty and mislead a
  future author. The table stores ONLY resolvable edges. The live dangling
  signal is computed at READ time by the typed `get_document/4` + untyped
  `Repo.exists?` resolution pass in `Barkpark.Content` (and the Phase-4
  `Content.Graph`), NEVER a table flag. There is also NO partial
  `(dangling) WHERE dangling` index — it went with the column.

  ## Weight is layout-only

  `weight` is a Cytoscape layout hint (edge thickness / spring length),
  consumed ONLY by the Studio graph renderer. Ranking is topology
  (distance, fan-in, inserted_at) and NEVER reads `weight`.

  ## Tenancy / cascade

  Like `task_edges`: the edge carries NO workspace/project/dataset of its own;
  scope is inherited from its two already-scoped endpoint documents. Both FKs
  use `on_delete: :delete_all`, so deleting either endpoint reaps the edge.

  ## Indexes

    * `unique (from_id, to_id, kind)` (`content_edges_from_to_kind_uniq`) —
      backs the `on_conflict: {:replace, …}` upsert in `Content.add_edge/4`.
    * `(from_id, kind)` — outbound scan (`list_outbound_edges/2`, BFS forward).
    * `(to_id, kind)`   — inbound scan (`list_inbound_edges/2`, reverse-walk).

  Reversible: `down/0` drops indexes then the table.
  """

  use Ecto.Migration

  def up do
    create table(:content_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :from_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :to_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false

      # LAYOUT-ONLY (Cytoscape edge thickness / spring) — never read by ranking.
      add :weight, :float, null: true
      add :plugin_source, :string, null: true

      # DIVERGES from task_edges (updated_at: false) deliberately — these rows
      # are MUTABLE on (weight, plugin_source) and the Phase-3 upsert bumps
      # updated_at on conflict.
      timestamps(type: :utc_datetime_usec)
    end

    # Uniqueness — no duplicate edge of the same kind between the same two docs.
    # Backs Content.add_edge/4's on_conflict {:replace, [:weight, :plugin_source,
    # :updated_at]} upsert (REPLACE, not :nothing — re-extract refreshes metadata).
    create unique_index(:content_edges, [:from_id, :to_id, :kind],
             name: :content_edges_from_to_kind_uniq
           )

    # Outbound: "give me X's out-edges" — forward BFS workhorse.
    create index(:content_edges, [:from_id, :kind])

    # Inbound: "give me who points at X" — reverse-referencer walk.
    create index(:content_edges, [:to_id, :kind])
  end

  def down do
    drop_if_exists index(:content_edges, [:to_id, :kind])
    drop_if_exists index(:content_edges, [:from_id, :kind])

    drop_if_exists index(:content_edges, [:from_id, :to_id, :kind],
                     name: :content_edges_from_to_kind_uniq
                   )

    drop table(:content_edges)
  end
end
