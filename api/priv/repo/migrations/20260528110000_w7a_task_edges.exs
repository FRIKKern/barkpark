defmodule Barkpark.Repo.Migrations.W7aTaskEdges do
  @moduledoc """
  W7a step 2 — `task_edges` table: typed dep graph for the orchestrator.

  ## Why a separate table

  Per the W7 plan (§2, "Dependencies as a relational graph"): tasks live in
  the `documents` table; the dep graph rides next to them, NOT in jsonb.
  Two reasons:

    * The ready-queue query needs a `LEFT JOIN … WHERE NOT EXISTS` over
      "all blockers closed?", which is cheap against an indexed relational
      edge but degenerate against a `content->'dependencies'` jsonb scan
      across every candidate row.
    * Edges are typed (`blocks` today; `discovered-from` for the rail's
      walk-back lineage; the masterplan leaves room for more without ever
      touching a document's jsonb).

  ## Schema

      task_edges(
        id           uuid PRIMARY KEY,
        from_id      uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        to_id        uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        kind         varchar NOT NULL,
        inserted_at  timestamptz NOT NULL
      )

  ## Direction convention

  `from_id` = the dependent (the task that BLOCKS ON something).
  `to_id`   = the blocker (the task being depended upon).

  The child "blocks on" the parent.
  The W7-03 ready query (per plan §2) picks this direction:

      WHERE NOT EXISTS (
        SELECT 1 FROM task_edges e
        JOIN documents b ON b.id = e.to_id
        WHERE e.from_id = candidate.id
          AND e.kind = 'blocks'
          AND b.content->>'lifecycle_status' <> 'done')

  i.e. "give me a candidate whose every `blocks`-out-edge points at a done
  document." `Barkpark.Tasks.dependencies/1` returns the candidate's
  blockers (the `to_id` side); `dependents/1` returns who depends on it
  (the `from_id` side).

  ## Indexes

    * `unique (from_id, to_id, kind)` — no duplicate edges; backs the
      `on_conflict: :nothing` idempotent insert in `Tasks.add_dep/3`.
    * `(from_id, kind)` — the ready-query's outbound scan (blockers-of-X).
    * `(to_id, kind)`   — the close-time inbound scan (dependents-of-X,
      for the "newly-unblocked" sweep landing in W7-04).

  ## Cascade

  Both FKs use `on_delete: :delete_all`. Combined with the workspace/
  project/dataset cascades shipped in `20260527160000` +
  `20260527170000`, deleting a workspace (or directly deleting a document)
  reaps all edges that touch a deleted document on EITHER side. No orphans
  because edges have no scope columns of their own — both endpoints carry
  the workspace/project/dataset FKs, and the multi-path cascade Postgres
  guarantees dedups the row delete.

  ## Tenancy

  Edges are a leaf relation between two already-scoped documents. The edge
  itself carries no workspace/project/dataset. Cross-workspace edges are
  not enforced at the table level — they're prevented because in practice
  the application layer (`Barkpark.Tasks.add_dep/3`) only ever holds
  document references retrieved through a scoped read. A confirming test
  in `test/barkpark/tasks_edges_test.exs` documents this.

  Reversible: `down/0` drops indexes + table cleanly.
  """

  use Ecto.Migration

  def up do
    create table(:task_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :from_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :to_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Uniqueness — no duplicate edges of the same kind between the same
    # two docs. Backs Tasks.add_dep/3's `on_conflict: :nothing` idempotency.
    create unique_index(:task_edges, [:from_id, :to_id, :kind],
             name: :task_edges_from_to_kind_uniq
           )

    # Outbound: "give me X's blockers" — the ready-query workhorse.
    create index(:task_edges, [:from_id, :kind])

    # Inbound: "give me X's dependents" — the unblock-on-close sweep.
    create index(:task_edges, [:to_id, :kind])
  end

  def down do
    drop_if_exists index(:task_edges, [:to_id, :kind])
    drop_if_exists index(:task_edges, [:from_id, :kind])

    drop_if_exists index(:task_edges, [:from_id, :to_id, :kind],
                     name: :task_edges_from_to_kind_uniq
                   )

    drop table(:task_edges)
  end
end
