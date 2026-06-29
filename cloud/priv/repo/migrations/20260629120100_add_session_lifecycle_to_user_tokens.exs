defmodule BarkparkCloud.Repo.Migrations.AddSessionLifecycleToUserTokens do
  use Ecto.Migration

  # INTEGRATION NOTE: this is the COMBINED user_tokens alteration — it merges the
  # account-sessions migration (session lifecycle / device metadata) with the
  # personal-access-tokens migration (PAT columns). The two candidates each shipped
  # their own `20260629120000_*_user_tokens` migration; integration deduped them
  # into this single superset so the table is altered exactly once. Every new
  # column is nullable / defaulted so pre-existing session rows are untouched.
  #
  # Session lifecycle (account-sessions):
  #   * revoked_at  — the leaked-session kill switch (mirrors agent_tokens). NULL =
  #     "live". Stamped on logout / sign-out-everywhere / member-removal. ALSO the
  #     PAT revocation tombstone — shared by both token kinds.
  #   * ip_address / user_agent / last_used_at — device metadata Coolify's
  #     `sessions` table carries (ip_address / user_agent / last_activity), backing
  #     the active-sessions list UI. last_used_at is refreshed on each verify.
  #
  # PAT columns (personal-access-tokens): user_tokens is DUAL-PURPOSE, discriminated
  # by `context` (base default "session"). A PAT is `context = "pat"`:
  #   * name      — the user-facing PAT label.
  #   * abilities — {array,string} ability vocabulary (read/write/deploy/root),
  #     NOT NULL default ["read"]. Session rows ignore it.
  #   * team_id   — binds a PAT to the team it was minted under (Coolify's PAT
  #     team_id). Session rows leave it NULL (a session resolves its team live via
  #     Accounts.primary_team/1).
  def change do
    alter table(:user_tokens) do
      # session lifecycle / device metadata
      add :revoked_at, :utc_datetime_usec
      add :ip_address, :string
      add :user_agent, :string
      add :last_used_at, :utc_datetime_usec

      # PAT columns
      add :name, :string
      add :abilities, {:array, :string}, null: false, default: ["read"]
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all)
    end

    # Backs list_user_sessions/1 + the revoke-all-by-user bulk update: the plain
    # (user_id) index already exists from create_user_tokens; this adds the
    # revoked_at discriminator so the "live sessions for a user" scan stays tight.
    create index(:user_tokens, [:user_id, :revoked_at])

    # PAT-side indexes. The PAT-listing query is
    #   WHERE user_id = ? AND context = 'pat' ORDER BY inserted_at DESC
    # so the composite (user_id, context) index keeps the listing cheap without
    # slowing the hot session-verify path (which still hits the token_hash unique).
    create index(:user_tokens, [:team_id])
    create index(:user_tokens, [:user_id, :context])
  end
end
