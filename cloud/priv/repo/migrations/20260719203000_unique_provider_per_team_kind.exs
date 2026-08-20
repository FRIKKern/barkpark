defmodule BarkparkCloud.Repo.Migrations.UniqueProviderPerTeamKind do
  use Ecto.Migration

  # gr-p5 / charter GR44 — a Team has AT MOST ONE provider per kind.
  #
  # `create_providers` only ever made a NON-unique index on `team_id`, and
  # `Registry.connect_provider/4` was a plain `Repo.insert`, so "reconnect your
  # Hetzner account" APPENDED a row instead of rotating the credential. Every
  # read path papered over it with newest-wins ordering
  # (`resolved_azure_credentials_for_barkpark`, `resolve_cloudflare_credential`,
  # `provider_of_kind/2` via `list_providers/1`), so the duplicates were
  # invisible — until a delete, an audit, or a per-team count met them.
  #
  # This migration is PURE INSURANCE, not a repair: re-verified against prod on
  # 2026-07-19, `providers` held 1 row and 0 duplicate (team_id, kind) pairs.
  # The DELETE below is therefore expected to remove ZERO rows in every live
  # database; it exists so the index can be created unconditionally on any
  # deployment that DID accumulate duplicates.
  #
  # Newest wins — the same rule the three read paths already applied — so
  # collapsing N rows to 1 is a no-op for every reader. `(inserted_at, id)` is a
  # TOTAL order (usec timestamps can tie under `insert_all`; the uuid breaks the
  # tie deterministically), so exactly one row per pair always survives.
  #
  # The `@dedup_sql` heredoc is executed verbatim by
  # `registry_provider_upsert_test.exs`, which reads it back out of THIS FILE —
  # editing the statement re-runs the protective proof against the new bytes.
  @dedup_sql """
  DELETE FROM providers older
  USING providers newer
  WHERE older.team_id = newer.team_id
    AND older.kind = newer.kind
    AND (newer.inserted_at, newer.id) > (older.inserted_at, older.id)
  """

  def up do
    execute(@dedup_sql)
    create unique_index(:providers, [:team_id, :kind])
  end

  def down do
    drop unique_index(:providers, [:team_id, :kind])
  end
end
