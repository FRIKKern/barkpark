defmodule Barkpark.Repo.Migrations.AddKindAndPausedToApiTokens do
  use Ecto.Migration

  # Barkpark Tickets — the low-trust ticket-key tier rides the existing
  # `api_tokens` table (reuse hashing / revocation / expiry / tenant scoping for
  # free). Two ADDITIVE columns:
  #
  #   kind       — the token tier. "api" for every existing token (the dev
  #                token, PATs, P5 share tokens) so the fail-closed WHERE clause
  #                in `Auth.verify_token/1` (`t.kind == "api"`) keeps every
  #                current consumer byte-identical. "ticket" marks a ticket key,
  #                resolvable ONLY by `Tickets.Keys.verify/1`. NOT NULL + default
  #                "api" backfills every legacy row in the same statement.
  #   paused_at  — a ticket key an operator has muted. Distinct from revoked_at:
  #                a paused key resolves to {:error, :paused} (403 "key paused")
  #                so a spammer is stopped WITHOUT destroying the thread, whereas
  #                a revoked key is indistinguishable from a missing one (401).
  #
  # No index on `kind` — the lookups are all `token_hash`-keyed (already unique-
  # indexed); kind is a post-hash equality filter, never a scan.
  def change do
    alter table(:api_tokens) do
      add :kind, :string, null: false, default: "api"
      add :paused_at, :utc_datetime
    end
  end
end
