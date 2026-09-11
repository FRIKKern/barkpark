defmodule Barkpark.Repo.Migrations.AttributeGithubSyncConflictsToWorkspace do
  use Ecto.Migration

  @moduledoc """
  Per-workspace attribution for the GitHub conflict quarantine
  (`github-bridge-w9-health-workspace-isolation`).

  `github_sync_conflicts` (20260707120000) was keyed on a BARE `dataset` text
  slug and nothing else. A dataset slug is unique only within a PROJECT
  (`Tenancy.Dataset`), so every workspace gets its own `"production"` — which
  means the wave-9 string-scope fix on `GET /v1/plugins/github/status` (pin the
  snapshot to the bearer's `api_token.dataset`) narrows a whole-fleet read to a
  SHARED LABEL, not to a tenant. Two workspaces that both call their dataset
  `production` still read each other's open-conflict backlog, including the
  `doc_id`s and the `detail` payload.

  This migration adds the tenant key the table never had: a NULLABLE
  `workspace_id` FK with `ON DELETE CASCADE`, mirroring the `sync_*` family's
  D55 attribution column exactly (20260714130000).

  ## Nullable, and NOT part of the dedup key

  The partial unique index `github_sync_conflicts_open_key`
  (`{repo, issue, kind, COALESCE(detail->>'source','')} WHERE resolved_at IS
  NULL`, widened by 20260713120000) is PRESERVED byte-for-byte. `workspace_id`
  is a stamped ATTRIBUTION column, never a key component — a GitHub issue is
  one issue no matter which workspace's task mirrors it, so adding the column
  to the key would let one issue pile two open rows and defeat the D7 dedup.

  Nullable because attribution is genuinely not always derivable:

    * a `dedup_refused` row has NO `doc_id` at all (no task was ever born), so
      there is nothing to trace to a workspace;
    * a `{doc_id, dataset}` pair can match documents in MORE THAN ONE workspace
      — that ambiguity is the very leak this task closes, and resolving it by
      picking one would INVENT an attribution.

  ## What the backfill does, stated rather than guessed

  The `UPDATE` below stamps `workspace_id` for EXACTLY those rows whose
  `{doc_id, dataset}` resolves to ONE AND ONLY ONE workspace
  (`COUNT(DISTINCT d.workspace_id) = 1`, and that id not null). Every other
  existing row — no `doc_id`, no matching document, or an AMBIGUOUS match
  across two workspaces sharing the slug — is deliberately LEFT NULL.

  A NULL row is "unattributed", not "everyone's": the read path
  (`Github.Health`) admits `workspace_id IS NULL OR workspace_id = ANY(caller's
  memberships)`, so an unattributable legacy row stays visible to the operators
  who could already see it (no behaviour regression at the existing
  dataset-string grain) while every row that CAN name its tenant is fenced to
  it. New writes stamp the column (`Github.Conflicts` / `Github.MirrorJob`), so
  the NULL population is closed and does not grow.

  ## Index

  A plain index on `workspace_id` — the read path's new predicate and the FK
  cascade both scan it.
  """

  def up do
    alter table(:github_sync_conflicts) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end

    create index(:github_sync_conflicts, [:workspace_id])

    flush()

    # Stamp ONLY unambiguous attributions. A {doc_id, dataset} that resolves to
    # two workspaces (the shared-slug case) yields COUNT(DISTINCT ...) = 2 and is
    # skipped, so the backfill never invents a tenant for a row that has none.
    execute("""
    UPDATE github_sync_conflicts c
       SET workspace_id = sub.workspace_id
      FROM (
            SELECT d.doc_id,
                   d.dataset,
                   -- Postgres has no MIN(uuid); the HAVING below guarantees
                   -- the aggregate holds exactly ONE distinct id, so element 1
                   -- of the distinct array IS that id.
                   (array_agg(DISTINCT d.workspace_id))[1] AS workspace_id
              FROM documents d
             WHERE d.workspace_id IS NOT NULL
             GROUP BY d.doc_id, d.dataset
            HAVING COUNT(DISTINCT d.workspace_id) = 1
           ) AS sub
     WHERE c.doc_id IS NOT NULL
       AND c.workspace_id IS NULL
       AND c.doc_id = sub.doc_id
       AND c.dataset = sub.dataset
    """)
  end

  def down do
    drop index(:github_sync_conflicts, [:workspace_id])

    alter table(:github_sync_conflicts) do
      remove :workspace_id
    end
  end
end
