defmodule Barkpark.Repo.Migrations.WidenGithubSyncConflictsOpenKey do
  use Ecto.Migration

  @moduledoc """
  GitHub bridge — widen the conflict-quarantine dedup key by `detail.source`
  (epic charter D17).

  Four semantically-distinct problems reuse the FROZEN `out_of_band_edit` kind
  (D14 keeps the kind set to three), discriminated only by a `detail.source`
  string: human drift (NO source key), `graphql`, `sub_issue_rejected`,
  `client_error`. The original partial unique index
  `github_sync_conflicts_open_key` keyed on `{repo, issue, kind}` alone, so two
  co-occurring distinct-source problems on ONE issue collapsed to ONE operator
  row — and a single Resolve cleared BOTH, silently dropping one (e.g. the
  sub-issue never gets linked and nobody knows).

  Widen the key's 4th component to `COALESCE(detail->>'source', '')`, in lockstep
  with `Conflicts.open_row/1`. The `COALESCE(..., '')` is load-bearing: Postgres
  treats NULL as DISTINCT inside a unique index, so a bare `detail->>'source'`
  would let five human-drift records (which carry NO source key → NULL) pile as
  five rows instead of deduping to one. The empty-string coalesce maps every
  no-source record to the SAME discriminator ''.

  Same index NAME is kept so `Conflict.changeset/2`'s
  `unique_constraint(..., name: :github_sync_conflicts_open_key)` still maps the
  lost-insert-race violation to a matchable changeset error.
  """

  def up do
    drop(
      unique_index(:github_sync_conflicts, [:repo, :issue, :kind],
        name: :github_sync_conflicts_open_key
      )
    )

    # Expression index — a functional 4th component. Ecto's `unique_index` can't
    # express COALESCE(detail->>'source',''), so raw SQL. Partial
    # (resolved_at IS NULL) so a resolved key can legitimately re-open.
    execute("""
    CREATE UNIQUE INDEX github_sync_conflicts_open_key
      ON github_sync_conflicts (repo, issue, kind, COALESCE(detail->>'source', ''))
      WHERE resolved_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX github_sync_conflicts_open_key")

    create(
      unique_index(:github_sync_conflicts, [:repo, :issue, :kind],
        where: "resolved_at IS NULL",
        name: :github_sync_conflicts_open_key
      )
    )
  end
end
